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
| external sort | runs to disk past a budget, stable merge; ORDER BY / GROUP BY / DISTINCT; the hash-join build side in a spilling row store; ORDER BY fetches stream from the merge | `serve-real-bigsort` 12 |
| MERGE | per-source-row desugar into the audited DML planners; first branch wins; dup-target raise; `NOT MATCHED BY SOURCE` orphan pass; `RETURNING` cursor | `serve-real-merge` 30 |
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

**op_info_blob / op_seek_blob DONE (2026-08-21, `serve-real-blobinfo`
50):** the client is `qa/c/blobinfo.c` against libfbclient (node has
neither op). `isc_blob_info` answers num_segments / max_segment /
total_length / type on the read and the write handle; `isc_seek_blob`
is stream-only (`isc_bad_segstr_type`), clamped to [0, length] in all
three modes (`BLB_lseek`); `op_get_segment` on a SEGMENTED blob now
packs whole segments into the client's buffer, one frame each, and
answers resp_object 1 for a partial segment (server.cpp `get_segment`)
— the client sees the segments it wrote, not one run. Measured on the
way: the engine's stream-blob header counts the PUTS (5 × 10 bytes:
count 5, max 10 — this crate wrote 1 / 50), `isc_bpb_type` is tag 3
(fc read tag 1, so every stream bpb was taken as segmented), and
libfbclient describes an SQL_BLOB parameter as `blr_blob2` (17), which
the parameter parser now binds. **Inline blobs are NOT sent** (FB6
`op_inline_blob`, protocol 19: a blob up to `max_inline_blob_size` rides
with the fetch, framed by max_segment, and the client then answers
info / seek / get_segment from its cache); the gate disables inlining
through the DPB so both servers answer the ops over the wire — a
default client reads the same bytes either way, in differently sized
frames for a stream blob. **`op_inline_blob` DONE (2026-08-21,
`serve-real-blobinfo` 103):** a client that declares
`p_sqldata_inline_blob_size` (protocol 19) gets each row's blobs ahead of
the row — the same 8 id bytes the row carries, the info `isc_blob_info`
would answer, the content framed per segment (a stream blob in
max_segment pieces) — when the framed length fits; the client then serves
info / seek / get_segment from its copy (the gate's inline pass: wire
opens fall away, the answers are the engine's line for line).

**Still absent:** `op_slice` (arrays). Auth: only Srp256 offered; no Legacy_Auth / ChaCha /
zlib. `op_info_transaction` answers only `isc_info_tra_id`. A text blob
is stored in the database charset (UTF8) with no bpb transliteration.

### D. Converted, not wired — MERGE executor DONE (2026-08-20)

**Done:** `Plan::Merge` (`serve-real-merge` 17): a table or derived-table
source, `ON`, `WHEN MATCHED [AND c] THEN UPDATE SET … | DELETE`, `WHEN NOT
MATCHED [AND c] THEN INSERT`, several branches per kind — the first whose
condition holds in declaration order, or nothing (MergeNode::genBlr's
if-else chain) — and `isc_merge_dup_update` (21000) when two source rows
reach one target, the statement undone. Desugared per source row at
execute into the audited UPDATE/DELETE/INSERT planners; the pairs are
read first against the statement's starting state, as the engine's one
join cursor does. **Tails DONE (2026-08-21, `serve-real-merge` 30):**
`WHEN NOT MATCHED BY SOURCE [AND c] THEN UPDATE | DELETE` — the join
turns FULL; every target row no pair reached gets its own pass, read from
the same starting state, identified by its primary key or (PK-less) by
every column, identical rows as one identity (they take the same branch,
as the engine's do); a source reference inside such a clause refuses at
prepare (the engine: 42S22 Column unknown, probed — NOT a NULL). `RETURNING`
wraps the plan like any DML's (a multi-row cursor: the after-image per
moved row, the old row for a DELETE branch, the BY SOURCE pass included);
the target is named by its ALIAS when it has one (`T.V` is unknown,
`tg.V` answers — probed), `NEW.` is that same image, a bare name both
sides carry refuses (the engine's 42702 ambiguous). The qualifier strip
[`unqualify_dml`] skips MERGE: two tables through aliases make its 2-part
references the norm. **Still absent:** `RETURNING OLD.x` / the source's
columns in RETURNING / an expression there (refused at prepare), `PLAN` /
`ORDER BY`, `OVERRIDING`, parameters inside a MERGE, the failed
statement's partial `Records affected` (the engine reports the rows it
moved before the raise; fc reports 0), a trigger-bearing target
(refused by the per-row planners at execute, not at prepare).
Scrollable cursors: `dsql` emits `blr_scrollable`, and `op_fetch_scroll`
is answered (2026-08-21, see the slice list).

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

### G. Absent subsystems — the external sort, slice 1 DONE (2026-08-20)

**Done (`serve-real-bigsort` 12):** `crates/wire/src/extsort.rs`, the
engine's `sort.cpp` shape - rows buffered to `FC_SORT_MEMORY` (64 MiB,
`TempCacheLimit`'s default), the buffer sorted STABLY by the same
comparator as before and written as a run under `FC_TEMP_DIR` (unlinked
on creation), the runs merged with ties broken by run then position -
so the order is the comparator's, ties in record order, identical
spilled or not. Wired into the `Sort` row source, `group_rows` and
`distinct_rows` (which was quadratic). Not copied, on purpose: the
engine's quicksort over diddled keys and its seek-ordered merge tree -
measured, its tie order past one 128 KB run is an artefact no gate pins.
**Slices 2–3 DONE (2026-08-20):** the hash-join build side lives in a
`RowStore` (the engine's RecordBuffer over a TempSpace: rows to the
budget in RAM, then an unlinked file, fetched by offset; the hash table
keeps offsets only) — a 300k-row build side spills to 18 MB and answers
byte-identically; an `ORDER BY` fetch streams through `SortedCursor`
(the scan drained into the external sort at open, each fetch pulled
from the merge — the result is never a `Vec`); the `Sort` row source
pulls its merge and honours `Flow::Stop`, so `FIRST n` after a sort
stops the delivery (the runs are still written whole, as the engine's
are). **Slices 4–6 DONE (2026-08-21):** an ORDER BY over a JOIN fetch
streams (`serve-real-joinorder` 12: the join cursor hands back its
COMBINED rows unprojected, the external sort takes them at open, each
fetch pulls from the merge and projects — spills at a 64 KB budget in
the gate); the RIGHT/FULL last part is HASHED by the ON's equi-key by
row index (`build_join_probe` now yields the key for RIGHT/FULL, never an
index; `index_hash` / `mirror_candidates` serve the cursor's mirror
phase, the streaming `for_each` arm and `join_step` alike — 4000×4000
RIGHT/FULL equi-join 2.2 s → 0.37 s, same rows; the side itself is still
a RAM `Vec`, its mirror bitmap needs it whole); `backfill_index` builds
the tree WHOLE from the sorted keys (`btw::build_index_bulk`, the
engine's `fast_load`: leaves in sequence, each level above, the top page
into the existing root — a 300k-row CREATE INDEX 41 s → 0.6 s, `gfix -v
-full` clean, the engine navigates and inserts into the result). **Bug
found on the way, fixed:** the insert path compared the interior page's
DEGENERATE first node (empty key) under the DESCENDING rule, where an
empty key is the GREATEST — once the root had split, every key of a
descending index descended the leftmost child and a propagated split key
landed before the degenerate node: a 300k-row descending index had 52
validation errors and a lookup missed rows. The degenerate node is
−∞ by position now, both directions. **Still open:** no merge join;
the RIGHT/FULL side in RAM.


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

- **Dead-code cleanup DONE (2026-08-21):** `Database::image_undo` /
  `ddl_undo` were never set once DDL became the transaction's, so
  `restore_db`, the image branch of `undo_window` / `rollback_now`
  (`TxEnd::RolledBackImage`), `snapshot_db`, the per-transaction and
  per-savepoint image snapshots, `UndoWindow::base`, and the autonomous
  block's page carve-out (`auto_pages` — an O(file) page compare on every
  autonomous commit, read by nobody) are gone. Every undo is by
  transaction state; the write side is released between requests
  unconditionally. The gates that pinned the image path pin the state
  path now (`serve-real-autonomous` counts commits, not carve-outs).
