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
TIMESTAMP (the 2020-01-01 base-date re-anchor law), EXTRACT/AT TIME
ZONE, CREATE INDEX on tz columns, tz parameters, no-space zone
tails, EXECUTE BLOCK tz literals (all clean refusals).

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
ALTER cycle can hit the pre-existing catalog page-full refusal — fc
writes catalog versions UNPACKED (no SQZ run-length writer yet),
so a patched RDB$FIELDS row blows out its RLE'd size. A SQZ writer
is now a recorded candidate (it would shrink every fc-written row).
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
