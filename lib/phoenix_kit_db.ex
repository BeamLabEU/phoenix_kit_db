defmodule PhoenixKitDb do
  @moduledoc """
  Database explorer module for PhoenixKit.

  Provides metadata, stats, and paginated previews for Postgres tables
  so the admin UI can browse data without exposing full SQL access.
  Live updates ride on Postgres `LISTEN/NOTIFY` via the
  `PhoenixKitDb.Listener` GenServer.

  ## Live Updates

  When a table is being viewed, changes to that table trigger automatic
  refreshes. This requires:

    1. The `Listener` GenServer running (started via the host's
       `PhoenixKit.Supervisor` from this module's `children/0` callback).
    2. A notification trigger on the table being viewed — installed
       lazily by `ensure_trigger/2` on first view.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings

  require Logger

  @enabled_key "db_enabled"
  @default_table_page 1
  @default_table_page_size 20
  @default_row_page 1
  @default_row_page_size 50
  @notify_channel "phoenix_kit_db_changes"
  @notify_function_name "phoenix_kit_notify_table_change"
  @trigger_prefix "phoenix_kit_db_change_"

  @textual_types ~w(text character varying character citext json jsonb uuid inet)

  @typedoc "An identifier accepted by the schema/table-name validator."
  @type identifier_string :: String.t()

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @spec module_key() :: String.t()
  def module_key, do: "db"

  @impl PhoenixKit.Module
  @spec module_name() :: String.t()
  def module_name, do: "DB"

  @impl PhoenixKit.Module
  @doc """
  Whether the DB module is enabled.

  Reads from the DB-backed settings table. Defensive against three
  failure modes that can hit before/around DB availability:

    - `rescue _`: DB not running, table missing, schema mismatch, etc.
    - `catch :exit, _`: connection pool checkout `EXIT` (e.g. when a
      test sandbox owner has just stopped — test-environment artifact,
      but harmless to handle in production code too).

  All branches return `false` so callers don't need to special-case
  startup ordering.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @spec enable_system() :: term()
  def enable_system do
    result = Settings.update_boolean_setting_with_module(@enabled_key, true, module_key())
    log_module_toggle(:enabled)
    result
  end

  @impl PhoenixKit.Module
  @spec disable_system() :: term()
  def disable_system do
    result = Settings.update_boolean_setting_with_module(@enabled_key, false, module_key())
    log_module_toggle(:disabled)
    result
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl PhoenixKit.Module
  @spec css_sources() :: [atom()]
  def css_sources, do: [:phoenix_kit_db]

  @impl PhoenixKit.Module
  @spec permission_metadata() :: %{
          key: String.t(),
          label: String.t(),
          icon: String.t(),
          description: String.t()
        }
  def permission_metadata do
    %{
      key: module_key(),
      label: "DB",
      icon: "hero-server-stack",
      description: "Database explorer and schema inspection"
    }
  end

  @impl PhoenixKit.Module
  @spec get_config() :: map()
  def get_config do
    stats = database_stats()

    %{
      enabled: enabled?(),
      table_count: stats.table_count,
      approx_rows: stats.approx_rows,
      total_size_bytes: stats.total_size_bytes,
      database_size_bytes: stats.database_size_bytes
    }
  end

  @impl PhoenixKit.Module
  @spec admin_tabs() :: [Tab.t()]
  def admin_tabs do
    [
      # Parent tab — match: :prefix keeps subtabs highlighted on any /db/* page.
      %Tab{
        id: :admin_db,
        label: "DB",
        icon: "hero-table-cells",
        path: "db",
        priority: 570,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitDb.Web.IndexLive, :index}
      },
      # Subtab — Overview at the same path as parent.
      %Tab{
        id: :admin_db_overview,
        label: "Overview",
        icon: "hero-table-cells",
        path: "db",
        priority: 571,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_db,
        live_view: {PhoenixKitDb.Web.IndexLive, :index}
      },
      # Subtab — Activity feed (visible).
      %Tab{
        id: :admin_db_activity,
        label: "Activity",
        icon: "hero-signal",
        path: "db/activity",
        priority: 572,
        level: :admin,
        permission: module_key(),
        parent: :admin_db,
        live_view: {PhoenixKitDb.Web.ActivityLive, :activity}
      },
      # Hidden — Table detail page, reached by clicking a row in the index.
      %Tab{
        id: :admin_db_show,
        label: "Table",
        icon: "hero-table-cells",
        path: "db/:schema/:table",
        priority: 573,
        level: :admin,
        permission: module_key(),
        parent: :admin_db,
        visible: false,
        live_view: {PhoenixKitDb.Web.ShowLive, :show}
      }
    ]
  end

  @impl PhoenixKit.Module
  @spec children() :: [module()]
  def children, do: [PhoenixKitDb.Listener]

  # ============================================================================
  # Stats / table listing
  # ============================================================================

  @doc "Aggregated Postgres stats for all user tables."
  @spec database_stats() :: %{
          table_count: non_neg_integer(),
          approx_rows: non_neg_integer(),
          total_size_bytes: non_neg_integer(),
          database_size_bytes: non_neg_integer()
        }
  def database_stats do
    sql = """
    SELECT
      COUNT(*) AS table_count,
      COALESCE(SUM(n_live_tup), 0) AS approx_rows,
      COALESCE(SUM(pg_total_relation_size(relid)), 0) AS total_size_bytes,
      pg_database_size(current_database()) AS database_size_bytes
    FROM pg_stat_user_tables
    """

    case RepoHelper.query(sql) do
      {:ok, %{rows: [[table_count, approx_rows, total_size_bytes, db_size]]}} ->
        %{
          table_count: table_count,
          approx_rows: approx_rows,
          total_size_bytes: total_size_bytes,
          database_size_bytes: db_size
        }

      _ ->
        %{
          table_count: 0,
          approx_rows: 0,
          total_size_bytes: 0,
          database_size_bytes: 0
        }
    end
  end

  @doc "Lists tables + stats with pagination and search."
  @spec list_tables(map()) :: map()
  def list_tables(opts \\ %{}) do
    page = normalize_page(Map.get(opts, :page, @default_table_page))
    per_page = normalize_page_size(Map.get(opts, :per_page, @default_table_page_size))
    search = Map.get(opts, :search, "") |> to_string()
    offset = (page - 1) * per_page

    {where_sql, where_params} = table_search_clause(search)

    count_sql = "SELECT COUNT(*) FROM pg_stat_user_tables #{where_sql}"

    total_entries =
      case RepoHelper.query(count_sql, where_params) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end

    list_sql = """
    SELECT schemaname, relname, n_live_tup, pg_total_relation_size(relid)
    FROM pg_stat_user_tables
    #{where_sql}
    ORDER BY schemaname ASC, relname ASC
    LIMIT $#{length(where_params) + 1}
    OFFSET $#{length(where_params) + 2}
    """

    params = where_params ++ [per_page, offset]

    entries =
      case RepoHelper.query(list_sql, params) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &row_to_table_entry/1)
        _ -> []
      end

    total_pages = max(div_with_ceiling(total_entries, per_page), 1)

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  defp row_to_table_entry([schema, name, approx_rows, size_bytes]) do
    %{schema: schema, name: name, approx_rows: approx_rows, size_bytes: size_bytes}
  end

  @doc """
  Fetches a single row by ID from a table.

  Returns `{:ok, row_map}` or `{:error, :not_found | :invalid_id |
  :invalid_identifier | term()}`. `:invalid_identifier` covers the case
  where `schema` or `table` contains characters that can't be safely
  quoted into SQL — this surfaces graceful "table not found" UX
  instead of a 500.
  """
  @spec fetch_row(identifier_string() | nil, identifier_string(), term()) ::
          {:ok, map()} | {:error, :not_found | :invalid_id | :invalid_identifier | term()}
  def fetch_row(schema, table, row_id) when is_binary(table) do
    schema = schema || "public"

    with {:ok, qualified} <- safe_qualified_table(schema, table),
         id when not is_nil(id) <- parse_row_id(row_id) do
      pk_col = RepoHelper.get_pk_column(qualified)

      case safe_quote_ident(pk_col) do
        {:ok, quoted_pk} ->
          fetch_row_by_pk(qualified, quoted_pk, id)

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, :invalid_id}
      {:error, _} = err -> err
    end
  end

  defp fetch_row_by_pk(qualified, quoted_pk, id) do
    sql = "SELECT * FROM #{qualified} WHERE #{quoted_pk} = $1 LIMIT 1"

    case RepoHelper.query(sql, [id]) do
      {:ok, %{columns: columns, rows: [row]}} ->
        {:ok, columns |> Enum.zip(row) |> Map.new()}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_row_id(id) when is_integer(id), do: id

  defp parse_row_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> if match?({:ok, _}, Ecto.UUID.cast(id)), do: id, else: nil
    end
  end

  defp parse_row_id(_), do: nil

  @doc """
  Returns table metadata and a row preview window.

  When `schema` or `table` is malformed, returns the empty preview
  shape rather than crashing — the LV uses this signal to render a
  graceful "table not found" message.
  """
  @spec table_preview(identifier_string() | nil, identifier_string(), map()) :: map()
  def table_preview(schema, table, opts \\ %{}) when is_binary(table) do
    schema = schema || "public"
    page = normalize_page(Map.get(opts, :page, @default_row_page))
    per_page = normalize_page_size(Map.get(opts, :per_page, @default_row_page_size), 10, 200)
    search = Map.get(opts, :search, "") |> to_string()

    with {:ok, qualified} <- safe_qualified_table(schema, table),
         true <- table_exists?(schema, table),
         columns when is_list(columns) <- fetch_columns(schema, table) do
      build_preview(schema, table, qualified, columns, page, per_page, search)
    else
      _ -> empty_preview(schema, table, page, per_page)
    end
  end

  defp build_preview(schema, table, qualified, columns, page, per_page, search) do
    {where_clause, search_params} = row_search_clause(search, columns)
    offset = (page - 1) * per_page

    total_rows = count_rows(qualified, where_clause, search_params)
    order_column = pick_order_column(columns)

    select_sql = """
    SELECT * FROM #{qualified}
    #{where_clause}
    ORDER BY #{order_column}
    LIMIT $#{length(search_params) + 1}
    OFFSET $#{length(search_params) + 2}
    """

    params = search_params ++ [per_page, offset]
    rows = fetch_preview_rows(select_sql, params)

    %{
      schema: schema,
      table: table,
      columns: columns,
      rows: rows,
      row_count: total_rows,
      page: page,
      per_page: per_page,
      total_pages: max(div_with_ceiling(total_rows, per_page), 1),
      approx_rows: get_table_stat(schema, table, :approx_rows),
      size_bytes: get_table_stat(schema, table, :size_bytes)
    }
  end

  defp empty_preview(schema, table, page, per_page) do
    %{
      schema: schema,
      table: table,
      columns: [],
      rows: [],
      row_count: 0,
      page: page,
      per_page: per_page,
      total_pages: 1,
      approx_rows: 0,
      size_bytes: 0
    }
  end

  defp count_rows(qualified, where_clause, search_params) do
    sql = "SELECT COUNT(*) FROM #{qualified} #{where_clause}"

    case RepoHelper.query(sql, search_params) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp pick_order_column(columns) do
    col_names = Enum.map(columns, & &1.name)

    cond do
      "uuid" in col_names -> "uuid"
      "id" in col_names -> "id"
      true -> "ctid"
    end
  end

  defp fetch_preview_rows(select_sql, params) do
    case RepoHelper.query(select_sql, params) do
      {:ok, %{columns: cols, rows: rows}} -> materialise_rows(cols, rows)
      _ -> []
    end
  end

  defp materialise_rows(columns, rows) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp fetch_columns(schema, table) do
    sql = """
    SELECT column_name, data_type, is_nullable, ordinal_position
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    ORDER BY ordinal_position
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &row_to_column/1)
      _ -> []
    end
  end

  defp row_to_column([name, data_type, nullable, position]) do
    %{
      name: name,
      data_type: data_type,
      nullable: nullable == "YES",
      ordinal_position: position
    }
  end

  defp table_exists?(schema, table) do
    sql = """
    SELECT 1 FROM pg_stat_user_tables
    WHERE schemaname = $1 AND relname = $2
    LIMIT 1
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{num_rows: num_rows}} when num_rows > 0 -> true
      _ -> false
    end
  end

  defp get_table_stat(schema, table, field) do
    sql = """
    SELECT n_live_tup, pg_total_relation_size(relid)
    FROM pg_stat_user_tables
    WHERE schemaname = $1 AND relname = $2
    LIMIT 1
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{rows: [[approx_rows, size_bytes]]}} ->
        case field do
          :approx_rows -> approx_rows
          :size_bytes -> size_bytes
        end

      _ ->
        0
    end
  end

  # Returns `{:ok, "\"schema\".\"table\""}` when both identifiers are
  # safe to quote, `{:error, :invalid_identifier}` otherwise. Wrapping
  # the previously-raise-on-bad-input `quote_ident/1` in a tuple-shape
  # API lets callers (LV mounts, `fetch_row/3`) render a graceful
  # "table not found" message instead of bubbling `ArgumentError` into
  # a 500 page.
  defp safe_qualified_table(schema, table) do
    with {:ok, s} <- safe_quote_ident(schema),
         {:ok, t} <- safe_quote_ident(table) do
      {:ok, "#{s}.#{t}"}
    end
  end

  defp safe_quote_ident(name) when is_binary(name) do
    if Regex.match?(~r/^[a-zA-Z0-9_]+$/, name) do
      {:ok, ~s("#{name}")}
    else
      {:error, :invalid_identifier}
    end
  end

  defp safe_quote_ident(_), do: {:error, :invalid_identifier}

  # Internal-only — every call site lives in this module and passes
  # validated identifiers (via `safe_quote_ident/1` upstream).
  defp quote_ident!(name) do
    case safe_quote_ident(name) do
      {:ok, quoted} -> quoted
      {:error, _} -> raise ArgumentError, "invalid identifier: #{inspect(name)}"
    end
  end

  defp table_search_clause(""), do: {"", []}

  defp table_search_clause(search) do
    {"WHERE (schemaname ILIKE $1 OR relname ILIKE $1)", ["%" <> search <> "%"]}
  end

  defp row_search_clause("", _columns), do: {"", []}

  defp row_search_clause(search, columns) do
    text_columns =
      Enum.filter(columns, fn column ->
        data_type = String.downcase(column.data_type || "")
        data_type in @textual_types
      end)

    if text_columns == [] do
      {"", []}
    else
      pattern = "%" <> search <> "%"

      clauses =
        text_columns
        |> Enum.with_index(1)
        |> Enum.map(fn {column, idx} ->
          "CAST(#{quote_ident!(column.name)} AS TEXT) ILIKE $#{idx}"
        end)

      {
        "WHERE (" <> Enum.join(clauses, " OR ") <> ")",
        List.duplicate(pattern, length(clauses))
      }
    end
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    page
    |> Integer.parse()
    |> case do
      {value, _} when value > 0 -> value
      _ -> @default_table_page
    end
  end

  defp normalize_page(_), do: @default_table_page

  defp normalize_page_size(size, min \\ 5, max \\ 100)

  defp normalize_page_size(size, min, max) when is_integer(size) do
    size
    |> max(min)
    |> min(max)
  end

  defp normalize_page_size(size, min, max) when is_binary(size) do
    size
    |> Integer.parse()
    |> case do
      {value, _} -> normalize_page_size(value, min, max)
      _ -> normalize_page_size(@default_table_page_size, min, max)
    end
  end

  defp normalize_page_size(_, min, max),
    do: normalize_page_size(@default_table_page_size, min, max)

  defp div_with_ceiling(0, _per_page), do: 0

  defp div_with_ceiling(total, per_page) when per_page > 0 do
    div(total + per_page - 1, per_page)
  end

  # ============================================================================
  # Live-update triggers
  # ============================================================================

  @doc """
  Ensures the notification function exists and creates a trigger on
  the table.

  Idempotent. A concurrent caller racing to create the same trigger
  surfaces as `:ok` rather than an error — the win condition is "the
  trigger exists", and Postgres' `duplicate_object` reply on the loser
  is folded back into success.

  Returns `:ok` on success, `{:error, :invalid_identifier}` if the
  schema/table contain unsafe characters, or `{:error, reason}` on a
  Postgres error.
  """
  @spec ensure_trigger(identifier_string(), identifier_string()) ::
          :ok | {:error, :invalid_identifier | term()}
  def ensure_trigger(schema, table) do
    with {:ok, _qualified} <- safe_qualified_table(schema, table),
         :ok <- ensure_notify_function() do
      create_table_trigger(schema, table)
    end
  end

  @doc "Removes the notification trigger from a table."
  @spec remove_trigger(identifier_string(), identifier_string()) ::
          :ok | {:error, :invalid_identifier | term()}
  def remove_trigger(schema, table) do
    with {:ok, qualified} <- safe_qualified_table(schema, table) do
      trigger = trigger_name(schema, table)
      sql = "DROP TRIGGER IF EXISTS #{trigger} ON #{qualified}"

      case RepoHelper.query(sql) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Whether a table has a notification trigger installed."
  @spec has_trigger?(identifier_string(), identifier_string()) :: boolean()
  def has_trigger?(schema, table) do
    trigger = trigger_name(schema, table)

    sql = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.triggers
      WHERE trigger_schema = $1
      AND event_object_table = $2
      AND trigger_name = $3
    )
    """

    case RepoHelper.query(sql, [schema, table, trigger]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc "Lists all tables that have notification triggers installed."
  @spec list_triggered_tables() :: [{String.t(), String.t()}]
  def list_triggered_tables do
    # @trigger_prefix is a hardcoded module attribute — not user input —
    # so direct interpolation into a LIKE pattern is safe by construction.
    sql = """
    SELECT trigger_schema, event_object_table
    FROM information_schema.triggers
    WHERE trigger_name LIKE '#{@trigger_prefix}%'
    GROUP BY trigger_schema, event_object_table
    ORDER BY trigger_schema, event_object_table
    """

    case RepoHelper.query(sql) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [schema, table] -> {schema, table} end)
      _ -> []
    end
  end

  @doc "Removes all notification triggers from all tables."
  @spec remove_all_triggers() :: :ok
  def remove_all_triggers do
    Enum.each(list_triggered_tables(), fn {schema, table} ->
      remove_trigger(schema, table)
    end)
  end

  @doc false
  @spec notify_channel() :: String.t()
  def notify_channel, do: @notify_channel

  defp ensure_notify_function do
    sql = """
    CREATE OR REPLACE FUNCTION #{@notify_function_name}()
    RETURNS trigger AS $$
    DECLARE
      row_id TEXT;
    BEGIN
      -- Try uuid first (Category A tables), then id (Category B), then empty
      IF TG_OP = 'DELETE' THEN
        BEGIN
          row_id := OLD.uuid::TEXT;
        EXCEPTION WHEN undefined_column THEN
          BEGIN
            row_id := OLD.id::TEXT;
          EXCEPTION WHEN undefined_column THEN
            row_id := '';
          END;
        END;
      ELSE
        BEGIN
          row_id := NEW.uuid::TEXT;
        EXCEPTION WHEN undefined_column THEN
          BEGIN
            row_id := NEW.id::TEXT;
          EXCEPTION WHEN undefined_column THEN
            row_id := '';
          END;
        END;
      END IF;

      -- Payload format: schema.table:operation:row_id
      PERFORM pg_notify('#{@notify_channel}', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME || ':' || TG_OP || ':' || COALESCE(row_id, ''));

      -- AFTER triggers ignore return value, but we return appropriately for completeness
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      ELSE
        RETURN NEW;
      END IF;
    END;
    $$ LANGUAGE plpgsql;
    """

    case RepoHelper.query(sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_table_trigger(schema, table) do
    if has_trigger?(schema, table) do
      :ok
    else
      do_create_trigger(schema, table)
    end
  end

  defp do_create_trigger(schema, table) do
    trigger = trigger_name(schema, table)
    qualified = qualified_table(schema, table)

    sql = """
    CREATE TRIGGER #{trigger}
    AFTER INSERT OR UPDATE OR DELETE ON #{qualified}
    FOR EACH ROW
    EXECUTE FUNCTION #{@notify_function_name}();
    """

    case RepoHelper.query(sql) do
      {:ok, _} ->
        :ok

      # Concurrent ensure_trigger lost the race — the trigger is now present,
      # which is what we wanted. Return :ok rather than propagate.
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_object}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp qualified_table(schema, table) do
    "#{quote_ident!(schema)}.#{quote_ident!(table)}"
  end

  defp trigger_name(schema, table) do
    safe_schema = String.replace(schema, ~r/[^a-zA-Z0-9_]/, "_")
    safe_table = String.replace(table, ~r/[^a-zA-Z0-9_]/, "_")
    "#{@trigger_prefix}#{safe_schema}_#{safe_table}"
  end

  # ============================================================================
  # Activity logging
  # ============================================================================

  defp log_module_toggle(state) when state in [:enabled, :disabled] do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "db.module_#{state}",
        module: module_key(),
        mode: "manual",
        resource_type: "module",
        metadata: %{}
      })
    end
  rescue
    Postgrex.Error ->
      :ok

    DBConnection.OwnershipError ->
      :ok

    e ->
      Logger.warning("[PhoenixKitDb] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, _reason -> :ok
  end
end
