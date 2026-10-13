# PhoenixKitDB

Database explorer module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Browse Postgres tables, preview rows, and watch INSERT/UPDATE/DELETE traffic in real time — all from the admin dashboard.

## Features

- **Table list** with row counts and total size at `/admin/db`
- **Row preview** with pagination and live updates at `/admin/db/:schema/:table`
- **Live activity feed** showing mutations of the tables you have opened, with diff highlighting, at `/admin/db/activity`

Live updates are driven by Postgres `LISTEN/NOTIFY`. A trigger function (`phoenix_kit_notify_table_change`) plus per-table `phoenix_kit_db_change_<schema>_<table>` triggers are installed lazily the first time a table is viewed; a dedicated `Postgrex.Notifications` connection (the `Listener` GenServer) parses the `phoenix_kit_db_changes` channel and rebroadcasts via `PhoenixKit.PubSub.Manager`.

A table is watched only once its page has been opened, so the activity feed shows nothing for a table nobody has viewed. Opening Activity updates the notification function without watching any additional tables. Function installation and upgrades are serialized; an unchanged function is not replaced. Disabling the module removes every trigger it installed; one whose table was locked at that moment is logged and stays until `PhoenixKitDb.remove_all_triggers()` is run again. Installing or removing a trigger waits at most 2 seconds for its table lock (`config :phoenix_kit_db, ddl_lock_timeout_ms: 2000`); the same timeout bounds a function upgrade waiting for another installer. If the lock is not granted the page still loads, without live updates.

Notifications carry `schema.table:OPERATION:row_id`; text IDs may contain colons. If the ID would make the payload reach PostgreSQL's 8,000-byte limit, the notification omits the ID and still refreshes the table. That event has no row detail in Activity, and the watched-table write succeeds.

Tables whose schema or table name contains anything other than letters, digits and underscore are not listed; the table list says how many were left out.

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_db, "~> 0.2"}
  ]
end
```

The module auto-discovers via beam scanning. Enable it from **Admin → Modules** (the setting key is `db_enabled`).

## Permissions

Requires the `db` permission. Anyone in the Owner / Admin role inherits it; custom roles can be granted access from the roles matrix.

### What `db` access exposes

The explorer is read-only, but it reads **every row of every table in the database**, including tables that belong to other modules and to the host app. Treat the `db` permission like handing someone `psql` access.

Values in secret-named columns are always masked. A cell is replaced with `••••••` when its column name contains `password`, `passwd`, `passphrase`, `pwd`, `secret`, `token`, `api_key`, `apikey`, `access_key`, `private_key`, `signing_key`, `encryption_key`, `auth_key`, `credential` or `salt`, starts with `hashed_` or `encrypted_`, or ends with `_hash` (case-insensitive). The same rule applies to keys inside JSON values. The real value is dropped on the server right after the query, so it is not in the page, in the LiveView's state or in anything sent to the browser, and there is no control to reveal it. `NULL` stays `null`.

In a key/value table (one with a `key` or `name` column), a row whose key or name matches that rule has its `value*` columns masked too.

Row search cannot be used to confirm a guess at a masked value: it reads no secret-named column, no JSON column, and no `value*` column of a table that has a `key` or `name` column (case-insensitive). A search with no eligible columns returns no matches. Columns whose names contain unsupported identifier characters are displayed but excluded from search.

Masking is by name only. A secret stored under a neutral name in any other shape (a `data` column, say) is shown as it is.

## License

MIT
