defmodule SystemMonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SystemMonitorWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:system_monitor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SystemMonitor.PubSub},
      {Registry, keys: :unique, name: SystemMonitor.WorkerRegistry},
      SystemMonitor.Storage.Records,
      SystemMonitor.Scheduler.Supervisor,
      SystemMonitorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SystemMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SystemMonitorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
