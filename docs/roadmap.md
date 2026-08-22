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
| packaged procedures + functions | a package qualifier resolves down the search path; a packaged FUNCTION runs in a select list and a selectable PROCEDURE in the FROM, bare or `PUBLIC.`/`SCHEMA.`-qualified, beside a same-named plain routine; `RDB$PROFILER` native no-ops with the engine's arity | `serve-real-pkgproc` 20, `serve-real-callpkg` 9 |
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

**Still absent:** nothing on the protocol list; see the array tails. `op_info_transaction` answers only `isc_info_tra_id`. A text blob
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

This section has largely closed. Planners now exist and are
differentially gated for `CREATE/ALTER/DROP VIEW`, `RECREATE <anything>`,
`ALTER/DROP TRIGGER`, `CREATE OR ALTER TRIGGER`, `ALTER PROCEDURE`,
`CREATE OR ALTER PROCEDURE`, `CREATE/ALTER/DROP FUNCTION`,
`CREATE/DROP PACKAGE` + `CREATE PACKAGE BODY`, `CREATE/DROP COLLATION`,
`CREATE/ALTER/DROP MAPPING`, and the full `CREATE TABLE` column-type set
(BLOB, DECFLOAT, `TIME/TIMESTAMP WITH TIME ZONE`, NCHAR, arrays, and the
`COLLATE` / `CHARACTER SET` clauses). DROP-dependency enforcement (views,
procedures, FK/PK back-references) refuses with the engine's exact vector.

Still `Plan::Refused` (generic Dynamic SQL Error at prepare): `CREATE/
ALTER/DROP USER` (the security database's PLG$SRP, a separate database,
not this catalog), `CREATE SHADOW` (a physical shadow file beside its
RDB$FILES row), `ALTER DATABASE` beyond `BEGIN/END BACKUP`, and `CREATE
ROLE … SET SYSTEM PRIVILEGES`. The first two are outside fc's
pure-catalog model by nature. Gates historically built their procedures
with the ENGINE, which is why the interpreter was well covered before the
DDL was.

### F. DML and PSQL gaps

`INTERSECT`/`EXCEPT`; the named `WINDOW` clause; an explicit `PLAN` (WITH LOCK / FOR UPDATE / OPTIMIZE are done); a `?` inside any PSQL query (loop, cursor,
`EXECUTE STATEMENT`, `SELECT INTO` — `server.rs:47089`);  `RDB$SET_CONTEXT`/`RDB$GET_CONTEXT`; `GEN_ID`
inside an autonomous body; `INSERT … VALUES` without a column list in
PSQL; `EXECUTE BLOCK` with parameters or `RETURNS`; `EXECUTE STATEMENT` with `USING` / `ON EXTERNAL` / `AS USER` (the dynamic operand and POSITIONAL + NAMED parameters are done); a bare aggregate over a
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

- **Statistical aggregates VAR_POP / VAR_SAMP / STDDEV_POP / STDDEV_SAMP
  DONE (2026-08-22, `serve-real-statagg` 4):** a DOUBLE fold over the
  non-null values, the naive sum-of-squares the engine uses
  (`Sxx - Sx*Sx/n` over n or n-1, folded in f64) so the DOUBLE bits match
  byte-for-byte over INTEGER, NUMERIC(9,2) and expression sources,
  whole-table and grouped. Unlike SUM/AVG they are NOT nullable and NEVER
  NULL: an empty, single-row or all-NULL group is 0, not NULL (probed
  against FB6 - the describe carries no Nullable flag, like COUNT;
  VAR_SAMP over one row and any fold over none are 0, not a divide by
  zero). New `AggFn` variants computed only in `compute_group`; every
  fast/scalar/subquery path declines to it. Boundaries (recorded, the
  engine answers them, fc refuses cleanly): the OVER (window) form, a
  HAVING comparison, a scalar subquery, DISTINCT - top-level select items
  only for now; and a DOUBLE-column source is moot because fc cannot yet
  INSERT into a DOUBLE column (a separate DML gap). No `VARIANCE`/`STDDEV`
  synonym (FB6 has neither - probed -804).

