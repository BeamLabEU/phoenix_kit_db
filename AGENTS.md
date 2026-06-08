# AGENTS.md

Guidance for AI agents working on `phoenix_kit_db`.

## Project overview

A PhoenixKit plugin module that gives admins a Postgres explorer + live activity feed. Implements the `PhoenixKit.Module` behaviour for auto-discovery. Three admin pages:

- **Index** (`/admin/db`) — list of tables with row counts, sizes, search, pagination. Live updates on any mutation across any table.
- **Show** (`/admin/db/:schema/:table`) — paginated row preview for one table with debounced live refresh on mutations to that table. Highlights newly-changed rows for 3 seconds.
- **Activity** (`/admin/db/activity`) — global INSERT/UPDATE/DELETE feed with filter by table + operation, pause/clear controls, per-key diff highlighting.

Live updates ride on Postgres `LISTEN/NOTIFY`. The module installs a notification function (`phoenix_kit_notify_table_change`) plus per-table triggers (`phoenix_kit_db_change_<schema>_<table>`) lazily — first time a Show or Activity page is viewed for a given table. A dedicated `Postgrex.Notifications` connection (the `Listener` GenServer) parses notifications on the `phoenix_kit_db_changes` channel and rebroadcasts them via `PhoenixKitDb.PubSub`.

## What this module does NOT have (by design)

- **No Ecto schemas** — the module reads `pg_stat_user_tables` and `information_schema.columns` directly via raw SQL through `PhoenixKit.RepoHelper.query/2`. There's no domain model.
- **No Errors module** — `fetch_row/3` returns `{:error, atom}` shapes (`:not_found`, `:invalid_id`, `:invalid_identifier`), but those don't currently surface to UI flashes (the LVs handle them by rendering empty state or redirecting). If a future code path surfaces them, copy the `phoenix_kit_locations/lib/phoenix_kit_locations/errors.ex` shape.
- **No write surface to user data** — the module is read-only against arbitrary tables. The only mutating operations it owns are the trigger DDL (CREATE / DROP TRIGGER) and the `db_enabled` settings toggle.
- **No `Activity` wrapper module** — only one mutation logs activity (the module enable/disable toggle in `phoenix_kit_db.ex`). A dedicated wrapper would be over-engineering for one call site; copy `phoenix_kit_staff/lib/phoenix_kit_staff/activity.ex` if you ever add more.

## Common commands

```bash
# Setup
mix deps.get
MIX_ENV=test mix test.setup    # creates phoenix_kit_db_test DB

# Tests
mix test                       # all tests (integration auto-skips if DB missing)
mix test --exclude integration # unit only

# Code quality
mix format
mix credo --strict
mix dialyzer
mix precommit                  # compile + format + credo --strict + dialyzer
mix quality                    # format + credo --strict + dialyzer
mix quality.ci                 # format --check-formatted + ...
```

## Dependencies

- `phoenix_kit` (`~> 1.7`) — Module behaviour, RepoHelper, Settings, Activity, PubSub.Manager, Dashboard.Tab, Utils.{Date, Routes}.
- `phoenix_live_view` (`~> 1.1`) — admin LiveViews.
- `postgrex` (`~> 0.17`) — `Postgrex.Notifications` for the Listener.
- Test-only: `lazy_html` (HTML parser used by `Phoenix.LiveViewTest` smoke tests).

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

### Concepts

- **Notification function** — single `phoenix_kit_notify_table_change()` plpgsql function that detects the row's PK (`uuid`, then `id`, then nothing), and `pg_notify`s on `phoenix_kit_db_changes`. Payload format: `schema.table:OPERATION:row_id`.
- **Per-table trigger** — `phoenix_kit_db_change_<schema>_<table>` AFTER INSERT/UPDATE/DELETE. Installed lazily on first view, never auto-removed (a `remove_all_triggers/0` helper exists for ops).
- **Listener** — GenServer running its own `Postgrex.Notifications` connection (auto-reconnect on drop). Parses each notification and broadcasts `{:table_changed, schema, table, op, row_id}` via `PhoenixKitDb.PubSub`.
- **PubSub topics**: `topic_all/0` for the Index + Activity pages, `topic_table/2` for the Show page (per-table to avoid noisy refreshes from unrelated tables).

### Files

- `lib/phoenix_kit_db.ex` — main module (`PhoenixKit.Module` behaviour) + DB query helpers (`database_stats/0`, `list_tables/1`, `table_preview/3`, `fetch_row/3`, trigger DDL).
- `lib/phoenix_kit_db/listener.ex` — Postgrex.Notifications GenServer.
- `lib/phoenix_kit_db/paths.ex` — URL builders (`index/0`, `activity/0`, `show/2`).
- `lib/phoenix_kit_db/pub_sub.ex` — topic constants + thin subscribe/broadcast wrappers.
- `lib/phoenix_kit_db/web/index_live.{ex,html.heex}` — table list + stats.
- `lib/phoenix_kit_db/web/show_live.{ex,html.heex}` — row preview + fake-scrollbar JS hook.
- `lib/phoenix_kit_db/web/activity_live.{ex,html.heex}` — live feed with per-key diff highlighting.

## Conventions

