defmodule SystemMonitor.Scheduler.MonitorWorker do
  @moduledoc """
  GenServer that periodically checks a system's health.
  Stores results with timestamps for state tracking.
  """

  use GenServer
  require Logger

  alias SystemMonitor.Storage.Records
  alias SystemMonitor.Formatter.OutputFormatter
  alias SystemMonitor.BodyCount
  alias SystemMonitor.Events

  @min_delay 300
  @max_delay 7200

  @min_delay_first 1
  @max_delay_first 30


  def start_link({system_config, commands_config}) do
    GenServer.start_link(__MODULE__, {system_config, commands_config},
      name: via_tuple(system_config.name)
    )
  end

  defp via_tuple(system_name) do
    {:via, Registry, {SystemMonitor.WorkerRegistry, system_name}}
  end

  @impl true
  def init({system_config, commands_config}) do
    Logger.info("Starting monitor worker for #{system_config.name}")
    # Subscribe to worker commands
    :ok = Events.subscribe_worker_commands(system_config.name)
    # Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "worker_commands")
    :ok = Events.subscribe_system_events()
    Logger.info("📡 Subscribed to worker_commands")
    schedule_first_check()
    {:ok, %{system: system_config, commands: commands_config}}
  end


  @impl true
  def handle_info({:reload_configuration, %{source: _source}}, state) do
    Logger.info("#{__MODULE__}  reloading system configuration.")
    # Here you would implement the logic to reload the configuration
    # For example, you might fetch the latest config from a shared source
    commands_config = state.commands
    {:ok , new_config_global} = SystemMonitor.Config.Loader.load_systems_config()
    new_config = Enum.find(new_config_global.systems, fn sys -> sys.name == state.system.name end)
    {:noreply, %{ system: new_config, commands: commands_config}}

  end

  @impl true
  def handle_info(:check_system, state) do
    schedule_next_check()
    perform_health_check(state)
    {:noreply, state}
  end

  # Handle immediate check request from PubSub
  @impl true

  def handle_info({:worker_command, :trigger_check, system_name}, %{system: system} = state) do
    if system.name == system_name do
      Logger.info("🚀 Immediate check triggered for #{system_name}")

      # Perform health check immediately
      perform_health_check(state)
    else
      Logger.debug("📭 Ignoring trigger for #{system_name} (I'm #{system.name})")
    end

    {:noreply, state}
  end

  defp command_runner_module do
    Application.get_env(:system_monitor, :command_runner_module, SystemMonitor.SSH.CommandRunner)
  end

  defp schedule_first_check do
    delay = :rand.uniform(@max_delay_first - @min_delay_first) + @min_delay_first
    Logger.debug("Next check in #{delay} seconds")
    Process.send_after(self(), :check_system, delay * 1000)
  end

  defp schedule_next_check do
    delay = :rand.uniform(@max_delay - @min_delay) + @min_delay
    Logger.debug("Next check in #{delay} seconds")
    Process.send_after(self(), :check_system, delay * 1000)
  end

  defp perform_health_check(%{system: system, commands: commands}) do
    Logger.info("Starting health check for #{system.name}")
    check_timestamp = DateTime.utc_now()

    try do
      # Execute all commands
      results_with_status = execute_all_commands(system, commands, check_timestamp)
      case results_with_status do
        {:ok, results_with_status } ->
          successful =
            Enum.count(results_with_status, fn {_result, ok?} -> ok? end)
          Logger.info("Health check completed for #{system.name} with #{successful} successful commands.")
          store_results_if_successful(system, results_with_status, check_timestamp)
        {:error, reason} ->
          Logger.error("Health check failed for #{system.name}. Error: #{inspect(reason)}")

          Phoenix.PubSub.broadcast(
            SystemMonitor.PubSub,
            "system_updates",
            {:system_check_failed, system.name, DateTime.utc_now()}
          )
      end
    rescue
      error ->
        Logger.error("""
        ❌ Health check failed for #{system.name}
        Error: #{inspect(error)}
        Type: #{inspect(error.__struct__)}

        This was likely a storage, formatting, or configuration error.
        Worker continues running.
        """)

        # Notify of failure
        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_check_failed, system.name, DateTime.utc_now()}
        )
    end
  end

  # Execute all commands and track success for each
  defp execute_all_commands(system, commands, timestamp) do
    runner = command_runner_module()

    case runner.execute_batch(system, commands, sudo_password: system[:sudo_password]) do
      {:ok, batch_results} ->
        batch_by_id = Map.new(batch_results, &{&1.id, &1})

        results_with_status =
          Enum.map(commands, fn cmd ->
            to_result_with_status(cmd, Map.get(batch_by_id, cmd.id), timestamp)
          end)

        {:ok, results_with_status}

      {:error, reason} ->
        Logger.error("Batch execution failed: #{inspect(reason)}")
        {:error, {:connection_failed, inspect(reason)}}
    end
  end

  defp to_result_with_status(cmd, %{status: :ok, output: output}, timestamp) do
    formatted = safe_format_output(output, cmd)
    result = build_command_result(cmd, formatted, timestamp)
    {result, true}
  end

  defp to_result_with_status(cmd, %{status: :error, reason: reason, message: message}, timestamp) do
    formatted = %{
      type: :error,
      value: message,
      display: "Error (#{reason}): #{message}"
    }

    result = build_command_result(cmd, formatted, timestamp)
    {result, false}
  end

  defp to_result_with_status(cmd, nil, timestamp) do
    error_output = "Error: missing batch result for command #{cmd.id}"

    formatted = %{
      type: :error,
      value: error_output,
      display: error_output
    }

    result = build_command_result(cmd, formatted, timestamp)
    {result, false}
  end

  defp safe_format_output(output, cmd) do
    OutputFormatter.format_output(output, cmd)
  rescue
    reason ->
      Logger.warning(
        "Error formatting output for command #{cmd.id}: #{inspect(output)} #{inspect(reason)}"
      )

    %{type: :raw, value: output, display: to_string(output)}
  end

  # Build the result data structure for a command
  defp build_command_result(cmd, formatted_output, timestamp) do
    {cmd.id,
     %{
       description: cmd.description,
       command: cmd.command,
       format: cmd.format,
       result: formatted_output,
       executed_at: timestamp,
       last_check_time: timestamp,
       last_known_good_time: timestamp
     }}
  end

  # Store results only if at least one command succeeded
  defp store_results_if_successful(system, results_with_status, timestamp) do
    success_count = count_successful_commands(results_with_status)
    total_count = length(results_with_status)

    if success_count > 0 do
      do_store_results(system, results_with_status, timestamp, success_count, total_count)
      BodyCount.report_success(system.ip)
    else
      BodyCount.report_failure(system.ip)
      log_skipped_storage(system.name, timestamp, total_count)
    end
  end

  # Count how many commands succeeded
  defp count_successful_commands(results_with_status) do
    Enum.count(results_with_status, fn {_, success} -> success end)
  end

  # Actually store the results
  defp do_store_results(system, results_with_status, timestamp, success_count, total_count) do
    results =
      results_with_status
      |> Enum.map(fn {result, _} -> result end)
      |> Map.new()

    record = %{
      system_name: system.name,
      timestamp: timestamp,
      results: results
    }

    Records.store(record)

    Logger.info(
      "✓ #{system.name}:  Health check completed - stored #{success_count}/#{total_count} results"
    )
  end

  # Log when storage is skipped due to all failures
  defp log_skipped_storage(system_name, timestamp, total_count) do
    Logger.warning(
      "✗ #{system_name}: Health check completed - skipped storage " <>
        "(all #{total_count} commands failed, likely SSH connection issue)"
    )

    Phoenix.PubSub.broadcast(
      SystemMonitor.PubSub,
      "system_updates",
      {:system_check_failed, system_name, timestamp}
    )
  end
end
