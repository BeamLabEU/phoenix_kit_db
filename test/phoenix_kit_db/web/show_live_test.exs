defmodule PhoenixKitDb.Web.ShowLiveTest do
  @moduledoc """
  The DB Show (table-detail) page, driven through the real LiveView.
  """
  use PhoenixKitDb.LiveCase

  alias PhoenixKitDb.Cells
  alias PhoenixKitDb.Web.ShowLive

  setup %{conn: conn} do
    %{conn: put_test_scope(conn, fake_scope())}
  end

  # `%{column => text}` for the first data row, as rendered.
  defp first_row(html) do
    headers = texts(html, "#table-container thead th")
    cells = texts(html, "#table-container tbody tr:first-child td")

    headers |> Enum.zip(cells) |> Map.new()
  end

  defp create_rows_table do
    Fixtures.sql!("CREATE TABLE pk_db_rows (uuid uuid PRIMARY KEY, label text)")

    for n <- 1..3 do
      uuid = "018f3c1e-7a2b-7c3d-8e4f-00000000000#{n}"
      Fixtures.sql!("INSERT INTO pk_db_rows VALUES ($1::text::uuid, $2)", [uuid, "row #{n}"])
      uuid
    end
  end

  describe "mount with valid table" do
    test "renders columns and row count for phoenix_kit_settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      # Heading is the schema.table identifier (programmatic — not gettext-wrapped).
      assert html =~ "public.phoenix_kit_settings"

      # Subtitle contains the gettext-wrapped "rows" plural and a "row total".
      assert html =~ ~r/(rows total|row total)/

      # Live Activity link includes the table filter param
      assert html =~ "?table=public.phoenix_kit_settings"

      assert "key" in texts(html, "#table-container thead th")
    end

    test "the header trail is DB / <schema.table>", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      assert assigns(view).page_section == "DB"
      assert assigns(view).page_section_path == "/en/admin/db"
      assert assigns(view).page_crumbs == []
      assert assigns(view).page_title == "public.phoenix_kit_settings"
    end

    test "renders pagination controls + Show/per-page form (gettext deltas)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      # Show/per page labels (delta — gettext-wrapped)
      assert html =~ "Show"
      assert html =~ "per page"

      # Page navigation button titles (delta — gettext-wrapped)
      for title <- ["First page", "Previous page", "Next page", "Last page"] do
        assert html =~ ~r/title="#{Regex.escape(title)}"/
      end
    end

    test "an uppercase table in a non-public schema opens", %{conn: conn} do
      Fixtures.sql!("CREATE SCHEMA pk_db_other")
      Fixtures.sql!(~s|CREATE TABLE pk_db_other."PkDbUpper" (id int PRIMARY KEY, label text)|)
      Fixtures.sql!(~s|INSERT INTO pk_db_other."PkDbUpper" VALUES (1, 'upper row')|)

      {:ok, _view, html} = live(conn, "/en/admin/db/pk_db_other/PkDbUpper")

      assert first_row(html) == %{"id" => "1", "label" => "upper row"}
    end
  end

  describe "the page loads its data once per render pass" do
    test "one COUNT and one SELECT for the dead render, one each for the connected one",
         %{conn: conn} do
      {{:ok, view, _html}, statements} =
        QueryCounter.capture(fn -> live(conn, "/en/admin/db/public/phoenix_kit_settings") end)

      assert QueryCounter.count(statements, ~s|COUNT(*) FROM "public"."phoenix_kit_settings"|) ==
               2

      assert QueryCounter.count(statements, ~s|SELECT * FROM "public"."phoenix_kit_settings"|) ==
               2

      {_html, statements} =
        QueryCounter.capture(fn -> render_click(view, "change_page", %{"page" => "2"}) end)

      assert QueryCounter.count(statements, ~s|COUNT(*) FROM "public"."phoenix_kit_settings"|) ==
               1
    end
  end

  describe "secret columns" do
    test "are masked in the HTML and absent from the LiveView's state", %{conn: conn} do
      Fixtures.create_secrets_table()

      {:ok, view, html} = live(conn, "/en/admin/db/public/pk_db_secrets")

      row = first_row(render(view))

      for column <- ~w(hashed_password API_KEY refresh_token webhook_secret password_salt) do
        assert row[column] == Cells.masked_placeholder(), "#{column} is not masked"
      end

      # A null secret is still visibly null, and plain columns are untouched.
      assert row["reset_token"] == "null"
      assert row["email"] == "visible@example.com"
      assert row["note"] == "plain note"
      assert row["settings"] =~ ~s("theme":"dark")

      state = inspect(assigns(view), limit: :infinity, printable_limit: :infinity)

      for marker <- Fixtures.secret_markers() do
        refute html =~ marker, "#{marker} is in the dead render"
        refute render(view) =~ marker, "#{marker} is in the connected render"
        refute state =~ marker, "#{marker} is in the LiveView's assigns"
      end
    end

    test "stay masked after a live refresh", %{conn: conn} do
      Fixtures.create_secrets_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_secrets")

      Fixtures.sql!("UPDATE pk_db_secrets SET hashed_password = 'LEAK-rotated', note = 'edited'")
      send(view.pid, {:table_changed, "public", "pk_db_secrets", "UPDATE", "1"})
      send(view.pid, :debounced_refresh)

      html = render(view)
      assert first_row(html)["note"] == "edited"
      assert first_row(html)["hashed_password"] == Cells.masked_placeholder()
      refute html =~ "LEAK-"
    end
  end

  describe "cell rendering" do
    test "every column type renders as readable text and the page does not crash",
         %{conn: conn} do
      Fixtures.create_types_table()

      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_types")

      row = first_row(render(view))

      for {column, expected} <- Fixtures.expected_type_texts() do
        assert row[column] == expected, "column #{column} rendered #{inspect(row[column])}"
      end

      # Types with no dedicated text still render something, not a crash.
      assert row["spot"] =~ "Postgrex.Point"
      assert row["words"] =~ "cat"
      assert row["missing"] == "null"
    end

    test "a uuid primary key is canonical text, not a byte list", %{conn: conn} do
      [uuid | _] = create_rows_table()

      {:ok, _view, html} = live(conn, "/en/admin/db/public/pk_db_rows")

      assert first_row(html)["uuid"] == uuid
      refute html =~ "&lt;&lt;"
    end
  end

  describe "mount with invalid table → graceful flash + redirect" do
    test "schema with unsafe characters redirects to /admin/db", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/bad-schema/users")

      assert redirect_to == "/en/admin/db"
      # Flash text is gettext-wrapped, with %{schema}/%{table} substitutions.
      assert flash["error"] =~ "Table bad-schema.users not found"
    end

    test "table with unsafe characters redirects to /admin/db", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/public/bad-table-name")

      assert redirect_to == "/en/admin/db"
      assert flash["error"] =~ "Table public.bad-table-name not found"
    end

    test "non-existent valid-name table redirects to /admin/db", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
               live(conn, "/en/admin/db/public/no_such_table_anywhere")

      assert redirect_to == "/en/admin/db"
      assert flash["error"] =~ "Table public.no_such_table_anywhere not found"
    end

    test "an existing table whose name cannot be quoted redirects too", %{conn: conn} do
      Fixtures.sql!(~s|CREATE TABLE "pk_db-dash" (id int PRIMARY KEY)|)

      assert {:error, {:live_redirect, %{to: "/en/admin/db", flash: flash}}} =
               live(conn, "/en/admin/db/public/pk_db-dash")

      assert flash["error"] =~ "Table public.pk_db-dash not found"
    end
  end

  describe "pagination" do
    test "set_per_page recalculates the page number to keep position", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      result = view |> form("#db-per-page", %{"per_page" => "50"}) |> render_change()

      # The select reflects the new per_page value
      assert result =~ ~r/<option value="50" selected/

      # The patch carries the new per_page; page=1 is dropped from URL.
      assert_patch(view, "/en/admin/db/public/phoenix_kit_settings?per_page=50")
    end

    test "change_page reaches a new page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings?per_page=10")

      result = view |> element(~s|button[title="Next page"]|) |> render_click()

      # Page indicator reflects the new page (the "Page N of M" badge updates)
      assert result =~ ~r/Page\s+2\s+of\s+\d+/
    end

    test "malformed page param falls back to page 1", %{conn: conn} do
      # parse_page/1's fallback branch — non-integer string becomes 1.
      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings?page=bogus")

      assert html =~ ~r/Page\s+1\s+of\s+\d+/
    end

    test "out-of-allowlist per_page falls back to default 20", %{conn: conn} do
      # parse_per_page/1 only accepts [10, 20, 50, 100, 200]; 9999 → 20.
      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings?per_page=9999")

      assert html =~ ~r/<option value="20" selected/
    end

    test "non-numeric per_page param falls back to default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/public/phoenix_kit_settings?per_page=abc")

      assert html =~ ~r/<option value="20" selected/
    end
  end

  describe "page markers" do
    test "page_markers/1 lists every page while they fit" do
      assert ShowLive.page_markers(1) == [1]
      assert ShowLive.page_markers(7) == Enum.to_list(1..7)
      assert ShowLive.page_markers(25) == Enum.to_list(1..25)
    end

    test "page_markers/1 is bounded however many pages there are" do
      for total <- [26, 30, 1_000, 50_000, 1_000_000] do
        markers = ShowLive.page_markers(total)

        assert length(markers) == 25, "#{total} pages gave #{length(markers)} markers"
        assert hd(markers) == 1
        assert List.last(markers) == total
        assert markers == Enum.sort(Enum.uniq(markers))
      end
    end

    test "the page renders a bounded number of marker nodes", %{conn: conn} do
      Fixtures.sql!("CREATE TABLE pk_db_pages (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_pages SELECT generate_series(1, 400)")

      {:ok, _view, html} = live(conn, "/en/admin/db/public/pk_db_pages?per_page=10")

      markers = texts(html, "#page-markers .page-marker")

      assert html =~ ~r/Page\s+1\s+of\s+40/
      assert length(markers) == 25
      assert hd(markers) == "1"
      assert List.last(markers) == "40"
    end
  end

  describe "row total" do
    test "a small table shows its exact count", %{conn: conn} do
      Fixtures.sql!("CREATE TABLE pk_db_small (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_small SELECT generate_series(1, 7)")

      {:ok, view, html} = live(conn, "/en/admin/db/public/pk_db_small")

      assert has_element?(view, ~s|#db-row-total[data-approximate="false"]|)
      assert texts(html, "#db-row-total") == ["7 rows total"]
    end

    test "a large table shows the estimate, labelled as one", %{conn: conn} do
      Fixtures.sql!("CREATE TABLE pk_db_big (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_big SELECT generate_series(1, 100500)")
      Fixtures.sql!("ANALYZE pk_db_big")

      {{:ok, view, html}, statements} =
        QueryCounter.capture(fn -> live(conn, "/en/admin/db/public/pk_db_big") end)

      assert has_element?(view, ~s|#db-row-total[data-approximate="true"]|)
      assert [total] = texts(html, "#db-row-total")
      assert total =~ ~r/\Aabout \d+ rows total \(estimate\)\z/
      assert QueryCounter.count(statements, "COUNT(*) FROM") == 0
    end
  end

  describe "live updates" do
    test ":table_changed for the viewed table schedules one refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      refute assigns(view).refresh_scheduled

      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "abc"})
      send(view.pid, {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "abc"})

      assert assigns(view).refresh_scheduled
    end

    test ":table_changed for a different table is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")

      send(view.pid, {:table_changed, "public", "different_table", "INSERT", "1"})

      refute assigns(view).refresh_scheduled
    end

    test "a changed row is highlighted by its primary key, then cleared", %{conn: conn} do
      [_first, second, _third] = create_rows_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_rows")
      refute has_element?(view, "tr.animate-highlight")

      Fixtures.sql!("UPDATE pk_db_rows SET label = 'edited' WHERE uuid = $1::text::uuid", [second])

      send(view.pid, {:table_changed, "public", "pk_db_rows", "UPDATE", second})
      send(view.pid, :debounced_refresh)

      # element/2 raises unless exactly one row matches.
      highlighted = view |> element("tr.animate-highlight") |> render()
      assert highlighted =~ second
      assert highlighted =~ "edited"
      assert texts(render(view), "#flash-info") == ["Data updated"]
      refute assigns(view).refresh_scheduled

      send(view.pid, :clear_highlights)
      refute has_element?(view, "tr.animate-highlight")
    end

    test "an added row is highlighted and counted in the flash", %{conn: conn} do
      create_rows_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_rows")

      added = "018f3c1e-7a2b-7c3d-8e4f-000000000009"
      Fixtures.sql!("INSERT INTO pk_db_rows VALUES ($1::text::uuid, 'fresh')", [added])
      send(view.pid, :debounced_refresh)

      assert view |> element("tr.animate-highlight") |> render() =~ added
      assert texts(render(view), "#flash-info") == ["1 row added"]
    end

    test "removed rows are counted in the flash and nothing is highlighted", %{conn: conn} do
      [first, second, _third] = create_rows_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_rows")

      Fixtures.sql!(
        "DELETE FROM pk_db_rows WHERE uuid IN ($1::text::uuid, $2::text::uuid)",
        [first, second]
      )

      send(view.pid, :debounced_refresh)

      html = render(view)
      assert texts(html, "#flash-info") == ["2 rows removed"]
      refute has_element?(view, "tr.animate-highlight")
      assert texts(html, "#db-row-total") == ["1 row total"]
    end

    test "a refresh that finds nothing changed says nothing", %{conn: conn} do
      create_rows_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_rows")

      send(view.pid, :debounced_refresh)

      assert texts(render(view), "#flash-info") == []
      refute has_element?(view, "tr.animate-highlight")
    end

    test "a table without a primary key highlights by position", %{conn: conn} do
      Fixtures.sql!("CREATE TABLE pk_db_no_pk (a int, b text)")
      Fixtures.sql!("INSERT INTO pk_db_no_pk VALUES (1, 'one')")
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_no_pk")

      Fixtures.sql!("UPDATE pk_db_no_pk SET b = 'uno'")
      send(view.pid, :debounced_refresh)

      assert view |> element("tr.animate-highlight") |> render() =~ "uno"
    end

    test "an estimated total never produces an added/removed count", %{conn: conn} do
      Fixtures.sql!("CREATE TABLE pk_db_big (id int PRIMARY KEY, label text)")
      Fixtures.sql!("INSERT INTO pk_db_big SELECT n, 'r' FROM generate_series(1, 100500) n")
      Fixtures.sql!("ANALYZE pk_db_big")
      {:ok, view, _html} = live(conn, "/en/admin/db/public/pk_db_big")

      Fixtures.sql!("DELETE FROM pk_db_big WHERE id > 100000")
      Fixtures.sql!("UPDATE pk_db_big SET label = 'edited' WHERE id = 1")
      Fixtures.sql!("ANALYZE pk_db_big")
      send(view.pid, :debounced_refresh)

      assert texts(render(view), "#flash-info") == ["Data updated"]
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "an unknown message changes nothing on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/public/phoenix_kit_settings")
      before = render(view)

      send(view.pid, :some_random_atom)
      send(view.pid, {:weird, :tuple})

      assert render(view) == before
    end
  end
end