- **Activity logging**: only the module enable/disable toggle is logged (`db.module_enabled` / `db.module_disabled`). System-level operations like `ensure_trigger/2` deliberately don't log — they fire on every Show mount and would drown out the audit feed.
- **gettext**: every user-facing string in `lib/phoenix_kit_db/web/**/*.{ex,heex}` wraps via `Gettext.gettext(PhoenixKitWeb.Gettext, "...")`. `:page_title` assigns are wrapped except where they reference programmatic identifiers (`schema.table`). Pluralisation uses `Gettext.ngettext/4`. Translation `.po` files live in core, not this module.
- **PubSub**: every subscribe/broadcast goes through `PhoenixKitDb.PubSub` — never hardcode topic strings.
- **Identifier validation**: `safe_quote_ident/1` and `safe_qualified_table/2` in `phoenix_kit_db.ex` are the only API for splicing `schema`/`table`/`column` names into SQL. They reject anything outside `[a-zA-Z0-9_]` with `{:error, :invalid_identifier}` — never raise. The internal `quote_ident!/1` only fires after validated input has been threaded through.
- **`handle_info/2` catch-all**: every LV and the Listener has a defensive catch-all that logs at `:debug` and returns `{:noreply, ...}`. Never silent.
- **LayoutWrapper**: external plugin LVs do NOT wrap content in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — `live_session :phoenix_kit_admin` auto-applies the layout.

## Settings keys

- `db_enabled` — boolean, read by `enabled?/0`, toggled via Admin → Modules. The `enabled?/0` callback rescues both general errors AND `:exit` signals so test sandbox-pool exits don't surface as 1-in-N flakes (workspace flaky-test trap).

## Permissions

Uses `permission: "db"` from the PhoenixKit role/permission matrix. Owner role inherits it; custom roles can be granted access from the roles matrix.

## Routing

Single visible parent tab (DB) with two visible subtabs (Overview, Activity) and one hidden subtab (Show, path `db/:schema/:table`). All registered via `admin_tabs/0`; no `route_module/0` needed.

## Testing

Three levels:

- **Unit tests** in `test/phoenix_kit_db_test.exs` — behaviour-compliance + input-validation branches that don't need a live DB.
- **Listener tests** in `test/phoenix_kit_db/listener_test.exs` — drive `handle_info({:notification, …})` directly via `send/2`. The Listener tolerates a missing/unreachable DB at startup (returns `{:ok, %{conn: nil}}`).
- **LiveView smoke tests** in `test/phoenix_kit_db/web/*_live_test.exs` — drive each LV via `Phoenix.LiveViewTest.live/2` against the test Endpoint + Router. Use `PhoenixKitDb.LiveCase`.

Tests using `DataCase` or `LiveCase` are auto-tagged `:integration` and excluded when the test DB isn't available.

### Test infrastructure

- `test/support/test_repo.ex` — `PhoenixKitDb.Test.Repo`.
- `test/support/test_endpoint.ex` — minimal `Phoenix.Endpoint`, `server: false`.
- `test/support/test_router.ex` — Router whose paths match `PhoenixKitDb.Paths.*` (base scope `/en/admin/db`).
- `test/support/test_layouts.ex` — root + app layouts; `app/1` renders flashes (`#flash-info`/`#flash-error`/`#flash-warning`) so smoke tests can assert flash content.
- `test/support/hooks.ex` — `:assign_scope` `on_mount` hook that mirrors session scope onto `phoenix_kit_current_scope` + `phoenix_kit_current_user`.
- `test/support/data_case.ex` — `PhoenixKitDb.DataCase`, auto-tags `:integration`, sandbox setup.
- `test/support/live_case.ex` — `PhoenixKitDb.LiveCase` with `fake_scope/1` + `put_test_scope/2` for plugging a real `%PhoenixKit.Users.Auth.Scope{}` into the session.
- `test/support/activity_log_assertions.ex` — `assert_activity_logged/2` and `refute_activity_logged/2` querying `phoenix_kit_activities` directly.
- `test/test_helper.exs` — calls `PhoenixKit.Migration.ensure_current/2` for the schema; starts `PhoenixKit.PubSub.Manager` + `PhoenixKit.ModuleRegistry`; pins `:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")`.

### Known test noise

- `[error] #PID<...> (Postgrex.Notifications) failed to connect to Postgres: ... database "phoenix_kit_db_test" does not exist` — fires on the first run before `mix test.setup`. Once the DB is created, it goes away. The Listener tolerates missing DB gracefully; this is just startup noise.
- `[warning] PhoenixKitDb.Listener is not running` — fires on every LV smoke test because the Listener isn't started in the test endpoint's supervision tree (we don't need real PG notifications, only the LV's `handle_info({:table_changed, …})` paths). Cosmetic.
- `[error] Failed to query setting db_enabled: %DBConnection.OwnershipError{...}` — the `enabled?/0` rescue firing during the unit-test phase before any sandbox owner has been started for the calling pid. The test's `is_boolean(enabled?())` assertion still passes (rescue returns `false`). Cosmetic.

## Versioning & releases

Two version locations must stay in sync:

1. `mix.exs` — the `@version` module attribute.
2. `lib/phoenix_kit_db.ex` — `def version, do: "x.y.z"`.

Releases (version bumps + CHANGELOG entries + `git tag` + `gh release create`) are boss-only — never auto-bump.

## Pre-commit

```bash
mix precommit               # compile + format + credo --strict + dialyzer
```

Step order matters: compile first (warnings-as-errors), then format, then credo --strict, then dialyzer.

## Commit messages

Start with action verbs (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution / `Co-Authored-By` footers — Max handles attribution on his own.

## Pull requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` with `{AGENT}_REVIEW.md` naming.

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `IMPROVEMENT - HIGH`, `IMPROVEMENT - MEDIUM`, `NITPICK`.
