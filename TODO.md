# TODO

Short, actionable items. The long-form engineering backlog lives in
[`docs/roadmap.md`](docs/roadmap.md).

## HIGH PRIORITY: full conversion (2026-10-05)

The plan, in order, is the top of [`docs/roadmap.md`](docs/roadmap.md) and the
[`docs/full-conversion-plan.md`](docs/full-conversion-plan.md) ([shared doc](https://claude.ai/code/artifact/b21b5433-02ee-42ef-9918-c9d8177a2d5e)).

- [x] **P0** Create databases natively; stop calling the C++ `isql` - op_create writes the engine's own empty database
      (crates/ods/templates, per page size) with a fresh GUID / creation time, the engine's page-size rounding and the
      DEFAULT CHARACTER SET; the client's re-sent CREATE DATABASE text and ALTER DATABASE SET DEFAULT CHARACTER SET apply
      it (`qa/serve-real-nativecreate.sh`, a server with no Firebird on its PATH). Next: write the catalog itself
      (INI_format) instead of the engine's empty file. With it: MON$OWNER / MON$CREATION_DATE answer (they were NULL), and
      a view's text column carries its set in the view's format (a UTF8 database's view described NONE to the engine).
- [ ] **P0** Pick the reference engine build; re-measure the stale backlog
- [ ] **P1** Move SQL execution out of `wire::server` into `dsql` → `opt` → `exe`, one statement family at a time.
      Slice 1 (`qa/serve-real-exeselect.sh`): under FC_EXEC_SELECT a parameterless SELECT whose outputs are exact
      numerics or temporals is compiled as `FOR <select> INTO .. DO SUSPEND` by dsql and served from exe's record
      sources; any decline falls back to the interpreter, FC_EXEC_SELECT_TRACE names where. A sweep with the switch
      ON measures the rest. Found on the way: exe ordered no temporal value (MAX(DATE) answered the earliest) - the
      kinds order now, and a pair of non-NULL values exe cannot order FAILS the run instead of answering; dsql
      refused an ORDER BY ordinal (CREATE PROCEDURE .. ORDER BY 1 was refused) - it compiles byte-for-byte now.
      Slice 2: text outputs in their own set (a plain column's, an expression's real set) - declined under a COLLATED
      relation and a CODEPAGE relation (the executor orders by code point). Slice 3: bound parameters (each `?` an
      input of the procedure, typed as the prepare described it, and every value MOVED into its slot - declined where
      the move would change it, since the engine COMPARES a bound 2.4 against an INTEGER slot unrounded; a temporal
      served only in its slot's own kind, a midnight TIMESTAMP into a DATE slot being its date). Next slices: the attachment's set (ATT_SUBTYPE
      outputs), DOUBLE / BOOLEAN / DECFLOAT in the BLR compiler and the executor.
      THE SWITCH-ON SWEEP (2026-10-05, all 523 gates with FC_EXEC_SELECT=1; the route stays OFF until these close):
      served ~2200 statements, declined ~10000 - compile 4485 (dsql), execute 2370 (exe: an unorderable comparison 939
      - DOUBLE / cross-type; "relation has no format" 539 - system relations; LIKE / STARTING over a non-text 493;
      arithmetic over a non-numeric 256), the attachment's-set text output 653, a parameter type 426. WRONG where it
      served, to close or decline FIRST: (1) exe reads the COMMITTED image, not the attachment's own uncommitted writes
      (viewdml, stalefmt, fnwhere: a SELECT after an UPDATE in one transaction shows the old rows); (2) a VIEW reads as
      EMPTY (view, viewjoin, viewrename); (3) a join predicate's conversion error raises on the engine and answers rows
      here (textnumwhere); (4) cmpparam's 204 cells. And speed: idxcost / leftjoinindex take minutes (no index use).
      CLOSED BY DECLINING (slice 3): (1) any transaction with writes; (2) any identifier of the text naming a view (the
      BLR's relation list names a joined view's BASE only); (3) a text literal compared with a non-text column unless
      a plain decimal against an integer (exe::shape walks the request); (4) a lossy parameter move, a temporal
      parameter of another kind, a negated non-literal (exe's negate cannot know the overflow); and an output value
      not of its column's kind. selparam / view / viewjoin / textnumwhere / cmpparam green under the switch.
      Slice 4: SYSTEM relations (exe read only RDB$FORMATS, which never holds a system relation's format - the
      built-in table now), and a VIRTUAL or GLOBAL TEMPORARY relation declines (no records in the file).
      Slice 5: DOUBLE / FLOAT (dsql's blr_double / blr_float descriptors, byte-identical procedure BLR; exe compares
      them as doubles - a FLOAT beside a FLOAT or an exact value in SINGLE precision, the engine's rule - and SUM / AVG
      fold them as doubles; a NaN, arithmetic and CAST over them still fail the run). Found: exe's SUM / AVG SKIPPED a
      non-exact operand (`HAVING SUM(D) > 1` answered no rows under the switch) and the window SUM would skip a scaled
      one - both now fail the run instead; a double SUM / AVG declines too (its value depends on the summation ORDER and
      it overflows to a raise - aggfold).
      THE SWITCH-ON SWEEP AFTER SLICE 5 (2026-10-05, 4152 s): declines - compile 9852, the attachment's set text
      output 3185, execute 1540, a lossy bound move 1008, own writes 763, BOOLEAN / DECFLOAT / INT128 / zoned outputs
      (32764 274, 32762 660, 32752 567, 32760 181, 32754 156), BLOB 392, DOUBLE arithmetic. WRONG where it served, the
      next closes: CHAR padding and LIKE / STARTING over CHAR conditionals and carriers (inselcond, condpattern,
      carriermix); OCTETS / codepage text (litcs, octets, cscast, xlit, codepages: the 0x00 pad, NONE bytes); ICU and
      key collations under joins and windows (icucoll, collkey FIRST_VALUE ties); a LIMBO record read without raising
      (limbo); an EXECUTE BLOCK's own writes (readconsistency); the window offset raise over an empty table (aggplan);
      a lazy COUNT overflow (ovlazy); a NULL-only outer's key raise (textcolcmp); SUBSTRING's BIGINT range (fnargs);
      index-deferral trace cells (index, idxcost - artifacts).
      CLOSED (2026-10-06, all by declining or failing the run): limbo (a limbo transaction in the TIP), readconsistency /
      snapshot (a snapshot some transaction it cannot see has committed past), textcolcmp (a text field against a
      non-text one), fnargs (SUBSTRING bounds past INTEGER), ovlazy (an out-of-range presentation), aggplan (a constant
      frame offset negative or past INTEGER), collkey (any window), carriermix (a non-literal, non-parameter pattern),
      inselcond / condpattern (a CHAR cast now PADS; a COALESCE over text declines), OCTETS (set 1) relations and
      outputs, a non-ASCII text beside NONE / OCTETS bytes or under a non-UTF8 attachment (litcs, xlit, codepages,
      utf8routines). ROOT CAUSE of two classes: the BLR decoder listed only blr_relation, so every ALIASED stream - a
      joined view, a joined codepage or collated relation - was invisible to the guards (icucoll, codepages); it lists
      blr_relation2 / blr_relation3 too now, which also tightens the stored-procedure collation guard.
      SPEED: exe's INNER join built the whole cross product before filtering (a 600 x 600 self join took over a
      minute - fetchdup's isql timed out under the switch). An equality conjunct across a join step now hashes the
      new side by its key (exact numerics at their shortest scale, text without trailing blanks, the temporal kinds)
      and probes per accumulated binding; the full ON still decides each candidate, and a key of another kind or an
      unhashable one falls back to the nested loop. 1.1 s now.
      Slice 6: a text output in the ATTACHMENT's set under a UTF8 attachment (the sentinel's length is characters).
      THE SWITCH-ON SWEEP AFTER SLICE 6 (2026-10-06, 3970 s): ~3540 statements served and NO served-wrong cell left -
      the 95 failures are the 83 known-red, 11 index / joinorder / idxcost cells that count the INTERPRETER's index
      trace (the route bypasses it), and one condpattern refusal cell the route now answers correctly. Declines: compile
      7588, the attachment's set under other attachments 1000, a lossy bound move 984, a text literal against a
      non-text column 706, execute 629, own writes 545, BOOLEAN / INT128 / DECFLOAT / zoned / BLOB outputs. Turning
      the route ON by default would need those trace gates to pin the interpreter (FC_EXEC_SELECT unset) - a decision
      for the plan, not taken here.
      Slice 7: BOOLEAN (dsql's blr_bool descriptor and TRUE / FALSE literals - `15 17 01` - byte-identical in fc-made
      procedures and functions; exe's BOOLEAN slots and literals; a non-BOOLEAN into a BOOLEAN slot, or the reverse,
      fails the run).
      Slice 8: INT128 / NUMERIC(19..38) (dsql's blr_int128 descriptor with its scale byte - `1A FE` - byte-identical in
      procedure parameters and view CASTs, catalog precision 0 for a bare INT128; the route serves INT128 outputs).
      Slice 9: THE TRANSACTION'S OWN VIEW. exe reads as the attachment - its own uncommitted rows and a concurrency
      transaction's isolation snapshot (ods::tra::visible_rows_as, exe::with_read_view) - where it read the committed
      image and declined both. 4180 statements served under the switch (3543 before). Its sweep found two classes,
      both closed: a SUM / AVG over INT128 (where it overflows is the engine's summation order) fails the run, and an
      OCTET_LENGTH beside NONE / OCTETS columns declines (the engine counts stored bytes - merge).
- [ ] **P1** Typed lock series, `-w` cycles, `PIO_open` locking, multi-process lock table
- [ ] **P1** Page cache eviction; background/cooperative GC
- [ ] **P2** WRONG ANSWER (found 2026-10-05 under the exe switch, in the INTERPRETER): an index KEY built from a
      text literal that cannot convert raises 22018 on the engine before any row. JOINS DONE (`qa/serve-real-joinkeyraise.sh`):
      a join inner's key is built when the inner OPENS, per outer row passing the outer-only conjuncts of the WHERE and
      the ON; a WHERE comparison on the inner keys it (the LEFT runs as an INNER); RIGHT / FULL open the left relation
      per preserved row; a COUNT(*) over the join raises at execute (it was counted at prepare and refused). SUBQUERIES DONE
      too (EXISTS / NOT EXISTS / IN / ANY / a scalar subselect, correlated or not; an uncorrelated EXISTS is an invariant
      and raises over an empty outer). LEFT: the engine STREAMS an outer row the gates turned away before the raise (row
      1, then 22018), here the raise comes first. Unmeasured: `WHERE E.N = 'x' OR T.ID = 1` over a LEFT join raises on row 2 on the engine (fc: row 1).
- [ ] **P2** The FLOAT/ROUND/DECFLOAT wrong answers first; then the rounds 6–8 items still refused (mixed multi-clause ALTER TABLE, `WHERE CURRENT OF` via `RDB$DB_KEY`) - the rest re-measured and agrees
- [x] **P2** WRONG ANSWER: the virtual RDB$TIME_ZONES / RDB$KEYWORDS answered NO ROWS (the zone list lacked America/Coyhaique
      too), and a subquery over any computed relation - MON$ included - walked its empty storage (`qa/serve-real-virtualrel.sh`).
      RDB$CONFIG (this host's firebird.conf, 70 rows) still answers none - recorded.
- [x] **P2** An expression over a selectable procedure's outputs with no clause (`SELECT CHAR_LENGTH(R), K * 2 FROM P`)
      was refused - the bare call's picker took only plain columns (`qa/serve-real-procexpr.sh`). A non-ASCII literal
      in a procedure body made under a NONE attachment is still "PSQL this server does not interpret".
- [x] **P2** WRONG ANSWER: a bare CURRENT_USER / USER / CURRENT_ROLE in a view, CHECK or routine this server compiled
      was stored as a COLUMN reference (`blr_field 'CURRENT_ROLE'`): `"CURRENT_ROLE" = CURRENT_ROLE` answered every row, `S =
      CURRENT_USER` failed at use. dsql emits blr_user_name / blr_current_role now; a delimited name spelling a context
      word refuses (`qa/serve-real-ctxwords.sh`).
- [ ] **P2** DECFLOAT left: GROUP BY a DECFLOAT expression (NaN / cohort laws). (Done: CREATE PROCEDURE / FUNCTION with a DECFLOAT parameter; `SET DECFLOAT ROUND` - all eight modes, dftraps 7)
- [x] **P2** DECFLOAT traps, specials, signed zero, the four DECFLOAT functions (`e07317d`); DECFLOAT in PSQL (`7fdb054`)
- [ ] **P2** Optimizer gaps (merge join, RIGHT/FULL in a chain, HAVING plans, `SET PLAN`)
- [ ] **P2** Refused DDL (USER, SHADOW, ALTER DATABASE, SCHEMA, PUBLICATION, LTT, ...)
- [ ] **P2** Charsets/blobs (codepage holes on a UTF8 delivery, UTF8 default-collation padding, `isc_bpb`, filters, arrays), services actions, MON$ coverage, auth gaps
- [x] **P2** `UCS_BASIC`; a COLLATE with no CHARACTER SET in DDL (`4a005dd`)
- [ ] **P3** System packages, batch API, `ON EXTERNAL`, UDR/plugins, trace, encryption, replication, Windows/XNET, external tables
- [ ] **P4** Rust fbclient (yvalve + remote client); standalone isql/gbak/gfix/gsec/nbackup; decide on gpre/qli

## Upstream reports to file

- [x] **Report to Firebird: semi-join `IN` / `EXISTS` loses a `0` match behind a `NULL`** (found 2026-10-03). **REPORTED 2026-10-03** on the existing issue [#9158](https://github.com/FirebirdSQL/firebird/issues/9158) (same SEMI-join defect, there via UUID hash collisions) rather than as a duplicate: <https://github.com/FirebirdSQL/firebird/issues/9158#issuecomment-5965771034>
  - Draft issue: [`docs/upstream/firebird-hashjoin-semi-null-zero.md`](docs/upstream/firebird-hashjoin-semi-null-zero.md)
  - Easy reproduction (two rows, pure SQL, creates and drops its own database): [`docs/upstream/firebird-hashjoin-semi-null-zero.sql`](docs/upstream/firebird-hashjoin-semi-null-zero.sql)
    `isql -q -user SYSDBA -pas masterkey -i docs/upstream/firebird-hashjoin-semi-null-zero.sql`
- [ ] **Candidate report** (not filed): the engine's compiled-statement cache reuses a PREPARE-TIME fold made under
  another `SET DECFLOAT ROUND` mode - one session, the same text `SELECT CAST(12345678901234567895 AS DECFLOAT(16))
  ..` after `SET DECFLOAT ROUND DOWN` answers 1.234567890123457E+19 (the CEILING fold of its first prepare) where a
  fresh text answers ..456. Reproduce: run the same SELECT under two modes in one isql session.
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
- [x] `SET DECFLOAT TRAPS TO [..]` and the untrapped specials: x/0 +-Infinity, 0/0 NaN, overflow Infinity, an
      untrapped NaN compares equal, a zero quotient/product keeps the XOR sign, the context variable renders the mask
      (`qa/serve-real-dftraps.sh`). `SET DECFLOAT ROUND HALF_UP` is a no-op; recorded: every other mode refuses.
- [x] The signed DECFLOAT zero (IEEE 754): unary minus flips it, `-0 + -0` is -0, `x / -Inf` is -0E-398 / -0E-6176;
      an untrapped CAST overflow is Infinity (`serve-real-dftraps.sh` 5).
- [ ] A NEGATED exact literal converts to DECFLOAT with its minus only under the engine's preferred-desc fold: `CAST(-0.0
      AS DECFLOAT(16))` is -0.0 as a DECFLOAT item (and under COALESCE / `* 1` there), '0.0' cast on to VARCHAR, +0
      under `|| ''` or in a WHERE; inside TOTALORDER `-0.00` keeps it and `-0` does not. Recorded (dftraps 4); +0 here.
- [x] A stood-down DECFLOAT trap at a function (EXP/POWER/LOG, true sign), an aggregate (SUM/AVG/VAR/window) and a
      conversion (0 at an exact target, the float's Infinity/NaN) - `serve-real-dftraps.sh` 6. BOUNDARY: a NaN into a
      scaled BIGINT / INT128 untrapped is engine garbage (78863920565143470.08); refused here.
- [x] QUANTIZE / NORMALIZE_DECFLOAT / COMPARE_DECFLOAT / TOTALORDER (`qa/serve-real-dffuncs.sh`): QUANTIZE HALF_UP
      to y's exponent, Invalid past the precision; the first operand's DECFLOAT(34) or else DECFLOAT(16); COMPARE by
      total order 0/1/2, 3 for a NaN; TOTALORDER IEEE -1/0/1. BOUNDARY: an sNaN / -NaN has no form here (refused).
- [ ] GROUP BY a DECFLOAT-valued expression (ABS(A), NORMALIZE_DECFLOAT(A)) refuses (recorded in dffuncs 6).
      Admitting the key is one line (parse_group_by's type_of guard) and agrees for finite values, but it would carry
      the column path's NaN divergence (below) to a new router.
- [x] A DECFLOAT EXECUTE BLOCK output / local / INTO target (`qa/serve-real-dfpsql.sh`): the output reader takes
      DECFLOAT, an output list is typed PER OUTPUT (a DOUBLE or DECFLOAT beside a VARCHAR refused), a DECFLOAT local
      substitutes as CAST('<canonical>' AS DECFLOAT(n)), a DECFLOAT(16) NaN compares as SQL's (equal), and RDB$FIELD_TYPE
      24/25 map to DEC64/DEC128. Recorded: `R = 2.5e0` (the engine reads the literal's text: 2.5; here 2.500000000000000).
- [x] A stored PROCEDURE / FUNCTION with DECFLOAT parameters or result, made by the ENGINE, runs (source_only_param
      takes DEC64/DEC128; a DECFLOAT user function is a decfloat leaf) - dfpsql 4.
- [x] A routine's unqualified TEXT parameter is of the DATABASE'S DEFAULT SET (`qa/serve-real-utf8routines.sh`): the
      domain row (set, byte length, character length) and the BLR descriptors - a UTF8 database's procedure made here
      was set 0 over character-count bytes, and the ENGINE refused a 'héllo' argument as string right truncation.
- [x] A string literal in a routine's BLR carries the ATTACHMENT's set (0150F04000 under UTF8) - every routine's BLR
      is now the engine's byte for byte (utf8routines). Views / triggers / CHECKs still stamp NONE: unmeasured.
- [x] An explicit `CHARACTER SET` on a routine parameter (or a CAST) - crates/dsql carries the engine's 52 sets and 119
      aliases (read off RDB$CHARACTER_SETS / RDB$TYPES): the domain row, the BLR, a non-ASCII call all the engine's
      (utf8routines). A COLLATE after it still refuses. With it: a VIEW's text expression column carries its set on
      its auto-domain (a CAST to OCTETS read as NONE by the engine), and an EXECUTE BLOCK output of an explicit set is
      described in that set. Under a NONE attachment such an output still refuses: the interpreter decodes NONE-literal
      octets lossily where the engine raises Malformed string (psqlassign 8d, recorded).
- [ ] Rounds 6-8, re-measured 2026-10-05: multi-column UNION, CTE shapes (recursive too), text-to-DOUBLE and store
      conversions agree. Still refused: a MIXED multi-clause ALTER TABLE (`ADD X1 INT, ALTER COLUMN B TYPE ..`, `DROP X3,
      ALTER COLUMN X2 TO X2B` - the engine writes ONE new format; ADD-only lists already take one here), and `UPDATE ..
      WHERE CURRENT OF <cursor>` in an EXECUTE BLOCK (the engine answers it).
- [ ] RDB$DB_KEY: refused whole here (SELECT RDB$DB_KEY, `WHERE RDB$DB_KEY = x'8000000001000000'` in UPDATE /
      DELETE). The engine's key is 8 bytes: the relation id and the record number, little-endian (128 / 1-based numbers
      on a fresh table). It is the foundation positioned DML needs: crates/dsql now compiles `FOR UPDATE [OF ..]
      [WITH LOCK]` byte-for-byte, but the source interpreter has no `WHERE CURRENT OF` (a declared cursor's FETCH, a
      FOR SELECT .. AS CURSOR).
- [ ] `SELECT CHAR_LENGTH(R) FROM <proc>(..)` - a function over a selectable procedure's output column - refuses.
- [x] CREATE PROCEDURE / FUNCTION with a DECFLOAT parameter: crates/dsql's blr_dec64 (24) / blr_dec128 (25) dsc, the
      domain's precision 16 / 34 - catalog and BLR the engine's byte for byte, run by both (dfpsql 5, utf8routines).
- [ ] `CAST(<a BLR blob> AS VARCHAR(n) CHARACTER SET OCTETS)` - sub_type 2 into text - is *filter not found to
      convert type 2 to type 1* here; the engine converts it (HEX_ENCODE over RDB$PROCEDURE_BLR).
- [ ] EXECUTE BLOCK: a duplicate output name is the engine's -637 *duplicate specification*, a bare refusal here; an
      error location after a non-ASCII literal is 2 columns past the engine's (`C = 'é'; R = 1 / 0` col 63 vs 61).
- [ ] GROUP BY a DECFLOAT column holding a NaN (pre-existing): the engine's group break is its COMPARE of the group
      head with the next sorted row - DECFLOAT(16) calls a NaN equal without raising, so Infinity and NaN merge
      (`NaN 2`) and under `GROUP BY -A` the negated NaN sorts first and swallows every row (`0.00 6`); DECFLOAT(34)
      raises 22000 there. Here every value is its own group.
- [ ] GROUP BY / DISTINCT of equal DECFLOATs of different cohorts picks another representative (`1.0, 1, 1.00` groups
      as 1.00 on the engine, 1.0 here; `2.00, 2.0` as 2.00, here 2.0; zeros alike). Not totalOrder - ORDER BY keeps
      insertion order for the same rows - it is the engine sort's tie handling; MIN/MAX likewise row-order-dependent.
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
- [x] UCS_BASIC (trailing blanks trimmed, then code points - this server's plain comparison) and a COLLATE with no
      CHARACTER SET in column / domain / ALTER TABLE ADD DDL (`qa/serve-real-ucsbasic.sh`); samples/nodejs/intl.js runs
      identically.
- [ ] UTF8's DEFAULT collation PADS with blanks on the engine ('a<TAB>' < 'a'), where this server trims - a character
      below the blank orders differently (recorded in ucsbasic section 3).
- [ ] samples/nodejs/psql.js: an exception raised in a procedure lacks the engine's `At procedure "PUBLIC"."HIRE" line:
      4, col: 29` context line.
- [x] A table carrying an EXPRESSION or PARTIAL index (engine-made) was read-only here; its writes now maintain both
      from the catalog sources, and the engine reads this server's file through them identically with gfix clean
      (`qa/serve-real-exprindex.sh`). Still refused: a UNIQUE expression index; an expression over a collated column.
- [x] A text index's key type is the column's set (`qa/serve-real-textitype.sh`): UTF8 4, a tabled single-byte set
      IDX_OFFSET_INTL + ttype, NONE/ASCII 1 - this server stamped 1 for every set, and the ENGINE then misread its
      WIN1252 / ISO8859_1 indexes (wrong rows). An index on a set with no codepage table (DOS437 ..) is refused now.
- [x] OCTETS keys idx_byte_array (3) and UNICODE_FSS 32834, as the engine does; an engine-made index of either kind
      takes this server's writes now (`qa/serve-real-textitype.sh` sections 4-5).
- [x] Every single-byte set the engine carries is tabled now - 34 tables READ OFF THE LIVE ENGINE (decode, UPPER, LOWER),
      `qa/serve-real-codepages.sh`; a column of DOS437 / WIN1253 / KOI8R / TIS620 .. stored UTF-8 bytes before.
- [ ] Engine-side nondeterminism seen once in sweep 72: cmpparam's `ID IN (SELECT b.ID .. b.ID IN (?, 3))` bound '0X2'
      answered 2;3 on the ENGINE (3 every other time, 3 alone and in a direct probe). Watch it.
- [x] ORDER BY, ranges, BETWEEN, IN, MIN / MAX, CASE and expression keys over a single-byte set follow its BYTE order
      (codepages section 2; WIN1252 '€' and the other older tabled sets included). A bound `?` against such a column
      compares in UNICODE order on the engine - kept on the plain path (measured).
- [ ] A codepage HOLE (WIN1252 0x81 ..) transliterates to U+0000 on the engine, which also refuses U+0081 into WIN1252;
      every table here keeps the hole at its C1 point instead, so a byte-carrier (NONE) delivery reproduces the stored
      bytes (cscast measured that law). Fixing it means telling a transliterating delivery from a byte one.
- [x] CREATE INDEX .. COMPUTED BY (..) and CREATE INDEX .. WHERE through this server (`qa/serve-real-exprindexddl.sh`;
      expression and condition BLR byte-identical, the engine reads the file through them, gfix clean). dsql compiles
      EXTRACT now. samples/nodejs/indexes.js runs; only its PLAN text differs (the plan request is unanswered).
- [x] INSERT .. SELECT of non-ASCII UTF8 text under a NONE attachment refused (`qa/serve-real-inselutf8.sh`).
- [ ] serve-real-gbakverbose.sh went red in sweeps 65 and 66 on "the restore streams are byte-equal" and passes
      alone (3/3) and under synthetic load (8/8, on this binary and d92cb5c's). With the wider DIFF it showed the ENGINE's
      own `gbak -b` through its service manager failing - "Invalid clumplet buffer structure: string length doesn't
      match with clumplet (6)", engine rc 1 - an engine-side intermittent, not this server's.
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
