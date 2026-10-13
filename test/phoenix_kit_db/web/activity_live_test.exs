defmodule PhoenixKitDb.Web.ActivityLiveTest do
  @moduledoc """
  The DB Activity feed page, driven through the real LiveView.

  Notifications are buffered and turned into entries on a timer. Tests that
  are not about the timer send `:flush_activity` themselves instead of waiting
  for it.
  """
  use PhoenixKitDb.LiveCase

  alias PhoenixKitDb.Cells

  setup %{conn: conn} do
    %{conn: put_test_scope(conn, fake_scope())}
  end

  defp notify(view, schema \\ "public", table, operation, row_id) do
    send(view.pid, {:table_changed, schema, table, operation, row_id})
  end

  defp flush(view) do
    send(view.pid, :flush_activity)
    render(view)
  end

  # `%{column => text}` for the newest entry's row data. The key cell also
  # carries the new/changed badge, so only its first word is the column name.
  defp newest_entry_row(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity-log > div:first-child table tr")
    |> Map.new(fn row ->
      [key, value] =
        row |> LazyHTML.query("td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      {key |> String.split() |> hd(), value}
    end)
  end

  defp newest_entry_badges(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity-log > div:first-child table tr")
    |> Enum.flat_map(fn row ->
      [key | _] =
        row |> LazyHTML.query("td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      case String.split(key) do
        [column, badge] -> [{column, badge}]
        [_column] -> []
      end
    end)
    |> Map.new()
  end

  describe "mount" do
    test "renders empty state and gettext-wrapped controls", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/db/activity")

      # Heading
      assert html =~ "Live Database Activity"

      # Empty-state copy (delta — gettext-wrapped)
      assert html =~ "Waiting for database activity..."
      assert html =~ "INSERT, UPDATE, and DELETE operations will appear here in real-time"

      # Pause/Clear buttons (Pause icon renders when not paused; PhoenixKit
      # renders Heroicons as <span class="hero-..."> not <svg>).
      assert has_element?(view, ~s|button[phx-click="toggle_pause"]|, "Pause")
      assert has_element?(view, ~s|button[phx-click="clear_log"]|, "Clear")
      assert html =~ ~r/<span[^>]*hero-pause/
    end

    test "says which tables it watches, and does not claim all of them", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      assert html =~ "Showing changes to tables that have been opened in the DB explorer"
      assert html =~ "A table is watched from the first time its page is opened."
      refute html =~ "all tables in real-time"
    end

    test "the header trail is DB / Activity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      assert assigns(view).page_section == "DB"
      assert assigns(view).page_section_path == "/en/admin/db"
      assert assigns(view).page_crumbs == []
      assert assigns(view).page_title == "Activity"
    end

    test "renders the filter form labels", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      # Filter labels (delta — gettext-wrapped)
      assert html =~ ~r/<span[^>]*fieldset-legend[^>]*>\s*Table\s*</
      assert html =~ ~r/<span[^>]*fieldset-legend[^>]*>\s*Operation\s*</

      # "All tables" / "All" defaults
      assert html =~ "All tables"
    end

    test "0 events counter rendered when log is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      # ngettext singular when count == 0 ("0 events")
      assert html =~ "0 events"
    end
  end

  describe "table filter options" do
    test "every table is offered, not just the first hundred", %{conn: conn} do
      names = Enum.map(PhoenixKitDb.list_table_names(), fn {s, t} -> "#{s}.#{t}" end)
      assert length(names) > 100

      {:ok, _view, html} = live(conn, "/en/admin/db/activity")

      options =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s|#activity-filters select[name="table"] option|)
        |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

      assert options == ["" | Enum.sort(names)]
    end

    test "a ?table= link selects its table wherever it sorts", %{conn: conn} do
      last =
        PhoenixKitDb.list_table_names()
        |> Enum.map(fn {s, t} -> "#{s}.#{t}" end)
        |> Enum.sort()
        |> List.last()

      {:ok, view, _html} = live(conn, "/en/admin/db/activity?table=#{last}")

      assert has_element?(
               view,
               ~s|#activity-filters select[name="table"] option[selected][value="#{last}"]|
             )

      assert assigns(view).filter_table == last
    end

    test "a ?table= link naming an unlisted table still shows it as the selection",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity?table=public.pk_db_gone")

      assert has_element?(
               view,
               ~s|#activity-filters select[name="table"] option[selected][value="public.pk_db_gone"]|
             )
    end
  end

  describe "the page loads its data once per render pass" do
    test "one table listing for the dead render and one for the connected one", %{conn: conn} do
      {{:ok, _view, _html}, statements} =
        QueryCounter.capture(fn -> live(conn, "/en/admin/db/activity") end)

      listings = Enum.filter(statements, &(&1 =~ "pg_stat_user_tables" and &1 =~ "ORDER BY"))
      assert length(listings) == 2
    end
  end

  describe "filters, through the form" do
    test "both selects sit in one form that sends one event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      assert has_element?(
               view,
               ~s|form#activity-filters[phx-change="filter"] select[name="table"]|
             )

      assert has_element?(
               view,
               ~s|form#activity-filters[phx-change="filter"] select[name="operation"]|
             )

      # No select carries its own phx-change: outside a form it would never fire.
      refute has_element?(view, "select[phx-change]")
    end

    test "filtering by table keeps that table and drops the others", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      html =
        view
        |> form("#activity-filters", %{"table" => "public.phoenix_kit_settings"})
        |> render_change()

      assert html =~ ~s(<option value="public.phoenix_kit_settings" selected)

      notify(view, "phoenix_kit_users", "INSERT", "1")
      assert flush(view) =~ "0 events"

      notify(view, "phoenix_kit_settings", "DELETE", "1")
      html = flush(view)
      assert html =~ "1 event"
      assert texts(html, "#activity-log a") == ["public.phoenix_kit_settings"]
    end

    test "filtering by operation keeps that operation and drops the others", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      html = view |> form("#activity-filters", %{"operation" => "DELETE"}) |> render_change()
      assert html =~ ~s(<option value="DELETE" selected)

      notify(view, "phoenix_kit_settings", "INSERT", "1")
      assert flush(view) =~ "0 events"

      notify(view, "phoenix_kit_settings", "DELETE", "1")
      html = flush(view)
      assert texts(html, "#activity-log .badge-error") == ["DELETE"]
    end

    test "both filters apply together, and clearing them shows everything again",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      view
      |> form("#activity-filters", %{
        "table" => "public.phoenix_kit_settings",
        "operation" => "UPDATE"
      })
      |> render_change()

      notify(view, "phoenix_kit_settings", "DELETE", "1")
      notify(view, "phoenix_kit_users", "UPDATE", "1")
      assert flush(view) =~ "0 events"

      notify(view, "phoenix_kit_settings", "UPDATE", "1")
      assert flush(view) =~ "1 event"

      view |> form("#activity-filters", %{"table" => "", "operation" => ""}) |> render_change()

      notify(view, "phoenix_kit_users", "DELETE", "1")
      assert flush(view) =~ "2 events"
    end
  end

  describe ":table_changed message handling" do
    test "an event becomes an entry on the flush timer, without anyone asking", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "phoenix_kit_settings", "DELETE", "0")

      # No `:flush_activity` is sent here: only the page's own timer can
      # turn the buffered event into an entry.
      html =
        Enum.find_value(1..100, fn _attempt ->
          html = render(view)
          if html =~ "1 event", do: html, else: Process.sleep(50) && nil
        end)

      assert html, "the buffered event never reached the log"
      assert texts(html, "#activity-log .badge-error") == ["DELETE"]
    end

    test "ignores entries when paused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()

      notify(view, "phoenix_kit_settings", "UPDATE", "1")

      assert flush(view) =~ "0 events"
    end

    test "an INSERT whose row cannot be found says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "phoenix_kit_settings", "INSERT", Ecto.UUID.generate())
      html = flush(view)

      assert html =~ "1 event"
      assert html =~ "Row data not available"
    end

    test "a DELETE shows that the row is gone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "phoenix_kit_settings", "DELETE", Ecto.UUID.generate())

      assert flush(view) =~ "Row deleted (data not available)"
    end
  end

  describe "entries carrying row data" do
    test "an INSERT shows the row with secrets masked and marks every key new", %{conn: conn} do
      id = Fixtures.create_secrets_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "pk_db_secrets", "INSERT", Integer.to_string(id))
      html = flush(view)

      row = newest_entry_row(html)

      for column <- ~w(hashed_password API_KEY refresh_token webhook_secret password_salt) do
        assert row[column] == Cells.masked_placeholder(), "#{column} is not masked"
      end

      assert row["reset_token"] == "null"
      assert row["email"] == "visible@example.com"
      assert row["id"] == Integer.to_string(id)

      assert newest_entry_badges(html)["email"] == "new"

      state = inspect(assigns(view), limit: :infinity, printable_limit: :infinity)

      for marker <- Fixtures.secret_markers() do
        refute html =~ marker, "#{marker} is in the rendered entry"
        refute state =~ marker, "#{marker} is in the LiveView's assigns"
      end
    end

    test "an UPDATE marks only the keys that changed", %{conn: conn} do
      id = Fixtures.create_secrets_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "pk_db_secrets", "INSERT", Integer.to_string(id))
      flush(view)

      Fixtures.sql!("UPDATE pk_db_secrets SET note = 'edited note'")
      notify(view, "pk_db_secrets", "UPDATE", Integer.to_string(id))
      html = flush(view)

      assert html =~ "2 events"
      assert newest_entry_row(html)["note"] == "edited note"
      assert newest_entry_badges(html) == %{"note" => "changed"}
    end

    test "every column type renders, and none of them takes the feed down", %{conn: conn} do
      uuid = Fixtures.create_types_table()
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "pk_db_types", "INSERT", uuid)
      html = flush(view)

      row = newest_entry_row(html)

      scalars = Map.drop(Fixtures.expected_type_texts(), ~w(ints texts uuids doc))

      for {column, expected} <- scalars do
        assert row[column] == expected, "column #{column} rendered #{inspect(row[column])}"
      end

      # Arrays and JSON fold behind a disclosure, pretty-printed.
      assert row["ints"] =~ "[ ... ]"
      assert row["ints"] =~ "1,\n  2,\n  3"
      assert row["doc"] =~ "{ ... }"
      assert row["doc"] =~ ~s("b": [)
      assert row["uuids"] =~ Fixtures.element_uuid()
      assert row["missing"] == "null"
      assert row["spot"] =~ "Postgrex.Point"

      # A decimal or a timestamp is a value, not a `{ ... }` disclosure.
      refute row["amount"] =~ "..."
      refute row["stamp"] =~ "..."
    end
  end

  describe "a burst of notifications" do
    setup do
      Fixtures.sql!("CREATE TABLE pk_db_burst (id int PRIMARY KEY, label text)")
      Fixtures.sql!("INSERT INTO pk_db_burst SELECT n, 'r' FROM generate_series(1, 400) n")
      :ok
    end

    test "is cut to what the log can show, and the rest is counted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      {html, statements} =
        QueryCounter.capture(fn ->
          for id <- 1..400, do: notify(view, "pk_db_burst", "INSERT", Integer.to_string(id))
          flush(view)
        end)

      assert html =~ "100 events"

      assert texts(html, "#activity-skipped") == [
               "300 events skipped: changes arrived faster than this page can show them."
             ]

      # The newest hundred survive, newest first.
      ids = texts(html, "#activity-log .badge-outline")
      assert hd(ids) == "id: 400"
      assert List.last(ids) == "id: 301"

      # One row lookup per SHOWN entry, none for the three hundred dropped.
      assert QueryCounter.count(statements, ~s|SELECT * FROM "public"."pk_db_burst"|) == 100
    end

    test "remembered rows are pruned to the entries still on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      for id <- 1..100, do: notify(view, "pk_db_burst", "INSERT", Integer.to_string(id))
      flush(view)
      assert map_size(assigns(view).row_states) == 100

      for id <- 101..160, do: notify(view, "pk_db_burst", "INSERT", Integer.to_string(id))
      flush(view)

      remembered = assigns(view).row_states |> Map.keys() |> Enum.map(&elem(&1, 2))
      shown = Enum.map(assigns(view).activity_log, & &1.row_id)

      assert Enum.sort(remembered) == Enum.sort(shown)
      assert length(shown) == 100
      assert "61" in remembered
      refute "60" in remembered
    end

    test "Pause stops the feed without working through the backlog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      {html, statements} =
        QueryCounter.capture(fn ->
          for id <- 1..400, do: notify(view, "pk_db_burst", "INSERT", Integer.to_string(id))
          view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()
          flush(view)
        end)

      # Nothing buffered before the click is added after it.
      assert html =~ ~r/Paused\s*[^<]*0 events captured/
      assert QueryCounter.count(statements, ~s|SELECT * FROM "public"."pk_db_burst"|) == 0

      assert texts(html, "#activity-skipped") == [
               "400 events skipped: changes arrived faster than this page can show them."
             ]
    end

    test "Clear resets the skipped count with the log", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      for id <- 1..150, do: notify(view, "pk_db_burst", "INSERT", Integer.to_string(id))
      flush(view)
      assert has_element?(view, "#activity-skipped")

      html = view |> element(~s|button[phx-click="clear_log"]|) |> render_click()

      assert texts(html, "#activity-skipped") == []
      assert assigns(view).row_states == %{}
    end
  end

  describe "controls" do
    test "toggle_pause flips the badge state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/db/activity")

      # Initially watching
      assert html =~ "Showing changes to tables"

      paused_html = view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()
      assert paused_html =~ ~r/Paused\s*[^<]*0 events captured/
      assert has_element?(view, ~s|button[phx-click="toggle_pause"]|, "Resume")

      resumed_html = view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()
      assert resumed_html =~ "Showing changes to tables"
    end

    test "resuming picks the feed up again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()
      view |> element(~s|button[phx-click="toggle_pause"]|) |> render_click()

      notify(view, "phoenix_kit_settings", "DELETE", "1")
      assert flush(view) =~ "1 event"
    end

    test "clear_log empties the activity feed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")

      notify(view, "phoenix_kit_settings", "DELETE", "0")
      assert flush(view) =~ "1 event"

      cleared_html = view |> element(~s|button[phx-click="clear_log"]|) |> render_click()
      assert cleared_html =~ "0 events"
      assert cleared_html =~ "Waiting for database activity..."
    end
  end

  describe "handle_info catch-all (defensive)" do
    test "an unknown message changes nothing on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/db/activity")
      before = render(view)

      send(view.pid, :random_atom)
      send(view.pid, {:bogus, :tuple})

      assert render(view) == before
    end
  end
end
