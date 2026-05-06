defmodule PhoenixKitDb.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and get
  excluded when the test DB isn't available, matching the rest of the
  suite.

  ## Example

      defmodule PhoenixKitDb.Web.IndexLiveTest do
        use PhoenixKitDb.LiveCase

        test "renders the index page", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/db")
          assert html =~ "Explore database tables"
        end
      end

  ## Scope assigns

  Tests can plug a fake scope via `with_scope/2` (a Plug-style helper
  that sets `:phoenix_kit_current_scope` on the conn before `live/2`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitDb.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitDb.ActivityLogAssertions
      import PhoenixKitDb.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDb.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  `Scope.has_module_access?/2` and `Scope.admin?/1` pattern-match on
  `%PhoenixKit.Users.Auth.Scope{}`, so a plain map won't satisfy them.
  `:cached_permissions` is a `MapSet`, `:cached_roles` is also a
  `MapSet` of role atoms.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `admin?/1` true
    * `:permissions` — list of module-key strings; `["db"]` grants
      access to the DB module pages
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope(permissions: ["db"]))
      {:ok, _view, html} = live(conn, "/en/admin/db")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["db"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/db")
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