- **Merge join — a non-gap, recorded (2026-08-21):** the engine plans
  one only when a to-be-hashed river exceeds `HashJoin::maxCapacity()`
  AND the join is INNER (Optimizer.cpp `useMergeJoin = hashOverflow &&
  INNER`; "MERGE JOIN does not support other join types yet"); fc's
  hash build side spills to a `RowStore` past its budget instead, so the
  overflow case is answered without a second join algorithm.
- **RIGHT/FULL side in a `RowStore` DONE (2026-08-21):** the join
  cursor streams the preserved side into a `RowStore` (RAM to the sort
  budget, an unlinked file past it), hashed by row index on the way;
  the mirror's bitmap and candidates address rows by index through
  their offsets (`serve-real-joinorder` 15 pins a spill at a 64 KB
  budget). The materialising paths (`join_step`, the `for_each` arm)
  still hold the side as a `Vec` — they materialise everything anyway.
- **`op_fetch_scroll` DONE (2026-08-21, `serve-real-scroll` 49):** a
  statement executed with `CURSOR_TYPE_SCROLLABLE` buffers its result at
  the first fetch (the engine's BufferedStream) and answers NEXT / PRIOR
  / FIRST / LAST / ABSOLUTE / RELATIVE with Cursor.cpp's rules (BOS / EOS
  parking, absolute from either end, relative 0 re-reads); NEXT/PRIOR
  deliver the client's batch, the positioned ops one row; a scroll op on
  a plain cursor answers `isc_invalid_fetch_option` naming the option.
  The client is `qa/c/scroll.cpp` over the OO API (its own prefetch and
  relative re-positioning included). `blr_scrollable` in `dsql` was
  already there.
