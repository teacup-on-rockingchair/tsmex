defmodule SystemMonitor.Config.Loader do
  @moduledoc """
  Loads external configuration files for systems and commands.
  """

  require Logger

  def load_services_config do
    path = get_services_config_path()
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"required_services" => required_services,
                 "optional_services" => optional_services}} ->
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

  def load_systems_config do
    path = get_systems_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"systems" => systems}} ->
            {:ok, parse_systems(systems)}

          {:error, error} ->
            Logger.error("Failed to parse systems config: #{inspect(error)}")
            {:error, :invalid_json}
        end

      {:error, reason} ->
        Logger.error("Failed to read systems config from #{path}: #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  def load_commands_config do
    path = get_commands_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"commands" => commands}} ->
            {:ok, parse_commands(commands)}

          {:error, error} ->
            Logger.error("Failed to parse commands config: #{inspect(error)}")
            {:error, :invalid_json}
        end
      {:error, reason} ->
        Logger.error("Failed to read commands config from #{path}:  #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  defp get_services_config_path do
    System.get_env("SERVICES_CONFIG_PATH") ||
      Path.expand("~/.system_monitor/services.json")
  end

  defp get_systems_config_path do
    System. get_env("SYSTEMS_CONFIG_PATH") ||
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

  defp parse_commands(commands) do
    commands
    |> Enum.filter(fn cmd -> Map.get(cmd, "enabled", true) end)
    |> Enum.sort_by(fn cmd -> Map.get(cmd, "order", 999) end)
    |> Enum.map(&SystemMonitor.Config.Commands.from_map/1)
  end
end
