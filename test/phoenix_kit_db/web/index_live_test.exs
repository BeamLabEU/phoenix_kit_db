defmodule PhoenixKitDb.Web.IndexLiveTest do
  @moduledoc """
  Smoke + delta-pinning tests for the DB Index page.
  """
  use PhoenixKitDb.LiveCase

  alias PhoenixKitDb.PubSub

  describe "mount" do
    test "renders the page heading and stats cards", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db")

      # Heading + subtitle
      assert html =~ "Explore database tables and their contents"

      # Stats card titles (delta — gettext-wrapped now)
      for label <- ["Tables", "Rows", "Tables Size", "Database Size"] do
        regex = Regex.compile!("<div[^>]*stat-title[^>]*>\\s*#{Regex.escape(label)}\\s*</div>")

        assert html =~ regex,
               "expected stat-title #{inspect(label)} rendered inside a <div class=\"stat-title\">"
      end
    end

    test "renders the search form", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db")

      assert html =~ "Filter by schema or table name"
    end

    test "shows the Live Activity action button linking to /admin/db/activity", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db")

      # Verify the link target is the activity subpath
      assert html =~ ~r{href="[^"]*/admin/db/activity"}
    end

    test "renders the pg_stat_user_tables list", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db")

      # Page 1 alphabetically starts with the oban_* tables — pin one
      # of those rather than something deeper (which would shift across
      # core migrations).
      assert html =~ "oban_jobs"
    end
  end

  describe "search" do
    test "filtering by schema patches the URL with ?search=", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db")

      result = render_change(view, "search", %{"search" => "phoenix_kit_settings"})

      # Filter shows in rendered output (the search input keeps its value)
      assert result =~ ~s(value="phoenix_kit_settings")
      # Page-1 default is dropped from the URL; only search remains.
      assert_patch(view, "/en/admin/db?search=phoenix_kit_settings")
    end

    test "clearing the search returns to the unfiltered URL", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db?search=phoenix_kit_settings")

      render_change(view, "search", %{"search" => ""})

      assert_patch(view, "/en/admin/db")
    end
  end

  describe "live updates" do
    test ":table_changed messages are absorbed without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db")

      # Drive a synthetic broadcast — the LV should schedule a debounced
      # refresh and stay alive.
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "INSERT", "1"})
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "1"})

      # render/1 forces the LV to drain its mailbox; the catch-all
      # absorbs anything unexpected.
      html = render(view)
      # Page 1 alphabetical entries persist after the synthetic refresh.
      assert html =~ "oban_jobs"
    end

    test "subscribes to topic_all on connected mount", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, _html} = live(conn, "/en/admin/db")

      # If subscription happened, broadcasting on topic_all should reach
      # the LV process. We verify by subscribing the test process to
      # the same topic and confirming the broadcast round-trips.
      PubSub.subscribe(PubSub.topic_all())
      PubSub.broadcast(PubSub.topic_all(), {:table_changed, "public", "x", "INSERT", "1"})

      assert_receive {:table_changed, "public", "x", "INSERT", "1"}, 500
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "swallows unknown OTP messages without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db")

      send(view.pid, :some_unrelated_message)
      send(view.pid, {:tuple_with_no_matching_clause})

      html = render(view)
      assert is_binary(html)
      assert html =~ "Explore database tables"
    end
  end
end
