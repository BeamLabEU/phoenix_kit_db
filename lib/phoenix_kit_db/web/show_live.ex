defmodule PhoenixKitDb.Web.ShowLive do
  @moduledoc """
  Table detail view with paginated row browsing and live updates via
  PostgreSQL `LISTEN/NOTIFY`. When data in the viewed table changes the
  view refreshes automatically (debounced).
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitDb
  alias PhoenixKitDb.Listener
  alias PhoenixKitDb.Paths

  require Logger

  @default_per_page 20
  @allowed_per_page [10, 20, 50, 100, 200]
  @refresh_debounce_ms 1000

  @impl true
  def mount(%{"schema" => schema, "table" => table} = params, _session, socket) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    preview = PhoenixKitDb.table_preview(schema, table, %{page: page, per_page: per_page})

    if preview.columns == [] do
      # Either the schema/table contains unsafe characters, or the
      # table doesn't exist. Bail to /admin/db with a flash rather than
      # render an empty grid.
      {:ok,
       socket
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitWeb.Gettext, "Table %{schema}.%{table} not found",
           schema: schema,
           table: table
         )
       )
       |> push_navigate(to: PhoenixKitDb.Paths.index())}
    else
      if connected?(socket), do: setup_live_updates(schema, table)

      socket =
        socket
        |> assign(:page_title, "#{schema}.#{table}")
        # ^ schema/table are programmatic identifiers — not translatable.
        |> assign(:schema, schema)
        |> assign(:table, table)
        |> assign(:per_page, per_page)
        |> assign(:preview, preview)
        |> assign(:highlighted_rows, [])
        |> assign(:refresh_scheduled, false)

      {:ok, socket}
    end
  end

  # Note: subscribe runs AFTER table_preview/3 in mount above. Standard
  # PubSub practice is subscribe-before-read, but here we want to
  # validate the table exists before leaking a subscription on bogus
  # identifiers. Cost: a broadcast in the gap is dropped; the next
  # `:table_changed` arrival catches the LV up.
  defp setup_live_updates(schema, table) do
    Listener.subscribe(schema, table)

    case PhoenixKitDb.ensure_trigger(schema, table) do
      :ok ->
        :ok

      {:error, reason} ->
        # Trigger install failed (DB permissions, transient error, etc.).
        # The LV stays usable; live updates simply won't fire until
        # something else installs the trigger.
        Logger.warning(
          "[#{inspect(__MODULE__)}] ensure_trigger(#{inspect(schema)}, " <>
            "#{inspect(table)}) failed: #{inspect(reason)}"
        )
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    preview =
      PhoenixKitDb.table_preview(
        socket.assigns.schema,
        socket.assigns.table,
        %{page: page, per_page: per_page}
      )

    {:noreply,
     socket
     |> assign(:per_page, per_page)
     |> assign(:preview, preview)}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = parse_page(page)
    {:noreply, push_patch(socket, to: build_path(socket, %{page: page}))}
  end

  @impl true
  def handle_event("set_per_page", %{"per_page" => per_page}, socket) do
    per_page = parse_per_page(per_page)
    # Recalculate page to keep roughly the same position
    current_row = (socket.assigns.preview.page - 1) * socket.assigns.per_page
    new_page = max(1, div(current_row, per_page) + 1)

    {:noreply, push_patch(socket, to: build_path(socket, %{per_page: per_page, page: new_page}))}
  end

  @impl true
  def handle_info({:table_changed, schema, table, _operation, _row_id}, socket) do
    if schema == socket.assigns.schema and table == socket.assigns.table do
      {:noreply, schedule_debounced_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:debounced_refresh, socket) do
    socket = assign(socket, :refresh_scheduled, false)

    old_preview = socket.assigns.preview
    old_row_count = old_preview.row_count

    new_preview =
      PhoenixKitDb.table_preview(socket.assigns.schema, socket.assigns.table, %{
        page: old_preview.page,
        per_page: socket.assigns.per_page
      })

    {added_count, removed_count, changed_on_page} =
      detect_changes(old_preview.rows, new_preview.rows, old_row_count, new_preview.row_count)

    highlighted_ids = find_new_or_changed_rows(old_preview.rows, new_preview.rows)

    socket = add_change_notification(socket, added_count, removed_count, changed_on_page)

    socket =
      socket
      |> assign(:preview, new_preview)
      |> assign(:highlighted_rows, highlighted_ids)

    if highlighted_ids != [] do
      Process.send_after(self(), :clear_highlights, 3000)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_highlights, socket) do
    {:noreply, assign(socket, :highlighted_rows, [])}
  end

  # Defensive catch-all so a stray PubSub broadcast can't crash the LV.
  # Logs at :debug to stay observable in dev but quiet in prod.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp schedule_debounced_refresh(socket) do
    if socket.assigns[:refresh_scheduled] do
      socket
    else
      Process.send_after(self(), :debounced_refresh, @refresh_debounce_ms)
      assign(socket, :refresh_scheduled, true)
    end
  end

  def format_cell(value) when is_map(value), do: Jason.encode!(value)
  def format_cell(value) when is_list(value), do: inspect(value)

  def format_cell(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  def format_cell(value), do: to_string(value || "")

  defp parse_page(nil), do: 1
  defp parse_page(value) when is_integer(value) and value > 0, do: value

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp parse_per_page(nil), do: @default_per_page
  defp parse_per_page(value) when is_integer(value) and value in @allowed_per_page, do: value

  defp parse_per_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in @allowed_per_page -> int
      _ -> @default_per_page
    end
  end

  defp parse_per_page(_), do: @default_per_page

  defp build_path(socket, overrides) do
    overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    params =
      %{
        "page" => socket.assigns.preview.page,
        "per_page" => socket.assigns.per_page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {k, v} ->
        v in [nil, ""] or
          (k == "page" and v in [1, "1"]) or
          (k == "per_page" and v in [@default_per_page, to_string(@default_per_page)])
      end)
      |> Map.new()

    base = Paths.show(socket.assigns.schema, socket.assigns.table)

    if map_size(params) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end

  defp detect_changes(old_rows, new_rows, old_count, new_count) do
    added_count = max(0, new_count - old_count)
    removed_count = max(0, old_count - new_count)
    changed_on_page = rows_changed_on_page?(old_rows, new_rows)

    {added_count, removed_count, changed_on_page}
  end

  defp rows_changed_on_page?(old_rows, new_rows) do
    length(old_rows) != length(new_rows) or old_rows != new_rows
  end

  defp find_new_or_changed_rows(old_rows, new_rows) do
    old_by_id = rows_by_identifier(old_rows)
    new_by_id = rows_by_identifier(new_rows)

    new_ids =
      new_by_id
      |> Map.keys()
      |> Enum.filter(fn id -> not Map.has_key?(old_by_id, id) end)

    changed_ids =
      new_by_id
      |> Enum.filter(fn {id, row} ->
        case Map.get(old_by_id, id) do
          nil -> false
          old_row -> old_row != row
        end
      end)
      |> Enum.map(fn {id, _} -> id end)

    new_ids ++ changed_ids
  end

  defp rows_by_identifier(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      id = Map.get(row, "id") || Map.get(row, :id) || "idx_#{idx}"
      {id, row}
    end)
    |> Map.new()
  end

  defp add_change_notification(socket, 0, 0, false), do: socket

  defp add_change_notification(socket, added, removed, changed_on_page) do
    messages =
      []
      |> append_added_message(added)
      |> append_removed_message(removed)
      |> append_updated_message(added, removed, changed_on_page)

    if messages == [] do
      socket
    else
      put_flash(socket, :info, Enum.join(messages, ", "))
    end
  end

  defp append_added_message(messages, 0), do: messages

  defp append_added_message(messages, added) do
    messages ++
      [
        Gettext.ngettext(
          PhoenixKitWeb.Gettext,
          "%{count} row added",
          "%{count} rows added",
          added
        )
      ]
  end

  defp append_removed_message(messages, 0), do: messages

  defp append_removed_message(messages, removed) do
    messages ++
      [
        Gettext.ngettext(
          PhoenixKitWeb.Gettext,
          "%{count} row removed",
          "%{count} rows removed",
          removed
        )
      ]
  end

  defp append_updated_message(messages, 0, 0, true) do
    messages ++ [Gettext.gettext(PhoenixKitWeb.Gettext, "Data updated")]
  end

  defp append_updated_message(messages, _added, _removed, _changed), do: messages

  def row_highlighted?(row, highlighted_rows) do
    id = Map.get(row, "id") || Map.get(row, :id)
    id != nil and id in highlighted_rows
  end
end
