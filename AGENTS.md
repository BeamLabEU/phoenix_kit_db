# AGENTS.md

Guidance for AI agents working on `phoenix_kit_db`.

## Overview

A PhoenixKit plugin module that gives admins a Postgres explorer plus a live
activity feed. It implements the `PhoenixKit.Module` behaviour for
auto-discovery and registers three admin pages:

- **Index** (`/admin/db`): list of tables with row counts, sizes, search and
  pagination. Live-refreshes on any mutation across any table.
- **Show** (`/admin/db/:schema/:table`): paginated row preview for one table
  with debounced live refresh on mutations to that table; newly-changed rows
  highlight for 3 seconds.
- **Activity** (`/admin/db/activity`): global INSERT/UPDATE/DELETE feed with
  filter by table and operation, pause/clear controls, per-key diff
  highlighting.

Live updates ride on Postgres `LISTEN/NOTIFY`. The module installs one
notification function (`phoenix_kit_notify_table_change()`) plus a per-table
trigger (`phoenix_kit_db_change_<schema>_<table>`) lazily, the first time a
Show page is viewed for that table. A dedicated `Postgrex.Notifications`
connection (the `PhoenixKitDb.Listener` GenServer) parses notifications on the
`phoenix_kit_db_changes` channel and rebroadcasts them via
`PhoenixKitDb.PubSub`.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex); `phoenix_live_view` `~> 1.1`;
  `postgrex` `~> 0.17` (`Postgrex.Notifications` for the Listener); test-only
  `lazy_html`. No sibling `phoenix_kit_*` deps. `PhoenixKit.Activity` is
  called behind `Code.ensure_loaded?/1`, so it is not part of the floor.
- **Consumed by:** nothing yet. Core mirrors this module's `permission_metadata/0`
  (label `"DB"`, icon `hero-server-stack`, description) in
  `PhoenixKit.Users.Permissions` fallbacks so the `db` key renders correctly
  when the module is not installed; a change to `permission_metadata/0` here
  needs that mirror updated in core.
- **Admin surface:** parent tab `:admin_db` ("DB", path `db`, group
  `:admin_modules`, priority 570) with subtabs Overview (`db`), Activity
  (`db/activity`) and the hidden Show (`db/:schema/:table`). All carry
  `permission: "db"`.
- **Module key** `"db"`; settings prefix `db_`.

## What this module does NOT do

- **No Ecto schemas.** The module reads `pg_stat_user_tables`,
  `information_schema.columns` and `information_schema.triggers` directly via
  raw SQL through `PhoenixKit.RepoHelper.query/2`. There is no domain model.
- **No Errors module.** `fetch_row/3` returns `{:error, atom}` shapes
  (`:not_found`, `:invalid_id`, `:invalid_identifier`), but those do not
  surface to UI flashes (the LVs render an empty state or redirect). If a
  future code path surfaces them, copy the shape of
  `phoenix_kit_locations`' `lib/phoenix_kit_locations/errors.ex`.
  `fetch_row/3` must never raise: `parse_row_id/1` reads integer-or-uuid off
  the string alone and cannot know the primary key's type, so a numeric id
  against a `uuid` column reaches Postgrex as the wrong type. Postgrex raises
  there instead of returning an error tuple, and the Activity feed calls this
  from `handle_info/2`, where an escaping exception kills the LiveView. The
  query is wrapped so that becomes `{:error, :invalid_id}`.
- **No write surface to user data.** The module is read-only against
  arbitrary tables. The only mutating operations it owns are the trigger DDL
  (`CREATE OR REPLACE FUNCTION`, `CREATE TRIGGER`, `DROP TRIGGER`) and the
  `db_enabled` settings toggle.
- **No `Activity` wrapper module.** Only one mutation logs activity (the
  module enable/disable toggle in `phoenix_kit_db.ex`). A dedicated wrapper
  is over-engineering for one call site; copy
  `phoenix_kit_staff/lib/phoenix_kit_staff/activity.ex` if more call sites
  appear.
