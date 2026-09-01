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
| LATERAL is an ordinary source | a LATERAL materialises before anything above it runs, so DISTINCT / FIRST / SKIP / ROWS, an outer WHERE or ORDER BY, a derived table over it and COUNT/SUM/GROUP BY/HAVING over that derived table all work; the fetch batch is honoured (it hung any flow-control-honouring client past ~2340 rows); the comma form carries the inner column's nullability, the LEFT form is always nullable | `serve-real-lateral` 36 |
| a literal is bytes in the attachment's charset | statement text is decoded by `lc_ctype` instead of `from_utf8_lossy`, so a lone `0xE9` under a NONE attachment is data; a literal's charset tags the value, the CAST source and the store; and a byte carrier yields its TAG to the other operand but never its BYTES | `serve-real-litcs` 60+ |
| one per-connection object id space | a compiled BLR request and a prepared statement are different KINDS over ONE client-side id space (fbclient's `port_objects` is a single untagged union array); minting them from separate counters collided at id 5 and KILLED THE CONNECTION | `serve-real-objid` 14 |
| a folded subquery carries its column's charset | a select-list scalar subquery is erased at prepare - its value is spliced back into the statement TEXT and re-planned - so the spliced literal was typed like any literal, in the ATTACHMENT's charset, and the inner column's set was lost the moment the subquery became an OPERAND. Now spliced as `CAST(x'..' AS VARCHAR(n) CHARACTER SET <set>)` | `serve-real-subqdesc` 70 |
| a window is a value and composes | each window call is LIFTED out of its expression, folded as its own column, and replaced by a reference to it - so `ROW_NUMBER() OVER (...) + 1`, COALESCE/CASE/CAST/function/concat over a window, and two windows in one expression all work; plus PERCENT_RANK and CUME_DIST | `serve-real-window` 139 |
| a NULL side is NULL however spelled | `IS [NOT] DISTINCT FROM` desugared to IS NULL only for a BARE NULL token, so a parenthesised or CAST NULL fell through to a value comparison and came back EXACTLY INVERTED | `serve-real-nulls` 40 |
| a correlated subquery answers per row or refuses | only EQUALITY pairs counted as a correlation; anything else was re-evaluated as UNCORRELATED and folded to ONE verdict for every row, so the anti-join idiom answered every row and the running-count idiom answered 0 | `serve-real-nulls` 40 |
| a bare NULL branch contributes nothing | `makeFromList` ignores a NULL argument for unification and falls back to CHAR(1) NONE only when EVERY argument is NULL; fire-crab typed a bare NULL as INT64 and let it WIN, announcing a VARCHAR(10) UTF8 as len 32765 charset NONE | `serve-real-branchtype` 69 |
| the output format travels with the row | the singleton path (`op_execute2`, how an INSERT ... RETURNING is answered) emitted with NO OutFmt, so a CHAR result was written in the value's own bytes while the describe announced the attachment's - under -ch UTF8 `RETURNING 'ok'` announced len 8, wrote 2, and KILLED THE CONNECTION | `serve-real-returningexpr` 33 |
| a MERGE's DELETE branch has no NEW record | `RETURNING NEW.<col>` over a deleted row is NULL, PER ROW (a mixed merge answers the update branch's values and the delete branch's NULLs in one result); and the describe follows a three-way rule - every branch deletes = the null constant, some branch deletes = named CONSTANT with the column's type, none deletes = the column itself | `serve-real-returnold` 59 |

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

**TIME/TIMESTAMP WITH TIME ZONE values in DML DONE (2026-08-25,
`serve-real-tzdml` 8):** fc could CREATE tz columns and read
engine-written rows; every tz VALUE refused. Now: zone-tailed
literals (`TIMESTAMP '... +02:00'`, `TIME '... UTC'`) parse
(`split_zone_tail`/`resolve_zone_tail` beside the CVT grammar,
BARE-digit offset fields — the engine 22009s every inner-sign
spelling, and `'-+2:00'` briefly stored a SIGN-FLIPPED instant
before review), the wall clock converts local→UTC by
`tz::displacement` (offset zones id = minutes+1439 and the UTC
family; NAMED zones with tzdata rules REFUSE — fc carries the
id↔name table, tzdata 2026c names, no rules, and a wrong instant is
worse than a refusal), and the stored form (UTC halves + USHORT
zone id) flows through new `RawExpr::TimeTzLit/TsTzLit` and
`WireParam::TimeTz/TimestampTz` into destination-aware
`encode_wire_value` arms: tz column verbatim, zoneless value into a
tz column takes the SESSION zone permanently (measured), tz value
into a zone-less column converts to session wall, text with a zone
tail everywhere the CVT grammar takes one. WHERE/ORDER BY compare
by UTC INSTANT across spellings (`temporal_kind` types the tz
dtypes; `value_cmp` mixed tz/plain arms read the zoneless side as a
session instant; `session_zone_id` is cached — it read
/etc/timezone per row). The 22009 vectors ride PREPARE_REFUSAL
verbatim (`Invalid time zone region/offset`), the DML branch now
clears+consumes it (and refreshes USER_FNS with it — a stale map
briefly called fresh functions unknown). The 16-agent review's
other catches, all fixed live-verified: the engine's 22008
`value exceeds the range for valid timestamps` at READ of a stored
instant past 0001..9999 (both servers ACCEPT the insert — the wall
clock was in range; fc used to serve the row); tz-column
SUBTRACTION (UTC-instant difference, TIME pairs at scale -4,
tz-minus-plain via session — fc answered NULL and silently emptied
filters); CAST of a zone-tailed STRING to plain temporals
session-converts (fc raised an affirmative 22018); CAST/concat of a
ruleless named-zone VALUE refuses (fc's own render is the
visibly-unconverted `<tz ...>` — it leaked as output);
INSERT..SELECT carries tz values via new psql_literal arms.
GROUP BY/DISTINCT/UNION over tz keys REFUSE (`plan_tz_dedup`): the
engine's tie representative is an unstable internal-sort artifact —
it flipped between largest- and smallest-zone-id under a WHERE
during review — and a wrong representative is a wrong answer.
Boundaries recorded: ruled named zones in DML, TIME-TZ into
TIMESTAMP (the 2020-01-01 base-date re-anchor law), CREATE INDEX on
tz columns, tz parameters, no-space zone tails, EXECUTE BLOCK tz
literals (all clean refusals). *(`EXTRACT`/`AT TIME ZONE` were on
that list until the slice below closed them.)*

**AT TIME ZONE, the time-zone EXTRACT parts and SET TIME ZONE DONE
(2026-08-26, `serve-real-attimezone` 49):** `<value> AT TIME ZONE
<zone>` and `<value> AT LOCAL` — a left-chaining postfix operator in
both front-ends (`expr_at_tz`, `texpr_at_tz`) — CONVERT AND THEN
RE-LABEL, the engine's own shape (AtNode::execute, ExprNodes.cpp:
3368: `MOV_move` to the WITH TIME ZONE type normalises to a UTC
instant, then only the zone id is overwritten). So a ZONELESS
operand is a wall time in the SESSION zone (12:00 under a UTC
session is 14:00 +02:00, 11:00 +02:00 under a +03:00 one — the
standard's reading, the opposite of PostgreSQL's re-anchoring) and a
ZONED one keeps its instant. The result is always a WITH TIME ZONE
value of the operand's family, described 32754/12 and 32756/8, named
`AT`, nullable iff either operand is; the zone is any expression,
evaluated per row, and a bad one raises the engine's 22009 at
EXECUTE. `EXTRACT` gains `TIMEZONE_HOUR`/`TIMEZONE_MINUTE`, SIGNED on
BOTH parts (`-03:30` gives −3 and −30), answering the SESSION
offset for a zoneless operand; its ordinary parts now read a zoned
value's LOCAL wall clock where they used to refuse. `SET TIME ZONE
'<zone>' | LOCAL` sets the session zone (`Plan::SetTimeZone`,
reported `isc_info_sql_stmt_ddl` as the engine reports every
session-management statement) and the zoneless clocks
(LOCALTIME/LOCALTIMESTAMP/CURRENT_DATE) move with it.
Four pre-existing divergences fell out with it: EXTRACT announced
BIGINT where the engine announces SMALLINT (and INTEGER at scale
−4/−1 for SECOND/MILLISECOND) — top level AND under every wrapper; a
WITH TIME ZONE column named out of a DERIVED TABLE or CTE decoded as
a BIGINT and answered **0** (`desc_of_projcol` had no tz arm);
COALESCE announced nullable always (the engine's list rule is
"nullable if ANY argument is"); and `expr_reads` — the walker that
decides whether a term is row-dependent — had a catch-all that
judged `<column> AT TIME ZONE '…'` row-INDEPENDENT, evaluated it
against an empty row and SILENTLY DROPPED EVERY ROW of a WHERE.
Boundaries: a ruled region still refuses everywhere (no tzdata
rules) and `TIMEZONE_NAME` refuses (ICU-rendered). *(The
isql-autocommit boundary recorded here — a `stmt_ddl` statement
committing the caller's pending DML — is CLOSED by the slice below.)*

**REAL PER-TRANSACTION WIRE HANDLES — DONE 2026-08-26
(`serve-real-txhandle` 10).** One attachment may hold several
transactions, and every op that carries a transaction handle names
WHICH one it means. fire-crab answered one fixed handle for all of
them and threw the incoming handle away, so a commit of one committed
them all: isql's autocommit of a DDL statement committed the user's
pending DML and the ROLLBACK that followed restored nothing, and two
explicit transactions on one attachment both survived when only one
was committed. **A rollback that does not roll back was the last
known wrong-answer class in this server.**
The model is a CONTEXT SWITCH: `Database` still holds ONE
transaction's state in its own fields, every other open transaction
is parked in a `TxSlot`, and `switch_tx` swaps them so the whole body
of the server keeps reading one transaction out of the fields it
always did — only the switch points know there are others. What is
per transaction: its id and nested ids, undo windows, snapshot,
generator cache, temp blobs, deferred DDL, TPB settings, savepoint
names, the 2PC limbo bit — and, after review, **its lock owner**.
`op_transaction` allocates the LOWEST FREE handle (the client indexes
its objects by handle, so they must stay small and dense — a
monotonic counter that climbed away was rejected outright, and the
protocol's object field is only sixteen bits); `op_commit` /
`op_rollback` resolve the named handle and free the slot, the
retaining forms keep it, and a handle that names nothing is
`isc_bad_trans_handle`. `SET TRANSACTION` executed with handle 0
opens one and the response carries the new handle. Statement handles
now step over live transaction handles.
Two corruption classes the review caught, both fixed and gated:
ending one transaction released the WHOLE attachment's locks, so a
concurrent `gfix -sweep` read a still-live sibling as abandoned and
backed its committed rows out; and temp-blob ids restarted at 2 in
every transaction while `op_put_segment` carries no handle, so a
segment landed in the sibling's blob. The earlier attempt at this
change died on `op_inline_blob`, which stamps the transaction the
client caches the blob under — it carries the live handle now.
Recorded: two transactions of ONE attachment do not conflict with
each other (they share no lock arbitration), and fetches bind to the
transaction live at fetch time (`op_fetch` carries no handle).

**BINARY LITERALS AND THE OCTETS LAWS — DONE 2026-08-26
(`serve-real-octets` 32).** `x'…'` is not a string with a funny
spelling: it is CHAR(n) CHARACTER SET OCTETS, and OCTETS is the one
character set whose *space* is a NUL byte. Getting the literal in was
half a day's parsing; the other half was that every string law bends
around that pad byte, and fire-crab had them all on the blank —
including for OCTETS **columns**, which is where the wrong answers
were:

* a `CHAR(4) CHARACTER SET OCTETS` holding `x'6162'` reads back
  `61620000`. fire-crab wrote `61622020`, so its file and the
  engine's disagreed byte-for-byte on data the engine could read.
* comparison pads the shorter side with 0x00 as soon as EITHER side
  is binary, and transliterates neither (`CVT2_compare`,
  cvt2.cpp:438): `x'4100' = 'A'` is TRUE where `x'4120' = 'A'` is
  FALSE. Both sides now wrap in `Expr::OctKey`, the byte-string twin
  of the collation key — the same trick, for the one charset whose
  padding rule the ordinary compare cannot express.
* `UPPER`/`LOWER` over OCTETS are IDENTITY. The binary texttype
  installs `internal_str_copy` for both directions
  (intl_builtin.cpp:1025) where NONE and ASCII, which share
  `FAMILY_INTERNAL`, upcase the ASCII range.
* `TRIM`'s default character is the charset's space — one 0x00 — so a
  0x20 survives a `TRIM` and a 0x00 does not. `LPAD`/`RPAD` fill with
  the same byte. The default form now carries ONE argument through
  the raw tree and resolution fills the pad in, where the descriptors
  are; a written-out character is still used as written.
* **`LIKE` over a binary left operand has no wildcards at all.** The
  wildcard bytes are `%` and `_` converted FROM UNICODE into the left
  operand's charset (Collation.cpp:1025), and the binary charset's
  converter is a UTF-16 byte dump (intl_builtin.cpp:926), so each
  arrives as `{0x00,0x25}` / `{0x00,0x5F}`; the matcher reads the
  first byte only, and its `sql_match_any &&` guard (evl_string.h:352)
  reads a zero as "no wildcard". What is left is a literal byte match
  over the FULL padded value — a `CHAR(4)` holding `61620000` matches
  `x'61620000'` and NOT `x'6162'`. A CHAR left operand keeps its
  wildcards even when the pattern is binary, and `SIMILAR TO`, a
  different engine entirely, keeps them for binary too.
* the result charset ABSORBS: one OCTETS operand makes the whole
  concatenation, CASE, COALESCE or MIN binary
  (`getResultTextType`, DataTypeUtil.cpp:59, now `cs_join`'s rule) —
  and a high byte then travels as ONE octet instead of its UTF-8
  pair, which also fixed a spurious string-truncation raise.

An OCTETS column now takes the EXPRESSION predicate path, the way a
temporal one does, because that is where these laws live. A binary
LIKE/STARTING pattern travels as `Rhs::Oct` so the LEFT operand can
decide whether its bytes are a value or a text pattern. The store
path carries the charset too (`expr_value_to_wireparam`), or
`x'41FF'` landed as its UTF-8 three bytes. `REPLACE` gained the
describe width the engine computes (source + how much longer the
replacement is, once per possible occurrence) — it was announcing
32765 for every call. Boundaries, both recorded and refused rather
than answered: a LIKE pattern that is not a literal (a parameter or
an expression) against a binary side, and `CAST(… AS … CHARACTER SET
…)`, which the slice below closed.

**THE CHARACTER-SET CAST — DONE 2026-08-26 (`serve-real-cscast`
40).** `CAST(<v> AS CHAR|VARCHAR(n) CHARACTER SET <cs>)` is how a
value crosses between character sets, and it was refused in every
set. Now it converts, with the three error classes the engine
separates — and the separation is the feature: which one a value
earns says *where it came from*.

* **to a byte carrier** (NONE, OCTETS) the OCTETS travel, whatever
  they are: a UTF8 `'café'` cast to NONE is its five UTF-8 bytes, a
  WIN1252 one its four codepage bytes.
* **from a byte carrier into a real set** the bytes must SPELL that
  set or it is `isc_malformed_string` (22000): `x'41FF'` into UTF8, or
  any byte past 0x7F into ASCII. A single-byte destination has an
  image for every octet, so `x'8182'` into WIN1252 answers.
* **between two real sets** the CHARACTERS travel and one with no
  image is `isc_transliteration_failed` (22018) — the *other* vector
  for the same bytes. Out of a BLOB source that failure carries no
  arithmetic-exception wrapper where its truncation does (measured,
  and now a vector of its own).
* transliteration comes **before** the width: five untranslatable
  characters into a `VARCHAR(2)` is the 22018, never the 22001.
* the width is counted in CHARACTERS OF THE TARGET, and the overflow
  that may silently drop is the target set's **pad**: `x'41202020'`
  into a `VARCHAR(2) CHARACTER SET OCTETS` raises where `x'41000000'`
  fits, because OCTETS pads with a NUL. A CHAR target fills with the
  same byte.

The result is a first-class value OF that set, so the OCTETS laws of
the slice above apply to it: `CAST('A' AS CHAR(2) CHARACTER SET
OCTETS) = x'4100'` is TRUE, its LIKE has no wildcards, and one such
operand makes a whole concatenation binary. Three seams had to learn
the same lesson, and each was a wrong answer before it: the STORE
path now binds a value with its own character set (a cast to NONE
landed as the UTF-8 of the characters it had decoded to), the
out-capacity check counts the bytes the EMIT will actually ship (a
tabled destination ships one byte per character, so a WIN1252 result
whose UTF-8 spelling is longer than the slot still fits), and
`OCTET_LENGTH` reads any expression's own set rather than only a
column's.

Refusals kept honest: a character set the engine has that fire-crab
carries no table for (UNICODE_FSS, the DOS pages, the multibyte
pages), a `COLLATE` naming anything but the set's own collation (its
ordering is a different answer, not a different spelling), a quoted
name in the wrong case (`"win1252"` is undefined — the engine matches
a quoted name as written), a zero or over-long width (the engine's
-842 / -204 name the number, this refusal is generic), and the two
places the BLR compiler would have to carry a charset'd cast
descriptor: a PSQL body and a VIEW body. An undefined character set
NAME answers the engine's own -204 vector, `CHARACTER SET
"PUBLIC"."NOSUCH" is not defined`.

Recorded beside it, found while gating and NOT this slice's: isql's
`CONNECT '<host>/<port>:<db>' USER 'SYSDBA' PASSWORD '...'` is rejected
by this server's auth. The client passes the login through **with its
quotes** (`'SYSDBA'`), the engine dequotes it and this server's identity
check is exact — so the gate reaches a UTF8 attachment through
`isql -ch UTF8` instead. Every gate that connects the ordinary way (the
connection string as isql's argument) is unaffected, which is why this
went unseen.

**BLOB OPERANDS IN EXPRESSIONS — DONE 2026-08-26
(`serve-real-blobexpr` 26).** A blob column was an operand of nothing:
every predicate and every text function over one refused, which is a
large part of what people actually do with a text blob. It is a TEXT
OPERAND now — the engine filters the blob to a string and runs the
ordinary text law over it, and so does this server
(`Expr::BlobText`, which carries the column's own CHARACTER SET so a
WIN1252 or NONE blob's high bytes survive the read):

* the comparison family (`=`, `<>`, ordering, `BETWEEN`, `IN`), `LIKE`
  with an `ESCAPE`, `STARTING WITH`, `SIMILAR TO`, a blob against
  another blob, and a blob operand inside a JOIN's `ON` or a `CASE`
  condition — all by CONTENT, which is what the engine compares.
* the LENGTHS answer a **BIGINT** over a blob where they answer an
  INTEGER over a string (`CHAR_LENGTH(<blob>)` describes INT64).
* **a blob operand makes the whole expression a BLOB** — concatenation,
  `UPPER`/`LOWER`/`TRIM`/`SUBSTRING`/`LEFT`/`RIGHT`/`REPLACE`/`LPAD`,
  and a conditional with a blob branch. The result's text type is the
  operands' joined one, the FIRST real charset winning (`S || B` is
  UTF8 from S, `W || B` WIN1252 from W, `B || W` UTF8 from B), and ONE
  binary blob operand makes the whole result binary with no charset at
  all. The value is MINTED as a temp blob through the LIST path
  (`Expr::BlobOf`); the id is this server's own, the content is the
  engine's.
* `ORDER BY` / `GROUP BY` / `DISTINCT` over a blob key the **BLOB ID**,
  not the content — four rows spelling `zzz, aaa, zzz, mmm` come out in
  ID order and group into FOUR groups (measured). Both servers answer
  that, which the gate pins: a server that keyed the content would
  answer `2,4,1,3` and three groups.

**And a pre-existing DDL bug fell out of it: fire-crab ignored the
database's DEFAULT CHARACTER SET.** In a `DEFAULT CHARACTER SET UTF8`
database a plain `VARCHAR(10)` is charset 4 and FORTY bytes to the
engine; this server wrote charset 0 and ten. Every text and text-blob
column it created in such a database had the wrong charset in its
catalog row, the wrong byte length in its format, and a describe
(`charset: 0 SYSTEM.NONE`) the engine disagreed with column by column
— and a non-ASCII literal stored into one landed as mangled carrier
bytes. `apply_db_charset` now resolves the default at CREATE TABLE,
CREATE DOMAIN, ALTER TABLE ADD, ALTER COLUMN TYPE and ALTER DOMAIN
TYPE, exactly where the engine resolves it; an explicit `CHARACTER SET
NONE` still means NONE (the parser now keeps "declared none" and "NONE"
apart). Verified end to end: the engine reads an fc-created UTF8 table
with the same describe, the same OCTET_LENGTH/CHAR_LENGTH and the same
values, `gfix -v -full` clean.

Boundaries, recorded and refused: `MIN`/`MAX` over a blob (the engine
compares CONTENT and answers the winning row's stored id), a blob in
arithmetic, a blob-valued SCALAR SUBQUERY, a blob-valued expression
inside a DERIVED TABLE, and — the next slice — every blob VALUE in
DML: `INSERT ... SELECT` of a blob column, an `UPDATE` whose `SET`
reads one, and `CAST(<v> AS BLOB)`.

**BLOB VALUES IN DML AND `CAST(<v> AS BLOB)` — DONE 2026-08-26
(`serve-real-blobexpr` 30).** The other half of the slice above: a blob
column could be READ by an expression and never WRITTEN by one. Now a
blob column takes ANY value as a blob, under the engine's own two laws.
An expression that answered another blob is COPIED, never shared
(`BLB_move`, blb.cpp:1183 — aliasing would leave two versions pointing
at one id, and the collector frees a collected version's blobs BY ID),
and the DESTINATION's subtype and character set decide the new blob's
(blb.cpp:1262), not the source's. A SCALAR stores its RENDERING (probed:
42 lands `'42'`, 3.14 `'3.14'`, a DATE its ISO day, a TIMESTAMP its full
`…10:20:30.0000`, TRUE the word in capitals) — the same spellings a CAST
to text produces, gathered in `wireparam_text`. `CAST(<v> AS BLOB
[SUB_TYPE TEXT|BINARY|<n>] [CHARACTER SET <cs>] [SEGMENT SIZE <n>])`
names the blob's own type, a `CHARACTER SET` clause promoting the
spelling to TEXT exactly as in a column declaration, `SEGMENT SIZE`
deciding nothing, a user sub_type refusing (`isc_nofilter`). The value
is minted through the LIST path, so a statement that MINTS AND STORES
inside ONE op — `INSERT … SELECT <blob expression>` — needed
`flush_minted_blobs`: the mint context is drained at the TOP of the next
op, too late for a store in the middle of this one. **A charset bug fell
out beside it:** `store_blob_param` hard-coded a text blob's charset to
UTF8, so a blob copied or created into a WIN1252 or NONE column was
labelled UTF8 in its header and read back through the wrong table.
Boundaries recorded: a blob-valued SCALAR SUBQUERY as the source (the
pre-existing scalar-subquery gap) and `RETURNING <expression>` (a
general RETURNING limit — a bare `RETURNING B` answers).

**A SUBQUERY AS A VALUE IN DML — AND THE STATEMENT CACHE'S FIRST LAW —
DONE 2026-08-26 (`serve-real-subqval` 33).** The read side has answered
subqueries for many increments; the WRITE side refused every one, so the
value a statement stored could never be looked up. `INSERT … VALUES (…,
(SELECT …))` and `UPDATE … SET <col> = (SELECT …)` serve now:

* an UNCORRELATED subquery is a CONSTANT for the statement — answered
  once by `eval_subquery` and folded back in as the literal it computed
  (`fold_dml_subqueries`), which hands the whole existing value surface
  to it for free: the item alone, arithmetic around it, a CAST, a
  COALESCE, several in one list, a source that is a VIEW or a DERIVED
  TABLE, the `FIRST 1 … ORDER BY` idiom, the TARGET table read at its
  own starting state, and a MERGE's `UPDATE SET`.
* an UPDATE's SET may CORRELATE to the target row (`SET N = (SELECT
  SUM(V) FROM P WHERE P.ID = D.ID)`): the same LOOKUP TABLE a correlated
  select-list item builds, keyed by the outer column, with the engine's
  absent-key law (COUNT 0, every other function NULL).
* the singleton laws travel with it: NO ROW is NULL (not an empty
  result, not a skipped assignment) and MORE THAN ONE ROW is
  `isc_sing_select_err` 21000. A raise is carried BESIDE the folded text
  and surfaced only once the rest of the statement has parsed — folding
  happens before the SET list is read, and a statement this server
  cannot parse must keep its generic syntax refusal (`SET N = (SELECT …)
  FROM D` is the engine's -104, not a runtime raise).
* the fold spells every type it can spell exactly: INTEGER, NUMERIC,
  VARCHAR (quotes doubled), DATE/TIME/TIMESTAMP as typed literals, and
  DOUBLE as a cast over its SHORTEST ROUND-TRIPPING text (the engine's
  16-digit display does not always name the same f64).

**A CLAUSE-SPLIT BUG fell out of it:** the statement's own `WHERE` is
the one at PAREN DEPTH ZERO. A SET value's subquery carries a WHERE of
its own, and `find_word` took the first one — cutting the SET list in
half, so the assignment lost its closing paren and the whole statement
refused (`find_word_depth0` now, as every other clause split already
used).

**AND THE REAL FIND: A FOLDED SUBQUERY IS NOT A PLAN THE STATEMENT CACHE
MAY KEEP** — a PRE-EXISTING silent wrong answer in the READ path, older
than this slice. The cache is keyed by (schema, text), so everything a
plan holds must be derivable from those two; a folded subquery is a
value read from ROWS. Measured before the fix:

```sql
SELECT COUNT(*) FROM D WHERE ID IN (SELECT ID FROM P);   -- 1
INSERT INTO P VALUES (2, 200); COMMIT;
SELECT COUNT(*) FROM D WHERE ID IN (SELECT ID FROM P);   -- 1; the engine says 2
```

The outer rows were read fresh every time and only the folded inner list
was frozen, so the query looked alive while answering from the first
preparation. The same held for a select-list subquery
(`SELECT (SELECT MAX(V) FROM P)` answered 100 for ever) and would have
held for every DML fold this slice adds. Fixed by a thread-local
`PLAN_READ_ROWS`, set inside `eval_subquery` and `build_correlated_lookup`
— the two places planning reads rows — cleared before each top-level
plan and read after it by the new `stmc::DbStatements::plan_if`, which
builds the plan and then declines to KEEP it. A FLAG rather than a scan
of the text, because a VIEW BODY can carry the subquery a statement's
own text does not show (gated). The stmc module's own question — *what
did the planner READ that the schema does not decide?* — now has a
mechanism behind it. The unfiltered `COUNT(*)`/`MAX` folds it warned
about were already per-execute; re-measured clean.

Boundaries recorded: a CORRELATED subquery inside a larger expression
(the lookup would have to be spliced into a tree the expression parser
has already refused), a correlated subquery in an INSERT's value list
(no outer row to name), a correlated BARE COLUMN whose source holds two
rows for one key (the lookup is built for every key at prepare, where
the engine raises only if that key is reached), a `?` inside a subquery,
and a blob-valued subquery (the blob boundary above). And one that is
inherent to folding at all: the fold reads at PREPARE, where the engine
reads at EXECUTE — a client that prepares under one transaction and
executes under another (isql does exactly that) takes the prepare-time
visibility. The plan is no longer KEPT, so every execution re-prepares
and the window is one op wide rather than for ever; closing it entirely
means executing the subquery as a row source, which is the nested
`blr_rse` the engine compiles.

**`RETURNING <EXPRESSION>` — DONE 2026-08-26
(`serve-real-returningexpr` 24).** The other direction of a DML value:
the RETURNING list took plain column references only, so `RETURNING ID +
1`, `RETURNING UPPER(S) AS U`, `RETURNING CAST(B AS VARCHAR(30))` and
even `RETURNING 1` refused. Any value expression serves now, built by
the SELECT LIST'S OWN `build_expr_col`, so the type, the width, the
charset and the un-aliased name are decided in one place and cannot
drift from the projection's: `MULTIPLY`, `ADD`, `CONCATENATION`, `CAST`,
`CASE`, `""` for a unary minus. Every family measured against the engine
over the written row — arithmetic, concatenation, CAST, COALESCE, CASE,
temporal arithmetic, the text functions, a BLOB-valued expression
(minted through the LIST path, as in a projection), a constant, a
literal keyword, a qualified column — for INSERT, UPDATE (the NEW row),
DELETE (the row as it WAS) and UPDATE OR INSERT, over the cursor path
AND the type-8 singleton path a driver takes for `INSERT ... RETURNING`.

The spelled/expression split is made on the TEXT and not by trying the
column route first: a quoted `RETURNING "id"` must stay `Column unknown`
(the engine's exact compare), where an expression resolver — which folds
case like every other resolver here — would have answered it. That
decision needed the select list's own literal rules with it: an unquoted
identifier CANNOT START WITH A DIGIT (`RETURNING 1` had been looked up
as a column named "1" and refused, while `'lit'` always worked because
it is not spelled like a name), and `NULL`/`TRUE`/`FALSE`/`UNKNOWN` and
the clock keywords look exactly like names and are values.

TWO PRE-EXISTING DESCRIBE DIVERGENCES fell out of it, both measured:
**every RETURNING column is nullable**, even one the table declares NOT
NULL (`RETURNING ID` over `ID INTEGER NOT NULL` describes Nullable where
the same column in a SELECT does not) — this server passed the column's
own flag through; and **a bare NULL literal describes as CHAR(1)
CHARACTER SET NONE**, in a select list as much as in a RETURNING, where
this server announced INT64. The second is a describe-only fix:
`Expr::type_of` still answers Int for a NULL, which is the arithmetic
default an all-NULL conditional leans on.

Boundaries recorded: an expression over a COMPUTED column (these rows
are decoded from the STORED image, where a computed column's descriptor
sits over the null flags — the bare column already refused for that
reason, and `RETURNING CC + 0` now refuses with it), an aggregate, a
subquery and a parameter. *(A MERGE's RETURNING was on that list until
the slice below took it.)*

**A `?` INSIDE A DML VALUE EXPRESSION — DONE 2026-08-26
(`serve-real-dmlparamexpr` 25).** A parameter standing ALONE has always
worked; one inside an expression refused — `INSERT ... VALUES (? + 1)`,
`UPDATE ... SET N = ? * 2`, `SET S = 'x' || ?`, `SET N = CAST(? AS
INTEGER)` — which is most of what a prepared statement does with
arithmetic. The feature is really the TYPE the parameter is described
with, and the engine's rule is not the obvious one. Read off its own
input SQLDA (`SET SQLDA_DISPLAY ON` prints the input message even for a
statement isql cannot then execute):

* **the DESTINATION COLUMN types the parameter**, whatever operators
  stand between them: `SET NM = ? * 2` over a `NUMERIC(9,2)` describes
  the parameter as that NUMERIC (LONG scale −2 subtype 1), NOT as the
  literal 2's INTEGER; `SET D = ? + 1` is a DATE; `SET S = SUBSTRING(?
  FROM 1 FOR 2)` is S's VARCHAR(20); `-?`, `(? + 1) * 2 - 3` and a CASE
  branch take it too. That is `PASS1_set_parameter_type` pushing the
  assignment's destination down the tree.
* a **CAST** types its own operand instead (`CAST(? AS VARCHAR(5))` is
  VARYING(5)), and **COALESCE** types its parameter from its OTHER
  ARGUMENTS and only from them — `SET NM = COALESCE(?, 0)` is a plain
  INTEGER where `SET NM = CASE WHEN … THEN ? ELSE 0 END` is NM's
  NUMERIC (CoalesceNode makes the descriptor itself; CaseNode and
  ValueIfNode pass down what they were given). Measured both ways.
* the slots are numbered in SOURCE order: the SET list left to right,
  then the WHERE.

`resolve_dest_param_expr` is that law; `InsVal::ParamExpr` carries the
numbered raw tree until the target column is known (a VALUES list is
parsed before the target list is resolved); `Plan::Insert.param_exprs`
binds and evaluates at execute, and an UPDATE's `SetVal::Expr` is bound
once before the row loop (a `Cow`, borrowed when parameterless). Both
sides re-check that the BOUND tree still types, because a `?` types None
at prepare and the eval fallthrough would otherwise store a silent NULL.

**A PRE-EXISTING DESCRIBE DIVERGENCE fell out of it: A PARAMETER
INHERITS THE NULLABILITY OF THE COLUMN THAT TYPES IT.** `WHERE ID = ?`
over an `ID INTEGER NOT NULL` announces the parameter NOT NULL; `SET V =
?` over a nullable column announces it nullable; a parameter typed by a
CAST or a COALESCE — by no column at all — is nullable. This server
announced EVERY parameter not-nullable, in both describe shapes
(`append_bind_section` and `answer_prepare`'s bind vars), which was
right by accident wherever the column happened to be NOT NULL and wrong
everywhere else. The engine derives it from the metadata — `DSC_nullable`
is explicitly "not stored" (dsc_pub.h:39) — so this server does the same
where the formats are BUILT: `stamp_param_nullability` writes the
catalog's NOT NULL onto the descriptors in the metadata cache
(`relation_meta`, `select_formats`, and the DELETE planner's own read),
and every consumer that types a `?` by copying a column's descriptor —
the predicate resolver, the SET list, the value list — inherits it. A
gate found the first draft of this (parameters made nullable
unconditionally): `serve-real-notnulldesc` pins exactly the NOT NULL
comparison. **And a second, smaller
one:** `raw_has_param` had no CASE arm, so `CASE WHEN … THEN ? END`
looked parameterless, took the ordinary resolver and refused — while
IIF, the same shape, answered. The asymmetry is what found it.

Boundaries recorded: a parameter in a CASE/IIF CONDITION (typed from the
other side of the compare — a different rule and its own slice), a
COALESCE whose arguments are ALL parameters (the engine's −804), a
parameter expression into a BLOB column, and a bare `?` in a select list
(−804 on the engine too, generic here).

**THE MERGE TAILS: PARAMETERS AND RETURNING EXPRESSIONS — DONE
2026-08-26 (`serve-real-mergeparam` 26).** Section D's executor has been
wired since the MERGE slice; these were its two recorded refusals.

A MERGE executes by DESUGARING each source row into ordinary
INSERT/UPDATE/DELETE statements built as TEXT, so a `?` could not ride
through as a slot — by the time the per-row statement is planned its
position in the original text is gone, and `plan_merge` refused the
moment the statement carried one. Each `?` becomes a numbered
`FC$P<n>` marker at prepare instead (text order, which is the order the
engine's input SQLDA is in), typed there, and written as its bound
literal at execute by `merge_subst`, beside the source row's own values.
The typing follows the slice above: a marker in a SET or an INSERT value
list takes its DESTINATION COLUMN's descriptor, one compared in the ON
clause or a branch's AND takes the column it is compared with, and
anything else — a parameter in the USING query, one compared with the
SOURCE, one standing outside a comparison — keeps the refusal.

`RETURNING <expression>` over a MERGE now goes through the select
list's own builder like every other RETURNING, with the TWO-CONTEXT rule
kept: the target's alias (or `NEW.`) qualifies a column and is stripped
before resolution, a BARE name the SOURCE also carries stays the
engine's 42702 rather than a silent pick, and a name the writer
qualified with the target is exempt from that check. A source column
inside the expression refuses — this path reads the target's
after-image, and the source is not in it.

Found while gating it: the INSERT ... SELECT re-render refused a DOUBLE
value ("a selected value cannot be written as a literal"), which a
MERGE branch carrying a double-bound parameter reaches — it renders
through `dml_subq_literal` now, the cast-over-shortest-round-trip form.

Still absent in D: `RETURNING OLD.x` and the source's columns in
RETURNING, `OVERRIDING`, `PLAN` / `ORDER BY`, the failed statement's
partial `Records affected` (the engine reports the rows it moved before
the raise; fc reports 0), and a trigger-bearing target (refused by the
per-row planners at execute, not at prepare).

**AN ICU COLLATION DECIDES THE ANSWER, AND THIS SERVER REFUSES RATHER
THAN ANSWERING BY BYTES — DONE 2026-08-27 (`serve-real-icucoll` 25).**
The roadmap's own line "collation-aware ordering (server keys binary)"
understated it: this was a SILENT WRONG-ANSWER class, and a broad one.
Firebird's `UNICODE`, `UNICODE_CI` and the language-specific collations
are ICU-backed — their order is the Unicode Collation Algorithm's, where
`'apple' < 'Ápple' < 'banana'`, and under CI `'apple' = 'APPLE'`. This
server compared and ordered the BYTES. Measured over one six-row
fixture: `ORDER BY <ci col>` answered 5,2,1,6,3,4 where the engine
answers 1,5,4,6,2,3; `WHERE CI = 'APPLE'` found ONE row where the engine
finds two; `GROUP BY CI` made SIX groups where the engine makes four;
`DISTINCT`, `MIN`/`MAX`, a join keyed on such a column and an
index-driven range were all wrong the same way.

There is no honest way to answer them here: the UCA's order is a table
this server does not have (and these crates carry no dependencies), so
every site where a collation decides now asks
`coll::keyable_ttype` — true for a charset's DEFAULT collation (byte
order: `UCS_BASIC` for UTF8) and for `PXW_INTL`, the one real collation
converted — and REFUSES when the answer is false. The sites: ORDER BY (a
column key and an EXPRESSION key, since the collation travels into the
result), the whole comparison family through `param_or_typed_term`, a
column-vs-column comparison through `resolve_expr_term` (which is what a
JOIN's ON is), GROUP BY in all three group planners, DISTINCT and a
distinct UNION (over the projection's own ttype — a text ProjCol's
`sub_type` IS the ttype), and MIN/MAX/COUNT DISTINCT.

**MIN/MAX refuses over `PXW_INTL` too**, which is not an ICU collation:
the fold ([compute_group]) compares plain values with no collation in
reach, and it answered `MIN(W)` = 'APPLE' where the engine answers
'apple'. Keying the fold is a slice of its own.

What is untouched: SELECTING such a column (bytes in, bytes out —
nothing is decided), its LENGTHS and CASTS, the whole default-collation
surface, and every PXW_INTL comparison and ordering, which keys as
before.

**...AND THEN IT ANSWERED THEM: THE ICU COLLATIONS, FROM THE UCA ITSELF
— DONE 2026-08-27 (`serve-real-icucoll` 25 refusals → 61 checks).** The
refusal above was honest but small; the table it lacked is a published
one, and there is a Rust implementation of it. **`icu_collator` is now
the ONE dependency in this workspace** (in `fire-crab-ods`; the release
binary grew 8.53 MB → 9.91 MB, all of it baked UCA data). It buys a
thing no amount of conversion can: the Unicode Collation Algorithm's own
order.

TWO LAWS, probed off the live engine over `apple/APPLE/Ápple/ápple` in
three columns:

1. **A SORT IS FULL STRENGTH whatever the column's collation is.**
   `ORDER BY <UNICODE>`, `ORDER BY <UNICODE_CI>` and
   `ORDER BY <UNICODE_CI_AI>` all answered `1 2 4 3`. A CI collation
   makes an EQUALITY loose; it does not make a SORT unstable. So an
   ordering key rides as `coll::TTYPE_UTF8_UNICODE` — not a fudge, a
   statement of that law.
2. **EQUALITY AND GROUPING READ THE COLLATION'S OWN STRENGTH.**
   `= 'APPLE'` took one row under UNICODE, two under UNICODE_CI, four
   under UNICODE_CI_AI.

Both are the same sort key cut at a different level, so one builder
answers both: `coll::icu_key(text, strength)` over a cached
`CollatorBorrowed` per strength, keyed through the existing
`Expr::CollKey` carrier (UCA key bytes are never zero, so a `0x00`
terminator makes a PREFIX key compare right and keeps the key out of
reach of the blank-stripping every text compare here does). Trailing
blanks are the pad and are not keyed (`texttype_pad_option`); a LEADING
blank is a real collation element (`' apple' < 'app le'`, measured —
the root table's non-ignorable variable weighting, which is ICU4X's
default).

WHAT NOW ANSWERS: ORDER BY (a column key, an ORDINAL, an EXPRESSION key,
DESC, NULLS FIRST/LAST, inside a derived table, under FIRST/SKIP and
under a JOIN), the whole comparison family (`=`, `<>`, the four ranges,
BETWEEN, an IN list, NOT IN, inside a CASE, through a derived table's
own name), the SEMI-JOIN rewrites (`IN (SELECT …)`, `= ANY`, correlated
`EXISTS`/`NOT EXISTS`, `NOT IN (SELECT …)`), a scalar subquery on the
other side, and UPDATE/DELETE `WHERE`.

TWO SILENT WRONG ANSWERS FELL OUT ON THE WAY, both pre-existing:

* **A semi-join's values travel as HASH KEYS** (`Rhs::StrKey`, the
  strict grammar's spelling) and that arm compared BYTES — so
  `CI IN (SELECT …)` answered ONE row where the literal
  `CI IN ('APPLE')` beside it answered two. The key arm now takes the
  collation like the literal one.
* **The BLR executor compares values, not descriptors**, and text values
  do not carry their collation — so a procedure body's
  `SELECT COUNT(*) … WHERE CI = 'APPLE'` answered 1 where the same
  statement typed at the prompt answered 2. `blr_reads_collated_relation`
  now stands the fast path aside for ANY non-default collation,
  PXW_INTL included, and the SOURCE interpreter re-plans the statement
  through the descriptor-aware planner. **The question is asked the way
  round that PROVES an answer**: the COLLATED RELATION SET is read from
  the catalog first (one walk per generation, memoised), and an empty
  set — every database in this suite but two — answers without decoding
  a byte. The first draft asked it of the BLR's own relation names and
  treated anything it could not resolve as collated; the sweep caught
  it refusing every recursive CTE in a procedure body (the recursion's
  name is no relation) and, through the decode-failure arm, every
  WINDOW one (`serve-real-exeproc`, `serve-real-funcbody`). Only a
  database that HAS a collation now pays for an undecodable body.

WHAT STILL REFUSES, each for a measured reason: `LIKE` / `STARTING WITH`
/ `CONTAINING` / `SIMILAR TO` (they match through the collation's own
MATCHER prefix by prefix, and a UCA key is not built prefix-wise — the
key of 'app' is no prefix of the key of 'apple'; measured,
`CI STARTING WITH 'APP'` takes 'apple' too); `GROUP BY` / `DISTINCT` /
a distinct UNION (not the COUNT — the surviving SPELLING, which follows
the engine's own sort's internal order and no rule this server could
reproduce. Measured three ways: over {apple, APPLE} `GROUP BY CI` kept
whichever was inserted SECOND — 'APPLE' one way round, 'apple' the
other; over four spellings {aPPle, APPLE, apple, ApPlE} it kept 'apple',
which is neither the first nor the last record, and stayed on 'apple'
after that row was deleted and re-inserted LAST; and `SELECT DISTINCT`
answers a different survivor from `GROUP BY` over the same rows);
`MIN`/`MAX`/`COUNT(DISTINCT)` (the fold, as before, PXW included); an
EXPRESSION over such a column inside a comparison (`UPPER(ci) =` — the
collation travels into a result there is no key for, so `cmp_sides`
refuses it rather than comparing bytes, which is what it silently did
before); a JOIN keyed on one; two DIFFERENT collations meeting in one
comparison; and an explicit `COLLATE` clause.

**...AND THEN THE FOLD AND THE GROUP KEYED IT TOO — DONE 2026-08-27
(`serve-real-icucoll` 61 → 74 checks).** Three of the refusals above
turned out to be two different questions wearing one coat, and only one
of them is unanswerable.

**THE FOLD.** `MIN`/`MAX` pick by the collation's ORDER and
`COUNT(DISTINCT)` buckets by its EQUALITY — and both read the
collation's OWN strength, not the full-strength order a SORT uses.
Measured: `MIN(<UNICODE_CI col>)` over {APPLE, apple} answered whichever
row came FIRST, both ways round — so to the fold the two are EQUAL and
`compute_group`'s keep-unless-strictly-less rule decides, where a sort
would have answered 'apple' either way. New `AggSrc::CollField(fid,
ttype)` carries the ttype into the fold (`agg_field_src` builds it at
all four planner sites, `agg_src_fid` reads through it), and a new
`fold_cmp` runs `coll_value_cmp` — PXW_INTL through its converted key
tables, the ICU family through `coll::icu_key`. **This closes the
PXW_INTL fold too**, which had answered `MIN(W)` = 'APPLE' where the
engine answers 'apple'. What still refuses is what has no key: a
tailored/narrow ICU collation, and an EXPRESSION source that READS a
collated column (`MIN(UPPER(ci))` carries the collation into a result
there is no key for — that one was a SILENT byte fold before, since the
old check looked only at `AggSrc::Field`).

**THE GROUP.** A collation that never calls two DIFFERENT strings equal
asks no "which spelling survives" question at all — so `UNICODE` (and
`PXW_INTL`, and every charset default) now GROUPs and DEDUPLICATEs,
while `UNICODE_CI`/`UNICODE_CI_AI` keep refusing for the reason above.
`coll_groupable_ttype` draws that line; the octets-only masks became
TTYPE masks (`coll_key_mask`, `coll_cols`, `rows_equal`,
`distinct_rows`, `group_rows`), so a group's buckets AND its ORDER come
from the collation.

TWO MORE PRE-EXISTING DEFECTS FELL OUT:

* **`coll_key_mask` read the PROJECTION**, matching `ProjCol::field_id`
  against a key's field id — but in a GROUPED plan a ProjCol's
  `field_id` is its OUTPUT SLOT, not a record field. `GROUP BY <col>`
  looked up key field 1 among output slots 0 and 1 and took slot 1, the
  COUNT, whose ttype is 0. It reads the RECORD descriptors now, and
  `Plan::JoinGroup` carries the mask from PLAN time because execute has
  the joined rows but not their descriptors.
* **A grouped ORDER BY was parsed with NO descriptors** (`&[]`), so a
  key over a collated group key came back `coll: 0` and sorted the
  groups by BYTES — `GROUP BY <PXW col> ORDER BY 1` answered byte order
  where the engine answers 'ae', 'ä', 'apple', 'APPLE', … The new
  `stamp_group_order_coll` stamps those keys from the group row's SLOT
  descriptors, in all three grouped planners.

**...AND THE COLLATION A STATEMENT WRITES FOR ITSELF — DONE 2026-08-27
(`serve-real-collclause` 30).** `COLLATE <name>` on an OPERAND, which is
what lets a statement ask a COLLATED column for the BYTE answer
(`CI COLLATE UCS_BASIC`) and an UNCOLLATED one for a collation's — the
half of the collation story that is not in the DDL.

Two grammars needed it, because a `COLLATE` can be written on either
side of the same statement: the TOKEN one (predicates) and the
CHARACTER one (the select list and the DML value surface). In both it is
a POSTFIX ON THE ATOM, the tightest binding SQL gives it — `A || B
COLLATE X` collates B. It resolves to `Expr::Collate(inner, ttype)`, an
IDENTITY at eval (a projected `S COLLATE X` answers S) that the
deciding sites read: `cmp_sides` wraps BOTH sides in `Expr::CollKey` of
that ttype, an ORDER key takes it instead of the operand's own
(`OrderKey::coll_explicit` keeps a grouped re-stamp off it), and
`agg_expr_src` folds `MIN/MAX/COUNT(DISTINCT)(<col> COLLATE <name>)`
into `AggSrc::CollField`. `UCS_BASIC` and a charset's own name resolve
to the ttype with collation byte ZERO - both order by the codepoint,
which over every charset here IS the stored byte order - so every site
downstream reads them as "no collation decides this".

DESCRIBE: the engine builds a CastNode for the clause, so the column is
named **CAST** (name and alias) and describes as its OPERAND — same
type, same width, same charset (`strip_collate_target` reads the
aggregate describe through it, which also stopped `MIN(S COLLATE X)`
inheriting the pre-existing "MIN over a TEXT expression" refusal).

THREE ERROR VECTORS, byte for byte: a name that is no collation of the
operand's charset is -204 / SQLSTATE 22021 `COLLATION "PUBLIC"."NOSUCH"
for CHARACTER SET "SYSTEM"."UTF8" is not defined`; a REAL collation of
ANOTHER charset answers the same with `"SYSTEM"` as its schema (a
collation belongs to ONE charset, and the name IS a built-in), told
apart by reading `RDB$COLLATIONS` (new `ods::ddl::collation_lookup`,
reached through the new `PLAN_IMAGE` thread-local — the same shape
`USER_FNS` uses, since the resolver is far from any `db`); and a
`COLLATE` on a non-TEXT operand is -204 / HY004 `Data type unknown` +
`Invalid use of CHARACTER SET or COLLATE`, which the engine answers
BEFORE it ever looks the name up.

REFUSED: `GROUP BY` / `DISTINCT` under a written collation. Grouping
keys off the RECORD descriptors here and a synthetic expression slot
carries no ttype, so the buckets AND the group order would be the
bytes' (measured: four groups where the engine makes three). A
statement-wide `EXPLICIT_COLL_SEEN` flag refuses them — a FLAG rather
than a walk of the resolved tree, because a walk that misses one
container variant misses a wrong answer and this cannot; the cost is
over-refusal (a `COLLATE` in the WHERE of a grouped query refuses it
too), and a GLOBAL aggregate is exempt since it buckets nothing. Also
refused: a collation with no table here, and a `COLLATE` on a literal
beside a collated column (the engine has a precedence rule between
them — measured that a column's CI beats a literal's explicit
`COLLATE UNICODE` — but not one this server has pinned).

**...AND THE LAST COLLATION REFUSAL: TWO COLLATIONS IN ONE COMPARISON —
DONE 2026-08-27 (`serve-real-icucoll` 74 → 77).** A JOIN keyed on a
collated column, and a column-vs-column comparison generally, were the
last shapes refused outright. **The engine does not raise on mixed
collations: it compares under `MAX(t1, t2)`, the numerically larger
TTYPE** (`INTL_compare`, `src/jrd/intl.cpp:380`, marked "YYY" in the
engine's own source with the comment that SQL II would have wanted the
collation written explicitly). A ttype is `(collation << 8) | charset`,
so within one character set that is the higher COLLATION id — read off
the source AFTER six probes had suggested the same shape, which is the
right order to trust them in.

`cmp_sides` now keys both sides at `MAX(t1, t2)` when the two bare
columns disagree, and the same rule already covered the one-sided case
(a literal or a plain column adopts the collated one's). ACROSS two
character sets the engine transliterates the other side first, which
this comparison does not do — refused. `resolve_expr_term`'s early
guard, which had refused any comparison reading a collated column
before `cmp_sides` ever saw it, now steps aside for a COMPARISON and
keeps refusing for `LIKE`/`STARTING WITH`/`CONTAINING`/`SIMILAR TO`,
which match through the collation's own matcher. And the fallback guard
that catches an EXPRESSION over a collated column widened from ICU-only
to ANY declared collation: `PXW_INTL` expands `ä` to `ae`, so its
compare is not the bytes' either, and `UPPER(<PXW col>) = 'x'` had been
answering by bytes.

**...AND THE PATTERN FAMILY, WHICH READS A DIFFERENT FORM ENTIRELY —
DONE 2026-08-27 (`serve-real-icucoll` 77 → 88).** `LIKE` and
`STARTING WITH` were refused on the grounds that a UCA sort key is not
built prefix-wise. True, and beside the point: **the engine does not
match patterns with the sort key at all.** It converts BOTH the value
and the pattern to the collation's CANONICAL FORM and runs the ordinary
matcher over that (`CanonicalConverter`, jrd/intl_classes.h:112 →
`TextType::canonical`), and for the ICU family that conversion is six
lines (`Utf16Collation::normalize`, common/unicode_util.cpp:2077):

* `UNICODE` has neither attribute, so **the canonical form IS the
  string** — its `LIKE` is the plain code-point match every uncollated
  column already got, and lifting the refusal was the whole change;
* `UNICODE_CI` UPPER-CASES (ICU's `u_strToUpper` at the root locale =
  Unicode's full uppercase, so `ß` becomes `SS`);
* `UNICODE_CI_AI` upper-cases and then transliterates by a rule the
  engine spells out in full (unicode_util.cpp:326):
  `::NFD; ::[:Nonspacing Mark:] Remove; ::NFC;` plus `Ð>D Ø>O Ŀ>L Ł>L`,
  the four letters whose accent is not a combining mark (CORE-4136).

New `coll::icu_canonical` implements exactly that — `icu_normalizer`
and `icu_properties` became direct dependencies for the NFD/NFC and the
Nonspacing-Mark test, both already in the graph under `icu_collator`,
so nothing new was downloaded or linked. New `Expr::CollCanon(inner,
ttype)` canonicalises the VALUE per row while the PATTERN is
canonicalised ONCE at prepare, which is what makes this cheap; the
ESCAPE character is canonicalised too, and one that canonicalises to
more than a single character (an upper-cased `ß`) refuses. Both the
bare form (`ci LIKE 'A%'`) and the written one (`s COLLATE UNICODE_CI
LIKE 'A%'`) take it.

STILL REFUSED: a `?` pattern (no value at prepare, and canonicalising
at bind is its own slice), `SIMILAR TO` (its pattern is a grammar, and
canonicalising a character class is not the same operation), and
`CONTAINING` — which is not a collation limit at all: this server has
never implemented it.

**...AND `CONTAINING`, WHICH THIS SERVER HAD NEVER IMPLEMENTED AT ALL —
DONE 2026-08-27 (`serve-real-containing` 28, new).** The collation
chunks kept recording it as a refusal beside `LIKE`; reading the engine
showed it is not a collation limit at all — `CONTAINING` appeared in
one keyword list here and nowhere else, for ANY character set.

THE LAW, from the matcher's own type: `ContainsMatcher<UCHAR,
UpcaseConverter<>>` for a direct collation (Collation.cpp:1075) and
`CanonicalConverter<UpcaseConverter<>>` for one with a canonical form
(:527). So **CONTAINING upper-cases FIRST — on every character set,
whatever the column's collation — then canonicalises, then searches for
a substring**, which is why it is the one predicate that folds case
everywhere. Its sibling `STARTING WITH` takes `NullStrConverter` for a
direct collation (no conversion at all: case-SENSITIVE) and the
canonical converter WITHOUT the upcase for the rest — the difference
the new gate exists to hold still.

Implemented as a DESUGAR onto the machinery the pattern chunk just
built: `x CONTAINING p` becomes
`CollCanon(x, ttype, upcase) LIKE '%' || escaped(upcase_canon(p)) || '%'
ESCAPE '\'`, with the pattern's own `%`, `_` and backslash escaped
first — CONTAINING has NO wildcards (measured: `S CONTAINING '%'` takes
only the row holding a literal per-cent). `Expr::CollCanon` gained the
upcase flag; new `upcase_cs` folds by the CHARACTER SET's own law
(OCTETS has none, a tabled single-byte set has its table, everything
else takes `intl::simple_case`).

