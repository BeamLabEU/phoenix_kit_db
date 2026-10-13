# Current version and PR #7 follow-up review

Reviewer: Codex. Date: 2026-10-13. Baseline: `c264ef2` on `main`, version
0.2.1. Scope: all library modules, all three LiveViews and templates, the JS
hook bundle, dependency/package declarations, and relevant tests. Claude's
review and fixes were checked against the current code. His review file was
left unchanged.

Baseline verification: `mix test` passed with 294 tests, including integration
tests against the real test database.

## Findings and fixes

### BUG - HIGH: notification size could abort watched-table writes

The trigger appended an arbitrary text `id` to its NOTIFY payload without
checking the byte length. PostgreSQL rejects payloads of 8,000 bytes or more,
which aborts the originating statement. This is possible even without a text
primary key: a table may have a large non-key `id` column.

Fixed: check the complete payload with `octet_length`. If the ID cannot fit,
send the normal `schema.table:OPERATION:` event without an ID. The Listener
already normalizes an absent ID to `nil`, so refreshes and operation entries
continue while Activity omits the row lookup. IDs are never truncated.

A committed integration test receives real notifications for colon-containing
IDs, payloads of exactly 7,999 and 8,000 bytes, and oversized multibyte IDs. It
also verifies UPDATE and DELETE succeed and notify without an oversized ID.
The wire format is unchanged.

### BUG - HIGH: missing secret names and uppercase key/value leaks

`pwd`, `signing_key`, `encryption_key` and `auth_key` were absent from the
secret-name fragments. Additionally, the row-level key/value masking rule
only recognized lowercase column names: a `Key` / `Value` table exposed the
same secret that a `key` / `value` table masked.

Fixed: add those explicit fragments and apply case-insensitive column checks
to both sanitization and the corresponding search exclusion. Tests cover the
new names and a real uppercase key/value table, including search resistance.
The documented policy still deliberately over-matches names, never contents.

### BUG - MEDIUM: function replacement raced and ignored the DDL timeout

Every Show or Activity mount replaced the shared function even when its body
was unchanged. Concurrent replacement could fail with a catalog-update race,
and this DDL bypassed `run_ddl/1` and its configured lock timeout.

Fixed: compare the installed `pg_proc.prosrc` with the desired body first.
Only installation/upgrades acquire a transaction advisory lock inside
`run_ddl/1`, then recheck before replacing the function. Ordinary page views
neither replace the function nor acquire the advisory lock. This avoids a
session lock leaking through the connection pool and works with the existing
serial integration suites and sandbox rollback.

Tests prove eight concurrent committed installers all succeed with exactly
one replacement; a contended advisory lock returns `:lock_timeout` promptly
and installation recovers after release. A repeated trigger installation
issues neither function DDL nor an advisory-lock query.

### BUG - MEDIUM: text primary-key row lookups were rejected or changed

`parse_row_id/1` accepted only integers and UUIDs. It rejected IDs containing
colons and converted numeric text to integers, losing leading zeros. Activity
could receive these events after Claude's parser fix but still show no row.

Fixed: preserve valid text unchanged and defer interpretation to the primary
key type. Integer keys parse strictly; text/varchar keys keep their spelling.
UUIDs retain the parameter-side cast that allows use of the primary key index.
Malformed table terms now return `:invalid_identifier` rather than raising a
function-clause exception. Tests cover text/varchar IDs, leading zeros, empty
text keys, quotes, missing rows, integer binding and range errors.

### BUG - MEDIUM: included index columns looked like composite primary keys

`ANY(pg_index.indkey)` included non-key columns from `PRIMARY KEY ... INCLUDE`.
A single-column primary key with an included label therefore returned
`:composite_primary_key`, and preview row identity used the changing label.

Fixed: restrict attribute membership to the first `indnkeyatts` entries of the
index vector. A real INCLUDE primary-key test covers lookup and row identity.

### BUG - MEDIUM: varchar/citext search and unsupported column names

`~w(text character varying ...)` split `character varying` into two strings,
so varchar columns were never searched. `citext` columns appeared as
`USER-DEFINED` in `information_schema.columns`, also bypassing the allowlist.
An otherwise supported table with a punctuation-containing text column raised
inside `quote_ident!/1` on search.

