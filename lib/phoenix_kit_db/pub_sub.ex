defmodule PhoenixKitDb.PubSub do
  @moduledoc """
  Topic constants and subscribe/broadcast helpers for the DB module,
  backed by `PhoenixKit.PubSub.Manager` (the shared in-process PubSub
  server).

  The Postgres `LISTEN/NOTIFY` channel itself
  (`#{__MODULE__ |> Module.split() |> List.last() |> String.downcase()}_changes`)
  is internal to `PhoenixKitDb.Listener` — these helpers wrap the
  per-LiveView fan-out that the Listener performs after parsing each
  notification.

  ## Topics

    * `topic_all/0` — every mutation, regardless of table. Used by the
      Index page (table-list refresh) and the Activity page (live feed).
    * `topic_table/2` — mutations for one specific `schema.table`.
      Used by the Show page so a busy unrelated table doesn't refresh
      the row preview.

  ## Events

  Messages are `{:table_changed, schema, table, operation, row_id}`
  tuples. `operation` is `"INSERT"` / `"UPDATE"` / `"DELETE"` (or
  `"UNKNOWN"` for a malformed payload). `row_id` may be `nil` when the
  underlying row has neither a `uuid` nor an `id` column.
  """

  alias PhoenixKit.PubSub.Manager

  @typedoc "PubSub topic name."
  @type topic :: String.t()

  # ── Topics ─────────────────────────────────────────────────────────

  @doc "Topic that fans out every mutation across every watched table."
  @spec topic_all() :: topic()
  def topic_all, do: "phoenix_kit_db:all"

  @doc "Topic scoped to a single `schema.table` pair."
  @spec topic_table(String.t(), String.t()) :: topic()
  def topic_table(schema, table), do: "phoenix_kit_db:#{schema}.#{table}"

  # ── Subscribe / broadcast ──────────────────────────────────────────

  @doc "Subscribes the calling process to the given topic."
  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic), do: Manager.subscribe(topic)

  @doc "Unsubscribes the calling process from the given topic."
  @spec unsubscribe(topic()) :: :ok | {:error, term()}
  def unsubscribe(topic), do: Manager.unsubscribe(topic)

  @doc "Broadcasts a `:table_changed` message on a topic."
  @spec broadcast(topic(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message), do: Manager.broadcast(topic, message)
end
