defmodule SystemMonitor.SSH.CommandRunner do
  @moduledoc """
  Executes commands on remote systems via SSH.
  """

  require Logger
  alias SystemMonitor.SSH.Client

  def execute(system, command, timeout \\ 10_000) do
    Logger.info("=== Executing command on #{system.name} ===")
    Logger.info("Original command: #{command}")
    Logger.info("System has sudo_password: #{!is_nil(Map.get(system, :sudo_password))}")

    case Client.connect(system) do
      {:ok, conn} ->
        Logger.info("Connected successfully to #{system.name}")

        # Wrap command to run as root
        final_command = wrap_with_sudo(system, command)
        Logger.info("Final command: #{final_command}")

        sudo_password = Map.get(system, :sudo_password)
        Logger.info("Passing sudo_password: #{!is_nil(sudo_password)}")

        result = Client.execute(conn, final_command, timeout, sudo_password)
        Client.disconnect(conn)

        case result do
          {:ok, output} ->
            Logger.info("Command succeeded, output length: #{String.length(output)}")
            Logger.debug("Raw output: #{inspect(output)}")
            cleaned = clean_sudo_output(output)
            Logger.debug("Cleaned output: #{inspect(cleaned)}")
            cleaned

          {:error, reason} ->
            Logger.error("Command failed: #{inspect(reason)}")
            "Error: #{inspect(reason)}"
        end

      {:error, reason} ->
        Logger.error("Failed to connect to #{system.name}: #{inspect(reason)}")
        "Connection failed:  #{inspect(reason)}"
    end
  end

  defp wrap_with_sudo(system, command) do
    result =
      cond do
        Map.get(system, :sudo_password) ->
          "sudo -S -i bash -c '#{escape_command(command)}'"

        true ->
          command
      end

    Logger.debug("wrap_with_sudo result: #{result}")
    result
  end

  defp escape_command(command) do
    String.replace(command, "'", "'\\''")
  end

  defp prepare_command(system, command) do
    sudo_password = Map.get(system, :sudo_password)

    cond do
      # No sudo password configured - run command as-is
      is_nil(sudo_password) ->
        {command, nil}

      # Command already has sudo - keep as-is but provide password
      String.starts_with?(command, "sudo") ->
        {command, sudo_password}

      # Add sudo -S and provide password
      true ->
        {"sudo -S #{command}", sudo_password}
    end
  end
  
  defp clean_sudo_output(output) do
    output
    |> String.replace(~r/^.*Read-only file system.*/m, "")
    |> String.replace(~r/^.*Failed to start Daily apt download activities\..*/m, "")
    |> String.replace(~r/^.*Failed to start Daily apt upgrade and clean activities..*/m, "")
    |> String.replace(~r/\A.*\[sudo\] password for [^:]+:\s*/ms, "")
    |> String.trim()
  end
end
