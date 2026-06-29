defmodule SystemMonitor.BodyCountTest do
  use ExUnit.Case, async: true

  import Mox

  alias SystemMonitor.BodyCount
  alias SystemMonitor.Config.Loader

  setup do
    IO.puts("Setting up BodyCount GenServer for tests...")
    server_name = make_ref()
    IO.inspect(server_name, label: "Generated unique server name")
    System.put_env("SYSTEMS_CONFIG_PATH", "test/support/test_systems.json") 
    Mox.set_mox_global()

    result = Loader.load_systems_config()
    {:ok, configured_systems} = result

    start_supervised!({BodyCount,  configured_systems})
    host_1 = "192.168.1.100"
    host_2 = "192.168.1.101"
    host_3 = "192.168.1.103"
    host_4 = "192.168.1.104"

    on_exit(fn ->
      # Cleanup runs after the test, even if it fails
      BodyCount.report_success(host_1)
      BodyCount.report_success(host_2)
      BodyCount.report_success(host_3)
      BodyCount.report_success(host_4)
    end)
    
    %{server: server_name, host_1: host_1,host_2: host_2, host_3: host_3, host_4: host_4}
  end

  setup :verify_on_exit!

  test "marks host for rescan after 3 failures", ctx do
    SystemMonitor.MockScanner |> expect( :scan, 1, fn [_,_],"password1"  ->  "192.168.1.100" end)
    SystemMonitor.MockScanner |> expect( :scan, 1, fn [_,_],"password3"  ->  "192.168.1.100" end)

    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_1)
    assert BodyCount.get(ctx.host_1) == 3
    
    BodyCount.report_failure(ctx.host_3)
    BodyCount.report_failure(ctx.host_3)
    BodyCount.report_failure(ctx.host_3)
    assert BodyCount.get(ctx.host_3) == 3
    
    assert ctx.host_3 in BodyCount.pending_rescans()
    assert ctx.host_1 in BodyCount.pending_rescans()
    assert ctx.host_2 not in BodyCount.pending_rescans()
    assert ctx.host_4 not in BodyCount.pending_rescans()
  end

  test "resets failure count after successful scan", ctx do
    BodyCount.report_failure(ctx.host_2)
    BodyCount.report_failure(ctx.host_2)
    assert BodyCount.get(ctx.host_2) == 2

    BodyCount.report_success(ctx.host_2)
    assert BodyCount.get(ctx.host_2) == 0
  end

  test "does not mark host for rescan if failures are below threshold", ctx do
    BodyCount.report_failure(ctx.host_4)
    BodyCount.report_failure(ctx.host_4)
    assert BodyCount.get(ctx.host_4) == 2
    assert ctx.host_4 not in BodyCount.pending_rescans()
  end

  test "handles multiple hosts independently", ctx do
    expect( SystemMonitor.MockScanner , :scan, 1, fn([_,_],"password1") -> {:ok, "192.168.1.100"} end)
    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_2)
    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_2)
    BodyCount.report_failure(ctx.host_1)

    assert BodyCount.get(ctx.host_1) == 3
    assert BodyCount.get(ctx.host_2) == 2

    assert ctx.host_1 in BodyCount.pending_rescans()
    assert ctx.host_2 not in BodyCount.pending_rescans()
  end

  test "starts with zero failures for all configured systems", ctx do
    assert BodyCount.get(ctx.host_1) == 0
    assert BodyCount.get(ctx.host_2) == 0
    assert BodyCount.get(ctx.host_3) == 0
    assert BodyCount.get(ctx.host_4) == 0

    assert BodyCount.pending_rescans() == []
  end

  test "can extract from configuration password for a given system", ctx do
    assert BodyCount.get_password(ctx.host_1) == "password1"
    assert BodyCount.get_password(ctx.host_2) == "password2"
    assert BodyCount.get_password(ctx.host_3) == "password3"
    assert BodyCount.get_password(ctx.host_4) == "password4"
  end
  
  test "initiates rescan for hosts that reach failure threshold", ctx do
    expect( SystemMonitor.MockScanner , :scan, fn (["192.168.1.100","192.168.1.110"], "password1") ->
      IO.puts("Mock scan initiated for password1")
      {:ok, "192.168.1.100"}
    end)
    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_1)
    BodyCount.report_failure(ctx.host_1)

    assert ctx.host_1 in BodyCount.pending_rescans()
  end
end