Fixed: use explicit type strings, recognize citext's catalog type, and omit
column names that the existing identifier validator cannot quote. Tests cover
varchar, fixed-width character, citext and a supported table with an
unsupported column name. Such columns remain visible in previews.

### BUG - MEDIUM: search with no eligible columns returned every row

A nonempty search on a table of only masked, JSON or non-text columns built
no WHERE clause, giving the appearance that every row matched every guess.

Fixed: use `WHERE FALSE` when there are no eligible columns. An empty search
still returns the unfiltered preview. Integration tests cover both behaviors.

### BUG - MEDIUM: pending Activity events survived Clear and filter changes

Clear reset displayed entries but left the pending notification buffer intact;
the next flush restored cleared events. A filter change could likewise admit
events accepted under the previous filter after the controls changed.

Fixed: discard the pending buffer on either action, preserving the scheduled
timer flag so new events still flush. Tests drive the actual Clear button and
filter form, flush pending events, and verify subsequent matching events work.
Already displayed entries retain the existing filter semantics.

### BUG - MEDIUM: stale pages and highlight timers after refresh

Removing rows past the last page left Show on an empty, out-of-range page.
Dropping a table left it displaying an empty preview rather than redirecting.
Each highlight refresh scheduled an untagged timer, allowing an earlier timer
to clear a newer refresh before its three seconds elapsed. Highlights also
survived unrelated pagination patches.

Fixed: clamp list/preview pages before querying; use the existing not-found
redirect on refresh; identify highlight timers with a reference stored in
socket private data; reset highlights on page changes. Tests cover last-page
deletion, table removal and a stale timer arriving after a newer refresh.

### BUG - MEDIUM: Index discarded the literal search term `1`

The URL builder removed all values equal to `1`, rather than only the default
page parameter. Searching for `1` silently removed the search itself.

Fixed: apply the default-value rule only to `page`, and parse Index page
strings strictly. The real search-form test verifies `?search=1` survives.

### IMPROVEMENT - MEDIUM: Activity watched a table as an update side effect

Opening Activity called `ensure_trigger("public", "phoenix_kit_settings")`
solely to refresh the function. This contradicted lazy table watching and
assumed a public-schema settings table.

Fixed: expose `ensure_notify_function/0` and call it directly, logging any
failure. A LiveView test verifies opening Activity installs no settings
trigger. README, AGENTS.md and payload documentation reflect the changes.
Stale dependency-floor commentary in `mix.exs` was also removed.

### IMPROVEMENT - MEDIUM: reject malformed Listener events before broadcasting

The parser accepted arbitrary operation strings and unsupported or empty
schema/table names, even though none can come from this module's triggers.
It also raised if a notification-shaped message carried a non-string payload.

Fixed: validate the operation and both identifiers, and reject non-string
payloads. Listener tests cover these inputs while preserving colon-containing
IDs and normal INSERT/UPDATE/DELETE broadcast behavior.

## Verification

- `mix format` applied.
- `mix test`: 319 tests, 0 failures, with database integration tests enabled.
- `mix precommit`: warnings-as-errors compilation, unused-lock check, Hex
  audit, formatting check, strict Credo and Dialyzer passed. Dialyzer retains
  the repository's two existing ignored warnings; no new warning was ignored.
- `git diff --check` passed.

No version bump, package publication, push or tag is part of this review.

## Remaining design limits

The Activity feed reads the latest committed row when flushing; NOTIFY does
not contain historical row snapshots, and identical notifications in one
transaction may be coalesced by PostgreSQL. A full notification queue can also
fail commit independently of the payload-size fix. These are existing protocol
limits, not promises of an audit log.

Masking remains name-based, and arbitrary punctuation-containing schema/table
names remain unsupported. The JS hook retains the existing hand-written
bundle and string-level tests; this sweep changes no JS and adds no toolchain.

PostgreSQL references: [NOTIFY](https://www.postgresql.org/docs/current/sql-notify.html)
and [advisory locks](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS).
