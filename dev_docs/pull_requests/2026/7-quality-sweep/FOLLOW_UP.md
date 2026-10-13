# PR #7 follow-up

| # | Finding | Resolution |
|---|---------|------------|
| 1 | Index heading test fails on core 2.61.0 | Fixed: test asserts the `<h1>`; stale example in `live_case.ex` updated |
| 2 | Row id with `:` drops the notification | Fixed: `String.split(payload, ":", parts: 3)`; test replaced |
| 3 | Index stats and Activity table list loaded in `mount/3` | Fixed: moved to `handle_params/3`; per-render-pass query-count tests added |
| 4 | `CREATE OR REPLACE FUNCTION` race on concurrent mounts | Not fixed: self-healing, advisory lock conflicts with the sandbox |
| 5 | Oversized text id can make `pg_notify` fail the write | Not fixed: maintainer decision on the payload format |
| 6 | Short secret-name denylist | Not fixed: maintainer decision on acceptable over-matching |
| nits | See review | Recorded only |
