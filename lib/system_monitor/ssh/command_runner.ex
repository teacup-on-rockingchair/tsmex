defmodule SystemMonitor.SSH.CommandRunner do
  @moduledoc """
  Executes monitor commands over SSH.
  Supports both legacy single-command execution and batch execution.
  """

  @behaviour SystemMonitor.SSH.CommandRunnerBehaviour

  require Logger

  defp client_module,
    do: Application.get_env(:system_monitor, :ssh_client_module, SystemMonitor.SSH.Client)
  
  @impl true
  def execute(system, command, timeout, sudo_password \\ nil) do
    conn_result = client_module().connect(system)

    try do
      case conn_result do
        {:ok, conn} ->
          case safe_execute(conn, command, timeout, sudo_password) do
            {:ok, output} -> output
            {:error, reason} -> "Error: #{format_reason(reason)}"
          end

        {:error, reason} ->
          "Error: #{format_reason(reason)}"
      end
    after
      case conn_result do
        {:ok, conn} -> maybe_disconnect(conn)
        _ -> :ok
      end
    end
  end

  @impl true
  def execute_batch(system, commands, opts \\ []) do
    sudo_password = Keyword.get(opts, :sudo_password, nil)

    case client_module().connect(system) do
      {:ok, conn} ->
        try do
          results = Enum.map(commands, fn cmd -> run_one(conn, cmd, sudo_password) end)
          {:ok, results}
        after
          maybe_disconnect(conn)
        end

      {:error, reason} ->
        {:error, %{reason: :connection_failed, message: format_reason(reason)}}
    end
  end

  defp run_one(conn, cmd, sudo_password) do
    timeout = Map.get(cmd, :timeout, 10_000)
    id = Map.get(cmd, :id)

    try do
      case safe_execute(conn, cmd.command, timeout, sudo_password) do
        {:ok, output} ->
          %{id: id, status: :ok, output: output}
          
          {:error, reason} ->
        Logger.warning("Command #{id} failed: #{inspect(reason)}")
          
          %{
            id: id,
            status: :error,
            reason: classify_reason(reason),
            message: format_reason(reason)
          }
      end
    rescue
      e ->
        Logger.warning("Command #{inspect(id)} raised: #{inspect(e)}")
      
      %{
        id: id,
        status: :error,
        reason: :exception,
        message: Exception.message(e)
      }
    catch
      :exit, reason ->
        Logger.warning("Command #{inspect(id)} exited: #{inspect(reason)}")
      
      %{
        id: id,
        status: :error,
        reason: :exit,
        message: format_reason(reason)
      }
    end
  end
  
  defp safe_execute(conn, command, timeout, sudo_password) do
    client_module().execute(conn, command, timeout, sudo_password)
  end

  defp maybe_disconnect(nil), do: :ok
  defp maybe_disconnect(conn), do: client_module().disconnect(conn)

  defp classify_reason(:timeout), do: :timeout
  defp classify_reason(_), do: :exec_failed

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
