defmodule SystemMonitor.SSH.ConnectionPool do
  use GenServer
  require Logger

  # Max 20 concurrent connections
  @max_concurrent 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{active:  0}, name: __MODULE__)
  end

  def acquire do
    GenServer.call(__MODULE__, :acquire, 30_000)
  end

  def release do
    GenServer.cast(__MODULE__, :release)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call(:acquire, _from, %{active: active} = state) do
    if active < @max_concurrent do
      Logger.debug("Connection acquired (#{active + 1}/#{@max_concurrent})")
      {:reply, :ok, %{state | active: active + 1}}
    else
      Logger.debug("Connection pool full, waiting...")
      # Wait a bit and retry
      Process.sleep(200)
      {:reply, :retry, state}
    end
  end

  def handle_cast(:release, %{active: active} = state) do
    Logger.debug("Connection released (#{max(active - 1, 0)}/#{@max_concurrent})")
    {:noreply, %{state | active: max(active - 1, 0)}}
  end
end
