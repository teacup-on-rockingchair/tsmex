defmodule SystemMonitorWeb.Router do
  use SystemMonitorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SystemMonitorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Protected routes
  pipeline :authenticated do
    plug SystemMonitorWeb.Plugs.Auth
  end

  # Public routes (login)
  scope "/", SystemMonitorWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    post "/login", AuthController, :create
    get "/logout", AuthController, :logout
  end

  # Protected routes
  scope "/", SystemMonitorWeb do
    pipe_through [:browser, :authenticated]

    live "/", DashboardLive, :index
    live "/systems/:system_name", SystemDetailLive
  end
end