- **NTILE(n) window function DONE (2026-08-22, `serve-real-ntile` 3):**
  the ordered partition split into n buckets as equally as it divides
  (the first `size % n` buckets get one extra row), each row its 1-based
  bucket - byte-identical to the engine across bucket counts and with
  PARTITION BY, an INT64 named NTILE. Joins the RankFn machinery
  (ROW_NUMBER / RANK / DENSE_RANK). Boundary: an expression bucket count.
  (Probed the same day and left: LIST/GROUP_CONCAT needs a COMPUTED BLOB
  result fc cannot yet emit - `CAST(x AS BLOB)` refuses; CORR/regr and
  PERCENTILE_CONT/DISC ordered-set aggregates; NTILE done, LAG/LEAD with
  offset+default already worked.)
- **EXECUTE STATEMENT positional + named parameters DONE (2026-08-22,
  `serve-real-execstmt` 4):** the `(sql) (v1, ...)` head binds its `?`
  placeholders, and the `(a := v, ...)` head its `:name` placeholders, at
  run time - the values evaluated in the frame and substituted as SQL
  literals (a placeholder inside the statement's own string literal left
  alone; a repeated `:name` filled each time), which answers the engine's
  rows for the common types; the BLR is byte-for-byte the engine's.
  Boundary: USING / ON EXTERNAL / AS USER.
- **Dynamic EXECUTE STATEMENT operand DONE (2026-08-22,
  `serve-real-execstmt` 4):** the SQL operand may now be any expression -
  a `||` concatenation of literals and variables, or a bare variable -
  not just a literal. dsql parses it as a Val and each form
  (blr_exec_sql / blr_exec_into / blr_exec_stmt) emits the expression
  byte-for-byte with the engine; the interpreter already rendered the
  operand. Boundary: a parameter head `(sql)(vals)` and the USING / ON
  EXTERNAL / AS USER modifiers are still a later slice.
- **Cross-type procedure inputs DONE (2026-08-22, `serve-real-crosstype`
  3):** the engine's CVT for a procedure argument whose literal type
  differs from the parameter's - a text into an INTEGER (spaces trimmed,
  leftover text a 22018 "conversion error from string"), an integer into
  a text parameter (rendered decimal, then the width/CHAR-padding, an
  over-long value a 22018 too). One place, bind_proc_args, so every call
  path (EXECUTE PROCEDURE, a selectable FROM, the BLR fast path) converts
  the same. fc's proc parameters are only INTEGER/TEXT, so those are the
  pairs.
- **Row-locking / optimizer clauses DONE (2026-08-22, `serve-real-rowlock`
  5):** `FOR UPDATE [OF ...]`, `WITH LOCK [SKIP LOCKED]` and `OPTIMIZE FOR
  ...` are stripped before planning - this single-snapshot server does not
  act on them and their rows are the plain query's. FOR UPDATE / OPTIMIZE
  are lenient (taken over a view, CTE, join or aggregate); WITH LOCK is
  valid only over a single physical table with no aggregate (the engine's
  -104 otherwise), so fc leaves it in - and thus refuses - in every other
  shape rather than answer a row the engine never returns. (An explicit
  `PLAN (...)` is still refused: an invalid plan is an engine error, so it
  cannot be blindly stripped.)
- **Selectable EXECUTE BLOCK RETURNS DONE (2026-08-22,
  `serve-real-execblock` 5):** `EXECUTE BLOCK RETURNS (...) AS ... SUSPEND
  ... END` runs as a statement whose SUSPENDed rows are the result set -
  an anonymous selectable procedure. The output metadata is recovered by
  compiling a synthesized `CREATE PROCEDURE` (which also validates the
  body); the body is interpreted by the same run_body_source plain
  EXECUTE BLOCK uses, and the rows are served through Plan::ProcRows. The
  columns describe with an empty table/owner, the engine's shape, and an
  in-body error carries `At block line: L, col: C`. Boundary: input
  parameters (a client message) are not taken; a block naming an
  unresolvable object (an undefined EXCEPTION) refuses on both.
