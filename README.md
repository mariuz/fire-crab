# fire-crab 🔥🦀

An incremental conversion of the [Firebird](https://github.com/FirebirdSQL/firebird)
database engine from C++ to Rust — started bottom-up from the storage layer,
tested differentially against the real engine from the first commit.

## What this is (and is not)

Firebird's engine is on the order of a million lines of C++ with thirty years
of accumulated correctness. **fire-crab is not a rewrite announcement** — it is
a methodical conversion experiment with three rules:

1. **Every converted piece must be verifiable against the C++ engine today** —
   not "when the project is finished". The first slice decodes real database
   files written by Firebird 6 and is diffed field-for-field against `gstat`
   on every database we can generate.
2. **The C++ source is the specification.** Every Rust struct, constant and
   algorithm carries a pointer to the file and line it was converted from, and
   the C++ `static_assert`s that pin on-disk layouts are mirrored as Rust
   tests.
3. **Documented as it happens.** The conversion steps, the decisions, and the
   dead ends live in [docs/methodology.md](docs/methodology.md); the map from
   engine subsystems to conversion status lives in
   [docs/subsystem-map.md](docs/subsystem-map.md).

The project grew out of
[a conceptual-architecture paper on Firebird](https://github.com/mariuz/conceptual-architecture-for-firebird-paper)
whose 43 subsystem documents (each with verified hands-on samples in five
languages) serve as the conversion's guidebook: each subsystem document tells
the converter what the C++ is *doing* before they read a line of it.

## Status

| Area | Crate | Status |
|---|---|---|
| ODS page structures (header, generic page, TIP) | `fire-crab-ods` | **converted + differential-tested** |
| Record RLE compression (`sqz.cpp`, incl. FB4 extended runs) | `fire-crab-ods` | **converted + round-trip-tested** |
| Page-type census / `gstat`-style tool | `fcstat` | **working** |
| PIP, pointer pages, data pages + record-version walk | `fire-crab-ods` | **converted + differential-tested vs live SELECT** |
| Record field decoding (RDB$FORMATS bootstrap, blob assembly) | `fire-crab-ods::format` | **converted + full-row differential vs live SELECT** |
| B-tree index pages + node encoding (`btn.h`) | `fire-crab-ods::btr` | **converted + index-order differential vs live ORDER BY** |
| Transaction system: TIP chain, delta versions, MVCC visibility (`tra.cpp`/`vio.cpp`) | `fire-crab-ods::tra` | **converted + committed-only-visibility differential vs live SELECT** |
| Garbage-collection / sweep analysis (`vio.cpp`) | `fire-crab-ods::gc` | **converted + prediction differential vs live `gfix -sweep`** |
| BLR intermediate language (`par.cpp`, `blp.h`) | `fire-crab-ods::blr` | **converted + verb-token differential vs the engine's own BLR printer** |
| Wire protocol - client: login + general SELECT (`src/remote/`, `src/auth/`) | `fire-crab-wire` | **fire-crab runs multi-column, multi-row SELECTs** matching isql row-for-row (integer + text). Validates the wire codec against the real C++ server |
| Wire protocol - server: accept + SRP-256 + attach + statement pipeline | `fire-crab-wire::server` | **a real third-party client (node-firebird) authenticates, arms Arc4 wire encryption, attaches and runs a query end-to-end against fire-crab**; the C++ `isql` authenticates and attaches too (see below) |
| Real query execution: `SELECT COUNT(*) FROM <table>` from pages | `fire-crab-wire::server` + `fire-crab-ods::catalog` | **the server answers a real query from the database file** - resolves the table name through `RDB$RELATIONS` and counts committed records from the data pages; over the wire, node-firebird's count matches isql exactly on user and system tables |
| Real column projections: `SELECT <cols>` / `SELECT *` from pages | `fire-crab-wire::server` + `fire-crab-ods::catalog` | **the server returns real typed rows** - columns resolved through `RDB$RELATION_FIELDS` (by field id, which reorders vs column position on mixed-width tables), records decoded with the format they name, integers sent as BIGINT and the rest as VARCHAR; node-firebird's result set matches isql value-for-value on user tables, including NULLs and `SELECT *` |
| WHERE-clause filtering: `SELECT ... WHERE <pred>` from pages | `fire-crab-wire::server` | **the server filters rows** - comparisons (`= <> < <= > >=`) on integer and text columns, combined with `AND`/`OR`, plus `IS [NOT] NULL`; evaluated per decoded record, honouring three-valued logic; `SELECT`, `SELECT *` and `COUNT(*)` all take a WHERE, matching isql |
| ORDER BY and aggregates | `fire-crab-wire::server` | **the server sorts and aggregates** - `ORDER BY` on columns or ordinals, ASC/DESC, multi-key, NULLs ordered as the engine does (first ascending); `MIN`/`MAX`/`SUM` over integer columns and `COUNT(col)`/`COUNT(*)`, all composable with WHERE; matches isql value-for-value including NULL results |
| GROUP BY | `fire-crab-wire::server` | **the server groups** - `SELECT <keys and aggregates> ... GROUP BY <cols\|ordinals>`, and multi-aggregate projections with no GROUP BY (one global group, one row even over an empty set); NULL keys bucket together, aggregates computed per group, composable with WHERE and ORDER BY (which sorts the *output*, by name or ordinal); matches isql value-for-value |
| HAVING | `fire-crab-wire::server` | **the server filters groups** - the predicate (comparisons, `AND`/`OR`, `IS [NOT] NULL`) is evaluated on each group's computed output row and may name aggregates *not in the select list* (computed as hidden items) or any grouping column; a global aggregate's single row can be kept or rejected; matches isql, including zero-row results |
| INNER JOIN | `fire-crab-wire::server` | **the server joins two relations** - `FROM t1 [a] [INNER] JOIN t2 [b] ON <col> = <col> [AND ...]` with table-qualified or unambiguous bare columns; NULL and partnerless keys drop out, text keys compare pad-insensitively (CHAR vs VARCHAR), WHERE/ORDER BY see the combined row, `SELECT *` is left columns then right, and a lone `COUNT(*)` counts the joined rows; matches isql value-for-value |
| OUTER JOIN | `fire-crab-wire::server` | **the server answers LEFT/RIGHT/FULL [OUTER] equi-joins** - partnerless preserved-side rows emitted once with the other side NULL-padded (NULL join keys never match, so they surface as padded rows), and WHERE runs on the *padded* row - SQL's join-then-filter order, making `WHERE <right col> IS NULL` the classic anti-join; COUNT(*) over any kind; matches isql value-for-value, the anti-join asserted non-empty so the outer path is provably exercised |
| Native wire types | `fire-crab-wire::server` | **columns travel in the engine's own wire form** - SMALLINT/INTEGER/BIGINT at their own SQL types, NUMERIC/DECIMAL as raw scaled integers with the scale in the describe (the client divides), FLOAT/DOUBLE as IEEE bytes, DATE/TIME/TIMESTAMP as raw day/1e-4-s units, BOOLEAN as an XDR slot; ORDER BY/GROUP BY on them compare numerically; node-firebird's typed decode (numbers, `Date`s, booleans) matches isql |
| INSERT (first DML) | `fire-crab-wire::server` + `fire-crab-ods::dml` | **the server writes real records into the pages** - transaction allocated from the header and committed in the TIP, image laid `rhd_not_packed` into a data-page slot; **the real engine is the oracle**: isql reads the rows back, `gfix -v -full` finds nothing wrong, `gbak` backs the file up; unsupported INSERTs answer SQL errors, never silent no-ops |
| UPDATE / DELETE (version chains) | `fire-crab-wire::server` + `fire-crab-ods::dml` | **the server writes MVCC version chains** - UPDATE copies the old version to a fresh slot flagged `rhd_chain` and rewrites the primary with a back pointer to it; DELETE leaves a header-only `rhd_deleted` stub over the chain (`VIO_modify`/`VIO_erase` + `DPM_update` on the file image); **three engine oracles**: `gfix -v -full` accepts the chains, the same statements applied by the C++ engine to a second copy produce an *identical* table, and `gfix -sweep` - the engine's own GC - collects fire-crab's chains with the version arithmetic exact (46 → 23) and the data intact |
| System-table projections | `fire-crab-ods::sysfmt` + `fire-crab-wire::server` | **system relations answer like user tables** - their formats (absent from RDB$FORMATS) are *computed* the way ini.epp computes them at database creation, but from the database's own catalog: RDB$RELATION_FIELDS names the fields, RDB$FIELDS types them, the ini.epp offset walk (FLAG_BYTES + MET_align) lays them out. Anchored: the computation must reproduce every offset catalog.rs found by differential testing (4/256/1394/1410, 32/42) - asserted in tests and at every runtime bootstrap. Projections, WHERE, ORDER BY, aggregates, GROUP BY and system-to-system JOINs over RDB$ tables match isql; DML on system relations stays refused |
| BLOB content over the wire | `fire-crab-wire::server` + `fire-crab-ods::format` | **blob columns are first-class** - described SQL_BLOB with sub_type, the 8-byte on-disk bid travels as the quad, and the server answers `op_open_blob(2)`/`op_get_segment`/`op_close_blob` by assembling content from the pages (level 0/1, segment framing stripped per-blob via `rhd_stream_blob`); the first CONTENT differential: node-firebird's assembled text == isql on a 30000-byte multi-page blob (length/head/tail), empty and NULL blobs, and a system blob through the computed system format |
| INT128 + DECFLOAT | `fire-crab-ods::decfloat` + `fire-crab-wire::server` | **decoded, rendered like decNumber, native on the wire** - decimal64/128 DPD decode converted from the engine's embedded decNumber (DPD2BIN table from decDPD.h), rendering per decNumberToString (cohort preserved: 100.00 keeps its zeros; the 0.000001-vs-1E-7 plain/scientific boundary exact); INT128 as a scaled i128. Wire forms exactly as xdr.cpp serializes them. Render differential: `fcstat rows` == isql text on 38-digit INT128 and 34-digit DECFLOAT; wire differential through node-firebird's typed decode; ORDER BY sorts numerically. Three node-firebird client bugs catalogued along the way (negative INT128, huge scale-0 INT128, multi-digit DECFLOAT coefficients - all broken against any server) |
| TIME ZONE types | `fire-crab-ods::tz` + `fire-crab-wire::server` | **decoded and served** - UTC + zone id per ISC_TIME_TZ/ISC_TIMESTAMP_TZ; the 637-entry zone-name table generated from TimeZones.h, offset zones converted to local exactly as TimeZoneUtil (displacement = id - 1439 - ONE_DAY is 24*60-1, an off-by-one the render differential caught first run); named zones render with the right region name but visibly unconverted (their rules need ICU's tzdata - honest placeholder over silently wrong local time); wire forms per xdr.cpp, ORDER BY by UTC instant |
| Write-path page allocation | `fire-crab-ods::dml` | **INSERT grows the table** - pages allocated from the PIP (first free bit, pip_used/pip_min maintained, the FILE extended past EOF), formatted and hooked into the pointer page with fill-bits; back versions grow the relation the same way. 250 inserts grow a table 1 → 8 data pages by gstat's own accounting, `gfix -v -full` accepts the bookkeeping, the engine produces the identical table from the same statements. DML on INDEXED tables refused with a real SQL error until index maintenance is converted - the last big write-path piece |
| Index maintenance (B-tree insertion) | `fire-crab-ods::btw` | **the engine reads through the trees fire-crab writes** - keys byte-exact per btr.cpp compress() (doubles for INTEGER, INT64_KEY for BIGINT, pad-stripped text), btn.h's prefix-compressed node encoding, page splits per split_and_insert incl. root splits; DELETE touches no index and UPDATE adds changed keys, exactly the engine's semantics. 2000 inserts drive leaf+root splits; isql point lookups/range scans/ORDER BY navigate OUR trees (PLAN asserted), `gfix -v -full` cross-checks every record against every entry, duplicate PKs refused. Expression/conditional indexes still refuse DML |
| Multi-segment + descending indexes | `fire-crab-ods::btw` | **compound and DESCENDING keys maintained** - compound keys assembled exactly as BTR_key: per-segment compression interleaved into 5-byte groups (marker byte = segments remaining, STUFF_COUNT data bytes, zero-padded at segment ends); descending keys complement the WHOLE assembled key after assembly (BTR_complement_key), descending NULL = pre-complement 0x00, the 0x01 end-value guard ported. Unique rule corrected BY the differential: only an ALL-NULL key is exempt (btr.cpp:5629) - the live engine refused a partial-NULL duplicate this conversion first assumed exempt. 1500 rows through a compound PK split leaves; the engine point-looks-up, partial-key-scans and navigates DESC through the trees (PLAN asserted), gfix cross-checks every entry |
| Parameter binding | `fire-crab-wire::server` | **prepared statements take real `?` parameters** - the describe's BIND section announces each parameter's target type (what real clients build their encoders from), op_execute's message is decoded from the client's own value-derived BLR (null bitmap + XDR values), and the values bind into INSERT images, UPDATE SET bytes and WHERE comparisons with engine-CVT coercions: integers rescale exactly into NUMERIC, doubles round half-away, a blr_timestamp truncates into DATE/TIME, blr_bool into BOOLEAN. A NULL parameter in a comparison is UNKNOWN; a type-mismatched one raises an SQL error at execute - never a wrong row set. node-firebird drives all of it; the engine applies the literal equivalents and prints the identical table |
| Predicate expression surface | `fire-crab-wire::server` | **LIKE/BETWEEN/IN/NOT/parentheses** - the WHERE grammar is a recursive parser (OR over AND over NOT/parens/leaves) normalized to DNF with NOT pushed into the leaves by De Morgan (sound in three-valued logic); BETWEEN desugars to >= AND <=, IN to OR-of-equalities, their NOT forms fall out - including `x NOT IN (1, NULL)` = UNKNOWN. LIKE matches the STORED value per character with ESCAPE support (CHAR padding counts - differentially confirmed before implementing), parameterised patterns/bounds/lists work through the `?` machinery (a leaf duplicated by the DNF cross-product keeps its one slot). 46 checks, every one the identical SQL through fire-crab and isql on the same file |
| DDL: CREATE TABLE | `fire-crab-ods::ddl` + `fire-crab-wire::server` | **the ENGINE adopts a table fire-crab created from raw bytes** - catalog rows (RDB$FIELDS/RELATION_FIELDS/RELATIONS/FORMATS/PAGES) with every system index maintained, the packed-descriptor format blob and the RDB$RUNTIME field-summary blob (both probe-pinned byte layouts), pointer + index-root pages allocated and registered. The engine then reads the table, INSERTs into it, runs its own CREATE TABLE beside it (id/domain sequences survive), gbak RESTORES it (a restore replays our catalog as real DDL), and DROPs it through our rows - gfix -v -full clean at every step. Three engine laws found by gdb-bisecting a hung attach against the DEBUG engine build: RDB$PAGES rows must be system-transaction (tx 0) records, a primary record clears dpg_secondary + the pointer fill bits, OIT/OAT/OST mirror a clean detach. Constraints/other DDL verbs refuse with real SQL errors |
| DDL breadth: PK/NOT NULL, CREATE INDEX, DROP TABLE | `fire-crab-ods::ddl` | **the ENGINE enforces the constraints fire-crab wrote** - its own duplicate INSERT dies with "violation of PRIMARY or UNIQUE KEY constraint INTEG_n" naming the constraint row fire-crab stored, its point lookups PLAN through the RDB$PRIMARYn and user indexes fire-crab built (CREATE INDEX backfills existing rows; a unique backfill over duplicate data fails like the engine's own index build), NOT NULL enforced both sides (the RSR_field_not_null runtime segment + server-side validation at store). DROP TABLE stubs eight catalog relations' rows, wipes the tx-0 RDB$PAGES rows and releases every owned page - the engine sees the table gone, sweeps the stub chains, gbak restores the file and the restored copy still enforces the PK. Engine law caught live: only pointer/root/TIP/generator rows are legal in RDB$PAGES - a B-tree bucket row CORRUPTs the attach |
| Python firebird-driver compatibility | `fire-crab-wire::server` | **the reference python driver firebird-qa's tests run their SQL through drives fire-crab end-to-end** - a third client kind (after node-firebird's pure JS and C++ isql), the OO API over the real fbclient library. Getting it working exposed protocol details node-firebird was lax about: op_prepare must answer the client's REQUESTED info-item list in order (the fixed-shape buffer made the OO API raise "Unrecognized C++ exception"); op_execute's response object must ECHO the transaction handle (the client nulls its ITransaction on a 0, so commit crashed); string params arrive as blr_text2. SELECT/param-DML/CREATE TABLE+PK/DROP all work, gfix-clean. The full firebird-qa PLUGIN additionally needs the Services API (op_service_attach/info - its bootstrap reads server version/dirs) and op_create - the named next milestones. Also fixed a DROP-with-index page-orphan bug (btr_relation is @28, not @26) |
| Services API + op_create | `fire-crab-wire::server` | **the firebird-qa plugin's session-bootstrap wire operations, driven by the real python driver** - `connect_server` (op_service_attach + op_service_info) answers the server version, home/lock directories, security database and architecture (byte format captured from the real server), which is exactly what the plugin's `pytest_configure` reads; `create_database` (op_create) materialises an empty database with the engine, then serves and mutates it, so the driver runs CREATE TABLE / INSERT / PK-enforced through fire-crab against a fresh file the engine then validates. This does NOT yet run the full suite: past bootstrap the plugin attaches to the `employee` sample database and probes `MON$ATTACHMENTS` and the ODS version to detect the server architecture - monitoring-table and sample-database emulation still ahead |
| Everything else | — | see [docs/subsystem-map.md](docs/subsystem-map.md) |

**On the firebird-qa milestone, precisely.** firebird-qa drives a *server*,
so the suite only becomes applicable once fire-crab can *accept* connections,
not just make them. Both halves now exist:

- **Client** (`fire-crab-wire`): connects to the running C++ engine; every
  query is checked against isql. This validated the wire codec (XDR, SRP-256,
  the message/BLR formats) end-to-end against the real server first.
- **Server** (`fire-crab-wire::server`): accepts TCP connections and speaks
  the same protocol the C++ `src/remote/` server does. **node-firebird - an
  independent, third-party client library with no fire-crab code in it -
  negotiates protocol 20, authenticates via the server half of SRP-256
  (no password on the wire), arms Arc4 wire encryption with the derived
  session key, attaches, and drives the full statement pipeline
  (transaction → allocate → prepare → execute → fetch), decoding the
  returned value correctly.** The C++ `isql` client authenticates via
  SRP-256 and attaches as well, then drives its richer post-attach ops
  (op_cancel, op_info_database) until it reaches op_exec_immediate.

The server now answers **real queries** from the database file the client
attaches to, dispatching into the converted `ods` engine rather than returning
a constant:

- `SELECT COUNT(*) FROM <table>` resolves the table through `RDB$RELATIONS`
  (read straight from its data pages by `fire-crab-ods::catalog`) and counts
  the committed records - matching isql on every user and system table tested.
- `SELECT <cols> FROM <table>` and `SELECT *` return **real typed rows**:
  columns resolved through `RDB$RELATION_FIELDS`, each record decoded with the
  format it names, integers sent as BIGINT and the rest rendered as VARCHAR.
  Over the encrypted wire, node-firebird's result set matches isql
  value-for-value on user tables - including NULLs, mixed-width tables (where
  a column's field id is *not* its position), and `SELECT *`.
- A **WHERE clause** filters those rows: comparisons (`= <> < <= > >=`) on
  integer and text columns, combined with `AND`/`OR` (and binding tighter, so
  the predicate is OR-of-ANDs) plus `IS [NOT] NULL`, evaluated per decoded
  record with SQL three-valued logic (a comparison against NULL is UNKNOWN,
  the row excluded). `SELECT`, `SELECT *` and `COUNT(*)` all take a WHERE, and
  a predicate the parser does not fully support makes the query fall back to
  the fixed value rather than answer it without the filter.
- **ORDER BY** sorts the result: by column name or 1-based ordinal, `ASC`/
  `DESC`, multiple keys, with NULLs ordered as the engine does (first when
  ascending, last when descending). Matching rows are collected and sorted
  before they are sent.
- **Aggregates** `MIN`/`MAX`/`SUM` over an integer column and
  `COUNT(col)`/`COUNT(*)` return a single value (NULL when the set is empty),
  composable with WHERE - matching isql, including that `SUM`/`MIN`/`MAX`
  ignore NULLs and `COUNT(col)` counts only non-NULLs.
- **GROUP BY** buckets the filtered rows by the key columns (named or by
  select-list ordinal) and computes each aggregate per bucket; NULL keys form
  one group, as SQL requires. Every bare select-list column must be a group
  key (anything else falls back rather than answering wrong). A projection of
  several aggregates with *no* GROUP BY is one global group - exactly one
  output row, even over an empty set (`COUNT` 0, the rest NULL). ORDER BY on
  a grouped query sorts the output rows, by output column name or ordinal
  (so `ORDER BY 2 DESC` on a `COUNT(*)` column works).
- **HAVING** filters the groups after aggregation, where WHERE filtered the
  rows before it: the predicate is evaluated on each group's computed output
  row, and may reference aggregates that are *not* in the select list
  (`SELECT DEPT_ID ... HAVING SUM(SALARY) > 190000` computes the sum as a
  hidden item) or any grouping column (`HAVING DEPT_ID IS NULL` selects the
  NULL-key bucket). With no GROUP BY it keeps or rejects the single global
  row - so a HAVING can legitimately answer zero rows. An aggregate in a
  WHERE clause, or a non-grouped column in a HAVING, is invalid SQL and
  falls back.
- **INNER JOIN** matches two relations' decoded records on one or more
  AND-ed `ON` column equalities: each joined row is the left record's values
  followed by the right's, so projections, WHERE and ORDER BY all address
  the combined row - through table-qualified names (`E.ID`, or `EMP.ID`
  when no alias hides the table) or bare names when exactly one side has
  the column. NULL keys never join (`=` with NULL is UNKNOWN), keys with no
  partner drop out, text keys compare with trailing blanks insignificant
  (a `CHAR(10)` key joins the same `VARCHAR` text), and duplicate keys
  yield their full cross product. `SELECT *` is all left columns then all
  right; a lone `SELECT COUNT(*)` counts the joined rows. Cross
  joins, chained joins, comma-list FROMs and grouping over a join fall
  back.
- **Outer joins.** `LEFT`, `RIGHT` and `FULL [OUTER] JOIN`: the
  preserved side's partnerless rows are emitted once with the other
  side all NULLs (FULL preserves both, appending the right rows nothing
  matched). The WHERE filter runs on the padded row - SQL evaluates the
  join first, the filter after - so `WHERE <right col> IS NULL` on a
  LEFT join selects exactly the rows that found no partner, the classic
  anti-join, and rows whose join key is NULL (which never matches
  anything) come back NULL-padded instead of vanishing.
- **Native wire types.** Every column type the record decoder handles
  exactly is described and encoded as the engine would: integers at their
  own width (`SQL_SHORT`/`SQL_LONG`/`SQL_INT64`), `NUMERIC`/`DECIMAL` as
  the raw stored integer plus the scale in the describe - the client
  divides, which is the engine's contract - `FLOAT`/`DOUBLE` as IEEE
  bytes, `DATE`/`TIME`/`TIMESTAMP` as raw Modified-Julian-day and
  1/10000-second units, `BOOLEAN` as an XDR int slot. Sorting and
  grouping on these compare numerically (9.50 before 12.30; dates
  chronologically). node-firebird decodes them through its normal typed
  path - JS numbers, `Date` objects, booleans - and matches isql.
- **INSERT writes the pages.** `INSERT INTO <t> [(cols)] VALUES (...)`
  (single row, literal values) allocates a transaction from
  `hdr_next_transaction`, marks it committed in the transaction
  inventory, builds the record image (null flags + fields at their
  descriptor offsets, length pinned to a live record's `fmt_length`) and
  lays it `rhd_not_packed` into a data-page slot - dpm.epp's directory
  arithmetic in reverse. The oracle is the engine itself: isql SELECTs
  the rows fire-crab wrote, `gfix -v -full` validates the whole file
  (a check with teeth - one corrupted slot makes it throw), `gbak`
  backs it up. It is an *offline-style* writer (whole-file flush, no
  careful-write ordering, no page allocation or index maintenance yet),
  and an INSERT the server cannot honour raises a real SQL error over
  the wire - for DML, a silent fallback would mean a client believing
  its write succeeded.
- **UPDATE/DELETE write version chains.** `UPDATE <t> SET col = lit
  [, ...] [WHERE ...]` and `DELETE FROM <t> [WHERE ...]` (the WHERE is
  the same grammar SELECT filters with) do what `VIO_modify`/`VIO_erase`
  do on the page image: the current version is *copied* to a fresh slot
  and flagged `rhd_chain`, then the primary slot is rewritten under a
  freshly committed transaction - the new image for an update, a
  header-only `rhd_deleted` stub for a delete - with
  `rhd_b_page`/`rhd_b_line` pointing at the copy. Back versions are full
  images (legal - the engine writes full back versions itself when a
  delta would not shrink), repeated updates extend the chain, and each
  statement executes against a working copy of the file so a failure
  leaves no half-written chains. The oracle is the engine three ways:
  `gfix -v -full` accepts the chains; the same statements applied by the
  C++ engine to a second copy of the same clean database produce an
  identical final table; and `gfix -sweep` - the engine's own garbage
  collector - consumes the chains fire-crab wrote, the version count
  dropping exactly as arithmetic predicts (30 rows, 9 statements → 46
  versions, sweep → 23) with the data unchanged.

The subtlety that had to be right: on a table mixing column widths the engine
lays fields out physically by alignment, so `RDB$FIELD_ID` (the record-format
index) diverges from `RDB$FIELD_POSITION` (the declared order); projecting by
position instead of field id silently returns the wrong column, which a
uniform-width table never reveals.

Projections, WHERE, joins, GROUP BY, HAVING, ORDER BY and aggregates
cover user tables AND system relations - the latter's formats (absent
from `RDB$FORMATS`; the engine builds them at creation from compiled-in
tables, ini.epp:1053-1088) are computed by the same offset walk from the
database's own catalog rows, so the file describes itself; only the two
catalog-reading relations are compiled into `sysfmt`, and the computation
must reproduce the offsets `catalog.rs` established empirically before it
is trusted. Integers, scaled numerics, float/double, date/time/timestamp,
boolean, text, `INT128`, `DECFLOAT` and the TIME ZONE types all travel
in native wire form, and blob columns are served as real blobs - the id
in the row, the content through the blob ops; named-zone local times
render visibly unconverted (their rules need tzdata), and other shapes
fall back to the fixed value.
Widening further (index maintenance - the last big write-path piece -
and scaled/temporal SET values) is the
work that continues - but the fixed answer is no longer fixed, the server
writes records and version chains the real engine validates and
garbage-collects, and the protocol server it all runs on is proven
against a genuine client.

Current QA state: `fcstat header` output is **byte-identical on the compared
fields with `gstat -h` across 123 real Firebird 6 databases** (every scratch
database generated by the paper's hands-on samples), and the record walk now decodes **full rows from raw pages** — RDB$FORMATS
bootstrap (the system format hardcoded, exactly like the engine's own
bootstrap), blob-id resolution through the record-number formulas, segmented
blob assembly, descriptor-driven field decode — **matching live
`SELECT` output value-for-value** on every compared column of every table
tested, from 0 to 200,000 rows. See
[docs/qa-and-benchmarks.md](docs/qa-and-benchmarks.md) for the numbers and the
honest caveats attached to them.

## Quick start

```sh
cargo test                                   # layout + round-trip tests
cargo build --release
./target/release/fcstat header  /path/to/db.fdb
./target/release/fcstat census  /path/to/db.fdb
./target/release/fcstat tip     /path/to/db.fdb

# differential QA against the C++ engine's gstat:
GSTAT=/opt/firebird/bin/gstat qa/diff-gstat.sh /path/to/*.fdb

# C++-vs-Rust timing on the same file:
GSTAT=/opt/firebird/bin/gstat bench/compare.sh /path/to/db.fdb
```

## Layout

- `crates/ods` — the conversion itself, one module per converted C++ unit,
  each headed by a comment naming its source (`ods.h`, `sqz.cpp`, `tra.h`).
- `crates/fcstat` — the inspector tool that makes the conversion observable.
- `qa/` — differential testing against the C++ engine (and the plan for
  adopting the [firebird-qa](https://github.com/FirebirdSQL/firebird-qa)
  suite once a wire-protocol milestone makes it applicable).
- `bench/` — C++-vs-Rust measurements with their caveats attached.
- `docs/` — methodology, subsystem map, QA strategy.

## License

The conversion follows the code it converts: Initial Developer's Public
License (IDPL), compatible with Firebird's IPL/IDPL licensing.
