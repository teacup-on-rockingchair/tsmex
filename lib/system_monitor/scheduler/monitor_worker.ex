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

  def run_command_once_for_test(system, cmd) do
    execute_command_safely(system, cmd)
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

  defp schedule_first_check do
    delay = :rand.uniform(@max_delay_first - @min_delay_first) + @min_delay
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

      # Store results only if at least one succeeded
      store_results_if_successful(system, results_with_status, check_timestamp)
    rescue
      error ->
        Logger.error("""
        ❌ Health check failed for #{system.name}
        Error: #{inspect(error)}
        Type: #{error.__struct__}

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
    
    Enum.map(commands, fn cmd ->
      Logger.debug("Executing #{cmd.id} on #{system.name}")

      output = execute_command_safely(system, cmd)
      is_success = command_successful?(output)
      formatted = OutputFormatter.format_output(output, cmd)

      result = build_command_result(cmd, formatted, timestamp)
      {result, is_success}
    end)
  end

  # Execute a single command with full error handling
  defp execute_command_safely(system, cmd) do
    command_runner_module = Application.get_env(:system_monitor, :command_runner_module, SystemMonitor.SSH.CommandRunner)
    try do
      command_runner_module.execute(system, cmd.command, cmd.timeout, nil)
    rescue
      e ->
        Logger.error("Exception executing #{cmd.id}:  #{inspect(e)}")
        "Error: #{Exception.message(e)}"
    catch
      :exit, reason ->
        Logger.error("Exit executing #{cmd.id}: #{inspect(reason)}")
        "Error: Process exited"
    end
  end

  # Determine if command output indicates success (not a connection/error)
  defp command_successful?(output) do
    case output do
      "Connection failed:" <> _ -> false
      "Error:  timeout" -> false
      "Error:" <> _ -> false
      output when is_binary(output) and byte_size(output) > 0 -> true
      _ -> false
    end
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
