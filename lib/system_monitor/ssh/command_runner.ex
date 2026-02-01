defmodule SystemMonitor.SSH.CommandRunner do
  @moduledoc """
  Executes commands on remote systems via SSH.
  """

  require Logger
  alias SystemMonitor.SSH.Client
  alias SystemMonitor.SSH.ConnectionPool

  def execute(system, command, timeout \\ 10_000) do
    # Acquire connection slot
    case ConnectionPool.acquire() do
      :ok ->
        try do
          do_execute(system, command, timeout)
        after
          ConnectionPool.release()
        end

      :retry ->
        Process.sleep(100)
        execute(system, command, timeout)
    end
  end

  def do_execute(system, command, timeout \\ 10_000) do
    Logger.debug("=== Executing command on #{system.name} ===")
    Logger.debug("Original command: #{command}")
    Logger.debug("System has sudo_password: #{!is_nil(Map.get(system, :sudo_password))}")

    case Client.connect(system) do
      {:ok, conn} ->
        try do
          Logger.debug("Connected successfully to #{system.name}")

          # Wrap command to run as root
          final_command = wrap_with_sudo(system, command)
          Logger.debug("Final command: #{final_command}")

          sudo_password = Map.get(system, :sudo_password)
          Logger.debug("Passing sudo_password: #{!is_nil(sudo_password)}")

          result = Client.execute(conn, final_command, timeout, sudo_password)
          Client.disconnect(conn)

          case result do
            {:ok, output} ->
              Logger.debug("Command succeeded, output length: #{String.length(output)}")
              Logger.debug("Raw output: #{inspect(output)}")
              cleaned = clean_sudo_output(output)
              Logger.debug("Cleaned output: #{inspect(cleaned)}")
              cleaned

            {:error, reason} ->
              Logger.error("Command failed: #{inspect(reason)}")
              "Error: #{inspect(reason)}"
          end
        after
          # ALWAYS disconnect, even on error
          Client.disconnect(conn)
          Logger.debug("Connection closed for #{system.name}")
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

  defp clean_sudo_output(output) do
    output
    |> String.replace(~r/^.*Read-only file system.*/m, "")
    |> String.replace(~r/^.*Failed to start Daily apt download activities\..*/m, "")
    |> String.replace(~r/^.*Failed to start Daily apt upgrade and clean activities..*/m, "")
    |> String.replace(~r/\A.*\[sudo\] password for [^:]+:\s*/ms, "")
    |> String.trim()
  end
end
