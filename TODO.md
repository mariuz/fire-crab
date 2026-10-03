# TODO

Short, actionable items. The long-form engineering backlog lives in
[`docs/roadmap.md`](docs/roadmap.md).

## Upstream reports to file

- [x] **Report to Firebird: semi-join `IN` / `EXISTS` loses a `0` match behind a `NULL`** (found 2026-10-03). **REPORTED 2026-10-03** on the existing issue [#9158](https://github.com/FirebirdSQL/firebird/issues/9158) (same SEMI-join defect, there via UUID hash collisions) rather than as a duplicate: <https://github.com/FirebirdSQL/firebird/issues/9158#issuecomment-5965771034>
  - Draft issue: [`docs/upstream/firebird-hashjoin-semi-null-zero.md`](docs/upstream/firebird-hashjoin-semi-null-zero.md)
  - Easy reproduction (two rows, pure SQL, creates and drops its own database): [`docs/upstream/firebird-hashjoin-semi-null-zero.sql`](docs/upstream/firebird-hashjoin-semi-null-zero.sql)
    `isql -q -user SYSDBA -pas masterkey -i docs/upstream/firebird-hashjoin-semi-null-zero.sql`
- [ ] Watch [#9158](https://github.com/FirebirdSQL/firebird/issues/9158): when the engine is fixed, promote the five pinned divergences in `qa/serve-real-nanrow.sh` section 6 to `both` cells, and re-run the repro script.

## Environment follow-ups (this box)

- [ ] Decide which engine build is the reference for the engine-side pins that are red here
      (`serve-real-widenum.sh` 24, `serve-real-semchk.sh` 47, `serve-real-unionlimit.sh` 6), and for
      `serve-real-gbak.sh` (external table after an engine restore) and `serve-real-tz.sh` (named zone).
      All of them are red identically on the binary before 2026-10-02, so they aren't regressions. See the
      roadmap's "ENVIRONMENT FINDING".
- [ ] The local engine stopped accepting connections once (2026-10-03 ~01:52) and needed
      `sudo systemctl restart firebird`. It didn't reproduce; if it recurs, capture `ss -ltn | grep 3050`
      and the engine's `firebird.log` before restarting.
