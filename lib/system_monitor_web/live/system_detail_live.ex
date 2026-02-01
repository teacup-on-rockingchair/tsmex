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