Measured and pinned: an EMPTY pattern matches every non-NULL row; NULL
on either side is UNKNOWN negated or not (`Term::Never` both ways); an
INTEGER operand renders to its decimal text; a CHAR operand's padding
is irrelevant (a substring test, not a comparison); `NOT CONTAINING`
needed the keyword added to the two NOT-lookahead lists, since it lexes
as an Ident like STARTING and SIMILAR.

REFUSED: under `PXW_INTL` — a NARROW collation's canonical is its own
table, which this server has not converted, and upper-casing alone
would be a guess about what that table says; a `?` or binary pattern;
and CONTAINING (or STARTING WITH) as a boolean VALUE in the SELECT
list, which is a different grammar that knows only LIKE — a
pre-existing gap this predicate inherits rather than one it adds.

**...AND THE LAST THREE PREDICATES THAT WERE NOT ALSO VALUES — DONE
2026-08-27 (`serve-real-containing` 28 → 33).** In Firebird a predicate
is a BOOLEAN expression, usable anywhere a value is. This server has
TWO expression grammars — a TOKEN one for predicates and a CHARACTER
one for the select list and the DML value surface — and the character
one's condition parser knew only `LIKE`. So the same test answered in a
`WHERE` and refused in a `CASE`.

Probed which predicates could already be values: comparisons, `LIKE`,
`BETWEEN`, `IN`, `IS NULL`, `AND`/`OR`, `EXISTS` and `IS DISTINCT FROM`
all could; exactly three could not — `STARTING WITH`, `CONTAINING` and
`SIMILAR TO`. All three parse there now (each keyword lexes as an
Ident, so each is matched by text, and each takes a LITERAL pattern
only — the restriction `LIKE` already had on that side; `read_quoted`
declines a `?` or an expression pattern rather than mis-reading it).

`Cond2` gained `Starting` and `Similar`, mirroring `Term::ExprStarting`
and `Term::ExprSimilar` exactly — render, then the prefix test or the
prepare-compiled regex. `CONTAINING` needed no variant: it desugars to
`Cond2::Like` through the SAME `containing_term` the predicate path
uses, so the upcase-then-canonical rule has one implementation rather
than two. Each keeps its collation law as a value: `starting_canon`
canonicalises both sides under an ICU collation and refuses a collation
with no canonical form here, and `SIMILAR TO` refuses a collated
operand as it does in a `WHERE`.

**A BEFORE TRIGGER THAT DRAWS A GENERATOR — DONE 2026-08-28
(`serve-real-triggen` 15, new).** The classic Firebird auto-increment
(`IF (NEW.ID IS NULL) THEN NEW.ID = GEN_ID(G, 1)`) refused at CREATE
TRIGGER, and a table carrying such a trigger then refused every INSERT.
Both halves are done.

THE BLR: `ods::expr::Expr` gained `GenId { name, step }` and
`GenId2 { name }`, emitting `blr_gen_id` (a COUNTED name then the step
as an ordinary expression) and `blr_gen_id2` (the counted name ALONE).
`NEXT VALUE FOR` is a DIFFERENT VERB, not sugar for `GEN_ID(g, 1)`
(probed both ways), and it advances by the SEQUENCE'S OWN increment -
the `step.unwrap_or(incr)` rule the DML draw path already followed. The
engine reads back what this server writes, byte for byte.

THE RUN, and the reason it needed a design at all: a draw is a PAGE
WRITE, and a trigger fires inside a statement that is already holding
the working copy of that page - the comment at [trig_body_pure] has said
so since the trigger chunk. So the draw belongs to the CALLER, and the
body runs TWICE around it ([PsqlFrame::gen]): pass one RECORDS what it
would draw (every draw answering 0, over a COPY of the row), the caller
performs exactly those draws through the same `gen_bump_through_cache`
the statement's own `NEXT VALUE FOR` columns take, and pass two REPLAYS
the values in order. All six firing sites carry a drawer now.

Two passes are sound because a runnable body is otherwise PURE and both
start from the same row - and the design was chosen for the two cases
that decide it:

* a CONDITIONAL draw consumes nothing when its branch is skipped (an
  INSERT that supplies its own ID leaves the generator alone - measured
  against the engine, and the case a "pre-draw the values" design gets
  WRONG);
* a body that RAISES after drawing still consumes the value, because
  pass one's recorded draws are performed even though its outcome is
  discarded. The generator is not transactional, and that is what the
  engine does.

