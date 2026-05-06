defmodule PhoenixKitDb.Web.ShowLiveTest do
  @moduledoc """
  Smoke + delta-pinning tests for the DB Show (table-detail) page.
  """
  use PhoenixKitDb.LiveCase

  describe "mount with valid table" do
    test "renders columns and row count for phoenix_kit_settings", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      # Heading is the schema.table identifier (programmatic — not gettext-wrapped).
      assert html =~ "public.phoenix_kit_settings"

      # Subtitle contains the gettext-wrapped "rows" plural and a "row total".
      assert html =~ ~r/(rows total|row total)/

      # Live Activity link includes the table filter param
      assert html =~ "?table=public.phoenix_kit_settings"
    end

    test "renders pagination controls + Show/per-page form (gettext deltas)", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      # Show/per page labels (delta — gettext-wrapped)
      assert html =~ "Show"
      assert html =~ "per page"

      # Page navigation button titles (delta — gettext-wrapped)
      for title <- ["First page", "Previous page", "Next page", "Last page"] do
        assert html =~ ~r/title="#{Regex.escape(title)}"/
      end
    end
  end

  describe "mount with invalid table → graceful flash + redirect" do
    test "schema with unsafe characters redirects to /admin/db", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/bad-schema/users")

      assert redirect_to == "/en/admin/db"
      # Flash text is gettext-wrapped, with %{schema}/%{table} substitutions.
      assert flash["error"] =~ "Table bad-schema.users not found"
    end

    test "table with unsafe characters redirects to /admin/db", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/public/bad-table-name")

      assert redirect_to == "/en/admin/db"
      assert flash["error"] =~ "Table public.bad-table-name not found"
    end

    test "non-existent valid-name table redirects to /admin/db", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/public/no_such_table_anywhere")

      assert redirect_to == "/en/admin/db"
      assert flash["error"] =~ "Table public.no_such_table_anywhere not found"
    end
  end

  describe "pagination" do
    test "set_per_page recalculates the page number to keep position", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      result = render_change(view, "set_per_page", %{"per_page" => "50"})

      # The select reflects the new per_page value
      assert result =~ ~r/<option value="50" selected/

      # The patch carries the new per_page; page=1 is dropped from URL.
      assert_patch(view, "/en/admin/db/public/phoenix_kit_settings?per_page=50")
    end

    test "change_page reaches a new page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings?per_page=10")

      result = render_click(view, "change_page", %{"page" => "2"})

      # Page indicator reflects the new page (the "Page N of M" badge updates)
      assert result =~ ~r/Page\s+2\s+of\s+\d+/
    end
  end

  describe "live updates" do
    test ":table_changed for the viewed table is absorbed", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "abc"})
      assert Process.alive?(view.pid)
    end

    test ":table_changed for a different table is ignored", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      # Different table → no refresh scheduled, no crash
      send(view.pid, {:table_changed, "public", "different_table", "INSERT", "1"})

      html = render(view)
      assert html =~ "phoenix_kit_settings"
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "swallows unknown messages without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      send(view.pid, :some_random_atom)
      send(view.pid, {:weird, :tuple})

      html = render(view)
      assert is_binary(html)
      assert html =~ "phoenix_kit_settings"
    end
  end
end
