defmodule SystemMonitorWeb.PageControllerTest do
  use SystemMonitorWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    conn = get(conn, redirected_to(conn))
    assert html_response(conn, 200) =~ "System Monitor Login"
  end
end
