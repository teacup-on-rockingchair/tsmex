defmodule SystemMonitorWeb.SystemDetailLive do
  use SystemMonitorWeb, :live_view
  alias SystemMonitor.Storage.Records
  alias SystemMonitor.Config.Loader

  def mount(%{"system_name" => system_name}, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh)
    end

    {:ok, commands} = Loader.load_commands_config()

    {:ok,
     socket
     |> assign(system_name: system_name)
     |> assign(commands:  commands)
     |> assign(current_state: load_current_state(system_name))
     |> assign(records: load_records(system_name))}
  end

  def handle_info(:refresh, socket) do
    {:noreply, 
     socket
     |> assign(current_state: load_current_state(socket.assigns.system_name))
     |> assign(records:  load_records(socket.assigns. system_name))}
  end

  def handle_event("download", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    record = Enum.at(socket.assigns. records, index)

    if record do
      json = Jason.encode!(record, pretty: true)

      {:noreply,
       socket
       |> push_event("download_file", %{
         filename: "#{socket.assigns.system_name}_#{format_filename(record.timestamp)}.json",
         content: json
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("download_all", _params, socket) do
    json = Jason.encode!(socket.assigns.records, pretty: true)

    {:noreply,
     socket
     |> push_event("download_file", %{
       filename: "#{socket.assigns.system_name}_all_records.json",
       content: json
     })}
  end

  defp load_current_state(system_name) do
    Records.get_system_state(system_name)
  end

  defp load_records(system_name) do
    Records.get_all(system_name)
  end

  def render(assigns) do
    ~H"""
    <div class="p-8">
      <div class="mb-6 flex items-center justify-between">
        <div>
          <.link navigate={~p"/"} class="text-blue-600 hover:text-blue-800 text-sm mb-2 inline-block">
            ← Back to Dashboard
          </.link>
          <h1 class="text-3xl font-bold text-gray-800">
            System:  <%= @system_name %>
          </h1>
        </div>
        <%= if ! Enum.empty?(@records) do %>
          <button
            phx-click="download_all"
            class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg transition-colors"
          >
            Download All Records
          </button>
        <% end %>
      </div>

      <%!-- Current State Summary --%>
      <%= if @current_state do %>
        <div class="mb-6 bg-blue-50 border border-blue-200 rounded-lg p-4">
          <h2 class="text-lg font-semibold text-blue-900 mb-2">Current State</h2>
          <p class="text-sm text-blue-700">
            Last checked: <%= format_timestamp(@current_state.last_check_time) %>
          </p>
          <p class="text-xs text-blue-600 mt-1">
            This shows the last known good state for each metric.  Individual metrics may be from different check times.
          </p>
        </div>
      <% end %>

      <%!-- Historical Records --%>
      <%= if Enum.empty?(@records) do %>
        <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6">
          <p class="text-yellow-800">No health check records available for this system yet.</p>
        </div>
      <% else %>
        <div class="space-y-4">
          <%= for {record, index} <- Enum.with_index(@records) do %>
            <div class="bg-white border border-gray-200 rounded-lg shadow-sm p-6">
              <div class="flex justify-between items-start mb-4">
                <div>
                  <h3 class="text-lg font-semibold text-gray-800">
                    Check #<%= index + 1 %>
                  </h3>
                  <p class="text-sm text-gray-600">
                    <%= format_timestamp(record.timestamp) %>
                  </p>
                </div>
                <button
                  phx-click="download"
                  phx-value-index={index}
                  class="text-blue-600 hover:text-blue-800 text-sm"
                >
                  Download JSON
                </button>
              </div>

              <div class="grid grid-cols-1 md: grid-cols-2 lg:grid-cols-3 gap-4">
                <%= for cmd <- @commands do %>
                  <% cmd_result = get_in(record.results, [cmd.id]) %>
                  <%= if cmd_result do %>
                    <div class="border border-gray-200 rounded p-3">
                      <div class="flex items-center justify-between mb-2">
                        <h4 class="font-medium text-gray-700 text-sm"><%= cmd.description %></h4>
                        <%= render_status_badge(cmd_result. result) %>
                      </div>
                      <%= if Map.get(cmd_result, :last_known_good_time) && 
                             cmd_result.last_known_good_time != cmd_result.executed_at do %>
                        <div class="text-xs text-orange-600 mb-2">
                          ⚠ Using state from:  <%= format_timestamp(cmd_result.last_known_good_time) %>
                        </div>
                      <% end %>
                      <div class="mt-2">
                        <%= render_command_output(cmd_result. result) %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>

    <script>
      window.addEventListener("phx:download_file", (e) => {
        const { filename, content } = e.detail;
        const blob = new Blob([content], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      });
    </script>
    """
  end

  defp render_status_badge(%{type: :icon, value: status}) do
    {icon, color_class} =
      case status do
        :ok -> {"✓", "bg-green-100 text-green-800"}
        :warning -> {"⚠", "bg-yellow-100 text-yellow-800"}
        :error -> {"✗", "bg-red-100 text-red-800"}
      end

    assigns = %{icon: icon, color_class: color_class}

    ~H"""
    <span class={"px-2 py-1 rounded text-sm #{@color_class}"}><%= @icon %></span>
    """
  end

  defp render_status_badge(_), do: nil

  defp render_command_output(%{type: :raw, display:  text}) do
    assigns = %{text: text}

    ~H"""
    <pre class="text-xs bg-gray-50 p-2 rounded overflow-x-auto"><%= @text %></pre>
    """
  end

  defp render_command_output(%{type:  :extract, display: text, raw_output: raw}) do
    assigns = %{text: text, raw:  raw}

    ~H"""
    <div>
      <p class="text-sm text-gray-700"><%= @text %></p>
      <details class="mt-2">
        <summary class="text-xs text-blue-600 cursor-pointer">Show full output</summary>
        <pre class="text-xs bg-gray-50 p-2 rounded overflow-x-auto mt-2"><%= @raw %></pre>
      </details>
    </div>
    """
  end

  defp render_command_output(%{type: :icon, raw_output: raw}) do
    assigns = %{raw: raw}

    ~H"""
    <details>
      <summary class="text-xs text-blue-600 cursor-pointer">Show output</summary>
      <pre class="text-xs bg-gray-50 p-2 rounded overflow-x-auto mt-2"><%= @raw %></pre>
    </details>
    """
  end

  defp format_timestamp(nil), do: "Never"
  defp format_timestamp(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_filename(timestamp) do
    Calendar.strftime(timestamp, "%Y%m%d_%H%M%S")
  end
end
