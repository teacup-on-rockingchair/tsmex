defmodule SystemMonitor.Scheduler.Supervisor do
  @moduledoc """
  Supervises all monitor workers.
  """

  use Supervisor
  require Logger

  alias SystemMonitor.Config.Loader
  alias SystemMonitor.Scheduler.MonitorWorker

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Logger.info("Initializing Monitor Supervisor")

    with {:ok, %{systems: systems, ip_range: _ip_range}} <- Loader.load_systems_config(),
         {:ok, commands} <- Loader.load_commands_config() do
      children =
        Enum.map(systems, fn system ->
          %{
            id: {MonitorWorker, system.name},
            start: {MonitorWorker, :start_link, [{system, commands}]},
            restart: :permanent
          }
        end)

      Logger.info("Starting #{length(children)} monitor workers")
      Supervisor.init(children, strategy: :one_for_one)
    else
      {:error, reason} ->
        Logger.error("Failed to load configuration: #{inspect(reason)}")
        Logger.error("Please ensure SYSTEMS_CONFIG_PATH and COMMANDS_CONFIG_PATH are set")
        Supervisor.init([], strategy: :one_for_one)
    end
  end
end
