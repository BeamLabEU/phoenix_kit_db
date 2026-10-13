defmodule PhoenixKitDb.Web.ActivityLive do
  @moduledoc """
  Live activity monitor for database changes.

  Shows real-time INSERT, UPDATE, DELETE operations with row data and
  per-key diff highlighting, for every table that has a notification trigger.
  A table gets its trigger the first time its Show page is opened, so a table
  nobody has opened does not appear here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitDb.Gettext

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitDb
  alias PhoenixKitDb.Cells
  alias PhoenixKitDb.Listener

  require Logger

  @operations ~w(INSERT UPDATE DELETE)
  @max_log 100

  # Notifications are buffered and turned into log entries on a timer, never
  # one by one. An entry costs a row lookup and a re-render; a bulk update
  # sends one notification per row, and paying that price per message leaves
  # the mailbox so far behind that a click on Pause waits for all of it.
  # Buffering a message is constant work, so the mailbox drains at once and
  # the click is handled next. The buffer holds no more than the log can
  # show; past that the oldest buffered event is dropped and counted.
  @max_buffered @max_log
  @flush_interval_ms 250
  @buffer_key :phoenix_kit_db_activity_buffer
  @empty_buffer %{events: [], count: 0, dropped: 0, scheduled?: false}

  # The table list is loaded in `handle_params/3` only. Both callbacks run on
  # the dead render and again on the connected one, so loading it here as well
  # would double the query.
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Listener.subscribe_all()
      # Make sure the trigger function exists with the row_id payload format.
      update_trigger_function()
    end

    socket =
      socket
      |> assign(:page_section, gettext("DB"))
      |> assign(:page_section_path, PhoenixKitDb.Paths.index())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, gettext("Activity"))
      |> assign(:activity_log, [])
      |> assign(:paused, false)
      |> assign(:filter_table, nil)
      |> assign(:filter_operation, nil)
      |> assign(:tables, [])
      |> assign(:row_states, %{})
      |> assign(:skipped, 0)
      |> put_private(@buffer_key, @empty_buffer)

    {:ok, socket}
  end

  # `?table=` preselects the table filter. The filters themselves change over
  # `phx-change` without a patch, so this runs once per render pass.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:tables, load_tables())
     |> assign(:filter_table, table_filter(params["table"]))}
  end

  # The whole list, not a page of it: `list_tables/1` clamps its page size, and
  # a table missing here cannot be picked, nor shown as selected by a
  # `?table=` link.
  defp load_tables do
    PhoenixKitDb.list_table_names()
    |> Enum.map(fn {schema, table} -> "#{schema}.#{table}" end)
    |> Enum.sort()
  end

  @impl true
  def handle_info({:table_changed, schema, table, operation, row_id}, socket) do
    if not socket.assigns.paused and matches_filters?(socket, schema, table, operation) do
      {:noreply, buffer_event(socket, {schema, table, operation, row_id})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:flush_activity, socket) do
    {:noreply, flush_buffer(socket)}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Pausing discards what is still buffered, so nothing is added to the log
  # after the click; the discarded events are counted as skipped.
  @impl true
  def handle_event("toggle_pause", _, socket) do
    if socket.assigns.paused do
      {:noreply, assign(socket, :paused, false)}
    else
      buffer = socket.private[@buffer_key]

      {:noreply,
       socket
       |> put_private(@buffer_key, %{@empty_buffer | scheduled?: buffer.scheduled?})
       |> assign(:skipped, socket.assigns.skipped + buffer.count + buffer.dropped)
       |> assign(:paused, true)}
    end
  end

  @impl true
  def handle_event("clear_log", _, socket) do
    socket =
      socket
      |> assign(:activity_log, [])
      |> assign(:row_states, %{})
      |> assign(:skipped, 0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_table, table_filter(params["table"]))
     |> assign(:filter_operation, operation_filter(params["operation"]))}
  end

  defp table_filter(table) when is_binary(table) and table != "", do: table
  defp table_filter(_table), do: nil

  defp operation_filter(operation) when operation in @operations, do: operation
  defp operation_filter(_operation), do: nil

  # The buffer lives in `socket.private`, not in an assign: an assign changed
  # on every message would make every message a render.
  defp buffer_event(socket, event) do
    buffer = socket.private[@buffer_key]

    buffer =
      if buffer.count >= @max_buffered do
        %{
          buffer
          | events: [event | List.delete_at(buffer.events, -1)],
            dropped: buffer.dropped + 1
        }
      else
        %{buffer | events: [event | buffer.events], count: buffer.count + 1}
      end

    put_private(socket, @buffer_key, schedule_flush(buffer))
  end

  defp schedule_flush(%{scheduled?: true} = buffer), do: buffer

  defp schedule_flush(buffer) do
    Process.send_after(self(), :flush_activity, @flush_interval_ms)
    %{buffer | scheduled?: true}
  end

  defp flush_buffer(socket) do
    buffer = socket.private[@buffer_key]
    socket = put_private(socket, @buffer_key, @empty_buffer)

    # Buffered newest first; entries are built oldest first so each row's
    # diff is computed against the state the event before it left behind.
    {entries, row_states} =
      buffer.events
      |> Enum.reverse()
      |> Enum.reduce({[], socket.assigns.row_states}, fn event, {entries, row_states} ->
        {entry, row_states} = build_entry(event, row_states)
        {[entry | entries], row_states}
      end)

    activity_log = Enum.take(entries ++ socket.assigns.activity_log, @max_log)

    socket
    |> assign(:activity_log, activity_log)
    |> assign(:row_states, prune_row_states(row_states, activity_log))
    |> assign(:skipped, socket.assigns.skipped + buffer.dropped)
  end

  # A remembered row only serves the diff of a later event for the same row,
  # and it is kept only while an entry for that row is still on the page.
  defp prune_row_states(row_states, activity_log) do
    visible = MapSet.new(activity_log, &{&1.schema, &1.table, &1.row_id})

    Map.filter(row_states, fn {row_key, _row} -> MapSet.member?(visible, row_key) end)
  end

  defp update_trigger_function do
    # CREATE OR REPLACE the function with the latest payload format.
    # phoenix_kit_settings is always present in a host with PhoenixKit installed.
    PhoenixKitDb.ensure_trigger("public", "phoenix_kit_settings")
  end

  defp build_entry({schema, table, operation, row_id}, row_states) do
    row_key = {schema, table, row_id}
    row_data = fetch_row_data(schema, table, operation, row_id)
    previous_state = Map.get(row_states, row_key)
    {changed_keys, new_keys} = compute_keys(operation, row_data, previous_state)

    entry = %{
      id: System.unique_integer([:positive]),
      timestamp: UtilsDate.utc_now(),
      schema: schema,
      table: table,
      operation: operation,
      row_id: row_id,
      row_data: row_data,
      changed_keys: changed_keys,
      new_keys: new_keys
    }

    {entry, update_row_states(row_states, row_key, row_data, row_id)}
  end

  defp fetch_row_data(_schema, _table, op, _row_id) when op not in ["INSERT", "UPDATE"], do: nil
  defp fetch_row_data(_schema, _table, _op, nil), do: nil

  defp fetch_row_data(schema, table, _op, row_id) do
    case PhoenixKitDb.fetch_row(schema, table, row_id) do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp compute_keys(_operation, nil, _previous), do: {MapSet.new(), MapSet.new()}

  defp compute_keys("INSERT", row_data, _previous) do
    {MapSet.new(), row_data |> Map.keys() |> MapSet.new()}
  end

  defp compute_keys(_op, _row_data, nil), do: {MapSet.new(), MapSet.new()}

  defp compute_keys(_op, row_data, previous_state) do
    compute_diff(previous_state, row_data)
  end

  defp update_row_states(states, _row_key, nil, _row_id), do: states
  defp update_row_states(states, _row_key, _row_data, nil), do: states

  defp update_row_states(states, row_key, row_data, _row_id),
    do: Map.put(states, row_key, row_data)

  defp compute_diff(previous, current) do
    all_keys = MapSet.union(MapSet.new(Map.keys(previous)), MapSet.new(Map.keys(current)))

    Enum.reduce(all_keys, {MapSet.new(), MapSet.new()}, fn key, {changed, new} ->
      prev_val = Map.get(previous, key)
      curr_val = Map.get(current, key)

      cond do
        is_nil(prev_val) && !is_nil(curr_val) ->
          {changed, MapSet.put(new, key)}

        prev_val != curr_val ->
          {MapSet.put(changed, key), new}

        true ->
          {changed, new}
      end
    end)
  end

  defp matches_filters?(socket, schema, table, operation) do
    full_table_name = "#{schema}.#{table}"

    table_match =
      case socket.assigns.filter_table do
        nil -> true
        filter -> full_table_name == filter
      end

    operation_match =
      case socket.assigns.filter_operation do
        nil -> true
        filter -> operation == filter
      end

    table_match and operation_match
  end

  def operation_badge_class("INSERT"), do: "badge-success"
  def operation_badge_class("UPDATE"), do: "badge-warning"
  def operation_badge_class("DELETE"), do: "badge-error"
  def operation_badge_class(_), do: "badge-ghost"

  # Text for one cell of an entry's row. `Cells.format/2` is total, which
  # matters here more than anywhere: these rows come from arbitrary tables and
  # a raise while rendering them takes the feed down.
  def format_value(value), do: Cells.format(value, pretty: true)

  def collection?(value), do: Cells.collection?(value)

  def key_changed?(entry, key), do: MapSet.member?(entry.changed_keys, key)
  def key_new?(entry, key), do: MapSet.member?(entry.new_keys, key)

  def field_highlight_class(entry, key) do
    cond do
      key_new?(entry, key) -> "bg-success/20 border-l-2 border-success"
      key_changed?(entry, key) -> "bg-warning/20 border-l-2 border-warning"
      true -> ""
    end
  end
end
