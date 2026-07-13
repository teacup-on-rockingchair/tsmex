defmodule SystemMonitor.Config.Loader do
  @moduledoc """
  Loads external configuration files for systems and commands.
  """
  @behaviour SystemMonitor.Config.LoaderBehaviour
  require Logger

  def load_services_config do
    path = get_services_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok,
           %{"required_services" => required_services, "optional_services" => optional_services}} ->
            {:ok, %{required: required_services, optional: optional_services}}

          {:error, error} ->
            Logger.error("Failed to parse services config: #{inspect(error)}")
            {:error, :invalid_json}
        end

      {:error, reason} ->
        Logger.error("Failed to read services config from #{path}: #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  defp parse_systems_config(content) do
    case Jason.decode(content) do
      {:ok, %{"systems" => systems, "ip_range" => ip_range}} ->
        case parse_ip_range(ip_range) do
          [] ->
            Logger.error("Invalid IP range configuration: #{inspect(ip_range)}")
            {:error, :invalid_ip_range}

          ok_ip_range ->
            {:ok, %{systems: parse_systems(systems), ip_range: ok_ip_range}}
        end

      {:error, error} ->
        Logger.error("Failed to parse systems config: #{inspect(error)}")
        {:error, :invalid_json}
    end
  end

  def load_systems_config do
    path = get_systems_config_path()

    case File.read(path) do
      {:ok, content} ->
        parse_systems_config(content)

      {:error, reason} ->
        Logger.error("Failed to read systems config from #{path}: #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  def update_system_ip({:error, reason}, _u, _p, _ip), do: {:error, reason}

  def update_system_ip({:ok, %{systems: systems, ip_range: ip_range}}, username, password, new_ip) do
    updated_systems =
      Enum.map(systems, fn system ->
        if system.username == username and system.password == password do
          Map.put(system, :ip, new_ip)
        else
          system
        end
        |> Map.from_struct()
      end)

    updated_content =
      %{"systems" => updated_systems, "ip_range" => ip_range}
      |> Jason.encode!(pretty: true)

    {:ok, updated_content}
  end

  def save_systems_config({:error, reason}), do: {:error, reason}

  def save_systems_config({:ok, updated_config}) do
    path = get_systems_config_path()

    case File.write(path, updated_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to write updated systems config to #{path}: #{inspect(reason)}")
        {:error, :write_failed}
    end
  end

  def set_new_ip(username, password, new_ip) do
    load_systems_config()
    |> update_system_ip(username, password, new_ip)
    |> save_systems_config()
  end

  def load_commands_config do
    path = get_commands_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"commands" => commands} = decoded} ->
            parsed_commands = parse_commands(commands)

            noise_patterns =
              decoded
              |> Map.get("output_sanitization", %{})
              |> Map.get("noise_patterns", [])
              |> normalize_noise_patterns()

            {:ok, %{commands: parsed_commands, noise_patterns: noise_patterns}}

          {:ok, _other} ->
            Logger.error("Invalid commands config shape: missing 'commands' key")
            {:error, :invalid_commands_config}

          {:error, error} ->
            Logger.error("Failed to parse commands config: #{inspect(error)}")
            {:error, :invalid_json}
        end

      {:error, reason} ->
        Logger.error("Failed to read commands config from #{path}:  #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  defp normalize_noise_patterns(patterns) when is_list(patterns) do
    Enum.filter(patterns, &is_binary/1)
  end

  defp normalize_noise_patterns(_), do: []

  defp get_services_config_path do
    System.get_env("SERVICES_CONFIG_PATH") ||
      Path.expand("~/.system_monitor/services.json")
  end

  defp get_systems_config_path do
    System.get_env("SYSTEMS_CONFIG_PATH") ||
      Path.expand("~/.system_monitor/systems.json")
  end

  defp get_commands_config_path do
    System.get_env("COMMANDS_CONFIG_PATH") ||
      Path.expand("~/.system_monitor/commands.json")
  end

  defp parse_systems(systems) do
    systems
    |> Enum.filter(fn system -> Map.get(system, "enabled", true) end)
    |> Enum.map(&SystemMonitor.Config.Systems.from_map/1)
  end

  defp parse_ip_range(ip_range) do
    ip_range
    |> parse_ip_range_length()
    |> parse_ip_range_values()
  end

  defp parse_ip_range_length(ip_range) do
    if ip_range == nil or length(ip_range) != 2 do
      Logger.error("Invalid IP range configuration: #{inspect(ip_range)}")
      []
    else
      ip_range
    end
  end

  defp parse_ip_range_values(ip_range) when ip_range == nil, do: []
  defp parse_ip_range_values(ip_range) when not is_list(ip_range), do: []
  defp parse_ip_range_values(ip_range) when ip_range == [], do: []
  defp parse_ip_range_values(ip_range) when length(ip_range) != 2, do: []

  defp parse_ip_range_values(ip_range) do
    Enum.map(ip_range, fn ip ->
      case :inet.parse_address(to_charlist(ip)) do
        {:ok, _} ->
          ip

        {:error, _} ->
          Logger.error("Invalid IP address in range: #{ip}")
          nil
      end
    end)
    # Remove nil values
    |> Enum.filter(& &1)
    |> parse_ip_range_values_compare(ip_range)
  end

  defp parse_ip_range_values_compare(nil, _original_ips), do: []
  defp parse_ip_range_values_compare([], _original_ips), do: []
  defp parse_ip_range_values_compare([_one_ip], _original_ips), do: []

  defp parse_ip_range_values_compare([start_ip, end_ip], original_ips) do
    case start_ip > end_ip do
      true ->
        Logger.error(
          "Start IP must be less than or equal to End IP in range: #{inspect(original_ips)}"
        )

        []

      false ->
        original_ips
    end
  end

  defp parse_commands(commands) do
    commands
    |> Enum.filter(fn cmd -> Map.get(cmd, "enabled", true) end)
    |> Enum.sort_by(fn cmd -> Map.get(cmd, "order", 999) end)
    |> Enum.map(&SystemMonitor.Config.Commands.from_map/1)
  end
end
