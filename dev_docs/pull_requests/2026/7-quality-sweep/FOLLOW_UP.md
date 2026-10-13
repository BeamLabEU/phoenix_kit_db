# PR #7 follow-up

| # | Finding | Resolution |
|---|---------|------------|
| 1 | Index heading test fails on core 2.61.0 | Fixed: test asserts the `<h1>`; stale example in `live_case.ex` updated |
| 2 | Row id with `:` drops the notification | Fixed: `String.split(payload, ":", parts: 3)`; test replaced |
| 3 | Index stats and Activity table list loaded in `mount/3` | Fixed: moved to `handle_params/3`; per-render-pass query-count tests added |
| 4 | `CREATE OR REPLACE FUNCTION` race on concurrent mounts | Fixed by Codex: compare the function body; serialize only installation/upgrades under the bounded DDL timeout, with a recheck after locking |
| 5 | Oversized text id can make `pg_notify` fail the write | Fixed by Codex: omit an oversized ID while preserving the existing table/operation payload; real byte-limit notification tests added |
| 6 | Short secret-name denylist | Fixed by Codex: add pwd/signing_key/encryption_key/auth_key and cover uppercase key/value masking and search parity |
| nits | See review | Codex fixed empty-search eligibility, stale Show pages/highlight timers, the Activity settings-trigger side effect, and text-PK lookups; PostgreSQL 11+ catalog use remains |

## General library follow-up

[CODEX_REVIEW.md](CODEX_REVIEW.md) records the full sweep, including additional
varchar/citext search fixes, safe handling of unsupported column names, INCLUDE
primary-key handling, pending Activity Clear/filter events, and the literal
Index search term `1`. The original Claude review is preserved.
