defmodule NixployWeb.Router do
  use NixployWeb, :router

  import NixployWeb.OperatorAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NixployWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_operator
  end

  pipeline :authenticated_operator do
    plug :require_authenticated_operator
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NixployWeb do
    pipe_through :api

    get "/health", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", NixployWeb do
    pipe_through :browser

    get "/login", OperatorSessionController, :new
    post "/login", OperatorSessionController, :create
    delete "/logout", OperatorSessionController, :delete
  end

  scope "/", NixployWeb do
    pipe_through [:browser, :authenticated_operator]

    live_session :authenticated,
      on_mount: [{NixployWeb.OperatorAuth, :ensure_authenticated}] do
      live "/", DeploymentLive.Index, :index
      live "/deployment-inputs/:id", DeploymentLive.Show, :show
      live "/native-deployments/:id", DeploymentLive.NativeShow, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", NixployWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:nixploy, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :authenticated_operator]

      live_dashboard "/dashboard", metrics: NixployWeb.Telemetry
    end
  end
end
