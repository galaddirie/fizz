defmodule FizzWeb.Router do
  use FizzWeb, :router

  import FizzWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FizzWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FizzWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/webhooks", FizzWeb do
    pipe_through :api

    post "/workos", WorkOSWebhookController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", FizzWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:fizz, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FizzWeb.Telemetry
      live "/vue_demo", FizzWeb.VueDemoLive
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", FizzWeb do
    pipe_through [:browser]

    get "/users/log-in", WorkOSAuthController, :authorize
    delete "/users/log-out", UserSessionController, :delete
    get "/auth/workos", WorkOSAuthController, :authorize
    get "/auth/workos/callback", WorkOSAuthController, :callback
  end

  scope "/", FizzWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{FizzWeb.UserAuth, :require_authenticated}] do
      live "/settings/", UserManagementLive, :index
      live "/sprites", SpriteHubLive, :index
      live "/org/:organization_id/workspaces/:workspace_id/sprites", SpriteIndexLive, :index
      live "/org/:organization_id/workspaces/:workspace_id/sprites/:id", SpriteShowLive, :show
    end
  end
end
