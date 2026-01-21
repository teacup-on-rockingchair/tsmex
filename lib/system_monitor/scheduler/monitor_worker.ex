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
  alias SystemMonitor.Config. {Systems, Commands}

  @min_delay 10
  @max_delay 1800

  @min_delay_first 1
  @max_delay_first 30

  def start_link({system_config, commands_config}) do
    GenServer.start_link(__MODULE__, {system_config, commands_config},
      name: via_tuple(system_config. name)
    )
  end

  defp via_tuple(system_name) do
    {:via, Registry, {SystemMonitor.WorkerRegistry, system_name}}
  end

  def init({system_config, commands_config}) do
    Logger.info("Starting monitor worker for #{system_config.name}")
    schedule_first_check()
    {:ok, %{system:  system_config, commands: commands_config}}
  end

  def handle_info(:check_system, state) do
    perform_health_check(state)
    schedule_next_check()
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

    results =
      Enum.map(commands, fn cmd ->
        Logger.debug("Executing #{cmd.id} on #{system.name}")
        
        # Execute command with error handling
        output = 
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

        formatted = OutputFormatter.format_output(output, cmd)

        {cmd.id,
         %{
           description: cmd.description,
           command: cmd.command,
           format: cmd.format,
           result: formatted,
           executed_at: check_timestamp,
           last_check_time: check_timestamp,
           last_known_good_time: check_timestamp
         }}
      end)
      |> Map.new()

    record = %{
      system_name: system.name,
      timestamp: check_timestamp,
      results: results
    }

    Records.store(record)
    Logger.info("Health check completed for #{system.name}")
  end
end