REFUSED, at prepare: a body whose CONTROL FLOW would read a value a draw
produced ([body_draw_decides_flow]), since pass one answers 0 for every
draw and the two passes could then take different branches. The check is
ORDER-AWARE - the classic trigger reads `NEW.ID` BEFORE anything assigns
it and passes, while `NEW.ID = GEN_ID(G,1); IF (NEW.ID > 100) ...`
refuses, and so does a loop whose condition reads what its own body
draws. Also refused: a draw in a DEFERRED (database-touching) body, and
a draw in a computed column or a CHECK.

GATE LESSON worth keeping: the ENGINE side of a `refuses` check RUNS the
statement, and **a generator draw is not transactional** - so a refused
trigger must not share a sequence with anything the gate compares, or
the two files drift by one and every later check DIFFs.

**THE ROW CONTEXTS OF `RETURNING` — DONE 2026-08-28
(`serve-real-returnold` 25, new).** This one started as a WRONG LAW in
this file's own source: "`NEW.`/`OLD.` do NOT exist in DSQL - they are
the PSQL trigger contexts, and the engine answers `Column unknown,
"NEW"."ID"`". That was probed on an INSERT, where it is true, and
generalised to all DML, where it is not.

**An UPDATE has TWO rows and names them**: `OLD.<col>` is the
before-image, `NEW.<col>` the after-image, and a BARE name is NEW
(measured: `RETURNING OLD.N, NEW.N, N` over `SET N = N + 1` answers
10, 11, 11). An INSERT and a DELETE have ONE row and no contexts at all
- there the engine's -206 stands.

The before-image is APPENDED to each returned row at `width` (the
`Affected` collector has carried `old_images` since the trigger chunk),
and an `OLD.` reference resolves there: as a plain column it becomes an
expression column over `Expr::Col(width + fid)` described exactly as the
column it names, and INSIDE an expression it is rewritten to a synthetic
`OLD$<col>` first (`rewrite_old_refs`, which walks the MASKED text so
`RETURNING 'OLD.N' AS L, OLD.N` keeps its string literal). `NEW.` comes
off entirely - that image is the row this route already read.

RECORDED BOUNDARIES: `INSERT`/`DELETE` with either qualifier refuse on
both servers, but the engine's is `-206 Column unknown "NEW"."ID"` and
this server has no -206 machinery, so the gate asserts BOTH REFUSE
without comparing vectors and says so in its own output. `RETURNING *`
is not implemented here at all, so `OLD.*` rides on it. And an ALIASED
DML TARGET (`UPDATE T t SET ...`) is refused by the planner outright -
the alias-as-qualifier support is wired (`dml_target_alias`) but
unreachable until that lands, and the gate pins the refusal so it cannot
be mistaken for this chunk's doing.

TWO CLEANUPS the ICU chunks recorded, done here: `stamp` and
`order_key_ttype` were the same rule written twice (unified — the
shared one also handles the negative-sentinel sub_type the other read
as a huge u16), and `coll_groupable_ttype`'s PXW_INTL clause was
already covered by `keyable_ttype`.

WHAT IS NOT CLAIMED: only the three ROOT collations over UTF8
(`UNICODE` = tertiary, `UNICODE_CI` = secondary, `UNICODE_CI_AI` =
primary, by their fixed built-in ids 2/3/4). A language-TAILORED
collation (`DE_DE`, `ES_ES_CI_AI`) is a tailoring of the root table and
would need its locale threaded through; an ICU collation over a NARROW
charset would need its byte-carrier values decoded to real text first.
Both keep refusing. An INDEX over a collated column is still not used
for retrieval (its itype is unknown to the index-op reader) and an
INSERT into a table carrying one still refuses — pre-existing, and the
reason the gate's fixture has no index.

**COMPILING A TEXT BODY — DONE 2026-08-29 (`serve-real-trigtext` 14 →
16).** The asymmetry the two slices before this one left: a body that
builds a string RAN here but could not be CREATED here, and creating
triggers is what a client does. `CREATE TRIGGER` refused every body
carrying a text literal, on a comment that had gone stale — "the
emitter's shape for `blr_literal blr_text` has never been held against
the engine's".

