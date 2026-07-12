defmodule SystemMonitor.BodyCount do
  @moduledoc """
  GenServer that keeps track of systems that are(not)
  reachable anymore. Per each unreachable system, the counter is incremented by 1.
  Once the counter reaches 3, the system is considered "dead",
  and a scanner is triggered to attempt to scan the network for the system.
  """

  use GenServer
  require Logger
  alias SystemMonitor.Events

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
  def find_counter(counters, system_ip) when is_list(counters) do
    Enum.find(counters, fn elem ->
      is_map(elem) and Map.has_key?(elem, system_ip)
    end)
  end

  def find_counter(_, _), do: nil

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
  Returns the user&password for the given system_ip.
  """
  def get_credentials(system_ip) do
    GenServer.call(__MODULE__, {:get_credentials, system_ip})
  end

  defp increment_counter(counters, system_ip) do
    Enum.map(counters, fn elem ->
      if Map.has_key?(elem, system_ip) do
        Logger.info("Incrementing counter for system #{system_ip} in map #{inspect(elem)}")
        Map.update(elem, system_ip, 0, &(&1 + 1))
      else
        elem
      end
    end)
  end

  defp trigger_scan(:not_found, :not_found, _, _, new_counters) do
    Logger.error("No credentials found for the system. Cannot trigger scan.")
    new_counters
  end

  defp trigger_scan(user, password, state, system_ip, new_counters) do
    config = state.config
    Logger.info("Triggering scanner for user #{user} with password #{password}")

    case SystemMonitor.scan(config.ip_range, user, password) do
      nil ->
        Logger.info("No system found in the given range.")
        new_counters

      result ->
        Logger.info("System found at IP: #{result}")
        pruned = Enum.reject(state.counters, &Map.has_key?(&1, system_ip))
        pruned
    end
  end

  @doc """
  Handles the increment of the failure counter for the given system_ip.
  If the counter reaches 3, it logs a warning and triggers the scanner.
  """
  def handle_increment(state, system_ip) do
    counters = state.counters
    config = state.config
    new_counters = increment_counter(counters, system_ip)
    {_reply, user, password} = get_credentials_internal(system_ip, config)

    if get_counter(new_counters, system_ip) < 3 do
      new_counters
    else
      trigger_scan(user, password, state, system_ip, new_counters)
    end
  end

  @doc """
  Handles the reset of the failure counter for the given system_ip.
  Resets the counter to 0 after a successful scan.
  """
  def handle_reset(counters, system_ip) do
    Logger.info("Resetting counter for system #{system_ip}")
    new_counters = Enum.reject(counters, fn x -> Map.has_key?(x, system_ip) end)
    Logger.info("New counters after reset: #{inspect(new_counters)}")
    [%{system_ip => 0} | new_counters]
  end

  @impl true
  def init(%{systems: systems} = systems_config) when is_list(systems) do
    systems_counters =
      Enum.map(systems_config.systems, fn system ->
        %{system.ip => 0}
      end)

    :ok = Events.subscribe_system_events()
    {:ok, %{counters: systems_counters, config: systems_config}}
  end

  def init(systems_config) do
    raise ArgumentError,
          "SystemMonitor.BodyCount requires config %{systems: list}, got: #{inspect(systems_config)}"
  end

  @impl true
  def handle_info({:reload_configuration, %{source: _source}}, state) do
    Logger.info("#{__MODULE__}  reloading system configuration.")
    old_counters = state.counters
    {:ok, new_config} = SystemMonitor.Config.Loader.load_systems_config()
    Logger.warning("Handle infor state.counters #{old_counters}")
    {:noreply, %{counters: old_counters, config: new_config}}
  end

  @impl true
  def handle_cast({:increment, system_ip}, state) do
    case find_counter(state.counters, system_ip) do
      nil ->
        Logger.warning(
          "System #{system_ip} not found in counters. Ignoring increment. state.counters #{inspect(state.counters)}"
        )

        {:noreply, state}

      _ ->
        new_counters = handle_increment(state, system_ip)
        new_state = %{state | counters: new_counters}

        Logger.debug(
          "System #{system_ip}  found in counters. Incrementing state.counters #{inspect(new_state.counters)}"
        )

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:reset, system_ip}, systems) do
    systems = Map.put(systems, :counters, handle_reset(systems.counters, system_ip))

    Logger.debug(
      "Reset counter for system #{system_ip}. New counters: #{inspect(systems.counters)}"
    )

    {:noreply, systems}
  end

  @impl true
  def handle_call({:get, system_ip}, _from, state) do
    value = get_counter(state.counters, system_ip)

    Logger.debug(
      "Counter for system #{system_ip} is #{value} state.counters: #{inspect(state.counters)}"
    )

    {:reply, value, state}
  end

  @impl true
  def handle_call(:pending_rescans, _from, state) do
    pending =
      Enum.filter(state.counters, fn elem ->
        Map.values(elem) |> Enum.any?(&(&1 >= 3))
      end)

    keys =
      pending
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    Logger.info(
      "Pending rescans for systems: #{inspect(keys)} and state.counters: #{inspect(state.counters)}"
    )

    {:reply, keys, state}
  end

  @impl true
  def handle_call({:get_credentials, system_ip}, _from, state) do
    {:ok, user, password} = get_credentials_internal(system_ip, state.config)

    Logger.info(
      "Password for system #{system_ip} is #{inspect(password)}  state.counters: #{inspect(state.counters)}"
    )

    {:reply, {user, password}, state}
  end

  @doc """
  Returns the password and username for the given system_ip from the configuration.
  """
  def get_credentials_internal(system_ip, config) do
    case Enum.find(config.systems, fn system -> system.ip == system_ip end) do
      nil ->
        {:error, :not_found, :not_found}

      system ->
        {:ok, system.username, system.password}
    end
  end
end