- **No migrations, no tables, no `route_module/0`, no own gettext backend.**
  Trigger install is runtime DDL, not a migration chain.
- **Triggers are never auto-removed.** `remove_trigger/2` and
  `remove_all_triggers/0` exist for ops; nothing in the UI calls them.

## Commands

```bash
mix deps.get
createdb phoenix_kit_db_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Repo-local aliases and details:

- `mix test.setup` (`ecto.create` on the test repo) is the alias equivalent of
  `createdb`; `mix test.reset` drops and recreates it.
- `mix test --exclude integration` runs the unit level only.
- `mix precommit` here is `compile --force --warnings-as-errors`,
  `deps.unlock --check-unused`, `mix hex.audit`, then `quality.ci`
  (`format --check-formatted`, `credo --strict`, `dialyzer`). It checks
  formatting rather than applying it, so run `mix format` first.
- `mix quality` is `format` + `credo --strict` + `dialyzer` (applies formatting).

## Conventions

- **Module key** is `"db"`; tab ids are `:admin_db`, `:admin_db_overview`,
  `:admin_db_activity`, `:admin_db_show`; URL segments use hyphens, never
  underscores (the behaviour test asserts no `_` in any tab path).
- **Path helpers:** `PhoenixKitDb.Paths` (`index/0`, `activity/0`, `show/2`),
  each built on `PhoenixKit.Utils.Routes.path/1` so the host's URL prefix and
  locale apply. Never hardcode `/admin/db` in an LV or template.
- **Routing:** every tab in `admin_tabs/0` carries `live_view:`; `route_module/0`
  is unset. The parent tab uses `match: :prefix` so subtabs stay highlighted on
  any `/db/*` page; the Overview subtab sits at the parent's path with
  `match: :exact`; Show is `visible: false`. Never hand-register these routes
  in a host router.
- **LiveView macro:** all three LVs `use PhoenixKitWeb, :live_view` with
  colocated `*.html.heex` templates. Templates do NOT wrap in
  `PhoenixKitWeb.Components.LayoutWrapper.app_layout`; `live_session
  :phoenix_kit_admin` applies the layout.
- **gettext:** core's `PhoenixKitWeb.Gettext` via the runtime form
  `Gettext.gettext(PhoenixKitWeb.Gettext, "...")`; plurals via
  `Gettext.ngettext/4`. Every user-facing string in
  `lib/phoenix_kit_db/web/**/*.{ex,heex}` is wrapped. `:page_title` assigns
  are wrapped except where they are programmatic identifiers
  (`schema.table`). Translation catalogs live in core, not here, and the
  runtime form is invisible to `mix gettext.extract`, so a new msgid must be
  added to core's `priv/gettext` by hand.
- **JS hooks:** the rule is a prebuilt bundle declared by `js_sources/0` under a
  namespaced global, never registered from an inline `<script>` (morphdom does
  not execute inserted script tags, so an inline hook vanishes on LiveView
  navigation). This module ships one hook, `PhoenixKitDbTableScroller`, in
  `priv/static/assets/phoenix_kit_db.js` under the global `PhoenixKitDbHooks`,
  declared by `js_sources/0`. A new hook goes in that same bundle, under a
  `PhoenixKitDb`-prefixed name — core's `:phoenix_kit_js_sources` compiler
  folds every bundle into `window.PhoenixKitHooks` last-write-wins, so an
  unprefixed name can clobber another module's or core's.
- **`enabled?/0`** reads `db_enabled` via `Settings.get_boolean_setting/2`,
  rescues every error AND catches `:exit`, and returns `false` in both cases
  so a sandbox-pool exit or a missing table does not surface as a crash.
- **Activity logging:** only the module toggle logs, as `db.module_enabled` /
  `db.module_disabled` with `module: "db"`, `mode: "manual"`,
  `resource_type: "module"`, empty metadata and no actor (core's Modules page
  invokes `enable_system/0` without threading a user). The call is guarded by
  `Code.ensure_loaded?(PhoenixKit.Activity)` and rescues `Postgrex.Error`,
  `DBConnection.OwnershipError` and `:exit`. `ensure_trigger/2` deliberately
  never logs: it fires on every Show mount and would drown the audit feed.
  No PII is written.
- **Soft-delete sentinel:** none (no schemas).
- **PubSub:** every subscribe/broadcast goes through `PhoenixKitDb.PubSub`;
  never hardcode a topic string. LVs subscribe through
  `PhoenixKitDb.Listener.subscribe/2` / `subscribe_all/0`, which warn when the
  Listener is not running.
- **Identifier validation:** `safe_quote_ident/1` and `safe_qualified_table/2`
  in `phoenix_kit_db.ex` are the only API for splicing `schema`/`table`/
  `column` names into SQL. They reject anything outside `[a-zA-Z0-9_]` with
  `{:error, :invalid_identifier}` and never raise. The internal
  `quote_ident!/1` runs only on input already validated upstream. Trigger names
  replace disallowed characters with `_`.
- **Trigger install is idempotent** and race-safe: a concurrent creator's
  `duplicate_object` reply is folded into `:ok`, because the win condition is
  "the trigger exists".
- **ShowLive subscribes AFTER `table_preview/3`** so a bogus identifier never
  leaks a subscription; a broadcast in that gap is dropped and the next
  `:table_changed` catches the LV up. ActivityLive calls
  `ensure_trigger("public", "phoenix_kit_settings")` on mount so the
  notification function is `CREATE OR REPLACE`d with the current payload
  format.
- **`handle_info/2` catch-all:** every LV and the Listener has a defensive
  catch-all that logs at `:debug` and returns `{:noreply, ...}`. Never silent.
- **Core pin stays a two-segment `~> 2.0`.** `test/core_pin_conformance_test.exs`
  fails on a three-segment form (which excludes the next core minor and breaks
  `mix deps.get` for every host) and on a committed `path:` dep.

### Landmines

- The Show page's fake scrollbar hook lives in
  `priv/static/assets/phoenix_kit_db.js`, not in the template. It used to be an
  inline `<script>` registering `DBTableScroller` on `window.PhoenixKitHooks`,
  which works on a hard load and is dead after any LiveView navigation into the
  page — morphdom does not execute a `<script>` it inserts, and the host's
  `LiveSocket` has already snapshotted the hooks map. Editing the hook means
  editing the bundle; adding one back into the template re-breaks it.
- `mix precommit` runs `format --check-formatted`; an unformatted file fails
  it after the compile step. Run `mix format` first.
- `test/test_helper.exs` `Code.require_file`s each `test/support/*.ex` by name
  because `mix test` no longer auto-loads `elixirc_paths` support modules at
  helper time. A new support module is "undefined" until added to that list.
- `Settings.update_*` writes a process-wide ETS cache, so tests that call
  `enable_system/0` / `disable_system/0` run `async: false` and reset the
  toggle afterwards, or later tests see the wrong state.
- The Listener is not in the test Endpoint's supervision tree. A test that
  needs the `handle_info({:notification, ...})` path does
  `start_supervised!(PhoenixKitDb.Listener)` and drives it with `send/2`; the
  Listener tolerates a missing DB (`{:ok, %{conn: nil}}`).

## Architecture

```
lib/phoenix_kit_db.ex                  PhoenixKit.Module impl + query helpers + trigger DDL
lib/phoenix_kit_db/listener.ex         Postgrex.Notifications GenServer (auto-reconnect)
lib/phoenix_kit_db/paths.ex            index/0, activity/0, show/2
lib/phoenix_kit_db/pub_sub.ex          topic constants + subscribe/broadcast wrappers
lib/phoenix_kit_db/web/index_live.*    table list + stats
lib/phoenix_kit_db/web/show_live.*     row preview + fake-scrollbar container
lib/phoenix_kit_db/web/activity_live.* live feed with per-key diff highlighting
priv/static/assets/phoenix_kit_db.js   PhoenixKitDbHooks bundle (fake-scrollbar hook)
```

Public API in `PhoenixKitDb`: `database_stats/0`, `list_tables/1`,
`table_preview/3`, `fetch_row/3`, `ensure_trigger/2`, `remove_trigger/2`,
`has_trigger?/2`, `list_triggered_tables/0`, `remove_all_triggers/0`,
`notify_channel/0`. `children/0` returns `[PhoenixKitDb.Listener]`, which the
host's `PhoenixKit.Supervisor` starts when the module is enabled.
`css_sources/0` returns `[:phoenix_kit_db]`; `js_sources/0` returns the one
bundle, `priv/static/assets/phoenix_kit_db.js` under the global
`PhoenixKitDbHooks`. `priv` is in the Hex package's `files:` list, so the
bundle reaches consumers.

### Postgres objects (runtime DDL, not migrations)

| Object | Name | Notes |
|---|---|---|
| Notification function | `phoenix_kit_notify_table_change()` | plpgsql; picks the row PK as `uuid`, then `id`, then empty; `pg_notify`s on the channel |
| Channel | `phoenix_kit_db_changes` | `notify_channel/0` |
| Per-table trigger | `phoenix_kit_db_change_<schema>_<table>` | AFTER INSERT OR UPDATE OR DELETE, FOR EACH ROW; installed lazily on first Show view |
| Payload | `schema.table:OPERATION:row_id` | `row_id` is `""` when the table has neither `uuid` nor `id` |

### PubSub (via `PhoenixKit.PubSub.Manager`)

| Topic | String | Subscribers |
|---|---|---|
| `topic_all/0` | `phoenix_kit_db:all` | Index and Activity pages |
| `topic_table/2` | `phoenix_kit_db:<schema>.<table>` | Show page (per-table, so unrelated tables do not refresh it) |

Message shape: `{:table_changed, schema, table, operation, row_id}` where
`operation` is `"INSERT"` / `"UPDATE"` / `"DELETE"` and `row_id` may be `nil`.
The Listener broadcasts every parsed notification on both topics.

### Settings, permissions, data

- Setting `db_enabled` (boolean): read by `enabled?/0`, toggled from Admin ->
  Modules via `enable_system/0` / `disable_system/0`.
- Permission key `"db"` (`permission_metadata/0`: label "DB", icon
  `hero-server-stack`). Every tab uses it. The Owner role inherits it; custom
  roles get it from the roles matrix.
- Data model: none. Stats come from `pg_stat_user_tables`; columns from
  `information_schema.columns`; trigger presence from
  `information_schema.triggers`. Row preview orders by `uuid`, then `id`, then
  `ctid`; row search casts textual columns (`text`, `character varying`,
  `citext`, `json`, `jsonb`, `uuid`, `inet`, ...) to TEXT and `ILIKE`s them.
- Page sizes: tables 5..100 (default 20); rows 10..200 (default 50 in
  `table_preview/3`, 20 in ShowLive's allowed list `[10, 20, 50, 100, 200]`).

## Database & migrations

None. No tables of its own; `migration_module/0` is unset. The module's only
DDL is the runtime trigger install through `RepoHelper.query/2` (see the
Postgres objects table), which is idempotent and reversible with
`remove_all_triggers/0`. There are no schemas, so the UUIDv7-PK and
`use PhoenixKit.SchemaPrefix` rules have no site here; they apply the moment a
table-backed schema is added.

## Testing

Test DB `phoenix_kit_db_test` (suffixed with `MIX_TEST_PARTITION` when set).
`config/test.exs` honours `PGUSER`, `PGPASSWORD` and `PGHOST` (defaults
`postgres` / `postgres` / `localhost`); on a Mac with brew Postgres use
`PGUSER=maxdon`. It also points `config :phoenix_kit, repo:` at the test repo,
without which every `RepoHelper` call crashes.

`test/test_helper.exs`:

- checks for the DB with `psql -lqt` (falls through to a connect attempt when
  `psql` is missing), then starts `PhoenixKitDb.Test.Repo`, builds the schema
  with `PhoenixKit.Migration.ensure_current(PhoenixKitDb.Test.Repo, log: false)`
  and puts the sandbox in `:manual` mode;
- excludes `:integration` when the DB is unavailable;
- starts `PhoenixKit.PubSub.Manager` and `PhoenixKit.ModuleRegistry`;
- pins `:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")` so
  `Paths.*` produce paths the test router matches (admin paths always get the
  default `en` locale, so the router scope is `/en/admin/db`);
- starts `PhoenixKitDb.Test.Endpoint` only when the DB is available.

Three levels:

- **Unit** (`test/phoenix_kit_db_test.exs`, `test/core_pin_conformance_test.exs`):
  behaviour compliance, Paths, the input-validation branches of `fetch_row/3`
  / `ensure_trigger/2` / `remove_trigger/2` (they short-circuit before any
  `RepoHelper` call). Run without Postgres.
- **Listener** (`test/phoenix_kit_db/listener_test.exs`): `start_supervised!`
  the Listener and drive `handle_info({:notification, ...})` via `send/2`;
  no Postgres needed.
- **Integration**: `test/phoenix_kit_db/activity_logging_test.exs` (`DataCase`)
  and the LiveView smoke tests in `test/phoenix_kit_db/web/*_live_test.exs`
  (`LiveCase`, driven through `Phoenix.LiveViewTest.live/2` against the test
  Endpoint and Router). Both cases auto-tag `:integration`.

Support modules (`test/support/`):

- `test_repo.ex`: `PhoenixKitDb.Test.Repo`.
- `test_endpoint.ex`: minimal `Phoenix.Endpoint`, `server: false`.
- `test_router.ex`: routes matching `PhoenixKitDb.Paths.*` under
  `/en/admin/db`, in a `live_session` with the `:assign_scope` hook.
- `test_layouts.ex`: root + app layouts; `app/1` renders flashes as
  `#flash-info` / `#flash-error` / `#flash-warning` so tests can assert flash
  content.
- `hooks.ex`: `:assign_scope` `on_mount` hook mirroring the session's
  `"phoenix_kit_test_scope"` onto `phoenix_kit_current_scope` +
  `phoenix_kit_current_user`.
- `data_case.ex`: `PhoenixKitDb.DataCase`, auto-tags `:integration`, sandbox
  setup.
- `live_case.ex`: `PhoenixKitDb.LiveCase` with `fake_scope/1` (a real
  `%PhoenixKit.Users.Auth.Scope{}`; defaults `roles: [:owner]`,
  `permissions: ["db"]`) and `put_test_scope/2`.
- `activity_log_assertions.ex`: `assert_activity_logged/2` and
  `refute_activity_logged/2`, querying `phoenix_kit_activities` directly.

Known test noise (all cosmetic):

- `[error] ... (Postgrex.Notifications) failed to connect to Postgres: ...
  database "phoenix_kit_db_test" does not exist`: fires while the DB does not
  exist yet; the Listener tolerates it.
- `[warning] PhoenixKitDb.Listener is not running`: on every LV smoke test,
  because the Listener is not in the test Endpoint's supervision tree (the
  tests exercise the LV's `handle_info({:table_changed, ...})` paths, not real
  notifications).
- `[error] Failed to query setting db_enabled: %DBConnection.OwnershipError{...}`:
  the `enabled?/0` rescue firing in the unit phase before any sandbox owner
  exists; the `is_boolean(enabled?())` assertion still passes.

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- The `PhoenixKitDbTableScroller` bundle is hand-written, unminified ES —
  there is no build step and nothing checks it beyond `PhoenixKitDbTest`'s
  string assertions. Trigger for adding a real JS toolchain (lint/bundle):
  a second hook, or the first bundle change that a string assertion cannot
  catch.