It has now. Probed out of engine-written TRIGGER BLR, not reasoned
about: a literal is `blr_literal blr_text2 <charset u16> <len u16>
<bytes>` with charset NONE (which is what `ods` had emitted all along,
gold-pinned from a CHECK), and a concatenation is `blr_concatenate`
(39) in prefix form. `Expr::Concat` carries it, `||` lexes and parses
BELOW `+ -` (the engine's precedence, so `'a' || 1 + 2` is `'a' || 3`),
and the gate compares fire-crab's stored bytes with the engine's for a
literal, a concatenation, and a three-way join over a CHAR column: all
byte-identical, and the ENGINE RUNS what this server compiled.

The column gate moved with it. A trigger body's references were INT-ONLY
— a plain SMALLINT/INTEGER/BIGINT — which is why a text body refused
even once the value shapes were right; `body_col_class` takes the
integer family and TEXT now, and still refuses a scaled numeric, a date
or a blob, so a body naming one is interpreted or refused rather than
stored under BLR nobody has held against the engine's.

Adding a variant to the shared `Expr` enum surfaced TWELVE exhaustive
matches across `ods` and `wire`, each answered with what a
CONCATENATION IS in that context rather than a copied default: it has no
integer rank (so the INT-ONLY surfaces keep refusing one), it IS text
whatever its operands are, it walks both sides like the arithmetic
nodes, and it evaluates with NULL-on-either-side-is-NULL.

AND THE DECLARATION WITH IT (same day, `serve-real-trigtext` 16 → 15
checks — one boundary became part of a comparison). A body may DECLARE
the variable it builds its message in: `DECLARE VARIABLE S VARCHAR(60)`
in a UTF8 database is `03 <id u16> 26 0400 F000` — `blr_varying2`,
charset 4, 240 = 60 x 4 BYTES — and a `CHAR(5)` is `03 <id u16> 0F 0400
1400`, `blr_text2` over 20. `DeclType` carries the two shapes where a
single dtype byte used to, the length is written in BYTES from the
database's default charset, and the engine's ONE dependency row on the
CHARACTER SET (object type 17, whatever the count of such variables) is
written beside it. Both compile byte-identically.

A parser trap worth keeping: `VARCHAR(60)` is ONE word to
`split_whitespace`, so the four-word arm that matched the integer names
also matched it and returned before the text arm was ever reached. The
arms are one now, with the length split off inside.

**THE MONITORING TABLES, AND THE ALL-NULL ROW — DONE 2026-08-29
(`serve-real-monitoring` 10, new).** `MON$` queries were answered by ONE
ALL-NULL ROW whatever they asked. `SELECT COUNT(*) FROM
MON$ATTACHMENTS` answered NULL — which COUNT never does — under a column
called `C0` rather than the name the query gave it. The relation was
never consulted at all: a `MON$` prefix short-circuited to
`Plan::VirtualEmpty { ncols }`, with the column count taken from the
top-level commas rather than a parse.

They are REAL CATALOG RELATIONS (`MON$DATABASE` is relation 33 with 28
fields), so they go down the ORDINARY path now and are described from
the catalog like anything else. `MON$DATABASE` is COMPUTED — one row of
what this server knows for certain about the file, read through the same
`HeaderPage` decoder gstat and gfix use. Every other `MON$` table scans
its own empty storage and answers NO ROWS, with the right shape and the
right names.

TWO FAST PATHS HAD TO LEARN THE SAME WORD. A computed relation has no
record headers, so `StreamCursor::open` (which walks data pages) and the
`COUNT(*)` fast path (which counts headers without decoding) both
DECLINE for one and leave it to the materialising scan — the count
answered 0 where the scan answers 1 until it did.

AND THE HEADER IS DECODED, NOT INDEXED. The first cut read the offsets
by hand and had ODS at **-32754** and the sweep interval at nonsense:
`ods_major` strips a flag bit, `page_buffers` sits where the guess put
`oldest_transaction`, and the sweep interval is not a field at all but a
CLUMPLET in the variable header, defaulting to 20000 when absent.
`HeaderPage` knew all of it.

WHAT IS LEFT NULL, deliberately: `MON$PAGE_BUFFERS` (the engine's
RUNTIME cache size, and this server's cache is not that), `MON$OWNER`,
`MON$FILE_ID`, `MON$CREATION_DATE`, `MON$NEXT_STATEMENT`. Each would be
a guess, and a guess in a monitoring table is an answer nobody can act
on.

**AND THEN `MON$ATTACHMENTS` (same day, `serve-real-monitoring` 10 →
13).** The divergence above, closed for the table an operator actually
opens: one row per live attachment, from a registry each session keeps
on the file's `DbGate` — added at the attach, removed wherever the
session ends, which is the same pair of places `ON DISCONNECT` fires
from. It answers who attached, the file they opened, the PEER address
(which only the server can know), the protocol, the state and whether
the wire is encrypted; and the gate holds the property that matters -
**the count follows the connections**, 1 then 2 then 1 as a second
session opens and goes.

The columns a CLIENT sends in its DPB - its process id and name, its
host, its OS user, its library version - are not retained by this
server, so they answer NULL rather than a guess, and the gate asserts
that too.

**AND `MON$TRANSACTIONS` WITH IT (`serve-real-monitoring` 13 → 17).**
Every attachment's live transactions, published by the sessions that own
them. A `SNAPSHOT` transaction reports mode 1 and ACTIVE on BOTH
servers, which is the comparison that can be made — and every
transaction joins an attachment this server also names.

WHICH ONE IS ACTIVE MOVES WITH THE STATEMENT, which is why the publish
is once per REQUEST rather than only where a transaction starts or ends:
a client may prepare on one handle and execute on another (isql does),
so a flag written at `SET TRANSACTION` is stale by the time anybody
asks. It named the snapshot transaction idle and isql's spare one
active, exactly backwards from the engine, until the refresh moved to
the top of the op loop.

A DIVERGENCE IN WHAT THE SERVERS DO, not in what they report, recorded
and gated: the engine's default read committed is READ CONSISTENCY (mode
4) and this server reads the latest committed version (mode 2). Each
answers what it actually does — which is the point of the column.

**AND `MON$STATEMENTS` CLOSES IT (`serve-real-monitoring` 17 → 19).**
What each attachment has prepared, with the one it is working on marked
ACTIVE and its text as a COMPUTED BLOB - the machinery `LIST()` brought.
The comparison this allows is the strongest on the surface: **the
statement a server reports as running IS the query asking**, so both
must answer the same TEXT. They do.

A REAL DEFECT FELL OUT OF IT, and it was not in the monitoring code. A
computed blob carries relation 0 and lives in the mint context until the
op ends, so the blob reader - which reads out of the FILE - refused it,
and `CAST(<a computed blob> AS VARCHAR(n))` answered NO ROWS AT ALL
where the engine answers the text. Silently: no error, no row, nothing
to act on. `blob_text_of` serves relation 0 from the mint now, which
fixes the same shape for `CAST(LIST(x) AS VARCHAR(n))`.

The gate compares the TEXT and not the blob's ID: a computed blob is
minted from this server's own range (`0:40000001`) where the engine
hands out `0:1`, and neither number is a fact about the statement.

THE SURFACE IS NOW: `MON$DATABASE`, `MON$ATTACHMENTS`,
`MON$TRANSACTIONS` and `MON$STATEMENTS` answered from live state, and
every remaining `MON$` table honestly empty with the right shape and
names - `MON$CALL_STACK` and the statistics tables among them, each
asserted at 0 rather than NULL.
An empty relation of the right shape is something a client can read —
the all-NULL row was not. The one thing that row bought, a firebird-qa
bootstrap whose projection uses `COUNT(DISTINCT ...)` and `IIF(...)`,
is a REFUSAL now: the honest answer to a query this server cannot read.

**A BODY CONDITION THE PLANNER ANSWERS — DONE 2026-08-29
(`serve-real-trigtext` 10 → 14, `serve-real-ddltrigger`'s recorded
policy refusal became a comparison).** The other half of the body
grammar. Values were freed in the text slice; a CONDITION was still the
arithmetic `Cond` — so `IF (UPPER(NEW.V) = 'AB')`, `IF (NEW.V LIKE
'a%')`, `IF (NEW.V IS NULL)` and above all `IF
(RDB$GET_CONTEXT('DDL_TRIGGER', 'OBJECT_NAME') = 'X')` were outside it.
That last one is how ANY DDL policy is written, so the chunk that made
DDL triggers fire could not run the trigger anybody would actually
write; the statement refused instead, honestly but uselessly.

Same mechanism as the values, and the same reason it is right: when the
arithmetic parse declines, the CONDITION TEXT is kept as written and the
frame substituted into it, then the ORDINARY planner answers it —
`SELECT COUNT(*) FROM RDB$DATABASE WHERE (<cond>)`, which is 1 for TRUE
and 0 for FALSE **or UNKNOWN**. That is exactly `IF`'s own three-valued
rule: only TRUE takes the branch (measured: `WHERE (NULL = 1)` counts
0), and the gate runs every test over a NULL to hold it there.

A `WHILE` takes the same path, so a loop may be driven by a test the
planner answers. Nothing that parsed before changes: the raw form is
kept only where the arithmetic parse declines, and a body carrying one
cannot be COMPILED to BLR (`body_has_uninterpretable_blr`), exactly as a
body carrying a text literal or a raw-values `INSERT` could not.

**WRITING A DDL TRIGGER — DONE 2026-08-28 (`serve-real-ddltrigger` 13
→ 14).** The other half, and the last piece of the trigger taxonomy:
`CREATE TRIGGER ... BEFORE ANY DDL STATEMENT`, `AFTER CREATE TABLE OR
DROP TABLE`, a single event with a `POSITION` — all compiled HERE, with
the catalog row, the BLR and the debug info the engine's BYTE FOR BYTE,
after which the ENGINE RUNS what this server compiled.

`CREATE TRIGGER` now has THREE shapes and one parser: a relation trigger
names its table (`FOR TBL BEFORE INSERT`), a database trigger names an
event after `ON`, and a DDL trigger names DDL VERBS after `BEFORE` or
`AFTER` with no `ON` at all. With no `FOR`, the head starts at whichever
keyword comes first — `ON`, `ACTIVE`, `INACTIVE`, `BEFORE` or `AFTER` —
which is what tells the last two apart.

The type is the family, the after-bit and a BIT PER EVENT, so an `OR`
list is a bitwise OR and `ANY DDL STATEMENT` is every bit at once:
`AFTER CREATE TABLE OR DROP TABLE` is 16395 = `16384 | 1 | (1 << 1) |
(1 << 3)`, which fire-crab and the engine now write identically.

**DDL TRIGGERS — DONE 2026-08-28 (`serve-real-ddltrigger` 13, new).**
The third trigger class, and the one a schema is POLICED with: `BEFORE
ANY DDL STATEMENT` to audit or forbid, `AFTER CREATE TABLE` to react,
with a context namespace of its own — `RDB$GET_CONTEXT('DDL_TRIGGER',
'DDL_EVENT' | 'OBJECT_NAME' | 'SQL_TEXT')`. This server read them from
the catalog and IGNORED them, so a database that forbids `DROP TABLE`
let one through.

HOW A TRIGGER'S TYPE SAYS WHAT IT IS (`jrd/constants.h`:362, then
measured against the engine's own rows): `RDB$TRIGGER_TYPE >> 13 & 3` is
the FAMILY — 0 a relation's DML trigger, 1 a database trigger, 2 a DDL
trigger — and a DDL trigger's type is `TRIGGER_TYPE_DDL | (AFTER ? 1 :
0) | (1 << event)` for EVERY event it names, so one trigger may fire for
many. `AFTER CREATE TABLE` is 16387 = `16384 | 1 | (1 << 1)`; `BEFORE
ANY DDL STATEMENT` is 9223372036854767614, every event bit with the
family bits and the after-bit cleared and the family put back.

THE REFUSAL THAT MATTERS: a DDL statement whose event this server cannot
NAME, in a file that carries a DDL trigger, refuses rather than running
unwatched. A trigger that did not fire is a policy that did not run, and
nothing else would say so. The same rule catches a body this server
cannot RUN — a policy written as `IF (RDB$GET_CONTEXT('DDL_TRIGGER',
'OBJECT_NAME') = 'X')` is outside the body-condition grammar, so the
statement it would police refuses (recorded, and gated).

TWO DEFECTS THE GATE FOUND, both already-learned laws in a new place:

1. **The engine WRAPS every DDL failure**, its triggers' raises
   included: `unsuccessful metadata update` / `-DROP VIEW
   "PUBLIC"."VG" failed` / then the exception. This server answered the
   exception alone. `EvalErr::DdlFailed` carries the wrapper, and
   `ddl_verb_gds` the per-verb message (`sqlerr.h`; the code is
   `0x14000000 | (13 << 16) | <number>`).
2. **A DDL statement whose triggers write needs a `Nested` window** —
   the same law the DML-trigger chunk learned. Their rows are installed
   by statements of their own, which dropping a working copy cannot take
   back: the audit row of a REFUSED `DROP VIEW` survived here where the
   engine has none.

RECORDED BOUNDARY: this server does not COMPILE a DDL trigger yet, so
the gate's triggers are made by the engine on both files and what is
under test is FIRING them — the same order the database-trigger pair
went in.

**A TRIGGER BODY THAT BUILDS A STRING — DONE 2026-08-28
(`serve-real-trigtext` 10, new).** Writing a message is the commonest
thing a PSQL body does — an audit row saying what changed, a log line
carrying the key — and every one of them refused: a body's values were
parsed into an ARITHMETIC grammar (`+ - * /` over integers) and a
concatenation is not in it. `INSERT INTO LOG VALUES (NEW.ID, 'set to '
|| NEW.A)` was outside the surface, and so was the two-step form that
builds the string in a variable first.

THE FIX IS NOT A BIGGER EXPRESSION GRAMMAR. A body's own statement is
already rendered back to SQL and run by the ORDINARY planner, which
knows the whole value grammar — so when a value will not fit the
arithmetic form, `TrigStmt::Store` keeps the VALUES TEXT AS WRITTEN and
substitutes the frame into it (`subst_body_query`: `:var`, `NEW.<col>`,
`OLD.<col>`). Concatenation arrives with everything else the planner can
do — the gate pins `UPPER`, `CASE`, `CAST` and `SUBSTRING` in a body's
`VALUES` — and nothing that parsed before takes the new path, because
the raw form is kept only when the arithmetic parse declines.
`DynPart::Row` does the same for the two-step form, where the string is
built in a variable first.

THE LAW THAT COST A WRONG ANSWER: **trailing blanks belong to a value
and not to a statement.** A CHAR variable holding a whole statement is
padded to its declared width and that padding is no part of the SQL
(probed long ago: a CHAR(40) holding a SELECT runs) — but a
CONCATENATION keeps every blank: measured, `'[' || <a CHAR(6) holding
'ab'> || ']'` is `[ab    ]` on the engine. One renderer served both and
trimmed for both, so the first cut of this slice answered `[ab]`. It
trims only where the whole value IS the statement now, and the gate
reads every row back inside `<>` so a trailing blank is visible.

A SECOND, smaller one: a substituted NEGATIVE number has to be
PARENTHESISED. `'set to ' || NEW.A` over `A = -3` became `'set to ' ||
-3`, where the leading minus reads as an operator and the statement
refuses; `(-3)` is the same value in every position.

RECORDED BOUNDARY: this server will not COMPILE such a body to BLR — it
has no probed byte shape for a text expression — so `CREATE TRIGGER`
refuses to STORE one, exactly as it already refused a body carrying a
text literal. The gate's triggers are made by the engine on both files;
what is under test is RUNNING them. (`serve-real-dbtrigger`'s recorded
concatenation refusal became an answer and is now compared.)

**WRITING A DATABASE TRIGGER — DONE 2026-08-28 (`serve-real-dbtrigger`
10 → 12).** The other half of the entry below: `CREATE TRIGGER ... ON
CONNECT` (and its four siblings) compiles HERE now, and its catalog row,
BLR and debug info are the engine's BYTE FOR BYTE — after which the
ENGINE RUNS what this server compiled, which is the check that matters.

`CREATE TRIGGER` has two shapes: a relation trigger names its table
(`FOR TBL BEFORE INSERT`), a database trigger names an EVENT (`ON
CONNECT`, `ON TRANSACTION COMMIT`). The row is written with
`RDB$RELATION_NAME` left NULL — `sys_insert` starts every field NULL, so
it is simply not written — and its name must be unique across ALL
triggers rather than within one relation's.

THREE DEFECTS, each measured against the engine's own bytes:

1. **The header keywords were searched for in the WHOLE statement.** A
   body carrying `NEXT VALUE FOR S` has a `FOR` of its own, and the
   parser took that as the relation clause and read the trigger's name
   as everything before it. The search is bounded to the header — the
   text before `AS` — which is what it always meant.
2. **The relation contexts start at 0, not 2.** A relation trigger's 0
   and 1 are OLD and NEW, so its first `blr_store` takes context 2; a
   database trigger has neither row and its first store takes 0. The BLR
   differed from the engine's in exactly that byte, in every place it
   appeared.
3. **A generator the body draws is a DEPENDENCY** (`RDB$DEPENDENCIES`,
   object type 14). The engine writes one; this server wrote the
   relation and column rows and not that one. Fixed for relation
   triggers too, which had the same gap.

A database trigger's body is validated with no relation to check names
against, so `NEW.`/`OLD.` in one refuses — the engine's rule — while the
OTHER tables it names are checked against their own catalogs exactly as a
relation trigger's are.

A FOURTH DEFECT came out of the sweep rather than the gate, and it is
the one worth remembering: **the ON CONNECT refusal has to REPLACE the
attach's reply, not follow it.** Answering the attach first and then
sending the exception told the client its attach had SUCCEEDED, so it
went on to send a statement, got the exception as THAT statement's
failure, and then a broken connection (`08006`) when this end hung up.
The gate had passed on it — the message was there, in the right order,
with the right stack item — and only a run under load, where the client
retried, showed the extra line.

TWO QA-HARNESS BUGS were found by the same sweep and are worth recording
because both read exactly like regressions. Six gates all wrote
`/tmp/fbhandson/q.sql`, so a parallel run had one overwriting another's
script — the failure looked like a package's function vanishing. And
`serve-real-idxcost` compares an index plan's milliseconds against a
scan's: four gates at once made the index side look 2x SLOWER, though it
passes alone at the same load average. It is SERIAL now. The scratch
names were swept for others; `q.sql` was the only one shared.

**DATABASE TRIGGERS — DONE 2026-08-28 (`serve-real-dbtrigger` 10,
new).** The trigger class that belongs to the ATTACHMENT rather than to
a table: `ON CONNECT` (8192), `ON DISCONNECT` (8193) and `ON
TRANSACTION START`/`COMMIT`/`ROLLBACK` (8194/8195/8196). This server
read them from the catalog and IGNORED them, so a database configured
with an `ON CONNECT` trigger behaved through fire-crab as though it had
none — silently, which is the outcome this project does not allow.

They fire where NO STATEMENT IS RUNNING, so nothing is holding a working
copy and there is nothing to publish: the bodies go down the ordinary
path with the database already in reach. There is no row either, so the
frame carries no `TrigCtx` and a body naming `NEW.`/`OLD.` refuses.

THE LAWS, measured first:

- `ON CONNECT` fires once per attachment, BEFORE the client's first
  transaction, in a transaction OF ITS OWN — and an internal transaction
  fires nothing itself, so no `tx-start` row appears for it.
- **That transaction has to be COMMITTED.** Work left under an id
  nothing commits is invisible to every later reader, which is exactly
  how this first behaved: the body ran, wrote its row, and the row was
  never there.
- `ON TRANSACTION COMMIT` and `ROLLBACK` fire INSIDE the transaction
  that is ending, which is visible: a ROLLBACK body's own rows GO BACK
  WITH THE ROLLBACK while the generator it drew from HAS moved, a draw
  not being transactional. (It is why Firebird's own documentation tells
  you to write rollback auditing in an autonomous transaction.)
- An `ON CONNECT` that RAISES REFUSES THE ATTACH, with the body's own
  message — the trigger is a gate, not a notification.
- `ON DISCONNECT` fires at the detach AND at every other way a session
  ends (a closed socket, a failed read); a body that audits
  disconnections must not be able to miss one by crashing the client.

A DEFECT IN THE RENDERER CAME OUT OF IT. A body's own statement is
rendered back to SQL, and a generator draw had no rendering at all
("rendering it into a statement's text would draw twice") — so the
CANONICAL database trigger, `INSERT INTO LOG VALUES (NEXT VALUE FOR S,
...)`, refused. The fold runs FIRST and answers wherever the frame can
draw (a BEFORE trigger's replay pass), so that arm is only reached when
the draw belongs to the NESTED STATEMENT, where rendering it as itself
draws exactly once, down the ordinary path.

THE GATE ITSELF NEEDED A DIFFERENT CLIENT. isql does not issue the same
ops to both servers — it opened two transactions against the engine
where it opened one against this server for the same script — and that
client-behaviour difference drowned the thing under test. The acting
connection is the node driver, which makes exactly the same calls to
both: one attach, one transaction, the log read back over the SAME
connection.

RECORDED BOUNDARIES: `CREATE TRIGGER ... ON CONNECT` refuses cleanly
(nothing is stored — checked), so the gate's triggers are made by the
engine on both files; whether a file carries database triggers at all is
read ONCE at the attach, so one another attachment creates afterwards is
not seen until this one reconnects; and a body expression has no
CONCATENATION, so `'sum=' || :N` refuses rather than storing something
else.

**A TRIGGER BODY THAT LOOPS, AND ONE THAT CALLS — DONE 2026-08-28
(`serve-real-trigloop` 12, new).** The rest of the surface the chunk
below opened: `FOR SELECT ... INTO ... DO`, a declared CURSOR with
`OPEN`/`FETCH`/`CLOSE`, and `EXECUTE PROCEDURE` in both its forms
(arguments, and `RETURNING_VALUES`).

THE LAW THAT DECIDES IT, probed first: **a loop takes its rows when it
starts.** A `FOR SELECT` over a table whose own loop body INSERTS into
that same table still walks only the rows that were there when it
opened — measured on a two-row table inserting one row per iteration:
the loop runs TWICE and leaves four rows. A cursor behaves the same
between its `OPEN` and its `CLOSE`. This server's `ForSelect` already
materialised its rows through `branch_rows` before the loop, so it
inherits the engine's answer; an implementation that re-read the table
per iteration would not terminate on the engine's own fixture.

Three things were missing rather than wrong. A loop's and a cursor's
query substituted VARIABLES but not the ROW — the same defect
`SELECT INTO` had — so `FOR SELECT ... WHERE K = NEW.K` could not be
planned; both go through `subst_body_query` now, with an empty bind list
because their variables were already marked by the parser. Trigger
frames were built with an EMPTY cursor map (only procedures ever
populated one from their header), so `OPEN CU` in a trigger body had no
cursor to find — `trig_cursor_states` reads the trigger's own header the
same way. And `trig_body_inlineable` was widened to let these run.

A REAL DEFECT CAME OUT OF IT, in the stack item this project has pinned
since the trigger chunk. The engine's first `RDB$DEBUG_INFO` source
entry is the DECLARATION SECTION when a body has one and the body's
`BEGIN` when it does not (measured, entry by entry: a trigger declaring
`V` on its own line has entries at the DECLARE's line, then `BEGIN`'s,
then each statement's). This server anchored on `BEGIN` either way, so
every stack item from a body whose header sits on a line of ITS OWN was
**one line short** — `line: 7` where the engine says `line: 8`. It was
invisible for as long as every gated trigger wrote `AS DECLARE ...
BEGIN` on one line, where the two are the same line. `anchor_base`
measures from whichever point the engine anchored on.

RECORDED BOUNDARIES: `EXECUTE STATEMENT` in such a body (it builds its
statement at runtime, where the prepare-time walk can see no table name
to judge, and the self-write refusal below depends on that walk) and an
autonomous block (a transaction of its own around a published working
copy, never measured).

**A TRIGGER BODY THAT READS AND WRITES THE DATABASE — DONE 2026-08-28
(`serve-real-trigdb` 24, new; `serve-real-trigfire` two boundaries
became answers).** The classic triggers work now: an AUDIT trigger that
writes another table from a `BEFORE` body, and a LOOKUP trigger that
reads one to decide a column. Until this, a body that touched the
database at all made every `INSERT`, `UPDATE` and `DELETE` against its
table refuse — a table with an audit trigger could not be written.

THE MECHANISM IS ONE LINE OF REASONING. A trigger fires inside a
statement that is holding its working copy of the file, and a body's own
statement goes down the ORDINARY path — taking a copy and installing it.
Two writers cloning the same base both install a whole image and the
second silently drops the first's rows, which is why such a body was
refused. So the statement PUBLISHES its copy around the body
(`fire_triggers_published`) and takes a fresh one after. Publishing is
not a concession to the mechanism: it is what puts the body's read on
exactly the file the engine shows it.

WHAT THE ENGINE SHOWS IT, all measured first:

- A `BEFORE` body reads its own table WITHOUT the row being written and
  WITH every earlier row of the same statement. Under an `INSERT ...
  SELECT` of three rows the per-row `SELECT COUNT(*)` answers 0, 1, 2 —
  so the body can be run neither after the statement (3, 3, 3) nor
  before it. The AFTER-the-statement ordering is what this server used
  to do for the one body shape it could defer, and it is gone with the
  whole `deferred` path.
- An `AFTER` body reads the table WITH the row.
- A `BEFORE UPDATE` body reads the sum BEFORE this row's update; a
  `BEFORE DELETE` body still counts the row it is about to remove.
- A statement that fails takes the body's writes with it, however far
  the body got: a trigger that logged a row whose own `INSERT` then
  violates a `CHECK` leaves the log EMPTY.
- A body's write fires the triggers of what it writes, and those fire on.

THREE THINGS HAD TO CHANGE UNDERNEATH, each found by the gate:

1. **The window kind.** A statement whose writes are installed as it
   goes cannot be undone by dropping a copy. It takes a
   `WindowKind::Nested` window — undone by killing the id its rows carry
   — exactly as a row-by-row statement already did.
2. **The transaction id is adopted AT THE PUBLISH.** A statement
   reserves an id in its copy and adopts it only when it installs, which
   is what makes a failed statement burn nothing. Un-adopted, the rows
   it has written are another transaction's uncommitted work to every
   reader — including this body. An `AFTER INSERT` body did not count
   the row it fired for, an `AFTER UPDATE` body read the value before
   the update, and a `BEFORE DELETE` body's `AFTER` twin still saw the
   row: three wrong answers from one missing line.
3. **The rows are written AS THEY ARE READ.** The `UPDATE` and `DELETE`
   arms read and validate every row, then write them all. That is
   invisible until a body reads the table: all three bodies then see the
   same state, where the engine's answer walks. The write walk's body is
   now `write_updated_row`, called either from the walk or from inside
   the scan loop — same function, same order, different moment — and the
   gate pins it with a log table read WITH NO `ORDER BY`, so the
   physical order of the rows the bodies wrote is compared too.

TWO PRE-EXISTING DEFECTS SURFACED BESIDE IT. `:VAR` was accepted only in
the embedded-DML positions (`colon_clean`), never in a plain PSQL one —
so `IF (:M IS NOT NULL)` refused the whole body, which is how a lookup
trigger is written; both forms resolve to the same slot now. And a body
query was planned as raw text, so `SELECT MULT FROM RATE WHERE K =
NEW.K` could not be planned at all; `subst_body_query` writes the
frame's values in as literals, the same substitution the body's own DML
already made.

The status vector gained a law too: a `CHECK` constraint's vector
already ENDS in an `isc_stack_trace` item, and a body whose write
violates it CONTINUES that item rather than adding a second — the whole
stack is one element with newlines in it, which is why isql prints a `-`
before the first line and nothing before the rest.

RECORDED BOUNDARIES: a body that WRITES THE TABLE IT FIRES FOR (the
engine recurses to `Statement::MAX_CLONES` = 1000 and answers 54001;
each level here is a whole executor frame, so it refuses rather than
answering by crashing — a cross-table cycle is caught at depth 16), a
cursor / `FOR SELECT` / `EXECUTE STATEMENT` / autonomous block in such a
body, and a body that DRAWS A GENERATOR beside one that needs the
database (the draw belongs to the caller, which has handed its working
copy back).

**THE STAR IN `RETURNING`, AN ALIASED DML TARGET, AND A MERGE'S THIRD
ROW — DONE 2026-08-28 (`serve-real-returnold` 25 → 52).** The three
boundaries the entry above recorded, closed together, because they are
one question: WHICH ROWS does a DML statement have to name, and what may
name them.

`RETURNING *` answers now, and so does every qualified star: `T.*` (the
target's own name), `NEW.*`, `OLD.*`, an alias's `x.*`, and `OLD.*,
NEW.*` together in that order. A qualified star may share the list with
ordinary columns; a BARE one may not — the engine's grammar takes `*` as
a whole production, so a comma beside it is -104, and the gate pins that
both servers refuse it. `StarCtx::{New,Old,Source}` says which image a
star expands over and `returning_star` does the expanding, against the
same descriptors the plain column route already had.

An ALIASED TARGET (`UPDATE T x SET x.N = ... RETURNING x.N`) is a text
pass, `strip_dml_alias`, and two mistakes are worth keeping: it first
scanned from offset 0, which found the TABLE name `T` before the alias
`t` and stripped that (`dml_target_alias` returns the alias's byte
OFFSET now, not just its text), and it was applied to INSERT as well,
where it made this server ACCEPT `INSERT INTO T t (...)` that the engine
answers -104 — restricted to UPDATE and DELETE, MERGE excluded, and the
gate holds a check for each. A string that merely SPELLS the alias, and
an identifier that merely begins with it, are left alone. The one shape
the pass may not take is a nested FROM re-declaring the SAME alias for
another table: rewriting through it would answer the wrong rows, so it
refuses.

A MERGE has THREE rows to name — the target's after-image, its
before-image, and the SOURCE row — and the engine names all three.
`Affected` carries the third in a new `src_rows`, parallel to
`old_images`, and a returned row is built in three blocks: the image at
0, the before-image at `width` (an inserted row leaves it NULL rather
than erroring), the source row at `2 * width`. The DESCRIBE of a source
column names the SOURCE's table, not the target's — the source
`ProjCol`'s relation is kept rather than blanked, which was a real
defect found by the gate. RECORDED BOUNDARY: a BARE `*` in a MERGE names
BOTH contexts and the engine proves it by raising 42702 on the column
they share; this server has only the target's columns to expand with and
no 42702 to answer with, so it refuses.

**FIRING USER TRIGGERS ON THIS SERVER'S OWN DML — DONE 2026-08-27
(`serve-real-trigfire` 16, then 22).** `serve-real-trigger` has covered
CREATE TRIGGER for a long time — the PSQL-to-BLR compile, the catalog
rows, the debug blob, with the ENGINE executing what this server wrote.
The other half was missing: this server never FIRED one, so **any** user
trigger on a table made every INSERT, UPDATE and DELETE against it
refuse (the coarse `user_trigger` flag in `check_predicates_uncached`).
A table with an audit or a compute-a-column trigger could not be written
at all.

It fires them now, and the runnable surface is exactly the one CREATE
TRIGGER compiles: assignments over `NEW.`/`OLD.`, variables, literals,
integer arithmetic, IF, WHILE, EXCEPTION, and blocks with their WHEN
handlers. Measured against the engine: a BEFORE trigger COMPUTES a
column and what it assigns to `NEW.<col>` is what gets stored (over a
client's value too); several fire in RDB$TRIGGER_SEQUENCE order, each
seeing the last one's result; a BEFORE UPDATE body reads OLD and NEW and
a BEFORE DELETE one reads OLD; an INACTIVE trigger does not fire; an
AFTER trigger fires with the row written and NEW read-only there.

**An EXCEPTION inside a body stops the statement with the ENGINE'S OWN
vector**, stack item included: `At trigger "PUBLIC"."T_BI3" line: 1,
col: 82`. That line and column count the ORIGINAL `CREATE TRIGGER` text,
not the stored source — so they are read back from the `RDB$DEBUG_INFO`
blob this server already writes (`debug_info_anchor` takes its first
source entry, the body's BEGIN, and the interpreter's own offset does
the rest). The exception's NUMBER and MESSAGE are resolved at PREPARE
(`TrigDef::excs`): a trigger fires while the statement holds the working
copy of the file, with no catalog in reach.

Two mechanisms, one seam: `PsqlFrame` grew a `TrigCtx` (the relation's
columns, the OLD and NEW rows, and whether NEW is writable), which is
what turned `Expr::Field` and `TrigTarget::Field` from
`PsqlStop::Unsupported` into the trigger contexts they always described.

**AND THE OTHER HALF: AN AFTER TRIGGER MAY TOUCH THE DATABASE — DONE
2026-08-27 (same gate).** The most common trigger of all - `AFTER INSERT
... INSERT INTO LOG ...` - was still refused, because a trigger fires
while the statement holds its working copy and a nested write would be
lost under it. An AFTER trigger has nothing left to decide, so such a
body now runs DEFERRED: after the statement's own writes are applied,
with the database in reach, and still inside the statement's undo window
(`fire_deferred_triggers`, called from `execute_dml_collecting` between
the inner run and the unwind) - so a raise takes the whole statement
back, its own rows included. The rows come from the `Affected` collector
the statement already fills for RETURNING, extended with `old_images` so
a deferred AFTER UPDATE body reads a real OLD.

Boundaries recorded, both stated rather than guessed: a BEFORE trigger
whose body touches the database keeps the refusal (it must decide what
gets stored, and by the time the database is free the row is already
there), and a deferred body that NAMES THE TABLE IT FIRES FOR refuses -
by then that table holds every row the statement wrote, where the
engine's per-row firing would have shown it a prefix. A multi-event
trigger (`BEFORE INSERT OR UPDATE`) refuses whole: its composed type
carries the INSERTING/UPDATING/DELETING predicates with it.

`serve-real-trigger` and `serve-real-trigger2` unrecorded their
"fire-crab REFUSES its own DML on a user-trigger table" boundaries, and
`serve-real-fkguard` its two (a USER trigger no longer refuses the
statement; the FK ACTION triggers it exists for still do).

**UNIVERSAL (MULTI-EVENT) TRIGGERS — DONE 2026-08-27 (same gate, 25).**
`BEFORE INSERT OR UPDATE [OR DELETE]` packs up to three actions into one
trigger type, and the slice above refused every one of them. Three small
pieces, small because the machinery around them now exists:

* the COMPOSED TYPE is decoded rather than special-cased. This server
  already spells it for SHOW (`trigger_type_words`: bit 0 is BEFORE,
  then three action slots carrying 1 INSERT / 2 UPDATE / 3 DELETE), so
  `dml_trigger_events` reads the same arithmetic the other way - and a
  single-event trigger is simply the one-slot case, so the six original
  types needed no arm of their own.
* `INSERTING` / `UPDATING` / `DELETING` take SYNTHETIC VARIABLE SLOTS
  appended to the body's name list (`TRIG_ACTION_NAMES`), so the
  ordinary name resolution turns them into `Expr::Variable`s and
  `trig_frame_vars` fills the three with 1/0 for the action actually
  firing. No parser surgery at all.
* a BARE ACTION PREDICATE is a condition: `IF (INSERTING) THEN ...`.
  That path is restricted to exactly those three names - an integer
  expression standing where a condition belongs is not a Firebird
  boolean, and accepting one would let this server COMPILE a trigger the
  engine refuses.

**THE ACTION PREDICATE IS A NODE, NOT A TRICK — DONE 2026-08-27
(`serve-real-trigger`, TR5).** The synthetic slots above answer
INSERTING/UPDATING/DELETING while a body RUNS, and that is all they can
do: the same parser feeds CREATE TRIGGER, where a predicate resolved as
a plain name would have been emitted as an ordinary FIELD REFERENCE -
wrong BLR, written into the catalog with no error to show for it. (Two
probes corrected the record here: this server's CREATE TRIGGER has
handled the COMPOSED TYPE for a long time - `BEFORE INSERT OR UPDATE =
17`, the triple 113, written order preserved - and the boundary recorded
above, "CREATE for a universal trigger still refuses", was measuring a
malformed probe: an isql script with no `SET TERM`, so the body's
semicolon split the statement into a -104 on BOTH servers.)

`ods::expr::Expr::TriggerAction` is the engine's own half of the
predicate: `parse.y`'s `trigger_action_predicate` builds
`blr_eql(blr_internal_info(<const 6 = INFO_TYPE_TRIGGER_ACTION>),
<const 1|2|3>)`, so the node emits `blr_internal_info` followed by the
info type as an ordinary long literal, and the literal beside it says
which action was asked about. One representation now serves both paths -
the interpreter answers it from `TrigCtx.action`, the compiler emits it -
and `serve-real-trigger` pins the bytes: a universal trigger's BLR and
debug info come back byte-for-byte identical to the engine's, the
composed type with them.

Adding a variant to that shared enum surfaced fifteen exhaustive matches
across `ods` and `wire`; each carries an arm saying what a trigger
action IS in that context (no column reference, not text, never inside a
domain CHECK) rather than a copied default. The WRITE side needed nothing: an index whose type is not
`PXW_INTL` was already unmaintainable here, so an INSERT that would
break a `UNIQUE` CI index refuses instead of storing a duplicate the
engine rejects (measured), and an FK over a CI key refuses rather than
accepting a case-variant parent.

**AGGREGATES IN EXPRESSIONS DONE (2026-08-25,
`serve-real-statexpr` 8):** the statistical/ordered-set family
(VAR_*/STDDEV_*, CORR/COVAR_*/REGR_*, PERCENTILE_CONT/DISC) and
SUM/AVG-over-expressions now serve in every position the engine does:
select-list arithmetic and wrappers (`STDDEV_SAMP(N)*2`,
`ROUND(VAR_POP(N),2)`, `CAST/COALESCE/CASE/NULLIF/unary minus`,
`SUM(N)*AVG(N)` → INT128:-4 subtype 1, `CORR(N,B)*100`,
`SUM(A+B)*2`), HAVING (bare and expression LHS — `SUM(N)*2 > 10`,
`STDDEV_POP(N)*2 > 3`, percentiles), and ORDER BY (bare aggregates,
aggregate expressions, aliases of both). The machinery was already
half-built: `RawExpr::Agg` leaves + slot substitution existed for
the five plain functions over bare columns; the slice factored
`resolve_agg_src` out of the bare select-item arm, taught
`agg_result_desc` the family's descriptors (DOUBLE; REGR_COUNT
BIGINT; PERCENTILE_DISC = the order column's), extended the WHERE
tokenizer's aggregate lexing to the whole family (with the `WITHIN
GROUP` tail swallowed, in both the token- and char-level parsers),
gave `texpr`/`parse_leaf` aggregate expression leaves, rebuilt
HAVING's `resolve_having` around a parallel `slot_descs` and an
expression route over the extracted `synth_group_view`, and hung an
aggregate-expression resolver on the grouped `parse_order_by_expr`.
DESCRIBE follows the engine's measured dsc rules: family expressions
NOT nullable yet NULL-capable on the wire (isql renders that NULL
`0.000...`; PERCENTILE stays nullable; COALESCE nullability is
ALL-branches), SQLDA name = top operator, CASE text at literal
length. THE FOLD FIX the wrap exposed: VAR/STDDEV of an empty/all-
NULL group (and the SAMPLE forms over one row) are NULL, not 0.0 —
invisible in bare renders for years, `COALESCE(VAR_SAMP(..), -1)`
told the truth. The 16-agent adversarial review caught 8 more, all
fixed + live-verified: the DOUBLE-describe coercion must run BEFORE
`value_of`'s exact-contract guards (a `COALESCE(D, 1.5)` branch
value 22003'd mid-fetch where the engine converts — reachable on
PLAIN rows too); **`ORDER BY X` where X aliases `0 - SUM(N)`
silently sorted by the bare SUM slot (pre-existing wrong order,
now the alias sorts by its expression)**; **exact-vs-DOUBLE
comparisons and the f64 folds converted scaled values by MULTIPLY
where the engine's CVT divides — `WHERE N = 35.8e0` picked the
WRONG ROWS silently (pre-existing), and VAR/STDDEV's last digit
drifted**; HAVING's Pair/Percentile route now runs the operand
gates (a text CORR fed the numeric fold silently) and
PERCENTILE_DISC compares text orders as text; MIN/MAX-over-
expression and SUM/AVG slots carry the NUMERIC sub_type; DOUBLE
describes never leak subtype 1. Boundaries recorded: LIST in
expressions (computed-blob concat), DISTINCT inside the family
(engine -104 Token unknown), aggregates in WHERE (engine's specific
-104 vs fc generic), windows/NTILE in expressions, family
expressions over GROUP-BY-expression keys, derived tables/views/
INSERT..SELECT wrapping family expressions (clean refusals), the
engine's 42702 ambiguous-ORDER-BY refusal that fc still serves, and
bare MIN/MAX over CAST announcing INT64 where the engine keeps LONG
(both pre-existing describe/refusal-shape divergences, candidates).

**DOMAIN CHECK constraints DONE (2026-08-25,
`serve-real-domaincheck` 6):** the silent-wrong class closed — fc used
to WRITE rows the engine refuses (RDB$VALIDATION_* had no consumer).
Three legs. (1) ENFORCEMENT: `domain_check_predicates` joins each
column's RDB$FIELD_SOURCE to RDB$FIELDS.RDB$VALIDATION_SOURCE and
re-parses `NOT (<cond>)` through the WHERE machinery with the `VALUE`
token text-substituted by the bare column name — so engine-built
BETWEEN/IN/LIKE/function checks all enforce; `validate_row_fields`
runs at INSERT and UPDATE on the FINAL row image in the engine's
measured order (table CHECK triggers first, then per-field in FIELD
order, domain check then NOT NULL — one walk, earliest field wins),
over EVERY validated column (an UPDATE re-validates untouched
columns; measured). Violations are byte-exact `isc_not_valid` 23000
(`validation error for column "S"."T"."C", value "v"`): NULL renders
`*** null ***`, text raw, scaled with its scale, DATE ISO — and
TIMESTAMP in the LEGACY `07-JUN-2019 8:09:10.5000` form (measured;
unlike every other render). FALSE fails, UNKNOWN passes. (2) CREATE
DOMAIN ... CHECK compiles the engine's stored form — the bare
POSITIVE boolean `blr_version5 <cond> blr_eoc`, `VALUE` = `blr_fid
0,0,0` (new `Expr::DomainValue`), a written NOT normalized into
inverted comparisons (`Cond::normalized`), IS NOT NULL keeping
`blr_not blr_missing` — dump-pinned in
`domain_checks_compile_to_engine_validation_blr`; source verbatim;
the ENGINE enforces fc-written checks (via the RSR 7 runtime segment
create_table already emits). (3) ALTER DOMAIN ADD [CONSTRAINT] CHECK
/ DROP CONSTRAINT: compile-at-execute (the domain's type read off the
live file), the second ADD refuses with the engine's three-item
vector (`ALTER DOMAIN @1 failed` 336397278 + dyn 160 336068768, the
message text carrying its own quotes), DROP nulls both columns
(no-op when none), no re-scan of existing rows, and
`update_relation_runtime` for every table using the domain so the
engine picks the change up. Boundaries: fc's DDL compile surface is
the table-CHECK surface (int + NONE-charset text comparisons,
AND/OR/NOT/IS NULL) — anything wider refuses the WHOLE statement
(never a domain without its rule) where the engine creates;
CAST(x AS domain) and PSQL vars over checked domains keep refusing
(engine: 42000 `validation error for CAST/variable`); a repeated
ALTER cycle used to hit a catalog page-full refusal — CLOSED
2026-08-25 by SQZ pack-on-write: every record fc stores (INSERT,
UPDATE, fragment pieces, restore rows) is RLE-packed when smaller
(the engine's sqz.cpp `m_allowUnpacked` law), the FILL pad to
RHDF_SIZE lands on EVERY store — raw records included (dpm.epp:471
"It is critical that the record be padded": the engine's `fragment()`
writes an rhdf header into the old slot assuming it; the 3-lens
review proved a short fc slot page-corrupts a plain engine UPDATE) —
while every RE-STORE site trims the all-zero tail back to fmt_length
(`trim_fill_tail`; re-packing the pad makes a record that unpacks
past fmt_length — engine BUGCHECK 179, the wire UPDATE path's
measured trim law now shared by `patch_sys_row` and the sweep's
promotion), a new version a FULL page cannot take whole FRAGMENTS in
place of refusing (dpm.epp `DPM_update` → `store_big_record`: head
in the fixed slot, tail elsewhere), and a fragmented catalog row
stays patchable — a poke past the head falls back to a whole-row
update whose back version is the old head CLONED, forward pointer
and all, so the old tail pieces follow it (`push_back_version`
already accepted an `rhd_incomplete` head). 24 drop/add cycles on 8K
now run clean where 3 used to die at "no room on page 112";
`serve-real-sqzpack` 9 checks — the cycles differentially, packed
USER rows written by fc and read byte-for-byte by the ENGINE, gfix
-v -full silent, a gbak round trip. Known-safe leak: a collected
fragmented back version's tail pieces are skipped by gc
(`chains_skipped`), never freed — space, not correctness. The review
also caught `insert_record_as` sizing `find_space` by the raw image
while writing the padded record — every insert clipped the
transaction id of the record stored just below it; the spot is now
found for the built record's true length. The first full sweep then
caught the last member of the class: `build_insert_image` /
`upgrade_image` sized fresh images by a LIVE SAMPLE record — whose
assembled length includes the engine's FILL pad — so every insert
into a table with padded rows built the pad INTO the image, and the
now-packed store unpacked past fmt_length (live BUGCHECK 179 in the
nbackup/ddltx/growth gates). Images are now built at fmt_length
exactly (met.epp's last-descriptor law; the sample only
sanity-checks), the pad living solely at the record layer.
serve-real-grow's growth threshold relaxed to +1 page: packed small
rows fill ~6x denser, exactly as the engine stores them.

**Catalog blob GC — DONE 2026-08-25.** The other half of the
page-pressure class: a catalog patch that REPLACES or NULLs a blob
field (the `RDB$RUNTIME` summary every ALTER rewrites, an ALTER
DOMAIN's validation pair, a re-granted `RDB$ACL`, a re-COMMENTed
`RDB$DESCRIPTION`) leaked the superseded blob forever — 2 slots per
ALTER-DOMAIN cycle on `RDB$FIELDS`, one runtime per cycle on
`RDB$RELATIONS`, and fc's sweep skips blob-bearing relations, so
nothing ever reclaimed them. Now: `patch_sys_row` (and the five
hand-rolled `RDB$RUNTIME` poke sites) captures the old id before the
overwrite, keeps anything the final image still names (the engine's
going-minus-staying diff, blb.cpp:424 — identity is the id, a blob
that moved fields is kept), and the free rides as DEFERRED work
(`DdlDeferred::FreeBlob`) applied at COMMIT with the other dfw.epp
phases; the settled path (tools, restore) frees on the spot. **The
law the hard way: blob and referencing version go TOGETHER.** The
first cut freed the slot while back/dead row versions still named the
id — the ENGINE's own version GC (a gbak attach's cooperative purge)
later collected the stale version and freed the id's NEW occupant
(gbak died on a live `RDB$RUNTIME`: "BLOB not found"). So every free
is paired with `PurgeRowChain` — the engine's `purge` narrowed to the
patched row: back chain freed (fragmented members' tails included),
head's back pointer zeroed; and a ROLLED-BACK statement's own minted
blobs deliberately STAY beside the dead versions that name them (the
engine's sweep collects both together — gated). The 3-lens review
confirmed four more: the commit guard was TIP-blind to READ-ONLY
snapshot transactions (fc reserves ids at first write — a reader has
no TIP entry; now any other live attachment holds the frees back),
the autonomous-block epilogue applied frees unguarded mid-outer-
transaction (they ride to the outer commit now), `free_blob` resolved
recnos through the zero-compacted page list where ids are
dpg_sequence-positional (resolved by the page's own sequence now),
and `op_prepare` refused every superseding DDL (the pending-DROP
guard now ignores free/purge entries). `serve-real-blobgc` 18 checks:
40 cycles with gstat "Blobs:" flat at/below the engine's own lazy
trail, rollback keeps the old check and the engine's sweep reclaims
the mints, GRANT/REVOKE + COMMENT churn at engine parity, snapshot
re-read under a concurrent COMMENT still answers the old value.
Remaining recorded: blobs superseded via delete-then-recreate (ALTER
VIEW/PROCEDURE/TRIGGER/FUNCTION, DROP TABLE stubs) still leak with
their dead rows — engine-collectable, same law.

**Blob-aware sweeping — DONE 2026-08-25.** The last leak dimension.
fire-crab's sweep SKIPPED any relation whose pages carry blob records
("the blob walk is its own slice"), so a user table with a blob
column never got version GC at all and the catalog's own blob
relations kept every back version forever. Now every collected
version takes its blobs with it, under the engine's law
(`BLB_garbage_collect`, blb.cpp:424): going = the removed versions'
blob ids, staying = the survivors', identity is the `(relation,
recno)` id, and only the difference is freed. All four arms carry it
— a rolled-back INSERT (everything goes), a PROMOTION (the dead
head's ids minus the promoted image's and every deeper member's), an
EXPUNGE (the whole chain, nothing stays), a live head's HISTORY (the
chain's minus the head's). A relation with no blob slots keeps the
old fast path; anything the walk cannot read whole — an unresolvable
format, an unreadable member — leaves the chain UNTOUCHED (never
free blind, unit-pinned).
Three laws the review pinned, each a corruption class: `rhd_delta`
says "the PRIOR version is differences only" (ods.h:1012), so the
flag that decides how a member is stored sits on the version IN
FRONT of it — reading it off the member itself handed raw delta
streams to the field decoder on every engine-written chain (garbage
blob ids, and a garbage id can name a LIVE blob); a blob id naming a
FOREIGN relation is IGNORED, never freed (blb.cpp:474's own guard —
such ids occur in real user data); and a version's own format number
is the only one that may decode it (a near-enough system format lays
the blob fields at the wrong offsets — freeing blind by another
name). `free_slot` no longer panics on a pointer past the file.
`serve-real-blobsweep` 18 checks: the same churn on twin databases,
each server sweeping its own file to the SAME survivors (records,
versions 0, live blob count, blob pages) with every row and a
level-1 blob's bytes identical — plus fire-crab sweeping the
ENGINE's own file, whose wide rows (`PAD CHAR(400)`, so the engine's
difference stream beats the record — measured: 0 delta versions
without it, 5 with) carry the delta chains fc's own writer never
produces. `serve-real-gfixsweep`'s recorded boundary ("the blob
relation is left whole") became the equality it always promised.
The 13-agent adversarial review caught 8 real defects, all fixed and
live-verified: two CRITICAL silent-wrongs — a case-blind
RDB$FIELD_SOURCE join bound the WRONG domain's check when `"dm2"`
and `DM2` coexist (fixed EXACT in domain checks, `not_null_fids` and
both domain-default joins — the same latent class), and the engine's
LOSSY source transliteration (`'né'` stored as `'n??'` while the
BLR keeps the real bytes) made fc enforce a wrong rule (a `?` inside
a string literal of a stored check source now refuses that table's
DML); a standalone TIME message renders PADDED (`08:09:10.5000` —
only TIMESTAMP is legacy-unpadded); `CHECK (...) DEFAULT` clause
order refuses (engine -104s it; `CHECK (...) NOT NULL` is legal both
sides); a multibyte byte-boundary panic in the CHECK splitter; a
SOURCE-without-BLR row is now SKIPPED (the engine enforces only from
the BLR's runtime segment); the duplicate-constraint test moved
BEFORE the new check's compile (an out-of-surface second ADD gets
the engine vector); and — pre-existing, review-surfaced — `ALTER
TABLE ADD <col> <domain>` used to write the UNRESOLVED zero-typed
column under a fresh carrier (length-0 garbage the engine chokes
on): it now resolves the domain like create_table, points
RDB$FIELD_SOURCE at it, mints no carrier, and the engine enforces
the domain's check on the added column (NOT NULL domains refuse —
the re-scan story is unproven). Two review findings stand as
designed fail-safes: one unevaluatable domain check refuses ALL DML
on tables using it (the table-check law), and fc's refusal SHAPES
for out-of-surface DDL stay generic.
`serve-real-scaledarith` 6):** `+`/`-`/`*`/`/`/unary-minus over
`Value::Scaled`/`Int128` with Firebird's scale rules (mirror of the wire
server's `numeric_bin`), and an assignment coerces its source to the
target's declared scale (rounds half-away into an INTEGER slot, rescales
into a finer NUMERIC, raises 22003 past the slot width). Observable via
INTEGER-signature routines whose bodies use decimal literals (`RETURN
A*1.5`). Boundary: an intermediate that overflows i64 raises 22003
"numeric value is out of range" where the engine may say "Integer
overflow" (both 22003) — fc's i128 numeric model, consistent with the
server's own `numeric_bin`.

**SQL COMMENTS accepted everywhere DONE (2026-08-25,
`serve-real-comments` 7):** `/* ... */` and `-- to end of line` in any
statement, as the engine's lexer treats them - whitespace. fire-crab
refused a comment ANYWHERE outside a PSQL body (`SELECT 1 /* c */` was a
generic 42000), which kept every real-world script off the server.
`strip_sql_comments` was rewritten as a POSITION-PRESERVING blanker -
every comment byte becomes one space, so byte length and every offset
(the error line/col mapping included) match the original; quote-aware
for `'` strings and `"` identifiers with doubled-quote escapes; block
comments unnested (the first `*/` closes, and the engine -104s the
leftover of a "nested" one); a comment separates tokens
(`SELECT/*t*/2`); unterminated blanks to the end - and applied at the
FOUR statement entries: the three wire decode sites (op_exec_immediate,
op_exec_immediate2, op_prepare) and PSQL's EXECUTE STATEMENT dynamic
text. The PSQL body parser's own two strip calls became the same
function, which also retired its latent Latin-1 mangling of non-ASCII
bodies (the old byte-through-`as char` copy). Commented DDL now
compiles and the ENGINE runs what fc stored - procedures, triggers,
views, CHECK constraints (re-parsed at every DML from stored source)
and COMPUTED columns, value- and vector-exact. Boundaries (recorded): a
routine/view/check created THROUGH fc's wire stores its RDB$SOURCE with
the comments BLANKED to spaces - same length, same line/col coordinates
- where the engine stores them verbatim (fc's RDB$DEFAULT_SOURCE was
already re-rendered, the precedent; gbak-carried and engine-built
sources keep their comments, and EVERY stored-source re-parser now
strips at read time - the adversarial review caught the three that did
not (the view re-plan, computed columns and the CHECK predicate parser
read engine-built sources raw: a '--' comment there parsed as DOUBLE
NEGATION, a '/*' refused DML the engine serves - all three fixed and
gated on an engine-built file), plus two more port misses fixed: an
UNTERMINATED block comment was silently swallowed where the engine
-104s (the entries now pass the original through and refuse), and
block-comment NEWLINES were blanked where the engine counts lines
through a comment (the 'At ... line:' frames kept their numbers only by
luck). The nested-comment and comment-split-operator refusals wear
fc's generic vector where the engine spells -104. Pre-existing gaps the
review surfaced for the candidate list: q'{...}' alternative quoting
(refused entirely), the doubled-quote identifier rendering (fc shows
a""b where the engine undoubles), and DOMAIN CHECK validation — the
latter CLOSED by the 2026-08-25 domain-check slice above.

**Constant EXPRESSIONS in INSERT ... VALUES - and the boolean wire fix -
DONE (2026-08-24, `serve-real-insertexpr` 8):** the engine accepts any
value expression in a VALUES list; fire-crab's was a fixed set of token
shapes, so `1e3`, `1+2`, `'A'||'B'`, `(5)`, `UPPER('x')`, `CAST('55' AS
INTEGER)`, `DATE '..' + 1`, `2.5 * 2`, `1 > 0`, `COALESCE(NULL, 3.25)` -
fourteen of sixteen probed engine-accepted forms - refused. The VALUES
list now splits at TEXT level (the paren- and quote-aware
`split_set_list`); the staged token shapes keep their arms (a parameter,
DEFAULT, the generators, a blob-bound string), and ANY other item parses
as an expression, resolves WITH NO COLUMNS, evaluates at plan (the query
side's own clock rule) and stages as `InsVal::Wire` through
`value_to_wireparam` - FACTORED OUT of the UPDATE expression tier, which
now calls the same mapping, so the two DML halves cannot drift. Folded
CASE/COALESCE/IIF/ABS/SQRT/TRIM, mixed `'a' || 5`, negative parens,
scaled and DOUBLE arithmetic, boolean comparisons and temporal
arithmetic all store what the engine stores, the engine reads fc's rows
line for line, and a NULL-answering fold stores NULL. **Found on the
way, fixed: the BOOLEAN WIRE ENCODING sent a big-endian int (value byte
LAST) where XDR opaque puts the value byte FIRST - every boolean OUTPUT
column read `<false>` at isql/libfbclient, `SELECT TRUE` included, while
WHERE and CAST were right; the engine read fc's STORED booleans
correctly all along (the writes were fine), and the patched node
driver's metadata-directed decode masked it in the node gates. The old
unit pin asserted the wrong form and was corrected; both dedicated
boolean gates and the sweep stay green.** An adversarial review (three lenses, live-verified) plus the author's
probes caught and fixed SEVEN more divergences: an UNTYPED fold whose
eval answered NULL (`'5' + 1` - the engine's "Strings cannot be added")
would have stored a silent NULL row - the INSERT arm refuses it, the
UPDATE expression tier gained the same type gate, and a `CASE ... ELSE
NULL END` stays typeable (an explicit NULL branch is now TRANSPARENT in
the conditional type, the engine's rule); TIME ± n arrived (the amount
is SECONDS, fraction kept, wrapping at midnight), DATE + TIME composes a
timestamp, and a TIMESTAMP ± n keeps the day FRACTION (TS + 0.25 shifts
six hours - fc's whole-day rounding there was a pre-existing wrong
answer in queries too); `TRUE || ''` spells TRUE; a DOUBLE fold into a
NUMERIC lands the .xx5 edge with the CVT epsilon (1.005e0 is 1.01); an
exact fold with extra fraction digits ROUNDS on the first dropped digit
half-away (the engine's adjustForScale - 1.005 into a NUMERIC(9,2) is
1.01, 1.0049 is 1.00; every wire parameter shares the rule); scaled and
approximate folds RENDER into text columns ('2.50', the 16-digit
double); a bare TRUE/FALSE literal into a text column spells TRUE/FALSE
(the '1'/'0' stays the client-bound-parameter rule); and a TRAILING
COMMA in a VALUES or SET list refuses (-104 there; the splitter's
dropped empty tail had it silently executing - the UPDATE side had that
hole before the slice). The stale `SELECT TM + 1` refusal pin in
serve-real-datemath was retired for a differential.
Boundaries (recorded): a
scalar-SUBQUERY value refuses (the engine answers it); a RAISING fold
(`1/0`) refuses at plan where the engine raises its typed 22012 at
execute, and an overflow/truncation fold the same way - the INSERT
vector family; a `?` inside an expression refuses (engine 07002); hex
literals and SQL COMMENTS inside a statement are pre-existing lexer
gaps (fc refuses `SELECT 64 /* c */` too - a comment-stripping slice is
a candidate); a blob-valued expression into a BLOB column refuses (the
plain string form works).

**Temporal values in DML - and the engine's WHOLE string-to-datetime
grammar - DONE (2026-08-24, `serve-real-temporaldml` 16):** until this
slice fire-crab could not put a DATE/TIME/TIMESTAMP value into a column
through its own wire in ANY form - typed literal, string, CAST,
CURRENT_DATE, every one refused, and every temporal fixture had to be
engine-built - while its text-to-temporal conversion knew ISO forms only.
The encoder side had been complete all along (WireParam::Date/Time/
Timestamp, record encode, index keys, wire parameters, column defaults);
the holes were the two DML literal parsers and the grammar. Now: INSERT
... VALUES takes temporal literals, strings, folded CAST constants, the
clocks (CURRENT_DATE, and CURRENT_TIME / CURRENT_TIMESTAMP - WITH TIME
ZONE values landing session-local through the zone's own displacement)
and LOCALTIME / LOCALTIMESTAMP, via new InsVal variants and a VALUES arm
that resolves a constant expression and accepts a temporal result; UPDATE
SET's string tier converts through the same encoder arm and its
expression tier gained the TZ clocks; INSERT ... SELECT carries temporal
columns (its per-row re-render now spells them as typed literals, value
exact); and `string_to_datetime` is CVT_string_to_datetime (cvt.cpp:677)
ported arm for arm - the three date components in any order decided by
the first token's shape (a 4-digit lead Y-M-D, a leading English month
M-D-Y, a middle one D-M-Y, a `.` separator D-M-Y, else M-D-Y), one
CONSISTENT separator from `/ - .` or whitespace, month names by
>=3-letter prefix, 2-digit years slid into the 50-year window, a missing
year defaulting to the current one, the specials NOW / TODAY / TOMORROW /
YESTERDAY (string coercion only - a typed literal refuses them, probed),
minutes-required times with at most 4 fraction digits, impossible dates
by round-trip, years 1..9999 - pinned by a 60-assertion unit battery of
measured vectors and shared by every consumer: DML strings, CAST from
text, and a text literal against a temporal column in a WHERE (so
`WHERE D = 'TODAY'` and `WHERE D = '15-JAN-2020'` now match, and a
date-only string compares against a TIMESTAMP as midnight). The
cross-type lattice is the engine's: TIMESTAMP truncates into DATE/TIME, a
DATE is midnight of a TIMESTAMP, a TIME lands dated TODAY (a new encode
arm); TIME-into-DATE and DATE-into-TIME refuse. `tz::displacement`
learned the UTC-family named zones (Etc/UTC = 0) and the fixed Etc/GMT+N
offsets (tzdata's inverted sign), which is what lets the session-zone
clocks convert - and un-bracketed TZ rendering ride along. Boundaries
(recorded): a bad string refuses with fc's GENERIC vector at INSERT where
the engine spells 22018 with the string (the shape every fc INSERT
conversion has - 'abc' into an INTEGER is the same; the CAST path is
typed); a trailing TIMEZONE in a string refuses where the engine converts
it (and junk after a fraction draws the engine's 22009 invalid-zone, fc's
22018); TIME/TIMESTAMP WITH TIME ZONE columns still take no DML values;
`DEFAULT DATE '...'` on a column refuses at CREATE TABLE (the string and
CURRENT_DATE default forms work and fill value-exact) and its BLR remains
undecodable at INSERT; a PSQL BODY's own INSERT of a temporal (an
EXECUTE BLOCK or procedure statement, literal or variable) refuses - the
body statement parser is the second parser the column-less-INSERT note
already records - all pre-existing. The clocks FOLD AT PLAN (the
query side's own model - CURRENT_DATE resolves to a literal): a PREPARED
INSERT re-executed across midnight keeps its plan-time clock where the
engine reads the clock per execute - the same recorded shape fc's
SELECT CURRENT_DATE already has under the statement cache.

**The LIST aggregate - and the first COMPUTED BLOB - DONE (2026-08-24,
`serve-real-list` 33):** `LIST([DISTINCT] arg [, separator])`, the
string-concatenation aggregate whose result is a TEXT BLOB the server itself
CREATES - the "computed-blob result fc cannot emit" that had blocked it. The
fold renders each non-null value to text (`Value::render`; a blob argument by
CONTENT through the blobcast reader; TRUE/FALSE for booleans; a CHAR column
padded to its declared CHARACTER count in the plain fold but to its full BYTE
image under DISTINCT - both measured) and mints a temp blob through a
thread-local mint context the connection loop arms per op and drains into
`Database::temp_blobs` at the top of the next op, ids floored at 0x40000000
so a client's own op_create_blob ids never collide; the row carries the
relation-0 id, and op_open_blob2 / op_info_blob / op_get_segment already
resolve those through temp_blobs, so the whole read side came free - the
segment structure byte-exact (each value and each separator its OWN segment,
an empty piece writing none, type 0 segmented, the engine's counts). The
separator (default `,`) is evaluated PER ROW and appended before each value
after the first; a NULL separator at any append - or a NULL constant - marks
the WHOLE result NULL (aggPass: dsc_dtype = 0); DISTINCT sorts and dedupes
the values, its separator evaluated with the group's last row current
(measured). The describe: BLOB sub_type 1, Nullable, named LIST, charset =
the ARGUMENT's (a text column its own, a text expression the first text
column it references, a bare literal or numeric NONE - all measured).
WITHIN A GROUP the tie order is the engine's grouping sort, which compares
its WHOLE sort record (sort.cpp `quick(n, j, m_longs)` runs over every
native ULONG of [diddled keys][per-field null flags][referenced fields in
field order]): fc reproduces the measured grain - ties follow the OTHER
REFERENCED fields in field order (a field referenced only in the WHERE
included, an unreferenced one excluded), a NULL in a referenced field sinks
its row, a VARYING value compares by its count word first ('b','c','aa') and
then by 4-byte words whose LAST byte dominates ('ba','ca','ab'), an INTEGER
value as one UNSIGNED word (1, 256, -5) - while over a JOIN the join's
delivery order holds (measured; fc's join row order already matches), and a
DERIVED table, CTE, UNION source or VIEW flattens into the SAME record (a
bound fold with no join parts tie-orders; a real join's does not). An
adversarial review (three lenses, every finding verified against the live
engine) and the author's own probes caught SEVEN real divergences
pre-commit, all fixed: the tie extension first sorted by ALL fields where
the engine sorts by REFERENCED ones; CHAR padding was byte- where the plain
fold is character-count; the NULL flags, unsigned-int words and vary count
word of the tie grain; the derived/CTE/UNION/view fold left in delivery
order; `LIST(DISTINCT <blob>)` deduped by CONTENT where the engine keys the
DESCRIPTOR (equal content never dedupes, id order) - now refused;
`LIST(DISTINCT <collated>)` deduped binary where the engine dedupes by the
collation key - now refused; and the segment split was 65535 where
BLB_put_data splits at 32768. Boundaries (recorded): LIST inside an
EXPRESSION (`CHAR_LENGTH(LIST(..))`, a HAVING comparison), in a scalar
SUBQUERY or a DERIVED-table projection, the window OVER () form, and
`INSERT ... SELECT LIST(..)` refuse where the engine answers; the malformed
shapes (three arguments, `LIST(*)`) refuse with fc's generic vector where
the engine spells -104; the tie order's word-granular corners
(multi-text-field packing, a derived source's own WHERE fields, a reordered
or computed derived projection, a collated or blob-id tie field) are
unpinned; a blob id opened after its transaction ends degrades to the empty
blob rather than the engine's invalid-id error.

**The ordered-set aggregates PERCENTILE_CONT / PERCENTILE_DISC DONE
(2026-08-24, `serve-real-percentile` 6):** the inverse-distribution
aggregates `PERCENTILE_x(fraction) WITHIN GROUP (ORDER BY expr [ASC|DESC])`
- fc's first WITHIN GROUP form. Each collects the non-null ORDER BY values,
sorts them, then PERCENTILE_CONT interpolates between the two bracketing the
rank 1 + fraction*(n-1) and answers a DOUBLE (the rank and each
interpolation term fused into multiply-adds to match the engine's
`-ffp-contract=fast` to the last bit), while PERCENTILE_DISC picks the value
at 1-based position ceil(fraction*n) (at least 1), KEEPING its exact type
(its `make()` copies the ORDER BY descriptor - a NUMERIC(9,2) result stays
LONG scale -2 sub_type 1, a scaled expression keeps sub_type 1, a VARCHAR
VARYING). Both are nullable - NULL over an empty / all-null group and for a
NULL fraction; a NULL ORDER BY value drops from the set; DESC reverses. The
WITHIN GROUP clause is parsed by `parse_percentile_item`, carried through new
`AggTarget::Percentile` / `AggSrc::Percentile`, folded in `compute_group`
(`percentile_result`). An out-of-range non-null fraction raises the engine's
DSQL error ("... in the range [0, 1]", primary "Dynamic SQL Error" via a new
`EvalErr::DsqlDomain`). An adversarial review found three byte-exactness
defects, all fixed: the interpolation missed the FMA contraction (now
`mul_add`); a scaled-NUMERIC EXPRESSION order described sub_type 0 not 1; and
a NULL fraction erred instead of answering NULL. Boundaries (recorded): a
DECFLOAT / INT128 ORDER BY; PERCENTILE_CONT over a NON-numeric ORDER BY (the
engine oddly answers NULL, fc refuses); more than one sort item; the FILTER
form and a percentile inside an expression. MODE is not an engine function;
LIST arrived in the next slice (the computed blob with it).

**The two-argument statistical aggregates CORR / COVAR / REGR family DONE
(2026-08-24, `serve-real-statagg2` 8):** the linear-correlation, covariance
and linear-regression aggregates - CORR, COVAR_POP, COVAR_SAMP, REGR_SLOPE,
REGR_INTERCEPT, REGR_COUNT, REGR_R2, REGR_AVGX, REGR_AVGY, REGR_SXX,
REGR_SYY, REGR_SXY. Each folds n and the five paired sums (Sx / Sxx / Sy /
Syy / Sxy) over the rows where BOTH arguments are non-null (the FIRST SQL
argument is Y, the SECOND X, per the standard and the engine's CorrAggNode /
RegrAggNode), then answers from the engine's closed formula (`stat2_result`)
folded in f64 in the SAME operation order so the DOUBLE bits match - over
DOUBLE, INTEGER and NUMERIC operands, whole-table and grouped, with the
FILTER (WHERE ...) form. The result is DOUBLE (BIGINT for REGR_COUNT), and
the engine DESCRIBES every one NOT nullable though they CAN be NULL at run
time (an empty or single-row group, a zero variance) - a NULL travels on a
not-nullable column and renders as 0; fc matches both. New plumbing:
`AggTarget::Pair` / `AggSrc::Pair`, `split_top_comma2`, and the four
duplicated inline aggregate-name matches folded into `AggFn::name()`. An
adversarial review (each dimension verified against the live engine) found
three byte-exactness defects, all fixed: a scaled-NUMERIC operand converted
by multiply-by-reciprocal (raw * 0.01) where the engine's CVT DIVIDES (raw /
100.0) - now `exact_to_f64`; and REGR_INTERCEPT's `avgY - slope*avgX`, which
the engine compiles as a fused multiply-add - now `mul_add`, so the last bit
agrees. Boundaries (recorded): a DECFLOAT / INT128 operand (decimal128
domain, fc refuses); these folds inside an EXPRESSION (CASE / COALESCE / a
comparison / a scalar subquery / a window OVER) refuse, the same
top-level-select-item limit VAR / STDDEV carry. MODE is not an engine
function (probed -104); PERCENTILE_CONT / PERCENTILE_DISC (ordered-set) and
LIST (a computed-BLOB result) followed as their own slices - both done.

**The EXACT-rounding family CEIL / CEILING / FLOOR / ROUND / TRUNC DONE
(2026-08-24, `serve-real-rounding` 28):** the last of the common numeric
SysFns, and the first EXACT-numeric ones whose result FORM (dtype width,
scale and NUMERIC sub_type) the engine DERIVES from the operand - the piece
that had blocked them. CEIL / CEILING / FLOOR promote the operand's storage
one dtype step (SMALLINT -> INTEGER, INTEGER / BIGINT -> BIGINT, INT128
stays), scale 0, sub_type 0, the way makeCeilFloor's makeLong / makeInt64 /
makeInt128 do. ROUND / TRUNC copy the operand descriptor (dtype AND sub_type
kept); a one-argument call forces scale 0, a two-argument call keeps the
operand scale and rounds to n decimal places (ROUND(3.14159,2) is INT64
scale -5, value 3.14000; ROUND(1234.5,-2) is scale -1, 1200.0). A literal
NULL operand answers INTEGER (makeLong). An APPROXIMATE operand answers
DOUBLE: CEIL / FLOOR are exact on the double, ROUND follows evlRound's CVT
(d * 10^-s, add 0.5 + eps with eps = 1e-14 double / 1e-5 float, truncate) so
the .x05 binary-representation cases land the decimal way (ROUND(1.005e0,2)
= 1.01), TRUNC follows evlTrunc's modf; CEIL / FLOOR / TRUNC additionally
string-convert a TEXT operand to DOUBLE (CEIL('3.2') = 4.0), while ROUND
refuses text. ROUND rounds half AWAY from zero, TRUNC toward zero; the exact
arithmetic is in i128 (`rounded_q` + `RndMode`), so a NUMERIC(30) operand
keeps its INT128 result. A non-integer places argument is accepted (rounded
to a whole count, as MOV_get_long does). The describe was threaded through
`result_width_bytes`, `result_scale`, `numeric_subtype` and `rank_of`, with
a polymorphic `type_of`. An adversarial review (3 dimensions, each verified
against the live engine) found FOUR defects, all fixed and re-verified: the
double .x05 rounding (evlRound's eps), a non-integer places argument, a
BIGINT round-up raising integer- rather than numeric-overflow, and CEILING
folding its column name to CEIL (a distinct `SysFn::Ceiling`). Boundaries
(recorded): a DECFLOAT / INT128 operand (engine computes it in the
decimal128 domain), ROUND(text) and wrong-arity messages (fc refuses
generically), and a FLOAT operand (engine keeps FLOAT; fc widens to DOUBLE,
its general approximate-EXPRESSION policy). With this the common
numeric-function surface (transcendental + bitwise + exact-rounding) is
complete.

**The DOUBLE-precision math cluster DONE (2026-08-24, `serve-real-math`
39):** the transcendental built-ins that answer a 64-bit float join the
SysFn machinery - SQRT, POWER, EXP, LN, LOG10, LOG(base,x), PI() (a
zero-argument constant, needing an empty-parens parse), the trig SIN / COS
/ TAN / COT / ASIN / ACOS / ATAN / ATAN2, and the hyperbolic SINH / COSH /
TANH. Each folds its operands to f64 (`fn_f64`, `exact_to_f64` for exact
operands) and calls Rust libm, which on this glibc host answers bit-for-bit
what the engine's C libm answers - the 17-digit DOUBLE matches to the last
place over literals, INTEGER / NUMERIC / DOUBLE columns, nesting and a WHERE
predicate; result DOUBLE (sqltype 480, `ExprType::Approx`), NULL propagates.
The domain / range / overflow errors match byte for byte: SQRT of a
negative, LN / LOG10 / LOG-value <= 0, LOG base <= 0, ASIN / ACOS outside
[-1,1], COT(0) raise `expression_eval_err` with the function name
(`EvalErr::MathDomain`); POWER(0, negative) -> `sysf_invalid_zeropowneg`
and POWER(negative, non-integral) -> `sysf_invalid_negpowfp` (an
APPROXIMATE exponent counts as non-integral, mirroring evlPower's
`!isExact()`); an infinite result raises float overflow - EXP / POWER the
plain `exception_float_overflow` (22003), SINH / COSH the NAMED
`sysf_fp_overflow` ("... in built-in function @1") via a new
`EvalErr::MathOverflow`; a TEXT operand converts to double by the numeric
grammar (SQRT('4') = 2.0), raising 22018 with the raw string when it is not
a number. **A DOUBLE-store bug fixed beside them:** `encode_wire_value`'s
WireParam::Int -> DOUBLE/REAL arm was guarded `if ws == 0`, so a fractional
literal (2.5 arrives as Int(25, ws=-1)) refused and the INSERT silently
stored NO row (found pre-existing on clean HEAD, `SELECT` of any stored
DOUBLE returned only the NULL rows); it now converts the whole magnitude
with `exact_to_f64`, byte-exact vs the engine for DOUBLE and FLOAT. An
adversarial review (4 dimensions, each verified against the live engine)
confirmed six defects - the POWER domains, the two overflow vectors and the
text operand, all fixed - plus a sixth kept as a **boundary: a DECFLOAT or
INT128 operand**, which the engine computes in the decimal128 domain to a
34-digit DECFLOAT, is REFUSED (fc's decfloat module is add/sub/mul/div/round
only - no decimal128 transcendentals; a separate slice). The exact-rounding
family CEIL / CEILING / FLOOR / ROUND / TRUNC is also a separate slice (its
result scale, integer width and NUMERIC sub-type the engine derives from the
operand - `int_func_form` carries neither scale nor sub-type yet).

**More SysFn scalar functions DONE (2026-08-24): ASCII_VAL(s)
(`serve-real-asciival` 3, the SMALLINT first-byte code), HASH(s)
(`serve-real-hash` 3, the engine's default WeakHashContext - a 64-bit
ELF-style rolling hash, ported byte-for-byte), and a text BLOB's CHARACTER
SET now reaching the catalog + describe (fixed `serve-real-blobfilter`).**
Boundaries: ASCII_CHAR(128..255) and OVERLAY need fc's byte-carrier
CHAR-width handling; the DOUBLE math functions (POWER / SQRT / LOG / ROUND /
CEIL / FLOOR / TRUNC) need f64 arithmetic the executor lacks.

**Bitwise functions BIN_AND / BIN_OR / BIN_XOR / BIN_NOT / BIN_SHL / BIN_SHR
DONE (2026-08-24, `serve-real-bitwise` 6):** the bitwise built-ins in the
SysFn scalar machinery - AND/OR/XOR variadic (2+), NOT unary, the shifts
arithmetic (sign-preserving). Integer in, integer out, folded in i128 so a
wide operand keeps its magnitude. The result TYPE follows the engine off the
expression's NumRank (AND/OR/XOR/NOT floor at INTEGER, the shifts at BIGINT,
either widening to INT128), so the describe matches byte for byte over
literals and columns. An adversarial review caught two INT128 defects (an
i64-truncating fold and a BIGINT-capped describe) plus a shift case it missed
- all fixed. Boundaries: a scaled-NUMERIC / text / NUMERIC(p,0) operand
refuses (fc generic vs the engine's "must be integral types"); a call inside
a PSQL body refuses at CREATE (query surface only). The DOUBLE-valued math
functions (POWER / SQRT / LOG / PI / ROUND / CEIL / FLOOR / TRUNC) stay
refused - the executor has no f64 arithmetic.

**NUMERIC in a FUNCTION signature DONE (2026-08-23, `serve-real-numfunc`
6):** a plain function with a NUMERIC(p,s) param and/or return now loads,
describes from its return descriptor (exact dtype/scale, `RDB$FIELD_SUB_TYPE
1`), binds a scaled/integer/text argument to the parameter's scale
(rescaling half-away, raising 22003 past the width, 22018 on a bad text),
computes through the exe scaled arithmetic, and coerces the result to the
return. `load_function` gate relaxed to `is_numeric_col`; `dsc_to_meta`
now writes sub_type 1 for a scaled param; `run_function` coerces its
result to the return scale (the source-interpreter fallback did not).
Boundaries (recorded): NUMERIC(19-38)/INT128 in a signature — the CREATE
FUNCTION DDL refuses it; DOUBLE/approx — the executor has no f64
arithmetic. NUMERIC in a PROCEDURE signature is a follow-up
(`load_procedure` unchanged; needs the proc output-column describe path).

**NUMERIC in a PROCEDURE signature DONE (2026-08-23, `serve-real-numproc`
8):** the follow-up above — a stored procedure with NUMERIC(p,s) params
and/or RETURNS columns now loads, over both the selectable path
(`SELECT ... FROM P(...)`) and `EXECUTE PROCEDURE`. The describe path
(`proc_out_col` → `wire_for`) already emitted the exact dtype/scale/subtype,
and `bind_proc_args` already rescaled a numeric argument to the parameter's
scale (22003 past width); the two missing pieces were the `load_procedure`
gate (relaxed to admit `is_numeric_col`, like `load_function`) and a
decimal literal in the call arguments — `parse_call_args` read NULL /
integer / `'text'` / `?` but a bare `10.55` fell through and refused the
whole statement. It now parses a decimal literal through the engine's
`text_number` grammar to a `Value::Scaled` (an over-i64 mantissa to
`Value::Int128`); a scientific literal with a positive exponent (`1.5e2`
= 150, which the engine accepts as an argument) folds the exponent into
the mantissa at scale 0, and a hex literal is not taken here.
Verified over numeric-literal / text / negative args, INT→NUMERIC, a
NUMERIC SUSPEND loop, division widening the scale, EXECUTE PROCEDURE, the
22003-past-width vector, and the subtype-1 describe — the ENGINE runs the
BLR fc stored. Boundaries carried from the function slice: NUMERIC(19-38)
/ INT128 in a signature refuses at the CREATE DDL; DOUBLE/approx has no
exe f64 arithmetic.

  `parse_call_args` is shared by every procedure-call site, so an
  adversarial review flagged that the new decimal arm also carries a
  decimal literal into an EXISTING INTEGER/TEXT-parameter procedure —
  where fc used to refuse the whole statement at prepare, and where the
  engine's CVT actually answers. Rather than restore the refusal, the
  binding now MATCHES the engine: `bind_proc_args` rounds an exact-numeric
  argument half-away into an INTEGER parameter (22003 past its width) and
  renders it into a text parameter (`render_exact` — `|scale|` fractional
  digits, trailing zeros kept, a leading `0`, no point at scale 0 — then
  CHAR-padded), and `proc_blr_offset` counts a `<=9`-digit-mantissa decimal
  literal as a LONG so the non-selectable-procedure `-104` offset stays
  byte-exact. So `SELECT * FROM PI(1.5)` now answers `2` and `PT(1.50)`
  answers `1.50`, as they do on the engine.

**Raising a user EXCEPTION from a FUNCTION body DONE (2026-08-23,
`serve-real-fnexc` 5).** A procedure body already raised a named exception
byte-for-byte — the shared PSQL source interpreter (`run_body_source`)
builds the engine's own vector (number, quoted name, message) — but a
FUNCTION hit the same `EXCEPTION E_NEG` and the select-list caller
collapsed EVERY error from the source fallback to `EvalErr::Unsupported`
(a generic "Dynamic SQL Error"), discarding the `ProcErr`'s status. The
caller now surfaces that status (`e.status.unwrap_or(Unsupported)`), so a
raise from a function answers exactly what it answers from a procedure;
only a genuine "cannot run this body" (status `None`) stays Unsupported.
A one-line change. Catching a raise inside a function (a `WHEN ANY` block)
already worked — it happens inside the interpreter before the result
returns. As with every fc raise, the per-level `At function` stack frame
is omitted (the recorded fc-wide boundary; the exception identity is
byte-exact). Boundary still refused at CREATE (dsql does not
compile it): `EXCEPTION <name> <message-override>`. (`WHEN EXCEPTION
<name> DO` handlers DO compile and run — see the next entry.)

**PSQL exception handlers, multi-condition compile DONE (2026-08-23,
`serve-real-whenexc` 5).** A `BEGIN..END` block with `WHEN ... DO` handlers
was already interpreted (the source interpreter's block AST carries a
`Vec<HandlerCond>` per handler and splits the `WHEN` list on the comma) and
single-condition handlers compiled fine — so `WHEN EXCEPTION <name>`,
`WHEN GDSCODE`, `WHEN SQLCODE`, `WHEN ANY` and nested handlers all worked
in procedures and functions (the fnexc entry's "only WHEN ANY compiles"
note was wrong and is corrected above). The one lag was in the dsql
COMPILER: it read a single condition per `WHEN` and emitted a hard-coded
`blr_error_handler` code-count of 1, so a MULTI-CONDITION handler
(`WHEN EXCEPTION A, EXCEPTION B DO`) refused at CREATE. dsql now parses the
comma list and emits the real count with each code in order; the ENGINE
runs the BLR fc stored (a handler mixing `EXCEPTION` and `GDSCODE` catches
both). Gate serve-real-whenexc, 5 checks, byte-for-byte incl the
engine-runs-fc's-BLR check. An adversarial review caught a real
create-then-run inconsistency: `WHEN ANY` may also appear INSIDE a comma
list (`WHEN ANY, EXCEPTION E`), which the engine accepts and runs as a
catch-all — dsql compiled it (the engine even ran the BLR) but fc's own
source interpreter refused it at fetch, so fc stored a procedure it could
not itself run. The interpreter now treats `ANY` anywhere in the list as
catch-all (an empty condition list), matching the engine (a raise of an
exception NOT in the explicit list is still caught). Boundary still refused at CREATE: a user-function
CALL in a body statement (`R = F(A)` — the body's expression surface is
arithmetic-only, a separate pre-existing gap).

**Re-raise `EXCEPTION;` inside a handler DONE (2026-08-23,
`serve-real-reraise` 7).** A bare `EXCEPTION;` re-raises the caught
exception, identity intact. The source interpreter already had the node,
but the dsql compiler required a name after `EXCEPTION` and refused a bare
one. Probed from the engine's stored BLR, a re-raise is `blr_abort, 5`
(condition 5 = blr_raise, no name) where a named raise is `blr_abort, 2,
len, name`; dsql now emits it and the ENGINE runs the BLR fc stored. Two
engine semantics — each a create-then-run trap the moment CREATE started
accepting the statement — were probed and matched: (1) a re-raise with
NOTHING live (at the top of a body, or after a handler completed) is a
NO-OP, not an error — the interpreter's `Reraise` None arm now returns
`Ok(())`; (2) `f.caught` is CLEARED after a handler body, never restored to
an outer level, so a re-raise reached after a NESTED inner handler no-ops
rather than re-raising the outer exception (probed: PN_AFTER answers 99),
while a re-raise BEFORE any inner block still re-raises the outer one. The
old code did the opposite (restored the outer) and its comment wrongly
claimed the engine refuses a bare `EXCEPTION;` at compile — both corrected.
A follow-up closed the trigger side too: `serve-real-trigreraise`
(4 checks). A TRIGGER re-raise compiles through the server's OWN BLR
emitter (`emit_trigger_stmt`, not dsql); `Reraise` was removed from both
the `body_has_uninterpretable_blr` refusal list and the emitter's
interpreted-only group, and a new arm emits `blr_abort, 5` with the same
savepoint bracket a named raise takes in a handler-bearing block. fc does
not itself execute user triggers (it refuses DML on a triggered table),
so the check is compile parity plus the ENGINE firing fc's stored trigger
BLR: a good INSERT succeeds, a bad one re-raises `E_NEG`, one row kept; a
top-level `EXCEPTION;` (unbracketed) no-ops. The exception surface —
raise, catch (all condition kinds, single/multi/nested/ANY-in-list),
re-raise — is now closed for procedures, functions AND triggers.

**EXCEPTION `<name>` `'<literal>'` message override DONE (2026-08-23,
`serve-real-excmsg` 5).** A raise may override the exception's catalog
message with a literal. Probed from the engine's stored BLR: a plain named
raise is `blr_abort, 2, name`; an override is `blr_abort, 6, name` then a
`blr_literal blr_text2` (charset 0, u16 length). Both the dsql compiler and
the server's trigger emitter emit it; the source interpreter uses the
literal in the raised vector (`message.unwrap_or(catalog_message)`), and the
ENGINE runs the BLR fc stored — procedures, functions, a trigger fired on
INSERT, and a doubled-quote message. Boundaries (recorded): an EXPRESSION
(`'v='||A`) or `USING` message refuses (the body expression surface is
arithmetic-only; the engine accepts them, fc will not guess); a message
past fc's ~32000-byte string-literal cap refuses (pre-existing, below the
engine's, so the u16 length field never overflows); a NON-ASCII message
renders mojibake in fc's OWN execution — a pre-existing fc-wide
exception-message encoding issue a plain catalog message shares, and fc
stores the correct bytes so the engine reads it right. The last body-PSQL gap — a
user-function call in a statement — is closed next.

**A bare PLAIN user-function call in a body DONE (2026-08-23,
`serve-real-bodyfn` 8).** `R = DBL(A)`, `RETURN F(A) + 1`. A plain call
compiles to `blr_function` (0x64) — counted name, a u8 arg count, the
arguments (probed from `RDB$FUNCTION_BLR`; distinct from the packaged
`blr_function2`). exe gained `blr_function` (an empty package resolves the
plain function, the slot a bare sibling takes, so its existing recursive
executor runs it); dsql binds a bare name against the catalog's plain
functions (passed from the server via `compile_*_with_funcs`), and a
function's own signature is added so a RECURSIVE self-call resolves.
Verified: call / nested (`DBL(DBL(A))`) / multi-arg / IF-condition /
recursion (`FACT`), fc running its own and the ENGINE running fc's BLR;
arity-mismatch and unknown-name refuse on both. Several create-then-run / create-mismatch
issues were probed against the binary and fixed: a body that BOTH calls a
function AND draws a GENERATOR is REFUSED at CREATE — the call needs exe,
exe declines a generator, and the source interpreter cannot call a
function, so fc refuses rather than store BLR it could not run (a clean
boundary, not a create-then-run split; the engine accepts it, a deliberate
divergence); an adversarial review then CONFIRMED a further one — `ALTER`
and `CREATE OR ALTER PROCEDURE` compiled the body with no catalog
(`&None`), so a function call refused there while a plain `CREATE` accepted
it; `plan_alter_procedure` now threads the db through. A RECREATE that
changes a function's arity uses the new signature for a self-call, and
`function_self_sig` masks string literals when counting the arity. Boundary: recursion past fc's depth guard (48) refuses where the
engine goes ~1000 then 54001 — the recorded stand-in the function-call
slices carry.

**ALTER FUNCTION / CREATE OR ALTER FUNCTION DONE (2026-08-23,
`serve-real-alterfunc` 6).** fc had `plan_alter_procedure` but no function
equivalent, so both refused entirely while the engine accepts them.
`plan_alter_function` mirrors the procedure planner — rewrite the head to
CREATE, compile via `plan_create_function` (WITH the catalog, so a body
function call resolves), repackage as `Plan::AlterFunction` /
`CreateOrAlterFunction`; the execution drops the function and restores it
with the same `RDB$FUNCTION_ID` preserved (`function_id_plain`), a CREATE
OR ALTER of a new name just creates. The failed-DDL vector is byte-exact
(`ALTER FUNCTION @1 failed` 336397261 / `Function @1 not found` 336068649).
Verified: ALTER then CREATE OR ALTER an existing function, CREATE OR ALTER
a new one, a body that calls another function, a recursive CREATE OR
ALTER, and the not-found vector; the ENGINE runs fc's altered functions.
Boundary carried from the body-call slice: a CREATE OR ALTER whose body
BOTH calls a function AND draws a generator refuses at compile (`exe_can_run`
fires through this path too). CREATE / RECREATE FUNCTION unaffected. An adversarial review
caught a real high-severity bug: `drop_function` (shared with DROP FUNCTION)
found the plain function package-aware but DELETED by name alone, so ALTER
(or DROP) of a plain `F` clobbered a coexisting packaged `PKG.F`'s catalog
rows. `drop_function`'s deletes are now package-aware (plain rows only),
fixing the ALTER path AND the pre-existing DROP FUNCTION bug. The same
package-blind pattern was then found and fixed in `drop_procedure` /
`procedure_id` (a targeted bug hunt): ALTER / DROP of a plain procedure had
likewise clobbered a coexisting packaged member; both are now plain-only
(gate `serve-real-plainpkgdrop`, covering procedures and functions).

**COMMENT ON PROCEDURE / FUNCTION DONE (2026-08-23, `serve-real-commentroutine`
6).** COMMENT ON handled TABLE/COLUMN/INDEX/SEQUENCE/EXCEPTION/ROLE/DOMAIN/
DATABASE but not a routine; both refused while the engine accepts them. The
planner's kind list and the ods `CommentTarget` gain Procedure/Function,
writing (or clearing on `IS NULL`) the PLAIN routine's RDB$DESCRIPTION - the
plain row only (RDB$PACKAGE_NAME NULL), never a packaged member of the same
bare name (verified: the comment lands on plain F, the member stays NULL).
The gbak-restore path already mapped routine descriptions, so a comment
survives a round-trip. Boundary (shared by ALL comment targets, pre-existing):
the not-found vector is fc's generic refusal, not the engine's byte-exact one.

**DEFAULT parameters on a PROCEDURE DONE (2026-08-23, `serve-real-procdefault`
7).** `A INTEGER DEFAULT 5`, `A INTEGER = 7`, `A VARCHAR(5) DEFAULT 'hi'`,
`DEFAULT -3`. dsql parses a LITERAL default (integer optionally signed,
string, NULL) in the input list, keeping the exact `DEFAULT`/`=` form;
`proc_default_of` turns it into the stored RDB$DEFAULT_SOURCE (verbatim) and
RDB$DEFAULT_VALUE BLR (the column-default helpers - byte-exact vs the engine:
`05 15 08 00 <i32> 4c` for an int, `blr_text2` for a string); load_procedure
decodes RDB$DEFAULT_VALUE into ProcParam.default, and `with_proc_defaults`
fills an omitted TRAILING argument at every call path (selectable,
run_body_source, try_procedure_blr) before the arity check, the value flowing
through bind coercion (an int default into a NUMERIC parameter rescales; a
NULL default fills NULL). Defaults must be trailing (a plain parameter after a
defaulted one refuses, as the engine does); a call missing a REQUIRED
parameter gives the byte-exact `Parameter mismatch`.

**CONTEXT / keyword parameter defaults DONE (2026-08-24,
`serve-real-ctxdefault` 9).** `DEFAULT CURRENT_USER` / `USER` /
`CURRENT_ROLE` / `CURRENT_CONNECTION` / `CURRENT_DATE` / `CURRENT_TIME` /
`CURRENT_TIMESTAMP` - resolved PER CALL, not a fixed literal. dsql's default
parser takes the keyword, `proc_default_of` stores the engine's own keyword
BLR (byte-identical incl the date/time forms) + verbatim source; a
`ProcParam` carries the UNEVALUATED context form (`default_ctx`) apart from a
literal value, and `with_proc_defaults(ctx)` resolves it per call from the
session (`eval_ctx_default`: the login upper-cased, role NONE, the
attachment id, the clock) wherever a ctx is in reach - the source path
(EXECUTE PROCEDURE, a selectable procedure at execute) and the select-list
function fill. The ctx-less BLR fast paths leave a context default short so
the call falls to the source path; the selectable-procedure PLAN path accepts
a context-default shortfall for the execute-time fill. `required` counts
inputs with neither a literal nor a context default. Verified byte-for-byte
incl the catalog + BLR, fc serving the login/role forms, provided-arg-wins,
the byte-exact missing-required vector, the ENGINE running fc's file, and the
literal->context->literal mix; a three-lens adversarial review found no
defects. Boundaries (recorded): a DATE/TIME/TIMESTAMP-typed routine BODY is
not one fc's arithmetic source interpreter runs (a pre-existing gap,
orthogonal), so fc stores those context defaults and the ENGINE reads them
but fc does not itself serve the fill; CURRENT_CONNECTION is self-referential
(fc's own attach id); a PSQL BODY call omitting a context-defaulted argument
refuses (exe has no context opcode); CURRENT_TRANSACTION and the LOCAL* forms
refuse at CREATE.

**DEFAULT parameters on a FUNCTION DONE (2026-08-24, `serve-real-funcdefault`
11).** The same literal defaults, now on `RDB$FUNCTION_ARGUMENTS`: the dsql
func refusal is gone, `plan_create_function` stores RDB$DEFAULT_SOURCE /
RDB$DEFAULT_VALUE (the same helpers), `load_function` reads it back, and -
because a function in a select list is arity-checked at query-compile, not at
runtime - `user_function_sigs` now reports the REQUIRED arity (inputs without
a default) as a 3-tuple `(Descriptor, arg-names, required)`, so the
`RawExpr::UserFn` check relaxes to `args.len() ∈ [required, params.len()]`
and `try_function_blr` fills the omitted tail with `with_proc_defaults`. A
missing required argument is the byte-exact `Parameter <n> has no default
value`, a surplus is `wrong number of arguments`. A `> i32` default refuses
at CREATE (as on the procedure/column paths). Removing the dsql refusal also
let a PACKAGE member parse a default, so the package writers were reconciled
with the engine's rule that a default lives on the header DECLARATION, never
in the body DEFINITION of a previously declared member: `create_package_body`
refuses ANY body-member default - procedure or function, encodable or not
(the source presence rides `proc_param_of` / `fn_arg_of` through a sentinel
so a `> i32` body default cannot slip past) - with the engine's byte-exact
DYN `dyn_defvaldecl_package_{proc,func}` vector (SQLERR 336397295 "CREATE
PACKAGE BODY @1 failed" then DYN 336068875/336068898 "...previously declared
packaged {procedure,function} @1.@2"); and `plan_create_package` refuses a
HEADER declaration carrying a default rather than store a catalog it cannot
preserve. An adversarial-review workflow found three real defects pre-commit
(the packaged-header wrong-catalog, the `> i32` body-default split, the
packaged-body accept-where-engine-rejects) - all fixed and gated. Boundaries
(recorded): packaged routine parameter defaults (header storage + preserving
the default across the body re-write, both of which the live engine does) and
non-literal / context defaults still refuse.

**Packaged routine HEADER parameter defaults DONE (2026-08-24,
`serve-real-pkgdefault` 7).** A DEFAULT on a packaged routine's HEADER
declaration - the canonical place the engine keeps it (a body default is the
-607 error, already refused). `plan_create_package`'s conv/fnarg header
closures now carry the literal default (the function return never gets one),
an un-encodable `> i32` refuses the CREATE, and create_package's declaration
writers store `RDB$DEFAULT_SOURCE/VALUE`. `create_package_body` PRESERVES it
across the member re-write: the body re-declares members without a default,
the re-write deletes and recreates each member's parameter rows, so new
`carried_member_defaults` reads the header's stored defaults (package-aware,
by parameter name) and re-applies them onto the fresh rows. The fill paths
need nothing new - an external call (a packaged function in a select list or
a body, a packaged procedure via EXECUTE PROCEDURE) resolves the default
through the same catalog-driven, package-aware machinery a plain routine
uses. Verified byte-for-byte incl the defaults surviving in BOTH catalogs,
cross-member scoping (a same-named parameter on another member is not
polluted), and all call forms. Boundary (recorded): a package body member's
UNQUALIFIED sibling call cannot omit the sibling's defaulted tail - the
header's required arity is not reliably visible at body-COMPILE (fc's
plan-time catalog is stale for same-connection DDL, and a header-only
declaration has no BLR for load_function); an external call fills fine.

**Omitted-default body function calls DONE (2026-08-24, `serve-real-bodydefault`
6).** `RETURN FA(X)` where `FA(B, A DEFAULT 5)` now works from inside a
routine body, as it already did in a select list. The engine LATE-BINDS - it
stores `blr_function` with only the arguments passed (a 1-arg call for
`FA(X)`) and fills the defaulted tail from the callee's catalog at run time,
NOT inlining the default at compile time - so fc matches on both sides: dsql
carries `plain_funcs` as `(name, total, required)` and relaxes the body-call
arity to `[required, total]`, emitting a short call whose BLR is
byte-IDENTICAL to the engine's; and exe's `Expr::Function` reads the callee's
input arity from its parsed BLR (message 0, two slots per param) and, when
the call passed fewer, fills the trailing args from
`RDB$FUNCTION_ARGUMENTS.RDB$DEFAULT_VALUE` (`function_arg_defaults` +
`parse_default_expr`, reusing the literal/blr_null parser), coerced like a
passed arg. So fc SERVES the same answer and the ENGINE runs fc's file
identically. Verified byte-for-byte incl the all-defaulted (0-arg),
zero-input, nested-call, string- and two-default edges, and a procedure body.
A three-lens adversarial review found no defects. Boundaries (recorded): a
wrong-arity body call refuses GENERICALLY (Dynamic SQL Error) vs the engine's
07001 Parameter mismatch (the pre-existing shape for all body-call arity
failures, fail-safe); a function omitting its OWN defaulted argument in a
recursive self-call refuses (self-sig required == total).

**The IF statement (blr_if) in exe DONE (2026-08-23, `serve-real-psqlif`
5):** the executor could not convert an IF, so a body combining IF/ELSE
control flow with an exe-only feature (a NUMERIC computation, a function
call, recursion) fell to the source path and refused. exe now runs blr_if
(condition, then, optional else — a missing else is a bare blr_end; a NULL
condition takes the else, as the engine does). This unlocks recursive
functions (`FACT` = IF base case + a sibling call), IF-guarded NUMERIC
bodies, and IF inside a FOR loop with LEAVE. A clean review (no defects).
Boundary: fc refuses recursion past its guard (48) where the engine
handles ~1000 then raises 54001 — the source interpreter's
`psql_depth_guard` stand-in, unchanged.

**WHILE loops (blr_loop / blr_continue_loop) in exe DONE (2026-08-23,
`serve-real-psqlwhile` 5):** exe could not convert a loop, so a WHILE body
combining loop control with an exe-only feature (a NUMERIC accumulator, a
function call) fell to the source path and refused. exe now runs blr_loop
and blr_continue_loop: a blr_label folds into the loop (or FOR) it wraps so
LEAVE ends it and CONTINUE moves to the next iteration; a FOR SELECT
loop's CONTINUE goes to the next row, not out of the loop (`Stmt::For`
gained an optional label). Verified over WHILE+NUMERIC, WHILE+CONTINUE,
nested WHILE with a labelled LEAVE/CONTINUE to an OUTER loop (3 levels),
and a WHILE whose body calls a function — a clean review (no defects), and
`serve-real-loopctl` now runs its bare/labelled control procedures through
exe. Boundary: an infinite loop hangs, as it does on the engine (no
iteration cap, consistent with the source interpreter).

**Function calls inside a body (blr_function2) DONE (2026-08-23,
`serve-real-fncall` 7):** exe gained the function-invoke verb, so a body
that calls another user function - a packaged sibling (`QUAD = DBL(DBL(A))`),
or a qualified `PK.F(x)` from any function/procedure - runs through the
executor instead of refusing. exe fetches the callee's BLR (function_blr)
and runs it recursively; each argument is coerced to the callee's
parameter (numeric rescale + width → 22003, CHAR padding / VARCHAR width),
and the result is coerced to the callee's return scale. A depth guard (64,
safe on the 2 MiB connection-thread stack) turns a runaway recursion
(`RETURN PK.F(N+1)`) into a clean error, never a crash. Boundaries: a
nested callee that draws a GENERATOR refuses (its advance cannot persist
through exe); a recursive/IF-controlled body refuses (exe does not convert
the IF statement); a plain function calling another plain function by a
BARE name still refuses at CREATE (dsql). An adversarial review confirmed
three defects in the first cut - uncoerced args, a lost generator advance,
and a too-high depth guard - all fixed here.

**Packaged functions via exe DONE (2026-08-23, `serve-real-pkgfunc` 6):**
`function_blr` is now package-aware (a dotted `PKG.F` resolves the
packaged member's BLR, a bare name the plain function — the two stay
distinct), so packaged functions run through the exe executor and get its
full scalar surface (NUMERIC params/returns, scaled arithmetic, a NUMERIC
literal, UPPER/CASE) instead of the arithmetic-only source path — closing
the previous slice's packaged-numeric boundary. Boundary: a packaged
member whose body CALLS A SIBLING (blr_function2) still refuses (exe has
no blr_function2; a clean refusal, the engine answers) — needs
blr_function2 in exe.

Other gaps: an explicit `PLAN` (WITH LOCK / FOR UPDATE / OPTIMIZE are
done); a `?` inside any PSQL query (loop, cursor, `EXECUTE STATEMENT`,
`SELECT INTO` — `server.rs:47089`); `GEN_ID` inside an autonomous body;
`INSERT … VALUES` without a column list in PSQL (probed 2026-08-24: needs
BOTH the dsql compiler AND the wire-local `parse_trig_block` interpreter
taught, each with the target's non-computed columns threaded in from the
catalog — dsql alone stores correct BLR but `run_body_source` still refuses,
a create/serve split, so it is a two-parser slice); `EXECUTE BLOCK` with
input parameters (RETURNS is done; not cleanly isql-gateable — isql passes no
input SQLDA); `EXECUTE STATEMENT` with `USING` / `ON EXTERNAL` / `AS USER`
(the dynamic operand and POSITIONAL + NAMED parameters are done); PSQL
literals held as i32 (`serve-real-psqlerrors`); the BLR compiler narrower
than the interpreter (a bare `EXCEPTION;` in a `CREATE TRIGGER` body refuses,
`server.rs:12764`); a read inside a PSQL body is read-committed regardless of
the transaction's snapshot. (Corrected 2026-08-24: `IF (c) THEN CONTINUE` /
`THEN LEAVE` — bare control as an IF then-branch — ALREADY WORK, an earlier
stale claim.)

Not features (the engine's own `-104`, fc refuses too — an error-text
parity gap only): `INTERSECT`/`EXCEPT`, `WITH TIES`, `PERCENT`,
`MIN … KEEP`. Confirmed WORKING (were listed as gaps): the named
`WINDOW` clause, `= ANY`/`= ALL` over a text subquery, a bare/grouped
aggregate over a comma join, `RDB$SET_CONTEXT`/`RDB$GET_CONTEXT`, a
selectable packaged procedure with arguments.

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

- **RE-EXECUTING A PREPARED STATEMENT DONE (2026-08-30,
  `serve-real-reexec` NEW, 15):** a second execute of a prepared handle
  answered **ZERO ROWS**, silently. A FETCH MUTATES THE LIVE PLAN - it
  materialises into `Plan::Rows`, drains those rows as it delivers them,
  and (since the cursor-exhaustion fix) marks the plan spent when the
  cursor finishes - so the plan a second execute would run is the
  wreckage of the first run. `OP_EXECUTE` clears the cursor maps and
  never rebuilds the plan.
  I INTRODUCED HALF OF THIS. The cursor-exhaustion commit justified the
  spent-marking with "safe across re-execute because `plan` is
  reassigned then". It is not, and I asserted the property instead of
  testing it - the exact mirror-image error the paper section written
  minutes earlier had described. Bisected: a plain scan's second run was
  3 rows before that commit and 0 after. `SELECT COUNT(*)` was ALREADY 0
  beforehand, because its materialised row had been drained, so the
  other half is long-standing.
  Fixed by recording the PRISTINE prepared plan per statement handle and
  restoring it on every execute - in BOTH `OP_EXECUTE` and
  `OP_EXECUTE2`, which is easy to miss since the two handlers open
  identically. Dropped on re-prepare of the same handle and on
  DROP-mode free.
  WHY NO GATE COULD SEE IT: **isql RE-PREPARES every statement text**, so
  it never reuses a prepared handle and cannot reach a second execute.
  All 355 gates went through isql or a node client with no statement
  cache. An entire class of defect sat behind that door with no key. The
  new gate uses node-firebird with `statementCacheSize` and runs every
  plan shape THREE times; its header says why it must not be
  "simplified" onto isql.
  THIS IS THE SECOND DEFECT IN A ROW that survived because the probe
  used a client which cannot exercise the path - the 500-row duplication
  was invisible to node-firebird for the opposite reason. The pattern is
  worth more than either fix: **when a defect is about a protocol
  SEQUENCE, the client is part of the experiment.**
  Found by an audit of the fetch/cursor state machine that was
  commissioned precisely because two silent defects had just been found
  in it; its first predicted case was this one.

- **A CURSOR IS CONSUMED BY ITS FETCH DONE (2026-08-30,
  `serve-real-fetchdup` NEW, 17):** **ANY result of 500 rows or more was
  delivered TWICE.** Not a window, not a join, not a sort: a plain
  `SELECT ID FROM T` with no WHERE and no ORDER BY. Row 1 came back
  twice and so did row 600; 1200 rows where the engine sends 600.
  TWO SEPARATE PATHS, and the first fix caught only one.
  (a) `emit_rows` walks the WHOLE plan and ignores the count the client
  asked for, but only `Plan::Rows` was emptied afterwards - so a
  STREAMING plan was re-walked from the start on the next op_fetch.
  (b) The resumable-cursor route REMOVES the cursor when it reports
  end-of-cursor, which loses the difference between "never started" and
  "already drained". fbclient sends one more op_fetch after the end
  status - it does so from 500 rows up - and, finding no cursor, the
  server opened a FRESH one and served the entire result again.
  A JOIN was already safe because it sets `keep_on_done` and therefore
  RESUMES an exhausted cursor. That asymmetry is the tell: a self-join
  agreed while the plain scan did not.
  Both now mark the plan spent on completion, so the extra fetch drains
  nothing and repeats the end-of-cursor status. Safe across re-execute
  because `plan` is reassigned then - keeping the CURSOR instead would
  have broken re-execution, since nothing removes cursors on execute.
  WHY NOTHING CAUGHT IT, and it is the same reason the windowed
  six-fold duplication hid: under ONE fetch the answer is correct, and
  one fetch is every hand-written test in the suite. It is wrong only
  from the SECOND fetch on. PRE-EXISTING - reproduced on the binary two
  commits back, so it predates the window work entirely.
  A METHOD ERROR WORTH RECORDING: I saw this duplication days-of-work
  earlier, checked it with node-firebird, got the correct row count, and
  concluded it was an isql rendering artifact. **node-firebird does not
  send the extra op_fetch, so it cannot observe this defect at all.**
  Verifying with a client that does not exercise the path is not
  verification. What settled it was counting occurrences of SPECIFIC
  rows rather than lines, then instrumenting the server to count fetch
  invocations: 499 rows is one fetch, 500 is two.
  The first fix was also verified too narrowly - only on `FIRST n`
  shapes, which are served by the path it changed - and the gate written
  afterwards caught the plain scan immediately. Write the gate before
  declaring the fix done.

- **THE NULLABLE BIT THROUGH A VIEW AND A GROUPED JOIN DONE
  (2026-08-30, `serve-real-nullbit` NEW, 27):** two describe defects,
  and in this server a describe defect of this kind is a VALUE defect -
  the announced bit decides whether a value's bytes go on the wire.
  (1) **EVERY COLUMN OF A VIEW IS NULLABLE**, whatever its body says.
  `plan_view` took the body's columns verbatim (`output_cols_of` is a
  clone) and touched `sql_type` NOWHERE, so a view over a NOT NULL
  column announced NOT NULL. The engine's rule is UNCONDITIONAL -
  measured over a plain NOT NULL column, a DOMAIN-typed one, an
  expression, through a WHERE, view-over-view, aliased, and nested in a
  derived table - and it agrees with the catalogue, where a view's
  RDB$RELATION_FIELDS row carries no RDB$NULL_FLAG at all.
  (2) **A GROUPED JOIN WAS NEVER MARKED AT ALL.** The grouped branch of
  the join planner returns ~230 lines BEFORE the only
  `mark_not_null_join` call, so a NOT NULL key came back Nullable while
  the same query WITHOUT the join was correct. No nested source is
  needed; plain base tables show it.
  MEASUREMENT REFUTED THE REPORT, and that is the main lesson. The brief
  named four "lost bit" shapes - a CAST through a derived table, `N + 0`,
  a derived joined to a base table, and the CTE form. ALL FOUR AGREE
  with the engine today. No fix was written for them; they are gated as
  CONTROLS instead, so a future change that breaks them is caught. A
  read-only code analysis had traced a plausible mechanism for them and
  it did not survive contact with the engine.
  TWO SELF-INFLICTED ERRORS, both caught by the gate's own fences rather
  than by the sweep. Passing the grouped columns straight to
  `mark_not_null_join` is wrong: a grouped column's `field_id` indexes
  the GROUP ROW, not the joined record, so the side lookup is
  meaningless - right for an INNER join by luck and wrong for an OUTER
  one, which is precisely the shape that would have shipped a wrong bit.
  The fix builds a probe from `gitems`, where a plain key's fid IS a
  combined-record id. Expression keys then needed the same treatment,
  carried as `key_exprs` so the marker can evaluate them against the
  join's own predicate.
  THE INTERACTION, gated: `<view> JOIN <base>` agreed BEFORE either fix
  and still agrees, because the join side discards a column's bit at the
  boundary - a fix that made the side CARRY the bit without fixing the
  view would have broken it.

- **A WINDOWED RESULT LARGER THAN ONE FETCH BATCH DONE (2026-08-30,
  `serve-real-winbatch` NEW, 15):** a bare top-level `SELECT ID,
  ROW_NUMBER() OVER (ORDER BY ID) FROM T` over 5000 rows came back **SIX
  TIMES OVER** - 30000 rows, row 1 at line offsets 2, 5002, 10002,
  15002, 20002 and 25002, five of the six blocks byte-identical. No
  error. And node-firebird, which honours the protocol's flow control,
  HUNG and never returned.
  `branch_rows` answers None for a windowed Project, so the plan was
  never materialised into `Plan::Rows` and control fell PAST the
  batching code to a path that ignores the client's requested batch size
  and re-emits the whole result every time it is asked. Under ONE batch
  the answer is correct - which is every hand-written test, including
  all 83 checks the window gate had - so it is wrong only from the
  SECOND fetch onwards. That is why a 353-gate suite never saw it, and
  why the new gate builds 5000 rows on purpose and asserts the
  MULTIPLICITY of individual rows: a row-count check alone passes the
  broken server on its first batch.
  Fixed by materialising a windowed projection in the fetch path BEFORE
  the generic `branch_rows` attempt, through the SAME fold the streaming
  emit path uses (`fold_project_windows`) rather than a second copy. The
  order is load-bearing and is why it is a shared function: scan with an
  EMPTY sort key, fold each window over its whole partition, and only
  THEN sort. A window folds over the partition, so a per-batch fold
  would be wrong exactly past the first batch boundary, and
  ROW_NUMBER's tie order is pinned to SCAN order, which a pre-sort would
  move.
  Found by a workflow sent to investigate something else entirely (the
  nested prepare-then-fail cluster), which is a fair argument for
  probing the paths ADJACENT to a defect and not only the defect.

- **`sqlerr` GATE COLLISION REPAIRED (2026-08-30):** eleven DDL gates
  compiled their `sqlerr` helper to ONE shared path,
  `/tmp/fbhandson/sqlerr`. Under `-j 4` a gate recompiling it while
  another executed it gets `Permission denied` (ETXTBSY), which surfaces
  as a DIFF whose two sides are IDENTICAL but for the isql line number
  that reported it - a failure that looks like a real divergence and is
  not. Each gate now compiles to `sqlerr-<gate>`; all eleven pass when
  run concurrently, which is the condition that produced it.

- **WINDOW FRAMES OVER A NULL KEY, AND LAG/LEAD'S DEFAULT DONE
  (2026-08-30, `serve-real-window` 83 -> 119):** two silent wrong-answer
  classes, both with a byte-identical SQLDA.
  **THE EXPLICIT RANGE FRAME WAS A VALUE FILTER**, and it got the NULL
  ordering key wrong twice over: `keyi(ri)?` dropped every NULL-key row
  from every OTHER row's frame even when that side's bound was
  UNBOUNDED, and the `None =>` arm hard-wired a NULL-key row's own frame
  to its NULL peers without ever consulting the bounds. The reported
  symptom was two offset shapes; the real extent is wider - `RANGE
  BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`, the whole
  partition BY DEFINITION, answered 2,2,7,7,7,7,7,7,7 over a nine-row
  partition with a two-row NULL peer group where every row is 9, and the
  SUMs were corrupted with the counts (200 vs 30 at one row), so this was
  wrong DATA and not a miscount.
  Now a POSITION INTERVAL over the sorted partition, which is how the
  IMPLICIT frame arm always worked - and that asymmetry is what localised
  it: `OVER (ORDER BY K)` agreed while the semantically identical `RANGE
  BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` did not. Both are gated
  now so the two paths cannot drift.
  The measured laws: UNBOUNDED IS ABSOLUTE (the partition edge, whatever
  the NULLness - there is no NULL/non-NULL barrier); a NULL key never
  satisfies a VALUE bound of a non-NULL row; an OFFSET bound on a NULL
  CURRENT key degenerates BY SIDE to that row's peer group while an
  UNBOUNDED bound on the same row does NOT (proved side-based by `RANGE
  BETWEEN 1 FOLLOWING AND 3 FOLLOWING` giving a NULL row its whole peer
  group, neither 0 rows nor 1); peers are equality on the ORDER BY tuple
  with NULL not distinct from NULL; CURRENT ROW under RANGE reaches
  through the LAST peer.
  **LAG/LEAD'S DEFAULT WAS NEVER CAST** to argument #1's type - it was
  handed to the evaluator raw and the announced descriptor was stamped
  onto whatever the literal happened to be, so the client read the
  MANTISSA: `LAG(<INTEGER>, 1, 2.5)` answered **25** where the engine
  answers 3, `LAG(<NUMERIC(9,2)>, 1, 7)` answered 0.07 for 7.00, and
  `LAG(<INTEGER>, 1, '12')` answered 0 for 12. Not in the original hunt;
  found by the measurement pass. Ordinary CAST semantics now apply
  (`cast_target_of_col` rebuilds the argument's own type as a target),
  and the default never widens the result - `LAG(K, 1, CAST(9 AS
  BIGINT))` still describes LONG len 4.
  Closes hunt findings 4 and 20 and this new one.
  NOT ATTEMPTED HERE, and the natural next chunk: the **28
  PREPARE-THEN-FAIL** shapes the measurement pass found - a window inside
  a CTE, a derived table, a UNION branch, a view body or an INSERT ...
  SELECT source PREPAREs with a byte-identical correct SQLDA and then
  dies, and in the UNION ALL case DELIVERS NINE CORRECT ROWS before
  failing mid-stream. Those are protocol violations rather than
  boundaries: the client has been told the statement is valid and has
  cached its description. The real fix is to make `branch_rows_res`
  window-aware (fold before sort, mirroring emit's Project arm) and must
  ship with a full SQLDA re-diff of the nested shapes; it also re-routes
  the batch-fetch and scrollable-cursor paths, which are unprobed. A
  cheaper way-station - refusing them at PREPARE - is honest but refuses
  shapes the engine answers, so it is only defensible as a step on the
  way.

- **A GROUPED SELECT LIST'S EXPRESSIONS GET THE ORDINARY NULLABLE RULE
  DONE (2026-08-30, `serve-real-groupconst` 11 -> 29):** `plan_group`
  had a nullability pass covering only the plain group KEYS, so every
  grouped EXPRESSION kept the bit `build_expr_col_from` stamped and came
  back Nullable - `SELECT 1 FROM T GROUP BY 1` and `SELECT <NOT NULL> +
  1 FROM T GROUP BY 1` both, while a grouped plain FIELD was already
  right. Every Project and Join site calls `mark_not_null_cols`; this
  one never did. Reported as the "all-literal temporal difference" half
  of a temporal finding, and not temporal at all - two non-temporal
  controls are what identified it.
  TWO LAYERS. An expression column takes `expr_nullable` directly. An
  expression GROUP KEY cannot: `build_group_items` builds its column
  through `build_expr_col` and then deliberately CLEARS `expr`, so the
  output column reads plainly from the group row's synthetic slot - the
  expression survives only in `key_exprs`, indexed past `synth_base`.
  THE REGRESSION THIS CAUSED, and it was not cosmetic. The statistical
  folds answer 0 rather than NULL and the engine describes them NOT
  NULL; marking them Nullable made `VAR_SAMP(N) + 1` over an empty set
  answer **<null>** where the engine answers 0.0, because the announced
  bit decides whether the bytes are shipped at all. Caught by
  `serve-real-statexpr` in the sweep.
  THE FIRST GUARD WAS ALSO WRONG: it skipped expressions reading a slot
  past `synth_base`, on the assumption that is where folds live.
  `GItem::Agg` carries no field id at all - a fold's slot is POSITIONAL,
  its index in `gitems` - so it can sit BELOW `synth_base` and
  `VAR_SAMP(N) + 1` went straight through. `synth_base` is the base for
  expression KEYS, which is not the same thing as "everything
  synthetic". The guard now tests the actual fold positions.
  Closes the Nullable half of hunt finding 25.

- **THE TEMPORAL CLUSTER DONE (2026-08-29, `serve-real-temporal2` 69):**
  five defects, two of them the worst kind - a value that LOOKS right.
  **DATEADD OVER A ZONED OPERAND ANSWERED A PLAUSIBLE LIE.** `eval`'s
  DateAdd arm decomposed Date/Time/Timestamp and sent everything else to
  `_ => Ok(Value::Null)` under the comment "type-checked away" - but
  `type_of` accepts EVERY TKind, the zoned ones included. The NULL then
  travelled under a NOT NULL describe: the encoder omitted the bytes and
  the client decoded their absence as `1858-11-16 00:01:00.0000 -23:59`,
  the Modified Julian Day epoch with zone id 0. It reads as a timestamp
  rather than as a missing value, which is exactly why it survived -
  EVERY DATEADD over a TIMESTAMP WITH TIME ZONE answered it, for every
  part and every amount. DATEDIFF over a zoned pair answered a constant
  0 from the same omission.
  THE LAWS, measured: DATEADD's result is the operand's own type, the
  arithmetic runs on the STORED UTC halves under ordinary zoneless
  calendar rules, and the zone id rides through UNCHANGED. DATEDIFF
  measures the UTC INSTANT and never the wall clock - the same wall
  clock under different offsets is NONZERO (-3 HOUR between +02:00 and
  +05:00) while the same instant under different zones is 0, which is
  the pair of checks that distinguishes the two models. The decisive
  evidence for DATEADD is on a RULED zone, where the models differ:
  `DATEADD(DAY, 1, '2024-03-30 12:00 Europe/Berlin')` is 03-31 13:00,
  twenty-four hours of INSTANT across the DST step, which local-field
  arithmetic cannot produce. (fire-crab refuses ruled-zone literals, so
  that one is the engine's measurement alone; every fixed-offset probe
  passes under either hypothesis and the implementation follows the
  measured law. Recorded as such.)
  The part-legality corollaries had to land in the SAME change: a TIME
  WITH TIME ZONE takes only the clock parts, exactly as a zoneless TIME
  does, and without widening those tests the new arms would have
  answered a WRONG VALUE for `DATEADD(DAY, .., <ttz>)` rather than the
  NULL they used to - a strictly worse outcome.
  **THE SHAPE OF A TEMPORAL DIFFERENCE.** `result_scale` already knew
  it; the width, the rank and the sub_type did not. `DATE - DATE`
  announced INT64 len 8 for a 4-byte LONG, and both scaled differences
  announced sub_type 0 where the engine says NUMERIC's 1. The width
  error CASCADED - `rank_of` found no numeric rank on either operand,
  fell to its `(None, None)` default of Long, Sub widened to I64, and
  `* 2` promoted to INT128 where the engine stays INT64. All four now
  read ONE classifier (`temporal_diff_shape`) so they cannot drift apart
  again.
  **A TEMPORAL RENDERED AS TEXT HAS A NATURAL WIDTH** - DATE 10, TIME
  13, TIMESTAMP 25 - where every implicit conversion fell into the 32765
  catch-all. It contributes a WIDTH but NO CHARSET; the text operand
  alone decides that. Mid-fix, adding it as a trailing catch-all fixed
  the LITERALS and left every COLUMN at 32765, because a temporal column
  has its own earlier `Expr::Col` arm - so the test is now the FIRST
  thing `text_form` does. The string functions then split, and not the
  way one would guess: UPPER, LOWER, TRIM and SUBSTRING over a temporal
  announce charset ASCII (re-announced as the attachment's under a real
  one), while LEFT, RIGHT, REVERSE, LPAD and REPLACE announce NONE and
  STAY NONE under UTF8. Both families are gated, since the rule is not
  uniform and the second was already right.
  Closes hunt findings 7, 8, 23, 24, 26 and the sub_type half of 25.
  SPLIT OUT DELIBERATELY: the Nullable half of finding 25 is NOT
  temporal. `SELECT 1 FROM T GROUP BY 1` and `SELECT ID+1 FROM T GROUP
  BY 1` are Nullable here and not on the engine, while a grouped plain
  FIELD is correct on both - `plan_group` never calls
  `mark_not_null_cols`, unlike every Project and Join site. That moves
  the describe of EVERY grouped statement and wants its own change and
  its own sweep.

- **CONCATENATING ACROSS CHARACTER SETS DONE (2026-08-29,
  `serve-real-concatcs` 44):** `eval` joins two rendered strings and has
  no descriptors to convert against, so an operand whose charset
  differed from the result's was spliced in as it stood. A `String`
  means different things per charset here - a byte carrier's octets ride
  one char per byte, a UTF8 column's are real characters - so this was
  not a rounding difference.
  **THE WORST OF IT WAS NOT A WRONG ANSWER.** `<NONE> || <WIN1252>`
  carried the NONE octets as chars U+0073.. U+009F.., announced the
  result WIN1252, and the emit path then tried to TRANSLITERATE those
  chars into WIN1252 - where U+009F has no image, WIN1252 mapping 0x9F
  to U+0178. It failed MID-ROW, after bytes were already on the wire:
  SQLSTATE 08006 and a DROPPED CONNECTION. The gate therefore asserts
  the session answers a SECOND question afterwards, not merely that the
  bytes agree.
  THE LAW (probed): a byte carrier is BYTES; a conversion to or from one
  is a BYTE COPY, never a transliteration. `transcode_text` already
  implemented exactly that - carrier source to tabled destination
  re-spells each octet, a carrier destination copies bytes - and nothing
  called it from the concatenation path. Each operand whose charset is
  STATICALLY KNOWN is now converted to the result's set before joining,
  through the synthetic text CAST that invokes it.
  Also fixed: a BYTE-CARRIER RESULT counts BYTES, not characters.
  `<UTF8 VARCHAR(32)> || <OCTETS VARCHAR(32)>` is 160 bytes on the
  engine (32x4 + 32) where summing characters announced 64 - and an
  announced width that disagrees with the shipped bytes is the same wire
  desync as above. (`cs_join` itself was already right: OCTETS absorbs
  from either side, NONE is weakest, ASCII yields to all but NONE.)
  TWO REGRESSIONS CAUGHT BEFORE SHIPPING, both by adjacent gates rather
  than by the sweep summary. The second is the more instructive: the
  wrap fired for CATALOG columns, which carry UNICODE_FSS, and
  `transcode_text` implements byte carriers, the tabled single-byte sets
  and UTF8 - nothing else. A carrier source into UNICODE_FSS falls
  through to `decode_text`, which answers None for an untabled set and
  raises `Malformed string`, so `RDB$FUNCTION_NAME || RDB$MODULE_NAME`
  became an ERROR where the engine answers (`serve-real-blobfilter`).
  The wrap is now restricted to destinations `transcode_text` actually
  implements - the same predicate `cast_source_charset` already uses.
  What pointed at the cause: `TRIM(<same col>) || TRIM(<same col>)`
  worked while two DIFFERENT columns failed, which ruled out the TRIM
  and the CAST and left the charset PAIR. It was then confirmed as ours
  by rebuilding the committed binary and re-running the query - the same
  check that had earlier established the gbakverbose flake was NOT ours.
  And the first: the first cut wrapped BLOB operands too. A
  blob concatenation's result type is found by WALKING for a `BlobText`
  node, and that walk does not descend through a CAST - so the wrapper
  HID the blob and a binary one described as a text blob, sub_type 1
  charset UTF8 where the engine says 0. `serve-real-blobexpr` caught it;
  blob concatenations are now left alone.
  DIVERGENCES (recorded, and ASSERTED in the gate as known-different so
  that FIXING them trips it): a **`<NONE column> || <literal>`** still
  splices the carrier's octets as UTF-8, because a literal's charset is
  the ATTACHMENT's and the join is therefore the attachment sentinel -
  no static conversion is possible, and the eval path has no attachment
  at all. Fixing it needs the conversion DEFERRED to emission. Note
  `<OCTETS> || <literal>` is CORRECT, since OCTETS absorbs and the join
  is statically known. Second: **`CAST(<literal> AS ... CHARACTER SET
  WIN1252)` under a NONE attachment** - the engine byte-copies the
  literal's octets where this transliterates; under UTF8 it agrees. Both
  answer with the wrong bytes rather than refusing.
  Closes hunt findings 11 and 12, and the column half of 10; the literal
  halves of 10 and 30 remain, precisely characterised above.

- **A NARROWING NUMERIC CAST RAISES 22003 DONE (2026-08-29,
  `serve-real-castint` 42 -> 58):** `CAST(<value> AS NUMERIC(p,s))`
  checked only the i64 edge, so a value that overflowed a NARROWER
  target wrapped silently: `CAST(123456789012.34 AS NUMERIC(9,2))`
  answered **19428925.30** - the raw scaled integer taken modulo 2^32 -
  where the engine raises `numeric value is out of range`. A plausible
  wrong number, which is the worst kind. The INTEGER family already had
  the check; the SCALED family did not.
  THE LAW, and it is not the obvious one: the engine checks the TARGET'S
  STORAGE WIDTH, **not the declared precision**. It ACCEPTS
  `CAST(15000000.00 AS NUMERIC(9,2))` although nine digits at scale 2
  top out at 9999999.99, and refuses only past the 4-byte slot. The
  boundaries land exactly on the integer limits, probed in both
  directions: 327.67 / 327.68 for a 2-byte NUMERIC(4,2), 21474836.47 /
  21474836.48 for a 4-byte NUMERIC(9,2), 922337203685477.5807 / ...5808
  for an 8-byte NUMERIC(18,4). Guessing "precision" here would have
  refused a pile of statements the engine answers.
  The vector matters too: this raises `EvalErr::NumericOutOfRange`
  (`isc_arith_except` + `numeric value is out of range`), the pair a cast
  to an INTEGER target already used - not `IntegerOverflow`, which is the
  same SQLSTATE 22003 with a different message and was what a first cut
  emitted.
  Closes hunt finding 9.

- **A SCALAR SUBQUERY ANSWERS UNDER ITS INNER COLUMN'S DESCRIPTION DONE
  (2026-08-29, `serve-real-subqdesc` 40):** a whole-item
  `(SELECT <col> FROM T WHERE ...)` is folded here by EXECUTING the
  subquery at plan time and splicing its value back as a literal. The
  fold is fine; the describe was then taken FROM THAT LITERAL - from the
  row that happened to be read. The inner plan was already computed at
  the fold site and thrown away unless it folded to a `Plan::Scalar`,
  which a plain-column subquery never does (the code said so in a
  comment three lines below). Five defects from that one cause:
  (1) **THE DESCRIBE DEPENDED ON THE DATA** - `(SELECT <BIGINT>)`
  announced LONG len 4 for a small stored value and INT64 len 8 for a
  large one. A protocol violation on its own, since a client caches what
  PREPARE told it, and the one law here no value comparison can catch:
  both describes render the right number.
  (2) a SMALLINT came back LONG; (3) a NUMERIC lost its scale and family
  code and was widened to INT64; (4) a subquery matching NO ROWS
  described as TEXT(1) CHARACTER SET NONE, the literal being the word
  NULL; (5) TEXT lost its CHARACTER SET and that CORRUPTED THE VALUE -
  under a NONE attachment a WIN1252 column shipped the UTF-8 spelling
  C3 A9 under a describe saying CHARACTER SET NONE, which the client
  re-expanded to C3 83 C2 A9.
  Fixed by not discarding the inner plan: `ScalarTy::from_col` takes the
  inner ProjCol's whole announced shape. `ScalarTy` gained `scale`,
  `sub_type` and `oct_length` - three fields could not express
  `(SELECT MAX(<NUMERIC(9,2)>))`, which is LONG len 4 scale -2 sub_type
  1 (probed; the DECIMAL twin is 2). That is not cosmetic:
  `ProjCol::value_of` raises IntegerOverflow when a value's scale is
  FINER than the announced one, so a carrier defaulting to scale 0 over
  a `Scaled(raw, -2)` would turn a working query into an ERROR rather
  than a wrong number.
  MEASURED FIRST, as the plan required: the engine describes a subquery
  EXACTLY as its inner column - CHAR(10) UTF8 stays 452 TEXT len 40 like
  the bare column, VARCHAR stays 448, OCTETS stays charset 1, WIN1252
  keeps charset 53 under a NONE attachment and rescales to the
  attachment under UTF8. The decisive probe was the value BYTES under
  each attachment: under UTF8 and WIN1252 fire-crab's bytes were ALREADY
  correct and only the padding width was wrong, which is what proved the
  fold's value round trip is clean and the whole defect was the lost
  description. (One of the three analysis passes had speculated the text
  was mangled on the round trip; the probe refuted it.)
  ALSO FIXED, found while testing the above: **`SELECT NULL X`** - a bare
  NULL with a bare, no-AS alias - was refused. `split_alias` treats a
  trailing NULL in the head as the tail of an `IS NULL` (which must keep
  refusing, since a projected boolean is not answered correctly here); a
  head that IS exactly NULL is the literal. It surfaced through this
  construct because a no-row subquery with a bare alias folds to
  precisely `NULL X`.
  AND: **any select item CARRYING a subquery is nullable**, not just a
  whole-item one. `(SELECT <col> ...) + 1` folds to two constants and
  described NOT NULL where the engine says Nullable - the subquery might
  have matched no row - and `EXISTS(<sub>)` is BOOLEAN Nullable on the
  engine too. The law already lived at the whole-item patch site; it now
  covers every item containing a marker.
  This closes hunt findings 3, 16, 17, 18, 19 and 31.

- **`serve-real-gbakverbose` REPAIRED (2026-08-29):** it had broken two
  consecutive sweeps and passed on every retry, which is the most
  dangerous shape a gate can have - it trains you to wave the failure
  through. Reproduced 1-in-3 STANDALONE on an idle box, which ruled out
  both load and the change under test, and then diagnosed to TWO real
  defects in the gate itself.
  (1) Its fixture was created with a BARE PATH, so the EMBEDDED engine
  made the file as the invoking user, while every consumer reached it
  through `localhost:service_mgr` - a service running as the `firebird`
  user. That mixed-mode access intermittently lost the race with the
  embedded process still releasing the file and answered `I/O error
  during "open" operation`, surfacing as `both -v backups run (rc)` want
  0/0 got 1/0 - THE ENGINE'S OWN gbak failing, on a gate whose subject is
  fire-crab. Now created through the server, the same law the rest of the
  suite follows.
  (2) The stream comparison was newline-based, and the engine's verbose
  service output does not merely re-chunk mid-line (known since
  2026-08-28) - it sometimes CUTS A RECORD OFF MID-WORD. A captured
  failing run held `gbak: writing privile`, which the `writing privilege`
  filter did not match, so the fragment survived and misaligned every
  line after it. The comparison now splits the stream on its own `gbak:`
  record marker rather than on newlines, and the privilege filter matches
  the truncated prefix. Privilege records are excluded by design (the
  engine writes them, fire-crab does not), so excluding their fragments
  weakens nothing.
  10 consecutive clean standalone runs after the fix, where before it
  failed 1-in-3.

- **BRANCH RECONCILIATION BEYOND UNION DONE (2026-08-29,
  `serve-real-branchtype` 51):** a UNION describes one column per
  position and decodes every branch's value under it - and so does a
  CASE, a COALESCE, an IIF, a DECODE and the anchor/recursive pair of a
  recursive CTE. The law has two halves: the description is RECONCILED
  from every branch, and every branch's VALUE is then brought to it.
  fire-crab had the first half and not the second, which is the worst
  possible split - the describe looks right, a row comes back, and the
  number in it is wrong.
  **THE FLAGSHIP:** `SUM(CASE WHEN <false> THEN CAST(1.50 AS
  NUMERIC(9,2)) ELSE 100 END)` answered **2.00** where the engine
  answers 200.00. The integer branch handed back a raw 100 where the
  announced scale of -2 wanted 10000, so every row contributed 1.00.
  `SUM(CASE WHEN ... THEN <amount> ELSE 0 END)` is a workhorse idiom and
  it was returning money short by a factor of 100. What hid it: the
  DIRECT projection of the same conditional is CORRECT on both servers,
  because the encoder renders the value's own scale - the defect only
  appears once an aggregate or a `CAST` to text CONSUMES the datum, so a
  value-only check of the expression sees nothing. Fixed by
  `align_conditional`, which wraps a scaled conditional in the CAST that
  already implements rounding, at the same single resolution point
  `pad_conditional` uses - so the aggregate's source, the cast's source
  and the select list are all covered at once, and `eval` (which has no
  descriptors to reconcile against) is left alone.
  Same law, four more places:
  (a) a conditional's **sub_type** is the MAX family code of its
  branches; CASE had no arm in `numeric_subtype` at all and announced 0
  for every one. NULLIF instead takes its **FIRST** operand's alone -
  its value IS that operand.
  (b) **MIN/MAX describe what their SOURCE describes**, expression
  sources included. Reading `MAX(ID+0)` is INT64 as "an expression
  source stays the fold's INT64" was the wrong lesson: `ID+0` is itself
  INT64, the arithmetic having widened it before the fold saw it, while
  `MAX(CASE ... <INTEGER> ... END)` is a 4-byte LONG.
  (c) **an 8-byte NUMERIC RANKS as I64** - what makes SUM widen it to
  INT128 and a multiplication around it promote. `CastTarget::Numeric`
  mapped everything below 16 bytes to Long, so neither fired (probed:
  `SUM(CAST(1.5 AS NUMERIC(18,4)))` is INT128 where the NUMERIC(9,2)
  one stays INT64).
  (d) a **UNION of TEXT branches** takes the widest length, VARYING wins
  over the fixed form, and the charset follows the concatenation join
  (a real charset beats a literal's attachment sentinel and beats NONE;
  of two reals the FIRST branch's wins). This was a gap in the union
  chunk two commits back: that reconciliation compared type, scale and
  sub_type but NOT length, so two CHAR branches looked identical, kept
  the first branch's width, and `'a' UNION ALL 'bb'` announced one
  character and died mid-cursor with a 22001. The width is maxed in
  CHARACTERS, not the branches' own units - a plain column carries its
  width in the bytes of ITS OWN charset, so the same six-character union
  is 6 bytes under WIN1252 and 24 under UTF8.
  BOUNDARY (recorded, gated): a **recursive CTE whose recursive member
  answers at a different SCALE from the anchor** now REFUSES. It used to
  answer **15** - the raw of 1.5 read as a scale-0 integer - and 15 then
  failed the loop's own `X < 3` guard, truncating the result set as
  well. The engine keeps the recursion in FULL PRECISION and renders
  only at the anchor's description (`SELECT 1 UNION ALL SELECT X + 0.5`
  answers 1, 2, 2, 3, 3 - the values 1, 1.5, 2.0, 2.5, 3.0 each rounded
  at output), which needs two column sets this planner does not carry.
  The first version of the check compared the announced TYPE too and
  refused the ordinary integer generator, since `X + 1` widens to INT64
  against a LONG anchor while the values are identical - caught before
  commit; only the SCALE is compared.
  KNOWN DIVERGENCE (recorded, not gated): a **simple CASE (`CASE x WHEN
  ...`) and DECODE are announced NOT NULL where the engine says
  Nullable**, even with an ELSE - a searched CASE with an ELSE correctly
  is not. Both lower to the same `Expr::Case` node as a searched one, so
  telling them apart needs a flag on it and a dozen match sites updated.
  The VALUES are identical; this is the describe's nullable bit alone.
  Found by a 12-agent differential hunt across six SQL surfaces, which
  confirmed 37 wrong answers and 26 refusal boundaries in all; this
  entry closes the branch-reconciliation cluster. The rest are listed
  under "What the hunt found" below.

- **THE DESCRIBE OF A COMPUTED COLUMN DONE (2026-08-29,
  `serve-real-exprshape` 54):** four wrong-answer classes, all of them
  live and none of them a refusal, in the description a projected
  expression travels under.
  (1) A **computed length** on `SUBSTRING`/`LPAD`/`RPAD` had no static
  width and fell into the catch-all that announces the maximum — and
  `CHARACTER SET NONE` with it, so a UTF8 `straße` shipped one byte per
  character and rendered `stra\xDF`. The engine's fallbacks, probed:
  `SUBSTRING` keeps the SOURCE's own width (it can only shrink its
  source — `FOR 5+0`, `FOR ID` and a computed `FROM` all describe the
  column's own 80 bytes where `FOR 5` describes 20), while a PAD can
  grow past its source and falls back to the widest VARCHAR the charset
  admits: 65533 bytes for NONE/WIN1252, 65532 for UTF8. The cap is on
  the CHARACTER count (`MAX_VARCHAR_BYTES / bytes-per-char`, applied in
  `resolve_text_cs` where the charset is finally known), which is what
  puts the byte width on the engine's multiple.
  (2) A **UNION took the first branch's description** and let the other
  branches ride it: `SELECT CAST(1.50 AS NUMERIC(9,2)) UNION ALL SELECT
  100` answered **1.00**, and the error propagated into `SUM` over the
  union and into the row count of a `UNION DISTINCT`. The engine's rule,
  probed: **the widest branch wins on each axis independently** - type up
  the ladder SHORT < LONG < INT64 < INT128 (`SMALLINT UNION INTEGER` is
  LONG whichever comes first, `NUMERIC(9,2) UNION NUMERIC(30,4)` is
  INT128), scale the widest, and ONE approximate branch makes the whole
  column a DOUBLE whatever the exact branches carried. Every branch's
  value is then converted to that column (`union_coerce_value`).
  (3) The union's **sub_type** is reconciled by a different rule — the
  MAX of the family codes (0 int, 1 NUMERIC, 2 DECIMAL), regardless of
  branch order and independent of whether anything else needed
  reconciling: an INTEGER beside a `NUMERIC(9,0)` agrees on type AND
  scale and still announces sub_type 1.
  (4) Found by the gate written for (3), with no union in sight: **every
  fold dropped its source's family.** `SUM`/`AVG`/`MIN`/`MAX` over a
  NUMERIC answer sub_type 1 and over a DECIMAL 2, grouped or not and
  through a wrapping expression (`SUM(N92*2)` is INT128 scale -2 sub_type
  1); fc announced 0 for all of them. `MIN`/`MAX` keep the source's
  WIDTH too — they select an existing value rather than accumulating one,
  so `MIN` over a `NUMERIC(9,2)` stays a 4-byte LONG where `SUM` widens
  to INT64.
  Also fixed alongside: **`ORDER BY` an output alias that shadows a base
  column** sorted by the table's column instead of the projection.
  THE TRAP, and it is not in the arithmetic: the ANNOUNCED type and the
  WIRE FORM THE ENCODER WRITES are two pieces of state and must move
  together. A first attempt set `sql_type` and `length` and left `wire`
  alone — it answered **6442450944.66** for 1.50, the 4-byte value
  landing in the high half of an 8-byte slot (1.5 × 2^32). The quiet
  version of the same trap: an approximate union announces scale 0, so
  an exact branch that skipped conversion handed the encoder a scaled
  integer it cannot read as a float and the column answered **0.0**.
  `wire`/`sql_type`/`length` are now set in one place ([exact_numeric_form]).
  BOUNDARY (recorded, gated): a number beside TEXT, which the engine
  reconciles by RENDERING the number, refuses — that needs the value
  side to render digit-for-digit as the engine does. The gate asserts
  the engine ANSWERS it, so the boundary cannot rot into a vacuous pass.
  A FIRST, TOO-CONSERVATIVE VERSION of this fix refused every union whose
  branches differed in wire type, which broke `SELECT X UNION ALL SELECT
  X+1` — caught by `serve-real-describe` in the sweep, three checks. A
  refusal where the engine answers is a regression, not a safe default;
  the sweep was killed and the ladder implemented rather than shipping
  it.
  The gate also stopped being flaky the honest way: its `CREATE DATABASE`
  raced with the previous run's file being closed by the engine, so it
  now DROPs through the engine before unlinking and retries the create —
  an intermittent "FAIL create" is otherwise indistinguishable from a
  real one.

- **PSQL functions run through the BLR executor — the full scalar surface
  DONE (2026-08-23, `serve-real-funcbody` 5):** a plain function's body was
  interpreted by an arithmetic-only path (a `RETURN` could only do
  `+ - * /`); now it runs through the existing `crates/exe` BLR executor,
  which reads `UPPER`/`LOWER`/`SUBSTRING`/`CAST`/`COALESCE`/`DECODE`/the
  searched `CASE`/a scalar subquery/concatenation/`IF`/`WHILE`. `exe`
  gained `blr_leave` (verb 18: a function's `RETURN` is assign-var0, send
  message 1, then leave the body wrapper) via an `Exec.leaving` unwind, and
  `exe::function_blr` (the mirror of `procedure_blr`, plain functions only).
  `try_function_blr` (the mirror of `try_procedure_blr`) runs it and pulls
  the one output from message 1; a divide-by-zero raises 22012 and a bad
  `CAST` 22018 (before, any function runtime error was a generic refusal).
  Boundaries (recorded): a PACKAGED function's rich body and a function that
  calls another user function (`blr_function2`, no executor support) fall to
  the source path and may refuse; NUMERIC in a function SIGNATURE is a
  separate pre-existing gap (`load_function` refuses it, so such a function
  is `-804` regardless); fc omits the engine's `-At function ... line/col`
  stack frame on a runtime error.

- **CREATE PACKAGE BODY: a member that calls a sibling unqualified DONE
  (2026-08-22, `serve-real-pkgsibling` 8):** inside a package body a bare
  `DBL(...)` names sibling member DBL, compiled to `blr_function2` with THIS
  package - byte-identical to the qualified `PK.DBL(...)` (probed against
  the engine's RDB$FUNCTION_BLR). Before, the standalone per-member compile
  refused the sibling call, so `CREATE PACKAGE BODY` fell through storing a
  NULL body source - which made EVERY function in the package unknown
  (-804) in later queries. Now the body compiles, its BLR is byte-exact,
  and the engine runs fc's stored file for every member (the sibling-caller
  included). The DSQL compiler gained a package context (name + sibling
  FUNCTION signatures); a sibling call binds only to a FUNCTION and only at
  the declared arity, so a wrong-arity call or a bare call to a sibling
  PROCEDURE refuses on both (an adversarial review caught both). Also fixed:
  a packaged function call columns by its BARE member name (DBL, not
  PK.DBL), the engine's describe. Boundary (recorded): fc INTERPRETS bodies
  from source and cannot yet run a user-function call from an interpreted
  body, so a member that calls a sibling, queried through fc's OWN wire,
  refuses (fc stores byte-exact BLR, so the engine runs it) - a broader gap
  that holds for a plain function calling another function too.

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
  (Probed the same day and left: LIST/GROUP_CONCAT needed a COMPUTED BLOB
  result - since arrived with the LIST slice, though `CAST(x AS BLOB)` still refuses; CORR/regr and
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

## Found by the SECOND hunt (2026-08-31) - still open

- ~~**HIGH (wrong answer)** — `MERGE ... DELETE ... RETURNING NEW.<col>`~~ **DONE 2026-09-01**, with the describe half. Original report:

  ```
  MERGE INTO T USING (SELECT 2 AS K FROM RDB$DATABASE) S ON T.ID=S.K
    WHEN MATCHED THEN DELETE RETURNING T.ID, OLD.V, NEW.V;
      engine    2 | 20 | <null>          fire-crab   2 | 20 | 20
  MERGE ... DELETE RETURNING NEW.ID, NEW.D;
      engine    <null> | <null>          fire-crab   2 | 42
  ```

  The whole NEW record is wrong, not one column. `OLD.*` is correct
  everywhere, and a plain `DELETE ... RETURNING <col>` is correct on both
  (the engine DOES answer the deleted values there) - so the rule is
  specifically that `NEW.` has nothing to read on a delete branch.

  WHY IT IS NOT A ONE-LINE FIX: the delete path pushes the deleted row as
  the AFTER image ON PURPOSE - "a DELETE's `images` ARE the old rows; the
  parallel slot keeps every consumer's indexing uniform"
  (server.rs, the delete arm of execute_dml_collecting) - and
  `wrap_returning` resolves `NEW.<col>` to that same after-image. In a
  MIXED merge (some rows updated, some deleted) the distinction is
  PER ROW: measured, the update-branch row agrees and only the
  delete-branch row diverges. So it needs per-row branch provenance in
  `Affected`, not a plan-time decision.

- **MEDIUM (describe)** — the same shape's describe: `NEW.<col>` over a
  MERGE DELETE branch is announced as the base column (`496 LONG len 4`,
  table T) where the engine folds it to a constant (`452 TEXT len 1
  charset NONE`, no table). fire-crab announces the WIDER field, so a
  client laying out its buffer from the describe mis-parses.

- **MEDIUM (refusal)** — `ROWS` and `ORDER BY` on searched `UPDATE` /
  `DELETE` are not supported at all, with or without RETURNING. A widely
  used Firebird extension; the largest single gap that hunt found.

## Found by the FIRST hunt (2026-08-31) - still open

A six-surface differential hunt, run because the recorded backlog held no
wrong answers left, found these. Two were fixed the same day (the
correlated-subquery fold and the parenthesised-NULL inversion); what
follows survived refutation and is NOT yet implemented.

- ~~**HIGH (describe)** — an untyped NULL branch poisons the unified type of~~ **DONE 2026-08-31.** Original report:
  CASE / COALESCE / IIF / NULLIF. fire-crab types a bare NULL as INT64 and
  lets it win: `CASE WHEN 1=0 THEN NULL ELSE <VARCHAR(10) UTF8> END` is
  announced `448 VARYING len 32765 charset 0 NONE` where the engine says
  `len 40 charset 4 UTF8` - an 819x width inflation on a per-row wire
  buffer AND a lost character set. `COALESCE(NULL, <INTEGER>)` is
  announced INT64 len 8 where the engine says LONG len 4. The VALUES
  agree (checked as bytes), so this is describe-only - but a client sizes
  its buffer from the describe. The engine's rule: the other branch's
  type wins, and with nothing to unify against a bare NULL is CHAR(1)
  NONE (`SELECT NULL FROM RDB$DATABASE` already agrees on both).

  THE ENGINE'S RULE, from primary source - `DataTypeUtilBase::makeFromList`
  (jrd/DataTypeUtil.cpp:99), which COALESCE (ExprNodes.cpp:3927), CASE
  (:5062) and LIST (:611) all call:

  ```cpp
  allNulls &= arg->isNull();
  // Ignore NULL and parameter value from walking.
  if (arg->isNull() || arg->isUnknown())
  {
      nullable = true;
      continue;
  }
  ...
  if (allNulls)
      result->makeNullString();
  ```

  So a NULL argument is IGNORED for unification and only forces nullable;
  when EVERY argument is NULL the result is `makeNullString()` - CHAR(1)
  NONE, which is what fire-crab already answers for a standalone
  `SELECT NULL`.

  WHERE FIRE-CRAB DIVERGES, all three in server.rs: `result_width_bytes`
  takes a plain `max` over branches for `Expr::Coalesce` (:15209) and
  `Expr::Case` (:15212), so a NULL branch contributes the 8-byte default
  and WINS against a LONG's 4; and `type_of` has `Expr::Null =>
  Some(ExprType::Int)` (:58019). The TEXT width path ALREADY implements
  the law for Coalesce (:15670, filtering `Expr::Null` with the
  makeFromList citation in its comment) - it was simply never applied to
  CASE or to the numeric width. `rank_of` also already does it
  (`Expr::Null => None, // takes the sibling's rank`, :58562). So this is
  one law applied consistently, not a new mechanism.
- **MEDIUM (describe)** — COUNT(*) inside a CORRELATED scalar subquery is
  announced `496 LONG len 4` where the engine says `580 INT64 len 8`.
  This is the NARROWER, riskier direction. The non-correlated form agrees
  on both, so it is specific to the correlated rewrite.
- **REFUSAL** — a quantified predicate (ALL / ANY / SOME) is usable only
  as a bare top-level WHERE conjunct; as a select-list value, under NOT,
  under IS NOT TRUE or under OR it refuses. The engine answers all of
  them. (Compare the window chunk: the same "a predicate is a value"
  shape, one layer over.)

## THE RECORDED BACKLOG IS STALE - RE-MEASURE BEFORE PLANNING (2026-08-31)

Re-measuring 15 recorded findings against the current binary found EIGHT
already fixed by later chunks, including both TIMESTAMP WITH TIME ZONE
HIGH items (DATEADD returning a zeroed buffer, DATEDIFF always 0) and the
narrowing-CAST HIGH (now raises 22003 exactly where the engine does).
Planning a chunk from the list below without re-measuring would have
spent it on defects that no longer exist.

What was still live, all of it REFUSALS rather than wrong answers:
PERCENT_RANK, CUME_DIST and windows nested in expressions (all three
fixed 2026-08-31); and BIT_LENGTH, ASCII_CHAR, OVERLAY and CAST AS
BOOLEAN, which remain - four unimplemented scalar functions, the
next coherent slice.

## What the hunt found (2026-08-29)

A 12-agent differential hunt probed six SQL surfaces against the live
engine with twin databases, each finding then re-run from scratch by an
independent verifier told to REFUTE it. It confirmed 37 wrong answers
and 26 refusal boundaries. The branch-reconciliation cluster (8 of them)
is fixed above; what follows is the rest, ranked, as the standing
backlog. A `wrong answer` means BOTH servers answer and differ - the
prize. A `refusal` means fire-crab errors where the engine answers: a
recorded boundary under this project's law, not a defect, and ranked
below every wrong answer.

### Confirmed WRONG ANSWERS still open

- **HIGH** (scalar subqueries) — Scalar subquery over a CHAR/VARCHAR column drops the column's CHARACTER SET: a WIN1252 value comes back double-encoded (Ã©Ã  instead of éà) and CHAR pads to the wrong width
- **HIGH** (window functions) — RANGE BETWEEN UNBOUNDED PRECEDING AND <offset> FOLLOWING excludes the NULL ordering-key peer group from every later row's frame
- **HIGH** (date/time arithmetic) — DATEADD on any TIMESTAMP WITH TIME ZONE returns a fixed zeroed buffer (1858-11-16 00:01:00.0000 -23:59) for every part
- **HIGH** (date/time arithmetic) — DATEDIFF between two TIMESTAMP WITH TIME ZONE values always returns 0
- **HIGH** (the CAST matrix and string functions a) — CAST to a narrower NUMERIC silently wraps modulo 2^32 / 2^16 instead of raising 22003 "numeric value is out of range"
- **HIGH** (the CAST matrix and string functions a) — Implicit CHARACTER SET NONE widening decodes NONE bytes as Latin-1 instead of treating them transparently, corrupting concatenation, REPLACE, POSITION and equality
- **HIGH** (the CAST matrix and string functions a) — UTF8 -> OCTETS implicit conversion transliterates to Latin-1 instead of taking raw storage bytes, and announces len 64 where the engine announces 160
- **HIGH** (the CAST matrix and string functions a) — NONE || WIN1252 resolves the NONE bytes through Latin-1 instead of WIN1252 (0x9F becomes U+009F, not U+0178)
- **MEDIUM** (scalar subqueries) — Scalar subquery describes from the executed VALUE, not the inner column: SMALLINT and small BIGINT both come back LONG, a large BIGINT comes back INT64 — the same statement describes differently depending on the data
- **MEDIUM** (scalar subqueries) — Scalar subquery over NUMERIC/DECIMAL announces sub_type 0, erasing the NUMERIC(1) vs DECIMAL(2) discriminator, and widens the storage type
- **MEDIUM** (scalar subqueries) — Scalar subquery that matches no rows describes as TEXT(1) CHARACTER SET NONE instead of the inner column's SMALLINT
- **MEDIUM** (scalar subqueries) — Subquery-bearing select-list expressions lose the Nullable flag and propagate the non-nullable claim through arithmetic, CHAR_LENGTH and CASE
- **MEDIUM** (window functions) — RANGE BETWEEN <offset> PRECEDING AND UNBOUNDED FOLLOWING gives a NULL ordering-key row only its own peer group instead of the tail of the partition
- **MEDIUM** (common table expressions) — A CTE whose name shadows a real table and self-references is answered with PostgreSQL-style scoping; the engine refuses it as cyclic
- **MEDIUM** (common table expressions) — String expression over a CTE/derived literal column is described with charset 255 CS_dynamic where the engine says charset 0 SYSTEM.NONE
- **MEDIUM** (date/time arithmetic) — DATE - DATE describes as INT64 len 8 where the engine says LONG len 4, and the wrong width cascades to INT128 in further arithmetic
- **MEDIUM** (date/time arithmetic) — TIME - TIME describes as INT64 subtype 0 len 8 where the engine says LONG subtype 1 (NUMERIC) len 4
- **MEDIUM** (date/time arithmetic) — TIMESTAMP - TIMESTAMP describes sub_type 0 where the engine says 1 (NUMERIC), and marks the all-literal form Nullable where the engine does not
- **MEDIUM** (date/time arithmetic) — Implicit temporal-to-string conversion in concatenation describes VARCHAR(32765) instead of the natural width (DATE 10, TIME 13, TIMESTAMP 25)
- **MEDIUM** (the CAST matrix and string functions a) — ASCII_VAL over a non-ASCII character returns the code point where the engine raises 22018 "Cannot transliterate character between character sets"
- **MEDIUM** (the CAST matrix and string functions a) — LPAD/RPAD with a non-literal length argument announces double the engine's maximum length (65532), above the 32765-byte VARCHAR limit
- **LOW** (CASE / COALESCE / NULLIF / IIF / DECOD) — CAST of a literal to CHARACTER SET WIN1252 transliterates where the engine byte-copies, so a CASE branch carrying it ships 1 byte instead of 2
- **LOW** (scalar subqueries) — EXISTS in the select list describes non-nullable and names the column CONSTANT instead of BOOL
- **LOW** (scalar subqueries) — Derived table + GROUP BY: fire-crab marks the grouping column Nullable where the engine keeps the base primary key's NOT NULL
- **LOW** (scalar subqueries) — Scalar aggregate subquery inside a derived table reports RDB$FIELD_NAME 'MAX' where the engine leaves it blank
- **LOW** (common table expressions) — Any expression over a CTE (or derived-table) column is announced Nullable; the engine announces it NOT NULL
- **LOW** (common table expressions) — Recursive CTE tree walk is emitted breadth-first; Firebird emits it depth-first
- **LOW** (common table expressions) — Recursive-CTE columns leak the anchor expression's node kind into the describe `name:` field (CONSTANT); the engine leaves it empty
- **LOW** (date/time arithmetic) — UNION DISTINCT with a CAST branch blanks the field name and table origin in the describe
- **LOW** (LATERAL) — an OUTER column that is NOT NULL, used inside the lateral subquery's own expression (`FROM NN a, LATERAL (SELECT a.W * 2 AS Z FROM RDB$DATABASE) x`), is announced Nullable; the engine announces it fixed. Mechanism: the describe stand-in renders every outer reference as `CAST(NULL AS <type>)`, which is nullable by construction, so `inner_cols` cannot see that the outer column was fixed. Fixing it needs a NOT NULL stand-in of the same type and WIDTH per type (a bare literal would move the described width of text expressions), not a one-line change. The divergence is in the SAFE direction - a bit announced set that is never used - unlike announcing NOT NULL where a NULL can arrive, which desynchronises the wire

### A REGRESSION THAT CHUNK CAUSED, found and fixed 2026-08-31

Making a literal type in the attachment's charset also retyped the
LITERAL A SCALAR SUBQUERY IS FOLDED INTO. Measured against the binary
from before that chunk (df5520e), on `OCTET_LENGTH((SELECT <col>))`:

| via a scalar subquery | pre-chunk | after the chunk | engine |
|---|---|---|---|
| a WIN1252 column | 27, every attachment | 27 / 27 / 10 | 10 |
| a UTF8 column | **5 - correct** | **4 / 5 / 4** | 5 |

The WIN1252 half was already broken; the UTF8 half WORKED and the chunk
broke it, and the 358-gate sweep stayed green because no gate covered a
subquery used as an OPERAND rather than as a whole select item. Fixed by
splicing a charset-carrying literal; `serve-real-subqdesc` 40 -> 70 now
covers the operand shapes under all three attachments.

### The charset cluster (hunt findings 10, 11, 12, 30) - DONE (2026-08-31)

Implemented as "a literal is bytes in the attachment's charset, and a
byte carrier is never transliterated". The roadmap framed this as a
CONCATENATION problem; re-measuring against the engine showed the concat
symptom is DOWNSTREAM of the literal's charset, and that the same miss
also corrupted data at rest and inverted a truncation check. What the
implementation actually needed, in the order the measurements forced:

- `stmt_text_decode` at the three statement entry points (op_prepare and
  both exec_immediate forms) - `from_utf8_lossy` destroyed a lone `0xE9`
  into U+FFFD BEFORE the tokenizer saw the literal.
- the `TfCs::Att` arm in `expr_value_charset` and in
  `cast_source_charset` - the width machinery already carried the
  attachment sentinel; only the VALUE side was guessing UTF-8. Two paths
  disagreed about one value: `OCTET_LENGTH(N||'')` answered 7 while the
  CAST of the same expression shipped 9 bytes.
- resolving the sentinel in `recode_concat`, which is what routes a
  carrier operand through `transcode_text` - that function already
  implemented the byte-copy law correctly and was simply never reached.
- the literal's charset on the STORE path (`InsVal::Str`), the same law
  `wire_text_param` already applied to a wire parameter.
- `respond_malformed_statement`, the engine's DSQL `-104` vector, for
  statement bytes that are not a string in a multi-byte attachment.
  fire-crab had been ACCEPTING those and storing U+FFFD.
- the EMIT path and its capacity check, together: the emit's byte-carrier
  branch tested a POSITIVE ttype only, so it never fired for a literal or
  any expression (whose charset travels as a negative sentinel). The
  capacity check's own comment said "the condition is the EMIT's own" -
  changing one without the other raised a 22001 on a value the engine
  returns. Both now read the same resolved `src_id`.
- `recode_conditional`, the byte-copy law for CASE / COALESCE / IIF,
  which the concat recoder cannot cover. Branches wrap individually,
  because WHICH branch runs is a runtime choice.
- the INSERT blob-literal path, whose comment recorded the old assumption
  in as many words ("a carrier stores the client's bytes verbatim - the
  UTF-8 the SQL text arrived as"). A literal into a UTF8 text blob stored
  SEVEN bytes where the engine stores five.
- `answer_prepare`'s NAME items: an identifier travels in the
  attachment's charset like any other text, so a quoted alias came back
  doubled (`ăî` announced as `ÄÃ®`).

Two gates recorded these divergences as `known_diff` - a check that FAILS
when a recorded divergence starts agreeing, so that fixing it trips the
gate instead of passing silently. Both fired and are ordinary assertions
now. That convention is worth keeping: a recorded divergence nobody
re-checks is just a bug with better manners.

The old text is kept below for the record.

### The charset cluster, as originally recorded

All four reproduce, and probing them established ONE law that explains
every case: **NONE and OCTETS are BYTE CARRIERS. A conversion to or from
one is a BYTE COPY - never a transliteration through Latin-1.** The
carrier machinery (`intl::carrier_decode` / `carrier_encode`) already
exists and is correct; it is the concatenation and emit paths that do
not reach for it.

Measured, under a NONE attachment, over a NONE column holding
`73 74 72 61 C3 9F 65`:

- `N || ''` - the engine passes the NONE bytes through unchanged;
  fire-crab decodes them as Latin-1 and re-encodes to UTF-8, shipping
  `73 74 72 61 C3 83 C2 9F 65`. The emit path HAS a byte-carrier branch,
  but it is gated on `c.sub_type` being a positive ttype, and an
  EXPRESSION carries its charset as a negative sentinel - so the branch
  never fires for a concatenation.
- `U || O` (UTF8 with OCTETS) - the engine answers OCTETS len 160
  (32*4 + 32) and takes the UTF8 operand's RAW STORAGE bytes `C3 9F`;
  fire-crab announces len 64 and transliterates to `DF`. Note OCTETS
  DOMINATES here, where NONE yields.
- `N || W` - the engine concatenates the raw NONE bytes and the raw
  WIN1252 bytes; fire-crab returns an essentially EMPTY value, which is
  worse than the reported "wrong bytes" and needs its own diagnosis.
- `CAST('<multi-byte>' AS VARCHAR(4) CHARACTER SET WIN1252)` - under a
  NONE attachment the literal arrives as raw bytes and the engine
  BYTE-COPIES them; fire-crab transliterates.

The reason this is a chunk and not a patch: the result of `N || W` is
the two operands' OWN stored bytes concatenated, so the conversion is
PER OPERAND at concat time, not a single fix-up at emit. That is the
shape the implementation has to take.

### Refusal boundaries recorded (fire-crab refuses, the engine answers)

- medium — REFUSAL: scalar subquery over FLOAT, DOUBLE PRECISION, DATE, TIME, TIMESTAMP or DECFLOAT fails to prepare
- medium — A CTE containing a window function PREPAREs with a byte-identical correct SQLDA, then fails at EXECUTE
- low — Introducer-prefixed literal (_WIN1252 'x') is refused, in a CASE branch and on its own
- low — REFUSAL: a scalar subquery as the LEFT operand of a comparison in WHERE fails to prepare
- low — REFUSAL: a CORRELATED EXISTS / NOT EXISTS used as a select-list value fails to prepare
- low — Multiple-row scalar subquery: fire-crab raises SQLSTATE 21000 at PREPARE, the engine emits the output SQLDA first and raises the identical error at fetch
- ~~low — PERCENT_RANK() and CUME_DIST() are not implemented~~ **DONE 2026-08-31**: both answer, defined over the PEER GROUP (ties share a value) and described as DOUBLE
- low — RANGE frames whose bounds are keyword-only (UNBOUNDED / CURRENT ROW) fail to parse, though the semantically identical default frame works
- low — RANGE offset frames are refused unless the ORDER BY key is a scale-0 integer
- ~~low — A window function nested inside any expression~~ **DONE 2026-08-31**: calls are lifted out and folded as their own columns. Note the two traps: the `OVER` of `COALESCE(SUM(V) OVER (...), 0)` sits at paren DEPTH 1, so a depth-0 search silently declines it; and `split_alias` accepts a bare alias only if the head ends with `)` or PARSES, which a head containing OVER does not - so `... + 1 AS R` worked while `... + 1 R` refused
- low — Window functions cannot be combined with GROUP BY, SELECT DISTINCT, or a frame clause on an ORDER BY-less window
- low — Windowed LIST() and non-constant LAG/LEAD offsets are refused
- low — REFUSAL: window function with OVER (ORDER BY ...) inside a CTE or derived table prepares, then fails at fetch
- low — REFUSAL: a CTE cannot be referenced from a subquery, a union branch of the main query, or a scalar subselect
- low — REFUSAL: forward reference to a CTE declared later in the same WITH list
- low — REFUSAL: CTE over a UNION mixing a UTF8 VARCHAR column with a longer literal fails to prepare, and with no diagnostic detail lines
- low — REFUSAL: a recursive CTE with more than one recursive member
- low — Arithmetic between a TIMESTAMP WITH TIME ZONE and a number is refused at prepare time
- low — CAST from TIME, or from TIMESTAMP WITH TIME ZONE, to DATE/TIMESTAMP is refused with a conversion error (includes CAST(CURRENT_TIMESTAMP AS DATE))
- low — LOCALTIME(n) and LOCALTIMESTAMP(n) with an explicit precision are rejected at prepare
- low — A bare NULL literal as either DATEDIFF operand is rejected, and the FROM/TO form misparses it as a table reference
- low — OVERLAY is not parsed: fire-crab reports "Table unknown" on the FROM keyword inside OVERLAY
- low — BIT_LENGTH is unknown to fire-crab (CHAR_LENGTH and OCTET_LENGTH work)
- low — ASCII_CHAR is unknown to fire-crab
- low — CAST(... AS BOOLEAN) is unsupported
- low — The _CHARSET introducer on a literal (_WIN1252 X'809F', _UTF8 '€') is unsupported
- **LOW, NEW (2026-08-31, measured)** — a CATALOG character column is announced `charset: 3 SYSTEM.UNICODE_FSS` where the engine announces `charset: 4 SYSTEM.UTF8` (`SELECT RDB$CHARACTER_SET_NAME FROM RDB$CHARACTER_SETS`, same len 252, same type). Verified PRE-EXISTING: the binary from before the literal-charset chunk (df5520e) announces it the same way, so it is not a regression from that work. Found while gating the object-id fix; `serve-real-objid` deliberately does NOT compare that describe, and says so, rather than encoding an unrelated bug as its own pass/fail
- ~~**HIGH** — CONNECTION KILL~~ **FIXED 2026-08-31** (`serve-real-objid`): with `SET SQLDA_DISPLAY ON`, a CHARACTER-typed result as the THIRD statement of a connection kills fire-crab's connection - `SQLSTATE 08006`, `-send_packet/send` - and EVERY later statement on it returns 08006. Bisected: position 1 or 2 is fine, three character statements in a row are fine, four integer statements are fine, a character COLUMN triggers it as well as a literal, and with SQLDA_DISPLAY off it never fires. Traced: on the first character-typed result fbclient opens a SECOND transaction and walks `RDB$CHARACTER_SETS` through the LEGACY BLR request API (`op_compile`, then `op_start_and_receive` and 53 `op_receive`) to resolve the charset NAME for the describe. That walk SUCCEEDS, and my first hypothesis - that it left state behind, or that the ChaCha64 cipher was involved - was WRONG on both counts: the failure reproduces identically over a CLEARTEXT connection, and the legacy path's every write goes through the encrypting writer. THE ACTUAL MECHANISM: fire-crab minted BLR request ids from their own counter starting at `BLR_REQ_HANDLE = 5` while statements ran 3, 4, 5, ... A compiled request and a prepared statement are different KINDS of object sharing ONE client-side id space - fbclient keeps a single untagged-union `port_objects` array (remote.h:1356) and the engine allocates every id by scanning that one array (`rem_port::get_id`, remote.h:1600), so the engine can never collide. When the walk's request took id 5 while the third statement held id 5, the compile response overwrote `port_objects[5]`, and the next `op_execute` failed the client's own typed-handle check INSIDE its encoder - `xdr_sql_blr` writes the input-BLR length (protocol.cpp:1910) and only then looks the statement up (:1922), so the CLIENT abandoned a half-written packet. Hence `send_packet/send`: the failing write is the client's, not the server's. The rule was never "position 3" - it is "the first op_compile lands on an id a live statement holds", which is why prepending `SHOW TABLES` (which burns a request id) moved the failure to position 4. FIXED by minting requests from the statement counter, which already stepped over live transaction handles for exactly this reason. NOTE FOR ANY GATE: a charset or describe gate is by nature a stream of character-typed statements, so this can poison a whole run and a diff-counter can read the dead tail as agreement - put describe checks in their own connections, one statement each (`serve-real-litcs` does)
- low — REFUSAL: an aggregate applied DIRECTLY to a lateral join (`SELECT COUNT(*) FROM T a, LATERAL (...) l`) refuses at prepare. `plan_lateral` delegates to the join planner and keeps only a `Plan::Join`; an aggregate makes that a `Plan::JoinGroup`, whose grouping columns index the COMBINED joined record, so the lateral cannot simply be substituted underneath it. The same query written with an explicit derived table IS served, which is what makes this a boundary rather than a hole

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

**THE THIRTEEN GATES NOBODY WAS RUNNING — WIRED IN 2026-08-28.** Their
`$1` is a prepared DATABASE rather than a port, and the runner had
nothing to give them, so in every sweep each printed a usage line and
exited 1: `join`, `outerjoin`, `project`, `insert`, `syscat`,
`joinchain`, `joingroup`, `orderagg`, `groupby`, `having`, `query`,
`where` and `types` — **171 checks over the core query surface** (joins,
grouping, HAVING, projection, the system catalogue, the type matrix)
that nothing was watching. They pass, so nothing had rotted; but a gate
nobody runs is a gate that has stopped telling the truth. The runner
builds the two fixtures once (`qa/mkjoindb.sh`, `qa/mktypesdb.sh`) and
hands each gate its OWN COPY, because they write.

**AND THE SUMMARY WAS BLIND TO THEM.** It counted DIFF and FAIL LINES,
so a gate that dies without printing one was invisible — which is
exactly how thirteen gates could fail in every sweep while the summary
said 0. A non-zero `rc` is now counted and reported beside them.

**RUNNING THEM ALL: `qa/sweep.sh`.** The suite is 340 gates and was
45-60 minutes serially, which is long enough that it stops being run.
A gate is mostly WAITING — on its own `fcwire`, on the engine at 3050,
on fsync — so it is latency-bound before it is CPU-bound, and a few at
once shortens the wall clock well past the core count: **1659s at -j 4,
340 gates, 9321 checks, 0 DIFF**. What makes it safe is that a gate
already takes its port as `$1` and builds its own scratch databases, so
each gets a private one. Three things it must get right, each learned
by getting it wrong: the log keeps the SERIAL `=== gate` / `--- rc=`
format and buffers each gate whole, because every habit built around a
sweep greps for those; gates that MEASURE TIME or contention run alone
afterwards, since a parallel sweep makes a loaded box and such a gate
starts reporting the load instead of the server; and `$1` is a PORT for
327 gates but a DATABASE PATH for 13, which does not error — it fails
eleven checks with an I/O error naming a file called "20676".

Ordering the slow gates first (`qa/sweep-times.txt`, kept in the repo)
measured NO gain here — 1659s either way. At -j 4 this two-core box is
saturated, so the wall clock is total work over parallelism and no
schedule changes total work; the ordering is kept because it costs
nothing and does pay on a wider box or a filtered run. The remaining
lever is the slow gates themselves: `textcolcmp` alone is 291s of the
1659.

Those 13 database-path gates (`join`, `groupby`, `having`, `query`,
`project`, `where`, `insert`, `syscat`, `types`, `outerjoin`,
`joinchain`, `joingroup`, `orderagg`) have never run in ANY sweep,
serial or parallel. Wiring their fixtures in is real uncovered surface.
