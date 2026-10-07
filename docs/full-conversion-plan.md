# fire-crab: Full Conversion Plan

*2026-10-05 · baseline `master` at `ea24856`, updated for slice 15 (2026-10-07) · shared copy:
[claude.ai doc](https://claude.ai/code/artifact/b21b5433-02ee-42ef-9918-c9d8177a2d5e)*

Every Firebird subsystem has a first Rust version checked against the real
engine. What is left is depth inside each subsystem, a few subsystems that
don't exist yet, and the client side. The first priority is moving SQL
execution out of the `wire` server.

## Phase 0: stop depending on the C++ engine

1. **Create databases natively.** *Done 2026-10-05 (`bd324f3`,
   `qa/serve-real-nativecreate.sh`):* `op_create` no longer runs the C++
   `isql`. It writes the engine's own empty database (`crates/ods/templates`,
   one per page size) with a fresh GUID and creation time, the engine's
   page-size rounding and the DEFAULT CHARACTER SET. **Next:** write the
   catalog itself (`INI_format`) instead of copying the engine's empty file.
2. **Choose one reference engine build and re-measure.** Several test gates
   fail on the engine's side, and the roadmap's backlog is marked stale
   ("re-measure before planning"). Rebuild the backlog from a fresh hunt.

## Phase 1: architecture (the largest risk)

Moving SQL execution out of `wire` comes first: until it moves, every later
feature has to be built twice.

