# Changelog

## 0.1.1

- Fix ExDoc warning: reference `PhoenixKit.Module.children/0` as a callback (`c:` prefix) so it autolinks instead of resolving as an undefined function.

## 0.1.0

- Initial extraction from `phoenix_kit` core (`lib/modules/db/`).
- Setting key renamed: `db_explorer_enabled` → `db_enabled`.
- Module namespace renamed: `PhoenixKit.Modules.DB.*` → `PhoenixKitDb.*`.
- LiveView module names: `PhoenixKitDb.Web.{IndexLive, ShowLive, ActivityLive}`.
- Routes registered via `admin_tabs/0` (visible parent + Activity subtab; hidden Show subtab for `:schema/:table`).
- `enabled?/0` now rescues both general errors AND `:exit` signals so sandbox-pool exits during tests don't surface as 1-in-N flakes.
