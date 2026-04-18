defmodule SystemMonitor.Storage.Records do
  @moduledoc """
  Persistent storage for health check records using DETS.
  Data survives application restarts.
  """

  use GenServer
  require Logger

  @max_records_per_system 30
  @dets_dir "priv/data"
  @health_records_file "health_records.dets"
  @system_states_file "system_states.dets"

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    # Ensure data directory exists
    File.mkdir_p!(@dets_dir)

    # Open DETS tables (create if don't exist)
    health_records_path = Path.join(@dets_dir, @health_records_file)
    system_states_path = Path.join(@dets_dir, @system_states_file)

    case :dets.open_file(:health_records,
           type: :set,
           file: String.to_charlist(health_records_path)
         ) do
      {:ok, :health_records} ->
        Logger.info("Opened health_records DETS table:  #{health_records_path}")

      {:error, reason} ->
        Logger.error("Failed to open health_records DETS:  #{inspect(reason)}")
        raise "Could not open health_records DETS table"
    end

    case :dets.open_file(:system_states,
           type: :set,
           file: String.to_charlist(system_states_path)
         ) do
      {:ok, :system_states} ->
        Logger.info("Opened system_states DETS table: #{system_states_path}")

        # Log existing systems on startup
        existing_systems =
          :dets.foldl(
            fn {system_name, _state}, acc -> [system_name | acc] end,
            [],
            :system_states
          )

        if length(existing_systems) > 0 do
          Logger.info(
            "Restored data for #{length(existing_systems)} systems:  #{inspect(existing_systems)}"
          )
        end

      {:error, reason} ->
        Logger.error("Failed to open system_states DETS:  #{inspect(reason)}")
        raise "Could not open system_states DETS table"
    end

    {:ok, %{}}
  end

  def terminate(_reason, _state) do
    Logger.info("Closing DETS tables...")
    :dets.close(:health_records)
    :dets.close(:system_states)
    :ok
  end

  @doc """
  Store a new health check record and update last known states.
  """
  def store(record) do
    GenServer.cast(__MODULE__, {:store, record})
  end

  @doc """
  Get the latest check record (may contain failures).
  """
  def get_latest(system_name) do
    case :dets.lookup(:health_records, system_name) do
      [{^system_name, records}] -> List.first(records)
      [] -> nil
    end
  end

  @doc """
  Get all historical records for a system.
  """
  def get_all(system_name) do
    case :dets.lookup(:health_records, system_name) do
      [{^system_name, records}] -> records
      [] -> []
    end
  end

  @doc """
  Get the current state view for all systems.
  This combines latest check time with last known good states.
  """
  def get_latest_for_all_systems do
    :dets.foldl(
      fn {_system_name, state}, acc -> [state | acc] end,
      [],
      :system_states
    )
  end

  @doc """
  Get the current state for a specific system.
  """
  def get_system_state(system_name) do
    case :dets.lookup(:system_states, system_name) do
      [{^system_name, state}] -> state
      [] -> nil
    end
  end

  @doc """
  Clear all data (useful for testing or maintenance).
  """
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  def handle_cast({:store, record}, state) do
    system_name = record.system_name

    # Store in history
    result = store_in_history(system_name, record)

    # Update system state
    update_system_state(system_name, record)

    # ✅ Broadcast AFTER storage completes
    case result do
      :ok ->
        Logger.debug("✅ Stored, broadcasting update for #{system_name}")

        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_updated, system_name, record.timestamp}
        )

        Logger.debug("📤 Broadcast complete for #{system_name}")

      {:error, reason} ->
        Logger.error("❌ Store failed for #{system_name}: #{inspect(reason)}")

        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_check_failed, system_name, record.timestamp}
        )
    end

    Logger.debug("Stored health record for #{system_name}")

    {:noreply, state}
  end

  def handle_call(:clear_all, _from, state) do
    :dets.delete_all_objects(:health_records)
    :dets.delete_all_objects(:system_states)
    Logger.info("Cleared all stored data")
    {:reply, :ok, state}
  end

  defp store_in_history(system_name, record) do
    try do
      existing =
        case :dets.lookup(:health_records, system_name) do
          [{^system_name, records}] -> records
          [] -> []
        end

      updated = [record | existing] |> Enum.take(@max_records_per_system)
      :dets.insert(:health_records, {system_name, updated})
      # Force write to disk
      case :dets.sync(:health_records) do
        :ok ->
          Logger.debug("✅ DETS synced for #{system_name}")
          :ok

        {:error, reason} ->
          Logger.error("❌ DETS sync failed: #{inspect(reason)}")
          {:error, :sync_failed}
      end
    rescue
      error ->
        Logger.error("❌ Storage exception: #{inspect(error)}")
        {:error, error}
    end
  end

  defp update_system_state(system_name, new_record) do
    # Get existing state
    existing_state =
      case :dets.lookup(:system_states, system_name) do
        [{^system_name, state}] -> state
        [] -> init_system_state(system_name)
      end

    # Merge new results with existing known states
    updated_results =
      Enum.reduce(new_record.results, existing_state.results, fn {cmd_id, new_cmd_data}, acc ->
        existing_cmd_data = Map.get(acc, cmd_id)

        updated_cmd_data =
          merge_command_state(existing_cmd_data, new_cmd_data, new_record.timestamp)

        Map.put(acc, cmd_id, updated_cmd_data)
      end)

    # Create updated state
    updated_state = %{
      system_name: system_name,
      last_check_time: new_record.timestamp,
      results: updated_results
    }

    :dets.insert(:system_states, {system_name, updated_state})
    # Force write to disk
    :dets.sync(:system_states)
  end

  defp init_system_state(system_name) do
    %{
      system_name: system_name,
      last_check_time: nil,
      results: %{}
    }
  end

  defp merge_command_state(existing, new, check_time) do
    # Check if new result is valid (not an error/timeout)
    new_is_valid = is_valid_result?(new.result)

    cond do
      # No existing data - use new data regardless
      is_nil(existing) ->
        Map.put(new, :last_known_good_time, check_time)

      # New data is valid - update everything
      new_is_valid ->
        new
        |> Map.put(:last_known_good_time, check_time)
        |> Map.put(:last_check_time, check_time)

      # New data is invalid - keep old state but update check time
      true ->
        existing
        |> Map.put(:last_check_time, check_time)
        |> Map.put(:check_failed, true)
    end
  end

  defp is_valid_result?(result) do
    case result do
      %{value: value} when is_binary(value) ->
        # Check if it's not an error message
        not String.contains?(value, ["Connection failed", "Error:", "timeout"])

      %{value: _} ->
        true

      _ ->
        false
    end
  end
end
