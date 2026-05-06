defmodule PhoenixKitDb.Web.ActivityLive do
  @moduledoc """
  Live activity monitor for database changes.

  Shows real-time INSERT, UPDATE, DELETE operations across all tables
  with full row data and per-key diff highlighting.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitDb
  alias PhoenixKitDb.Listener

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Listener.subscribe_all()
      # Make sure the trigger function exists with the row_id payload format.
      update_trigger_function()
    end

    tables = load_tables()

    initial_table_filter =
      case params["table"] do
        nil -> nil
        "" -> nil
        table -> table
      end

    socket =
      socket
      |> assign(:page_title, "Live Activity")
      |> assign(:activity_log, [])
      |> assign(:paused, false)
      |> assign(:filter_table, initial_table_filter)
      |> assign(:filter_operation, nil)
      |> assign(:tables, tables)
      |> assign(:row_states, %{})

    {:ok, socket}
  end

  defp load_tables do
    result = PhoenixKitDb.list_tables(%{page: 1, per_page: 1000})

    result.entries
    |> Enum.map(fn t -> "#{t.schema}.#{t.name}" end)
    |> Enum.sort()
  end

  @impl true
  def handle_info({:table_changed, schema, table, operation, row_id}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      socket = add_activity_entry(socket, schema, table, operation, row_id)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  @impl true
  def handle_event("clear_log", _, socket) do
    socket =
      socket
      |> assign(:activity_log, [])
      |> assign(:row_states, %{})

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_table", %{"table" => table}, socket) do
    filter = if table == "", do: nil, else: table
    {:noreply, assign(socket, :filter_table, filter)}
  end

  @impl true
  def handle_event("filter_operation", %{"operation" => operation}, socket) do
    filter = if operation == "", do: nil, else: operation
    {:noreply, assign(socket, :filter_operation, filter)}
  end

  defp update_trigger_function do
    # CREATE OR REPLACE the function with the latest payload format.
    # phoenix_kit_settings is always present in a host with PhoenixKit installed.
    PhoenixKitDb.ensure_trigger("public", "phoenix_kit_settings")
  end

  defp add_activity_entry(socket, schema, table, operation, row_id) do
    if matches_filters?(socket, schema, table, operation) do
      timestamp = UtilsDate.utc_now()
      row_key = {schema, table, row_id}

      row_data =
        if operation in ["INSERT", "UPDATE"] and row_id do
          case PhoenixKitDb.fetch_row(schema, table, row_id) do
            {:ok, row} -> row
            _ -> nil
          end
        else
          nil
        end

      previous_state = Map.get(socket.assigns.row_states, row_key)

      {changed_keys, new_keys} =
        if row_data && previous_state do
          compute_diff(previous_state, row_data)
        else
          {MapSet.new(), MapSet.new()}
        end

      new_keys =
        if operation == "INSERT" && row_data do
          row_data |> Map.keys() |> MapSet.new()
        else
          new_keys
        end

      entry = %{
        id: System.unique_integer([:positive]),
        timestamp: timestamp,
        schema: schema,
        table: table,
        operation: operation,
        row_id: row_id,
        row_data: row_data,
        changed_keys: changed_keys,
        new_keys: new_keys
      }

      row_states =
        if row_data && row_id do
          Map.put(socket.assigns.row_states, row_key, row_data)
        else
          socket.assigns.row_states
        end

      activity_log =
        [entry | socket.assigns.activity_log]
        |> Enum.take(100)

      socket
      |> assign(:activity_log, activity_log)
      |> assign(:row_states, row_states)
    else
      socket
    end
  end

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

  def format_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  def format_value(value) when is_list(value), do: inspect(value, pretty: true)

  def format_value(value) when is_binary(value) do
    if String.valid?(value) do
      if byte_size(value) > 200, do: String.slice(value, 0, 200) <> "...", else: value
    else
      inspect(value)
    end
  end

  def format_value(value), do: inspect(value)

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
