defmodule SystemMonitorWeb.DashboardLive do
  use SystemMonitorWeb, :live_view

  alias SystemMonitorWeb.DashboardLive.SystemHealth
  require Logger

  # ============================================================================
  # LiveView Callbacks
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "system_updates")
    end

    socket =
      socket
      |> assign_commands()
      |> assign(:services, [])
      |> assign_sort(:system_name, :asc)
      |> assign_systems()
      |> assign_services()
      |> assign_expanded_systems()
      |> assign_last_update()

    {:ok, socket}
  end

  defp assign_systems(socket) do
    systems =
      load_systems()
      |> sort_systems(
        socket.assigns.sort_by,
        socket.assigns.sort_dir,
        socket.assigns.commands || [],
        socket.assigns.services || []
      )

    assign(socket, :systems, systems)
  end

  defp assign_sort(socket, sort_by, sort_dir) do
    socket
    |> assign(:sort_by, sort_by)
    |> assign(:sort_dir, sort_dir)
  end

  def assign_commands(socket) do
    case loader_module().load_commands_config() do
      {:ok, %{commands: commands}} ->
        assign(socket, commands: commands)

      {:error, _reason} ->
        socket
        |> assign(commands: [])
        |> put_flash(:error, "Failed to load commands configuration")
    end
  end

  def assign_services(socket) do
    case loader_module().load_services_config() do
      {:ok, services} ->
        assign(socket, services: services)

      {:error, _reason} ->
        socket
        |> assign(services: [])
        |> put_flash(:error, "Failed to load services configuration")
    end
  end

  def assign_expanded_systems(socket) do
    assign(socket, expanded_systems: MapSet.new())
  end

  def handle_info({:system_updated, _system_name, _timestamp}, socket) do
    {:noreply, assign_systems(socket)}
  end

  def handle_info({:system_check_failed, _system_name, _timestamp}, socket) do
    {:noreply, assign_systems(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    try do
      Logger.info("Refresh triggered!")

      socket =
        socket
        |> assign(systems: load_systems())
        |> assign_systems()
        |> assign_services()
        |> assign_last_update()

      {:noreply, socket}
    rescue
      error ->
        Logger.error("""
        ❌ Refresh FAILED!
        Error: #{Exception.message(error)}

        Stacktrace:
        #{Exception.format_stacktrace(__STACKTRACE__)}
        """)

        # Don't crash, just skip this refresh
        {:noreply, socket}
    catch
      kind, reason ->
        Logger.error("""
        ❌ Refresh CAUGHT #{kind}!
        Reason: #{inspect(reason)}

        Stacktrace:
        #{Exception.format_stacktrace(__STACKTRACE__)}
        """)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_system", %{"system" => system_name}, socket) do
    expanded = socket.assigns.expanded_systems

    new_expanded =
      if MapSet.member?(expanded, system_name) do
        MapSet.delete(expanded, system_name)
      else
        MapSet.put(expanded, system_name)
      end

    {:noreply, assign(socket, expanded_systems: new_expanded)}
  end

  @impl true
  def handle_event("sort", %{"by" => by}, socket) do
    sort_by = parse_sort_by(by)

    sort_dir =
      if socket.assigns.sort_by == sort_by do
        toggle_sort_dir(socket.assigns.sort_dir)
      else
        default_sort_dir(sort_by)
      end

    systems =
      socket.assigns.systems
      |> sort_systems(
        sort_by,
        sort_dir,
        socket.assigns.commands || [],
        socket.assigns.services || []
      )

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:systems, systems)

    {:noreply, socket}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp load_systems do
    records_module().get_latest_for_all_systems()
  end

  defp assign_last_update(socket) do
    assign(socket, last_update: DateTime.utc_now())
  end

  # ============================================================================
  # Sorting
  # ============================================================================

  defp parse_sort_by("system_name"), do: :system_name
  defp parse_sort_by("health"), do: :health
  defp parse_sort_by("last_update"), do: :last_update
  defp parse_sort_by(_), do: :system_name

  defp default_sort_dir(:system_name), do: :asc
  defp default_sort_dir(:health), do: :desc
  defp default_sort_dir(:last_update), do: :desc

  defp toggle_sort_dir(:asc), do: :desc
  defp toggle_sort_dir(:desc), do: :asc

  defp sort_systems(systems, sort_by, sort_dir, _commands, services) do
    sorter =
      case sort_by do
        :system_name ->
          &String.downcase(system_name(&1))

        :health ->
          &health_rank(&1, services)

        :last_update ->
          &last_update_unix(&1)
      end

    sorted = Enum.sort_by(systems, sorter, :asc)

    case sort_dir do
      :asc -> sorted
      :desc -> Enum.reverse(sorted)
    end
  end

  defp system_name(system) do
    cond do
      Map.has_key?(system, :system_name) -> to_string(system.system_name)
      Map.has_key?(system, "system_name") -> to_string(system["system_name"])
      true -> ""
    end
  end

  defp health_rank(system, services) do
    case SystemHealth.health_status(system, services) do
      :red -> 3
      :yellow -> 2
      :green -> 1
      _ -> 0
    end
  end

  defp last_update_unix(system) do
    timestamps =
      system
      |> system_results()
      |> Enum.map(fn {_command_id, cmd_data} ->
        Map.get(cmd_data, :last_known_good_time)
      end)
      |> Enum.reject(&is_nil/1)

    case timestamps do
      [] ->
        0

      _ ->
        timestamps
        |> Enum.max(DateTime)
        |> DateTime.to_unix()
    end
  end

  defp system_results(system) do
    cond do
      Map.has_key?(system, :results) and is_map(system.results) ->
        system.results

      Map.has_key?(system, "results") and is_map(system["results"]) ->
        system["results"]

      true ->
        %{}
    end
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp command_cell(assigns) do
    case get_command_data(assigns.system, assigns.command) do
      nil ->
        ~H"""
        <span class="text-gray-400">—</span>
        """

      cmd_data ->
        assigns =
          assigns
          |> assign(:cmd_data, cmd_data)
          |> assign(:result, cmd_data.result)
          |> assign(:last_good_time, Map.get(cmd_data, :last_known_good_time))
          |> assign(:check_failed, Map.get(cmd_data, :check_failed, false))
          |> assign(:is_stale, data_stale?(cmd_data))

        render_command_result(assigns)
    end
  end

  defp render_command_result(%{result: %{type: :icon, value: status}} = assigns) do
    assigns = assign(assigns, :icon_data, prepare_icon_data(status, assigns.is_stale))

    ~H"""
    <div class="relative inline-block">
      <span class={"text-2xl #{@icon_data.color}"}><%= @icon_data.icon %></span>
      <%= if @is_stale || @check_failed do %>
        <div
          class="text-xs text-gray-400 mt-1"
          title={"Last updated: #{format_timestamp(@last_good_time)}"}
        >
          <%= format_age(@last_good_time) %>
        </div>
      <% end %>
      <%= if @check_failed do %>
        <span class="absolute -top-1 -right-1 text-orange-500" title="Recent check failed">
          ⚠
        </span>
      <% end %>
    </div>
    """
  end

  defp render_command_result(%{result: %{type: :raw, display: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="relative">
      <span class={[
        "text-sm font-mono",
        @is_stale && "text-gray-500",
        !@is_stale && "text-gray-700"
      ]}>
        <%= @text %>
      </span>
      <%= if @is_stale || @check_failed do %>
        <div
          class="text-xs text-gray-400 mt-1"
          title={"Last updated: #{format_timestamp(@last_good_time)}"}
        >
          <%= format_age(@last_good_time) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_command_result(%{result: %{type: :extract, display: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="relative">
      <span class={[
        "text-xs",
        @is_stale && "text-gray-500",
        !@is_stale && "text-gray-600"
      ]}>
        <%= @text %>
      </span>
      <%= if @is_stale || @check_failed do %>
        <div
          class="text-xs text-gray-400 mt-1"
          title={"Last updated: #{format_timestamp(@last_good_time)}"}
        >
          <%= format_age(@last_good_time) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_command_result(assigns) do
    ~H"""
    <span class="text-gray-400">—</span>
    """
  end

  # Mobile version of command cell - shows result in a more readable format
  defp command_cell_mobile(assigns) do
    case get_command_data(assigns.system, assigns.command) do
      nil ->
        ~H"""
        <span class="text-sm text-gray-400">No data available</span>
        """

      cmd_data ->
        assigns =
          assigns
          |> assign(:cmd_data, cmd_data)
          |> assign(:result, cmd_data.result)
          |> assign(:last_good_time, Map.get(cmd_data, :last_known_good_time))
          |> assign(:check_failed, Map.get(cmd_data, :check_failed, false))
          |> assign(:is_stale, data_stale?(cmd_data))

        render_command_result_mobile(assigns)
    end
  end

  defp render_command_result_mobile(%{result: %{type: :icon, value: status}} = assigns) do
    assigns = assign(assigns, :icon_data, prepare_icon_data(status, assigns.is_stale))

    ~H"""
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class={"text-xl #{@icon_data.color}"}><%= @icon_data.icon %></span>
        <span class="text-sm text-gray-700 font-medium"><%= format_status(status) %></span>
      </div>
      <%= if @is_stale || @check_failed do %>
        <div class="text-xs text-gray-400">
          <%= format_age(@last_good_time) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_command_result_mobile(%{result: %{type: :raw, display: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div>
      <div class={"text-sm font-mono break-all #{if @is_stale, do: "text-gray-500", else: "text-gray-900"}"}>
        <%= @text %>
      </div>
      <%= if @is_stale || @check_failed do %>
        <div class="text-xs text-gray-400 mt-1">
          Updated: <%= format_age(@last_good_time) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_command_result_mobile(%{result: %{type: :extract, display: text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div>
      <div class={"text-sm break-all #{if @is_stale, do: "text-gray-500", else: "text-gray-700"}"}>
        <%= @text %>
      </div>
      <%= if @is_stale || @check_failed do %>
        <div class="text-xs text-gray-400 mt-1">
          Updated: <%= format_age(@last_good_time) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_command_result_mobile(assigns) do
    ~H"""
    <span class="text-sm text-gray-400">Unknown format</span>
    """
  end

  # ============================================================================
  # Helper Functions - Data Access
  # ============================================================================

  defp get_command_data(system, command) do
    get_in(system.results, [command.id])
  end

  defp data_stale?(cmd_data) do
    case Map.get(cmd_data, :last_known_good_time) do
      nil -> false
      timestamp -> DateTime.diff(DateTime.utc_now(), timestamp, :hour) > 24
    end
  end

  # ============================================================================
  # Helper Functions - Icon Rendering
  # ============================================================================

  defp prepare_icon_data(status, is_stale) do
    {icon, color} = get_icon_and_color(status, is_stale)
    %{icon: icon, color: color}
  end

  defp get_icon_and_color(:ok, stale?),
    do: {"✓", if(stale?, do: "text-green-400", else: "text-green-600")}

  defp get_icon_and_color(:warning, stale?),
    do: {"⚠", if(stale?, do: "text-yellow-400", else: "text-yellow-500")}

  defp get_icon_and_color(:error, stale?),
    do: {"✗", if(stale?, do: "text-red-400", else: "text-red-600")}

  # ============================================================================
  # Helper Functions - Formatting
  # ============================================================================

  defp format_timestamp(nil), do: "Never"

  defp format_timestamp(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_age(nil), do: ""

  defp format_age(timestamp) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)}d ago"
      diff_seconds < 31_536_000 -> "#{div(diff_seconds, 2_592_000)}mo ago"
      true -> "#{div(diff_seconds, 31_536_000)}y ago"
    end
  end

  # ============================================================================
  # Helper Functions - UI State
  # ============================================================================

  defp expanded?(expanded_systems, system_name) do
    MapSet.member?(expanded_systems, system_name)
  end

  defp time_ago(nil), do: "Never"

  defp time_ago(datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  defp status_badge_class(:green), do: "bg-green-100 text-green-800"
  defp status_badge_class(:yellow), do: "bg-yellow-100 text-yellow-800"
  defp status_badge_class(:red), do: "bg-red-100 text-red-800"

  defp status_dot_class(:green), do: "bg-green-500"
  defp status_dot_class(:yellow), do: "bg-yellow-500"
  defp status_dot_class(:red), do: "bg-red-500"

  defp status_text(:green), do: "Healthy"
  defp status_text(:yellow), do: "Warning"
  defp status_text(:red), do: "Critical"

  defp status_badge_text_color(:green), do: "text-green-700"
  defp status_badge_text_color(:yellow), do: "text-yellow-700"
  defp status_badge_text_color(:red), do: "text-red-700"

  defp format_status(:ok), do: "OK"
  defp format_status(:warning), do: "Warning"
  defp format_status(:error), do: "Error"

  defp loader_module,
    do: Application.get_env(:system_monitor, :loader_module, SystemMonitor.Config.Loader)

  defp records_module,
    do: Application.get_env(:system_monitor, :records_module, SystemMonitor.Storage.Records)
end
