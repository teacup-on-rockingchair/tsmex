defmodule SystemMonitor.BodyCount do
  @moduledoc """
  GenServer that keeps track of systems that are(not)
  reachable anymore. Per each unreachable system, the counter is incremented by 1.
  Once the counter reaches 3, the system is considered "dead",
  and a scanner is triggered to attempt to scan the network for the system.
  """

  use GenServer
  require Logger

  def start_link(system_addresses \\ []) do
    GenServer.start_link(__MODULE__, system_addresses, name: __MODULE__)
  end

  def report_failure(ip_address) do
    GenServer.cast(__MODULE__, {:increment, ip_address})
  end

  def get(ip_address) do
    GenServer.call(__MODULE__, {:get, ip_address})
  end

  def pending_rescans do
    GenServer.call(__MODULE__, :pending_rescans)
  end

  def report_success(server \\ __MODULE__, system_ip) do
    GenServer.cast(server, {:reset, system_ip})
  end

  def find_counter(counters, system_ip) do
    Enum.find(counters, fn (elem) -> Map.has_key?(elem, system_ip) end)
  end

  def get_counter(counters, system_ip) do
    case find_counter(counters, system_ip) do
      nil -> 0
      counter_map -> Map.get(counter_map, system_ip, 0)
    end
  end

  def handle_increment(counters, system_ip) do
    count = get_counter(counters,system_ip)
    case count >= 3 do
      true ->
        Logger.warning("System #{system_ip} is considered dead. Triggering scanner.")
        # Trigger scanner logic here (e.g., send message to scanner GenServer)
        # Example: Scanner.scan(system_ip)
        counters
      false ->
        IO.puts("Increment ounter for system #{system_ip} from #{count} to #{count + 1}")
        new_counters =  Enum.map(counters, fn(elem) -> case Map.has_key?(elem, system_ip) do
                                                         true ->
                                                           IO.puts("Incrementing counter for system #{system_ip} in map #{inspect(elem)}")
                                                          Map.update(elem, system_ip, 0 ,&(&1 + 1))
                                                         false ->
                                                           IO.puts("No counter for system #{system_ip} in map #{inspect(elem)}. Leaving unchanged.")
                                                          elem
                                                      end
        end)
        IO.puts("New counters after increment: #{inspect(new_counters)}")
        new_counters
    end
  end

  def handle_reset(counters, system_ip) do
    IO.puts("Resetting counter for system #{system_ip}")
    new_counters = Enum.map(counters, fn(elem) -> case Map.has_key?(elem, system_ip) do
                                                    true ->
                                                      IO.puts("Resetting counter for system #{system_ip} in map #{inspect(elem)}")
                                                      Map.put(elem, system_ip, 0)
                                                    false ->
                                                      IO.puts("No counter for system #{system_ip} in map #{inspect(elem)}. Leaving unchanged.")
                                                      elem
                                                  end
    end)
    IO.puts("New counters after reset: #{inspect(new_counters)}")
    new_counters
  end

  def get_password(system_ip) do
    GenServer.call(__MODULE__, {:get_password, system_ip})
  end

  @impl true
  def init(systems_config) do
    IO.puts("Initializing BodyCount GenServer with systems: #{inspect(systems_config)}")
    systems_counters = Enum.map(systems_config, fn system ->
      %{ system.ip => 0 }
    end)
    {:ok, %{counters: systems_counters, config: systems_config}}
  end

  @impl true
  def handle_cast({:increment, system_ip}, systems) do
    case find_counter(systems.counters, system_ip) do
      nil ->
        Logger.warning("System #{system_ip} not found in counters. Ignoring increment.")
        {:noreply, systems}
      _ ->
        IO.puts("Incrementing counter for system #{system_ip} starting from #{inspect(systems)}")
        systems = Map.put(systems, :counters, handle_increment(systems.counters, system_ip))
        IO.puts("New state after increment: #{inspect(systems)}")
        {:noreply, systems}
    end
  end

  @impl true
  def handle_cast({:reset, system_ip}, systems) do
    systems = Map.put(systems, :counters, handle_reset(systems.counters, system_ip))
    {:noreply, systems}
  end

  @impl true
  def handle_call({:get, system_ip}, _from, state) do
    IO.puts("Getting counter for system #{system_ip}")
    value = get_counter(state.counters,  system_ip)
    IO.puts("Counter for system #{system_ip} is #{value}")
    {:reply, value, state}
  end

  @impl true
  def handle_call(:pending_rescans, _from, state) do
    pending = Enum.filter(state.counters, fn(elem) ->
      Map.values(elem) |> Enum.any?(&(&1 >= 3))
    end)
    IO.puts("Pending rescans: #{inspect(pending)}")
    keys =
      pending
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
    IO.puts("Pending rescans keys: #{inspect(keys)}")
    {:reply, keys, state}
  end

  @impl true
  def handle_call({:get_password, system_ip}, _from, state) do
        case Enum.find(state.config, fn system -> system.ip == system_ip end) do
          nil ->
                {:reply, {:error, :not_found}, state}
          system ->
                {:reply, {:ok, system.password}, state}
        end
  end
end
