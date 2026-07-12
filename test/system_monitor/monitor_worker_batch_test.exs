defmodule SystemMonitor.Scheduler.MonitorWorkerBatchTest do
  use ExUnit.Case, async: false
  import Mox

  alias SystemMonitor.Scheduler.MonitorWorker
  alias SystemMonitor.Config.Commands

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:system_monitor, :command_runner_module, SystemMonitor.SSH.CommandRunnerMock)
    Application.put_env(:system_monitor, :records_module, SystemMonitor.Storage.RecordsMock)

    on_exit(fn ->
      Application.delete_env(:system_monitor, :command_runner_module)
      Application.delete_env(:system_monitor, :records_module)
    end)

    :ok
  end

  test "worker uses execute_batch/3 and remains alive on partial command failure" do
    system = %{name: "test-system", ip: "127.0.0.1"}

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
    expect(SystemMonitor.Storage.RecordsMock, :store, fn _record -> :ok end)

    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)
    allow(SystemMonitor.Storage.RecordsMock, self(), pid)

    send(pid, :check_system)
    Process.sleep(100)

    assert Process.alive?(pid)
  end

  test "parses batch results into stored record with success and error command entries" do
    system = %{name: "test-system", ip: "127.0.0.1"}

    commands = [
      %Commands{id: "uptime", command: "uptime", timeout: 1_000, description: "uptime", format: :raw},
      %Commands{id: "disk", command: "df -h", timeout: 1_000, description: "disk", format: :raw}
    ]

    expect(SystemMonitor.SSH.CommandRunnerMock, :execute_batch, fn ^system, ^commands, _opts ->
      {:ok,
       [
         %{id: "uptime", status: :ok, output: "up 1 day"},
         %{id: "disk", status: :error, reason: :timeout, message: "timeout"}
       ]}
    end)

    test_pid = self()
    expect(SystemMonitor.Storage.RecordsMock, :store, fn record ->
      send(test_pid, {:stored_record, record})
      assert record.system_name == "test-system"
      assert %DateTime{} = record.timestamp

      uptime = record.results["uptime"]
      assert uptime.result.type in [:raw, :icon, :extract]
      assert uptime.result.value == "up 1 day"

      disk = record.results["disk"]
      assert disk.result.type == :error
      assert disk.result.value == "timeout"
      assert disk.result.display == "Error (timeout): timeout"

      :ok
    end)

    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)
    allow(SystemMonitor.Storage.RecordsMock, self(), pid)
    send(pid, :check_system)

    assert_receive {:stored_record, record}, 1000
    assert Process.alive?(pid)
  end


  test "marks command as error when execute_batch omits a command result (nil branch)" do
    system = %{name: "test-system", ip: "127.0.0.1"}

    commands = [
      %Commands{id: "uptime", command: "uptime", timeout: 1_000, description: "uptime", format: :raw},
      %Commands{id: "disk", command: "df -h", timeout: 1_000, description: "disk", format: :raw}
    ]

    # Return only one result, omit "disk" intentionally
    expect(SystemMonitor.SSH.CommandRunnerMock, :execute_batch, fn ^system, ^commands, _opts ->
      {:ok, [%{id: "uptime", status: :ok, output: "up 1 day"}]}
    end)

    test_pid = self()
    expect(SystemMonitor.Storage.RecordsMock, :store, fn _record ->
      send(test_pid, {:stored_record, _record})
      :ok
    end)

    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)
    allow(SystemMonitor.Storage.RecordsMock, self(), pid)

    send(pid, :check_system)

    # At least one command succeeded, so success update should still be emitted
    assert_receive {:stored_record, record}, 1000
    disk = record.results["disk"]
    assert disk.result.type == :error
    assert disk.result.value =~ "missing batch result"
    assert Process.alive?(pid)
  end

  test "broadcasts system_updated on successful store (integration path)" do
    Application.put_env(:system_monitor, :records_module, SystemMonitor.Storage.Records)
    
    system = %{name: "test-system", ip: "127.0.0.1"}
    commands = [
      %Commands{id: "uptime", command: "uptime", timeout: 1_000, description: "uptime", format: :raw}
    ]
    
    expect(SystemMonitor.SSH.CommandRunnerMock, :execute_batch, fn ^system, ^commands, _opts ->
      {:ok, [%{id: "uptime", status: :ok, output: "up 1 day"}]}
    end)
    
    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)
    
    Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "system_updates")
    send(pid, :check_system)
    
    assert_receive {:system_updated, "test-system", %DateTime{}}, 1000
    assert Process.alive?(pid)
  end

  test "broadcasts system_check_partial when batch has mixed command outcomes" do
    system = %{name: "test-system", ip: "127.0.0.1"}
    
    commands = [
      %Commands{id: "uptime", command: "uptime", timeout: 1_000, description: "uptime", format: :raw},
      %Commands{id: "disk", command: "df -h", timeout: 1_000, description: "disk", format: :raw}
    ]
    
    expect(SystemMonitor.SSH.CommandRunnerMock, :execute_batch, fn ^system, ^commands, _opts ->
      {:ok,
     [
       %{id: "uptime", status: :ok, output: "up 1 day"},
       %{id: "disk", status: :error, reason: :timeout, message: "timeout"}
     ]}
    end)
    
    # Keep store mocked so we don't depend on storage internals here
    expect(SystemMonitor.Storage.RecordsMock, :store, fn _record -> :ok end)
    
    {:ok, pid} = MonitorWorker.start_link({system, commands})
    allow(SystemMonitor.SSH.CommandRunnerMock, self(), pid)
    allow(SystemMonitor.Storage.RecordsMock, self(), pid)
    
    Phoenix.PubSub.subscribe(SystemMonitor.PubSub, "system_updates")
    send(pid, :check_system)
    
    assert_receive {:system_check_partial, "test-system", %DateTime{}, stats}, 1000
    assert stats.successful == 1
    assert stats.failed == 1
    assert Process.alive?(pid)
  end
end
