defmodule PhoenixKitDb do
  @moduledoc """
  Database explorer module for PhoenixKit.

  Provides metadata, stats, and paginated previews for Postgres tables
  so the admin UI can browse data without exposing full SQL access.
  Live updates ride on Postgres `LISTEN/NOTIFY` via the
  `PhoenixKitDb.Listener` GenServer.

  ## What `db` access exposes

  Every row of every table in the database, read-only. Values in
  secret-named columns (`PhoenixKitDb.Cells.secret_column?/1`) are replaced
  with a fixed placeholder right after the query, on the Show page and in the
  Activity feed alike. Row search reads nothing masking can hide
  (`PhoenixKitDb.Cells.searchable_column?/2`): not those columns, not JSON
  columns, and not the `value*` columns of a table that has a `key` or `name`
  column. A secret stored under a neutral column name is NOT masked, so grant
  the `db` permission as you would grant `psql` access.

  ## Live Updates

  When a table is being viewed, changes to that table trigger automatic
  refreshes. This requires:

    1. The `Listener` GenServer running (started via the host's
       `PhoenixKit.Supervisor` from this module's `children/0` callback).
    2. A notification trigger on the table being viewed — installed
       lazily by `ensure_trigger/2` on first view.

  Only tables that have been viewed carry a trigger, so only their changes
  reach the Activity feed. `disable_system/0` removes every trigger again.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitDb.Gettext

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKitDb.Cells

  require Logger

  @version Mix.Project.config()[:version]
  @enabled_key "db_enabled"
  @default_table_page 1
  @default_table_page_size 20
  @default_row_page 1
  @default_row_page_size 50
  @notify_channel "phoenix_kit_db_changes"
  @notify_function_name "phoenix_kit_notify_table_change"
  @trigger_prefix "phoenix_kit_db_change_"

  # Postgres silently truncates a longer identifier.
  @max_identifier_bytes 63

  # Above this planner estimate an exact `COUNT(*)` is a full scan the page
  # does not wait for; the estimate is shown instead, labelled approximate.
  @estimate_threshold 100_000

  @default_ddl_lock_timeout_ms 2_000

  # The identifiers this module can splice into SQL, as a Postgres regex
  # predicate. Must accept exactly what `safe_quote_ident/1` accepts.
  @supported_tables_sql "(schemaname ~ '^[a-zA-Z0-9_]+$' AND relname ~ '^[a-zA-Z0-9_]+$')"

  # The column types row search reads. `json` and `jsonb` are absent on
  # purpose: masking hides secret-named keys inside them, and a search over
  # the whole document would still match the hidden values.
  @textual_types ["text", "character varying", "character", "citext", "uuid", "inet"]

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
  @doc """
  Disables the module and removes every notification trigger it installed.

  A trigger left behind keeps running `pg_notify` on every write to its table
  for as long as the table exists, with nobody listening. Removal is best
  effort: a failure is logged and never blocks the disable. Nothing retries
  on its own. Leftovers are found in `pg_trigger`, not remembered, so calling
  `disable_system/0` or `remove_all_triggers/0` again removes them.
  """
  @spec disable_system() :: term()
  def disable_system do
    result = Settings.update_boolean_setting_with_module(@enabled_key, false, module_key())
    log_module_toggle(:disabled)

    unless match?({:error, _}, result), do: remove_triggers_on_disable()

    result
  end

  defp remove_triggers_on_disable do
    remove_all_triggers()
  rescue
    e ->
      Logger.warning(
        "[PhoenixKitDb] could not remove triggers on disable: #{Exception.message(e)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[PhoenixKitDb] could not remove triggers on disable: #{inspect({kind, reason})}"
      )

      :ok
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @spec version() :: String.t()
  def version, do: @version

  @impl PhoenixKit.Module
  @spec css_sources() :: [atom()]
  def css_sources, do: [:phoenix_kit_db]

  @impl PhoenixKit.Module
  @doc """
  The prebuilt JS bundle carrying this module's LiveView hooks.

  A hook must be in the host's `LiveSocket` when it is CONSTRUCTED.
  `PhoenixKitDbTableScroller` used to register itself from an inline
  `<script>` in `show_live.html.heex`, which works on a hard page load but
  silently does nothing after a LiveView navigation — morphdom never executes
  a `<script>` it inserts, and the hooks map is already fixed by then.

  The hook name is namespaced because core's `:phoenix_kit_js_sources`
  compiler folds every bundle's global into `window.PhoenixKitHooks`
  last-write-wins, across other modules' bundles and core's own hooks.
  """
  @spec js_sources() :: [%{app: atom(), file: String.t(), global: String.t()}]
  def js_sources do
    [
      %{
        app: :phoenix_kit_db,
        file: "static/assets/phoenix_kit_db.js",
        global: "PhoenixKitDbHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  @spec permission_metadata() :: PhoenixKit.Module.permission_meta()
  def permission_metadata do
    %{
      key: module_key(),
      label: "DB",
      icon: "hero-server-stack",
      description: "Database explorer and schema inspection",
      gettext_backend: PhoenixKitDb.Gettext,
      gettext_domain: "default"
    }
  end

  @doc """
  Pins every label this module declares as a gettext msgid.

  `permission_metadata/0` and `admin_tabs/0` declare their labels as plain
  string literals, which `mix gettext.extract` does not see. Core translates
  them at render time through each declaration's `gettext_backend` /
  `gettext_domain`, but only when the msgid exists in this module's own
  catalogue. `dgettext_noop/2` registers the msgid and returns it unchanged,
  so nothing here runs at request time.
  """
  @spec translatable_labels() :: [String.t()]
  def translatable_labels do
    [
      dgettext_noop("default", "DB"),
      dgettext_noop("default", "Overview"),
      dgettext_noop("default", "Activity"),
      dgettext_noop("default", "Table")
    ]
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
        live_view: {PhoenixKitDb.Web.IndexLive, :index},
        gettext_backend: PhoenixKitDb.Gettext,
        gettext_domain: "default"
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
        live_view: {PhoenixKitDb.Web.IndexLive, :index},
        gettext_backend: PhoenixKitDb.Gettext,
        gettext_domain: "default"
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
        live_view: {PhoenixKitDb.Web.ActivityLive, :activity},
        gettext_backend: PhoenixKitDb.Gettext,
        gettext_domain: "default"
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
        live_view: {PhoenixKitDb.Web.ShowLive, :show},
        gettext_backend: PhoenixKitDb.Gettext,
        gettext_domain: "default"
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

  @doc """
  Lists tables + stats with pagination and search.

  Only tables this module can open are listed: a schema or table name outside
  `[a-zA-Z0-9_]` cannot be spliced into SQL by `safe_quote_ident/1`, so its
  Show page could only ever answer "not found". `:hidden_count` says how many
  tables were left out for that reason, so the page can say so.
  """
  @spec list_tables(map()) :: map()
  def list_tables(opts \\ %{}) do
    page = normalize_page(Map.get(opts, :page, @default_table_page))
    per_page = normalize_page_size(Map.get(opts, :per_page, @default_table_page_size))
    search = Map.get(opts, :search, "") |> to_string()
    {where_sql, where_params} = table_search_clause(search)

    count_sql = """
    SELECT
      COUNT(*) FILTER (#{where_sql}),
      COUNT(*) FILTER (WHERE NOT #{@supported_tables_sql})
    FROM pg_stat_user_tables
    """

    {total_entries, hidden_count} =
      case RepoHelper.query(count_sql, where_params) do
        {:ok, %{rows: [[count, hidden]]}} -> {count, hidden}
        _ -> {0, 0}
      end

    total_pages = max(div_with_ceiling(total_entries, per_page), 1)
    page = min(page, total_pages)
    offset = (page - 1) * per_page

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

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: total_pages,
      hidden_count: hidden_count
    }
  end

  @doc """
  Every table this module can open, as `{schema, table}`, unpaginated.

  For pickers that must offer the whole list; `list_tables/1` clamps its page
  size and so cannot.
  """
  @spec list_table_names() :: [{String.t(), String.t()}]
  def list_table_names do
    sql = """
    SELECT schemaname, relname
    FROM pg_stat_user_tables
    WHERE #{@supported_tables_sql}
    ORDER BY schemaname ASC, relname ASC
    """

    case RepoHelper.query(sql) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [schema, table] -> {schema, table} end)
      _ -> []
    end
  end

  defp row_to_table_entry([schema, name, approx_rows, size_bytes]) do
    %{schema: schema, name: name, approx_rows: approx_rows, size_bytes: size_bytes}
  end

  @doc """
  Fetches a single row by ID from a table.

  The row comes back through `PhoenixKitDb.Cells.sanitize_row/2`: values in
  secret-named columns are masked and uuid columns are canonical text.

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
         id when not is_nil(id) <- parse_row_id(row_id),
         {:ok, attributes} <- relation_attributes(qualified),
         {:ok, pk_col, pk_type} <- single_primary_key(attributes),
         {:ok, quoted_pk} <- safe_quote_ident(pk_col),
         {:ok, placeholder, param} <- bind_pk_param(pk_type, id) do
      fetch_row_by_pk(qualified, quoted_pk, placeholder, param, attribute_uuid_kinds(attributes))
    else
      nil -> {:error, :invalid_id}
      {:error, _} = err -> err
    end
  end

  def fetch_row(_schema, _table, _row_id), do: {:error, :invalid_identifier}

  defp fetch_row_by_pk(qualified, quoted_pk, placeholder, param, uuid_kinds) do
    sql = "SELECT * FROM #{qualified} WHERE #{quoted_pk} = #{placeholder} LIMIT 1"

    case run_pk_query(sql, param) do
      {:ok, %{columns: columns, rows: [row]}} ->
        {:ok, columns |> Enum.zip(row) |> Map.new() |> Cells.sanitize_row(uuid_kinds)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every column's NAME and TYPE plus whether it is part of the primary key,
  # in one round trip: the key decides how a row is looked up and told apart,
  # the types decide which binaries are uuids.
  #
  # This deliberately does not use `RepoHelper.get_pk_column/1`, which returns
  # only the name and RAISES `ArgumentError` when the table has no primary key,
  # has a composite one, or does not exist. `fetch_row/3` is called from the
  # Activity feed's `handle_info/2` on a LISTEN/NOTIFY payload naming an
  # arbitrary table, and an escaping exception there takes the LiveView down.
  # Those three cases are ordinary "no row to show", so they return error
  # tuples. A table that does not exist has no attributes at all.
  defp relation_attributes(qualified) do
    sql = """
    SELECT
      a.attname,
      format_type(a.atttypid, a.atttypmod),
      EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = a.attrelid AND i.indisprimary
          AND a.attnum = ANY((i.indkey::smallint[])[0:i.indnkeyatts - 1])
      )
    FROM pg_attribute a
    WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
    ORDER BY a.attnum
    """

    case RepoHelper.query(sql, [qualified]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [name, type, primary?] ->
           %{name: name, type: type, primary?: primary?}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp single_primary_key(attributes) do
    case Enum.filter(attributes, & &1.primary?) do
      [%{name: name, type: type}] -> {:ok, name, normalize_pk_type(type)}
      [] -> {:error, :no_primary_key}
      _composite -> {:error, :composite_primary_key}
    end
  end

  defp attribute_uuid_kinds(attributes) do
    for %{name: name, type: type} <- attributes, kind = uuid_kind(type), into: %{} do
      {name, kind}
    end
  end

  defp uuid_kind("uuid"), do: :scalar
  defp uuid_kind("uuid[]"), do: :array
  defp uuid_kind(_type), do: nil

  # `format_type/2` returns the modifier too (`character varying(255)`); only
  # the base name decides how a parameter binds.
  defp normalize_pk_type(type) when is_binary(type) do
    type |> String.split("(", parts: 2) |> hd() |> String.trim()
  end

  defp normalize_pk_type(_), do: ""

  # Binding the parameter to the primary key's ACTUAL type is what makes a row
  # lookup work at all.
  #
  # `WHERE "uuid" = $1` makes Postgres resolve `$1` to `uuid`, and Postgrex then
  # demands a raw 16-byte binary. A canonical dashed uuid string is 36 bytes, so
  # it raised `DBConnection.EncodeError` — meaning row lookups on a uuid primary
  # key ALWAYS failed, valid uuid or not, and every PhoenixKit table has one.
  # Casting on the PARAMETER side (`$1::text::uuid`) resolves `$1` to `text`,
  # which a string encodes into cleanly, and leaves the comparison against the
  # bare column so the primary key index is still used. Casting the COLUMN
  # instead (`"uuid"::text = $1`) would also work and would lose the index.
  #
  # A value that cannot be the column's type is rejected here, before the query.
  defp bind_pk_param("uuid", id) do
    case Ecto.UUID.cast(id) do
      {:ok, canonical} -> {:ok, "$1::text::uuid", canonical}
      :error -> {:error, :invalid_id}
    end
  end

  defp bind_pk_param(type, id) when type in ["smallint", "integer", "bigint"] do
    case parse_integer_id(id) do
      int when is_integer(int) -> {:ok, "$1", int}
      _ -> {:error, :invalid_id}
    end
  end

  defp bind_pk_param(type, id) when type in @textual_types do
    {:ok, "$1", to_string(id)}
  end

  # Text-ish and every other primary key type: bind the value as-is. A string
  # against a text column needs no cast, and an unknown type is better attempted
  # than refused — `run_pk_query/2` catches an encode mismatch either way.
  defp bind_pk_param(_type, id), do: {:ok, "$1", id}

  defp parse_integer_id(id) when is_integer(id), do: id

  defp parse_integer_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer_id(_id), do: nil

  # A backstop, not the fix. `bind_pk_param/2` rejects a value that cannot be
  # the primary key's type before any query runs, so this should no longer
  # fire — but Postgrex RAISES `DBConnection.EncodeError` on a parameter/column
  # type mismatch rather than returning an error tuple, and `fetch_row/3` runs
  # inside the Activity feed's `handle_info/2` on a LISTEN/NOTIFY payload naming
  # an arbitrary table, where an escaping exception takes the LiveView down.
  # An exotic primary key type reaching the catch-all `bind_pk_param/2` clause
  # lands here. Only the encode error is caught, and only around the query
  # itself: anything else raised here is a bug and must stay visible.
  defp run_pk_query(sql, id) do
    RepoHelper.query(sql, [id])
  rescue
    e in DBConnection.EncodeError ->
      Logger.warning(
        "[PhoenixKitDb] row lookup skipped, id does not match the primary key type: #{Exception.message(e)}"
      )

      {:error, :invalid_id}
  end

  defp parse_row_id(id) when is_integer(id), do: id

  defp parse_row_id(id) when is_binary(id), do: if(String.valid?(id), do: id)

  defp parse_row_id(_), do: nil

  @doc """
  Returns table metadata and a row preview window.

  Rows come back through `PhoenixKitDb.Cells.sanitize_row/2`: values in
  secret-named columns are masked, uuid columns are canonical text, and
  `:search` never looks inside a masked column (a match would confirm a
  guess at the hidden value).

  `:row_count` is exact unless the planner estimates more than
  #{@estimate_threshold} rows and no search is active; then it is the
  estimate and `:row_count_approx` is `true`. `:primary_key` lists the
  primary key columns that can tell rows apart (`[]` when the table has no
  primary key, or its key is masked).

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
         %{} = stats <- table_stats(schema, table),
         columns when is_list(columns) <- fetch_columns(schema, table) do
      build_preview(%{
        schema: schema,
        table: table,
        qualified: qualified,
        stats: stats,
        columns: columns,
        page: page,
        per_page: per_page,
        search: search
      })
    else
      _ -> empty_preview(schema, table, page, per_page)
    end
  end

  defp build_preview(%{qualified: qualified, columns: columns, stats: stats} = request) do
    %{page: page, per_page: per_page} = request
    {where_clause, search_params} = row_search_clause(request.search, columns)
    {total_rows, approx?} = count_rows(qualified, where_clause, search_params, stats.estimate)
    total_pages = max(div_with_ceiling(total_rows, per_page), 1)
    page = min(page, total_pages)
    offset = (page - 1) * per_page
    order_column = pick_order_column(columns)

    attributes =
      case relation_attributes(qualified) do
        {:ok, attributes} -> attributes
        {:error, _} -> []
      end

    select_sql = """
    SELECT * FROM #{qualified}
    #{where_clause}
    ORDER BY #{order_column}
    LIMIT $#{length(search_params) + 1}
    OFFSET $#{length(search_params) + 2}
    """

    params = search_params ++ [per_page, offset]
    rows = fetch_preview_rows(select_sql, params, attribute_uuid_kinds(attributes))

    %{
      schema: request.schema,
      table: request.table,
      columns: columns,
      primary_key: row_identity_columns(attributes),
      rows: rows,
      row_count: total_rows,
      row_count_approx: approx?,
      page: page,
      per_page: per_page,
      total_pages: total_pages,
      approx_rows: stats.approx_rows,
      size_bytes: stats.size_bytes
    }
  end

  defp empty_preview(schema, table, page, per_page) do
    %{
      schema: schema,
      table: table,
      columns: [],
      primary_key: [],
      rows: [],
      row_count: 0,
      row_count_approx: false,
      page: page,
      per_page: per_page,
      total_pages: 1,
      approx_rows: 0,
      size_bytes: 0
    }
  end

  # A masked key column holds the same placeholder in every row, so it cannot
  # tell two rows apart.
  defp row_identity_columns(attributes) do
    names = for %{primary?: true, name: name} <- attributes, do: name

    if Enum.any?(names, &Cells.secret_column?/1), do: [], else: names
  end

  # An exact count is a full scan. Past the threshold the planner's estimate
  # stands in for it, but only for the unfiltered total: the planner has no
  # estimate for an arbitrary search.
  defp count_rows(_qualified, "", [], estimate) when estimate > @estimate_threshold do
    {estimate, true}
  end

  defp count_rows(qualified, where_clause, search_params, _estimate) do
    sql = "SELECT COUNT(*) FROM #{qualified} #{where_clause}"

    case RepoHelper.query(sql, search_params) do
      {:ok, %{rows: [[count]]}} -> {count, false}
      _ -> {0, false}
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

  defp fetch_preview_rows(select_sql, params, uuid_kinds) do
    case RepoHelper.query(select_sql, params) do
      {:ok, %{columns: cols, rows: rows}} -> materialise_rows(cols, rows, uuid_kinds)
      _ -> []
    end
  end

  defp materialise_rows(columns, rows, uuid_kinds) do
    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new() |> Cells.sanitize_row(uuid_kinds)
    end)
  end

  defp fetch_columns(schema, table) do
    sql = """
    SELECT column_name,
      CASE WHEN data_type = 'USER-DEFINED' AND udt_name = 'citext'
        THEN udt_name ELSE data_type END,
      is_nullable, ordinal_position
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

  # `nil` when the table does not exist. `estimate` is the planner's row
  # estimate, negative until the table has been analyzed.
  defp table_stats(schema, table) do
    sql = """
    SELECT s.n_live_tup, pg_total_relation_size(s.relid), c.reltuples::bigint
    FROM pg_stat_user_tables s
    JOIN pg_class c ON c.oid = s.relid
    WHERE s.schemaname = $1 AND s.relname = $2
    LIMIT 1
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{rows: [[approx_rows, size_bytes, estimate]]}} ->
        %{approx_rows: approx_rows, size_bytes: size_bytes, estimate: estimate}

      _ ->
        nil
    end
  end

  # Returns `{:ok, "\"schema\".\"table\""}` when both identifiers are
  # safe to quote, `{:error, :invalid_identifier}` otherwise. The tuple
  # shape lets callers (LV mounts, `fetch_row/3`) render a graceful
  # "table not found" message instead of bubbling `ArgumentError` into
  # a 500 page. The anchors are `\A`/`\z`: `$` also matches before a
  # trailing newline, which would let `"users\n"` through.
  defp safe_qualified_table(schema, table) do
    with {:ok, s} <- safe_quote_ident(schema),
         {:ok, t} <- safe_quote_ident(table) do
      {:ok, "#{s}.#{t}"}
    end
  end

  defp safe_quote_ident(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, name) do
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

  defp table_search_clause(""), do: {"WHERE #{@supported_tables_sql}", []}

  defp table_search_clause(search) do
    {"WHERE #{@supported_tables_sql} AND (schemaname ILIKE $1 OR relname ILIKE $1)",
     ["%" <> search <> "%"]}
  end

  defp row_search_clause("", _columns), do: {"", []}

  defp row_search_clause(search, columns) do
    column_names = Enum.map(columns, & &1.name)

    text_columns =
      Enum.filter(columns, fn column ->
        data_type = String.downcase(column.data_type || "")

        data_type in @textual_types and Cells.searchable_column?(column.name, column_names) and
          match?({:ok, _}, safe_quote_ident(column.name))
      end)

    if text_columns == [] do
      {"WHERE FALSE", []}
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

  `CREATE TRIGGER` needs a lock that conflicts with every writer, and a
  waiting lock request makes every later writer queue behind it. The DDL
  therefore gives up after a short lock timeout and returns
  `{:error, :lock_timeout}`: no live updates for this table right now, and
  the next view tries again.

  Returns `:ok` on success, `{:error, :invalid_identifier}` if the
  schema/table contain unsafe characters, or `{:error, reason}` on a
  Postgres error.
  """
  @spec ensure_trigger(identifier_string(), identifier_string()) ::
          :ok | {:error, :invalid_identifier | :lock_timeout | term()}
  def ensure_trigger(schema, table) do
    with {:ok, qualified} <- safe_qualified_table(schema, table),
         :ok <- ensure_notify_function() do
      if has_trigger?(schema, table) do
        :ok
      else
        create_table_trigger(schema, table, qualified)
      end
    end
  end

  @doc """
  Removes the notification trigger from a table.

  Drops every trigger of this module found on the table, under whatever name
  it was created with, so one installed by an earlier naming scheme goes too.
  """
  @spec remove_trigger(identifier_string(), identifier_string()) ::
          :ok | {:error, :invalid_identifier | :lock_timeout | term()}
  def remove_trigger(schema, table) do
    with {:ok, qualified} <- safe_qualified_table(schema, table) do
      schema
      |> installed_trigger_names(table)
      |> drop_triggers(qualified)
    end
  end

  defp drop_triggers([], _qualified), do: :ok

  defp drop_triggers([name | rest], qualified) do
    with :ok <- drop_trigger(name, qualified), do: drop_triggers(rest, qualified)
  end

  @doc """
  Whether a table has a notification trigger installed.

  A trigger counts when it carries this module's name prefix and calls its
  notification function. The full name is not compared: Postgres truncates an
  identifier to #{@max_identifier_bytes} bytes, so the name stored for a long
  table name is not the name that was asked for.
  """
  @spec has_trigger?(identifier_string(), identifier_string()) :: boolean()
  def has_trigger?(schema, table) do
    installed_trigger_names(schema, table) != []
  end

  @doc "Lists all tables that have notification triggers installed."
  @spec list_triggered_tables() :: [{String.t(), String.t()}]
  def list_triggered_tables do
    sql = """
    SELECT DISTINCT n.nspname, c.relname
    #{installed_triggers_from_sql()}
    ORDER BY n.nspname, c.relname
    """

    case RepoHelper.query(sql, [@notify_function_name, @trigger_prefix]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [schema, table] -> {schema, table} end)
      _ -> []
    end
  end

  @doc """
  Removes all notification triggers from all tables.

  Best effort: a table whose trigger cannot be dropped (its lock was not
  granted in time, say) is logged and skipped, and the rest still go. Returns
  `{:error, tables}` naming the tables that still carry a trigger. The tables
  are read from `pg_trigger` on every call, so calling it again is the retry.
  """
  @spec remove_all_triggers() :: :ok | {:error, [{String.t(), String.t()}]}
  def remove_all_triggers do
    failed =
      Enum.reject(list_triggered_tables(), fn {schema, table} ->
        case remove_trigger(schema, table) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning(
              "[PhoenixKitDb] could not remove the trigger on #{schema}.#{table}: " <>
                "#{inspect(reason)}. It keeps firing pg_notify on every write to that table; " <>
                "run PhoenixKitDb.remove_all_triggers() again to remove it"
            )

            false
        end
      end)

    if failed == [], do: :ok, else: {:error, failed}
  end

  # pg_trigger rather than information_schema.triggers: the latter lists only
  # triggers on tables the current role owns or has privileges on.
  defp installed_triggers_from_sql do
    """
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE NOT t.tgisinternal
    AND p.proname = $1
    AND starts_with(t.tgname::text, $2)
    """
  end

  defp installed_trigger_names(schema, table) do
    sql = """
    SELECT t.tgname::text
    #{installed_triggers_from_sql()}
    AND n.nspname = $3
    AND c.relname = $4
    """

    case RepoHelper.query(sql, [@notify_function_name, @trigger_prefix, schema, table]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [name] -> name end)
      _ -> []
    end
  end

  defp drop_trigger(name, qualified) do
    with {:ok, quoted} <- safe_quote_ident(name) do
      run_ddl("DROP TRIGGER IF EXISTS #{quoted} ON #{qualified}")
    end
  end

  @doc false
  @spec notify_channel() :: String.t()
  def notify_channel, do: @notify_channel

  @doc "Updates the notification function without watching an additional table."
  @spec ensure_notify_function() :: :ok | {:error, term()}
  def ensure_notify_function do
    body = """
    DECLARE
      row_id TEXT;
      payload TEXT;
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
      payload := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME || ':' || TG_OP || ':';
      -- Keep the refresh event even when the id cannot fit. Never send a
      -- truncated id that could resolve a different row, or abort the write.
      IF octet_length(payload || COALESCE(row_id, '')) < 8000 THEN
        payload := payload || COALESCE(row_id, '');
      END IF;
      PERFORM pg_notify('#{@notify_channel}', payload);

      -- AFTER triggers ignore return value, but we return appropriately for completeness
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      ELSE
        RETURN NEW;
      END IF;
    END;
    """

    case notify_function_current?(body) do
      {:ok, true} -> :ok
      {:ok, false} -> replace_notify_function(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_function_current?(body) do
    sql = "SELECT EXISTS (SELECT 1 FROM pg_proc WHERE oid = to_regprocedure($1) AND prosrc = $2)"

    case RepoHelper.query(sql, ["#{@notify_function_name}()", body]) do
      {:ok, %{rows: [[current?]]}} -> {:ok, current?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_notify_function(body) do
    # Only installation/upgrades take the lock. Recheck after acquiring it:
    # another session may have installed the same body while this one waited.
    run_ddl(fn ->
      with {:ok, _} <-
             RepoHelper.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [
               @notify_function_name
             ]),
           {:ok, current?} <- notify_function_current?(body) do
        write_notify_function(current?, body)
      end
    end)
  end

  defp write_notify_function(true, _body), do: {:ok, nil}

  defp write_notify_function(false, body) do
    RepoHelper.query("""
    CREATE OR REPLACE FUNCTION #{@notify_function_name}()
    RETURNS trigger AS $phoenix_kit_db$#{body}$phoenix_kit_db$ LANGUAGE plpgsql
    """)
  end

  defp create_table_trigger(schema, table, qualified) do
    sql = """
    CREATE TRIGGER "#{trigger_name(schema, table)}"
    AFTER INSERT OR UPDATE OR DELETE ON #{qualified}
    FOR EACH ROW
    EXECUTE FUNCTION #{@notify_function_name}();
    """

    case run_ddl(sql) do
      :ok ->
        :ok

      # Concurrent ensure_trigger lost the race — the trigger is now present,
      # which is what we wanted. Return :ok rather than propagate.
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_object}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Trigger DDL takes a lock that conflicts with every writer on the table.
  # Queued behind one long transaction it would hold up all the writers that
  # arrive after it, so the wait is bounded: `SET LOCAL` scopes the timeout to
  # this transaction, and a timeout comes back as `{:error, :lock_timeout}`.
  defp run_ddl(sql) when is_binary(sql), do: run_ddl(fn -> RepoHelper.query(sql) end)

  defp run_ddl(action) when is_function(action, 0) do
    result =
      RepoHelper.transaction(fn ->
        with {:ok, _} <-
               RepoHelper.query("SET LOCAL lock_timeout = '#{ddl_lock_timeout_ms()}ms'"),
             {:ok, _} <- action.() do
          :ok
        else
          {:error, reason} -> RepoHelper.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> {:error, :lock_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ddl_lock_timeout_ms do
    case Application.get_env(:phoenix_kit_db, :ddl_lock_timeout_ms, @default_ddl_lock_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_ddl_lock_timeout_ms
    end
  end

  # The one place trigger names are built. Schema and table are validated
  # identifiers, so the name is plain ASCII. A name that would not fit is cut
  # and given a hash of the full `schema.table`, so it is the same on every
  # call and two long names sharing a prefix still differ.
  defp trigger_name(schema, table) do
    name = "#{@trigger_prefix}#{schema}_#{table}"

    if byte_size(name) <= @max_identifier_bytes do
      name
    else
      hash =
        :sha256
        |> :crypto.hash("#{schema}.#{table}")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)

      binary_part(name, 0, @max_identifier_bytes - 9) <> "_" <> hash
    end
  end

  # ============================================================================
  # Activity logging
  # ============================================================================

  defp log_module_toggle(state) when state in [:enabled, :disabled] do
    PhoenixKit.Activity.log(module_key(), "db.module_#{state}", resource_type: "module")
  end
end
