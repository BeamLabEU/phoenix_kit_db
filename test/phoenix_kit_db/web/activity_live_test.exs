defmodule PhoenixKitDb.Web.ActivityLiveTest do
  @moduledoc """
  Smoke + delta-pinning tests for the DB Activity feed page.
  """
  use PhoenixKitDb.LiveCase

  describe "mount" do
    test "renders empty state and gettext-wrapped controls", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      # Heading
      assert html =~ "Live Database Activity"

      # Empty-state copy (delta — gettext-wrapped)
      assert html =~ "Waiting for database activity..."
      assert html =~ "INSERT, UPDATE, and DELETE operations will appear here in real-time"

      # Pause/Clear buttons (Pause icon renders when not paused; PhoenixKit
      # renders Heroicons as <span class="hero-..."> not <svg>).
      assert html =~ ~r/phx-click="toggle_pause"/
      assert html =~ ~r/phx-click="clear_log"/
      assert html =~ ~r/<span[^>]*hero-pause/
    end

    test "renders the filter form labels", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      # Filter labels (delta — gettext-wrapped)
      assert html =~ ~r/<span[^>]*label-text[^>]*>\s*Table\s*</
      assert html =~ ~r/<span[^>]*label-text[^>]*>\s*Operation\s*</

      # "All tables" / "All" defaults
      assert html =~ "All tables"
    end

    test "0 events counter rendered when log is empty", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      # ngettext singular when count == 0 ("0 events")
      assert html =~ "0 events"
    end
  end

  describe ":table_changed message handling" do
    test "adds an entry when not paused", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      # Synthesise an INSERT — the LV's add_activity_entry path will
      # try to fetch_row from the DB; in this test the row doesn't
      # exist, so row_data is nil and the entry shows the "Row data
      # not available" message.
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "INSERT", "0"})

      html = render(view)
      # Counter ticks to 1
      assert html =~ "1 event"
      # Operation badge
      assert html =~ "INSERT"
    end

    test "ignores entries when paused", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      # Pause first
      render_click(view, "toggle_pause", %{})

      # Then push an event
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "1"})

      html = render(view)
      # Counter stays at 0
      assert html =~ "0 events"
    end

    test "filtering by table excludes other tables", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      # Filter to a specific table
      render_change(view, "filter_table", %{"table" => "public.users"})

      # Push an event for a different table
      send(view.pid, {:table_changed, "public", "other_table", "INSERT", "1"})

      html = render(view)
      assert html =~ "0 events"
    end

    test "filtering by operation excludes other operations", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      render_change(view, "filter_operation", %{"operation" => "DELETE"})

      # Push a non-matching INSERT
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "INSERT", "1"})

      html = render(view)
      assert html =~ "0 events"
    end
  end

  describe "controls" do
    test "toggle_pause flips the badge state", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, "/en/admin/db/activity")

      # Initially monitoring
      assert html =~ "Monitoring all tables in real-time"

      # Click pause
      paused_html = render_click(view, "toggle_pause", %{})
      assert paused_html =~ ~r/Paused\s*[^<]*0 events captured/

      # Toggle again
      resumed_html = render_click(view, "toggle_pause", %{})
      assert resumed_html =~ "Monitoring all tables in real-time"
    end

    test "clear_log empties the activity feed", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      # Add an entry
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "INSERT", "0"})
      assert render(view) =~ "1 event"

      # Clear
      cleared_html = render_click(view, "clear_log", %{})
      assert cleared_html =~ "0 events"
      assert cleared_html =~ "Waiting for database activity..."
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "swallows unknown messages without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      send(view.pid, :random_atom)
      send(view.pid, {:bogus, :tuple})

      html = render(view)
      assert is_binary(html)
      assert html =~ "Live Database Activity"
    end
  end
end
