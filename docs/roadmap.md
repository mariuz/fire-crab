# Roadmap

*Live document. The narrative of how every closed item got closed is in
`docs/roadmap-history.md` (frozen 2026-08-20) and in the commit and gate
named beside it.*

fire-crab, 2026-08-20: a Rust conversion of the Firebird 6 engine —
123k lines across 14 crates (`ods` 22.7k, `dsql` 12k, `burp` 5.1k,
`exe`, `opt`, `lck`, `svc`, `auth`, `cch`, `pio`, `blb`, `evt`,
`fcstat`, and the `wire` server at 67k). The server answers real SQL
over the real wire protocol, and every answer is held DIFFERENTIALLY
against the live FB6 engine: 289 gates under `qa/`, of which the 264
`serve-real-*` sweeps are green (8,627 checks at the last full sweep
before the growth chunk; +32 with it).
The rule that produced all of it still holds: *what does the engine do
here?* — measured, then converted, then gated in both directions
(the engine reads what fire-crab writes, fire-crab reads what the
engine writes). Where the answer is not known, the server REFUSES;
it never guesses.

## Done

One line each; the gate is the proof.

| programme | what it means | pinned by |
|---|---|---|
| gbak (21 slices) | fc's backup writer and restore carry everything FB6 produces except an index expression the restore cannot evaluate (refused whole) and multi-file shapes FB6 no longer makes; both directions, with execution | `serve-real-gbak` 58, `gbakrestore` 39, `gbakse` 12, `gbakverbose` 14 |
| nbackup (A–D) | level-0 + level-N chains, restore with the engine's "Wrong order" refusal, `BEGIN/END BACKUP` with the `.delta` overlay — every cell cross-implementation | `serve-real-nbackup` 25 |
| programme R (R1–R8) | the row-source tree replaced textual rewriting: views, CTEs, derived tables, `WITH RECURSIVE`, the fetch PULLS the tree, `FIRST n` stops the scan | `serve-real-derived`, `recursive`, `cte`, `view` |
| W1 optimizer | the converted cost model chooses the executed plan: equality/range/compound-prefix/text-key index bands, ORDER BY navigation, the FK check, DML targets, index-driven joins, every equi-join HASH family, resumable join cursors | `opt-plans` 112, `opt-grid`, `serve-real-index` 346, `joinchain`, `leftjoinindex` |
| W2 page cache | a page-addressed `ods::Image` (`Vec<Arc<[u8]>>`), per-page fetch, Arc-identity flush diff — a write costs O(pages) end to end | `cch-crash-harness`, `serve-real-carefulflush` |
| W3 pio | the file is written in the open mode the header's Forced Writes flag calls for | `pio-layout`, `serve-real-forcedwrites` |
| W4 lck | row-level waits on the owning transaction's lock, deadlock denied by the wait-for scan with `isc_deadlock`, lock timeout | `lck-reserving-matrix`, `serve-real-concurrency` 20 |
| W5 evt | `POST_EVENT` delivered over the auxiliary connection | `evt-semantics`, `serve-real-eventdelivery` |
| W6 exe/svc | PSQL interpreter (procedures, triggers, cursors, handlers, autonomous blocks, `EXECUTE STATEMENT`), gfix's DPB channel, limbo, validation with all sixteen counters | `serve-real-psql`, `cursors`, `limbo`, `validate`, `gfixsweep` |
| W7 metadata cache | columns, check predicates and the optimizer GATE memoised per epoch | `serve-real-statementcache` |
| savepoint is a transaction | a savepoint is a nested transaction id; `ROLLBACK TO` marks it dead | `serve-real-savepointtx` |
| snapshot isolation | `parse_tpb`, a stable `Snapshot { limit, active }` per concurrency transaction | `serve-real-snapshot`, `autonomous`, `consistency` |
| cost model + stale statistics | the stale region measured and matched, the filtered-driver term included | `opt-stale` |
| transliteration + collation | eight codepage tables generated from the live engine, carriers, the assignment matrix, case law, PXW_INTL keys | `serve-real-xlit` 58, `collate` 16, `textcolcmp` 359 |
| generator SET is deferred | `tra_gen_ids` cache + dfw postings per savepoint; no compensating record | `serve-real-gencomp` 22 |
| packaged procedures | a package qualifier resolves down the search path; `RDB$PROFILER` native no-ops with the engine's arity | `serve-real-pkgproc` 20 |
| fragmenting store | records larger than a page chain the engine's way; UPDATE/DELETE of a fragmented head | `serve-real-fragstore` 13 |
| UNIQUE is walk-order | enforcement row-at-a-time in RECNO order, 23000 byte-exact; the sub-9-byte RHDF corruption found and fixed with it | `serve-real-uniqueorder` |
| blob writes + RETAIN | temp blobs over the wire materialised at the store; COMMIT/ROLLBACK RETAIN keep the transaction with its snapshot | `serve-real-blobwrite` 8, `retain` 8 |
| transactional DDL | catalog rows under the user transaction's id, undo by state + journaled residue, deferred drops; first-updater-wins on a relation with the engine's vector; owner-only schema visibility | `serve-real-ddltx` 32 |
| the file grows the engine's way | pointer-page chain, PIP chain, SCN pages at every `pagesPerSCN·N`, TIP chain — each crossed by fc and read by the engine (count, `gfix -v -full`, a write of its own on the new structure, a level-1 nbackup over fc's late pages), and the reverse | `serve-real-growth` 32 |

