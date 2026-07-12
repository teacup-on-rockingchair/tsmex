defmodule SystemMonitor.Scheduler.MonitorWorkerInjectionTest do
  use ExUnit.Case, async: false
  import Mox

  alias SystemMonitor.Scheduler.MonitorWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:system_monitor, :command_runner_module, SystemMonitor.SSH.CommandRunnerMock)

    on_exit(fn ->
      Application.delete_env(:system_monitor, :command_runner_module)
    end)

    :ok
  end

  test "worker uses configured command_runner_module for batch execution" do
    system = %{name: "test-system", ip: "127.0.0.1"}
    cmd = %{id: "uptime", command: "uptime", timeout: 1_000}
    
    expect(SystemMonitor.SSH.CommandRunnerMock, :execute, fn ^system, "uptime", 1_000, nil ->
      "up 1 day"
    end)
    
    assert MonitorWorker.run_command_once_for_test(system, cmd) == "up 1 day"
  end
end
