defmodule SystemMonitorWeb.DashboardLive do
  use SystemMonitorWeb, :live_view
  alias SystemMonitor.Storage.Records
  alias SystemMonitor.Config. Loader

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh)
    end

    case Loader.load_commands_config() do
      {:ok, commands} ->
        {:ok,
         socket
         |> assign(systems: load_systems())
         |> assign(commands:  commands)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(systems: [])
         |> assign(commands: [])
         |> put_flash(:error, "Failed to load commands configuration")}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, systems: load_systems())}
  end

  defp load_systems do
    Records.get_latest_for_all_systems()
  end

  def render(assigns) do
    ~H"""
    <div class="p-8">
      <div class="mb-6">
        <h1 class="text-3xl font-bold text-gray-800">System Monitor Dashboard</h1>
        <p class="text-sm text-gray-600 mt-2">
          Showing last known state for each metric.  Data may be from previous checks if recent checks failed.
        </p>
      </div>

      <%= if Enum.empty? (@systems) do %>
        <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6 text-center">
          <p class="text-yellow-800 font-medium">No systems data available yet</p>
          <p class="text-yellow-600 text-sm mt-2">
            Health checks will appear here once executed.  Checks run every 10-1800 seconds.
          </p>
          <%= if Enum.empty?(@commands) do %>
            <p class="text-red-600 text-sm mt-4">
              ⚠️ Commands configuration not loaded.  Check your COMMANDS_CONFIG_PATH. 
            </p>
          <% end %>
        </div>
      <% else %>
        <div class="overflow-x-auto shadow-md rounded-lg">
          <table class="min-w-full bg-white border border-gray-200">
            <thead class="bg-gray-100">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 uppercase border-b">
                  System
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-700 uppercase border-b">
                  Last Check
                </th>
                <%= for cmd <- @commands do %>
                  <th
                    class="px-4 py-3 text-center text-xs font-medium text-gray-700 uppercase border-b"
                    title={cmd.command}
                  >
                    <%= cmd.description %>
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <%= for system <- @systems do %>
                <tr class="hover:bg-gray-50 transition-colors">
                  <td class="px-4 py-3 border-b">
                    <.link
                      navigate={~p"/systems/#{system.system_name}"}
                      class="text-blue-600 hover:text-blue-800 hover:underline font-medium"
                    >
                      <%= system.system_name %>
                    </.link>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 border-b">
                    <%= format_timestamp(system.last_check_time) %>
                  </td>
                  <%= for cmd <- @commands do %>
                    <td class="px-4 py-3 text-center border-b">
                      <%= render_cell_content(system, cmd) %>
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <div class="mt-4 text-xs text-gray-500">
          <p>💡 Tip: Click on a system name to see detailed history and timestamps for each metric.</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_cell_content(system, cmd) do
    case get_in(system.results, [cmd.id]) do
      nil ->
        assigns = %{}
        ~H"""
        <span class="text-gray-400">—</span>
        """

      cmd_data ->
        result = cmd_data.result
        last_good_time = Map.get(cmd_data, :last_known_good_time)
        last_check_time = Map.get(cmd_data, :last_check_time)
        check_failed = Map.get(cmd_data, :check_failed, false)

        # Check if data is stale (more than 24 hours old)
        is_stale = last_good_time && 
                   DateTime.diff(DateTime.utc_now(), last_good_time, :hour) > 24

        case result do
          %{type: :icon, value: status} ->
            status_icon_with_age(status, last_good_time, is_stale, check_failed)

          %{type: :raw, display: text} ->
            assigns = %{text: text, is_stale: is_stale, check_failed: check_failed, 
                       last_good_time: last_good_time}
            ~H"""
            <div class="relative">
              <span class={[
                "text-sm font-mono",
                @is_stale && "text-gray-500",
                ! @is_stale && "text-gray-700"
              ]}>
                <%= @text %>
              </span>
              <%= if @is_stale || @check_failed do %>
                <div class="text-xs text-gray-400 mt-1" title={"Last updated: #{format_timestamp(@last_good_time)}"}>
                  <%= format_age(@last_good_time) %>
                </div>
              <% end %>
            </div>
            """

          %{type: :extract, display: text} ->
            assigns = %{text: text, is_stale: is_stale, check_failed: check_failed,
                       last_good_time: last_good_time}
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
                <div class="text-xs text-gray-400 mt-1" title={"Last updated: #{format_timestamp(@last_good_time)}"}>
                  <%= format_age(@last_good_time) %>
                </div>
              <% end %>
            </div>
            """

          _ ->
            assigns = %{}
            ~H"""
            <span class="text-gray-400">—</span>
            """
        end
    end
  end

  defp status_icon_with_age(status, last_good_time, is_stale, check_failed) do
    {icon, color} =
      case status do
        :ok -> {"✓", if(is_stale, do: "text-green-400", else: "text-green-600")}
        :warning -> {"⚠", if(is_stale, do: "text-yellow-400", else: "text-yellow-500")}
        :error -> {"✗", if(is_stale, do: "text-red-400", else: "text-red-600")}
      end

    assigns = %{
      icon: icon, 
      color: color, 
      is_stale: is_stale,
      check_failed: check_failed,
      last_good_time: last_good_time
    }

    ~H"""
    <div class="relative inline-block">
      <span class={"text-2xl #{@color}"}><%= @icon %></span>
      <%= if @is_stale || @check_failed do %>
        <div class="text-xs text-gray-400 mt-1" title={"Last updated: #{format_timestamp(@last_good_time)}"}>
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
end
