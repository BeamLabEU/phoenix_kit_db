defmodule PhoenixKitDb.Web.IndexLiveTest do
  @moduledoc """
  Smoke + delta-pinning tests for the DB Index page.
  """
  use PhoenixKitDb.LiveCase

  alias PhoenixKitDb.PubSub

  setup %{conn: conn} do
    %{conn: put_test_scope(conn, fake_scope())}
  end

  describe "mount" do
    test "renders the page heading and stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/db")

      # Core renders a header subtitle only when the site-wide
      # `show_page_descriptions` setting is on (off by default), so the
      # heading is what this page owns.
      assert [heading] = texts(html, "header h1")
      assert heading == "DB"

      # Stats card titles (delta — gettext-wrapped now)
      for label <- ["Tables", "Rows", "Tables Size", "Database Size"] do
        regex = Regex.compile!("<div[^>]*stat-title[^>]*>\\s*#{Regex.escape(label)}\\s*</div>")

        assert html =~ regex,
               "expected stat-title #{inspect(label)} rendered inside a <div class=\"stat-title\">"
      end
    end

    test "renders the search form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/db")

      assert html =~ "Filter by schema or table name"
    end

    test "shows the Live Activity action button linking to /admin/db/activity", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/db")

      # Verify the link target is the activity subpath
      assert html =~ ~r{href="[^"]*/admin/db/activity"}
    end

    test "renders the pg_stat_user_tables list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/db")

      # Page 1 alphabetically starts with the oban_* tables — pin one
      # of those rather than something deeper (which would shift across
      # core migrations).
      assert html =~ "oban_jobs"
    end
  end

  describe "search" do
    test "a search for the literal 1 stays in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db")
      view |> form("#db-table-search", %{"search" => "1"}) |> render_change()
      assert_patch(view, "/admin/db?search=1")
      assert assigns(view).search == "1"
    end

    test "filtering by schema patches the URL with ?search=", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db")

      result =
        view
        |> form("#db-table-search", %{"search" => "phoenix_kit_settings"})
        |> render_change()

      # Filter shows in rendered output (the search input keeps its value)
      assert result =~ ~s(value="phoenix_kit_settings")
      # Page-1 default is dropped from the URL; only search remains.
      assert_patch(view, "/admin/db?search=phoenix_kit_settings")
      assert texts(result, "tbody td a.font-semibold") == ["public.phoenix_kit_settings"]
    end

    test "clearing the search returns to the unfiltered URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db?search=phoenix_kit_settings")

      view |> form("#db-table-search", %{"search" => ""}) |> render_change()

      assert_patch(view, "/admin/db")
    end
  end

  describe "the page loads its data once per render pass" do
    test "one table listing for the dead render and one for the connected one", %{conn: conn} do
      {{:ok, view, _html}, statements} =
        QueryCounter.capture(fn -> live(conn, "/admin/db") end)

      listings = Enum.filter(statements, &(&1 =~ "pg_stat_user_tables" and &1 =~ "LIMIT $"))
      assert length(listings) == 2

      {_html, statements} =
        QueryCounter.capture(fn ->
          view |> form("#db-table-search", %{"search" => "oban"}) |> render_change()
        end)

      listings = Enum.filter(statements, &(&1 =~ "pg_stat_user_tables" and &1 =~ "LIMIT $"))
      assert length(listings) == 1
    end

    test "the database stats are read once per render pass too", %{conn: conn} do
      {{:ok, _view, _html}, statements} =
        QueryCounter.capture(fn -> live(conn, "/admin/db") end)

      assert QueryCounter.count(statements, "pg_database_size") == 2
    end
  end

  describe "tables this page cannot open" do
    test "are not linked, and the page says how many were left out", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/db")
      assert texts(html, "#db-hidden-tables") == []

      Fixtures.sql!(~s|CREATE TABLE "pk_db-dash" (id int PRIMARY KEY)|)
      Fixtures.sql!(~s|CREATE TABLE "pk_db.dot" (id int PRIMARY KEY)|)
      Fixtures.sql!(~s|CREATE TABLE pk_db_fine (id int PRIMARY KEY)|)

      {:ok, _view, html} = live(conn, "/admin/db?search=pk_db")

      assert texts(html, "tbody td a.font-semibold") == ["public.pk_db_fine"]
      assert [note] = texts(html, "#db-hidden-tables")
      assert note =~ ~r/\A2 tables are not listed/
    end
  end

  describe "live updates" do
    test "a broadcast on topic_all reaches the page and schedules one refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db")
      refute assigns(view).refresh_scheduled

      # Nothing but the page's own subscription delivers this.
      PubSub.broadcast(PubSub.topic_all(), {:table_changed, "public", "x", "INSERT", "1"})
      PubSub.broadcast(PubSub.topic_all(), {:table_changed, "public", "x", "UPDATE", "1"})

      assert assigns(view).refresh_scheduled
    end

    test "a broadcast on a table topic does not reach the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db")

      PubSub.broadcast(
        PubSub.topic_table("public", "x"),
        {:table_changed, "public", "x", "INSERT", "1"}
      )

      refute assigns(view).refresh_scheduled
    end

    test "the debounced refresh re-reads the table list and the stats", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/db?search=pk_db_fresh")

      assert html =~ "No tables found."
      tables_before = assigns(view).stats.table_count

      Fixtures.sql!("CREATE TABLE pk_db_fresh (id int PRIMARY KEY)")
      send(view.pid, {:table_changed, "public", "pk_db_fresh", "INSERT", "1"})
      send(view.pid, :debounced_refresh)

      html = render(view)

      assert texts(html, "tbody td a.font-semibold") == ["public.pk_db_fresh"]
      assert assigns(view).stats.table_count == tables_before + 1
      refute assigns(view).refresh_scheduled
      # The refresh keeps the search the page was opened with.
      assert html =~ ~s(value="pk_db_fresh")
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "an unknown message changes nothing on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/db")
      before = render(view)

      send(view.pid, :some_unrelated_message)
      send(view.pid, {:tuple_with_no_matching_clause})

      assert render(view) == before
    end
  end
end
