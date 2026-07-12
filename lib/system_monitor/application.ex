defmodule SystemMonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    result = SystemMonitor.Config.Loader.load_systems_config()
    {:ok, configured_systems} = result

    children =
      [
        SystemMonitorWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:system_monitor, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SystemMonitor.PubSub},
        {Registry, keys: :unique, name: SystemMonitor.WorkerRegistry},
        SystemMonitor.Storage.Records,
        SystemMonitor.Scheduler.Supervisor,
        SystemMonitor.SSH.ConnectionPool,
        SystemMonitorWeb.Endpoint
      ] ++ body_count_children(configured_systems)

    opts = [strategy: :one_for_one, name: SystemMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp body_count_children(configured_systems) do
    if Application.get_env(:system_monitor, :start_body_count, true) do
      IO.puts(
        "Starting BodyCount GenServer with configured systems: #{inspect(configured_systems)}"
      )

      [
        {SystemMonitor.BodyCount, configured_systems}
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    SystemMonitorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