- **The batch API DONE (2026-08-21, `serve-real-batch` 22):**
  `op_batch_create` / `msg` / `exec` / `rls` / `cancel` / `sync` — a
  prepared DML statement's input messages queued (each in op_execute's
  packed message form) and run in one round trip through the ordinary
  DML path (one statement undo per message); the completion state
  (`op_batch_cs`) carries a count per message under `TAG_RECORD_COUNTS`,
  `EXECUTE_FAILED` and the failure's vector up to `TAG_DETAILED_ERRORS`
  (64), and the run stops at the first failure unless `TAG_MULTIERROR`.
  Laws probed: the parameters block is WIDE-tagged (u32 lengths); a
  second `createBatch` supersedes the open one. Client `qa/c/batch.cpp`
  (OO API). Blobs inside a batch and `op_info_batch` followed the same
  day (below).
- **Blob parameters in UPDATE … SET DONE (2026-08-21,
  `serve-real-blobupdate` 64, client `qa/c/blobupdate.c`):** a blr_quad
  parameter at an UPDATE's SET (and UPDATE OR INSERT's update half) goes
  through `store_blob_param`, blb::move's three cases probed live: a
  TEMPORARY id is materialised into the relation (the first matched row;
  every further row gets a COPY — no two records share a blob), the
  ALL-ZERO quad stores an EMPTY blob (not NULL — INSERT too, probed), a
  PERMANENT id is COPIED with the target column's sub_type/charset unless
  it is the row's own id echoed back (kept, blb.cpp:1059). A stale temp
  id (its transaction ended) is `invalid BLOB ID`. Also in:
  `OCTET_LENGTH` over a BLOB column (BIGINT, from the stored header),
  `UPDATE OR INSERT` with parameters (the update half's slot map), a
  per-statement reset of materialised temp ids on failure. Before this,
  an UPDATE with a blob parameter was silently wrong (the raw temp id
  landed in the record). Boundaries: MERGE's UPDATE branch with a blob
  source value; `SET blob = <expression>`; `OCTET_LENGTH` of the blob
  inside the writing statement's RETURNING; a blob id bound to a
  non-BLOB column refuses (the engine converts).
- **Blobs inside a batch DONE (2026-08-21, `serve-real-batchblob` 52,
  client `qa/c/batchblob.cpp`):** `op_batch_blob_stream` decoded as a
  per-statement state machine mirroring protocol.cpp `xdr_blob_stream`
  (the 16-byte header as xdr_quad + two big-endian u32s, a header that
  would straddle packets held back and counted in the next packet's
  length, bpb and data raw, a segment length as a 4-byte xdr_u_short,
  alignment padding never on the wire) into closed temp blobs;
  `op_batch_set_bpb` (the default is STREAM — `initBlobParameters`);
  `op_batch_regblob` (a batch id over an existing blob, which the store
  then copies); `op_info_batch` (blob alignment 4, header 16, buffer
  size — the client asks before its first blob packet). At execute each
  message's blob field is re-spelled as the message comes up; an unknown
  id ends the execute with `isc_dsql_error` / `-104` /
  `isc_batch_blob_id`, the messages before it stored and kept (probed).
  Policies BLOB_ID_ENGINE / BLOB_ID_USER / BLOB_STREAM, appendBlobData,
  per-blob bpb, a 5000-byte blob, all line for line with the engine.
- **`op_ping` / `op_transact` DONE (2026-08-21, `serve-real-transact`
  8, client `qa/c/transact.cpp`):** ping is a bare op answered clean;
  transactRequest compiles the BLR through the SHOW-request parser, runs
  it with message 0 pre-filled from the input (the engine memcpy's it in
  BEFORE the start — a `blr_receive` would stall the request), and
  answers the first message 1 the program sent. Wire quirk recorded: the
  BLR travels TWICE in op_transact (`xdr_trrq_blr` and then the MAP macro
  over the same field). A BLR the parser refuses is `isc_invalid_blr`
  (offset 0 — the parser keeps no offset).
- **NEXT**: `op_slice` (arrays — a programme: ARRAY columns in DDL,
  RDB$FIELD_DIMENSIONS, the array blob (InternalArrayDesc + data), the
  SDL subset `gen_sdl` emits, op_get_slice / op_put_slice); the auth
  tail (Legacy_Auth / ChaCha / zlib). (MERGE `RETURNING` / `NOT MATCHED BY SOURCE`, `op_info_blob`
  / `op_seek_blob`, the ordered JOIN fetch streaming, the RIGHT/FULL
  hash, the bulk index build, the cleanup — all done 2026-08-21.)
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
