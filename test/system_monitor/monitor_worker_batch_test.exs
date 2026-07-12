defmodule SystemMonitor.Scheduler.MonitorWorkerBatchTest do
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

  test "worker uses execute_batch/3 and remains alive on partial command failure" do
    system = %{name: "test-system", ip: "127.0.0.1"}
    alias SystemMonitor.Config.Commands

    commands = [
      %Commands{id: "uptime", command: "uptime", timeout: 1_000, description: "uptime", format: :raw},
      %Commands{id: "disk", command: "df -h", timeout: 1_000, description: "disk", format: :raw}
    ]

    expect(SystemMonitor.SSH.CommandRunnerMock, :execute_batch, fn ^system, ^commands, _opts ->
      {:ok, [
        %{id: "uptime", status: :ok, output: "up 1 day"},
        %{id: "disk", status: :error, reason: :timeout, message: "timeout"}
      ]}
    end)

    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)

    send(pid, :check_system)
    Process.sleep(100)

    assert Process.alive?(pid)
  end
end