## Stale claims retired

- "`hdr_next_transaction` is stored one display slot apart (fc: last assigned, engine: next to assign)" — FALSE, read off tra.cpp `bump_transaction_id` on 2026-08-20: both store the highest id assigned. The one-slot difference was fc's OIT sitting AT the first interesting id where the engine's `--oldest` puts it one below — and that was a LIVE bug: the engine's sweep over an fc-written file resurrected 200 rolled-back rows (`serve-real-undo`). Fixed in `update_oldest`; `serve-real-oldesttx` asserts the same triple on both sides now.

An audit of the history file (2026-08-20) found fifteen places where a
paragraph says "still to do" and a later paragraph, higher up, closed
it. Recorded here once so nobody re-opens them:

- W2 "per-page fetch still to do / the image is one contiguous `&[u8]`" — done (Inc500–502, page-addressed `Image`).
- W4 "only LOCK TIMEOUT is read as plain WAIT" — done (`parse_tpb`, `isc_tpb_lock_timeout`).
- W6 "snapshot isolation is not converted; the gate asserts the divergence" — done (`serve-real-autonomous` asserts agreement).
- W6 "the gbak writer refuses sequences, views, triggers, procedures, UNIQUE/FK/CHECK" — all done (the gbak programme).
- W4 "what still needs an image: `ROLLBACK TO` a mark" — done (savepoint is a transaction). DDL remains (item B below).
- W4 "what is left is granularity — writers serialise on the database" — done (steps 2 and 3 beneath it).
- W1 "param'd DML WHERE needs a defer field" — done (`Plan::Update`/`Delete` grew it, `serve-real-pdml`).
- R "a date inner key still scans" — a temporal key hashes.
- W1 "`Infinity`/`NaN` text specials deliberately left to 22018" — converted.
- W1 "DECFLOAT in arithmetic still refused" — arrived.
- savepoint section "a writing window burns a transaction id the engine does not" — measured false on 2026-08-20: 1,000 `SAVEPOINT`s in one transaction leave `Next transaction` where it was. Only a transaction burns an id.
- W6 "CHECK stays int-only" — closed (text/NULL/BIGINT comparisons compile).
- W1 "still to do: index-driven joins, text keys, compound prefixes, parameters" — all done; only "a statement `opt` cannot parse (a `HAVING`) scans" survives (item I).
- W2 "fire-crab has no statement cache: the next item" — in, 36 lines above the claim.
- W1 "`records_for` rebuilds `page_sequence_map` per call" — `ProbedSide` derives it once at open for the cursor path; the probe path is item I.
- R "`NestedLoopJoin` still materialises for RIGHT/FULL" — the cursor streams the mirror; the index PROBE and the HASH still decline for RIGHT/FULL (genuinely open, item I).

