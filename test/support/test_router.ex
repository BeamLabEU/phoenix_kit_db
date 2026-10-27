defmodule PhoenixKitDb.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitDb.Paths` so `live/2` calls in tests work with
  exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` gives an unprefixed admin path here, so
  our base is `/admin/db`.
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

  # The LiveViews push to whatever `PhoenixKitDb.Paths` returns, which is
  # unprefixed here (`PhoenixKit.Utils.Routes.path/1` adds a locale only for a
  # localized request), and phoenix_live_view 1.2 refuses to patch to a path of
  # another live_session.
  scope "/admin/db", PhoenixKitDb.Web do
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
