defmodule SystemMonitorWeb.SystemDetailLive do
  use SystemMonitorWeb, :live_view
  require Logger

  alias SystemMonitor.Storage.Records

  def mount(%{"system_name" => system_name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "system_updates")
    end

    socket =
      socket
      |> assign(:system_name, system_name)
      |> assign(:loading, false)
      |> load_history()
      |> assign(:expanded_checks, MapSet.new())

    {:ok, socket}
  end

  # Handle system updates
  def handle_info({:system_updated, updated_system_name, timestamp}, socket) do
    if socket.assigns.system_name == updated_system_name do
      socket = load_history(socket)

      {:noreply,
       socket
       # Clear loading state
       |> assign(:loading, false)
       |> put_flash(:info, "Updated at #{Calendar.strftime(timestamp, "%H:%M:%S")}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:system_check_failed, failed_system_name, timestamp}, socket) do
    if socket.assigns.system_name == failed_system_name do
      {:noreply,
       socket
       |> assign(:loading, false)
       |> put_flash(:error, "Health check failed at #{Calendar.strftime(timestamp, "%H:%M:%S")}")}
    else
      {:noreply, socket}
    end
  end

  # Toggle expanded/collapsed state for a check
  def handle_event("toggle_check", %{"timestamp" => timestamp_str}, socket) do
    expanded = socket.assigns.expanded_checks

    new_expanded =
      if MapSet.member?(expanded, timestamp_str) do
        MapSet.delete(expanded, timestamp_str)
      else
        MapSet.put(expanded, timestamp_str)
      end

    {:noreply, assign(socket, :expanded_checks, new_expanded)}
  end

  def handle_event("copy_to_clipboard", %{"text" => text_str}, socket) do
     {:noreply,
       socket
       |> assign(:loading, false)
       |>put_flash(:info, "About to copy #{text_str}")}
#    {:noreply, socket}
  end

  # Manual refresh (trigger new health check)
  def handle_event("refresh", _params, socket) do
    system_name = socket.assigns.system_name
    # This would trigger an immediate health check if implemented
    {:noreply, put_flash(socket, :info, "Refresh requested for #{socket.assigns.system_name}")}
    Logger.info("🔄 Triggering immediate health check for #{system_name}")

    # Option A: Broadcast refresh request via PubSub
    Phoenix.PubSub.broadcast(
      SystemMonitor.PubSub,
      "worker_commands",
      {:trigger_check, system_name}
    )

    {:noreply,
     socket
     # Show loading state
     |> assign(:loading, true)
     # Reload current data
     |> put_flash(:info, "Health check triggered for #{system_name}")}
  end

  # NEW: Download full history as JSON
  def handle_event("download_history", _params, socket) do
    system_name = socket.assigns.system_name
    history = socket.assigns.history

    # Prepare data for JSON export
    export_data = %{
      system_name: system_name,
      exported_at: DateTime.utc_now(),
      total_checks: length(history),
      checks:
        Enum.map(history, fn record ->
          %{
            timestamp: record.timestamp,
            results:
              Enum.map(record.results, fn {cmd_id, result} ->
                %{
                  command_id: cmd_id,
                  description: result.description,
                  command: result.command,
                  result: result.result,
                  executed_at: result.executed_at
                }
              end)
          }
        end)
    }

    # Encode to pretty JSON
    json_content = Jason.encode!(export_data, pretty: true)

    # Generate filename with timestamp
    filename = "#{system_name}_history_#{DateTime.utc_now() |> DateTime.to_unix()}.json"

    Logger.info(
      "Prepared history export for #{system_name} with #{length(history)} checks with filename #{filename}"
    )

    # Push download event to client
    {:noreply,
     socket
     |> push_event("download_file", %{
       filename: filename,
       content: json_content
     })
     |> put_flash(:info, "Downloaded history for #{system_name}")}
  end

  # NEW: Download single check as JSON
  def handle_event("download_check", %{"timestamp" => timestamp_str}, socket) do
    system_name = socket.assigns.system_name

    # Find the specific check
    check =
      Enum.find(socket.assigns.history, fn record ->
        DateTime.to_iso8601(record.timestamp) == timestamp_str
      end)

    case check do
      nil ->
        {:noreply, put_flash(socket, :error, "Check not found")}

      record ->
        export_data = %{
          system_name: system_name,
          timestamp: record.timestamp,
          results:
            Enum.map(record.results, fn {cmd_id, result} ->
              %{
                command_id: cmd_id,
                description: result.description,
                command: result.command,
                result: result.result,
                executed_at: result.executed_at
              }
            end)
        }

        json_content = Jason.encode!(export_data, pretty: true)

        timestamp_safe = String.replace(timestamp_str, ":", "-")
        filename = "#{system_name}_check_#{timestamp_safe}.json"

        {:noreply,
         socket
         |> push_event("phx:download_file", %{
           filename: filename,
           content: json_content
         })
         |> put_flash(:info, "Downloaded single check")}
    end
  end

  # Load historical data
  defp load_history(socket) do
    system_name = socket.assigns.system_name
    history = Records.get_all(system_name)

    # Auto-expand the most recent check (optional)
    expanded_checks =
      case history do
        [latest | _] ->
          MapSet.new([DateTime.to_iso8601(latest.timestamp)])

        [] ->
          MapSet.new()
      end

    assign(socket,
      history: history,
      timestamp: get_most_recent_time(history),
      expanded_checks: expanded_checks
    )
  end

  defp get_most_recent_time([]), do: nil
  defp get_most_recent_time([latest | _]), do: latest.timestamp

  # Check if a timestamp section is expanded
  defp is_check_expanded?(expanded_checks, timestamp) do
    timestamp_str = DateTime.to_iso8601(timestamp)
    MapSet.member?(expanded_checks, timestamp_str)
  end

  # Helper functions for rendering

  defp render_status_badge(%{type: :icon, value: status}) do
    {icon, color_class} =
      case status do
        :ok -> {"✓", "bg-green-100 text-green-800"}
        :warning -> {"⚠", "bg-yellow-100 text-yellow-800"}
        :error -> {"✗", "bg-red-100 text-red-800"}
        _ -> {"?", "bg-gray-100 text-gray-800"}
      end

    assigns = %{icon: icon, color_class: color_class}

    ~H"""
    <span class={"px-2 py-1 rounded text-sm #{@color_class}"}><%= @icon %></span>
    """
  end

  defp render_status_badge(%{result: %{type: :icon, value: status}}) do
    assigns = %{status: status}

    ~H"""
    <%= case @status do %>
      <% :ok -> %>
        <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-green-100 text-green-800">
          ✓ OK
        </span>
      <% :warning -> %>
        <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">
          ⚠ Warning
        </span>
      <% :error -> %>
        <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-red-100 text-red-800">
          ✗ Error
        </span>
      <% _ -> %>
        <span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
          ? Unknown
        </span>
    <% end %>
    """
  end

  defp render_status_badge(_), do: nil


  defp render_result_content(%{result: result, format: _format} = _result_data) do
    case result do
      %{type: :raw, display: display} ->
        render_scrollable_text(display)

      %{type: :extract, display: _display} ->
        render_scrollable_text(result.raw_output)

      %{type: :icon, value: _status} ->
        render_scrollable_text(result.raw_output)

      text when is_binary(text) ->
        render_scrollable_text(text)

      _ ->
        render_scrollable_text(inspect(result))
    end
  end

  defp render_scrollable_text(text) do
    assigns = %{text: text}

    ~H"""
    <div class="relative">
      <!-- Scrollable container with both horizontal and vertical scroll -->
      <div class="overflow-auto max-h-64 rounded border border-gray-300 bg-gray-50">
        <pre class="p-3 text-xs sm:text-sm font-mono text-gray-800 whitespace-pre"><%= @text %></pre>
      </div>
      <!-- Scroll hint for mobile -->
      <div class="mt-2 flex items-center justify-between text-xs text-gray-500">
        <span class="flex items-center">
          <.icon name="hero-arrows-pointing-out" class="h-3 w-3 mr-1" /> Scroll to see more
        </span>
        <button
          phx-click={JS.dispatch("phx:copy")}
          class="flex items-center text-blue-600 hover:text-blue-800"
        >
          <.icon name="hero-clipboard" class="h-3 w-3 mr-1" /> Copy
        </button>
      </div>
    </div>
    """
  end

  defp time_ago(nil), do: "Never"

  defp time_ago(timestamp) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end

  defp format_timestamp(nil), do: "Never"

  defp format_timestamp(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

end
