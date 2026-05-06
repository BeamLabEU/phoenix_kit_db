defmodule PhoenixKitDb.Web.IndexLive do
  @moduledoc """
  Admin DB index — lists all tables with stats.

  Subscribes to `phoenix_kit_db:all` for live updates; debounces refreshes
  so the page doesn't hammer the DB on busy systems.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitDb
  alias PhoenixKitDb.Listener
  alias PhoenixKitDb.Paths

  require Logger

  @refresh_debounce_ms 2000

  @impl true
  def mount(params, _session, socket) do
    page = parse_int(params["page"], 1)
    search = params["search"] || ""

    if connected?(socket) do
      Listener.subscribe_all()
    end

    tables = PhoenixKitDb.list_tables(%{page: page, search: search})

    socket =
      socket
      |> assign(:page_title, Gettext.gettext(PhoenixKitWeb.Gettext, "DB"))
      |> assign(:search, search)
      |> assign(:tables, tables)
      |> assign(:stats, PhoenixKitDb.database_stats())
      |> assign(:refresh_scheduled, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    search = params["search"] || ""

    tables = PhoenixKitDb.list_tables(%{page: page, search: search})

    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:tables, tables)}
  end

  @impl true
  def handle_event("search", %{"search" => value}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{search: value, page: 1}))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{page: page}))}
  end

  @impl true
  def handle_info({:table_changed, _schema, _table, _operation, _row_id}, socket) do
    {:noreply, schedule_debounced_refresh(socket)}
  end

  @impl true
  def handle_info(:debounced_refresh, socket) do
    socket = assign(socket, :refresh_scheduled, false)

    tables =
      PhoenixKitDb.list_tables(%{
        page: socket.assigns.tables.page,
        search: socket.assigns.search
      })

    socket =
      socket
      |> assign(:tables, tables)
      |> assign(:stats, PhoenixKitDb.database_stats())

    {:noreply, socket}
  end

  # Defensive catch-all so a stray PubSub broadcast or OTP message can't
  # crash this LiveView with a FunctionClauseError. Logs at :debug to
  # stay observable in dev but quiet in prod.
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

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default

  defp build_path(socket, overrides) do
    overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    params =
      %{
        "search" => socket.assigns.search,
        "page" => socket.assigns.tables.page
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_k, v} -> v in [nil, "", 1, "1"] end)
      |> Map.new()

    base = Paths.index()

    if map_size(params) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end
end