- **PSQL loop control CONTINUE / bare LEAVE DONE (2026-08-22,
  `serve-real-loopctl` 7):** `CONTINUE` (next iteration) and bare `LEAVE`
  (end the innermost loop) now COMPILE in fc's own dsql - a loop-label
  stack in the body parser gives each a blr_leave / blr_continue_loop
  (197) over the enclosing loop's label, byte-for-byte with the engine
  (pin test QW_LC) - and the interpreter runs them (every WHILE / FOR
  SELECT / FOR EXECUTE loop catches PsqlStop::Continue). Works in WHILE,
  FOR SELECT and nested loops; the engine runs the BLR fc stored. Before,
  fc could interpret a bare LEAVE it read from an engine-built procedure
  but its compiler refused both. LABELLED `LEAVE lbl` / `CONTINUE lbl`
  followed (same day): a `<name>:` prefix names a loop, an OUTER one
  included, resolved to that loop's label number - byte-for-byte with the
  engine (pin TOL), and the interpreter propagates a labelled jump to the
  matching loop. Boundary: CONTINUE/LEAVE outside every loop refuse.
- **SQL-standard OFFSET / FETCH DONE (2026-08-22, `serve-real-offsetfetch`
  16):** `OFFSET <n> ROW|ROWS` and `FETCH {FIRST|NEXT} [<n>] ROW|ROWS
  ONLY`, alone or combined (OFFSET then FETCH -> skip then take), beside
  the native FIRST/SKIP/`ROWS n [TO m]`. Parsed in `strip_modifiers` as a
  trailing clause, mapping to the same skip/take as the native forms;
  literal counts only (like FIRST/SKIP). The native `ROWS n [TO m]` scan
  is skipped when OFFSET/FETCH is present, since `FETCH NEXT 2 ROWS ONLY`
  contains the word ROWS. Composes with DISTINCT and inside a derived
  table. `WITH TIES` and `... PERCENT` are not this engine's syntax (both
  -104) and stay refused.
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
- **The auth tail DONE (2026-08-21, `serve-real-wirecrypt` 15):**
  ChaCha64 / ChaCha / Arc4 on offer (server-generated IVs announced in
  the accept keys as `TAG_PLUGIN_SPECIFIC`; key = SHA-256 of the SRP
  session key; `FC_WIRE_CRYPT` narrows the offer) — a default libfbclient
  now talks ChaCha64 to fire-crab, so every gate runs over it; wire
  COMPRESSION (`pflag_compress` echoed on the accept, one zlib stream
  each way below the encryption: a hand-written inflater for what
  arrives, stored deflate blocks for what leaves; `FC_WIRE_COMPRESS=0`
  declines); Legacy_Auth (the client's DES crypt of the password under
  "9z", checked through the C library's `crypt`; no session key, the wire
  stays clear; a wrong password is `isc_login`). The engine takes neither
  a Legacy_Auth client (its `AuthServer` is Srp256) nor compression (its
  `WireCompression` is off) — those cells are fc-only, recorded.
