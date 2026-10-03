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
      (`serve-real-widenum.sh` 24, `serve-real-semchk.sh` 47, `serve-real-unionlimit.sh` 6,
      `serve-real-errvec.sh` 3 - the same AND-operand-order class as semchk), and for
      `serve-real-gbak.sh` (external table after an engine restore) and `serve-real-tz.sh` (named zone).
      All of them are red identically on the binary before 2026-10-02, so they aren't regressions. See the
      roadmap's "ENVIRONMENT FINDING".
- [ ] **The local engine hits an internal mutex fault under heavy parallel load** - its `firebird.log`
      records `Operating system call pthread_mutex_trylock failed. Error code 22` (EINVAL) three times
      (2026-10-02 19:46 and 23:07, when fbguard restarted it; 2026-10-03 05:17, when it instead stopped
      accepting connections - the 3050 accept queue full - and needed `sudo systemctl restart firebird`;
      an earlier wedge at ~01:52 had the same symptom). Every time during a `-j 4` sweep; the first two
      predate any of this work's code. Symptom in gates: `rc=124` timeouts and "the engine printed no
      describe". Check `ss -ltn | grep 3050` (Recv-Q) and the log, restart, re-run the affected gates
      alone; sweeps now run at `-j 3`. Possibly worth an upstream report once it has a narrower trigger.- [x] **The reference engine moved to 6.0.0.2196 (56d656b) on 2026-10-03** (previous install kept as
      `/opt/firebird_20261003_1116.tar.gz`). Two of its laws reached the gates and are followed now:
      DDL under a user savepoint is refused 0A000 (`qa/serve-real-ddlsavepoint.sh`; ddltx, savepointtx,
      gendurable and gencomp adjusted), and an exponent literal whose significand is exactly 2^63 is
      DECFLOAT(34), the INT128 quirk gone (`qa/serve-real-explit.sh`).
- [ ] After that upgrade node-firebird could not log in as SYSDBA (isql could): the installer's SRP
      verifier for SYSDBA tripped node-firebird's SRP client while fresh users worked. Re-setting the
      same password (`ALTER USER SYSDBA PASSWORD 'masterkey'`, a new salt) cleared it. Probably a
      node-firebird SRP edge case (salt / verifier padding) - worth a reproduction from the old
      `security6.fdb` in the tarball and an upstream report, if it reproduces.

## Recorded gaps found on the way (2026-10-03)

- [x] `CAST(LIST(..) AS VARCHAR(n))` answers (`qa/serve-real-listexpr.sh`).
- [x] Every other expression over a LIST (`||`, UPPER, SUBSTRING, COALESCE, CHAR/OCTET_LENGTH, IIF, CASE WHEN,
      ORDER BY) answers, and a computed blob is minted and delivered in its own character set (UTF8 / NONE /
      WIN1252 attachments - listexpr sections 2 and 4).
- [ ] A LIST in HAVING's comparison or LIKE (`HAVING LIST(ID) = '1,2'`) still refuses (listexpr 2b).
- [x] Schema-qualified DDL (`CREATE TABLE PUBLIC.T7 ..`, every kind, a view body over `PUBLIC.T`) and an
      unknown schema's vector (`qa/serve-real-ddlqualified.sh`).
- [x] A select list holding `GEN_ID(..)` / NEXT VALUE FOR beside a stored function call (fnwhere section 10).
- [ ] A generator in an IIF branch, a CASE WHEN condition or under AND / OR, and DISTINCT over a select list with a
      generator column (with or without a call), refuse at prepare.
- [x] An empty PSQL body (`AS BEGIN END`) compiles to the engine's BLR (`qa/serve-real-emptybody.sh`).
- [x] A trigger body with `EXIT;` stores `blr_leave 0` (emptybody section 4).
- [x] A trigger's `DECLARE V INTEGER = 0;` initializer stores the engine's BLR (emptybody section 5).
- [ ] CREATE PROCEDURE / FUNCTION stores no `RDB$DEBUG_INFO` (the engine writes one; triggers do).
- [x] A duplicate CREATE TRIGGER / INDEX / DOMAIN / ROLE answers the engine's already-exists vector (metaupdate).
- [x] A schema-qualified DML target that does not exist answers the -204 `"PUBLIC"."S2"` (dmlunknown section 2).
- [x] UPDATE / DELETE whose WHERE calls PURE stored functions (fnwhere section 8).
- [x] A PURE stored call in a derived table, a join, a UNION branch or a subquery (fnwhere section 9,
      the memo fallback).
- [x] A row window counted by `?` (FIRST ? / SKIP ? / ROWS ? [TO ?] / OFFSET ? / FETCH ?) -
      `qa/serve-real-boundwindow.sh`.
- [ ] Still refused: a window over a navigated key (6); an impure call in DML (8b); an impure
      call in those shapes (9b).
