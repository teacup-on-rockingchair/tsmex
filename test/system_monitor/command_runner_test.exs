defmodule SystemMonitor.SSH.CommandRunnerTest do
  use ExUnit.Case, async: true

  import Mox

  alias SystemMonitor.SSH.CommandRunner

  setup :verify_on_exit!
  setup :set_mox_from_context
  
  setup do
    Application.put_env(:system_monitor, :ssh_client_module, SystemMonitor.SSH.ClientMock)
    :ok
  end
  
  test "execute_batch returns structured results in command order" do
    SystemMonitor.SSH.ClientMock |> expect(:connect, 1, fn _system -> {:ok, :conn} end)
    SystemMonitor.SSH.ClientMock |> expect(:execute, 2, fn :conn, command, _timeout, _sudo_password ->
      {:ok, "Output for #{command}"}
    end)
    SystemMonitor.SSH.ClientMock |> expect(:disconnect, 1, fn :conn -> :ok end)
    
    system = %{name: "s1", ip: "127.0.0.1", password: "password", username: "user", timeout: 5_000, port: 22, ssh_key_path: nil}
    commands = [
      %{id: "c1", command: "echo ok", timeout: 1_000},
      %{id: "c2", command: "echo ok2", timeout: 1_000}
    ]

    # Initially expected to fail until execute_batch/3 is implemented
    assert {:ok, results} = CommandRunner.execute_batch(system, commands)
    assert Enum.map(results, & &1.id) == ["c1", "c2"]
  end

  test "execute_batch continues after one command failure" do
    SystemMonitor.SSH.ClientMock |> expect(:connect, 1, fn _system -> {:ok, :conn} end)
    SystemMonitor.SSH.ClientMock |> expect(:execute, 1, fn :conn, command, _timeout, _sudo_password ->
      {:error, "Bad #{command} output"}
    end)
    SystemMonitor.SSH.ClientMock |> expect(:execute, 1, fn :conn, command, _timeout, _sudo_password ->
      {:ok, "Output for #{command}"}
    end)
    SystemMonitor.SSH.ClientMock |> expect(:disconnect, 1, fn :conn -> :ok end)

    system = %{name: "s1", ip: "127.0.0.1", password: "password", username: "user", timeout: 5_000, port: 22, ssh_key_path: nil}
    commands = [
      %{id: "c1", command: "bad", timeout: 1_000},
      %{id: "c2", command: "echo ok", timeout: 1_000}
    ]

    assert {:ok, results} = CommandRunner.execute_batch(system, commands)
    assert length(results) == 2
  end
end
