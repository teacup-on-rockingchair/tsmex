defmodule SystemMonitorWeb.DashboardLiveTest do
  use SystemMonitorWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mox
  alias SystemMonitor.Config.Commands

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:system_monitor, :loader_module, SystemMonitor.Config.LoaderMock)
    Application.put_env(:system_monitor, :records_module, SystemMonitor.Storage.RecordsMock)

    on_exit(fn ->
      Application.delete_env(:system_monitor, :loader_module)
      Application.delete_env(:system_monitor, :records_module)
    end)

    :ok
  end

  test "mount handles commands config map shape and renders command column", %{conn: conn} do
    # however you stub Loader in your app:
    # Mox/stub module/app env/etc

    stub(SystemMonitor.Config.LoaderMock, :load_commands_config, fn ->
      {:ok,
       %{
         commands: [
           %Commands{
             id: "uptime",
             command: "uptime",
             description: "Uptime",
             format: :raw,
             timeout: 1000
           }
         ],
         noise_patterns: []
       }}
    end)

    stub(SystemMonitor.Config.LoaderMock, :load_services_config, fn ->
      {:ok, []}
    end)

    # also stub records call used on mount if needed
    stub(SystemMonitor.Storage.RecordsMock, :get_latest_for_all_systems, fn ->
      [
        %{
          system_name: "analyzer-01",
          last_check_time: DateTime.utc_now(),
          results: %{
            "uptime" => %{
              result: %{
                type: :raw,
                display: "up 1 day, 2:34"
              },
              last_known_good_time: DateTime.utc_now(),
              check_failed: false
            }
          }
        }
      ]
    end)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:authenticated, true)

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "analyzer-01"
    assert html =~ "up 1 day, 2:34"
    assert html =~ "System Monitor Dashboard"
  end
end
