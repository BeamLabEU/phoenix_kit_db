defmodule PhoenixKitDb.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitDb.Paths` so `live/2` calls in tests work with
  exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable, and admin paths always
  get the default locale ("en") prefix — so our base becomes
  `/en/admin/db`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitDb.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/db", PhoenixKitDb.Web do
    pipe_through(:browser)

    live_session :phoenix_kit_db_test,
      layout: {PhoenixKitDb.Test.Layouts, :app},
      on_mount: {PhoenixKitDb.Test.Hooks, :assign_scope} do
      live("/", IndexLive, :index)
      live("/activity", ActivityLive, :activity)
      live("/:schema/:table", ShowLive, :show)
    end
  end
end
