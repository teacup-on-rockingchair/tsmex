defmodule SystemMonitorWeb.PageController do
  use SystemMonitorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
