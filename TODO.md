# TODO

Short, actionable items. The long-form engineering backlog lives in
[`docs/roadmap.md`](docs/roadmap.md).

## Upstream reports to file

- [ ] **Report to Firebird: semi-join `IN` / `EXISTS` loses a `0` match behind a `NULL`** (found 2026-10-03).
  - Draft issue: [`docs/upstream/firebird-hashjoin-semi-null-zero.md`](docs/upstream/firebird-hashjoin-semi-null-zero.md)
  - Easy reproduction (two rows, pure SQL, creates and drops its own database): [`docs/upstream/firebird-hashjoin-semi-null-zero.sql`](docs/upstream/firebird-hashjoin-semi-null-zero.sql)
    `isql -q -user SYSDBA -pas masterkey -i docs/upstream/firebird-hashjoin-semi-null-zero.sql`
  - File at <https://github.com/FirebirdSQL/firebird/issues>, then record the issue link here and in the draft's **Status** line.
  - When the engine is fixed, promote the five pinned divergences in `qa/serve-real-nanrow.sh` section 6 to `both` cells.

## Environment follow-ups (this box)

- [ ] Decide which engine build is the reference for the engine-side pins that are red here
      (`serve-real-widenum.sh` 24, `serve-real-semchk.sh` 47, `serve-real-unionlimit.sh` 6), and for
      `serve-real-gbak.sh` (external table after an engine restore) and `serve-real-tz.sh` (named zone).
      All of them are red identically on the binary before 2026-10-02, so they aren't regressions. See the
      roadmap's "ENVIRONMENT FINDING".
- [ ] The local engine stopped accepting connections once (2026-10-03 ~01:52) and needed
      `sudo systemctl restart firebird`. It didn't reproduce; if it recurs, capture `ss -ltn | grep 3050`
      and the engine's `firebird.log` before restarting.
