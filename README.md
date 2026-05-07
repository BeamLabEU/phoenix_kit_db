# PhoenixKitDB

Database explorer module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Browse Postgres tables, preview rows, and watch INSERT/UPDATE/DELETE traffic in real time — all from the admin dashboard.

## Features

- **Table list** with row counts and total size at `/admin/db`
- **Row preview** with pagination, search, and live updates at `/admin/db/:schema/:table`
- **Live activity feed** showing every mutation across all tables with diff highlighting at `/admin/db/activity`

Live updates are driven by Postgres `LISTEN/NOTIFY`. A trigger function (`phoenix_kit_notify_table_change`) plus per-table `phoenix_kit_db_change_<schema>_<table>` triggers are installed lazily the first time a table is viewed; a dedicated `Postgrex.Notifications` connection (the `Listener` GenServer) parses the `phoenix_kit_db_changes` channel and rebroadcasts via `PhoenixKit.PubSub.Manager`.

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_db, "~> 0.1.0"}
  ]
end
```

The module auto-discovers via beam scanning. Enable it from **Admin → Modules** (the setting key is `db_enabled`).

## Permissions

Requires the `db` permission. Anyone in the Owner / Admin role inherits it; custom roles can be granted access from the roles matrix.

## License

MIT
