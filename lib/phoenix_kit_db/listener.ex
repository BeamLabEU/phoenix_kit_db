defmodule PhoenixKitDb.Listener do
  @moduledoc """
  GenServer that listens for PostgreSQL `NOTIFY` events for live table updates.

  Holds a separate `Postgrex.Notifications` connection (auto-reconnect on
  drop) on the `phoenix_kit_db_changes` channel. When a notification
  arrives, it broadcasts via `PhoenixKit.PubSub.Manager` so LiveViews can
  react in real time.

  Started via the `PhoenixKit.Module.children/0` callback on
  `PhoenixKitDb`, which the host's `PhoenixKit.Supervisor` consumes when
  the module is enabled.
  """

  use GenServer

  alias PhoenixKit.PubSub.Manager, as: PubSubManager

  require Logger

  @channel "phoenix_kit_db_changes"

  # ── Client API ───────────────────────────────────────────────────

  @doc "Starts the listener process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the Listener is started. Called automatically by subscribe
  functions. The Listener is normally started by `PhoenixKit.Supervisor`
  via this module's `children/0` callback. This function is a safety
  check that logs a warning if the Listener isn't running.
  """
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
  def subscribe(schema, table) do
    ensure_started()
    PubSubManager.subscribe(topic(schema, table))
  end

  @doc "Unsubscribe from changes for a specific table."
  def unsubscribe(schema, table) do
    PubSubManager.unsubscribe(topic(schema, table))
  end

  @doc "Subscribe to all table changes (for the index / activity pages)."
  def subscribe_all do
    ensure_started()
    PubSubManager.subscribe("phoenix_kit_db:all")
  end

  @doc "Unsubscribe from all table changes."
  def unsubscribe_all do
    PubSubManager.unsubscribe("phoenix_kit_db:all")
  end

  # ── Server callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    case get_connection_config() do
      {:ok, config} ->
        case Postgrex.Notifications.start_link(config) do
          {:ok, pid} ->
            case Postgrex.Notifications.listen(pid, @channel) do
              {:ok, _ref} ->
                {:ok, %{conn: pid}}

              {:eventually, _ref} ->
                # auto_reconnect: connection not yet established, will activate later
                {:ok, %{conn: pid}}

              {:error, reason} ->
                Logger.warning("PhoenixKitDb.Listener failed to LISTEN: #{inspect(reason)}")
                {:ok, %{conn: nil}}
            end

          {:error, reason} ->
            Logger.warning("PhoenixKitDb.Listener failed to connect: #{inspect(reason)}")
            {:ok, %{conn: nil}}
        end

      {:error, reason} ->
        Logger.warning("PhoenixKitDb.Listener could not get DB config: #{inspect(reason)}")
        {:ok, %{conn: nil}}
    end
  end

  @impl true
  def handle_info({:notification, _conn, _ref, @channel, payload}, state) do
    # Payload format: "schema.table:OPERATION:row_id" (e.g., "public.users:INSERT:123")
    case parse_payload(payload) do
      {schema, table, operation, row_id} ->
        Logger.info(
          "PhoenixKitDb: #{schema}.#{table} - #{operation} (id: #{row_id || "n/a"})"
        )

        message = {:table_changed, schema, table, operation, row_id}

        # Broadcast to specific table subscribers
        PubSubManager.broadcast(topic(schema, table), message)

        # Broadcast to "all tables" subscribers (for index/activity pages)
        PubSubManager.broadcast("phoenix_kit_db:all", message)

      :error ->
        Logger.warning("PhoenixKitDb: Invalid notification payload: #{payload}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    Postgrex.Notifications.unlisten(conn, @channel)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ──────────────────────────────────────────────────────

  defp parse_payload(payload) do
    case String.split(payload, ":") do
      # New format: schema.table:OPERATION:row_id
      [table_part, operation, row_id] ->
        case String.split(table_part, ".", parts: 2) do
          [schema, table] ->
            parsed_id = if row_id == "", do: nil, else: row_id
            {schema, table, operation, parsed_id}

          _ ->
            :error
        end

      # Legacy format: schema.table:OPERATION (backwards compat)
      [table_part, operation] ->
        case String.split(table_part, ".", parts: 2) do
          [schema, table] -> {schema, table, operation, nil}
          _ -> :error
        end

      # Very old format without operation (backwards compat)
      [table_part] ->
        case String.split(table_part, ".", parts: 2) do
          [schema, table] -> {schema, table, "UNKNOWN", nil}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp topic(schema, table), do: "phoenix_kit_db:#{schema}.#{table}"

  defp get_connection_config do
    case PhoenixKit.RepoHelper.repo() do
      nil ->
        {:error, :no_repo}

      repo ->
        config = repo.config()

        # Build Postgrex-compatible config from the host repo's settings.
        # Include socket/socket_dir for local connections, and SSL options.
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
