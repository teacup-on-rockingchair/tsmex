defmodule SystemMonitorWeb.DashboardLive.SystemHealth do
  @moduledoc """
  Determines system health status based on monitoring data.
  """

  @doc """
  Returns the health status color class for a system.
  Returns: :green, :yellow, or :red
  """
  require Logger

  def health_status(system_data) do
    cond do
      is_critically_stale?(system_data) -> :red
      is_healthy?(system_data) -> :green
      #      true -> :green
      true -> :yellow
    end
  end

  @doc """
  Returns CSS classes for the health status
  """
  def health_color_class(:green), do: "bg-green-100 hover:bg-green-200"
  def health_color_class(:red), do: "bg-red-100 hover:bg-red-200"
  def health_color_class(:yellow), do: "bg-yellow-100 hover:bg-yellow-200"

  # Red: Last check more than 4 hours ago
  defp is_critically_stale?(system_data) do
    case get_last_check_time(system_data) do
      nil ->
        true

      timestamp ->
        hours_ago = DateTime.diff(DateTime.utc_now(), timestamp, :hour)
        hours_ago > 4
    end
  end

  # Green: All conditions met
  defp is_healthy?(system_data) do
    within_two_hours?(system_data) and
      all_services_healthy?(system_data) and
      network_healthy?(system_data)
  end

  # Check if last successful check was within 2 hours
  defp within_two_hours?(system_data) do
    case get_last_check_time(system_data) do
      nil ->
        false

      timestamp ->
        hours_ago = DateTime.diff(DateTime.utc_now(), timestamp, :hour)
        Logger.debug("System #{system_data.system_name} last updated #{hours_ago} hours ago")
        hours_ago <= 2
    end
  end

  # Check if lis1, lis2, pixcell, rc-local show no errors
  defp all_services_healthy?(system_data) do
    required_services = ["lis1_status", "rc_local_status"]

    required_result =
      Enum.all?(required_services, fn service_key ->
        get_command_result(system_data, service_key)
        #        |> tap(&Logger.info("Service #{service_key} status for #{system_data.system_name} is #{inspect(&1)}"))
        |> case do
          nil -> false
          result -> not has_error?(result)
        end
      end)

    optional_services = ["lis2_status", "pixcell_status"]

    optional_result =
      Enum.any?(optional_services, fn service_key ->
        get_command_result(system_data, service_key)
        |> tap(
          &Logger.info(
            "Optional Service #{service_key} status for #{system_data.system_name} is #{inspect(&1)}"
          )
        )
        |> case do
          nil ->
            false

          result ->
            Logger.info(
              "Optional Service #{service_key} result for #{system_data.system_name} is #{inspect(result)} and that is #{not has_error?(result)}"
            )

            not has_error?(result)
        end
      end)

    Logger.info(
      "System #{system_data.system_name} required services healthy: #{required_result}, optional services healthy: #{optional_result}"
    )

    required_result and optional_result
  end

  # Check if analyzer_network contains UP,LOWER_UP and not NO CARRIER
  defp network_healthy?(system_data) do
    get_command_output(system_data, "analyzer_network")
    |> tap(&Logger.info("Network status for #{system_data.system_name} is #{inspect(&1)}"))
    |> case do
      nil ->
        false

      result ->
        String.contains?(result, "UP") and
          String.contains?(result, "LOWER_UP") and
          not String.contains?(result, "NO CARRIER")
    end
  end

  # Helper: Get last check timestamp
  defp get_last_check_time(system_data) do
    system_data
    |> Map.get(:results, %{})
    |> Enum.map(fn {_key, data} -> Map.get(data, :executed_at) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # Helper: Get command result by key
  defp get_command_result(system_data, command_key) do
    system_data
    |> Map.get(:results, %{})
    |> Map.get(command_key)
    |> case do
      nil -> nil
      data -> Map.get(data, :result)
    end
  end

  # Helper: Get command ouptut by key
  defp get_command_output(system_data, command_key) do
    get_command_result(system_data, command_key)
    |> case do
      nil -> nil
      data when is_map_key(data, :raw_output) -> data[:raw_output]
      data when is_binary(data) -> data
      _ -> nil
    end
  end

  # Helper: Check if result contains error indicators

  defp has_error?(result) when is_map_key(result, :raw_output) do
    String.contains?(result[:raw_output], [
      "Error",
      "error",
      "failed",
      "Failed",
      "Connection failed"
    ])
  end

  defp has_error?(result) when is_binary(result) do
    String.contains?(result, ["Error", "error", "failed", "Failed", "Connection failed"])
  end

  defp has_error?(_) do
    true
  end
end
