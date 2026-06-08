defmodule PhoenixKitDb.Listener do
  @moduledoc """
  GenServer that listens for PostgreSQL `NOTIFY` events for live table
  updates.

  Holds a separate `Postgrex.Notifications` connection (auto-reconnect
  on drop) on the `phoenix_kit_db_changes` channel. When a notification
  arrives it broadcasts via `PhoenixKitDb.PubSub` so LiveViews can
  react in real time.

  Started via the `c:PhoenixKit.Module.children/0` callback on
  `PhoenixKitDb`, which the host's `PhoenixKit.Supervisor` consumes
  when the module is enabled.
  """

  use GenServer

  alias PhoenixKitDb.PubSub

  require Logger

  @channel "phoenix_kit_db_changes"

  # ── Client API ───────────────────────────────────────────────────

  @doc "Starts the listener process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the Listener is started. Called automatically by the
  subscribe helpers. The Listener is normally started by
  `PhoenixKit.Supervisor` via this module's `children/0` callback;
  this function logs a warning if it isn't running so a missed startup
  is observable rather than silent.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        Logger.warning(
          "PhoenixKitDb.Listener is not running. Live updates will not work. " <>
            "Ensure PhoenixKit.Supervisor is started."
        )

        :ok

      _pid ->
        :ok
    end
  end

  @doc "Subscribe to changes for a specific table."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(schema, table) do
    ensure_started()
    PubSub.subscribe(PubSub.topic_table(schema, table))
  end

  @doc "Unsubscribe from changes for a specific table."
  @spec unsubscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(schema, table) do
    PubSub.unsubscribe(PubSub.topic_table(schema, table))
  end

  @doc "Subscribe to all table changes (Index + Activity pages)."
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    ensure_started()
    PubSub.subscribe(PubSub.topic_all())
  end

  @doc "Unsubscribe from all table changes."
  @spec unsubscribe_all() :: :ok | {:error, term()}
  def unsubscribe_all do
    PubSub.unsubscribe(PubSub.topic_all())
  end

  # ── Server callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    with {:ok, config} <- get_connection_config(),
         {:ok, pid} <- Postgrex.Notifications.start_link(config) do
      case Postgrex.Notifications.listen(pid, @channel) do
        {:ok, _ref} ->
          {:ok, %{conn: pid}}

        # auto_reconnect: connection not yet established, will activate later.
        {:eventually, _ref} ->
          {:ok, %{conn: pid}}

        {:error, reason} ->
          Logger.warning("PhoenixKitDb.Listener failed to LISTEN: #{inspect(reason)}")
          {:ok, %{conn: nil}}
      end
    else
      {:error, reason} ->
        Logger.warning("PhoenixKitDb.Listener failed to start: #{inspect(reason)}")
        {:ok, %{conn: nil}}
    end
  end

  @impl true
  def handle_info({:notification, _conn, _ref, @channel, payload}, state) do
    case parse_payload(payload) do
      {schema, table, operation, row_id} ->
        Logger.info("PhoenixKitDb: #{schema}.#{table} - #{operation} (id: #{row_id || "n/a"})")

        message = {:table_changed, schema, table, operation, row_id}

        PubSub.broadcast(PubSub.topic_table(schema, table), message)
        PubSub.broadcast(PubSub.topic_all(), message)

      :error ->
        Logger.warning("PhoenixKitDb: Invalid notification payload: #{inspect(payload)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[#{inspect(__MODULE__)}] Unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    Postgrex.Notifications.unlisten(conn, @channel)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ──────────────────────────────────────────────────────

  # Trigger function payload format (set by db.ex's notify function):
  #   "schema.table:OPERATION:row_id"
  # The schema/table half always splits on ".", parts: 2; the operation
  # is one of {INSERT, UPDATE, DELETE}; row_id is the row's `uuid` or
  # `id` cast to TEXT, or "" when the table has neither column.
  defp parse_payload(payload) do
    with [table_part, operation, row_id] <- String.split(payload, ":"),
         [schema, table] <- String.split(table_part, ".", parts: 2) do
      {schema, table, operation, normalize_row_id(row_id)}
    else
      _ -> :error
    end
  end

  defp normalize_row_id(""), do: nil
  defp normalize_row_id(id), do: id

  defp get_connection_config do
    case PhoenixKit.RepoHelper.repo() do
      nil ->
        {:error, :no_repo}

      repo ->
        config = repo.config()

        # Postgrex-compatible config from the host repo's settings.
        # Local sockets and SSL options pass through.
        postgrex_config =
          config
          |> Keyword.take([
            :hostname,
            :port,
            :database,
            :username,
            :password,
            :socket,
            :socket_dir,
            :ssl,
            :ssl_opts
          ])
          |> Keyword.put_new(:hostname, "localhost")
          |> Keyword.put_new(:port, 5432)
          |> Keyword.put(:auto_reconnect, true)

        {:ok, postgrex_config}
    end
  rescue
    e ->
      Logger.error("PhoenixKitDb.Listener failed to get connection config: #{inspect(e)}")
      {:error, e}
  end
end
