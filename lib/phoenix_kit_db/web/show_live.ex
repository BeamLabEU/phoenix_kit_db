defmodule PhoenixKitDb.Web.ShowLive do
  @moduledoc """
  Table detail view with paginated row browsing and live updates via
  PostgreSQL `LISTEN/NOTIFY`. When data in the viewed table changes the
  view refreshes automatically (debounced).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitDb.Gettext

  alias PhoenixKitDb
  alias PhoenixKitDb.Cells
  alias PhoenixKitDb.Listener
  alias PhoenixKitDb.Paths

  require Logger

  @default_per_page 20
  @allowed_per_page [10, 20, 50, 100, 200]
  @refresh_debounce_ms 1000
  @highlight_ms 3000

  # The scrollbar's page markers are one DOM node each. A table of a million
  # rows has tens of thousands of pages, so only this many evenly spaced
  # markers are rendered, whatever the table size.
  @max_page_markers 25

  # The preview is loaded in `handle_params/3` only. Both callbacks run on the
  # dead render and again on the connected one, so loading it here as well
  # would double every query, the row count included.
  @impl true
  def mount(%{"schema" => schema, "table" => table}, _session, socket) do
    socket =
      socket
      |> assign(:page_section, gettext("DB"))
      |> assign(:page_section_path, Paths.index())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, "#{schema}.#{table}")
      # ^ schema/table are programmatic identifiers — not translatable.
      |> assign(:schema, schema)
      |> assign(:table, table)
      |> assign(:highlighted_rows, [])
      |> assign(:refresh_scheduled, false)
      |> assign(:live_updates, :pending)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    %{schema: schema, table: table} = socket.assigns
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    preview = PhoenixKitDb.table_preview(schema, table, %{page: page, per_page: per_page})

    if preview.columns == [] do
      {:noreply, table_not_found(socket)}
    else
      {:noreply,
       socket
       |> assign(:per_page, per_page)
       |> assign(:preview, preview)
       |> assign(:highlighted_rows, [])
       |> put_private(:highlight_ref, nil)
       |> setup_live_updates()}
    end
  end

  # Runs once, on the connected render, AFTER the first `table_preview/3`.
  # Standard PubSub practice is subscribe-before-read, but here we want to
  # validate the table exists before leaking a subscription on bogus
  # identifiers. Cost: a broadcast in the gap is dropped; the next
  # `:table_changed` arrival catches the LV up.
  defp setup_live_updates(%{assigns: %{live_updates: :pending}} = socket) do
    if connected?(socket) do
      %{schema: schema, table: table} = socket.assigns
      Listener.subscribe(schema, table)
      assign(socket, :live_updates, install_trigger(schema, table))
    else
      socket
    end
  end

  defp setup_live_updates(socket), do: socket

  defp install_trigger(schema, table) do
    case PhoenixKitDb.ensure_trigger(schema, table) do
      :ok ->
        :on

      {:error, reason} ->
        # Trigger install failed (the table lock was not granted in time, DB
        # permissions, a transient error). The LV stays usable and says so;
        # the next view of the table tries again.
        Logger.warning(
          "[#{inspect(__MODULE__)}] ensure_trigger(#{inspect(schema)}, " <>
            "#{inspect(table)}) failed: #{inspect(reason)}"
        )

        :unavailable
    end
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

    new_preview =
      PhoenixKitDb.table_preview(socket.assigns.schema, socket.assigns.table, %{
        page: old_preview.page,
        per_page: socket.assigns.per_page
      })

    if new_preview.columns == [] do
      {:noreply, table_not_found(socket)}
    else
      {added_count, removed_count, changed_on_page} = detect_changes(old_preview, new_preview)
      highlighted = find_new_or_changed_rows(old_preview, new_preview)
      ref = make_ref()

      socket =
        socket
        |> add_change_notification(added_count, removed_count, changed_on_page)
        |> assign(:preview, new_preview)
        |> assign(:highlighted_rows, highlighted)
        |> put_private(:highlight_ref, ref)

      if highlighted != [] do
        Process.send_after(self(), {:clear_highlights, ref}, @highlight_ms)
      end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:clear_highlights, ref}, socket) do
    if socket.private[:highlight_ref] == ref do
      {:noreply, assign(socket, :highlighted_rows, [])}
    else
      {:noreply, socket}
    end
  end

  # Defensive catch-all so a stray PubSub broadcast can't crash the LV.
  # Logs at :debug to stay observable in dev but quiet in prod.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp table_not_found(socket) do
    socket
    |> put_flash(
      :error,
      gettext("Table %{schema}.%{table} not found",
        schema: socket.assigns.schema,
        table: socket.assigns.table
      )
    )
    |> push_navigate(to: Paths.index())
  end

  defp schedule_debounced_refresh(socket) do
    if socket.assigns[:refresh_scheduled] do
      socket
    else
      Process.send_after(self(), :debounced_refresh, @refresh_debounce_ms)
      assign(socket, :refresh_scheduled, true)
    end
  end

  @doc """
  The pages that get a marker beside the scrollbar: all of them while they
  fit in #{@max_page_markers}, otherwise that many evenly spaced ones, always
  including the first and the last.
  """
  @spec page_markers(pos_integer()) :: [pos_integer()]
  def page_markers(total_pages) when total_pages <= @max_page_markers do
    Enum.to_list(1..max(total_pages, 1))
  end

  def page_markers(total_pages) do
    last = @max_page_markers - 1

    Enum.map(0..last, fn index -> 1 + round(index * (total_pages - 1) / last) end)
  end

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

  # An estimated total drifts between two reads without a single row having
  # changed, so it says nothing about rows added or removed.
  defp detect_changes(old_preview, new_preview) do
    changed_on_page = old_preview.rows != new_preview.rows

    if old_preview.row_count_approx or new_preview.row_count_approx do
      {0, 0, changed_on_page}
    else
      added_count = max(0, new_preview.row_count - old_preview.row_count)
      removed_count = max(0, old_preview.row_count - new_preview.row_count)

      {added_count, removed_count, changed_on_page}
    end
  end

  defp find_new_or_changed_rows(old_preview, new_preview) do
    old_by_key = rows_by_key(old_preview)

    for {key, row} <- rows_by_key(new_preview), Map.get(old_by_key, key) != row do
      key
    end
  end

  defp rows_by_key(%{rows: rows, primary_key: primary_key}) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {row, index} -> {row_key(row, index, primary_key), row} end)
  end

  @doc """
  What tells a row apart from the others on its page: the values of the
  table's primary key columns, or its position when the table has no usable
  primary key.
  """
  @spec row_key(map(), non_neg_integer(), [String.t()]) :: term()
  def row_key(_row, index, []), do: {:index, index}
  def row_key(row, _index, primary_key), do: Enum.map(primary_key, &Map.get(row, &1))

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
    messages ++ [ngettext("%{count} row added", "%{count} rows added", added)]
  end

  defp append_removed_message(messages, 0), do: messages

  defp append_removed_message(messages, removed) do
    messages ++ [ngettext("%{count} row removed", "%{count} rows removed", removed)]
  end

  defp append_updated_message(messages, 0, 0, true) do
    messages ++ [gettext("Data updated")]
  end

  defp append_updated_message(messages, _added, _removed, _changed), do: messages

  def row_highlighted?(row, index, primary_key, highlighted_rows) do
    highlighted_rows != [] and row_key(row, index, primary_key) in highlighted_rows
  end

  defp format_cell(value), do: Cells.format(value)
end
