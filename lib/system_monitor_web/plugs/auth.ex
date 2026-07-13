defmodule SystemMonitorWeb.Plugs.Auth do
  @moduledoc """
  Handle web user authentication
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :authenticated) do
      true ->
        conn

      _ ->
        conn
        |> redirect(to: "/login")
        |> halt()
    end
  end
end
