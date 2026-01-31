defmodule SystemMonitorWeb.DashboardLive do
  use SystemMonitorWeb, :live_view

  alias SystemMonitor.Storage.Records
  alias SystemMonitor.Config.Loader
  alias SystemMonitorWeb.DashboardLive.SystemHealth
  require Logger
  @refresh_interval 5_000

  # ============================================================================
  # LiveView Callbacks
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "system_updates")
      Logger.info("Starting refresh timer")
    else
      Logger.info("Not connected, skipping timer")
    end

    case Loader.load_commands_config() do
      {:ok, commands} ->
        {:ok,
         socket
         |> assign(systems: load_systems())
         |> assign(commands: commands)
         # Track expanded/collapsed state
         |> assign(expanded_systems: MapSet.new())}

      {:error, _} ->
        {:ok,
         socket
         |> assign(systems: [])
         |> assign(commands: [])
         # Track expanded/collapsed state
         |> assign(expanded_systems: MapSet.new())
         |> put_flash(:error, "Failed to load commands configuration")}
    end
  end

  def handle_info({:system_updated, _system_name, _timestamp}, socket) do
    {:noreply, assign(socket, systems: load_systems())}
  end

  def handle_info({:system_check_failed, _system_name, _timestamp}, socket) do
    {:noreply, assign(socket, systems: load_systems())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    try do
      Logger.info("Refresh triggered!")

      socket =
        socket
        |> assign(systems: load_systems())
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

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp load_initial_data(socket) do
    case Loader.load_commands_config() do
      {:ok, commands} ->
        socket
        |> assign(systems: load_systems())
        |> assign(commands: commands)

      {:error, _reason} ->
        socket
        |> assign(systems: [])
        |> assign(commands: [])
        |> put_flash(:error, "Failed to load commands configuration")
    end
  end

  defp load_systems do
    Records.get_latest_for_all_systems()
  end

  defp assign_last_update(socket) do
    assign(socket, last_update: DateTime.utc_now())
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
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
          |> assign(:is_stale, is_data_stale?(cmd_data))

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
          |> assign(:is_stale, is_data_stale?(cmd_data))

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

  defp is_data_stale?(cmd_data) do
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
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86400)}d ago"
      diff_seconds < 31_536_000 -> "#{div(diff_seconds, 2_592_000)}mo ago"
      true -> "#{div(diff_seconds, 31_536_000)}y ago"
    end
  end

  defp time_ago_class(timestamp) do
    minutes_ago = DateTime.diff(DateTime.utc_now(), timestamp, :minute)

    cond do
      minutes_ago < 5 -> "text-green-600"
      minutes_ago < 15 -> "text-gray-600"
      minutes_ago < 60 -> "text-yellow-600"
      true -> "text-red-600"
    end
  end

  # ============================================================================
  # Helper Functions - UI State
  # ============================================================================

  defp is_expanded?(expanded_systems, system_name) do
    MapSet.member?(expanded_systems, system_name)
  end

  defp time_ago(nil), do: "Never"

  defp time_ago(datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
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
end
