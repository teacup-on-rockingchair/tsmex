defmodule SystemMonitor.SSH.Client do
  @moduledoc """
  SSH connection management. 
  """
  @behaviour SystemMonitor.SSH.ClientBehaviour
  require Logger

  def connect(%{ssh_key_path: key_path} = system) when not is_nil(key_path) do
    connect_with_key(system)
  end

  def connect(%{password: password} = system) when not is_nil(password) do
    connect_with_password(system)
  end

  defp connect_with_password(system) do
    options = [
      user: String.to_charlist(system.username),
      password: String.to_charlist(system.password),
      silently_accept_hosts: true,
      user_interaction: false,
      connect_timeout: system.timeout
    ]

    case :ssh.connect(
           String.to_charlist(system.ip),
           system.port,
           options,
           system.timeout
         ) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        Logger.error("SSH connection failed for #{system.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp connect_with_key(system) do
    options = [
      user: String.to_charlist(system.username),
      silently_accept_hosts: true,
      user_interaction: false,
      connect_timeout: system.timeout
    ]

    options =
      if system.ssh_key_path do
        key_dir = Path.dirname(system.ssh_key_path) |> String.to_charlist()
        Keyword.put(options, :user_dir, key_dir)
      else
        options
      end

    case :ssh.connect(
           String.to_charlist(system.ip),
           system.port,
           options,
           system.timeout
         ) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, reason} ->
        Logger.error("SSH connection failed for #{system.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def disconnect(conn) do
    :ssh.close(conn)
  end

  def execute(conn, command, timeout \\ 10_000, sudo_password \\ nil) do
    case :ssh_connection.session_channel(conn, timeout) do
      {:ok, channel_id} ->
        try do
          success = :ssh_connection.exec(conn, channel_id, String.to_charlist(command), timeout)
          # Send sudo password if provided
          if sudo_password do
            :ssh_connection.send(conn, channel_id, "#{sudo_password}\n")
          end

          case success do
            :success ->
              receive_output(conn, channel_id, "", timeout)

            :failure ->
              {:error, "Failed to execute command"}
          end
        after
          # ALWAYS close channel
          :ssh_connection.close(conn, channel_id)
          Logger.debug("Channel #{channel_id} closed")
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_output(conn, channel_id, acc, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel_id, 0, data}} ->
        receive_output(conn, channel_id, acc <> to_string(data), timeout)

      {:ssh_cm, ^conn, {:data, ^channel_id, 1, data}} ->
        receive_output(conn, channel_id, acc <> to_string(data), timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel_id, _status}} ->
        receive_output(conn, channel_id, acc, timeout)

      {:ssh_cm, ^conn, {:eof, ^channel_id}} ->
        Logger.debug("EOF received on channel #{channel_id}")
        # EOF means no more data, keep waiting for :closed
        receive_output(conn, channel_id, acc, timeout)

      {:ssh_cm, ^conn, {:closed, ^channel_id}} ->
        Logger.debug("Channel #{channel_id} closed, output length: #{String.length(acc)}")
        {:ok, acc}
    after
      timeout ->
        Logger.error("Command timeout after #{timeout}ms")
        # Flush any remaining SSH messages for this channel
        flush_ssh_messages(conn, channel_id)
        {:error, :timeout}
    end
  end

  # Add this helper function
  defp flush_ssh_messages(conn, channel_id) do
    receive do
      {:ssh_cm, ^conn, {_type, ^channel_id, _data}} ->
        flush_ssh_messages(conn, channel_id)
    after
      0 -> :ok
    end
  end
end
