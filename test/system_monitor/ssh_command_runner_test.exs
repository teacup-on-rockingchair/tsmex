defmodule SystemMonitor.SSHCommandRunnerTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "mock execute returns expected output" do
    Application.put_env(:system_monitor, :command_runner_module, SystemMonitor.SSH.CommandRunnerMock)

    SystemMonitor.SSH.CommandRunnerMock
    |> expect(:execute, fn _system, _command, _timeout, _ssh_key ->
      "Command executed successfully"
    end)

    result = SystemMonitor.SSH.CommandRunnerMock.execute(%{}, "monitor", 5_000, nil)
    assert result == "Command executed successfully"
  end
end
