defmodule SystemMonitor.Scheduler.MonitorWorker do
  @moduledoc """
  GenServer that periodically checks a system's health.
  Stores results with timestamps for state tracking.
  """

  use GenServer
  require Logger

  alias SystemMonitor.Formatter.OutputFormatter
  alias SystemMonitor.BodyCount
  alias SystemMonitor.Events

  @min_delay 300
  @max_delay 7200

  @min_delay_first 1
  @max_delay_first 30

  def start_link({system_config, %{} = commands_config}) do
    GenServer.start_link(__MODULE__, {system_config, commands_config},
      name: via_tuple(system_config.name)
    )
  end

  def start_link({_system_config, commands_config}) do
    raise ArgumentError,
          "MonitorWorker expects commands_config map, got: #{inspect(commands_config, limit: 5)}"
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

    noise_patterns =
      Map.get(commands_config, :noise_patterns) ||
        get_in(commands_config, [:output_sanitization, :noise_patterns]) ||
        []

    {:ok,
     %{system: system_config, commands: commands_config.commands, noise_patterns: noise_patterns}}
  end

  @impl true
  def handle_info({:reload_configuration, %{source: _source}}, state) do
    Logger.info("#{__MODULE__} reloading system configuration.")

    system_name = state.system.name

    with {:ok, systems_cfg} <- SystemMonitor.Config.Loader.load_systems_config(),
         {:ok, commands_cfg} <- SystemMonitor.Config.Loader.load_commands_config() do
      new_system =
        Enum.find(systems_cfg.systems, fn sys -> sys.name == system_name end) || state.system

      new_commands = Map.get(commands_cfg, :commands, state.commands)

      new_noise_patterns =
        Map.get(commands_cfg, :noise_patterns) ||
          get_in(commands_cfg, [:output_sanitization, :noise_patterns]) ||
          []

      {:noreply,
       %{
         state
         | system: new_system,
           commands: new_commands,
           noise_patterns: new_noise_patterns
       }}
    else
      {:error, reason} ->
        Logger.warning("Failed to reload configuration: #{inspect(reason)}")
        {:noreply, state}
    end
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

  defp records_module do
    Application.get_env(:system_monitor, :records_module, SystemMonitor.Storage.Records)
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

  defp handle_check_results(system, results_with_status, check_timestamp) do
    successful = Enum.count(results_with_status, fn {_result, ok?} -> ok? end)
    total = length(results_with_status)
    failed = total - successful

    Logger.info(
      "Health check completed for #{system.name} with #{successful}/#{total} successful commands."
    )

    # Lenient: store whenever batch execution succeeded (even partial/all-failed command results)
    store_results_if_successful(system, results_with_status, check_timestamp)

    cond do
      failed == 0 ->
        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_updated, system.name, check_timestamp}
        )

        :ok

      successful > 0 ->
        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_check_partial, system.name, check_timestamp,
           %{successful: successful, failed: failed}}
        )

      true ->
        Phoenix.PubSub.broadcast(
          SystemMonitor.PubSub,
          "system_updates",
          {:system_check_failed, system.name, check_timestamp}
        )
    end
  end

  defp perform_health_check(%{system: system, commands: commands, noise_patterns: noise_patterns}) do
    Logger.info("Starting health check for #{system.name}")
    check_timestamp = DateTime.utc_now()

    try do
      # Execute all commands
      results_with_status =
        execute_all_commands(system, commands, check_timestamp, noise_patterns)

      case results_with_status do
        {:ok, commands_results} ->
          handle_check_results(system, commands_results, check_timestamp)

        {:error, reason} ->
          Logger.error("Health check failed for #{system.name}. Error: #{inspect(reason)}")

          Phoenix.PubSub.broadcast(
            SystemMonitor.PubSub,
            "system_updates",
            {:system_check_failed, system.name, check_timestamp}
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
          {:system_check_failed, system.name, check_timestamp}
        )
    end
  end

  # Execute all commands and track success for each
  defp execute_all_commands(system, commands, timestamp, noise_patterns) do
    runner = command_runner_module()
    sudo_password = Map.get(system, :sudo_password)

    case runner.execute_batch(system, commands, sudo_password: sudo_password) do
      {:ok, batch_results} ->
        Logger.debug(
          "BATCH raw results for #{system.name}: #{inspect(batch_results, pretty: true, limit: :infinity)}"
        )

        Logger.debug("Noise patterns: #{inspect(noise_patterns)}")
        batch_by_id = Map.new(batch_results, &{&1.id, &1})

        results_with_status =
          Enum.map(commands, fn cmd ->
            to_result_with_status(cmd, Map.get(batch_by_id, cmd.id), timestamp, noise_patterns)
          end)

        Logger.debug(
          "BATCH mapped results_with_status for #{system.name}: #{inspect(results_with_status, pretty: true, limit: :infinity)}"
        )

        {:ok, results_with_status}

      {:error, reason} ->
        Logger.error("Batch execution failed: #{inspect(reason)}")
        {:error, {:connection_failed, inspect(reason)}}
    end
  end

  defp sanitize_output(output, patterns) when is_binary(output) and is_list(patterns) do
    if patterns == [] do
      output
    else
      output
      |> String.split("\n")
      |> Enum.reject(fn line ->
        trimmed = String.trim(line)
        Enum.any?(patterns, &String.starts_with?(trimmed, &1))
      end)
      |> Enum.join("\n")
      |> String.trim()
    end
  end

  defp sanitize_output(output, _patterns), do: output

  defp to_result_with_status(cmd, %{status: :ok, output: output}, timestamp, noise_patterns) do
    Logger.debug("[#{cmd.id}] raw output: #{inspect(output)}")
    cleaned = sanitize_output(output, noise_patterns)
    Logger.debug("[#{cmd.id}] cleaned output: #{inspect(cleaned)}")
    formatted = safe_format_output(cleaned, cmd)
    Logger.debug("[#{cmd.id}] formatted output: #{inspect(formatted)}")
    result = build_command_result(cmd, formatted, timestamp)
    {result, true}
  end

  defp to_result_with_status(
         cmd,
         %{status: :error, reason: reason, message: message},
         timestamp,
         _noise_patterns
       ) do
    formatted = %{
      type: :error,
      value: message,
      display: "Error (#{reason}): #{message}"
    }

    result = build_command_result(cmd, formatted, timestamp)
    {result, false}
  end

  defp to_result_with_status(cmd, nil, timestamp, _noise_patterns) do
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

    Logger.debug(
      "Record to store for #{system.name}: #{inspect(record, pretty: true, limit: :infinity)}"
    )

    records_module().store(record)

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
