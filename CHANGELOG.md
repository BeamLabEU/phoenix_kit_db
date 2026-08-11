# Changelog

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
