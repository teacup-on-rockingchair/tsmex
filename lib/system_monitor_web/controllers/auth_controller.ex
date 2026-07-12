defmodule SystemMonitorWeb.AuthController do
  use SystemMonitorWeb, :controller

  #  plug :put_layout, html: {SystemMonitorWeb.Layouts, :root}

  def login(conn, _params) do
    render(conn, :login, layout: false)
  end

  def create(conn, %{"username" => username, "password" => password}) do
    # Get credentials from config
    valid_username = Application.get_env(:system_monitor, :auth_username, "admin")
    valid_password = Application.get_env(:system_monitor, :auth_password, "admin")

    # Debug logging
    require Logger
    Logger.info("ENV AUTH_USERNAME: #{inspect(System.get_env("AUTH_USERNAME"))}")
    Logger.info("Config auth_username: #{inspect(valid_username)}")
    Logger.info("Attempting login with username: #{username}")

    if username == valid_username && password == valid_password do
      conn
      |> put_session(:authenticated, true)
      |> put_flash(:info, "Welcome!")
      |> redirect(to: "/")
    else
      conn
      |> put_flash(:error, "Invalid username or password")
      |> redirect(to: "/login")
    end
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Logged out successfully")
    |> redirect(to: "/login")
  end
end