- **ARRAYS DONE (2026-08-21, `serve-real-arrays` 16, client
  `qa/c/arrays.c`):** `<type> [l:u, …]` at CREATE TABLE (RDB$FIELDS
  RDB$DIMENSIONS + RDB$FIELD_DIMENSIONS rows, the record field
  `dtype_array` 18 = an 8-byte array-blob id, described SQL_ARRAY); the
  array blob as `store_array` writes it (a stream blob: InternalArrayDesc
  16 + 24/dim, then the elements row-major); op_put_slice over a zero id
  makes a temp array the row's store materialises like a temp blob;
  op_get_slice reads the stored blob through the header's strides, the
  slice named by the SDL `gen_sdl` emits (element struct, relation,
  field, a do-loop per dimension, the scalar's variables) and the
  elements xdr'd by type. Laws probed: a temp array cannot be read before
  its row is stored (`invalid BLOB ID`); unset elements of a partial put
  are zero; out-of-bounds subscripts are `isc_ss_out_of_bounds`, a short
  buffer `isc_out_of_bounds`. The engine reads fc's arrays, including a
  table fc's own DDL created. **Recorded boundaries:** element types
  SMALLINT/INTEGER/BIGINT/FLOAT/DOUBLE/DATE/TIME/TIMESTAMP only (text and
  NUMERIC elements refuse; arrays of domains refuse); an SDL whose
  element type differs from the stored one refuses (`isc_invalid_sdl`)
  where the engine converts; ARRAY columns only at CREATE TABLE (ALTER
  ADD refuses); `isc_array_lookup_bounds` (the client's catalog query
  through `system.rdb$sql.parse_unqualified_names`) is outside fc's SQL
  surface — clients must build their descriptors. (All lifted the same
  day — see ARRAY TAILS below.)
- **ARRAY TAILS DONE (2026-08-21, `serve-real-arrays` 34):** CHAR and
  NUMERIC/DECIMAL elements (the catalog rows carry the scale; an SDL
  `blr_text` element carries its length word); element CONVERSION on
  get and put (`convert_element`: scaled ints, float/double, rounding
  half away from zero; an element the SDL type cannot hold is the
  engine's `isc_arith_except`); `ALTER TABLE … ADD <type> [l:u]` writes
  the RDB$FIELD_DIMENSIONS rows, and an UPDATE now re-lays a record
  stored in an OLDER format into the newest one instead of refusing
  (`upgrade_image`, field by field by id — the first ALTER ADD + UPDATE
  of an old row fc answers); `isc_array_lookup_bounds` runs over the
  wire: `system.rdb$sql.parse_unqualified_names(rdb$get_context(
  'SYSTEM','SEARCH_PATH'))` folds at prepare (`rewrite_system_sql`:
  the SEARCH_PATH / CURRENT_USER / CURRENT_SCHEMA / ENGINE_VERSION
  context to literals, the function to a `UNION ALL` derived table
  of names), and a WINDOW over a derived table / CTE plans
  (`plan_win_item` shared with the Project path; `Plan::Derived`
  folds after the WHERE and before the sort; `OVER ()` with no order
  numbers the scan order and ranks every row 1). The singleton inline
  blob path was already covered by `op_inline_blob` (the remaining
  `OP_SQL_RESPONSE` site is a scalar path with no blob).
- **`op_info_transaction` DONE (2026-08-21, `serve-real-trainfo` 36,
  client `qa/c/trainfo.c`):** every item — `tra_id`, the oldest
  interesting / snapshot / active counters (4-byte, obeying id ≥ oat ≥
  ost ≥ oit on both servers), isolation (consistency 1, concurrency 2,
  read committed 3 + the READ CONSISTENCY option 2 for every flavour),
  access (the new `Tpb.read_only`), lock_timeout (−1 wait / 0 no wait /
  N), `fb_info_tra_dbpath` (the attach string, answered FIRST whenever
  asked — probed), `fb_info_tra_snapshot_number` (0 when read committed);
  answers in request order, repeats repeated, an unknown item
  `isc_info_error`, overflow `isc_info_truncated`;
  `isc_tpb_at_snapshot_number` refused with the engine's "base snapshot
  number does not exist".
- **ARRAYS OF DOMAINS DONE (2026-08-21, `serve-real-arrays` 43):**
  `CREATE DOMAIN DA AS INTEGER [1:3]` writes the dimension rows on the
  domain; a column of it is the array (`DomainType.dims`, read back from
  RDB$FIELD_DIMENSIONS); `isc_array_lookup_bounds` resolves through the
  field source. Found on the way: a DOMAIN's NOT NULL was never enforced
  at INSERT (fc read only RDB$RELATION_FIELDS.RDB$NULL_FLAG; the engine
  keeps a domain's on RDB$FIELDS) — `not_null_fids` now follows the
  field source.
- **BLOB COLUMNS + BLOB FILTERS DONE (2026-08-21, `serve-real-blobfilter`
  95, client `qa/c/blobcol.c` printing status vectors raw):**
  until this slice fc's OWN DDL had no BLOB type at all (every blob table
  in the gates was an engine-built fixture) and no literal could land in
  a blob column. Now `BLOB [SUB_TYPE {n|TEXT|BINARY}] [SEGMENT SIZE n]
  [CHARACTER SET cs]` (type 261, SEGMENT_LENGTH 80 unless declared, the
  text blob's charset — also what DESCRIBE announces in sqlscale);
  string (sub_type 1) and `_octets` (sub_type 0) literals stored as blobs
  at INSERT and UPDATE (`store_blob_literal`; an UPDATE matching no row
  stores and raises nothing); the engine's filter law (`isc_nofilter
  from, to`: TEXT into a user sub_type refuses, binary lands anywhere; a
  bpb on open needs no filter for same/same, to binary, or binary to
  text); `DECLARE FILTER` / `DROP FILTER` (RDB$FILTERS row + security
  class) with the engine's vectors — duplicate name, duplicate
  (input, output) pair = the unique violation on RDB$INDEX_17, missing
  name; `BLOB SUB_TYPE 2` refused at CREATE TABLE with the nested −204
  vector; `IS [NOT] NULL` over a BLOB/ARRAY column. General fixes found
  on the way: DESCRIBE never announced NOT NULL (every column was 497 —
  now a plain base column reads its flag: 496); a blob's negative
  sub_type went through the text-charset convention (−5 described as
  charset 3, length 24, and the row message was 24 bytes wide).
  **Recorded boundaries:** CAST(<blob> AS VARCHAR) is outside the
  expression engine; the internal system-sub_type filters (BLR/ACL/… →
  text) are not mirrored; a text-blob DOMAIN's charset does not reach the
  descriptor; NOT NULL through expressions / join sides still describes
  nullable.
- **CAST(<blob> AS …) DONE (2026-08-21, `serve-real-blobcast` 21):** the
  evaluator carries no database, so the connection loop arms a per-op
  image (`BLOB_CTX`, an Arc clone) and `Expr::BlobText(fid)` —
  produced when a CAST's operand is a plain BLOB column — materialises
  the blob at evaluation: text and binary blobs cast to their bytes, the
  text truncation vector when they do not fit, `isc_nofilter(st, 1)` for
  a user sub_type, a numeric target converts the text; works in WHERE /
  UPPER / LIKE / `||` / ORDER BY, and `expr_reads` decodes the blob
  column only when read. **Boundaries:** `<blob> || 'x'` (a BLOB
  result), CHAR_LENGTH(<blob>) and `WHERE <blob> = 'x'` without a CAST
  stay refused; a temp blob of the running transaction is not readable
  by an expression; CAST(x AS CHAR(n)) describes 448 on fc for ANY
  operand (the engine 452) — the fixed-text wire form is its own slice.
- **NOT NULL IN DESCRIBE DONE (2026-08-21, `serve-real-notnulldesc`
  27):** the nullable bit now travels the engine's way (probed):
  `expr_nullable` — an expression is nullable only when an input is
  (arithmetic, negation, CAST, `||`, the string/date functions, CASE/IIF
  by their branches); COALESCE, NULLIF, a boolean, a parameter, a
  subquery and NULL always; `mark_not_null_join` — INNER keeps both
  sides, LEFT/FULL null the right side, RIGHT/FULL everything before;
  a GROUP BY key keeps its column's bit; a derived table / CTE copies
  the inner's; a UNION is nullable when any branch is. Unknown shapes
  stay nullable (the bit is only ever cleared when certain).
  **Boundary found:** `CURRENT_TIMESTAMP` in a select list refuses
  (`CURRENT_DATE` answers).
- **CURRENT_TIME / CURRENT_TIMESTAMP DONE (2026-08-21,
  `serve-real-currenttime` 8):** TIME / TIMESTAMP WITH TIME ZONE
  (32756/8, 32754/12) in the session zone (the server's OS zone —
  `/etc/timezone`, `TZ` — through `tz::zone_id`), optional precision
  (`CURRENT_TIME` defaults to 0 fractional digits, `CURRENT_TIMESTAMP`
  to 3, probed), never nullable; `TKind::TimeTz/TimestampTz`,
  `Expr::TimeTzLit/TsTzLit`. Also `mark_not_null_cols` no longer skips
  a table without NOT NULL columns (a literal over RDB$DATABASE is
  not-nullable too).
- **INTEGER WIDTHS DONE (2026-08-21, `serve-real-intwidth` 7):**
  `result_width_bytes` now follows the engine — an integer literal is
  LONG when it fits 32 bits (BIGINT beyond), negation keeps, CASE / IIF /
  COALESCE take their widest branch, NULLIF its FIRST argument's type
  (probed); arithmetic stays BIGINT. The wire form follows the describe.
- **CHAR TRAVELS AS CHAR (2026-08-21, `serve-real-charform` 8,
  `serve-real-charset` 43):** until this slice every CHAR column and every
  fixed-text expression described as VARYING (448) — a client saw
  CHAR(5) as VARCHAR(5). Now `Wire::Text`: a CHAR column, a text
  literal, CAST AS CHAR, UPPER/LOWER of a CHAR, CASE/COALESCE/IIF of
  CHARs describe 452 at the engine's width (a UTF8 CHAR(3) is 12
  bytes); TRIM, `||`, SUBSTRING and VARCHAR stay 448 (`text_form`
  already knew — the flag was dropped at the describe). The row carries
  the FORM THE CLIENT DECLARED in its blr (`OutSlot.fixed`, at the
  client's declared byte length — the engine serves a CHAR fetched as
  VARCHAR and back); a fixed slot is space-padded, no length word. Input
  binds keep the even form by design (see `nullable`).
- **RDB$SET_CONTEXT / RDB$GET_CONTEXT DONE (2026-08-21,
  `serve-real-context` 61):** the attachment's USER_SESSION /
  USER_TRANSACTION variables (a thread-local per connection; the
  transaction map empties at COMMIT / ROLLBACK, not RETAINING);
  SET_CONTEXT answers 0 new / 1 existed, a NULL value deletes;
  GET_CONTEXT is VARCHAR(255) nullable, NULL for an unknown name; SYSTEM
  answers the session's facts at evaluation (and is read-only); any other
  namespace is `isc_ctx_namespace_invalid`; the select list evaluates
  RIGHT-TO-LEFT when a SET_CONTEXT is in it (probed — `SET(K, v),
  GET(K)` reads the old value). Until this slice fc folded every
  non-SYSTEM GET_CONTEXT to NULL at prepare — a silent wrong answer.
  `rewrite_system_sql` now folds only inside `PARSE_UNQUALIFIED_NAMES(`.
  Boundary: the functions inside a PSQL body (the dsql crate) are not
  this slice.
- **DESCRIBE IN THE ATTACHMENT CHARSET (2026-08-21, found by
  `serve-real-outblr` 32 through node-firebird 2.11):** a plain column of
  a REAL charset (anything but NONE / OCTETS — ASCII included) is
  described in the ATTACHMENT's charset at chars × its bytes per char
  (WIN1252 CHAR(5) under UTF8 is len 20 charset 4; a UTF8 CHAR(3) under
  WIN1252 is 3 charset 53; NONE keeps its bytes — probed with `isql -ch`).
  fc always announced the column's own charset; VARCHAR hid it (clients
  read the counted length), CHAR exposed it (2.11 derives the char count
  from the declared width). `resolve_text_cs` now carries the rule.
- **CREATE / DROP VIEW DONE (2026-08-21, `serve-real-createview` 4 — the
  ENGINE opens fc's file and runs fc's BLR):** `CREATE VIEW <name>
  [(cols)] AS <select>` plans the SELECT at prepare: a plain column
  reuses its base relation's RDB$FIELD_SOURCE with RDB$BASE_FIELD and
  RDB$VIEW_CONTEXT; an expression column gets an auto-domain RDB$<n> of
  its type (precision by storage width) carrying the expression's BLR
  over the VIEW's streams in RDB$COMPUTED_BLR (no source — probed;
  `dsql::compile_view_columns`); the FROM items are the contexts (1.. in
  order, the alias quoted or `"PUBLIC"."T"`); `RDB$VIEW_BLR` is the dsql
  crate's RSE (its select-list scanner now skips expression items,
  aggregates still refuse); dbkey 8 bytes per context, a security class
  and a default class written on the row at INSERT (a later patch of a
  full system page has no room for a new version — measured on the fifth
  view of one transaction); `DROP VIEW` removes the relation, its fields,
  its own auto-domains, view relations, formats, class and privileges,
  with the engine's vectors (duplicate name, missing / not-a-view: the
  nested −607 with the VIEW verbs). **Boundaries:** WITH CHECK OPTION,
  UNION views, derived tables / CTEs in the FROM, an expression outside
  the dsql crate's surface, `ALTER VIEW`.
- **ALTER / DROP TRIGGER, CREATE OR ALTER TRIGGER / PROCEDURE, ALTER
  PROCEDURE DONE (2026-08-21, `serve-real-altertrigger` 3):** `ALTER
  TRIGGER` edits the active flag / position in place, or redefines (an
  event clause or a body — through the CREATE planner over the stored
  relation, unspoken attributes kept); `CREATE OR ALTER TRIGGER` keeps an
  existing trigger's sequence and flag unless the statement says
  (probed); `DROP TRIGGER` removes the row and its dependency rows;
  `ALTER PROCEDURE` / `CREATE OR ALTER PROCEDURE` replace the row keeping
  `RDB$PROCEDURE_ID` (`create_procedure_with_id`); the engine's
  missing-object vectors (336397271/273/266 + 336068755/748), the name
  checked before the body. `UserTriggerDef.inactive`.
- **BLOB IDS ON THE WIRE ARE xdr_quad (2026-08-21):** every quad crossing
  the wire (rows, inline blobs, op_create_blob's answer, parameters,
  op_open_blob / slices, batch regblob and the batch blob stream's
  headers) now carries the ISC_QUAD's two memory words big-endian; fc
  sent and read the file's little-endian bytes, which every echoing
  client round-tripped and isql rendered as `c000000:a000000` for the
  engine's `c:1e6`. All nine blob/array/batch gates green after the
  switch.
- **NEXT**: the tail of the auth/restore-only DDL — `CREATE USER` (the
  security database's PLG$SRP, not this catalog); `CREATE SHADOW` (a
  physical shadow file beside its RDB$FILES row); and collation-aware
  ordering (this server keys binary). Both are outside fc's pure-catalog
  model (a separate database / a physical file), so the DDL group is
  effectively complete for the catalog cases.
  (`PACKAGE` headers + BODY DONE 2026-08-22: CREATE/DROP PACKAGE write
  RDB$PACKAGES + declaration members + params, byte-for-byte; a
  `declaration` flag on the procedure/function writers omits the BLR
  columns. CREATE PACKAGE BODY compiles each member's full body (a
  BEGIN/END-depth splitter finds the PROCEDURE/FUNCTION boundaries),
  fills its BLR/TYPE/VALID_BLR keeping the member id and rewriting the
  params over fresh domains, leaves the member SOURCE null, and stamps
  RDB$PACKAGES with the body source + VALID_BODY_FLAG. A second body or a
  body with no header refuses with the engine's vector; the engine runs
  the BLR fc stored. serve-real-package 7. INVOKING packaged routines
  from a query DONE 2026-08-22: a packaged FUNCTION resolves in a select
  list and a selectable PROCEDURE in the FROM clause - bare, `PUBLIC.`-
  and `SCHEMA.`-qualified, over literals / table columns / nested calls -
  with the engine's arity, -804 (unknown function), -204 "Procedure
  unknown" (unknown selectable procedure in a FROM call) and -204 "Table
  unknown" (an unknown relation in the FROM or in any subquery / derived
  table / IN-EXISTS body) vectors;
  load_function became package-aware like load_procedure, and a packaged
  member coexists with a same-named plain routine (function AND procedure).
  serve-real-callpkg 9.) (`MAPPING`
  and `COLLATION` DONE 2026-08-22: CREATE/ALTER/DROP MAPPING →
  RDB$AUTH_MAPPING and CREATE/DROP COLLATION → RDB$COLLATIONS, both
  byte-for-byte with the engine's catalog and vectors — serve-real-mapping
  5, serve-real-collation 5. The collation SPEC's ICU version is copied
  from the base collation; ids count down from 126 per charset. GLOBAL
  mapping and FROM EXTERNAL collation refuse.) (`DROP TABLE` dependency
  enforcement is now complete for the common cases: views, procedures, and
  FK/PK back-references all block with the engine's exact vector and count.
  serve-real-dropdeps 7 — FK/PK is checked first and wins over a view; the
  count is views-else-procedures. One boundary remains: a table referenced
  ONLY by a trigger on another table, which is DFW-internal category
  precedence.) The common `CREATE TABLE` column types are now all in: BLOB,
  NUMERIC, DECFLOAT, `TIME/TIMESTAMP WITH TIME ZONE`, `CHARACTER SET` /
  NCHAR / `COLLATE`, and arrays (single- and multi-dimension; the multi-dim
  fix was a `[]`-aware column-list splitter — serve-real-arrays 46, which
  now round-trips a 2-D array through fc's own CREATE TABLE). (Non-default `COLLATE`
  DONE 2026-08-21 for the built-in UTF8 family: the collation rides the
  ttype high byte, RDB$COLLATION_ID written on both the field and
  relation-field rows; serve-real-charsetddl grew two COLLATE columns.
  Boundaries: a language collation needs the full RDB$COLLATIONS lookup,
  and collation-aware ORDER BY / index keys stay binary — later slices.) (`DROP TABLE`
  view-dependency enforcement DONE 2026-08-21: a view over a table blocks
  its DROP with the engine's "there are N dependencies" vector, N = distinct
  dependent views from RDB$VIEW_RELATIONS — which is exactly the engine's
  count whenever any view exists. The engine defers to COMMIT and fc refuses
  at execute, but isql auto-commits so they read identically.
  serve-real-dropdeps 5. Boundaries: procedure-only and FK/PK-parent drops
  are refused by the engine, dropped by fc.) (`CREATE TABLE` `CHARACTER SET` / NCHAR
  columns DONE 2026-08-21, single-byte and multibyte UTF8: catalog +
  describe + record layout matched, a UTF8 value inserted through fc stores
  at the right width and the engine reads it back; serve-real-charsetddl 7.
  The descriptor sub_type is the ttype the read path already keys on, the
  catalog RDB$FIELD_SUB_TYPE a separate 0.) (`CREATE TABLE` with DECFLOAT / DECFLOAT(16|34) and
  `TIME/TIMESTAMP WITH TIME ZONE` DONE 2026-08-21: catalog + describe +
  record layout matched, the engine writes tz values into fc's own table
  and both read them back; serve-real-coltypes 7. BLOB, NUMERIC, BOOLEAN,
  INT128 were already in. Separate value-parser gaps left: a WITH TIME
  ZONE literal and a scientific `1E10` DECFLOAT literal in an INSERT.)
  (`RECREATE` DONE 2026-08-21: `RECREATE TABLE/VIEW/PROCEDURE/EXCEPTION/
  SEQUENCE/FUNCTION` = drop-if-exists then create, the CREATE planned at
  prepare so a bad definition preserves the old object; `Plan::Recreate(Box<Plan>)`,
  `plan_recreate` rewrites to CREATE and wraps, exec drops-then-creates.
  serve-real-recreate 5 checks. `ALTER VIEW` DONE 2026-08-21: replaces a
  view keeping its relation id — ods `alter_view` drops and repopulates with
  a `forced_id`; missing-view vector matched. serve-real-alterview 5 checks.
  Boundary carried by both: this server's DROP TABLE does not enforce
  dependencies.) (`CREATE FUNCTION`
  DONE 2026-08-21: CREATE/DROP FUNCTION write the catalog and BLR, and a
  PSQL function is CALLED from a select list — `F(<expr>)` resolves only
  against the catalog, describes as the RETURN domain, and evaluates per
  row by materialising the statement's rows at the first fetch, each call
  run through `run_function`. `RETURN <text>` is a new `TrigStmt::ReturnText`;
  an unknown `NAME(` is -804, the wrong arity `fun_param_mismatch`. Gate
  serve-real-createfunction, 7 checks. Boundary: a long blob-returning
  session under wire encryption accumulates op_inline_blob packets past
  the client's cache — pre-existing, unrelated to functions — so the gate
  checks the catalog query by query in fresh attachments. A distinct
  per-transaction handle scheme (the engine's model, which would let one
  session carry the catalog blobs beside the calls) was tried and reverted:
  it fixed that case but desynced the SQLDA_DISPLAY request path under
  crypt; deferred.) Full sweep 2026-08-21 after the UPDATE-format change:
  259 gates, 8246 checks, 0 DIFF. MERGE `RETURNING` / `NOT MATCHED BY
  SOURCE`, `op_info_blob` / `op_seek_blob`, the ordered JOIN fetch
  streaming, the RIGHT/FULL hash, the bulk index build, the cleanup — all
  done 2026-08-21.
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