## What the engine has that fire-crab does not

Ranked. Each line carries where the gap is visible.

### A. Hard growth walls in fire-crab-written files — DONE (2026-08-20)

Closed as one slice, `qa/serve-real-growth.sh` (32). What was here:
one PIP (`"first PIP exhausted"`, ~510 MB), one pointer page per
relation (`"pointer page full"`, ~13 MB per table), one TIP
(`"transaction id beyond the TIP chain"`, 32,688 ids), and SCN
stamping that knew page 2 only with 2,043 slots where the engine reads
2,041 — so page 2041 of a 16 MB file went out as DATA, and an engine
`nbackup -B 1` over fc's late pages would have missed them (the
engine's increment reads the SCN SLOTS, nbackup.cpp:1462). All four
now follow the engine's own allocator; see "The growth chunk" below.

### B. Transactional DDL — DONE (2026-08-20, slices 1 + 2)

**Done (`qa/serve-real-ddltx.sh` 22):** a DDL statement's catalog rows
are written under the transaction's own id (`Image::ddl_tx` —
`allocate_committed_tx` answers it; the engine's DdlNodes.epp STOREs
under the user transaction), so ROLLBACK, ROLLBACK TO SAVEPOINT and a
failing autonomous block undo DDL by TRANSACTION STATE. The catalog
readers (`catalog_image`, `OwnTx::catalog`) step past a DEAD or LIMBO
version — a rolled-back DROP gives its table back — and the unique-key
liveness test (`btw::recno_is_live`) is MVCC-aware, so a dead row never
blocks a key. What no state takes back is journaled per undo window
and undone by hand (`DdlResidue`: a created relation's whole storage,
a created index's tree + root slot, tx-0 `RDB$PAGES` rows — the eager
form of dpm.epp's MRK_rollback resolution); what COMMIT owns is
deferred to it (`DdlDeferred`: a dropped relation's pages, a dropped
index's `irt_drop` — dfw.epp delete_relation / ods.h:456). The image
fallback, the savepoint's write-side hold and the autonomous refusal
are gone; `op_prepare` on a DDL transaction is allowed unless a DROP
is pending (its page release is COMMIT's, and limbo may outlive this
process's journal).

**Slice 2 DONE (2026-08-20, `serve-real-ddltx` 22 → 32, zero
recorded boundaries):** the write-side hold for a DDL transaction is
gone. In its place, the engine's FIRST-UPDATER-WINS on a relation
(`ddl::relation_head_owner`: the `RDB$RELATIONS` head version's
transaction when ACTIVE — an ALTER's new version, a DROP's stub, a
CREATE's first row): an ALTER or DROP of a relation another active
transaction holds a version of refuses AT ONCE, no wait even under WAIT
(measured 60–100 ms against a 3 s hold), with the engine's own vector —
`isc_no_meta_update` / `<VERB> TABLE @1 failed` / `isc_random`
"newVersion: table N is used by transaction M" (a DROP: "table id=N busy
in another thread - operation failed"). DML, reads and index DDL are
unaffected (CacheVector.h: a different cache element). Per-transaction
SCHEMA VISIBILITY: a thread-local reader view (`tra::ReaderViewGuard`,
set per request from the attachment's own ids and refreshed whenever
they change — an adopted id, an autonomous block opened or closed, an
undo) makes `catalog_image` owner-only, so another transaction's
uncommitted CREATE TABLE is "unknown" to name resolution, while a DDL
statement and the unique-key liveness test read WIDE (a second CREATE
of the name says "already exists", as measured). The shared metadata
cache is bypassed by an attachment with uncommitted DDL and invalidated
when such a transaction commits.

**Still recorded:** `RDB$FORMATS` is written at statement time here, at
COMMIT there (DFW `makeFormat`; measured 0 before / 1 after). A limbo DDL
transaction resolved by `gfix -commit` after a restart leaves its
residue un-released (orphan pages, as the engine's own lazy markers do
until reclaimed). An uncommitted table is "unknown" here with fc's
generic unknown-table refusal where the engine spells −204 (the
pre-existing vector boundary). Inside a PSQL body the reader view is the
enclosing transaction's; an autonomous block sees the outer's
uncommitted tables where the engine's separate transaction would not.
`ddl_undo`/`image_undo` and the `restore_db` path survive as dead code
to delete.

### C. Wire surface — blob writes + RETAIN DONE (2026-08-20)

**Done:** `op_create_blob`/`op_create_blob2`, `op_put_segment`,
`op_batch_segments`, `op_cancel_blob`, a `blr_quad` parameter, and the
store that MATERIALISES a temporary blob into the relation's pages
(blb.cpp `blb::move`; levels 0–2 through `crates/blb`) — a driver's
`INSERT … VALUES (?)` with a Buffer works and the engine reads the
result (`serve-real-blobwrite` 8). `COMMIT RETAIN` / `ROLLBACK RETAIN`
as SQL and as `op_commit_retaining` (50) / `op_rollback_retaining`
(86): the transaction keeps its handle, snapshot (seeing its own
retained commits — `tra_commit_sub_trans`), cursors, statements,
generator cache and temp blobs; savepoints die; a retain without work
burns no id (`serve-real-retain` 8). `isc_invalid_savepoint` spelled.

**Still absent:** `op_info_blob`, `op_seek_blob` (stream only), blob
parameters in UPDATE … SET, `op_batch_*` (the batch API), `op_fetch_scroll`
(dsql already emits `blr_scrollable`), `op_ping`, `op_slice` (arrays),
`op_transact`. Auth: only Srp256 offered; no Legacy_Auth / ChaCha /
zlib. `op_info_transaction` answers only `isc_info_tra_id`. A text blob
is stored in the database charset (UTF8) with no bpb transliteration.

### D. Converted, not wired

- **MERGE**: `crates/dsql/src/lib.rs:8444` compiles it to byte-identical BLR with a test corpus; the server has no executor (`MERGE INTO` has zero hits in `server.rs`).
- **Scrollable cursors**: `blr_scrollable` emitted; `op_fetch_scroll` unimplemented, so no client can scroll.

### E. DDL without planners

Everything below falls to `Plan::Refused` (generic Dynamic SQL Error at
prepare): `CREATE/ALTER/DROP VIEW` (views are read from restored
metadata only), `ALTER/DROP TRIGGER`, `CREATE OR ALTER TRIGGER`,
`ALTER PROCEDURE`, `CREATE OR ALTER PROCEDURE`, `CREATE/ALTER/DROP
FUNCTION`, `CREATE PACKAGE` (restore-only), `CREATE COLLATION`,
`CREATE/ALTER/DROP USER`, `CREATE/ALTER MAPPING`, `CREATE SHADOW`
(restore-only), `RECREATE <anything>` (the verb gate admits it, no
planner), `ALTER DATABASE` beyond `BEGIN/END BACKUP`, `CREATE ROLE …
SET SYSTEM PRIVILEGES`. `CREATE TABLE`'s column types
(`server.rs:11183`) lack BLOB, DECFLOAT, `TIME/TIMESTAMP WITH TIME
ZONE`, NCHAR, arrays, and the `COLLATE` / `CHARACTER SET` clauses.
Gates today build their procedures with the ENGINE, which is why the
interpreter is well covered and the DDL is not.

### F. DML and PSQL gaps

`INTERSECT`/`EXCEPT`; the named `WINDOW` clause; `WITH LOCK`, `FOR
UPDATE`, an explicit `PLAN`; a `?` inside any PSQL query (loop, cursor,
`EXECUTE STATEMENT`, `SELECT INTO` — `server.rs:47089`); `CONTINUE`
and labelled `LEAVE`; `RDB$SET_CONTEXT`/`RDB$GET_CONTEXT`; `GEN_ID`
inside an autonomous body; `INSERT … VALUES` without a column list in
PSQL; `EXECUTE BLOCK` with parameters or `RETURNS`; `EXECUTE
STATEMENT` with parameters, `ON EXTERNAL`, `AS USER`; cross-type
procedure inputs where the engine converts; a bare aggregate over a
comma join (42000 at prepare); `= ANY`/`= ALL` over the strict text
key; PSQL literals held as i32 (`serve-real-psqlerrors`); the BLR
compiler narrower than the interpreter (a bare `EXCEPTION;` in a
`CREATE TRIGGER` body refuses, `server.rs:12764`); a read inside a
PSQL body is read-committed regardless of the transaction's snapshot.

### G. Absent subsystems

- **External sort + TempSpace** (`sort.cpp`): every sort, DISTINCT, GROUP BY and hash build lives in RAM (`server.rs:31046 sort_rows`) — a scalability ceiling, not only a feature.
- **MON$** (`Monitoring.cpp`): answered as `Plan::VirtualEmpty` (`server.rs:27032`).
- **Trace API** (`jrd/trace/`, 15 files), **replication** (`jrd/replication/`, 15 files): nothing beyond a constant and a header field.
- **UDR / external engines / external data sources / external tables** at runtime: declarations ride gbak; nothing executes.
- **CryptoManager**: an encrypted database cannot be read (flag decode only).
- **Batch / BulkInsert**, **arrays** (`RDB$FIELD_DIMENSIONS`, gbak refuses them), **blob filters** and **blob level 2** (`blb/src/lib.rs:330`).
- **User management** (gsec, `SEC$`, `CREATE USER`, `Mapping.cpp`).
- **Background and cooperative GC**: only `gfix -sweep` collects; nothing collects during a scan.
- **Shadow maintenance** in the running server (the restore writes the mirror; `CREATE SHADOW` does not exist).
- **Services**: `REPAIR`, `VALIDATE`, `PROPERTIES`, the four user actions, `TRACE_START`, `GET_FB_LOG` refused by number (`svc/src/lib.rs:141`); gstat's data/index/record-version reports refuse with `isc_wish_list` (`server.rs:2998`).
- **sys-packages**: `RDB$BLOB_UTIL`, `RDB$TIME_ZONE_UTIL` absent; `RDB$PROFILER` members are native no-ops.

### H. Recorded divergences kept on purpose

Each is asserted by its gate so a change shows:

- the engine stores a text value of exactly 4× the declared length, silently truncated (a buffer-sizing defect); fc refuses (`serve-real-charset`);
- the engine's string→double is not correctly rounded; fc is (`serve-real-textnum` compares to 16 digits);
- a codepage hole transliterates to U+0000 on the engine; fc keeps the C1 carrier so every table stays a bijection (`serve-real-xlit`);
- a rolled-back writer pins fc's OIT; a read-only transaction burns no id here (`serve-real-oldesttx`, gstat-only);
- a conditional's text result is VARYING here, padded CHAR of the widest branch there; aggregates in a scalar subquery describe BIGINT (`serve-real-decode`, `qualname`);
- generator draws on a DML that fails on row k: the engine draws k, fc draws all (`serve-real-genwrite`);
- bitmap AND is a residual filter here, two bitmaps there; a WHERE on a LEFT join's inner side flips the engine's driver and cannot flip fc's (rows equal, plan differs);
- `i64::MIN` is keyed under zero's key, matching an engine defect; a WIN1252 `ƒ` UPPER raises 22018 as the engine's does.

### I. Stragglers in W1 / R / W7

Compound DESCENDING indexes scan; `fk_partner_has` with a text key
scans; a temporal/double scalar fold arrives as `Tok::FnExpr` and the
outer scans; the WHERE tokeniser cannot spell `-(9223372036854775808)`;
a statement `opt` cannot parse (`HAVING`) scans; `index_itype` stamps
`idx_string` regardless of charset (metadata divergence, no wrong
answer); RIGHT/FULL decline the inner index probe and the hash; probed
join sides must be plain tables; only an ORDER BY still materialises a
join; the `records_for` probe path rebuilds `page_sequence_map` per
outer row. W7: the triggers a statement gathers and the per-statement
clone of the cached check predicates (~127 µs) sit outside the cache.

## The growth chunk: the file grows the engine's way (done)

Laws pinned from `pag.cpp:430-700` (`PAG_allocate_pages`),
`tra.cpp:566-615` (`TRA_extend_tip`, called from `TRA_start` when
`number % transPerTIP == 0`), `dpm.epp:3146` (`extend_relation`) and
`DPM_pages`, then measured on live files:

1. **Pointer-page chain** (`ods::dml::extend_relation`). A full last
   pointer page chains a new one: `ppg_sequence` + 1, `ppg_eof` MOVED,
   `ppg_next` linked, `dpg_sequence = pp_sequence · dp_per_pp + slot`,
   and an `RDB$PAGES (relation, pag_pointer, sequence, page)` row for
   every relation but `RDB$PAGES` itself — the row `DPM_scan_pages`
   needs, without which the engine never reads the second page. The
   FIRST pointer page never uses its last slot (dpm.epp:3195 —
   `ppg_count < dp_per_pp - 1` for sequence 0).
2. **PIP chain + SCN pages** (`ods::dml::allocate_page`). PIP *n* lives
   at `n·pagesPerPIP − 1`, minted all-free when the previous PIP hands
   out its last bit; every multiple of `pagesPerSCN` (= `pagesPerPIP /
   32` = 2,041 at 8K, ods.cpp:63) is formatted as an SCN page and
   stepped over. `pip_used` is a HIGH-WATER mark (`PAG_last_page` sizes
   the file by it; `PAG_release_page` never lowers it — fc used to
   decrement it), `pip_min` = last bit + 1, `pip_extent` lowered on a
   release that frees a whole extent byte. `stamp_page_scns` stamps
   each page's era on the SCN page that OWNS it, slot `page %
   pagesPerSCN`, and an SCN page's own slot 0 carries its own era.
3. **TIP chain** (`ods::dml::ensure_tip_for`). The first id of a TIP's
   range mints it: zeroed page, prior `tip_next` linked, `RDB$PAGES (0,
   pag_transactions, sequence, page)` — a fresh engine database carries
   `(0, 287, 0, 3)` for TIP 0, so the row is the engine's own.

**Measured on the way.** `pip_used` on an engine file is NOT the
allocation mark either — `ensureDiskSpace` raises it to the size the
engine pre-extended the file to (a 64,000-row fixture read 65,312 with
1,300 bits still free); the gate sizes the PIP cell off the free bits.
The engine allocates data pages in aligned 8-page EXTENTS once a
pointer page holds 8; fc allocates one page at a time — same rows,
different page numbers, both readers indifferent (recorded, not
gated). A `SAVEPOINT` burns no id. And a silent no-op fell out of the
probing: `DECLARE I INTEGER = 0;` dropped its initialiser, so a `WHILE
(I < N)` body ran ZERO times and reported success — fixed
(`declared_var_inits`, initialisers run as the assignments they are;
one this server cannot read refuses the body).

**Residual, recorded:** `tip_chain_pages`, `extend_relation` and
`relation_data_pages` find their pages by scanning every page's type
byte — O(pages) per write, ~6 ms per INSERT on a 65k-page image. The
engine keeps these in `RDB$PAGES`-fed vectors; a per-database cache of
pointer-page and TIP page numbers is the next step when it dominates.

## Next, in order

- **D, the MERGE executor — THE NEXT CHUNK** — the BLR is already
  compiled and tested; only the executor is missing.
- **D, the MERGE executor** — the BLR is already compiled and tested;
  only the executor is missing.
- **G, the external sort** — every sort and hash build is bounded by
  RAM today; after the growth walls this is the next scalability
  ceiling a real database reaches.

## How these slices are gated

A slice that wires an engine mechanism in needs two gates of different
kinds: a **coverage** check that the mechanism was REACHED (the page
exists at the predicted number, the counter is non-zero, the lock was
enqueued) — because "wired in but never used" passes every behaviour
gate — and the existing behaviour gates, unchanged, as the floor. A
gate that cannot fail is not a weaker check; it is a source of false
confidence. And before believing a gate that fails is a regression,
run the OLD binary: a server that improved past a recorded refusal
reads exactly like one that broke.