3. **Move SQL execution out of `wire`.** `server.rs` is 163k lines, 67% of
   all the Rust. It calls `dsql` 44 times, `exe` 12 and `opt` 4; SQL runs
   through an interpreter inside `wire`, not parse → BLR → executor. Target
   path:
    - `dsql`: full statement compilation to BLR
    - `opt`: plans every statement
    - `exe`: runs the record sources (`jrd/recsrc`)
    - `wire`: back to protocol only

    Move one statement family at a time (SELECT, DML, PSQL, DDL), each
    checked against the engine before and after.

    *In progress (`qa/serve-real-exeselect.sh`), off unless `FC_EXEC_SELECT`
    is set:*
    - Slice 1 (`953ec53`): a parameterless SELECT with exact-numeric or
      temporal outputs is compiled by `dsql` as `FOR <select> INTO .. DO
      SUSPEND` and served from `exe`'s record sources. Any decline falls back
      to the interpreter, and `FC_EXEC_SELECT_TRACE` names where.
    - Slice 2 (`a771c23`): text outputs in their own set; declined under a
      collated or codepage relation.
    - Slice 3 (`fee1e98`): bound parameters, each `?` an input of the
      procedure, declined where moving the value into its slot would change it.
    - Slice 4 (`529313c`): system relations (the built-in formats); a virtual
      or global temporary relation declines.
    - Slice 5 (`768bc86`): DOUBLE / FLOAT, compared as the engine does (a
      double SUM / AVG declines: its value depends on the summation order).
    - Slice 6 (`69d712e`): text output in the attachment's set under UTF8.
      Slice 7 (`983cd3c`): BOOLEAN. Slice 8 (`ee344b8`): INT128 /
      NUMERIC(19..38). Each type's BLR descriptor is byte-identical to the
      engine's.
    - Slice 9 (`c975df7`): **the transaction's own view** - `exe` reads its
      own uncommitted rows and a concurrency transaction's snapshot, where it
      read the committed image and declined both.
    - Slice 10 (`644ef69`): arithmetic over DOUBLE / FLOAT, IEEE as the
      engine's C++ doubles are; an integer operand joins exactly under 2^53.
      A scaled operand, a division by zero and a non-finite result still fail
      the run. It also reaches the stored routines `exe` runs by default.
    - Slice 11 (`204f43a`): DECFLOAT, read-only - outputs, comparison by
      value beside a DECFLOAT or an exact value (1.0 = 1.00 = 1), MIN / MAX.
      A NaN, arithmetic, SUM, CAST, DISTINCT / GROUP BY (the cohort laws) and
      MIN / MAX over equal values of different cohorts fail the run.
    - Speed (`3828117`): an equality across an INNER join step is a hash
      join; a 600 x 600 self join went from over a minute to 1.1 s.
    - Found on the way and fixed: `exe` did not order temporal values,
      `dsql` refused an ORDER BY ordinal, and `exe`'s SUM / AVG skipped a
      non-exact operand.
    - **Switch-on sweeps:** the first (2026-10-05) served about 2,200
      statements; every class of wrong answer it found now declines or fails
      the run (`37fc50f`, `f91d03a`). One root cause: the BLR decoder listed
      only `blr_relation`, so aliased streams - joined views, joined codepage
      or collated relations - escaped the guards. After slice 6 (2026-10-06)
      **no served-wrong cell is left**; after slice 9 the route serves about
      4,180 statements. The remaining failures are the known engine-side reds
      and 11 index / join-order cells that count the interpreter's own index
      trace, which the route bypasses.
    - **Decision needed before the route goes on by default:** pin those trace
      gates to the interpreter (`FC_EXEC_SELECT` unset), or give `exe` an
      equivalent trace.
    - Slice 15 (2026-10-07): **the compile census.** A sweep with the trace
      exported counted 5,430 `compile` declines - the largest class - and a
      probe harness measured 190 of those shapes against the engine's own
      `RDB$PROCEDURE_BLR`. `dsql` now compiles, byte for byte: every system
      function (`blr_sys_function`, with the DATEADD / DATEDIFF /
      FIRST_DAY / POSITION / OVERLAY / CRYPT_HASH spellings rewritten to
      the engine's argument order); CONTAINING, SIMILAR TO [ESCAPE] and
      LIKE .. ESCAPE; exponent literals (a `blr_double` literal carrying the
      source text) and hex literals; aggregate FILTER (sugar for the
      aggregate over `CASE WHEN c THEN arg END`); HAVING without GROUP BY,
      GROUP BY without an aggregate item, FIRST / SKIP and ROWS n over an
      aggregate, ORDER BY an aggregate; one-item IN lists (an equality) and
      IN lists typed among their items. **A typed catalog** (`set_catalog_typed`,
      each column's type from the relation's current format) lets CASE /
      IIF / NULLIF / FILTER over a column carry the engine's unified cast:
      the widest exact dtype with the smallest scale, where a decimal
      literal is an INT64 inside DSQL - which also fixed a pre-existing
      wrong BLR (`CASE WHEN c THEN 1.5 ELSE 2.5 END` compiled as LONG).
      `qa/dsql-proc-blr.sh` pins 365 byte-identical cells (78 new); five old
      refusal pins promoted after measuring. Still refused: NULLS FIRST /
      LAST, LIST, derived tables (the engine dissolves a one-table derived
      table into an aliased relation), COLLATE expressions, text beside a
      number in a CASE.
    - Slice 16 (2026-10-07): **NULLS FIRST / LAST** on every sort key (the
      placement byte before the direction byte, in a statement's, an
      aggregate's and a window's ORDER BY alike), an unselected GROUP BY
      field as a sort key (a fresh map slot), and **derived tables**: the
      inner select nests as one `blr_rse` standing as the stream - FIRST,
      SKIP, WHERE, ORDER BY and a DISTINCT's projection inside it, the base
      relation aliased `"D" "PUBLIC"."T"` (or `"D" "A"` over an inner
      alias, a plain relation when the derived table has no alias), an
      expression item wrapped in `blr_derived_expr` at every outer
      reference; aggregates, FIRST / SKIP and joins over a derived table,
      and CTEs, follow. The executor declines the two placement bytes
      rather than guessing. 34 new byte-checked cells across the two BLR
      gates; three stale pins promoted. Still refused: an aggregate, a UNION
      or a join inside a derived table, LIST, COLLATE expressions.
    - Next: the remaining compile classes - COLLATE expressions (which the
      executor could not serve anyway), windows beside GROUP BY, derived
      tables and CTEs, UNION in a derived table, NULLS FIRST / LAST, LIST;
      then the other decline classes - the
      attachment's set under non-UTF8 attachments, lossy bound moves, a text
      literal against a non-text column; DECFLOAT arithmetic and grouping,
      zoned and BLOB outputs;
      NaN, CAST and scaled operands over doubles; views; index use in `exe`.
4. **Concurrency and sharing.** Writers are serialized per database, and only
   the transaction-lock series is used.
    - the typed lock series from `jrd/lck.cpp`, so writers conflict per row
      rather than per database
    - wait-for deadlock detection (the `-w` cycles)
    - file locking in `PIO_open`
    - multi-process sharing of the lock table (Classic/SuperClassic modes)
5. **Page cache.** Page eviction and per-page fetch through buffer
   descriptors under memory pressure.
6. **Garbage collection.** Background and cooperative GC; today only
   `gfix -sweep` collects garbage.

## Phase 2: deeper work in the existing subsystems

Wrong answers rank above refusals; a refusal is safe, a wrong answer is not.

7. **SQL surface.**
    - Remaining wrong answers: FLOAT, ROUND, DECFLOAT exponent literals, bind
      errors.
    - Rounds 6–8, re-measured 2026-10-05: multi-column `UNION`, CTE shapes
      (recursive too), text-to-DOUBLE and store conversions agree. Still
      refused: a mixed multi-clause `ALTER TABLE` (ADD with ALTER COLUMN or
      DROP; the engine writes one new format), and `WHERE CURRENT OF` in an
      EXECUTE BLOCK.
    - `RDB$DB_KEY` is refused whole (8 bytes: relation id and record number,
      little-endian). It is the foundation `WHERE CURRENT OF` needs; `dsql`
      already compiles `FOR UPDATE [OF ..] [WITH LOCK]` byte for byte.
    - A BLR blob cast to `VARCHAR .. CHARACTER SET OCTETS` reports *filter not
      found*; a non-ASCII literal in a procedure body made under a NONE
      attachment is not interpreted.
    - Wrong answer, mostly closed: an index key built from a text literal that
      cannot convert raises 22018 on the engine before any row. Joins
      (`92ea9c4`) and subqueries (`cb8ea7f`) now raise too. Left: under a LEFT
      join the engine streams a row before the raise, where this server raises
      first.
    - `RDB$CONFIG` answers no rows.
    - Wrong answer fixed (`a88ecfd`, `qa/serve-real-ctxwords.sh`): a bare
      CURRENT_USER / USER / CURRENT_ROLE in a view, CHECK or routine this
      server compiled was stored as a column reference.
    - Done 2026-10-05/06: an expression over a selectable procedure's outputs
      (`768bc86`); the virtual `RDB$TIME_ZONES` / `RDB$KEYWORDS` and subqueries
      over computed relations, MON$ included (`529313c`).
    - DECFLOAT still open: GROUP BY a DECFLOAT expression, and GROUP BY's NaN
      and cohort laws; a negated exact literal's sign under the engine's
      preferred-desc fold.
    - Done 2026-10-05: `SET DECFLOAT TRAPS`, the untrapped specials and the
      signed zero; QUANTIZE, NORMALIZE_DECFLOAT, COMPARE_DECFLOAT, TOTALORDER
      (`e07317d`); DECFLOAT in PSQL outputs, locals and engine-made routines
      (`7fdb054`); `SET DECFLOAT ROUND`, all eight modes, and CREATE
      PROCEDURE / FUNCTION with a DECFLOAT parameter (`a771c23`).
    - Scalar functions: `OVERLAY`, `BIT_LENGTH`, `ASCII_CHAR`,
      `CAST AS BOOLEAN`.
    - GROUP BY or windows together with FIRST/SKIP; impure calls in DML;
      `NEXT VALUE FOR` in PSQL.
    - `RDB$DEBUG_INFO`, so errors carry line and column.
8. **Optimizer.** `cheaperThan`; merge join; RIGHT/FULL joins inside a chain
   without holding a side in RAM; scanning descending compound indexes; plans
   for HAVING; an answer to `SET PLAN`.
9. **DDL still refused.** USER management (also `SEC$` and gsec), SHADOW,
   `ALTER DATABASE` beyond BEGIN/END BACKUP, SCHEMA, PUBLICATION, EXTERNAL
   CONNECTIONS POOL, system privileges on roles, LOCAL TEMPORARY TABLE.
10. **Character sets and blobs.**
    - Codepage holes: every table is now a bijection on 256 bytes
      (`44c1c3f`), but the engine transliterates a hole to U+0000 for a UTF8
      delivery and refuses U+0081 into WIN1252. Fixing it means telling a
      transliterating delivery from a byte one.
    - UTF8's default collation pads with blanks (`'a<TAB>' < 'a'`) where this
      server trims.
    - `isc_bpb` charset transliteration, blob filters, arrays.
    - A COLLATE after an explicit CHARACTER SET on a routine parameter
      refuses; an explicit-set EXECUTE BLOCK output under a NONE attachment
      refuses (the engine raises *Malformed string*).
    - Done 2026-10-05 (`a771c23`, `qa/serve-real-utf8routines.sh`): a
      routine's text parameter takes the database's default set, a literal in
      a routine's BLR the attachment's set, and an explicit `CHARACTER SET`
      on a parameter or CAST (52 sets, 119 aliases) - every routine's BLR is
      the engine's byte for byte.
    - Done 2026-10-05: `UCS_BASIC`, and a COLLATE with no CHARACTER SET in
      DDL (`4a005dd`, `qa/serve-real-ucsbasic.sh`).
11. **Services.** REPAIR, VALIDATE, PROPERTIES, the user actions,
    `GET_FB_LOG`; per-action SPB grammar; gstat's data, index and
    record-version analysis.
12. **Monitoring.** Full MON$ coverage, including `MON$IO_STATS` and system
    attachments.
13. **Authentication.** Identity mapping, multi-step login (`op_cont_auth`),
    `Legacy_UserManager`, and possibly Legacy_Auth.

## Phase 3: subsystems that don't exist yet

Roughly in order of how much existing applications need them.

| # | Subsystem | C++ source | Notes |
| --- | --- | --- | --- |
| 14 | System packages | `RDB$BLOB_UTIL`, `RDB$TIME_ZONE_UTIL`, `RDB$PROFILER` | Redo the removed packages; the profiler is a no-op |
| 15 | Batch / bulk insert API | `jrd/` (batch) | Used by modern drivers |
| 16 | External data sources (`EXECUTE STATEMENT ON EXTERNAL`) | `jrd/extds` (~7.5k lines) | Refused today |
| 17 | UDR and external engines, plugin loading | `plugins/`, `yvalve` plugin manager | Declarations survive gbak; nothing runs |
| 18 | Trace and audit | `jrd/trace`, `utilities/ntrace` (~12k lines) | |
| 19 | Database encryption | CryptoManager, crypt plugins | Encrypted databases can't be read |
| 20 | Replication | `jrd/replication` (~6.4k lines) | |
| 21 | Platform layer | `winnt.cpp`, XNET, raw devices, O_DIRECT | Windows build |
| 22 | External tables | `jrd/` | |

## Phase 4: client side and tools

23. **Client library.** A Rust equivalent of fbclient (`yvalve`, ~26k lines,
    plus `remote/client`, ~11k): the ISC and OO APIs, a C ABI, and a provider
    dispatcher (remote and embedded).
24. **Command-line tools.** Standalone Rust isql (24.5k lines), gbak, gfix,
    gsec and nbackup. Today these exist only as server-side services;
    `fcstat` is the only tool.
25. **Probably out of scope.** gpre (64k lines) and qli are legacy; decide
    explicitly whether to drop them.

## Suggested order

**0 → 3 → 4 → 7–9**, with the pieces of 10–13 that real applications hit,
then **14–16 → 23–24 → 17–22**.

- Within each phase: wrong answers before refusals, then whatever can be
  checked against the engine with the least new machinery.
- Fix the stale docs along the way: the auth and services docs still list
  ChaCha and gbak/gfix as unconverted, while the roadmap marks them done.

Sources: `docs/subsystem-map.md`, `docs/roadmap.md`, `TODO.md`, and a line
count of the Firebird `src/` tree against `crates/`.
