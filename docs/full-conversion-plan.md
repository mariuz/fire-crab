# fire-crab: Full Conversion Plan

*2026-10-05 · baseline `master` at `ea24856`, updated for `a771c23` · shared copy:
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
    - Found on the way and fixed: `exe` did not order temporal values, and
      `dsql` refused an ORDER BY ordinal.
    - Next slices: parameters, the attachment's set (`ATT_SUBTYPE` outputs),
      DOUBLE / BOOLEAN / DECFLOAT in the BLR compiler and the executor; then a
      sweep with the switch on, and making it the default.
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
    - A function over a selectable procedure's output column
      (`SELECT CHAR_LENGTH(R) FROM <proc>(..)`) refuses; a BLR blob cast to
      `VARCHAR .. CHARACTER SET OCTETS` reports *filter not found*.
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
