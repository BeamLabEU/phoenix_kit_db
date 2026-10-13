# PR #7 review: Quality sweep (masking, total formatter, trigger and feed hardening)

Reviewer: Claude. Scope: `ed818b5` (34 files). Read in full: `cells.ex`,
`phoenix_kit_db.ex`, `listener.ex`, the three LiveViews and their templates.
Tests were read where a finding touches them. Baseline on `main`: 292 tests,
1 failure (see finding 1).

## Findings

### BUG - MEDIUM

**1. `IndexLiveTest` "renders the page heading" fails against core 2.61.0.**
The test asserts the header subtitle, but core's `admin_page_header` now
renders `subtitle` only when the site-wide `show_page_descriptions` setting is
on (off by default). The page is fine; the test pinned a string the page no
longer shows. Fixed: the test asserts the `<h1>`; the stale example in
`test/support/live_case.ex` follows.

**2. A row id containing `:` drops the notification.**
`Listener.parse_payload/1` split on every `:`, so a text `id` such as
`user:42:web` produced four parts, hit the `:error` branch and the event
vanished from the Show refresh and the Activity feed (with a warning that
echoed the payload). Schema and table names cannot contain `:` (identifier
rule), so only the first two colons delimit. Fixed with `parts: 3`. The old
test "swallows payload with too many colons" pinned the bug and was replaced
by one asserting the id arrives whole.

### IMPROVEMENT - MEDIUM

**3. `IndexLive` and `ActivityLive` queried in `mount/3`.**
`database_stats/0` (Index) and `list_table_names/0` (Activity) ran in `mount`,
so each ran twice per page load. AGENTS.md says a page loads its data in
`handle_params/3` only, and the PR's own "loads once" test covered only
`list_tables/1`, which is why this slipped through. Fixed: both moved to
`handle_params/3` (Activity gained one; `?table=` is read there). Tests count
the stats and table-listing statements: two each, one per render pass.

### IMPROVEMENT - MEDIUM (recorded, not fixed)

**4. `ensure_notify_function/0` is `CREATE OR REPLACE FUNCTION` on every Show
and Activity mount, outside `run_ddl/1`.** Two sessions replacing the same
function at once can fail with `tuple concurrently updated`. The Show page
degrades to the "live updates unavailable" notice and the Activity page
ignores the result, so nothing breaks. An advisory lock would serialise it,
but a transaction-scoped one would be held until the end of the outer
transaction under the SQL sandbox and stall async tests. Left as is; the
failure is self-healing on the next view.

**5. `pg_notify` can fail the user's write.** The trigger sends
`schema.table:OP:row_id`. A text `id` over roughly 7.9 kB makes `pg_notify`
raise `payload string too long`, which aborts the INSERT/UPDATE on the watched
table. Only a pathological text key reaches it (uuid and integer ids are tiny).
Not fixed here: truncating would produce an id the feed cannot look up, and
changing the function is a deliberate format decision for the maintainer.

**6. The secret-name denylist is short.** `Cells.secret_column?/1` misses
names such as `pwd`, `signing_key`, `encryption_key`, `auth_key`. The doc
already says masking is by name and over-matches on purpose, and AGENTS.md
says grant `db` like `psql`. Adding fragments is cheap; deciding which
over-matches are acceptable is the maintainer's call. Not changed.

### NITPICK (recorded)

- Row search with no searchable column (every text column masked, or a table
  of only JSON columns) returns all rows, so a search appears to match
  everything. Showing "no searchable columns" would be clearer.
- `ShowLive` `:debounced_refresh` does not redirect when the table has been
  dropped meanwhile, nor clamp the page when rows were deleted past the last
  page; both render the empty state.
- Overlapping refreshes each schedule their own `:clear_highlights`, so the
  first timer can clear a later refresh's highlights early.
- `ActivityLive` always installs a trigger on `public.phoenix_kit_settings`
  (to refresh the notify function), which contradicts the Overview line "a
  table nobody has opened is not watched" for that one table, and assumes the
  `public` schema.
- `installed_triggers_from_sql/0` uses `starts_with/2` (PostgreSQL 11+).
- `fetch_row/3` cannot look up a text primary key: `parse_row_id/1` accepts
  only integers and UUID-shaped strings, so any other text id is
  `:invalid_id`, and an all-digit text id is parsed to an integer and then
  rejected by the encode backstop.

## Checked and found sound

- Masking runs before any assign on the Show path (`table_preview/3`), the
  single-row path (`fetch_row/3`) and the Activity feed (which only sees
  `fetch_row/3` output). The NOTIFY payload carries ids, never row data.
- Search/masking parity: `searchable_column?/2` mirrors `sanitize_row/2`; JSON
  columns are excluded by type.
- Identifier handling: `\A...\z` anchors, `@supported_tables_sql` and
  `safe_quote_ident/1` accept the same names; `SET LOCAL lock_timeout`
  interpolates a validated integer.
- Trigger naming stays within 63 bytes with a stable hash suffix; lookup is by
  prefix plus function, so truncation cannot hide a trigger.
- `Cells.format/2` is total (structs before the plain-map clause, `rescue` and
  `catch` around everything, `inspect` fallback also guarded).
- Activity buffering: constant work per message, bounded buffer, Pause drains
  the backlog, the timer flag is reset on flush.
- The `uuid` parameter-side cast (`$1::text::uuid`) keeps the primary key
  index usable.

## Verification

`mix format`, `mix test` (294 tests, 0 failures), `mix precommit` clean.
