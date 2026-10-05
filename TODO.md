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
      alone; sweeps now run at `-j 3`. Possibly worth an upstream report once it has a narrower trigger.
      Again 2026-10-04 ~06:45 during a `-j 3` sweep (accept queue 117/128; `sudo systemctl restart firebird`).
- [x] **The reference engine moved to 6.0.0.2196 (56d656b) on 2026-10-03** (previous install kept as
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
- [x] A LIST in HAVING's condition (`= 'text'`, LIKE, STARTING, IS NULL, IN, BETWEEN) answers (listexpr 2b).
- [x] A BLOB against a number or a temporal compares AS TEXT, the other side rendered (`B = 3` is not '3.0',
      `B > 9` is text order, `LIST(ID) = 3` no 22018) - it compared numerically (`qa/serve-real-blobcmp.sh`).
- [ ] A BOOLEAN against a blob: the engine's 22018 names the string "BLOB", this server's the content (blobcmp 9).
- [ ] A `?` compared with a blob refuses at prepare (unmeasured).
- [x] `ALTER TABLE T ADD A .., ADD B .. [, ADD CONSTRAINT ..]` - the columns under ONE format, then the
      constraints in clause order (the engine's order); the duplicate-column vector (`qa/serve-real-altermulti.sh`).
- [ ] A multi-clause ALTER with a DROP or ALTER clause, a CHECK over a column the same statement adds, or a
      COMPUTED column beside others, refuses (altermulti 4).
- [x] A sibling transaction's snapshot (isql's main one beside its DDL transaction) read NO ROW for an altered
      table: the commit purged the old RDB$RELATIONS version. The purge now keeps exactly the versions a live
      sibling snapshot reads and collects the rest, blobs included (`gc::purge_row_chain_keeping`, altermulti 5).
- [x] The transaction isql opens after a DSQL COMMIT / ROLLBACK ran READ COMMITTED here: the answer echoed the
      ended transaction's handle where the engine answers object 0, so isql never re-opened with `SET
      TRANSACTION` (a SNAPSHOT) and a SELECT after COMMIT saw another attachment's later commit
      (`qa/serve-real-txrestart.sh`; the COMMENT-under-a-snapshot cell of altermulti was the same cause).
- [x] A key added over duplicate rows (ADD CONSTRAINT, single or multi-clause, and CREATE UNIQUE INDEX) answers
      the engine's vector, naming the first key in index order (`qa/serve-real-keydup.sh`).
- [x] `.. USING [ASC | DESC] INDEX <name>` on a PRIMARY KEY / UNIQUE / FOREIGN KEY, in CREATE and ALTER TABLE
      (`qa/serve-real-usingindex.sh`); a constraint's index leaves RDB$INDEX_TYPE NULL unless DESCENDING - this
      wrote 0 for every UNIQUE constraint.
- [ ] `SET PLAN ON` prints no PLAN lines here (isql's plan request).
- [x] The backup wrote auto-domains under INVENTED RDB$<n> names in table-then-column order - right only while the
      catalog rows sat in that order; a reused RDB$RELATIONS slot restored them under other names than the engine's
      backup of the same file (empbackup). They keep their real names now.
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

## Found running the paper's samples/nodejs against this server (2026-10-04)

- [x] Triggers as applications write them: the SQL-2003 header (`BEFORE INSERT ON T`), INACTIVE (was ignored -
      the trigger FIRED), RECREATE TRIGGER, and bodies the strict emitter cannot express compiled by the DSQL
      compiler (CURRENT_TIMESTAMP / COALESCE stores, INSERT without a column list, FOR SELECT, SELECT INTO), the
      DSQL compiler told the database's default charset (`qa/serve-real-trigbody.sh`).
- [x] The parser's Token unknown for an unknown first word and for `WHERE ORDER BY` (`qa/serve-real-parseword.sh`).
- [x] A `;` after a nested block's END is refused (the engine's -104) - it was accepted in procedures too.
- [x] PROCEDURES and FUNCTIONS (dsql-compiled) accepted a bare variable inside DML and unknown tables / columns /
      exceptions / sequences / procedures the engine refuses at CREATE; checked now (`qa/serve-real-procnames.sh`).
- [x] A target variable needs no colon (`INTO N`, `FETCH C INTO N`, `RETURNING_VALUES N`) - procnames 3.
- [ ] The PSQL runtime cannot run `G = NEXT VALUE FOR SQ` in a procedure ("uses PSQL this server does not
      interpret").
- [ ] A trigger compiled that way stores an empty RDB$DEBUG_INFO, as a procedure does; and a procedure this server
      created raises without the `At procedure .. line: L, col: C` item (no debug map to place it).
- [ ] `SET DECFLOAT TRAPS TO [..]` / `SET DECFLOAT ROUND <mode>` refuse (session state; measured: untrapped 1/0 is
      Infinity, 0/0 NaN, the context variable reads `None`, CEILING rounds at the 16th digit).
- [x] `BLOB_APPEND(..)` (`qa/serve-real-blobappend.sh`); recorded: it describes Nullable where the engine says
      NOT NULL (and still delivers NULL).
- [ ] Non-ASCII text CAST into a NONE text blob counts double (`OCTET_LENGTH(CAST('abcéé' AS BLOB SUB_TYPE TEXT
      CHARACTER SET NONE))` 11, engine 7); passing it through transcode_text made it 19 - the source set the CAST
      arm is handed is not what it looks like.
- [x] `COUNT(*) FILTER (WHERE ..)` was already answered (`qa/serve-real-aggfilter.sh`); the windows.js refusal was
      `LISTAGG .. WITHIN GROUP` over a text or NUMERIC key under a UTF8 database, and DISTINCT with WITHIN GROUP
      (`qa/serve-real-listagg8.sh`). Recorded there: a WIN1252 key, a UNICODE_CI key, a DISTINCT UNICODE_CI
      argument descending.
- [ ] A `?` as RDB$GET_CONTEXT's variable name. (ENGINE_VERSION / NETWORK_PROTOCOL already answered; the session's
      keys, CURRENT_CONNECTION and the MON$ATTACHMENTS client columns answer since 2026-10-04 -
      `qa/serve-real-session.sh`.)
- [x] samples/nodejs/windows.js runs identically: an op_create now honours the dpb's isc_dpb_set_db_charset (a node
      `attachOrCreate` database was NONE where the engine's was UTF8); the hypothetical-set aggregates
      (`qa/serve-real-hypoagg.sh`, with the engine's NULL-is-the-peer-of-zero law); a frame's EXCLUDE clause and a frame
      on a ranking function (`qa/serve-real-frameexclude.sh`). Recorded there: a hypothetical value count that is not the
      key count raises at EXECUTE on the engine (prepare here), a per-row value's -104 vector, a text value for a
      numeric key, a collated or DECFLOAT key; a misplaced EXCLUDE's -104 and LIST-in-a-framed-window's 0A000.
- [ ] A column declared `COLLATE UCS_BASIC` refuses everywhere (samples/nodejs/intl.js) - `keyable_ttype` takes collation
      0 only, and UCS_BASIC is NOT that order: measured on 2196 it compares with trailing blanks TRIMMED and then by
      code point ('a' = 'a ' < 'a<TAB>'), where UTF8's default pads with blanks ('a<TAB>' < 'a'), and COUNT(DISTINCT)
      folds 'a' and 'a ' (4 of 5) where the default does not (5). Needs its own comparator in every route.
- [ ] samples/nodejs/psql.js: an exception raised in a procedure lacks the engine's `At procedure "PUBLIC"."HIRE" line:
      4, col: 29` context line.
- [ ] serve-real-gbakverbose.sh went red in sweeps 65 and 66 on "the restore streams are byte-equal" and passes
      alone (3/3) and under synthetic load (8/8, on this binary and d92cb5c's). Its DIFF now prints the differing lines
      (it printed 400 bytes of each stream, which hid them) - read them the next time it trips.
- [ ] samples/nodejs/types.js: a DECFLOAT column fetches through node here and does not on the engine (`-804 SQLDA
      missing or incorrect version`) - a describe difference to measure.
- [ ] CURRENT_TRANSACTION / TRANSACTION_ID: a transaction has no id here before its first write (the engine's has one
      from its start) - recorded in `qa/serve-real-session.sh`.
- [x] A HAVING over a literal-only condition (`HAVING 1 = 1`, `COUNT(*) > 0 OR 1 = 0`, `HAVING CURRENT_USER =
      'SYSDBA'`) answers (`qa/serve-real-havingexpr.sh` section 6). Still refused: `HAVING 1 > ?` (the engine
      prepares it).
- [ ] MON$ATTACHMENTS lists only client attachments; the engine also lists its system ones (garbage collector, cache
      writer - NULL address).
- [ ] CREATE / DROP SCHEMA; ALTER DATABASE .. PUBLICATION; CREATE / DROP SHADOW; ALTER EXTERNAL CONNECTIONS POOL.
- [x] A new table's RDB$RELATION_ID was never the divergence: the ids agree (128, then 129 after a RECREATE). The
      sample failed because node-firebird's attachOrCreate sends op_create on the same socket after a refused
      op_attach, and this server hung up (`qa/serve-real-attach.sh` 4b). What still differs there is the
      transaction number in `table 128 is used by transaction N` (ids are reserved lazily here).
- [ ] The MON$ surface the samples read (MON$SERVER_PID, MON$IO_STATS, MON$PARALLEL_WORKERS, MON$WIRE_CRYPT_PLUGIN).
- [ ] Engine quirk, NOT to emulate: a procedure created in the same attachment is selectable there although
      RDB$PROCEDURE_TYPE is 2; a fresh attachment gets "not selectable" (both measured on 2196).
