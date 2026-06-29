defmodule SystemMonitor.BodyCount do
  @moduledoc """
  GenServer that keeps track of systems that are(not)
  reachable anymore. Per each unreachable system, the counter is incremented by 1.
  Once the counter reaches 3, the system is considered "dead",
  and a scanner is triggered to attempt to scan the network for the system.
  """

  use GenServer
  require Logger

  @doc """
  Starts the BodyCount GenServer with a system configuration.
  The system configuration contains a list of systems with their IPs and passwords.
  """ 
  def start_link(system_config \\ %{}) do
    GenServer.start_link(__MODULE__, system_config, name: __MODULE__)
  end

  @doc """
  Reports a failure for the given system_ip. Increments the counter for that system.
  """
  def report_failure(ip_address) do
    GenServer.cast(__MODULE__, {:increment, ip_address})
  end

  @doc """
  Gets the current failure count for the given system_ip.
  """
  def get(ip_address) do
    GenServer.call(__MODULE__, {:get, ip_address})
  end

  @doc """
  Returns a list of system IPs that have reached the failure threshold and are pending rescans.
  """
  def pending_rescans do
    GenServer.call(__MODULE__, :pending_rescans)
  end

  @doc """
  Resets the failure count for the given system_ip. Called after a successful scan.
  """
  def report_success(server \\ __MODULE__, system_ip) do
    GenServer.cast(server, {:reset, system_ip})
  end

  @doc """
  Returns the current state of the counters. Useful for debugging.
  """
  def find_counter(counters, system_ip) do
    Enum.find(counters, fn (elem) -> Map.has_key?(elem, system_ip) end)
  end

  @doc """
  Returns the current failure count for the given system_ip. If the system_ip is not found, returns 0.
  """
  def get_counter(counters, system_ip) do
    case find_counter(counters, system_ip) do
      nil -> 0
      counter_map -> Map.get(counter_map, system_ip, 0)
    end
  end

  @doc """
        Returns the password for the given system_ip.
  """
  def get_password(system_ip) do
    GenServer.call(__MODULE__, {:get_password, system_ip})
  end
  
  @doc """
  Handles the increment of the failure counter for the given system_ip.
  If the counter reaches 3, it logs a warning and triggers the scanner.
  """
  def handle_increment(state, system_ip) do
    counters = state.counters
    config = state.config
    new_counters =  Enum.map(counters, fn(elem) -> case Map.has_key?(elem, system_ip) do
                                                     true ->
                                                       Logger.info("Incrementing counter for system #{system_ip} in map #{inspect(elem)}")
                                                       Map.update(elem, system_ip, 0 ,&(&1 + 1))
                                                     false ->
                                                       Logger.info("No counter for system #{system_ip} in map #{inspect(elem)}. Leaving unchanged.")
                                                       elem
                                                   end
    end)

    if get_counter(new_counters,system_ip) >= 3 do
      Logger.warning("System #{system_ip} is considered dead. Triggering scanner.")
      # Trigger scanner logic here (e.g., send message to scanner GenServer)
      case get_password_internal(system_ip, config) do
        {:ok, password} ->
          Logger.info("Password for system #{system_ip} is #{password}. Triggering scanner.")
          SystemMonitor.scan(config.ip_range, password)
        {:error, :not_found} ->
          Logger.error("Password for system #{system_ip} not found. Could not trigger scan.")
      end
    end
    new_counters
  end

  @doc """
  Handles the reset of the failure counter for the given system_ip.
  Resets the counter to 0 after a successful scan.
  """
  def handle_reset(counters, system_ip) do
    Logger.info("Resetting counter for system #{system_ip}")
    new_counters = Enum.map(counters, fn(elem) -> case Map.has_key?(elem, system_ip) do
                                                    true ->
                                                      Logger.info("Resetting counter for system #{system_ip} in map #{inspect(elem)}")
                                                      Map.put(elem, system_ip, 0)
                                                    false ->
                                                      Logger.info("No counter for system #{system_ip} in map #{inspect(elem)}. Leaving unchanged.")
                                                      elem
                                                  end
    end)
    Logger.info("New counters after reset: #{inspect(new_counters)}")
    new_counters
  end

  @impl true
  def init(systems_config) do
    systems_counters = Enum.map(systems_config.systems, fn system ->
      %{ system.ip => 0 }
    end)
    {:ok, %{counters: systems_counters, config: systems_config}}
  end

  @impl true
  def handle_cast({:increment, system_ip}, state) do
    case find_counter(state.counters, system_ip) do
      nil ->
        Logger.warning("System #{system_ip} not found in counters. Ignoring increment.")
        {:noreply, state}
      _ ->
        Logger.info("Incrementing counter for system #{system_ip} starting from #{inspect(state.counters)}")
        state = Map.put(state, :counters, handle_increment(state, system_ip))
        Logger.info("New state after increment: #{inspect(state.counters)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:reset, system_ip}, systems) do
    systems = Map.put(systems, :counters, handle_reset(systems.counters, system_ip))
    {:noreply, systems}
  end

  @impl true
  def handle_call({:get, system_ip}, _from, state) do
    value = get_counter(state.counters,  system_ip)
    Logger.info("Counter for system #{system_ip} is #{value}")
    {:reply, value, state}
  end

  @impl true
  def handle_call(:pending_rescans, _from, state) do
    pending = Enum.filter(state.counters, fn(elem) ->
      Map.values(elem) |> Enum.any?(&(&1 >= 3))
    end)

    keys =
      pending
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
    Logger.info("Pending rescans for systems: #{inspect(keys)}")
    {:reply, keys, state}
  end

  @impl true
  def handle_call({:get_password, system_ip}, _from, state) do
    {:ok, password} = get_password_internal(system_ip, state.config)
    Logger.info("Password for system #{system_ip} is #{inspect(password)}")
    {:reply, password, state}
  end

  
  @doc """
  Returns the password for the given system_ip from the configuration.
  """
  def get_password_internal(system_ip, config) do
        case Enum.find(config.systems, fn system -> system.ip == system_ip end) do
          nil ->
                {:error, :not_found}
          system ->
                {:ok, system.password}
        end
  end
    
end
