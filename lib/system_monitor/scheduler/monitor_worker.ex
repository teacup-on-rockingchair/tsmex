defmodule SystemMonitor.Scheduler.MonitorWorker do
  @moduledoc """
  GenServer that periodically checks a system's health.
  Stores results with timestamps for state tracking.
  """

  use GenServer
  require Logger

  alias SystemMonitor.SSH.CommandRunner
  alias SystemMonitor.Storage.Records
  alias SystemMonitor.Formatter.OutputFormatter
  alias SystemMonitor.Config.{Systems, Commands}

  @min_delay 10
  @max_delay 1800

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

  def init({system_config, commands_config}) do
    Logger.info("Starting monitor worker for #{system_config.name}")
    schedule_first_check()
    {:ok, %{system: system_config, commands: commands_config}}
  end

  def handle_info(:check_system, state) do
    schedule_next_check()
    perform_health_check(state)
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

    # Execute all commands
    results_with_status = execute_all_commands(system, commands, check_timestamp)

    # Store results only if at least one succeeded
    store_results_if_successful(system, results_with_status, check_timestamp)
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
    try do
      CommandRunner.execute(system, cmd.command, cmd.timeout)
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
    else
      log_skipped_storage(system.name, total_count)
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
    # Broadcast that data changed
    Phoenix.PubSub.broadcast(
      SystemMonitor.PubSub,
      "system_updates",
      {:system_updated, system.name, record}
    )
    Logger.info(
      "✓ #{system.name}:  Health check completed - stored #{success_count}/#{total_count} results"
    )
  end

  # Log when storage is skipped due to all failures
  defp log_skipped_storage(system_name, total_count) do
    Logger.warn(
      "✗ #{system_name}: Health check completed - skipped storage " <>
        "(all #{total_count} commands failed, likely SSH connection issue)"
    )
  end

  # defp perform_health_check(%{system: system, commands: commands}) do
  #   Logger.info("Starting health check for #{system.name}")
  #   check_timestamp = DateTime.utc_now()

  #   results =
  #     Enum.map(commands, fn cmd ->
  #       Logger.debug("Executing #{cmd.id} on #{system.name}")

  #       # Execute command with error handling
  #       output =
  #         try do
  #           CommandRunner.execute(system, cmd.command, cmd.timeout)
  #         rescue
  #           e ->
  #             Logger.error("Exception executing #{cmd.id}:  #{inspect(e)}")
  #             "Error: #{Exception.message(e)}"
  #         catch
  #           :exit, reason ->
  #             Logger.error("Exit executing #{cmd.id}: #{inspect(reason)}")
  #             "Error: Process exited"
  #         end

  #       formatted = OutputFormatter.format_output(output, cmd)

  #       {cmd.id,
  #        %{
  #          description: cmd.description,
  #          command: cmd.command,
  #          format: cmd.format,
  #          result: formatted,
  #          executed_at: check_timestamp,
  #          last_check_time: check_timestamp,
  #          last_known_good_time: check_timestamp
  #        }}
  #     end)
  #     |> Map.new()

  #   record = %{
  #     system_name: system.name,
  #     timestamp: check_timestamp,
  #     results: results
  #   }

  #   Records.store(record)
  #   Logger.info("Health check completed for #{system.name}")
  # end
end
