# Changelog

## 0.4.0 - 2026-11-13

### Changed

- **Core pin widened to accept core 3.x** (ceiling `< 4.0.0`; the floor is unchanged).

## 0.3.0 - 2026-10-13

### Changed

- **Requires `phoenix_kit >= 2.38.0 and < 3.0.0`** (the module toggle logs through
  core's `PhoenixKit.Activity.log/3`). Adds a `gettext ~> 1.0` dependency: the
  module now ships its own backend with `en`, `et` and `ru` catalogues.
- The Activity page no longer installs a trigger on `phoenix_kit_settings`; it
  only refreshes the notification function. A table is watched once its Show
  page has been opened.
- Row totals above 100,000 rows show the planner estimate, labelled approximate,
  instead of running `COUNT(*)`.
- Tables whose schema or table name is outside `[a-zA-Z0-9_]` are left out of
  every list and counted on the Index page.

### Added

- Secret masking: values in secret-named columns, secret-named JSON keys and
  `value*` columns of secret-keyed key/value rows are replaced by a placeholder
  before they reach the page, on the Show page and the Activity feed. Row search
  never reads anything that masking hides.
- One total value formatter (`PhoenixKitDb.Cells`) for every Postgres type.
- Trigger DDL runs under a lock timeout; `disable_system/0` removes every
  trigger it installed; `remove_all_triggers/0` reports leftovers.
- The notification function is replaced only when its body is outdated, under an
  advisory lock. A row id too large for a notification no longer aborts the write
  (the event is sent without the id).

### Fixed

- A row id containing `:` no longer drops its notification.
- Index and Activity pages load their data once per render pass.
- Row lookup works for uuid, integer and text primary keys, and for primary keys
  with `INCLUDE` columns; citext columns are searched; a search with no
  searchable column matches nothing instead of everything.
- Searching the table list for `1` stays in the URL; out-of-range pages are
  clamped; a table dropped while open redirects with a flash.
- Activity Clear and filter changes discard buffered events; Show highlight
  timers no longer clear a later refresh's highlights.
- Fold-out sections no longer close whenever the page re-renders.
- Page markers are bounded for very large tables.

## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## 0.1.1

- Fix ExDoc warning: reference `PhoenixKit.Module.children/0` as a callback (`c:` prefix) so it autolinks instead of resolving as an undefined function.

## 0.1.0

- Initial extraction from `phoenix_kit` core (`lib/modules/db/`).
- Setting key renamed: `db_explorer_enabled` → `db_enabled`.
- Module namespace renamed: `PhoenixKit.Modules.DB.*` → `PhoenixKitDb.*`.
- LiveView module names: `PhoenixKitDb.Web.{IndexLive, ShowLive, ActivityLive}`.
- Routes registered via `admin_tabs/0` (visible parent + Activity subtab; hidden Show subtab for `:schema/:table`).
- `enabled?/0` now rescues both general errors AND `:exit` signals so sandbox-pool exits during tests don't surface as 1-in-N flakes.
