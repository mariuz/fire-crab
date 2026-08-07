# Roadmap: from converted models to a working engine

Every increment so far has answered the same question — *what does the
engine do here?* — and answered it with a differential. That has produced
a server whose SQL surface agrees with Firebird across 150+ gates, and,
alongside it, nine converted subsystems with their own oracles.

This document is about the two things that are **not** more SQL surface.

## Where the project actually stands

The subsystem map's rows fall into three states, and the difference
matters more than the row count:

| state | rows | what it means |
|---|---|---|
| **done** | on-disk structures, record decode + RLE, PIP, pointer/data pages, B-tree decode, TIP/MVCC, GC/sweep, BLR decode | converted and held against an oracle; the server depends on them |
| **converted, wired** | `ods`, `blb`, `auth`, `svc`, `exe`, `dsql` | the running server links and uses them |
| **converted, wired** | `evt` | `POST_EVENT` posts into it, commits move its counters, and the delivery is CARRIED over the auxiliary connection - the paper's own `samples/nodejs/events.js` prints the same lines against fire-crab as against the engine (W5 done) |
| **converted, wired** | `stmc` | the plan a statement resolves to is kept per attachment and dropped by DDL. It took moving the two prepare-time FOLDS to fetch first — a lone aggregate and a `GEN_ID` read were computed by the planner and carried in the plan, so a kept plan answered the same number for ever |
| **wired** | `lck` | a writer that meets another transaction's uncommitted row waits on that transaction's own lock and then re-reads, and two waiting on each other are denied by the wait-for scan with the engine's `isc_deadlock` (W4) |
| **being wired** | `opt`, `cch`, `pio` | the server asks `opt` for the access path and takes an index when it says so (W1); the pages of a file live once per process in `cch`'s buffer pool and are flushed in its careful write order (W2), and written with `pio`, in the open mode the header's Forced Writes flag calls for (W3) |

That third row was the honest headline, and it is one crate long now:
`crates/wire/Cargo.toml` depends on `-lck` as well as `-opt`, `-cch`
and `-pio`; only `-evt` is still a conversion nothing calls. The optimizer's
choice is executed rather than merely printed — for the one shape W1
covers so far. The lock manager arbitrates the rows two transactions
both want, and denies the cycle when they wait on each other. The page
cache holds the file's pages once for every attachment, and flushes them
in its careful order — what it does not do yet is hand them out one page
at a time.

And inside the SQL layer there is a second structural gap: the server
answers views, CTEs and constant subqueries by **rewriting SQL text and
re-planning it**, where the engine builds a tree of record sources. That
approach has worked far better than it has any right to — but it is why
a CTE body that GROUPs refused, why `FROM (SELECT ...)` did not exist,
why `WITH RECURSIVE` could not work, and why a qualifier-stripping pass
had to be taught not to reach inside a subquery. R1–R6 have closed all
four; R7 is the removal of what they replaced.

## Measured gaps that are nobody's slice yet

- **A scalar subquery's aggregate describes as BIGINT.** `SELECT (SELECT
  MAX(C) FROM V) AS M FROM T` announces an INT64 where the engine
  announces the source column's own INTEGER; the ROWS agree on every
  probe. It is the prepare-time aggregate fold's type (`Plan::Scalar` is
  "a single BIGINT computed at prepare" by construction), so the slice is
  MIN/MAX/SUM carrying their source's type rather than the fold's, which
  touches every consumer of that fold and is not a one-line widening.
  Reproduces on binaries from before it was noticed — recorded, not new.
  Found while adjudicating a gate that was failing because the server had
  got BETTER, below.

- **A REFUSAL THAT WAS CLOSED AND NOT UNRECORDED.** `qa/serve-real-qualname.sh`
  section K asserted that a view inside an IN / EXISTS / scalar subquery
  REFUSES — true when written, because the nested path did not expand a
  view and a view has no records of its own. **R7 closed it** (a VIEW IS
  A ROW SOURCE, so a subquery plans one like every other consumer) and
  nobody returned to the gate, so four checks went on asserting a refusal
  that no longer happens. *A gate failing because the server improved
  reads exactly like a regression* — what distinguishes them is running
  the OLD binary, where the same four DIFFs appear. They assert agreement
  now, over a FILTERING view (`C > 1`) so the check can tell a body that
  RAN from storage that was SCANNED: both old failure modes — zero rows,
  and everything — get that one wrong. 115 → 118 checks.

- ~~A modifier dropped the SELECT LIST, and a set was not a sort~~ —
  *both fixed*, and both were found by asking a question the gate had
  been phrased to avoid. `SELECT FIRST 2 CAST(S AS INTEGER) FROM TE`
  answered the ID column where the engine answers the cast, because the
  modifier's columns are POSITIONAL over rows the inner plan has already
  projected and one path handed them BASE RECORDS. **It hid behind the
  batch fetch**, which materialises through `branch_rows` first and only
  falls through when THAT returns `None` — which happens exactly when
  some row RAISES, so one unconvertible row silently corrupted the
  answer for every good one. And `DISTINCT` is a SORT in the engine
  (`PLAN SORT (T NATURAL)`, index or no index): the set arrives
  ascending over every output column, NULLs first, where this server
  kept scan order — which a modifier then SLICES, so `SELECT FIRST 2
  DISTINCT A FROM T` returned a different ROW SET, not merely a
  different order. `UNION` is the same node; `UNION ALL` does not sort;
  an explicit `ORDER BY` REPLACES that sort rather than sitting under
  it. **Why no gate saw it**: every `DISTINCT` check in
  `qa/serve-real-modifiers.sh` pinned the order with `ORDER BY 1`, which
  that file's header states as a deliberate choice — and it is the right
  one for `FIRST`/`SKIP`, where "the first two" is undefined without an
  order. For `DISTINCT` it removed the question instead of answering it.
  48 → 66 checks, 18 DIFF against the pre-fix binary. *A gate's stated
  convention is worth re-reading for the case it was not written about.*

- ~~A bare boolean parameter as a whole predicate~~ — *fixed*. `WHERE ?`
  is `TRUE = ?` with the `TRUE =` elided: the engine describes the slot
  as `SQL_BOOLEAN` and answers ordinary three-valued logic, and that leaf
  was one the parser already built.

- ~~`WHERE ? IS NULL`, `? LIKE 'o%'`, `? BETWEEN 1 AND 3`, `? IN (1,2)`~~
  — *fixed*, plus `? STARTING WITH`, `? LIKE ?`, `? STARTING WITH ?`,
  and the refuter's `N STARTING WITH ?` (integer column, text slot).
  The load-bearing probe discovery: the mirrored comparisons already
  answered, so BETWEEN/IN are a parse-time desugar into `lo <= ? AND
  hi >= ?` / an OR of equalities, all referencing the ONE slot — only
  IS NULL/LIKE/STARTING needed new bind-time terms. Engine laws pinned:
  `? IS NULL` describes as SQL_NULL (32766/len 0) and the bind is
  TYPE-BLIND; NULL binds are UNKNOWN under both polarities everywhere;
  `? BETWEEN 1 AND 3` takes `'2.5'` and raises a conversion error on
  `'x'` at EXECUTE on both sides; `? NOT IN (1, NULL)` is never true.
  `qa/serve-real-paramshapes.sh`, 87 checks. **A DOUBLE bind refuses
  where the engine answers** on every param-tested shape (`? BETWEEN 1
  AND 3` bound 1.5 — engine all rows, fc refuses at execute), and the
  root is pre-existing in the mirrored comparison leaves (`? >= 1.5`
  bound a double refuses too — "the mirrored comparisons already
  answered" held only for text and integer binds). Matching it needs
  the engine's double rendering/compare rules; fail-closed until then.
  Refused deliberately, with
  the engine's answers recorded in the gate: `? IN (?, 2)` (the engine
  types the inner `?` from the list), `? IN (1, 'a')` (per-bind
  conversion semantics), `? BETWEEN 1 AND 'x'` (conversion deferred to
  execute), `? IS DISTINCT FROM 5`, `N LIKE ?` (same treatment as
  STARTING would fix it — the probes are already captured).

- ~~A text parameter into a numeric column or filter~~ — *fixed*. It was
  the largest single hole in the parameter surface (82 of 119 measured
  disagreements). See `qa/serve-real-textnum.sh`; the store side and the
  filter side turned out to have different rules, and the filter
  comparison is exact rather than through a double.

- **The per-statement cost at HEAD is 2.92 ms against the engine's
  0.95 ms**, measured on a verified-quiet box (nproc 1, load 0.04, 97%
  idle, serialised). The metadata cache took it from 19.6 ms and server
  CPU from 3,810 to 730 ms per 200 statements. The residual is CPU-bound,
  not waiting, and the cause is the same disease at the next call site:
  `catalog::relation_columns` (`catalog.rs:139`) is an uncached full walk
  of `RDB$RELATION_FIELDS` with 121 call sites — 60.9% of what is left,
  with `sqz::unpack` and `catalog::cstr` beneath it. `intl::fit_char` is
  secondary.

- **169/169 does NOT mean the cost model is right everywhere the guard
  used to refuse.** On a stale UNIQUE/PK index there is a structural miss
  at (1200, 700) — engine `PLAN HASH`, fcopt `JOIN_SWAP`, loop 4375.7
  against hash 6417.7, a 47% margin — and it is **pre-existing**: it
  reproduces on the same database with FRESH statistics, where the guard
  never fired. Removing the guard unmasked it; it did not create it.

- ~~A second per-statement stall, ~44 ms~~ — *explained, and half of it
  was self-inflicted*. A `cargo test` binary left spinning on this
  ONE-CORE box since Jul 31 (14h41m of CPU) halved every measurement;
  the rest was `system_relation_formats` being uncached and called five
  times per statement. Both fixed. **Any timing measurement on this box
  must check `nproc` and the load first** — see the playbook.

- **(superseded)** With
  `TCP_NODELAY` set, 200 sequential `SELECT 1 FROM RDB$DATABASE` still
  take 8,689 ms against the engine's 293. About 3.8 s of that is server
  CPU and the rest is waiting; the client socket's own `noDelay` changes
  nothing and the cost barely scales with database size (2.3 MB → 8.9 s,
  25 MB → 11.1 s). Unfound, and named so it is not mistaken for finished.

- ~~FRAGMENTED RECORDS ARE NOT ASSEMBLED~~ — *fixed*. `rhdf` data starts
  at 22, not 13/16; `assembled_image` follows `rhdf_f_page`/`rhdf_f_line`
  and joins the compressed pieces before unpacking once. All 69 indexes
  on the 99-relation fixture are visible again (was 52). `image()`
  returns `None` for a fragmented record on purpose, so the 33 callers
  not yet converted keep skipping rather than silently gaining truncated
  rows — converting the rest is incremental work, and `fcstat`, `exe`,
  `ddl` and `catalog` are still on the old path.

- **Fragment assembly is wired into the READ paths; the PATCH paths still
  refuse.** `catalog.rs` (name resolution), nine read loops in `ddl.rs`
  including `backfill_index`, both MVCC sites in `tra.rs`, `opt`'s four
  catalogue readers and the server's four record readers all assemble
  now. The in-place rewriters — `alter_domain_type`,
  `alter_table_alter_column_type` and the other `dp.record(slot)` patch
  sites — deliberately do NOT: patching a fragmented record means writing
  across pages, which fire-crab cannot do, and refusing is the correct
  boundary. `fcstat`, `exe` and `sysfmt` still use the old path and are
  incremental work.

- ~~The head-in-place rewrite~~ — *done*, worth 179 of 184.
  `dml::patch_head_in_place` pokes a fragmented record's HEAD in place
  and refuses when the field lives in the tail; the guard is "every
  poked range ends within the head's unpacked length". Validated against
  the live engine by an adversarial pass - head is a byte-prefix of the
  assembled image 266/266, every poke head-resident, full column
  differential byte-identical including tail fields, `gfix` clean, and
  `COMMENT ON` text readable through the engine after 88 pokes. The
  `ddl.rs` patch sites route through it when `INCOMPLETE` is set, and
  `serve-real-restored.sh` reads the patched values back THROUGH THE
  ENGINE rather than trusting survival.

  It did NOT acquire the four missing machinery items (rhdf writer,
  packed stream truncate, tail teardown, page compaction) and should not:
  each is a new way to write into a user's database, and nothing in the
  184 statements needs one.

  **The remaining 5** are indexes owning a fragmented
  `RDB$INDEX_SEGMENTS` row, deleted via the same guard. Still refused,
  deliberately.

- **(historical, kept for the mechanism)** Fixing those two DDL reads
  would NOT have fixed them, and that was the trap — the head-in-place
  rewrite sidesteps `push_back_version` entirely (a byte edit inside one
  record's payload, no back version pushed).
  Both `patch_sys_row` and `deferred_drop_index` write back through
  `dml::update_records`, and `dml::push_back_version`
  (`crates/ods/src/dml.rs:502`) rejects the record at :517-521 whenever
  its flags carry `CHAIN|BLOB|FRAGMENT|INCOMPLETE|DELETED`. Note the gap:
  `is_primary_record` (`data.rs:74`) excludes only
  `CHAIN|FRAGMENT|BLOB|DELETED`, so the **one flag in the difference is
  INCOMPLETE** — exactly the fragmented rows. Converting the reads to
  `assembled_image` would change the error message and nothing else. The
  WRITE path has to learn fragments first, or neither statement moves.

  This also explains the residual `DROP INDEX` failures on rows that are
  NOT fragmented: it also deletes the index's `RDB$INDEX_SEGMENTS` rows
  through the same `push_back_version`, and that relation carries 26
  fragmented rows on a restored file. Same cause, different relation.

- **(superseded by the head-in-place rewrite, kept for the numbers)**
  Two DDL statements refused on a fragmented catalogue row, and the cost
  was measured. Both were in-place patch sites that could not rewrite a
  record spanning pages, so they failed closed - `gfix -v -full` clean,
  the engine still read the file. NOT the durable-wrong-state class that
  `backfill_index` was. The refusals were common on a restored database:

  * `COMMENT ON TABLE` (`ddl.rs:5716`, `patch_sys_row`) - engine 220/220,
    fire-crab 132 OK / **88 refused**, and the 88 are EXACTLY the tables
    whose `RDB$RELATIONS` row is fragmented (the two sorted name sets
    diff empty). Control: against the same schema before `gbak`, where no
    row is fragmented, fire-crab is 220/220.
  * `DROP INDEX` (`ddl.rs:4472`, `deferred_drop_index`) - on the 60
    indexes whose catalogue row is whole, fire-crab matches the engine
    **statement by statement**, including the 24 constraint indexes both
    correctly refuse. On the 178 fragmented ones the engine does 92 and
    fire-crab does 0. **92 statements the engine performs and fire-crab
    will not.**

  Fixing these needs a record REWRITE that can re-fragment across pages -
  a real slice in `ods`, not a patch.

- **Restored databases fragment their catalogues heavily, and not where
  the source did.** Measured on a 220-table schema: 292 fragmented rows
  after `gbak -b`/`gbak -c`, concentrated in `RDB$INDICES` (27.4% of
  rows) and `RDB$RELATIONS` (28.4%); the un-backed-up source had 45, in
  different relations. **Restore does not preserve fragmentation, it
  relocates it.** And it is not the >8151-byte case: `dpm.epp:2650-2656`
  fragments whenever an UPDATE's new version exceeds the space left on
  the page the record already occupies, so ordinary small catalogue rows
  fragment as restore replays DDL onto crowded pages. An EMPTY database
  gains 26 fragmented rows from a backup/restore round trip alone.

- **fire-crab refuses to WRITE a row that would fragment.** A cross-page
  store it does not implement. `qa/serve-real-fragment.sh` asserts the
  refusal so it cannot quietly become a half-written row.

- ~~`STARTING WITH` is not in the predicate parser~~ — *fixed*. One
  leaf beside LIKE, recognized by Ident text because STARTING is NOT a
  reserved word (probed: a column may be named by it). Per-byte prefix
  on the stored value with no trimming on either side — which exposed
  that the BLR path's `BBool::Starting` DOES trim both sides (right for
  the padded metadata columns isql's SHOW reads, wrong in general — a
  recorded divergence, not copied). An INTEGER column coerces to its
  decimal text per row. WHERE, HAVING, join filters, UPDATE/DELETE and
  parameters all funnel through the same term; the index path scans
  (fcopt answers INDEX for a prefix but no band-builder exists — the
  deliberate prefix band via `prefix_successor` is its own measured
  increment). Refusals kept: a column prefix, an expression prefix, a
  numeric prefix literal — the engine's answers for each are in
  `qa/serve-real-starting.sh` for the slice that converts them.

- **The engine converts a NONE column into the ATTACHMENT charset on
  the way out, and fire-crab does not.** Measured with plain ASCII: a
  stored `'ab '` (OCTET_LENGTH 3) answers `'ab'` through a UTF8
  attachment and `'ab '` through a NONE one; fire-crab passes the
  stored bytes through on every attachment. Same family as the
  transliteration entry below, but it bites on a BLANK, not a high
  byte — any gate comparing VARCHAR VALUES with trailing blanks must
  compare a server-side length instead (see serve-real-starting.sh).

- ~~`qa/serve-real-index.sh` 346/13 and `viewjoin` 33/3 environment
  drift~~ — *diagnosed and fixed*, and the label "numeric overflow on
  the BIGINT-family keys" was a red herring. All 16 DIFFs were ONE
  defect selected by what the check PROJECTS, not what it filters on:
  a ≥2-character NONE `VARCHAR` through the driver's default UTF8
  attachment. A stock node-firebird (2.11.0) declares its output slot
  at the column's byte length; `blr_varying` carries no charset, the
  engine resolves the slot to the ATTACHMENT charset (4 bytes/char),
  and the capacity check raises "string right truncation" per row —
  the ENGINE erroring, correctly, on the client's own declaration. The
  green baselines ran on the patched 2.14.1 checkout
  (`/home/ubuntu/work`, has the node-firebird#422 fix); the drift was
  a NODE_PATH note gone stale. Both gates are pinned to
  `encoding:"NONE"` now (driver-proof) and answer 359/0 and 36/0
  under either driver.

- ~~fire-crab IGNORES the client's declared output message format~~ —
  *fixed*. The attach's `isc_dpb_lc_ctype` is parsed (absent = NONE),
  the out-BLR is parsed where op_fetch/op_execute2 discarded it, and
  the row encode enforces the engine's probed rule: transliterate-skip
  when source and destination are distinct REAL charsets (no length
  enforcement at all — probed); else cap = declared_len /
  bytes_per_char(dest) when dest is multibyte or the value exceeds the
  slot; a value over cap first TRIMS TRAILING BLANKS and delivers
  padded-to-cap SILENTLY if it then fits; else raises the engine's
  exact vector (arith_except << string_truncation << trunc_limits <<
  cap << UNTRIMMED actual - a CHAR(5) 'ab' raises (1, 5)). Rows before
  the failing row still ship; INSERT..RETURNING raises AND does not
  persist on either side. The describe grew a charset dimension on the
  way: expression columns announce the ATTACHMENT charset where the
  engine does (UPPER(V6) stays NONE, `V6||'x'` goes UTF8 at 4
  bytes/char - probed table in the gate). `qa/serve-real-outblr.sh`
  runs the same statements through BOTH driver generations.

- ~~`EXECUTE PROCEDURE` on an ENGINE-created FB6 procedure fails "no
  such procedure"~~ — *stale, and the entry's own hypothesis was what
  closed it*: the qualifier WAS the bug, and the schema-qualified-call
  fix struck it out further down. Re-probed on engine-created
  procedures, selectable and not, bare and `PUBLIC.`-qualified, in
  `EXECUTE PROCEDURE` and in `FROM` — byte-identical on both sides.

- **`qa/auth-srp.sh` has harness bugs**: its NF path is $0-relative
  (node resolves it as a module unless invoked by absolute path), its
  default port has no listener on this box, and the 30 s security-db
  wait is occasionally short. Green (13 OK) when invoked by absolute
  path. Unclaimed.

- **(superseded by the fix above, kept for the record)** fire-crab
  IGNORED the client's declared output message format.
  Found by the drift diagnosis: op_fetch discards the client's BLR
  (`server.rs` "read_wire_bytes // blr"), as do op_exec_immediate2 and
  op_execute2's out_blr — rows encode from fire-crab's own formats. So
  for a stock 2.11.0 client, THE ENGINE REFUSES (per-row truncation on
  a too-narrow declared slot) WHAT FIRE-CRAB ANSWERS. Being a faithful
  twin means: record `isc_dpb_lc_ctype` at attach, parse the out-BLR
  text slots (`parse_param_blr` already decodes these shapes for
  input), and raise `isc_arith_except << isc_string_truncation <<
  isc_trunc_limits << Num(cap) << Num(actual)` in place of the row
  when a non-NULL text value exceeds `declared_len /
  max_bytes_per_char(attachment charset)`. Zero-row and NULL results
  succeed (probed). Its own slice, unclaimed.

- **(superseded, kept for the mechanism)** A record too large for one page is stored as a head with
  `rhd_incomplete` (flag 8) plus `rhdf` continuation fragments on other
  pages. `RecordHeader::is_primary_record` (`crates/ods/src/data.rs:65`)
  excludes CHAIN, FRAGMENT, BLOB and DELETED — **but not INCOMPLETE** —
  and `image()` unpacks only that record's own bytes. So a fragmented row
  decodes to a TRUNCATED image, and every field past the cut reads short
  or missing.

  **Measured, on a database with 99 relations and 69 indexes:
  `RDB$INDEX_SEGMENTS` holds 15 INCOMPLETE records, and 17 of the 69
  indexes are invisible to `fcopt` — `WHERE K = 5` plans NATURAL where
  the engine plans INDEX.** The mechanism is exact: `index_columns` skips
  the truncated segment rows, `indexes_of` then drops any index whose
  segments come back empty, and the optimizer never learns the index
  exists. It degrades to a scan **silently**, which is worse than
  refusing.

  It is layout-dependent, so it comes and goes: the missing set changes
  after a `gbak` backup/restore of the same database. That is also why no
  gate has ever caught it — every fixture here is small enough that
  nothing fragments.

  Note the asymmetry that shows someone already knew: `crates/ods/src/dml.rs:518`
  DOES exclude INCOMPLETE, refusing to update a fragmented record ("target
  is not a live primary record version"). The write path was guarded and
  the read path was not.

  The fix is fragment assembly in `ods` — follow the chain from the head
  and concatenate before unpacking — and it needs its own gate with a
  fixture built to fragment on purpose (incompressible content, since RLE
  makes repeated bytes collapse and the row then fits after all; two
  attempts at a fragmenting fixture failed for exactly that reason).
  Until then, **any differential over a many-relation database is
  confounded** and must not be used to judge the optimizer.

- **Statistics that are non-zero but WRONG are not refused at all.**
  fcopt's stale guard tests `sa == 0.0`, so an index whose statistics
  were computed and then went stale as the table grew takes the ordinary
  costing path with a figure that no longer describes the data. The
  engine takes its `useDefaultSelectivity == false` branch there. That
  third region is **entirely unmeasured** — neither the fresh grid nor
  the stale one reaches it — so nothing currently says whether fcopt is
  right in it. Measured and named by the grid fleet; it needs its own
  fixture family (load, `SET STATISTICS`, then grow the table).

- **The stale grid's only threshold is the 20→30 step**, which the
  widened size set barely straddles and the old `{0,1,5,50,500,3000}` set
  jumped clean over. Any stale-region model tuned on the old grid had
  zero cells near the one boundary that decides it. When the
  `DEFAULT_SELECTIVITY` increment comes, the size set needs points
  *inside* 20-30, not merely either side.

- **The HASH band edge is not a scale-invariant ratio and does not move
  monotonically with size.** Measured brackets: at base 20 the edge is in
  (1.50, 1.55]; at base 100 in (1.30, 1.40]; at base 1000 in (1.55,
  1.70]. So the band is *narrowest in the middle*. Any "HASH iff the
  cardinalities are within factor F" model is refuted by measurement, and
  one fitted on a single decade will mis-predict another.

- ~~The `DEFAULT_SELECTIVITY = 0.1` substitution and the stale-statistics
  guard~~ — *done*. Both grids now score 169/169 with zero refusals. The
  guard's premise was false: the "internal state this crate has not
  converted" was one constant, and for the leading segment the engine's
  `MAX` is dead code. Superseded text below.

- **(superseded)** The engine
  does not refuse a zero selectivity, it substitutes
  (`Retrieval.cpp:1019-1026`, a **value** test `selectivity <= 0`, per
  matched segment; for the leading segment `minSelectivity` is provably
  inert so the answer is exactly 0.1). fcopt refuses instead. The two are
  coupled: putting the substitution in `index_selectivity` makes the
  guard unreachable as a *side effect*, and "the guard can now go" is the
  claim that was asserted twice and refuted twice. Ground truth now
  exists to judge it — the widened 169-cell **stale** grid, where the
  engine answers every cell and fcopt today answers 4 and refuses 165
  with zero wrong. Note the stale region's shape distribution is quite
  different from the fresh one (59 HASH against 13), so it is a real
  test and not a formality.

- **The `opt` cost model is plan-text fidelity only, today.** A fleet
  established the mechanism: `server.rs` discards any plan that is not a
  one-element `Access::Index | Access::Order` stream, `plan_join_bound`
  pushes a `TableScan` for every base side without ever calling
  `choose_index`, and there is no hash-join row source. So the four
  coupled cost-model edits (the doubled selectivity in `loop_cost`,
  charging position 0, pricing both hash arrangements, and the
  `MINIMUM_CARDINALITY` cap on a unique hashed side), the
  `DEFAULT_SELECTIVITY = 0.1` substitution, the one-sided-index arm, and
  the removal of the stale-statistics guard are all worth doing — the
  crate's stated purpose is agreeing with `SET PLANONLY ON`, and a
  correct model is a hard prerequisite for the keyed join — but none of
  them changes an executed plan until that join exists. They must ship as
  ONE increment for the first four, because each alone regresses a
  measured fixture.

- ~~`name` and `alias` are two describe fields, and fire-crab sets both
  to the alias~~ — *fixed*. `ProjCol` carries `fname` (item 16, the
  engine's symbolic name — `ADD`, `UPPER`, the base column) beside
  `name` (item 19, the alias, still the client's row key), `None`
  meaning "same as name" so unconverted sites stay byte-identical. The
  engine's rule is `DsqlAliasNode::setParameterName`: the expression
  sets BOTH, `AS` overwrites only the alias. Probed surprises now
  pinned by `qa/serve-real-describe.sh` (63 checks): unary minus is
  EMPTY, `NULLIF` describes as `CASE` (fire-crab answered `NULLIF` —
  a live DIFF even unaliased), UNION columns have an empty field name,
  a derived table lets the BASE name shine through where a VIEW hides
  it, a scalar subquery delegates naming to its inner item, and
  `NEXT VALUE FOR ... FROM RDB$DATABASE` is `NEXT_VALUE` (the
  GenIdIncrement path said `GEN_ID`). Two alias-visible bugs fixed on
  the way: a selectable procedure's `R AS RR` dropped the alias, and
  the folded-subquery path lost the inner symbol (patched onto the
  re-planned columns, since SQL text cannot carry it).

  Residual, flagged not gated: a derived table as a JOIN side loses
  base-name propagation (`resolve_join_col` works over synthetic
  `RelationColumn`s, an ods catalog type that should not grow a wire
  concern).

- ~~Describe items 17 (relation), 18 (owner) answer `""`~~ — *fixed*,
  and the item numbers in the plan were themselves wrong: the
  relation ALIAS is item 25, not 34 — fire-crab's 34 arm was DEAD CODE
  no client ever requests, and the engine answers 25 (empty payload)
  for every query while fire-crab OMITTED it, invisible to a
  field+alias comparison. `ProjCol` carries `relation`/`rel_alias`
  (None = `""`); owner derives at emission (SYSDBA iff a relation is
  answered — uniform, RDB$ tables included; a non-SYSDBA owner is a
  recorded boundary); item 33 (schema) was wrong in BOTH directions
  (SYSTEM tables got PUBLIC, expressions got PUBLIC instead of `""`)
  and now follows the same relation knowledge. The probed laws: a
  view's own name is NOT a binding alias but a CTE's name IS; an
  expression view column still carries the view as relation; a
  derived table lets the base relation shine through under the
  OUTERMOST alias; an inner subquery FROM alias escapes the fold; a
  union carries the first branch's relation and alias under the same
  all-plain predicate as the field name; and a BINDING ALIAS does NOT
  need a relation (`(SELECT X+1 AS C FROM T) V` answers relation `""`,
  alias `V` — refuting the first draft of the rule).
  `qa/serve-real-describe.sh` is 107 checks comparing all six describe
  strings.

- ~~A generator inside an EXPRESSION~~ — *fixed*. `RawExpr::Gen` is a
  leaf on the `RawExpr::Agg` pattern: not resolvable on its own, the
  planner assigns it a synthetic slot the per-row advance fills. The
  law that took a probe to find: the engine evaluates select-list
  ITEMS RIGHT-TO-LEFT (two bare `NEXT VALUE` items give the LEFT one
  the HIGHER value — fire-crab had been answering ascending
  left-to-right, a pre-existing wrong VALUE) and leaves within one
  item left-to-right; `gen_cols` order now carries that law. LAZY
  positions refuse: an untaken CASE branch does not bump on the
  engine, so eager slot-filling would over-bump — CASE/IIF/NULLIF/
  COALESCE-tails, WHERE, ORDER BY clauses, GROUP BY (measured: 19
  bumps for 5 rows) and FIRST/SKIP/DISTINCT all refuse rather than
  mis-answer. Two bugs died on the way: `FIRST 2 NEXT VALUE FOR SEQ`
  had ANSWERED — every value NULL and the sequence never moved
  (`branch_rows` knows nothing of gen_cols; it now refuses gen-bearing
  Projects outright, and the batch fetch materialises them in RECORD
  coordinates so expressions evaluate against filled slots); and the
  batch path's positional patch is gone with it.

- ~~Text LITERALS against numeric columns~~ — *fixed*. The compare
  side uses a DIFFERENT grammar from the store side (cvt2.cpp's
  cmp_numeric_string, not cvt_decompose): interior spaces SKIP
  (`N = '1 0'` matches 10 — unindexed; an INDEX makes the same
  spelling raise. **That half is now IMPLEMENTED rather than sided
  with** — see the two-grammar entry below; this entry's "fc sides
  with the strict grammar and the gate excludes the index-dependent
  spellings" was a stopgap and is no longer what the code does),
  e-notation goes through
  DOUBLE with a rounding window past 2^53 (refused), hex is
  op/arity/index-incoherent (refused). Conversion errors are PER ROW
  and VALUE-GATED — `Term::CmpConvErr` inherits dead-group/
  empty-table/NULL suppression from the conjunct machinery free. The
  probe pass also caught a LIVE wrong-answer bug: cmp_sides'
  rendered-text fallback compared digits as strings (`N + 0 > '9'`
  answered [] vs engine's rows) — expression-side literals convert
  now. Params were already correct and untouched.
  `qa/serve-real-textnumwhere.sh`, 152 checks. Residuals priced: text
  COLUMN vs numeric side still render-compares (its own slice).
  The indexed-EMPTY-table residual is CLOSED: an index makes the
  conversion an OPEN-time one, because the retrieval's bounds are
  built before the first record. `Predicate::key_conversion` mirrors
  that off the CATALOG (so it holds under `FC_NO_INDEX=1` too), after
  the invariant pass, for the LEADING segment of any index -
  ascending, descending or compound - keyed by a bound (`=`, `<`,
  `<=`, `>`, `>=`, BETWEEN, IN) but not by `<>`, LIKE or STARTING
  WITH; every branch of a disjunction must be servable or nothing
  converts, and one segment holds ONE value per side, so the LAST
  match written wins (`N = 'x' AND N = 5` answers [] where the other
  order raises). The same slice closed the JOIN twin: a PARTNERLESS
  row still meets the ON, because the engine evaluates the condition
  per row of the stream it walks - the pair walk's FALSE key
  comparison short-circuits the raiser where the NULL-padded row's
  UNKNOWN one does not - gated by a WHERE conjunct that names that
  ONE side, which the engine runs on that stream first.

- **(superseded)** Text LITERALS against numeric columns — `N BETWEEN '1' AND '3'`
  → 1,2,3; `N IN ('1','2')`; `N = '2'`; `N > '1.5'` (fraction kept);
  `N92 = '0.5'` — engine answers all, fc refuses at prepare; and
  `N = 'x'` raises a conversion error UNLESS a dead group suppresses
  it (`N='x' AND 1=0` → []), the constant-evaluation law now
  implemented. The fix is routing typed_term's Rhs::Str through
  text_number for Int/Numeric columns with per-row error timing —
  unblocked, unclaimed. Param twins already agree.

- ~~A NON-TEXT parameter against a TEXT column / text-column
  render-compare~~ — *fixed*. The engine coerces the COLUMN's text
  per row with the lenient compare grammar (spaces anywhere, '5' ≡
  ' 5' ≡ '5.0' ≡ '05'), raising 22018 mid-scan with the raw
  CHAR-padded value; fc's Term::TextNumCmp and the Expr::TextNum
  wraps replace the rendered-text fall-through (NAME > N answered
  string-ordered rows), and Int/Double binds against text columns
  coerce the column too. The gate DIFF also forced the FIRST-1
  streaming law: the engine stops evaluating after the take limit, so
  fc's Modified arm now streams unsorted take-limited inners.
  qa/serve-real-textcolcmp.sh, 92 checks. Residuals: blr_bool/
  temporal binds refuse (unprobed); FOR SELECT feeders still
  materialize under FIRST (unpinned).

- **(superseded)** A NON-TEXT parameter against a TEXT column — `WHERE S_VC = 5`,
  `WHERE S_VC = ?` with a boolean — is refused; the engine answers it.
  And it is not "render the value as text": the engine coerces the
  **column** to a number, per row, so that predicate matches `'5'`,
  `' 5'`, `'5.0'` and `'05'` alike — and *raises mid-scan* if any row
  holds a non-numeric string. That is a comparison rule rather than a
  conversion, it needs a per-row coercion this server has nowhere to put
  yet, and `qa/serve-real-textnum.sh` asserts the refusal so it cannot
  quietly become a wrong answer.

- **Transliteration between character sets.** `crates/ods/src/intl.rs`
  gives every text descriptor its character set and so its declared
  CHARACTER width, which is what the reads and writes needed. It does not
  convert bytes: the engine hands a WIN1252 column back in the
  connection's character set, and fire-crab passes the stored bytes
  through. Identical for ASCII content, which is what every fixture uses;
  not identical for a high byte. A codepage-table job, and named as one.

- **The engine's string→double is not correctly rounded**, and fire-crab
  is. `'99999999999999999'` becomes `100000000000000020` on the engine
  where the nearest double is `100000000000000000`. Not a gap to close —
  copying a one-ulp error would make fire-crab less accurate — but a
  divergence that exists, so `qa/serve-real-textnum.sh` compares twins
  only up to sixteen significant digits and checks correctness directly
  beyond that.

- ~~`RETURNING` comes back in a different shape~~ — *fixed*. The
  engine announces `INSERT ... RETURNING` (values form) as statement
  type 8 (exec_procedure) and answers the row INLINE on op_execute2;
  node-firebird branches object-vs-array on exactly that. fc announces
  8 for the Insert inner now and answers the ProcInvoke framing at
  execute2 (capacity enforcement moved to execute2-time, driver
  rollback keeps the outblr persistence check honest);
  UPDATE/DELETE RETURNING stay type 1 (probed).

- ~~`EXECUTE PROCEDURE` on an engine-created FB6 procedure fails~~ —
  *fixed, and the diagnosis was wrong twice*: every procedure is
  engine-created (fc has no CREATE PROCEDURE), and the failing shape
  was the SCHEMA-QUALIFIED call. Three name-handling defects:
  `parse_execute_procedure` swallowed the dot; `split_proc_call`
  refused it; and the catalog scans matched by BARE name, merging
  FB6's packaged SYSTEM rows (`RDB$PROFILER.FLUSH` collided with a
  user FLUSH → arity error). `catalog_row_public` filters both scans
  now (package/schema NULL-or-PUBLIC, absent-column tolerant for
  pre-schema ODS). `strip_gen_name` had the same disease plus a WRONG
  ANSWER: a foreign-qualifier `GEN_ID(NOSCHEMA.SQ1,0)` answered where
  the engine raises — refuses now.

- ~~Qualified TABLE/VIEW references still refuse everywhere~~ —
  *fixed* (`qa/serve-real-qualname.sh`, 70 checks). `SCHEMA.TABLE`
  wherever a relation is named, plus the three-part column reference
  `SCHEMA.TABLE.COLUMN` that goes with it, in the select list, WHERE,
  GROUP BY, HAVING, ORDER BY, as a star, on either side of a join, in
  comma lists, IN-subqueries, derived tables, CTE bodies, a stored
  view body, and every DML shape's target, SET, WHERE and RETURNING.
  Four laws carry it:

  **The qualifier is a TWO-WAY CATALOG CHECK, not a strip** — the rule
  that works for procedures (drop a `PUBLIC.`) is wrong for relations.
  `SYSTEM.RDB$RELATIONS` answers, `PUBLIC.RDB$RELATIONS` and
  `SYSTEM.T` both raise −204, and it must be a real catalog read
  rather than an `RDB$` name test: `CREATE TABLE "RDB$FOO"` lands in
  PUBLIC, so a prefix rule would answer `SYSTEM."RDB$FOO"`.
  **THE VIEW GUARD** is why this matters more than a refusal count — a
  view is a relation with an id and no records of its own, so a
  wrongly-qualified view that reached the scan would answer ZERO ROWS
  rather than raise: a wrong answer wearing an empty result's clothes.

  **Unquoted halves fold, a quoted half does not** — `PUBLIC.T`,
  `public.t`, `"PUBLIC".T`, `"PUBLIC"."T"` and `PUBLIC . T` all name
  the same relation; `"public".T` is −204. An unknown schema and an
  unknown table are the IDENTICAL vector (−204,
  `isc_dsql_relation_err`, `"S"."T"`, line and column), and the column
  points at the START OF THE QUALIFIER — there is no "schema unknown"
  diagnostic.

  **QUALIFICATION IS INVISIBLE IN THE DESCRIBE** — `FROM T` and `FROM
  PUBLIC.T` describe byte-identically (item 17 the BARE relation, 25
  the alias, 33 the schema). A qualifier leaking into any of the ~7
  sites that stamp a relation is a silent describe corruption no row
  gate catches, so section G prepares and compares them item by item.

  **An alias is exclusive, and a qualified reference SHADOWS a CTE** —
  after `FROM PUBLIC.T AS X` all of `T.C`, `PUBLIC.T.C` and
  `PUBLIC.X.C` raise −206 (`SELECT T.C FROM T X` is the same law, and
  closes a PRE-EXISTING wrong answer: fire-crab used to answer it). An
  alias may itself be named PUBLIC and then shadows the schema. A CTE
  can be neither defined nor referenced qualified, and `WITH T AS (…)
  SELECT * FROM PUBLIC.T` answers the BASE TABLE. A two-part reference
  is always TABLE.COLUMN, never SCHEMA.COLUMN.

  *Priced boundaries*: fire-crab emits the −204 vector for a SELECT's
  FROM item only — a −206, a qualified DML target and a qualified CTE
  reference keep the generic Dynamic SQL Error, so the gate asserts
  only that both sides raise. fire-crab holds one user schema, so the
  cross-schema ambiguity vector (336003085) and `SET SEARCH_PATH` are
  unreachable.

  **THE REFUTE PASS BROKE IT, one level down** (and the fix is in the
  same gate, now 115 checks). Both laws were installed at the OUTERMOST
  FROM only; a nested query expression — `IN`, `NOT IN`, `EXISTS`, `NOT
  EXISTS`, a scalar subquery, and those same shapes inside an
  UPDATE/DELETE/`INSERT…SELECT` WHERE — resolved by BARE name and threw
  the schema half away. `… WHERE C IN (SELECT C FROM SYSTEM.U)`
  answered rows against the engine's −204; `SYSTEM.V2` answered `[]`,
  which is precisely the empty result the view guard exists to prevent;
  and **`DELETE FROM T WHERE C IN (SELECT C FROM SYSTEM.U)` DELETED THE
  ROW the engine refuses to touch** — a wrong WRITE. The alias leaked
  the same way: after `FROM T AS Q`, a correlated `… WHERE U.C = T.C`
  answered where the engine raises −206, because the correlation split
  decided the inner side from the pair alone and never asked the outer
  binding. One shared question — `ColBinding::answers_to` — now answers
  it for every nested site, `relation_qualifier_ok` and the view guard
  are called where the nested FROM resolves, and the inner relation's
  own three-part spelling resolves inside the subquery.
  **LAW (the sharpest form yet of "vary the shape"): when a slice
  installs a CHECK, enumerate every CONTEXT that reaches the same
  machinery, not just every spelling. Ten laws held at the top level
  and none of them held one nesting level down.**

  *Found while fixing, and now CLOSED*: a VIEW inside a nested query
  expression answered `[]` at HEAD — **unqualified too** — because a
  subquery never expanded one, it just scanned the view's empty
  storage. It became a fail-closed refusal, and then a real answer:

- ~~A subquery must be ONE PHYSICAL TABLE~~ — *closed, by planning it
  instead of walking it*. `eval_subquery` resolved a rel id, read its
  formats and walked its records, so every shape that is not a plain
  table refused — a VIEW (an id with no records, hence the guard), a
  DERIVED table, a CTE, a JOIN, a UNION. The engine answers all of
  them.

  An UNCORRELATED subquery, though, **is a statement**, so when the
  relation path declines the text is planned as one and materialised
  through `branch_rows_res` — the function that gained a real error
  channel one increment earlier, so a subquery whose rows RAISE now
  raises instead of collapsing into "unsupported". Twelve shapes closed
  at once (`qa/serve-real-subquery.sh` 25 → 37, `qa/serve-real-view.sh`
  31 → 34; 12 and 3 DIFF against the pre-fix binary): views plain, with
  their own WHERE and with renamed columns; derived tables; unions;
  joins; scalar and aggregate subqueries; in IN, NOT IN, EXISTS and
  NOT EXISTS.

  The GUARDS hold because the PLANNER enforces them rather than the
  evaluator: a wrongly qualified view still refuses (the two-way
  catalog check lives at the top-level FROM), the semi-join key is
  still read strictly, and NOT IN stays lenient.

  *That increment's recorded boundary — a CORRELATED subquery over a
  view — closed in the next one*, and the reason it was reachable is
  worth stating: "correlated" and "not a plain table" are SEPARATE
  limitations, and only the second was structural. A correlated
  subquery is not a statement on its own, but its SOURCE is, and the
  source was the only part the relation path could not walk. So the
  source is planned and materialised once, and the correlation then
  splits against its OUTPUT columns (`derived_view`, the same helper
  the top-level planner uses for a derived table) exactly as it splits
  against a relation's — which is what makes the two paths agree on
  NULLs, on a residual conjunct beside the correlation, and on what a
  semi-join collects. Seven shapes gated, plus two base-table controls
  that pass on BOTH binaries; 7 DIFF against the pre-fix binary, one
  per shape.

  **The boundary check is why this was cheap to pick up.** It was
  written as a `case` accepting the refusal OR a matching answer, with
  both sides printed — so when the fix landed it printed *"a correlated
  subquery over a view now ANSWERS, and matches"* by itself. That is
  the right shape for a boundary you EXPECT to close: it records
  today's behaviour without blessing it. It is the opposite of the
  two-branch check corrected in `serve-real-view.sh`, where the
  engine's answer was already known and the second branch only made the
  check blind.

  ~~*Still open*: a DERIVED TABLE in a correlated subquery~~ —
  *closed, and the second half of it is the lesson.* Pointing the
  source planner at `parse_derived_table` was mechanical (the
  `(SELECT …) D (K)` declared-names form included, which the engine
  counts). What blocked it was a SECOND place that resolved columns
  PHYSICALLY: after the evaluator answered, the caller re-derived the
  correlated OUTER column through `correlated_outer_col`, which calls
  `relation_columns` — a view has catalog rows so it worked, a derived
  table has none, so the columns came back empty, the split found no
  correlation, and **a subquery this server had just evaluated
  correctly was refused by the code asking it what it had done**.

  That function's own comment warns "a rule stated twice is a rule that
  drifts; a rule stated three times drifts twice" — and the rule for
  *which side is which* WAS stated once, in `split_correlation`. What
  was stated twice is where the inner COLUMNS come from. **De-duplicating
  a rule is not enough while its INPUTS are still fetched
  independently**: `SubqRows` carries the outer column now, and only a
  reading that did not record one re-derives it.
  `qa/serve-real-subquery.sh` 46 → 51, 5 DIFF against the pre-fix
  binary.

- ~~A non-selectable procedure in FROM answers `[]`~~ — *fixed, with a
  stated surface* (`qa/serve-real-nosuspend.sh`). Selectability is
  `RDB$PROCEDURES.RDB$PROCEDURE_TYPE`, a LEXICAL DDL-time property: a
  SUSPEND inside `IF (1=0)`/`WHILE (1=0)`/a FOR over an empty table, or
  dead after `EXIT`, is still `TYPE = 1` and its `[]` is CORRECT — the
  fix is metadata-driven, never "no rows came back". And the one user
  mistake splits across THREE vectors in a fixed order,
  **zero-outputs → arity → not-selectable**:

  *Matched byte for byte*, `SELECT <*|cols> FROM <proc>[(<int|NULL
  literals>)]` with integer outputs, optionally under
  `FIRST`/`SKIP`/`DISTINCT`/`ROWS`: `isc_dsql_error` +
  `isc_prcmismat` (-902) for a wrong argument count; `isc_dsql_error` +
  `isc_sqlerr`(-84) + `isc_dsql_procedure_use_err` +
  `isc_dsql_line_col_error` for zero outputs, *including* the 1-based
  line/column of the FROM item as written; and the bare
  `isc_invalid_blr` + `isc_illegal_prc_type` pair (-104, no DSQL
  wrapper at all) for a `TYPE = 2` procedure with outputs — *including*
  the `isc_invalid_blr` BYTE OFFSET, which fire-crab never generated
  and reconstructs as `24 + len(schema) + len(name) + 4·(cols−1) +
  (args ? 3 + Σ(1|7|11) : 0)`, validated on 20 probed statements.

  *Refused generically* (both sides error, texts differ — no wrong
  answer): WHERE/GROUP BY/HAVING/ORDER BY over the call; an aggregate
  or expression in the select list (offset +4); a non-integer output or
  parameter (`load_procedure` refuses first; text columns are +3 each);
  every LAW-7 context — JOIN, IN/EXISTS subquery, derived table, CTE,
  UNION arm, `INSERT…SELECT`, MERGE, LATERAL — each with its own
  arithmetic and only one `split_proc_call` call site; any wrapper that
  REWRITES the text (derived inner `+19+len(name)`, CTE
  materialisation, select-list fold, qualifier strip), where the
  position or offset would be a fabricated number
  (`downgrade_rewritten`); and empty parentheses `P()` (engine: token
  unknown at the `)`).

  *Not implemented*: the `EXECUTE PROCEDURE` arity vector (-170,
  `isc_prcmismat` first, one `isc_param_no_default_not_specified` per
  missing parameter) — a different error family.

  Two PRE-EXISTING, unrelated boundaries surfaced while gating this and
  are pinned in it as refusals: fire-crab's PSQL interpreter has no
  `EXIT` (`SELECT * FROM PEXIT` refuses where the engine answers `[]`),
  and an empty `BEGIN END` body is outside its surface (`EXECUTE
  PROCEDURE PEMPTY` refuses where the engine succeeds silently).

  **The refute pass held the BLR arithmetic and broke the line
  counter** (gate now 82 checks). The reconstructed `isc_invalid_blr`
  offset survived every shape it ships one for — four outputs, a
  three-of-four subset, a column named twice, a 30-character name, a
  quoted name, the smallint/i32 rims — and every wrapper it cannot
  reconstruct honestly still downgrades rather than invent a number.
  What fell was the position: **a bare CR is a line terminator to
  Firebird's lexer and was not to fire-crab's reconstruction** (`SELECT
  *<CR>FROM P` reported 1,15 against the engine's 2,6), so
  `text_line_col` now ends a line on CR, on LF, or on CRLF counted
  once. Priced, not fixed: the `-84` vector fires only for a narrow
  textual shape (`FIRST 1`, an alias, a JOIN, a leading `--` comment
  all downgrade it where the engine keeps it), and the arity vector
  only for integer-parameter procedures — both refusals on both sides.
  A procedure in a non-PUBLIC schema does not resolve in FROM at all,
  so the `len(schema)` term of the arithmetic is asserted by no probe;
  the engine's own offset 28 for `S1.PQ` confirms the term is right in
  principle.

- ~~fire-crab's lexer accepts whitespace the engine's does not~~ —
  *fixed, and it was a WRONG WRITE*, found while attacking the line
  counter. Firebird's lexer knows exactly five space characters —
  SPACE, TAB, LF, FF (0x0C) and CR — and rejects everything else as
  `-104 Token unknown`, including VERTICAL TAB (0x0B). fire-crab's
  parser trims with Rust's UNICODE class, so `SELECT ID<VT>FROM T`
  answered rows and `INSERT INTO T<VT>(ID) VALUES (6)` **committed a
  row the engine refuses**. The cause was NOT the whitespace predicate
  the suspicion pointed at (`find_word` splits on identifier
  boundaries, so a VT separates two tokens whatever that predicate
  says, and Rust's `is_ascii_whitespace` happens to BE the engine's
  five): it is the several-hundred `str::trim` calls, whose class is
  the Unicode one. `has_unknown_space` therefore asks the question once
  at the three wire entry points — is there a Unicode space that is not
  one of the engine's five, outside literals, delimited identifiers and
  comments — and refuses before anything is planned. fire-crab still
  answers the GENERIC error where the engine spells `-104, Token
  unknown - line 1, column N`, which is what it already does for every
  other unknown token (`#`, `~`, a fourth dotted part); emitting the
  real vector needs a token scanner with a position.

  *Found beside it, unfixed and unpinned*: through isql, fire-crab
  mishandles MULTI-BYTE string literals — `SELECT 'aéb' FROM T` answers
  `aé` against the engine's `aéb`, and a literal holding NBSP DROPS THE
  CONNECTION (`SQLSTATE 08006`). Both are correct through
  node-firebird, so it is the isql/describe width path, not the literal
  parser. Its own slice; deliberately NOT pinned in the lexer gate,
  where it would have been hidden behind a passing check.

- **(superseded)** `RETURNING` comes back in a different shape. Through node-firebird
  the engine answers an `INSERT ... RETURNING` as a single object and
  fire-crab as an array of one. The values agree; the statement's
  announced *type* apparently does not. Noticed while diffing 495
  conversions and set aside, not chased.

- ~~An IN-SUBQUERY refuses past ~10-100 inner rows~~ — *fixed*. It was
  exactly 64/65 DISTINCT values, and the cause was one constant doing
  two jobs: the DNF cap bounds the AND cross-product (multiplicative,
  must stay small) and was also bounding OR growth (additive, one group
  per value). Separate bounds now.

- **UNIQUE/PK enforcement is FINAL-STATE, the engine's is WALK-ORDER —
  a self-overlapping key-shift UPDATE commits here where the engine
  refuses 23000.** Probed: from identical fixtures (`W`: PK 1..10;
  `U2`: UNIQUE 10,20..100), `UPDATE W SET ID = ID + 1 WHERE ID >= 5`
  — engine `SQLSTATE 23000 ... ("ID" = 6), Records affected: 0`; fc
  `Records affected: 6`, durable state `{1,2,3,4,6..11}` vs the
  engine's untouched `{1..10}`, gfix -v -full clean on fc's file (the
  divergence is silent and semantic). Same on `U2 SET K = K + 10`.
  The executor rewrites all collected record images FIRST and
  `unique_conflict` (crates/wire/src/server.rs, the enforce path
  around it) judges uniqueness from the CURRENT images — a deferred
  final-state check — while the engine enforces row-at-a-time in walk
  order. Direction-aware by accident: `SET ID = ID - 1 WHERE ID <= 4`
  matches (both succeed), and a shift into an UNTOUCHED row is refused
  by both with full rollback; only the self-overlapping,
  conflict-free-final-state shape diverges. Shared with the
  FC_NO_INDEX build, so it is the common write path, not the index
  walk. Pre-existing, durable, structurally clean — a real
  enforcement-order slice in the write path. — *FIXED*: enforcement is
  now row-at-a-time in RECNO order (probed: the engine's walk is
  record-number order even under an index-driven UPDATE) through one
  interleaved write-then-index loop seeing the partially-updated
  state, and every constraint refusal carries the engine's 23000
  vector byte-exact (constraint vs bare-index codes, FK direction
  items, print_key's format). **The gate's engine re-reads also
  exposed a pre-existing FILE CORRUPTION at clean HEAD: any UPDATE of
  a table whose record data is under 9 bytes re-stored the RHDF fill
  RLE-packed and the engine then unpacked past fmt_length — BUGCHECK
  179. Fixed (trim to fmt_length + the RHDF fill in ods).** Residuals:
  PSQL bodies flatten constraint errors to strings; INSERT images may
  carry the fill byte (NOT_PACKED, engine-forgiven); FK cascades and
  param'd UPDATE defer unchanged. `qa/serve-real-uniqueorder.sh`.

- **Packaged-procedure calls refuse** — `EXECUTE PROCEDURE
  RDB$PROFILER.FLUSH` (and the 3-part `SYSTEM.RDB$PROFILER.FLUSH`):
  the engine prepares TYPE 8 and executes (`NONE []`); fc refuses. A
  package qualifier is not a schema qualifier, and the PUBLIC rule
  currently swallows both. Pre-existing, refusal-only. Unclaimed.

- ~~`INSERT ... SELECT ... RETURNING` refuses at EXECUTE~~ — *fixed*:
  the multi-row cursor answers in select order through the one
  insert_select path (the bare special case deleted).

- ~~`UPDATE OR INSERT ... MATCHING ... RETURNING` fails at PREPARE~~ —
  *fixed*: dml_table_name walks the OR/INSERT/INTO head; a multi-match
  MATCHING answers one row per updated row.

- ~~An IDENTITY-column INSERT refuses~~ — *fixed*: an omitted
  identity column generates through the shared generator substrate
  (RETURNING and NOT NULL come free); an explicit value into
  GENERATED ALWAYS refuses with the engine's vector (335545137) — a
  wrong write closed.

- ~~OVERRIDING SYSTEM|USER VALUE, INSERT DEFAULT VALUES, params in an
  INSERT..SELECT source~~ — *fixed* (`qa/serve-real-overriding.sh`,
  101 differential checks). The 24-cell matrix matches cell for cell,
  including the generator readings that are the only thing separating
  several of them. Three points worth keeping:

  **OVERRIDING USER VALUE means the opposite of what it reads like** —
  it silently DISCARDS the supplied value and draws from the generator
  (`VALUES (1006,'x')` stores id 2; RETURNING confirms it), while
  OVERRIDING SYSTEM VALUE takes the value literally and leaves the
  sequence BEHIND the table. The `DEFAULT` keyword is the sanctioned
  escape from the ALWAYS rule and OVERRIDING does not make it literal;
  an explicit NULL never is.

  **Three vectors, chosen by metadata, never by the value** —
  335545134 (no identity in the field list, including a table with no
  identity at all), 335545135 (OSV against BY DEFAULT), 335545137
  (ALWAYS named without OVERRIDING). All prepare-time, one pre-quoted
  `"PUBLIC"."TBL"`, no `isc_dsql_error` wrapper. The metadata-first
  ordering is what makes `OSV + NULL` on a BY DEFAULT column answer
  335545135 where the same NULL without OVERRIDING answers 335544347
  at execute. `UPDATE OR INSERT` ships the typed vector at prepare
  instead of refusing generically; `UPDATE` is deliberately NOT
  protected (probed: `SET ID = ID + 100000` succeeds).

  **INSERT..SELECT resolves at prepare**, which closed two silent
  wrong writes: the implicit target list is now DECLARATION (position)
  order with COMPUTED columns excluded — execute used to re-derive it
  in FIELD_ID order with no filter, so a repositioned table landed
  every source column in the wrong target — and a repeated column in
  an explicit field list is refused instead of writing the last value.
  A `?` in the source WHERE now describes from the compared column and
  binds; the source plan and its input SQLDA are built once, at
  prepare, where the engine builds them.

  *Priced boundaries, refusals not wrong answers*: a `?` in the SELECT
  LIST (the engine types it from the INSERT target column — type,
  scale, subtype, charset and the nullability bit — which is a
  projection-planner slice); `? + 1` / `COALESCE(?, X)` / `CAST(? AS
  SMALLINT)` / `FIRST ? SKIP ?` with it; MERGE in any form; `RETURNING
  *`; `RETURNING <computed column>`, which was a WRONG ANSWER (the
  null-flag bytes decoded as data) and is now a refusal. The engine's
  `-104` / `-204` / `-206` / `-804` details are not reproduced —
  fire-crab ships the generic Dynamic SQL Error at the same TIME.

  **The refute pass found the vectors FABRICATING two things** (gate
  now 117 checks, 11 boundaries). The identity semantics themselves
  survived everything thrown at them, generator readings included; the
  message argument did not. *The schema was assumed, not read* — all
  three vectors formatted a literal `"PUBLIC"` because every gate cell
  used a PUBLIC table, so `INSERT INTO S1.TZ3 … OVERRIDING SYSTEM
  VALUE` named `"PUBLIC"."TZ3"` where the engine names `"S1"."TZ3"` —
  and fire-crab had resolved the S1 table correctly enough for the
  SUCCESSFUL spelling of the same insert to work, so only the message
  was wrong. It comes from the catalog now, through the read the
  qualified-name slice already uses. *And a typed verdict was asserted
  where there is no surface at all* — fire-crab cannot INSERT through a
  view (a priced boundary; the engine writes the base table), but the
  new metadata check ran FIRST, asked a table-only catalog reader about
  a view's identity columns, found none, and confidently answered
  335545134 naming the view. The engine attributes the ALWAYS refusal
  to the BASE table, so even the name would have been wrong. A view
  target returns None now and falls through to the generic boundary.
  **LAW: a refusal fire-crab cannot justify must be GENERIC — a
  confident wrong verdict is worse than an admitted one, because it is
  the one a driver will act on.**

  *Surprises worth keeping*: the `RDB$<n>` identity-generator counter is
  GLOBAL across schemas while the generator lands in the TABLE's schema
  (S1.RDB$1, S1.RDB$2, PUBLIC.RDB$3), so an unqualified
  `GEN_ID(RDB$1,0)` does not see an S1 table's generator. And
  `EvalErr::PrimaryKeyRequired` in the upsert path still formats
  `"PUBLIC"` from the statement's own spelling — the same fabrication
  in a different vector, left alone to keep the diff to this slice.

- ~~The generator-durability class stays recorded~~ — *closed by the
  generator-burn slice, and HALF THE ENTRY'S OWN LAW WAS WRONG*. The
  advance half held on re-probe: `GEN_ID(g,n)`, `NEXT VALUE FOR g` and
  an identity column's implicit draw are non-transactional and survive
  ROLLBACK, ROLLBACK TO SAVEPOINT, statement undo and a statement that
  FAILED (two dup-PK inserts drawing 7 then 5 leave the generator at 12
  with the table empty). The *absolute set* half did not: `SET
  GENERATOR ... TO n` and `ALTER SEQUENCE ... RESTART WITH n` are
  ORDINARY TRANSACTIONAL WRITES that a ROLLBACK undoes. They looked
  durable because the original probe ran through isql with **AUTODDL
  ON**, which committed them before the rollback could reach them; with
  `SET AUTODDL OFF` a rolled-back `RESTART WITH 3` leaves the generator
  exactly where it was. **LAW: an isql probe of anything transactional
  must set AUTODDL OFF first — the default silently commits the very
  statement under test, and the entry that came out of it had fire-crab
  aiming at a law the engine does not have.**

  AND THE ABSOLUTE-SET HALF HAS A SHAPE, which the first cut of this
  slice missed by one axis and which four wrong answers then made
  visible. An absolute set does not merely "get rolled back": it leaves
  a COMPENSATING UNDO RECORD naming the value it FOUND, and an undo
  replays those records in reverse. So **undoing a window puts the
  generator back to the value it held just before that window's FIRST
  absolute set, and leaves the cell exactly where it is when the window
  holds none.** Two cases pull against each other and only that rule
  gets both: advance to 51, `RESTART WITH 3`, ROLLBACK leaves **51**
  (the pre-set value), while `SET GENERATOR TO 3`, advance to 4,
  ROLLBACK leaves **50** — the compensating record outlives the later
  draw, so "replay the draws made inside the window" answers 4 and is
  wrong. A record scoped to the TRANSACTION instead of to the window is
  wrong the other way: `GEN_ID(G1,10)`, `SET GENERATOR G1 TO 3`, a
  FAILED statement, COMMIT must leave **3** — the undone window is the
  statement, which holds neither a draw nor a set — and it answered 10.

  So the record is a STACK, `Database::gen_windows`, one `GenWindow` per
  open undo window with window 0 the transaction: `draw` (name → the
  value its last advance inside reached, written by `burn_generator`)
  and `pre_set` (name → the value found by the window's first absolute
  set, written by `mark_generator_set` from the `SetGenerator` and
  `AlterColumnRestart` arms). `gen_window_push` opens one wherever a
  snapshot is taken — every statement, `insert_select`'s all-or-nothing
  loop, a PSQL body, a savepoint mark, the transaction — and
  `gen_window_unwind` closes it: an UNDONE window has its settled values
  written over the restored image (`pre_set` first, `draw` where there
  is none) and its compensating records die with it, a CLOSED one hands
  both halves to its parent, `draw` overwriting and `pre_set` only where
  the parent has none of its own. A statement is its own window, which
  is what stops a later failure from dragging back a set nothing undid;
  COMMIT clears the stack, because the commit made that image the new
  base. The DDL guard falls out of writing BY NAME into the restored
  image: a rolled-back `CREATE SEQUENCE` leaves no name, so its advance
  dies with it, while a rolled-back `DROP SEQUENCE` puts the name back
  and keeps the advance.

  The readable divergences are gone with it: the rolled-back identity
  INSERT that used to hand its id back (fire-crab wrote `ID 1` where
  the engine writes `ID 3`) now writes the engine's row, and so does an
  identity column whose `ALTER TABLE ... RESTART WITH 100` is followed
  by a failed statement (`ID 100`, where the window-blind record wrote
  `ID 3`). `qa/serve-real-gendurable.sh` — **263 checks, 44 DIFF
  against the pre-slice binary** — reads every generator back **through
  the engine out of fire-crab's own file** in every phase, and its
  INTERACTION section crosses the three absolute-set spellings against
  five kinds of undo against BOTH orderings of the set and the draw:
  that last axis is the one the original 94 checks never varied, and it
  is why they missed this.

  *Still open, and none of them is the carve-out*: `INSERT ... SELECT`
  with a `GEN_ID` in the SELECT LIST refuses at prepare (the succeeding
  and the failing spellings alike — a select-list generator feeding a
  write is not on the surface); a PSQL `WHEN ANY` block that draws then
  divides by zero still refuses whole where the engine answers `X = 5`;
  a PSQL assignment `V = GEN_ID(g,1)` inside a body that then RAISES
  does not record its draw at all (probed: engine 4, fire-crab 3 —
  pre-slice does the same, so the PSQL evaluator simply never reaches
  `burn_generator`); and `UPDATE OR INSERT ... VALUES (1, GEN_ID(g,2))`
  refuses whole, so nothing is drawn and the row that should collide
  never lands (engine writes `(1,5)`, fire-crab `(1,9)` — also
  pre-slice). All four are the PSQL/insert-select/upsert surface.

- **The compensating undo of an absolute set is DEFERRED in the engine
  and EAGER here** — a divergence this slice's probing found and did
  NOT introduce (identical on the pre-slice binary). The engine runs an
  absolute set's compensating record at TRANSACTION END: read the
  generator between a `ROLLBACK TO SAVEPOINT` that undid the set and
  the commit, and the engine still answers the *un-compensated* value.
  `SAVEPOINT SP; ALTER TABLE AID ALTER COLUMN ID RESTART WITH 100;
  ROLLBACK TO SP; INSERT INTO AID (V) VALUES (3);` writes `ID 100` on
  the engine and `ID 2` here; the same shape through `ALTER SEQUENCE`
  answers 101 against 51. Put a `COMMIT` after the `ROLLBACK TO SP` and
  both sides agree again, which is why every phase of
  `qa/serve-real-gendurable.sh` — all of which read after a commit —
  is green. Matching it needs the record to fire at transaction end
  rather than at the savepoint undo, and to fire on COMMIT as well as
  ROLLBACK when the window that held it was undone; that is a
  visibility model, not a value model, and it is its own slice.

- ~~A generator DRAWN IN A DML STATEMENT never advances~~ — *closed by
  the DML-draw slice, and **the counting law is the whole question***.
  `UPDATE T SET V = GEN_ID(G1,3)` and `DELETE FROM T WHERE ID =
  GEN_ID(G1,1)` both refused at prepare; the engine advances, and not
  "once per statement". Probed:

  - a draw in the **SET LIST** advances **once per UPDATED row** — over
    5 rows `SET V = GEN_ID(G,3)` leaves 15 and stores 3,6,9,12,15;
    behind a WHERE matching 2 of 5 it leaves 6; matching none, and over
    an empty table, it leaves the generator alone. The ACCESS PATH does
    not gate it (an index-driven range still draws once per row it
    writes), and two draws in one assignment evaluate left to right
    (`GEN_ID(G,1) + GEN_ID(G,1)` stores 3, 7, 11, ...).
  - a draw in the **WHERE** advances **once per row COMPARED**, matching
    or not — 5 rows leave 5, 2 rows leave 2, an empty table leaves 0,
    and a predicate NO row satisfies still leaves a full table's worth.
    A NULL column compares UNKNOWN *after* it has drawn.
  - per row the **WHERE's draw comes first** and the SET's follows only
    when that row matched: `UPDATE T SET V = GEN_ID(G,1) WHERE ID =
    GEN_ID(G,1)` over 5 rows leaves **6**, with `V = 2` in the one row
    that matched. `NEXT VALUE FOR` is the same law; `GEN_ID(g,0)` is a
    read and advances nothing.
  - and the draw is made **as the row is written**: an UPDATE raising on
    its first row burns one draw, on its second burns two, and writes no
    row either way — the durability carve-out above, met from the DML
    side.

  **THREE ENGINE BEHAVIOURS fire-crab REFUSES rather than answer a
  different number of advances**, each proved to raise and to leave the
  generator where it stood. (1) **An INDEX RETRIEVAL changes the count
  outright**: with a PRIMARY KEY on ID, `DELETE FROM TP WHERE ID =
  GEN_ID(G,1)` over 5 rows draws **twice** and deletes **nothing** (the
  bound is drawn, then the one retrieved row is re-tested against a
  second draw), where `PLAN (TP NATURAL)` draws 5 and deletes every row
  — so a WHERE draw on a relation with ANY index refuses. (2) **AND/OR
  SHORT-CIRCUIT**: `WHERE ID > 99 AND ID = GEN_ID(G,1)` leaves the
  generator at **0** and the same two conjuncts reversed leave it at
  **5**; the DNF the predicate parser builds has lost that order, so a
  connective beside a draw refuses. (3) **Uniqueness is judged after the
  patch walk here**, so a drawing SET list that rewrites a UNIQUE key
  over a row set the WHERE has not pinned to one row refuses (the
  upsert's own shape — a full unique-key equality — is exactly the
  pinned case, and still works). A silently different generator value is
  a wrong answer no client can see coming; a refusal is one it can.

  `qa/serve-real-genwrite.sh` — **194 checks, 65 DIFF against the
  pre-slice binary** — carries the whole matrix, reading every generator
  back **through the engine out of fire-crab's own file** after every
  phase, with the engine's own numbers pinned as teeth so a phase where
  both sides move together still fails.

  **THE ONE COUNT THAT STILL DIVERGES, now RECORDED rather than left to
  be rediscovered: a statement that FAILS mid-walk.** The engine draws
  AS IT WALKS, so a raise on row k has exactly k draws behind it;
  fire-crab draws for every row while COLLECTING the targets and only
  then writes, so it has drawn for all of them. `UPDATE TNN SET ID =
  NULL WHERE ID = GEN_ID(G1,1)` over three rows leaves the engine at
  **1** and fire-crab at **3**; a CHECK failing on row 2 and a division
  by zero on row 2 both leave the engine at **2**; and in the SET LIST,
  `SET ID = 1/(ID-3), V = GEN_ID(G1,1)` leaves the engine at **2**
  because the items are evaluated in WRITTEN order and row 3's first
  item raises before the second draws. Rows are identical on both sides
  (the statement is atomic either way) — only the sequence a client
  reads back afterwards differs. This is NOT a regression: the pre-slice
  binary answered **0** here, having no WHERE draw at all. Closing it
  means interleaving the draw with the WRITE walk — the same reshaping
  Inc366 did for uniqueness enforcement — and is its own slice; until
  then both numbers are asserted in the gate so either one moving is
  visible.

- ~~Constraint errors surface as generic 42000 `Dynamic SQL Error`,
  never 23000 with the constraint/key detail~~ — *stale, closed by the
  enforcement-order slice above and re-probed*: the duplicate-key
  INSERT and the PK-moving UPDATE the entry names both ship the
  engine's vector verbatim now (`... constraint "INTEG_2" on table
  "PUBLIC"."T", Problematic key value is ("ID" = 1)`), on two
  different indexes. The entry had been contradicting its own sibling.

- ~~Text COLUMN vs numeric side still render-compares~~ — *stale,
  closed by the per-row coercion slice above and re-probed*: `NAME >
  N`, `NAME = ID` and `NAME = N` all raise the engine's 22018 with the
  same argument on both sides. This was the loudest wrong-answer claim
  left on the open list, and it had been dead since that slice landed.

- ~~A tab in a failing text literal renders RAW in the error argument~~
  — *closed, and the rule was PROBED before it was written*: the 22018
  argument now goes through `conversion_error_arg` on its way into the
  status vector, which is where the engine escapes it too
  (`CVT_conversion_error`). `#x` + two LOWERCASE hex digits for every
  byte outside `0x20..=0x7f`, PER BYTE — a UTF-8 `é` prints
  `#xc3#xa9`, the euro sign `#xe2#x82#xac` — with `0x7f` (DEL) alone
  above the printable band travelling raw and a CHAR's padding staying
  blanks. It is THIS vector only: the 23000 key value (print_key), the
  -204/-206 unknown-name arguments and the -104 token all carry the raw
  byte on the engine's own wire, so nothing else moved.
  `qa/serve-real-textcolcmp.sh` grew the whole matrix (115 checks, 17
  of them DIFF against the pre-fix binary).

- ~~A refusal ships the engine's MESSAGE TEMPLATE at the user~~ —
  *closed at the responder*. `EvalErr::ConversionError(None)` shipped
  `isc_convert_error` with NO `isc_arg_string`, and the engine's text
  for that code is "Conversion error from string @1" — so the CLIENT
  rendered the unfilled slot: node-firebird printed `"@1"` and isql
  `"<Missing arg #1 - possibly status vector overflow>"`. A view whose
  body this server cannot answer said that at the user.

  The `None` arm was never a conversion failure: a dozen "this shape is
  outside the surface" sites reach for it when they have no error of
  their own, the honest example being `branch_rows`, whose `Option`
  return LOSES a real `EvalErr` on the way out and leaves the caller
  inventing one. It degrades to the generic vector now, by the rule the
  identity verdicts already follow — **a refusal this server cannot
  justify must be GENERIC, because a confident wrong answer is the one
  a driver acts on**. A conversion error that HAS its string is
  untouched and still matches the engine byte for byte.
  `qa/serve-real-view.sh` gates both halves (32 checks, 1 DIFF against
  the pre-fix binary).

- ~~`branch_rows` loses a real error on the way out~~ — *closed, and it
  was the cause behind the template leak above*. Its `Option` could not
  say whether a shape was UNSERVED or whether its rows RAISED, so every
  caller that owed an error invented one. `branch_rows_res` returns
  `Result<_, EvalErr>` now, with a new `EvalErr::Unsupported` (the
  generic vector) for the first case and the row's own error for the
  second; the twelve callers that legitimately want a fallback keep
  their `Option` face through a one-line wrapper, so only the sites
  that owed an error changed. Four `.ok()` calls inside the row
  builders were discarding column-evaluation errors the same way and
  now propagate too.

  What it fixes, measured: a DERIVED TABLE, a VIEW and a UNION BRANCH
  whose rows raise all said `Dynamic SQL Error` where the engine says
  `arithmetic exception … Integer divide by zero`. All three ship the
  engine's vector now. `qa/serve-real-derived.sh` 44 → 52 checks, 5
  DIFF against the pre-fix binary, with three controls (shapes that do
  NOT raise) passing on both binaries so the section cannot pass by
  failing everything.

  ~~*Recorded beside it*: the engine EMITS ROW 1 and then raises~~ —
  *closed for the shapes that do not block*, and the probing is what
  made it small. The law is finer than "materialise or stream":

      derived, raiser on row 3   ->  rows 1,2 then the raise
      ORDER BY ID DESC           ->  row 4 then the raise on row 3
      raiser IN the sort key     ->  no rows at all
      DISTINCT                   ->  no rows at all
      UNION ALL                  ->  all of branch 1, then branch 2
                                     up to its raiser

  `ORDER BY ID DESC` is the decisive cell: the plan says `SORT` and rows
  still arrive, in SORTED order. **A sort materialises its KEY, not the
  projection** — the select-list expression is evaluated as each row is
  DELIVERED — while a raiser in the KEY, or under DISTINCT, must fire
  before anything, because every key has to exist before the first
  delivery.

  That maps onto what this server already does: `src.rows(db)`
  materialises RECORDS (sort included) and the projection runs after.
  So `branch_rows_each` only had to PUSH each projected row as it is
  produced, and the derived and `UNION ALL` emit paths stream through
  it; the blocking shapes fall through to the collecting path, which is
  the faithful reading there rather than a shortcut.
  `qa/serve-real-derived.sh` 52 → 57 (+2 boundaries), 3 DIFF against
  the pre-fix binary.

  **These checks cannot go through node-firebird**: it buffers the whole
  result, so a partial delivery and a clean refusal look identical to
  it. isql prints rows as they arrive and is the only oracle, so the
  section compares whole session text.

  *Two residuals, both pinned*: an outer ORDER BY over a derived table
  still blocks here, because the engine FLATTENS the derived table into
  one pipeline and sorts base records while fire-crab's outer sort is a
  real blocking node over already-projected rows; and on the blocking
  shapes the engine raises at OPEN where fire-crab announces the result
  set and raises at the first FETCH (one blank line in isql, the same
  lazy/eager split one level up, pre-existing).

- ~~The strict grammar reaches a VIEW BODY, where the engine does not
  hash~~ — *closed, and it cost two edits rather than the thirteen the
  symptom suggested*. `SELECT * FROM V` refused where the engine
  answers every row, because the view's body was marked for the strict
  grammar like any statement's. The marking turned out to be reachable
  from exactly THREE places (`plan_update`, `plan_delete`, and
  `plan_query_inner`'s own body), so a `plan_query_inner_ctx` wrapper
  carrying one `in_view` flag, plus the single call in `plan_view`,
  does it — the other twelve callers never learn the flag exists.
  **Trace what actually reaches the site before pricing a fix by its
  call-site count.**

  The gate check for it is written as an EQUALITY on purpose. It began
  as "refuses generically OR answers and matches", which was honest
  while the engine's behaviour was unknown — and passed BOTH WAYS when
  A/B'd, catching nothing. Once the engine's answer is known, a
  two-branch check is a blind one.

  *Found by a control while gating it, and pinned there*: a same-side
  filter that EMPTIES the outer silences the engine's key raise, because
  the hash is never built. `WHERE A = '1 2' AND A IN (SELECT T FROM TT)`
  answers `[]` on the engine — the literal reads leniently as 12 and
  matches no row — and raises here. One step weaker than the
  FALSE-conjunct cell the invariant pass already handles: not a constant
  false, just a filter that matches nothing.

- ~~A DML `SET` list's evaluation failure answers 42000 where the engine
  answers 22012~~ — *closed, one line, and the interesting part is why
  it lived so long*. `ExecErr` has carried an `Eval(EvalErr)` arm since
  the day its doc comment promised that "`UPDATE ... WHERE A / 0 = 1`
  answers the same 22012 the engine raises", and the WHERE half does
  exactly that — but the SET half called `map_err(|_| "expression
  failed")`, flattening the typed error into text and out through the
  generic vector. **The two halves of one UPDATE disagreed with each
  other**, and `SET V = 1/(ID-2)` answered `Dynamic SQL Error` where
  `WHERE 1/(ID-2) = 1` answered `-Integer divide by zero`.

  **The gate that should have caught it had the case and could not see
  it.** `qa/serve-real-setexpr.sh` names `SET A = A / 0` in its header
  teeth and has tested it since the slice landed — but its `same`
  helper compares the two resulting TABLES, and a statement that fails
  on both sides leaves both tables untouched, so the check passes
  whatever either side SAID. A new `vect` helper compares the SQLSTATE
  line as well as the table (9 checks: the raiser hit on the first row
  and on a later one, the header's own tooth, a NUMERIC divide, `MOD`
  by zero, the WHERE half, both halves at once, and two controls — a
  division that succeeds and a NULL numerator that must propagate).
  6 DIFF against the pre-fix binary, 0 after.
  **LAW, and it applies to more gates than this one: a gate that
  compares only END STATE cannot see an error's CLASS. Where both sides
  fail, the table is identical by construction and proves nothing.**

- **A RAW high byte is lost before any error can name it** — the
  escaping slice above measured it in the SQL TEXT: fc decodes the
  statement as UTF-8 lossily, so a NONE-charset literal carrying `0x80`
  (or `0xff`) reaches the argument as U+FFFD and prints `#xef#xbf#xbd`
  where the engine prints `#x80`. **The refute pass then showed the
  residual is WIDER than the note said: it reproduces from a STORED
  COLUMN VALUE in a charset-NONE database (`WHERE S > 1` over a row
  holding `0x80`), where no statement text is involved at all** — so
  the lossy step is the byte→String decode of the RECORD IMAGE as much
  as of the SQL. A text-decoding defect, not an escaping one; it wants
  the charset honoured on both paths. Unclaimed.

- ~~The compare grammar refuses interior blanks the engine accepts~~ —
  *closed*, and the comment that said otherwise is gone. The claim in
  the tree had been that fire-crab's compare grammar is WIDER than its
  CAST grammar and that the gate's compare controls proved it. They
  proved it for the COLUMN side only: the interior-blank vector on the
  LITERAL side never reached `text_col_num` at all, because
  `literal_num_rhs` classified the literal `Raise` at prepare and the
  statement either raised per row or refused. fire-crab's LITERAL
  grammar was NARROWER than its CAST grammar, the opposite of the
  recorded law.
  What the engine does, probed both ways over an INTEGER column
  holding 12: the literal side is converted TWICE, by two grammars,
  and an INDEX decides which one the statement sees. Unindexed,
  `I = '1 2'`, `' 1 2 '`, `'5 . 0'`, `'- 5'`, `Q = '1 2.0 0'`,
  `I + 0 = '1 2'` and a text PARAMETER bound `'1 2'` all ANSWER the
  row; with an index on the column every one of them raises 22018,
  because the optimizer builds the key with the strict store grammar
  at OPEN. `Term::CmpConvErr` carries the lenient reading beside the
  original string now (`lenient_num_rhs`), so it compares per row and
  `key_conversion` raises unchanged — every timing law (dead group,
  NULL row, empty table, DML atomicity) rides the machinery that was
  already there.
  Two side laws fell out of the probe pass. **A multi-value `IN` is
  not the OR it desugars to**: the engine compiles its list once with
  the STRICT grammar, so `I IN ('1 2', '9')` raises where
  `I = '1 2' OR I = '9'` answers and `I IN ('1 2')` answers — the OR
  desugar cannot carry that, so a multi-value IN holding a
  blanks-and-digits string REFUSES the statement rather than answer
  the OR's rows. **And two unconvertible bounds on one keyed segment
  name the UPPER one**, whichever order they are written in (`K >= 'zz'
  AND K <= 'yy'` and its mirror both name 'yy'), which `key_conversion`
  now orders by; `K BETWEEN 'zz' AND '9'` still names 'zz'.
  `qa/serve-real-textcolcmp.sh` law 10, 339 checks.
  Residual priced: a DOUBLE column's literal side (`D = '1 2'`) still
  REFUSES here — the approximate predicate path has no per-row raiser
  and no key conversion, and the engine's answer there is
  index-dependent too (probed: unindexed answers, indexed raises), so
  converting it without that machinery would ship a wrong answer.
  Also unrelated but measured beside it: a text PARAMETER neither
  grammar takes (`I = ?` bound `'x'`) answers *Dynamic SQL Error* where
  the engine raises *Conversion error from string "x"* — the bind path
  reports through `ExecErr::Text`, which has no status vector.

- ~~The lenient literal grammar leaked through a SUBQUERY FOLD, and
  WROTE~~ — *closed; it was a regression of the entry above.* A
  subquery is folded to a literal before the predicate is built, and
  the new lenient grammar then read the folded value as if the user
  had spelled it: `UPDATE J1 SET A = 77 WHERE A IN (SELECT T FROM J2)`
  over a VARCHAR holding `'1 2'` COMMITTED `A = 77` where the engine
  raises 22018 and writes nothing; `DELETE` removed the row; `SELECT`
  and the correlated `EXISTS` spelling answered it.
  The rule is NOT "a fold is strict" — that was the hypothesis, and the
  engine refuted it in four cells. **The rule is that the STRICT
  grammar belongs to a KEY, and a SEMI-JOIN'S HASH KEY is the third
  kind of key** (after the index key and the store/CAST target). `SET
  PLANONLY ON` is the discriminator, and it is exact: a POSITIVE `IN
  (<subquery>)` / `= ANY` / correlated `EXISTS` written as a TOP-LEVEL
  CONJUNCT is `PLAN HASH` and raises; the same subquery under an `OR`
  or a `NOT`, `NOT IN`, `NOT EXISTS`, `= ALL` and a SCALAR subquery
  drop to two plain plans and ANSWER the row with the lenient grammar.
  An `OR` in a SIBLING conjunct does not count.
  The raise has a different gate from every other 22018 in this file:
  it is the hash BUILD that fails, not a comparison, so an outer table
  holding only a NULL still raises (where `Term::CmpConvErr` would say
  UNKNOWN) while an EMPTY outer raises nothing, and one bad key sinks a
  list whose other keys convert and match. `Tok::StrKey` marks the
  folded value at the one site that knows the shape
  (`conjunctive_position`), `Term::KeyConvErr` raises ungated, and the
  refused spellings are written FIRST into the desugared OR so the
  raising group is reached before any group can answer.
  `qa/serve-real-textcolcmp.sh` law 11 and `qa/serve-real-dmlsubq.sh`
  (339 and 36 checks; 8 and 14 DIFF against the same tree with the
  marking disabled — the dmlsubq half being WRONG WRITES, visible only
  because every phase is re-read through the ENGINE).
  ~~**The INNER JOIN's hash key**~~ — *built, and the law I recorded for
  it had a WRONG CELL that the build found.* `Expr::TextNumKey` is the
  strict twin of the `TextNum` wrap; `mark_hash_keys` rewrites the
  boundary equality of an INNER or comma join to use it, at TWO sites —
  the ON at the join step, and the plan's WHERE for the comma spelling,
  whose key never appears in an ON (and only when every step in the
  chain is inner, since a LEFT step is a nested loop). Three spellings
  that answered now raise with the engine's own vector; `textcolcmp`'s
  boundary pins became real checks (341, 3 DIFF pre-fix).

  **THE CELL THAT WAS WRONG: "either side EMPTY → no raise".** It was
  measured on a one-row fixture and it does not generalise, because
  WHICH SIDE the engine builds the hash from is the OPTIMIZER'S choice
  and it moves with CARDINALITY:

      S1 = 1 row : PLAN HASH ("NE" NATURAL, "S1" NATURAL)  -> answers 0
      S1 = 2 rows: PLAN HASH ("S1" NATURAL, "NE" NATURAL)  -> RAISES

  with `NE` empty in both. The build side is read whether or not the
  other side has a row. fire-crab evaluates per PAIR, so it cannot
  raise with an empty stream at all; matching this needs the hash build
  AND a model of the side choice. It therefore UNDER-raises there —
  the direction that answers rather than invents — and both plans are
  quoted in the gate. *(The project's own law, earned again: a rule
  probed on ONE shape is a hypothesis. This one survived two
  increments and a roadmap entry before the second shape refuted it.)*

  **Two conservative silencers keep it from trading one wrong answer
  for another.** The engine answers 0 rather than raising when a
  sibling conjunct is INVARIANT (`AND 1=0`: the hash is never built)
  and when a conjunct filters the KEY'S OWN STREAM (`AND S1.T = '34'`:
  applied to that stream before the build). Marking either would make
  this server RAISE where the engine answers; it declines to mark, so
  the pre-existing lenient answer stands. Both are gated, and both pass
  against the PRE-FIX binary too — they test the guards, not the fix.

  ~~*Found while building*: `LEFT JOIN … WHERE J1.A = J2.T` raises on
  the engine~~ — *closed*: a LEFT join whose padding cannot survive the
  WHERE **is** an inner join, and the engine plans it as one (`PLAN
  JOIN` → `PLAN HASH`, probed; the ANTI-JOIN idiom `WHERE J2.ID IS
  NULL` and a conjunct under an OR both stay `PLAN JOIN`, and both are
  excluded). The ROWS are identical either way — a padded row fails a
  null-rejecting conjunct — so what changes is which EVALUATIONS
  happen: the ON stops running over partnerless rows, the inner side
  stops being probed, and the key becomes a hash key read strictly.

  Two traps, both caught by controls rather than by reasoning. The
  first attempt did not fire on the shape it was built for, because by
  resolution time `cmp_sides` has WRAPPED the text side — the term is
  `Cmp(Col, TextNum(Col))`, so a "bare column" test sees no column;
  `null_rejecting` reads through the coercion wraps now. Then the gate
  caught the opposite error: `… ON TK.S = TNI.N WHERE TK.S = '34'`
  raised where the engine answers `[]`, because a conjunct that filters
  the KEY'S OWN STREAM is applied before the hash is built. That
  silencer existed for the ON's conjuncts; the WHERE's are only visible
  at the degradation site — and a same-side conjunct is exactly what
  degraded the join. `qa/serve-real-textcolcmp.sh` 342, 1 DIFF against
  the pre-fix binary with four negative controls green on BOTH.

- ~~`<op> ANY | SOME | ALL (<subquery>)` has no surface at all~~ —
  *implemented, measured first*. Every spelling answered `Dynamic SQL
  Error`; the engine answers all of them. Three corners are not what
  the words suggest, and all three were probed before a line was
  written:

  * **`= ANY` IS `IN`, and `<> ALL` IS `NOT IN`** (`= SOME` is the
    synonym), so both route through that path and INHERIT ITS HASH-KEY
    MARKING — which is why `= ANY` reads its key strictly and `= ALL`
    stays lenient, the asymmetry an earlier refute pass had recorded as
    two boundary pins.
  * **An EMPTY set makes ALL vacuously TRUE — including for a NULL
    outer value** (`> ALL (empty)` returns the NULL row), and ANY
    FALSE.
  * **A NULL in the set makes ALL unknown; ANY ignores it** — `> ANY
    {1,NULL}` answers exactly what `> ANY {1}` answers, because an
    UNKNOWN disjunct cannot change a TRUE and a row that matches
    nothing is dropped either way.

  Everything else is the general desugar: an AND of comparisons for
  ALL, an OR for ANY, each the left side against one value.

  **UNKNOWN and FALSE part company under a NOT**, and a token stream
  can only say FALSE — so a quantified comparison over a NULL-bearing
  set REFUSES there rather than answer the wrong rows. That guard first
  tested for a `Not` immediately before the expression and never fired,
  because `NOT (V = ANY …)` puts a paren in between; it uses the same
  "is this a plain conjunct" test the hash-key marking uses now, which
  sees an enclosing NOT or OR. `qa/serve-real-subquery.sh` 51 → 70 (19
  DIFF against the pre-fix binary) and `qa/serve-real-textcolcmp.sh`
  345 (3 DIFF), the latter being the two pins turned into checks.

- **Derived-table FLATTENING is the wrong way to close the sorted-raiser
  residual** — recorded so it is not attempted again. Merging `SELECT …
  FROM (SELECT …) X` into one statement would close it and would let an
  index reach through a derived table, but it is EXACTLY the text
  expansion R7 removed (`splice_ctes`: "the old path EXPANDED a
  definition … this moves ONE FROM ITEM and hands the body to the
  planner as a query of its own"). The residual belongs to programme R:
  the sort must carry UNPROJECTED records and apply the projection at
  delivery, which is the lazy row-source tree, not a rewrite.

  **The older measurement, kept for the cells that held:**
  `SET PLANONLY ON` confirms the split: `J1 JOIN J2 ON J2.T = J1.A` and
  the comma spelling are `PLAN HASH`, a LEFT JOIN of the same pair is
  `PLAN JOIN`, and a semi-join inside a VIEW BODY is neither — two
  plain plans. So the strict grammar reaches the first two and must NOT
  reach the other two (fire-crab answers the hashed pair today and is
  over-strict inside the view body, where its message even leaks the
  raw `@1` template slot).

  The GATING, probed cell by cell, and two of these rule out the
  obvious implementation:
  * both sides non-empty → RAISES; either side EMPTY → no raise, count
    0. So it is not a prepare-time refusal.
  * **it raises with NO MATCHING PAIR AT ALL** (`N1 = {12, 999}` against
    `S1 = {'1 2', '34'}` raises) — the hash BUILD reads the key, so a
    per-pair comparison is the wrong unit of evaluation, or at least
    must not be gated on matching.
  * **filtering the bad row off its OWN stream silences it**: `... ON
    S1.T = N1.A AND S1.T = '34'` answers 0, and so does the derived
    spelling `JOIN (SELECT T FROM S1 WHERE T = '34') X`. The engine
    applies a single-side conjunct to that stream BEFORE the hash — the
    same pushdown `side_filter` already implements for the partnerless
    ON raiser, which is where the implementation should start.
  * a FALSE sibling conjunct (`AND 1=0`) silences it, which the
    invariant pass gives for free.

  Not built yet: it needs a strict twin of the `Expr::TextNum` wrap
  (with arms in all of `type_of`/`rank_of`/`result_scale`/`eval`, per
  this file's own law about new variants), the boundary equality of an
  INNER or comma join rewritten to use it, and same-side ON conjuncts
  pushed onto their stream first. Its own slice; the measurement above
  is the expensive half and is done.

  **The older note, kept:**
  `FROM TNI JOIN TK ON TK.S = TNI.N` and the comma spelling both raise
  on the engine and answer here, at HEAD as well as after this fix — the
  join path compares those two columns per row with the lenient
  grammar and does not know which of its equalities the engine turns
  into hash keys. Pinned on both sides at the end of law 11. Closing it
  is a join-path slice, not a fold one. Beside it: `= ANY` / `= ALL`
  have no surface at all here, and an `INSERT ... SELECT` whose WHERE
  carries ANY per-row conversion raiser refuses at prepare rather than
  raising it (`WHERE ID = 'x'` does the same, and did before).

- ~~A text→number conversion longer than 52 characters raises the wrong
  CLASS~~ — *closed*, and the note that asked for it was wrong twice
  over: it is not one cap, and the targets it called uncapped are not.
  The cap is the CALLER's stack buffer that `CVT_make_string` copies
  the source into before `cvt_decompose` reads a character of it —
  `sizeof(VaryStr<N>)` = N + 2, which is why the numbers are 22, 52 and
  130 rather than 20, 50 and 128 — so it follows the CONVERSION
  ROUTINE, that is, the target's STORAGE WIDTH:
  **22** for `CVT_get_short` (`SMALLINT`, `NUMERIC(p ≤ 4)`);
  **52** for `CVT_get_long`/`CVT_get_int64` (`INTEGER`, `BIGINT`,
  precision 5..18 — **and `DECIMAL(p ≤ 4)`, which is a LONG where
  `NUMERIC(p ≤ 4)` is a SHORT**: one keyword apart, two caps, probed);
  **130** for `CVT_get_double` — `FLOAT`, `DOUBLE PRECISION` — **and
  for the TEMPORAL targets and BOOLEAN with it**, where the old note
  said "no cap at all" (probed: 120 blanks then `'2020-01-01'` casts
  to a DATE, 121 raise 22001, and the 22001 REPLACES the 22018 a
  nonsense source of that length earns);
  **none** on the INT128 path (`NUMERIC(19,0)` and up takes a 201-byte
  source).
  The rest of the old note held: BYTES not characters (53 characters /
  54 bytes reports `actual 54`); TRAILING blanks drop BEFORE the test
  and count INTO the reported `actual` (52 blanks + `'2'` + 200 blanks
  is *expected 52, actual 253*); it fires BEFORE the grammar; and the
  COMPARISON vector has no cap on either side.
  `CastTarget::Int`/`Numeric` carry the storage width now (`bytes`),
  `CastTarget::cvt_cap` spells the buffer and the CAST path raises
  `EvalErr::StringTruncation` through the vector that already existed.
  `qa/serve-real-textcolcmp.sh` law 9, 339 checks (47 DIFF against the
  pre-fix binary).
  Residuals, both priced rather than guessed:
  **the STORE path is still uncapped** — `INSERT INTO T (N) VALUES
  ('<53 bytes>')` raises the same 22001 on the engine, but fire-crab's
  store conversion answers `Option` (a prepare-time refusal), not an
  `EvalErr`, so spelling the vector there is a store-path slice;
  and **the KEY build caps at 130 too** — an indexed `I = '<200
  blanks>12'` raises *expected 130, actual 202* because the optimizer
  converts through the DOUBLE routine whatever the column's type,
  where fire-crab answers the row (the keyed term keeps no original
  string to measure).
  Still open beside it, and unrelated to the cap: `CastTarget` has its
  width now but no RANGE check, so `CAST('99999' AS SMALLINT)` answers
  99999 where the engine raises *numeric value is out of range* — one
  `match bytes` away, in the same field this slice added.

- **`CAST(? AS <type>)` is refused outright** — measured, unimplemented,
  and the describe is the interesting half. The engine types the SLOT
  as the CAST TARGET itself (probed: `SELECT CAST(? AS SMALLINT)`
  describes `500 SHORT len 2`, INTEGER `496 LONG len 4`, BIGINT `580
  INT64 len 8`, `NUMERIC(9,2)` `496 subtype 1 scale -2`, DOUBLE
  PRECISION `480 len 8`, `VARCHAR(5)` `448 subtype 4 len 20` under a
  UTF8 attachment, DATE `570 len 4` — all nullable), and node-firebird
  then sends its own value-derived BLR anyway, so the CAST GRAMMAR is
  what converts the bound value: `'  2  '` answers 2, `'1 2'` raises
  *Conversion error from string "1 2"*, `2.5` answers 3, NULL answers
  NULL. fire-crab answers *Dynamic SQL Error* to every one of them.
  The blocker is not the cast: the projection parser has no PARAMETER
  ATOM at all, and the input SQLDA for a select list is built from the
  WHERE clause's slots only. It is the projection-planner slice the
  `plan_insert_select` comment already names — a `?` atom, a sink for
  its descriptor in textual order, and an execute-time bind of the
  projection expressions beside `bind_filter`'s.

- ~~`CAST('<TAB>2' AS INTEGER)` answers 2 where the engine raises~~
  — *closed*. Three call sites were trimming Rust's `White_Space`
  class where the engine's `cvt_decompose` skips **0x20 and nothing
  else**: `decimal_parts` (the CAST to an exact scaled target), the
  CAST-to-integer arm's `parse::<i64>`, and the CAST-to-approximate
  arm's `parse::<f64>`. All three take `trim_matches(' ')` now, and
  the whole matrix agrees — TAB, LF, VT, FF, CR **and** the Unicode
  blanks a `char`-wise trim also ate (NBSP `#xc2#xa0`, EM SPACE,
  IDEOGRAPHIC SPACE, NEL), at the START and at the END, two adjacent,
  across SMALLINT / INTEGER / BIGINT / NUMERIC(9,2) / DOUBLE
  PRECISION, from a stored COLUMN and from a statement LITERAL.
  The three grammars in this server are now distinct and each right on
  its own vector, which the gate pins with ONE value: `'1 0'` compares
  equal to 10 and casts to a conversion error, in adjacent checks.
  The store and parameter grammars were already 0x20-only and did not
  move. `qa/serve-real-textcolcmp.sh` grew section 16 (205 checks, 70
  of them DIFF against the pre-fix binary).
  A fourth site went with them: `approx_literal`, the literal side of
  a comparison against a DOUBLE column, had `DP = '<TAB>2'` ANSWERING
  the 2 row. It refuses at prepare now instead of answering wrongly —
  the engine raises 22018 there, so this is a message residual, not a
  wrong answer: an approximate column has no `Term::CmpConvErr` twin
  (`pick_for_terms` only routes `ColKind::Int` through
  `literal_num_rhs`), and giving it one is the slice that would close
  it.
  One twin site was left ALONE on purpose: `crates/exe`'s BLR cast
  (`blr_cast` to `DT_SHORT`/`DT_LONG`/`DT_INT64`) trims the same wrong
  class, and renders its 22018 argument from the TRIMMED text rather
  than the original besides. It is reachable only through the stored
  procedure path (`fire_crab_exe::bind_and_execute`), which no gate
  drives, so there is no oracle for it yet; a procedure-body CAST gate
  is what should carry that change.

- **The parameter-bind and STORE vectors refuse with a bare `Dynamic
  SQL Error` where the engine raises 22018 with the argument** — the
  CAST slice above chased this and it is A DIFFERENT MACHINE, not the
  whitespace grammar: the grammar there is already 0x20-only and
  correctly REFUSES `'<TAB>2'`; what is missing is the error. And it
  is not TAB-specific — `SELECT … WHERE N = ?` bound `'abc'`, and
  `INSERT INTO T (N) VALUES ('abc')`, answer the same bare message.
  Both sides fail, so no wrong write; it is the prepare-time refusal
  path that needs the engine's status vector, which the per-row
  `Term::CmpConvErr` path already builds. Unclaimed.

- **`CAST(? AS INTEGER)` refuses outright**, whatever is bound
  (probed with `'2'` and with the integer 2) — the cast target is not
  applied to a parameter slot at all. Unclaimed.

- **`CAST('2.5' AS INTEGER)` raises where the engine answers 3** — the
  opposite failure to the whitespace one, in the same arm: the
  integer CAST reads its text with `parse::<i64>`, which is NARROWER
  than the engine's grammar, so every fractional or e-notation
  spelling the engine ROUNDS into an integer (`'2.5'` → 3, `'1e3'` →
  1000) is a conversion error here. A wrong refusal, not a wrong
  answer. `decimal_parts` + `round_scaled_to_int` — already the
  NUMERIC arm's pair — is the shape of the fix for the fractions, and
  `text_number` (which does read an exponent) for the rest.
  Unclaimed.

## The two programmes

### Programme R — the engine's execution shape

Replace textual rewriting with the engine's own structure: a tree of row
sources (`RecordSource`/rsb in `src/jrd/`), built by the planner and
pulled by the fetch.

- **R1 — the tree exists.** *(done)* A `RowSource` with `TableScan`, `Filter` and
  `Sort`, and the simplest plan executing through it. No behaviour
  change; the gates are the proof.
- **R2 — Aggregate** is a node. *(done)* `group_output` and both grouped
  paths build `TableScan → Filter → Aggregate → Sort`; the fold itself
  (`group_rows`) now has exactly ONE caller, the node.
- **R3 — NestedLoopJoin**, inner and outer. *(done)* `join_rows` builds
  a LEFT-DEEP tree instead of folding, so "each step's kind applies to
  everything accumulated so far" is true by construction; the WHERE is a
  `Filter` above the whole join.
- **R4 — derived tables**: `FROM (SELECT ...)`. *(done)* The first
  capability the tree unlocks that the rewriting could not reach: a
  derived table has no name to substitute, so the outer query resolves
  against a synthetic view built from the inner plan's DESCRIBE.
- **R5 — a materialised CTE**. *(done)* A CTE body the inlining cannot
  rewrite is a DERIVED TABLE by another name: `FROM C` becomes
  `FROM (<body>) C`. Grouped, starred and joined bodies all answer now,
  and a grouped PLAN became a row source in the process.
- **R6 — `WITH RECURSIVE`**, a fixpoint over the tree. *(done)* The one
  CTE shape rewriting cannot reach, because the name it resolves is its
  own. Seed once, then evaluate the recursive branch against the last
  level's rows until a round yields nothing. The hierarchy walk — the
  thing recursive CTEs are usually *for* — goes to the ORDINARY join
  planner with the CTE bound as a side, which is R5a paying for itself;
  aggregating the result reuses the grouped join with no parts. Two
  shapes the engine REJECTS were found ANSWERING (two self-references,
  and `ORDER BY` inside a branch), which is the failure direction a
  behaviour gate does not look in unless it is told to.
- **R5a — a derived table as a SIDE of a join.** *(done)* `JoinSide`,
  `JoinPart` and `Plan::Join` now carry a ROW SOURCE instead of a
  relation id, so a side can be a scan or an inner plan. A materialised
  CTE can be a join side too, which was R5's stated refusal.
- **R7 — retire the textual view/CTE rewriting.** *(done)* A VIEW is a
  ROW SOURCE: its stored SELECT is planned on its own and the outer
  query resolves against that plan's DESCRIBE, exactly as over a derived
  table; in a join it is a side, which is R5a again. `expand_view`,
  `expand_view_join`, `qualify_idents`, `replace_qualified_col`,
  `mentions_bare`, `replace_table_ref` and `replace_idents` are **gone** -
  ~870 lines - and with them the WHERE-moving, the name-lending and the
  renaming-through-text they implemented. Three shapes that refused
  because the rewriting could not express them (a view over a JOIN, a
  view under a RIGHT/FULL join, a bare renamed column in a join) now
  answer, and the derived-table and CTE planners became ONE function.
  What is left of the rewriting is a single FROM-ITEM replacement
  (`FROM C` → `FROM (<body>) C`) into that planner. Removing even that
  needs the planner to bind N names at once rather than one; the
  refusals it still carries are listed with it.

- **R8 — the fetch PULLS the tree.** *(the walk exists)* R1-R7 built
  the tree and retired the rewriting it replaced, but every node
  returned a `Vec`, so this programme's own sentence — "built by the
  planner and PULLED BY THE FETCH" — was half true. A node that
  materialises cannot express the engine's laziness, and this project
  has now measured that the laziness is OBSERVABLE, not an
  implementation detail:

  * a raiser three rows into a derived table delivers the two rows
    before it;
  * a SORT materialises its KEY, so a raiser in the key raises before
    any row while one in the PROJECTION does not — `ORDER BY ID DESC`
    delivers row 4 and then raises on row 3, in sorted order;
  * DISTINCT and a distinct UNION block, and the engine answers no rows
    there either.

  `RowSource::for_each` walks the tree handing each row to a sink, with
  a `Flow::Stop` a consumer can end the walk with; `rows()` is a thin
  collecting wrapper over it, so there is ONE traversal to reason about
  rather than two that can drift. What the split makes explicit rather
  than incidental: `TableScan`, `IndexScan`, `Filter` and `Rows` pass
  rows through; `Aggregate` and `Sort` BLOCK, as the engine's do;
  `NestedLoopJoin` still materialises, because its RIGHT/FULL mirror
  needs the whole accumulated side (`join_step`).

  *No behaviour change — the gates are the proof*, which is R1's
  standard and the right one for a step whose value is what it makes
  possible. What it makes possible, in the order it should be taken:

  1. ~~**`FIRST n` stops the scan.**~~ *(done)* `for_each_record_while`
     is the walker that can end - a SIBLING of the existing one rather
     than a signature change, since 23 of its callers are catalog walks
     that do not care - and the `Modified` arm's hand-rolled early exit
     is gone: it used to keep reading the relation and discard the
     rest, which is the right answer at the cost of the scan the engine
     does not do. The filter moved out of that closure into the tree.

     **It also caught a node LYING about which kind it was.**
     `scan_filter_sort` builds a `Sort` unconditionally, so an unsorted
     `FIRST n` went through a node classed as blocking, materialised
     the whole relation, and raised on a row the engine never reaches -
     the one gate check that measures laziness through an error
     (`SELECT FIRST 1 ID FROM TDIRTY WHERE S = 5`). **A sort with no
     keys is not a sort**, and passes rows through. Under the old code
     that distinction was invisible, because everything materialised
     and only the hand-rolled counter made FIRST behave; making the
     split load-bearing is what exposed it.

     *Measured honestly*: wall-clock cannot show the stop at any size
     this box can build - per-statement cost swamps an 80k-row scan,
     and `FIRST 1 WHERE ID > 79999`, which must scan everything, timed
     FASTER than a plain `FIRST 1`. The claim is therefore made by a
     unit test that COUNTS what the sink saw, not by a benchmark.
  2. ~~**`NestedLoopJoin` streams for LEFT and INNER.**~~ *(done)* Both
     kinds read only the outer row in hand, so "concatenating the
     per-row results IS the whole-pass result" - the identity the index
     probe already relied on, now used for the walk itself. RIGHT and
     FULL fall through to the materialising arm: their MIRROR emits the
     unmatched rows of the OTHER side, which is not knowable one outer
     row at a time. Both inner streams are still built at most ONCE,
     lazily, so an unbuildable key cannot cost a scan per outer row.
  3. ~~**Projection at delivery above `Sort`**~~ *(done)* — the
     sorted-raiser residual, and PROBING NARROWED IT from what this
     entry assumed. A plain scan with an outer ORDER BY was ALREADY
     right: that path materialises RECORDS and projects at encode,
     which is the engine's rule arrived at independently. A raiser in
     the sort KEY, and DISTINCT, block on both sides. The one real case
     was a DERIVED TABLE under an outer sort, where fire-crab sorted
     ALREADY-PROJECTED rows and so ran the inner projection for every
     row before the first shipped.

     A sort above a derived table now sorts the BASE RECORDS and runs
     the inner projection at delivery. The rewrite fires only when
     every outer key is a plain FIELD naming a plain inner column, so
     its record `field_id` exists; a key that needs the EXPRESSION
     (`ORDER BY Q` where Q is the raiser) falls through to the blocking
     path, and that is the ENGINE'S behaviour, not a shortfall - it
     must compute the key before sorting too. `qa/serve-real-derived.sh`
     57 → 61 checks and 3 boundaries, 2 DIFF against the pre-fix
     binary, with both controls and the new blocking check green on
     BOTH binaries.

  **R8's published steps are done.** What the programme has not taken:
  `NestedLoopJoin` for RIGHT and FULL still materialises (their mirror
  emits the other side's unmatched rows), `Aggregate` and `Sort` are
  blocking by nature, and the fetch still asks for a whole batch rather
  than pulling row by row across the wire - the walk is a PUSH with a
  `Flow::Stop`, which is observationally equal for errors and early
  exit but is not the engine's iterator.

  ~~The next thing worth doing here is a boundary the gates already pin:
  the engine raises a blocking node's error at OPEN, where this server
  announces the result set and raises at the first FETCH.~~
  **REFUTED BY MEASUREMENT — that boundary was an artefact of comparing
  two different TRANSPORTS.** Asked over the SAME transport fire-crab
  speaks, the engine does exactly what this server does. `SELECT DISTINCT
  CAST(S AS INTEGER) FROM TR` with one unconvertible row:

  | attachment | `MON$REMOTE_PROTOCOL` | what isql shows |
  |---|---|---|
  | bare path (embedded) | `<null>` | the error, no result set announced — **raised at OPEN** |
  | `localhost/3050:` (remote) | `TCPv4` | a blank line, then the error — **announced, raised at FETCH** |
  | fire-crab, `127.0.0.1/<port>:` | `TCPv4` | a blank line, then the error — identical |

  The engine's own remote layer does not run a blocking node at
  `op_execute`; the cursor materialises on the first `op_fetch`, and the
  error arrives there. Since fire-crab speaks only the remote protocol,
  there is nothing here to converge on. **What this leaves is a GATE
  rule, and it is the fourth time this suite has measured its own
  environment** (after `NODE_PATH` drift, isql `AUTODDL` and
  `FORCE_COLOR`): *a differential must hold the transport fixed*. Handing
  isql a bare FILE PATH for the engine side and a `host/port:` string for
  fire-crab is not one difference but two, and the second one talks.
  `qa/serve-real-modifiers.sh` was doing exactly that and now reaches
  both servers over TCP.

### Programme W — wire the converted subsystems in

Each of these is "the model exists and is right; make the server use
it", which is a different risk profile from converting something new:
the oracle already exists, so the gate is *behaviour must not change*
plus *the subsystem is now on the path*.

- **The optimizer's cost model has three further known gaps**, measured
  by a fleet against the engine's own source and confirmed by sweeping
  the crossover: `loop_cost` charges the index SCAN term against the
  table's cardinality where the engine uses the index's PAGE count
  (Retrieval.cpp:186-194), so a keyed loop looks roughly twice its true
  cost; the driver's own natural scan is not charged at position 0
  (InnerJoin.cpp:323); and only one hash arrangement is costed where the
  engine takes the minimum over all of them. Between them the engine
  crosses from HASH to a keyed loop at ~115 distinct inner values and
  fcopt at ~441. None of these is a wrong ANSWER - they choose a slower
  plan, not a different result - which is why they are recorded here
  rather than fixed in a hurry.

- **W1 — index-driven retrieval.** *(equality, ranges, compound prefixes, text keys, the fold's input, ORDER BY navigation, the FK check and DML targets done)* The first
  slice that put a converted subsystem on the running server's path.
  `crates/wire/Cargo.toml` now depends on `fire-crab-opt`, and **opt
  makes the choice**: `plan_query` is asked about the statement, and only
  when it answers `Access::Index` does the retrieval descend a tree
  (`btr::lookup_key`, new) instead of scanning. The predicate above the
  leaf is unchanged, so an index narrows what is READ and never what is
  ANSWERED.
  - Scope so far: a single-segment index on the projection's retrieval —
    equality and RANGES (`>`, `>=`, `<`, `<=`, `BETWEEN`), multiple
    bounds on one column (a conjunction narrows), any exact-numeric
    SCALE, and **DESCENDING indexes, whose arithmetic is established
    now**. It was read off the engine's own index rather than derived:
    dumping an ascending and a descending index over the same values
    gives `1 → bff0 / 400f`, `2 → c0 / 3f`, `'ab' → 6162 / 9e9d`,
    `'abc' → 616263 / 9e9d9c`, so **the descending key is the bitwise
    COMPLEMENT of the ascending one**, taken after the ascending
    zero-chop and not re-chopped — which is what `build_index_key`
    already wrote. Two things follow it: the BOUNDS SWAP (a larger value
    is a smaller key), and the COMPARISON is not `memcmp` — a shorter
    key pads with **0xFF**, so a key that is a byte PREFIX of another
    sorts AFTER it. That second rule is BOTH recorded misses, and the
    integer one is the same shape as the text one for a reason that was
    not obvious: a zero-chopped key like 2's `c0` IS a prefix of 3's
    `c008`. The rule itself is `btw::key_cmp_desc` — the write side had
    it already, and `lookup_range` asks for it rather than restating it.
    Compound descending indexes still scan (the prefix band's successor
    arithmetic is computed in ascending key space, and one rule for two
    directions is how a missed row ships). Both the PROJECTION's
    retrieval and the
    FOLD's - a grouped query and the prepare-time aggregate fast path
    read their candidates through the same leaf. A key this cannot
    build byte-exactly would be a MISSED ROW rather than a refusal,
    which is why the mechanics are narrow and everything else scans.
  - **The map of what is left, measured rather than remembered.** The
    original entry said "30 `for_each_record` sites"; there are **21**,
    and most are CATALOG walks (`RDB$RELATIONS`, `RDB$FIELDS`,
    `RDB$RELATION_FIELDS`, the FK catalog) which are not query retrieval
    at all. The retrieval sites that matter are four, and two of them
    the roadmap had never named:
    - **`fk_partner_has`** — *(done)* was a FULL SCAN of the referenced
      relation **per written row**. It drives the parent's unique index
      now; the whole key is known, so a compound index is a point lookup
      rather than a prefix range. A text key still scans.
    - **`collect_dml_targets`** — *(done)* `UPDATE`/`DELETE ... WHERE`
      retrieves through the index now. It had its own scan rather than
      going through `for_each_record`, which is why it never appeared in
      the count.
    - ~~`eval_subquery` / `build_correlated_lookup` — a subquery's own
      retrieval~~ *(done)*: the inner residual WHERE drives
      `choose_index` through a reconstructed de-aliased statement
      (fcopt refuses aliased FROM — converting that would delete the
      reconstruction); the fold model stays, because the engine itself
      hash-joins over an inner NATURAL scan for the plain correlated
      semi-join (probed plans in the gate). Still open in this family:
      the OUTER query of a folded subquery scans (`plan_query_inner`
      hands the ORIGINAL text to `choose_index` and fcopt refuses
      anything containing `(SELECT`; `plan_correlated_select`
      hard-codes `index: None` on its outer Project) — hand the FOLDED
      token text to that call. *(done)*: the WHERE-side fold is
      hoisted and rendered into a reconstructed statement at all four
      choose_index sites and both DeferredAccess constructions; the
      select-list fold's re-plan already indexed (verified, pinned);
      plan_correlated_select's outer takes index/defer now; and
      plan_update/plan_delete's choose_index calls — DEAD WEIGHT since
      W1 began (fcopt: "not a SELECT") — get the same reconstruction
      with their own "[srv] dml index:" trace. Activating the DML walk
      exposed a LATENT MISSED-WRITE bug: dml_targets_at claimed the
      recno BEFORE the staleness check, so a band covering a moved
      key's old+new entries skipped the current one — the engine
      writes the row, fc didn't. Fixed per the for_each_candidate law
      (verify only when the walk IS the order; the current image
      decides; recno dedup stops the double write). Follow-ups
      recorded: param'd DML WHERE needs a defer field on the DML
      plans; temporal/double scalar folds arrive as Tok::FnExpr
      (unrenderable → outer scan); IN-subquery outers deliberately
      stay NATURAL (the engine hashes there — model pins in the
      gate).
    - **the JOIN's inner side — ADJUDICATED against the engine's own
      plans, and it is TWO items, not one.** `SET PLANONLY ON` over a
      fixture with an indexed inner column (P 200 rows, C 2000 rows
      with a non-unique index on the FK, Q 2000 rows unindexed):

      *INNER, comma, self, three-table — DO NOT CONVERT.* The engine
      HASHes every inner-join shape fire-crab can reach: `Q ⋈ P` on a
      unique PK is `PLAN HASH (Q NATURAL, P NATURAL)`, so is the
      self-join, so is the comma spelling, and the three-table INNER
      hashes its first pair. In the ONE inner shape that does say JOIN
      (`C ⋈ P`) the engine drives the 200-row side and indexes the
      2000-row one — the DRIVER IS SWAPPED relative to fire-crab's
      left-deep fold, which cannot reproduce it without moving row
      order. Converting these would model a plan the engine does not
      have; the correlated-subquery precedent applies verbatim. **A
      pin, not code.**

      *LEFT — the slice is ON.* A LEFT JOIN never hashes. In every
      probe the engine's plan IS fire-crab's execution tree: driver =
      the syntactic left, inner = the syntactic right, `INDEX` on the
      inner's ON column when one exists (unique or not, and for `>` as
      well as `=`), NATURAL when none does, chains staying left-deep in
      SQL order with every inner indexed, and a view or derived inner
      FLATTENED rather than materialised. Two boundaries decide the
      scope: a WHERE naming the inner side FLIPS the driver (back to
      the inner-join shape, so out of scope), and the smallest honest
      first slice is a two-table `A LEFT JOIN B ON B.<col> = A.<col>`
      over plain relations with a single conjunctive equality and an
      ascending single-segment index `pick_for_terms` already keys —
      probe once per outer row, fall back to today's materialised inner
      whenever the band cannot be built. Obligations are the W1 standard
      ones (candidates are not answers, the fetched record must still
      carry the entry's key, dedup across bands, a NULL inner key, and
      the padded row must still be emitted — the last of which is why
      the partnerless-ON wrong answer above had to be fixed BEFORE this
      slice could be gated).

      *Slice A is DONE.* `JoinPart` now carries a `JoinProbe`;
      `build_join_probe` gates on LEFT + plain relation + one DNF
      branch + exactly one boundary column-equality + a bare-spellable
      table and column + a single-band blessing from `choose_index`
      over the reconstructed `SELECT 1 FROM <t> WHERE <c> = 0`, and the
      `NestedLoopJoin` arm calls `join_step` with a ONE-ROW accumulated
      side per outer row so the padding, the partnerless ON evaluation
      and the row order stay decided where they were.
      `qa/serve-real-leftjoinindex.sh` (114 checks) gates it, moved keys
      and all; the LEFT CHAIN came free, because the probe is decided
      per part off `sides[k+1].offset`, and the engine plans that chain
      left-deep with both inners indexed. Measured on C 2000 ⋈ BIG
      10000: 2.96 s → 0.39 s wall (engine 0.04 s). Two follow-ups
      recorded: (a) `records_for` rebuilds `page_sequence_map` per
      call, so a probe pays it once per outer row — hoist it behind the
      same function when it starts to dominate; (b) a WHERE naming the
      inner side still probes here, because this executor's tree is
      fixed by the SQL and cannot reproduce the engine's driver flip —
      the rows are the engine's, only the plan shape diverges, and it
      diverged that way before the probe too.

      *The refute pass (265 probes) confirmed the rows and falsified a
      SENTENCE.* Moved keys, keys at every type rim, all-NULL inner
      keys, MVCC, an index built after a DROP COLUMN, the join inside a
      subquery, a CTE and a view body — the row sets held everywhere,
      and the INNER/comma/self pins stayed unprobed. What did not hold
      is W1's usual phrasing, "an index narrows what is READ, never
      what is ANSWERED": an ON that RAISES is value-gated by the band,
      so `ONEN LEFT JOIN RZ ON RZ.K = O.K AND RZ.T > 0` answers the
      padded row under the probe and raises 22018 under `FC_NO_INDEX=1`.
      **The probe is the ENGINE'S answer** — the engine indexes that
      inner side too — so the invariant was reworded (…*and with it
      WHICH ON EVALUATIONS HAPPEN*…) rather than the code changed. It
      is the first place in W1 where the two retrieval paths of the
      same server legitimately differ, and the FC_NO_INDEX twin is an
      equivalence oracle only for non-raising ONs from here on.

      *And it measured the gap, which is the shape of Slice B*: SEVEN
      inner sides the engine INDEXES and this probe declines — **five
      now**: the scaled-NUMERIC keys closed `NUMERIC(9,2)` and the
      descending arithmetic closed the DESCENDING index, both of them
      OUTSIDE the join, because neither refusal was ever about the join
      (`pick_for_terms` declined every scaled column and every
      descending one, so plain `WHERE` retrievals scanned too). The
      rest: `NUMERIC(38,0)`, a VIEW inner
      (the engine flattens it), a DERIVED inner, an expression in the
      ON (`RZ.K = O.K + 0`), an OR in the ON, and the engine's bitmap
      AND of two indexes. Their rows agree today; with a raising ON
      they do not, so each is a shape where identical SQL raises or
      answers depending on whether fire-crab's heuristics bless the
      inner. `pick_for_terms`, not the fcopt gatekeeper, is what
      refuses most of them (fcopt blesses `NUMERIC(9,2)` happily) —
      which is why the band is built through `choose_index` rather than
      trusted from the plan text.
  - **A predicted bug that measurement did not confirm, recorded as
    such.** `ods::ddl::index_itype` maps every TEXT/VARYING column to
    `idx_string`, ignoring the charset, so a `CREATE INDEX` issued to
    fire-crab on a UTF8 column stamps itype 1 where the engine stamps 4.
    It was expected to produce an index the engine misreads. It does
    not: the engine builds its lookup keys from the itype IN THE INDEX
    ROOT, so the index is self-consistent either way, a gbak round trip
    normalises it, and the two encodings differ only for the EMPTY
    string. The WRITE path was never at risk because
    `resolve_index_ops` reads the itype from the root too — which the
    gate now pins with an empty-string lookup, the one byte where
    `idx_string` (0x20) and `idx_metadata` (0x00) disagree. It remains a
    metadata divergence worth closing, not a wrong answer.
  - **Scaled NUMERIC/DECIMAL keys** *(done)*. A `NUMERIC(9,2)` is a LONG
    holding 1250 at scale -2 and its key is the DOUBLE 12.5 — the same
    bytes a `DOUBLE PRECISION 12.5` gets; a `NUMERIC(18,2)` is an INT64
    and takes the `INT64_KEY` form. **The ENCODER always handled both**
    (`index_key`'s IDX_NUMERIC arm divides by the power of ten, which is
    `MOV_get_double`'s way — multiplying by 10⁻ⁿ differs in the last ulp
    for about a third of the raws at scale 1, and a key one bit off is a
    key the engine never wrote). What was missing was one step earlier:
    carrying the LITERAL to the column's own scale before asking for a
    key. `pick_for_terms` refused every column with `scale != 0`
    outright, so the engine indexed `WHERE N92 = 1.50` and fire-crab
    scanned. `at_column_scale` now moves a literal there — `1.5` and `2`
    both reach a `NUMERIC(9,2)` — and **a literal that does not land
    exactly still scans**: `N > 12.505` has no key at scale -2, and
    rounding one out moves the band's EDGE, which drops rows no filter
    above can recover. FLOAT/DOUBLE columns keep scanning for the same
    reason from the other side: their key is the value's own bits, and a
    decimal literal would have to travel the engine's literal→double
    conversion to land on them. `qa/serve-real-index.sh` 359 → 387
    checks, 14 DIFF against the previous commit — **all of them
    COVERAGE, none of them answers**, which is the right shape for a
    slice that changes which path is taken and not what is returned.
  - **Compound prefixes and text keys** *(done)*: an equality on an
    ascending compound index's LEADING segment is a band whose upper
    bound is the prefix's EXCLUSIVE SUCCESSOR (an inclusive one drops
    every row with a non-NULL trailing segment), and text equality is
    keyed for ASCII literals on `idx_string` and `idx_metadata`.
  - ~~**A named, measured write-path divergence at `i64::MIN`.**~~
    *(done — and the premise was backwards)*. The entry said
    `btw::int64_key` builds a key the engine did not write, because
    `make_int64_key` NEGATES before choosing a scale and negating
    `i64::MIN` overflows, "so its choice differs from the arithmetically
    correct one" — true, and it stopped one step short. **What the
    engine actually WRITES was never read.** Written by the engine, one
    value per database, dumped with `fcstat index-walk`:

    | value | stored key |
    |---|---|
    | `-9223372036854775808` | `800000000000000080` |
    | `0` | `800000000000000080` |
    | `-9223372036854775807` | `3cf5c91d14e3bcd76951` |
    | `1` | `bf1a36e2eb1c432d80` |
    | `-1` | `40e5c91d14e3bcd280` |

    **THE ENGINE FILES `i64::MIN` UNDER ZERO'S KEY.** The overflow does
    not perturb the scale choice, it sends the loop one bucket on, and
    `q *= 10` on `i64::MIN` wraps to exactly 0 (10·2⁶³ is a multiple of
    2⁶⁴), so both parts come out zero — at every scale, since
    `0 / powerof10(scale)` is 0.

    **It is a DEFECT, and it is the ENGINE'S ALONE**: equality finds
    such a row (both sides compute the same wrong key) while every RANGE
    misses it, because the entry sits at zero's position. On the engine,
    `A < -9223372036854775807` answers NOTHING though the row exists,
    and `A+0 < -9223372036854775807` — the same predicate with the index
    taken away — returns it. Matching it is not endorsing it: **a key is
    an ADDRESS in a shared file**, and a row written at a different
    address is one the engine's own lookups cannot find, which is a lost
    record rather than a slower one. So `int64_key` answers zero's key
    here instead of abstaining, `fcstat`-dumped bytes are pinned in a
    unit test, and `qa/serve-real-btree.sh` writes the row with
    fire-crab and reads it back **with the engine** (plus `gfix -v
    -full`, which cross-checks every record against every index entry).

    The blocked half is unblocked too. The literal parse read a digit
    run WITHOUT its sign — a leading `-` is a separate unary node — so
    `9223372036854775808` overflowed `i64` and the whole statement was
    REFUSED, though the value it names is representable. Measured, the
    engine folds the sign in before it types the literal: `-<digits>`,
    `- <digits>` and `-(<digits>)` all describe as **INT64**, while the
    bare magnitude and anything wider are **INT128** (and past 2¹²⁷,
    DECFLOAT(34)). Only the exact magnitude is folded; everything wider
    stays refused until INT128 literals are their own slice, which is a
    real one — `Rhs` carries an `i64` raw across 113 sites.

    **It also uncovered a silent wraparound.** `Expr::Neg` used
    `wrapping_neg` where `+` and `-` beside it have always raised, and
    nothing could reach it until this value became spellable. The engine
    describes `- -9223372036854775808` as INT64 and raises 22003 at the
    row; that arm now does the same.

    *This is the SECOND place where fire-crab's two retrieval paths
    legitimately differ* (after the raising ON). `FC_NO_INDEX=1` answers
    the arithmetically correct rows for a range over `i64::MIN`; the
    index path answers the engine's. The twin is an equivalence oracle
    everywhere except this value and a raising ON.

    *Residual, pinned in the gate rather than left silent*: the WHERE
    clause has its OWN tokeniser and the fold lives in the select list's
    parser, so `WHERE A = -(9223372036854775808)` still refuses where the
    engine answers. The BARE spelling works on both sides everywhere.
    Closing it means teaching the token lexer the same magnitude — a
    refusal, never a wrong answer, and the check says so.

  - **`OR` and `IN`** *(done)*: a disjunction is a UNION OF BANDS, one
    per DNF branch, with every branch required to be servable (a partial
    union is a missing set of rows) and candidates deduplicated ACROSS
    bands (one row can satisfy two branches).
  - **Parameters** *(done)*: the bands are built at EXECUTE from the
    bound predicate, since a `?` has no value at prepare. Only the
    projection's retrieval defers so far - a parameterised GROUP BY or
    DML WHERE still scans.
  - **A failure that was the GATE's, and a claim of mine that was
    wrong.** `qa/serve-real-params.sh` had been failing since before W1,
    and I reported it as "fire-crab accepts a boolean parameter INSERT
    the engine rejects" — inferred from the gate's expectation rather
    than from the engine. Asked directly, **the engine accepts it too**,
    and the two files come out byte-identical: node-firebird 2.14.1 made
    boolean encoding metadata-directed, so a BOOLEAN target now gets a
    real `blr_bool`. The gate's premise was written when the driver could
    not do that. Four failures, every one pointing at fire-crab, and
    none of them fire-crab's. The gate now asks the engine instead of
    remembering.
  - Still to do: index-driven joins,
    text keys (a collation makes the key a collation key), compound
    prefixes, and parameters (their values arrive after the plan is
    built). Also: a statement `opt` cannot parse - a `HAVING`, for one -
    scans, because the retrieval inherits the optimizer's own limits.
  - **The rule that took two increments to state correctly.** "An index
    names candidates, the predicate decides" is not enough: an entry
    outlives the version that wrote it, so a record whose key CHANGED is
    named by both its old and its new entry, and a range covering both
    returns it TWICE — which no predicate can catch, because the row
    genuinely matches. A candidate is kept only if the fetched record
    still carries the entry's key.
  - It also fixed a pre-existing wrong answer it was in a position to
    see: uniqueness was read from the index ENTRIES, which outlive their
    records, so re-inserting a deleted key was refused against an engine
    that accepts it. The conflicting records are fetched and checked now
    — the same "candidates, not answers" rule.
- **W2 — the page cache.** *(the write order done; the image now
  SHARED)* **The buffer pool landed** (`fire_crab_cch::pool`): the pages
  of a database live **once per file per process** instead of once per
  attachment. `load_database` opens through the pool, readers take a
  reference-counted snapshot of the image, and writers are **serialized
  per database** — the write side is taken at a transaction's first
  write and held to its commit or rollback, because a rollback here
  restores a whole-image snapshot and must not be able to restore over
  another connection's committed rows. A connection that never wrote no
  longer restores anything at all. The pool re-reads a file that
  changed underneath it and forgets a dropped one.

  That closed both divergences W4's oracle had recorded — an attachment
  opened before another's commit sees it, and 20 concurrent inserts
  across two attachments leave 20 rows — and `qa/serve-real-concurrency.sh`
  now asserts the engine's answers on both, plus a COVERAGE section
  reading the pool's own counters (attachments that found the image
  resident, writers that queued) out of the server log, because the
  behaviour checks would also pass against a server whose probes never
  overlapped.

  Still to do here: **per-page fetch**. The unit of sharing is the whole
  image, not `Cache`'s buffer descriptors — reads still slice, they just
  slice pages nobody else can lose. Hit accounting and eviction are the
  rest of W2, and the seam for them is the single `SharedImage::image`
  every read now goes through. Also still: a file that GROWS is written
  whole (extending is its own careful-write question).

  **AND THE COMMIT IS WHAT WRITES NOW.** A statement installs its pages
  into the pool and leaves them dirty; the COMMIT flushes them, in one
  careful pass that carries the transaction's two bits as well. An
  autocommit INSERT was paying two flushes (~866us each of 2.78ms), a
  multi-statement transaction one per statement; both pay one now. It
  is also the durability the engine has: pages no commit reached are
  pages a crash may lose, and killing the server mid-transaction leaves
  the file holding exactly the committed rows.

  And the bug that came with it is the kind worth writing down: the
  commit returned early when the transaction had reserved no
  transaction ID, which is precisely what a DDL-only transaction looks
  like - its catalog rows are settled as they are written, so it never
  asks for one. Its pages stayed dirty and unwritten, and the engine
  reading the file answered *Table unknown*. **Deferring a write means
  every path that ends a transaction has to know it owns a flush.**

  **The last whole-file write went with it.** A generator draw did
  `fs::write` of the image - 5.5ms on a 2MB database, 26.4ms on a 5MB
  one - and so did putting a snapshot back. Both go through the pool
  and its careful flush now: 2.12ms and 3.68ms for the same draws. What
  is left that scales with the file is the per-write COPY of the image,
  which is what per-page fetch removes.

  **WHERE A STATEMENT'S TIME GOES NOW**, measured on an indexed table
  (`FC_SRV_TIME=1`, INSERT 3.6ms end to end):

  | phase | cost |
  |---|---|
  | the careful flush | 2234us |
  | the SELECT plan | 1003us, of which `choose_index` 544us |
  | the DML plan | 420us |
  | executing the write | 118us — the record write itself 2us, index maintenance 6us |
  | the image copy per write | 84us |

  **The statement cache is in, for DML and SELECT alike**
  (`crates/wire/stmc.rs`, 4 unit tests, `FC_NO_STMTCACHE` switch). It
  took a correction first: **a plan was not always a pure function of
  (schema, text)**, because a lone aggregate and a `GEN_ID` read were
  COMPUTED at prepare and carried in the plan. `Plan::Scalar` holds a
  `ScalarVal` now - what to compute, not what was computed - and the
  fetch works it out, which is where the engine works it out. Measured:
  `plan(select)` 984us → 291us and the statement 1.22ms → 0.50ms;
  `plan(dml)` 645us → 514us on a repeated parameterised INSERT. Timed on
  the WARM path rather than as an average, a repeated SELECT is 0.26ms
  against 1.34ms uncached and the hit itself is unmeasurable: the cache
  hands back an `Rc` rather than cloning the plan out, worth 3.3us per
  prepare on a bulky plan and 0.2us on a small one.

  **An average over a cold start is not a measurement of the warm
  path.** "The clone is what a hit costs" was inferred from averages a
  single MISS dominated, and it was wrong by two orders of magnitude.
  Time the thing itself.

  An unfiltered
  `SELECT COUNT(*)` is folded to a CONSTANT at prepare time, so a
  cached plan freezes the count - measured, with the cache on: one row,
  insert a row, ask again, one. The same query with a filter, which is
  not folded, answered two.

  So the next step is precise: **move the unfiltered COUNT(*) fold from
  prepare to execute** - it should plan to the aggregate the filtered
  one already plans to - and then the cache goes in unchanged. It was
  worth measuring what it would buy first: plan(select) 1104us → 299us,
  the statement 1.40ms → 0.50ms.

  Two things follow. **The flush is the physics of the disk**: Forced
  Writes means a synchronous write per page, and the engine is in the
  same regime — fewer pages per transaction is the only lever, and the
  commit already batches a transaction's statements into one. **And
  `choose_index` calls the optimizer per statement**, which re-derives
  its plan from the SQL text and the index metadata every time. That is
  a STATEMENT CACHE - the paper has a chapter on it, the engine has one,
  and fire-crab has none: the next item after this one, with its own
  invalidation (DDL, as here) and its own bound.

  **MEASURED AT SIZE, and both of the costs are O(FILE).** With
  `FC_SRV_TIME=1`, one INSERT:

  | database | INSERT | work copy | careful flush | execute |
  |---|---|---|---|---|
  | 6MB | 4.0ms | 259us | 2449us | 300us |
  | 33MB | 32.0ms | 6550us | 13660us | 6677us |

  Two costs scale, not one. The **image copy** every write makes, and
  the **flush's diff** — `changed_pages` compares the work image with
  the file page by page over the WHOLE file to find the handful that
  moved. At 33MB they are about two thirds of the statement.

  **And the shortcuts do not work, which is why this needs the real
  thing.** A private per-TRANSACTION working image would make the copy
  once per transaction instead of once per statement — but a private
  image is exactly what the buffer pool removed: two transactions each
  publishing a whole image at commit lose each other's rows, unless the
  write side is held for the whole transaction again, which is what W4
  stopped doing so that two writers could work at once.
  `Arc::make_mut` cannot win either while the pool holds a reference of
  its own. **The blocker is that `ods` addresses a database as one
  contiguous `&[u8]` with absolute offsets** — `resolve_relation(file,
  page_size, name)`, `assembled_image(file, ...)`, `u32_at(file, off)` —
  so the pages cannot be stored, shared or copied one at a time while
  that is the shape of the API.

  So the work is: give `ods` a page-addressed image (`Vec<Arc<[u8]>>`
  behind a `pages(n) -> &[u8]` accessor), convert its readers and
  writers to it, and let the pool publish by replacing the pages that
  changed — which also gives the flush its changed set for free and
  ends the diff. It is the largest single piece left in programme W,
  and it is worth what the table above says: at 33MB, ~20ms of a 32ms
  statement.

  **MEASURED BEFORE DOING IT, and it is not where the time is.** With
  `FC_SRV_TIME=1` on a two-row table, an INSERT cost 8.2ms: the work
  copy 111us (1.3%), the careful flush 957us, and **building the plan
  5.6ms**. The whole-image copy per write is real and grows with the
  file (~0.39ms/MB, so ~40ms on a 100MB database — it will have to go),
  but the statement in front of it was spending five times as much
  re-reading the catalog. That is what the metadata cache below
  answered, and per-page fetch is worth doing for the SCALING, not for
  the fixed cost.
- **W2 (as it stood) — the careful write order.** The server's DML
  flush writes PAGES in `cch`'s precedence order and syncs each before
  the page that references it, instead of dumping the whole file — so
  every prefix of the write sequence is a database the engine can open,
  which is exactly what `qa/cch-crash-harness.sh` had been checking
  about a model nothing called. `crates/wire` depends on
  `fire-crab-cch` now. Measured: five pages per statement instead of the
  whole file, and no speed change (the per-page sync cancels the smaller
  write) — this buys crash behaviour, not throughput. The read path that
  this left "slicing the image directly" was afterwards found to be
  **W4's prerequisite rather than a parallel item**, and is what the
  buffer pool above answers.
- **W3 — platform I/O.** *(the write path done)* The careful flush
  writes its pages through `fire-crab-pio`, opened with
  `plan_for_header(<the header's flags>)`. That fixed a rule the flush
  had got wrong on its own: **Forced Writes is an OPEN MODE, not an
  fsync per write** — the engine adds SYNC to the open mode when the
  header says so and does nothing per write when it does not, while the
  flush had been syncing every page unconditionally. Measured: 38.4s
  with it on against 38.3s off, so the sync was never the cost. Still to
  do: the READ path (the pool holds the image; `pio` is not the one
  reading it in).
- **W4 — the lock manager participating** (`lck`). *(done)* Written as
  "what makes concurrent attachments correct rather than accidentally
  correct", then **measured, and it was neither** — and the finding was not a missing lock manager but a
  missing *shared resource*: every attachment held a private
  `std::fs::read` copy of the file, so two attachments were two
  databases that shared a filename. `qa/serve-real-concurrency.sh` is
  the first gate in this suite that opens TWO of them, which is why none
  of the other 183 ever said anything about it.

  **The buffer pool (W2) is that resource, and it is in.** What the same
  probes answer now:

  | probe | engine | before the pool | with the pool | with transaction state |
  |---|---|---|---|---|
  | writer sees its own write | 555 | 555 | 555 | 555 |
  | an attachment opened BEFORE the commit | 555 | **100** — frozen at attach | 555 | 555 |
  | one opened AFTER | 555 | 555 | 555 | 555 |
  | the engine reading the file | 555 | 555 — durable and correctly on disk | 555 | 555 |
  | 20 concurrent inserts, 10 per attachment | all 20 rows | **10** — one image overwrote the other | all 20 rows | all 20 rows |
  | `gfix -v -full` on the result | clean | clean (that is what made it silent) | clean | clean |
  | an uncommitted row, read from another attachment | invisible | invisible — nothing was shared | **visible** | invisible |
  | a second writer, on an UNRELATED row | does not block | did not block | **waits** | **waits** |

  **The second-to-last row closed with real transaction state**, which
  is the half of W4 that is not locking at all. A transaction reserves
  one id at its first write and leaves it `tra_active` in the TIP;
  COMMIT is the two bits that flip it; every record walk goes through
  `fire_crab_ods::tra::visible_version` and takes the newest version
  whose transaction it counts — committed, its own, or the system
  transaction (id 0, whose slot reads active in every real database
  because the engine answers for it in code). That wired `tra`, which
  had been converted and gated since the MVCC increment with nothing
  calling it.

  Two rules came with it, both the engine's: a connection that detaches
  with work uncommitted has its transaction marked `tra_dead` rather
  than left open for good, and the system transaction (id 0) counts as
  committed although its TIP slot reads active. And one bug came out of
  it — reserving the id in an install of its own exposed that a careful
  flush was diffing against the last image PUBLISHED rather than the one
  on DISK, so pages changed by an install that was not itself flushed
  never reached the file. `qa/serve-real-update.sh` caught it as 16
  record-level errors from `gfix -v -full`; the pool now keeps the
  on-disk image as the flush baseline.

  **What is left is granularity.** fire-crab serializes writers on the
  DATABASE — the write side is held from a transaction's first write to
  its commit, because rollback here restores a whole-image snapshot —
  where the engine blocks only on a CONFLICTING row, through `lck` plus
  the record's transaction state.

  **And the reason the write side is held that long is the rollback, not
  the locking.** That is the dependency worth writing down before
  anything is enqueued, because `lck` is not the first step:

  1. **Rollback by STATE, not by image.** *(done)* A transaction that
     wrote only records is undone by `tra_dead` — two bits — instead of
     putting back the whole image; the rows, the index entries naming
     them and the pages they allocated all stay, and none of it counts,
     which is what the engine leaves behind too. `qa/serve-real-undo.sh`
     holds it: 202 versions still on the pages after the rollback, the
     engine reading 2 rows, `gfix -v -full` clean — **and that read
     collecting them, 202 → 34, because Firebird garbage-collects
     cooperatively**; the sweep takes the rest. One page flushed instead
     of the database; 32ms → 11ms to roll back 200 inserts on a 20MB
     file. Snapshots became free on the way (a reference to an immutable
     published image, not a copy).

     What still needs an image: DDL, whose catalog rows are settled as
     they are written, and `ROLLBACK TO` a mark — one transaction id
     cannot say "undo the last three statements". Those transactions
     carry `Database::image_undo`, and it is what step 2 will keep the
     transaction-scoped write side for.

     It also found a bug of the kind this whole programme is for: the
     rows a rollback now LEAVES behind were still being counted.
     `SELECT COUNT(*)` with no filter took a decode-free fast path over
     live primary headers — right only while every transaction in the
     file was committed — so a refused statement's rolled-back row came
     back as `COUNT(*) = 1`. Nothing about the count was new; what was
     new was a file that finally contained a row nobody should see.
  2. **A statement-scoped write side.** *(done)* The exclusive window
     is the read-modify-write of ONE statement now, released between
     requests, so two transactions can be open and writing at once. A
     transaction whose undo still needs an image keeps it — and the
     image it would put back is refreshed at each statement boundary
     until then, since restoring the one from transaction start would
     undo another connection's commits that landed in between.
  3. **The conflict, through `lck`.** *(done)* And the engine's
     mechanism turned out not to be a lock per record at all: a writer
     that meets a version belonging to another transaction reads that
     transaction's STATE, and waits on the lock that transaction holds
     over its own id (`LCK_tra`). `crates/wire/dblocks.rs` is those two
     calls; `with_conflict_wait` drops the write side, waits, and runs
     the statement again — the engine's WAIT and re-read. Two
     transactions waiting on each other close a cycle in the wait-for
     graph and one is denied with the engine's own `isc_deadlock`.

  Written this way round because the tempting order — enqueue first —
  would have produced locks that arbitrate a resource nothing else can
  reach during a transaction, and every single-session gate would pass.

  And it cost one bug worth keeping: **"has this transaction written?"
  had been answered by "does it hold the write side"**, which was the
  same question until the side became one statement long. A transaction
  that wrote and then read held nothing, so its rollback believed there
  was nothing to undo and skipped the generator compensations —
  `qa/serve-real-genwrite.sh` said so. The transaction carries the
  answer itself now.

  **What is left of W4** is the shape of the answer, not the answer:
  the engine's deadlock vector carries two more items after the code
  (`isc_update_conflict` and the concurrent transaction's number), and
  the TPB's NO WAIT / LOCK TIMEOUT are read as WAIT.
- **W7 — the metadata cache** (`mdc`). *(done, and it was the
  measurement that put it here)* Every plan re-derived its table from
  the file — id, columns, descriptors, index operations, NOT NULL
  fields, identity column, qualified name, each a walk of a system
  relation — and `FC_SRV_TIME=1` put 5.6ms of an 8.2ms INSERT in
  planning. `crates/wire/mdc.rs` holds those answers per database,
  keyed by a generation only DDL advances (and the buffer pool's epoch,
  since a re-read file is a different database). Plan 4857us → 1809us,
  INSERT 7.4ms → 4.3ms. `qa/serve-real-metadata.sh` runs a
  DDL-then-DML script through the engine, through fire-crab and through
  fire-crab with `FC_NO_MDC=1`, and all three must agree.

  Then the rest of the plan, phase by phase: `plan:defaults` was
  1277us of the 1852us that remained — a walk of the whole of
  `RDB$RELATION_FIELDS` and a blob per default, for an answer that
  depends on the table and not the statement. Split into a cached
  `table_defaults` (with a per-column "exists and cannot be evaluated"
  marker, so a statement that omits the column still refuses) and a
  per-statement filter; the FK partnerships and check predicates
  followed. **Plan 5498us → 402us, INSERT 8.2ms → 3.06ms.**

  The SELECT planner followed - its own id and columns, the formats it
  decodes with (the system relations' bootstrap walk included) and the
  computed-column sources - taking `plan(select)` from 902us to 657us
  and the statement from 1.24ms to 0.94ms.

  Still outside it, deliberately: `choose_index` (232us) depends on the
  statement's filter and ORDER BY, not only on the schema. Still
  outside it, not deliberately: the triggers a statement gathers, and
  the per-statement CLONE of the cached check predicates (127us) -
  the answer is shared, the copy is not.
- **W5 — event delivery** (`evt`). *(done)* `POST_EVENT` is
  a PSQL statement now - a procedure containing one used to be refused
  whole - and `fire_crab_evt` is on the path behind it: the post is
  filed under the transaction, the COMMIT moves the counter, a ROLLBACK
  swallows it, and the table is per database so a poster in one
  attachment moves what a listener in another is watching
  (`qa/serve-real-events.sh`, 7 checks).

  ~~**What is left is the carrying**~~ **DONE** (second slice, and W5
  with it). `op_connect_request` answers a sockaddr for a listener of
  the server's own; the client opens the second socket; `op_que_events`
  registers an interest from an EPB; `op_cancel_events` takes it down;
  and each delivery is an `op_event` frame pushed on that socket by
  whichever attachment's COMMIT moved the counter - another connection,
  on another thread, which is why the sockets live in a per-database
  registry beside the event table.

  **The gate is the paper's own client**, as this section predicted:
  `samples/nodejs/events.js` runs against the live engine and against
  fire-crab and the two outputs must match LINE FOR LINE
  (`qa/serve-real-eventdelivery.sh`, 10 checks). That is a stronger
  statement than an assertion of our own, because the client was not
  written for it.

  **It also corrected two counter laws that no gate could see before.**
  A delivery carries `evnt_count + 1` (event.cpp:884), so a subscriber
  to an event nobody has posted is told 1; and a post to a name with no
  event block is DROPPED WHOLE (`if (event)`, event.cpp:376), the block
  being made by a subscription. Both were invisible while the only
  available differential compared DELTAS - which `qa/evt-semantics.sh`
  had to, having no delivery path to read an absolute number from. The
  carrying is what made them observable, and they disagreed at once.

  `EXECUTE BLOCK AS ... BEGIN ... END` came with it, because the
  paper's client posts with one: the interpreter's own surface with the
  DDL taken away, running at execute because it may write, its errors
  carrying the engine's `At block line: L, col: C`
  (`qa/serve-real-execblock.sh`, 11 checks). The parameterised and
  `RETURNS` forms are refused and gated as boundaries.
- **W6 — depth in `exe` and `svc`**: the request lifecycle, cursors and
  exceptions; then gbak/gfix/nbackup as services. *(three slices done;
  the first corrected the sentence above)*

  **EXCEPTIONS ARE DONE for the user-exception half** (third slice):
  named handlers, a bare `EXCEPTION;` re-raise, and - the point of it -
  an uncaught exception reaching the client as the engine's own error
  rather than a generic Dynamic SQL Error, `At procedure ... line: L,
  col: C` included (`qa/serve-real-exceptions.sh`, 19 checks).

  **The rest of `exe`, measured rather than guessed.** Eleven PSQL
  shapes were run against both servers; ten were refused, one worked.
  What is left, in the order the measurement suggests:

  * ~~runtime errors as catchable conditions~~ **DONE** (fourth
    slice): every error the interpreter raises carries a gdscode, a
    SQLCODE and a SQLSTATE, so all three condition forms work, a
    division by zero is catchable, and an overflow that used to answer
    NULL raises 22003 (`qa/serve-real-psqlerrors.sh`, 15 checks). The
    identity is read back out of the vector the server would send, so
    the two can never disagree;
  * ~~explicit cursors~~ **DONE** (fifth slice), and `LEAVE`/`EXIT`/
    `ROW_COUNT` with them, since the canonical loop needs all three
    (`qa/serve-real-cursors.sh`, 14 checks). The cursor's query is
    planned by the ordinary planner, so it sees joins and expressions
    for free; a fetch past the end leaves the variables alone, which is
    the part that would silently answer wrongly if guessed;
  * ~~`EXECUTE PROCEDURE` inside a body~~ **DONE** (sixth slice), with
    `ROW_COUNT` for DML alongside it (`qa/serve-real-callproc.sh`, 15
    checks);
  * ~~`EXECUTE STATEMENT`~~ **DONE** (seventh slice), in all three
    shapes - bare, `INTO` for a singleton, and the `FOR EXECUTE
    STATEMENT` loop (`qa/serve-real-execstmt.sh`, 33 checks). It is
    `isc_dsql_execute_immediate` seen from the inside, so it goes down
    the SAME plan chain a client's statement does - the chain was
    EXTRACTED from the `op_exec_immediate` handler rather than copied,
    because two lists of what a server can execute would drift, and the
    direction they drift is a body silently refusing DDL a client is
    served. What had to be measured rather than guessed: **a dynamic
    DML does not touch `ROW_COUNT`** (the count stays that of the last
    STATIC statement), a singleton that matched nothing leaves its slots
    alone, one that matched several raises 21000 rather than taking the
    first, the INTO slots must equal the projected columns exactly -
    including a query with NO INTO, which is the same "Output parameters
    mismatch" - and a NULL or empty text is the engine's -104, not a
    no-op. Two things came with it because the feature is unusable
    without them: a **text assignment** (`S = 'SELECT ...' || :K`), since
    `Expr` is arithmetic and has no string literal, and **a body's DML
    failure carrying the engine's own error** instead of a generic
    Dynamic SQL Error - which is what lets a handler catch what the
    dynamic statement raised, and which fixed the static form too. The
    text surface also surfaced a WRONG ANSWER that predates it: `N =
    '5'` into an INTEGER output is a conversion the engine performs, and
    the row encoder renders a text value into an integer slot as 0, so
    the client was told 5 is 0. Both the source interpreter and the BLR
    executor now refuse it instead;
  * ~~`IN AUTONOMOUS TRANSACTION`~~ **DONE** (eighth slice), and
    `EXECUTE STATEMENT ... WITH AUTONOMOUS TRANSACTION` with it, since
    it is the same requirement wearing the other syntax
    (`qa/serve-real-autonomous.sh`, 22 checks). The block reserves its
    own id, commits or dies on its own, and - the part that took the
    work - **what it committed survives the failure of the body around
    it**, because every undo in this server is "put an image back" and
    the block's pages therefore have to be written FORWARD over what the
    undo restores, the way the generator windows already write their
    settled values. The other direction came free: the block cannot see
    the outer transaction's uncommitted rows, since visibility here is
    "committed, or my own" and the block's reads run under the block's
    id.

    **What it refused, and what lifted it - DONE, the increment after
    it.** If the BODY AROUND the block had already written, the enclosing
    undo restored an image without those writes and the page carve-out
    carried them straight back in - a failed statement's own rows, still
    visible to its transaction. Undoing them needed them to have a
    transaction of their own to KILL, which is the engine's savepoint
    model (`tra.cpp`'s undo records / `VIO_verb_cleanup`). **That is now
    what every undo window is** (see *A savepoint is a transaction*
    below): the body's writes carry a nested id, killing it is the undo,
    and both the body-wrote-first and the block-inside-a-block boundary
    are ordinary differential checks. What is still refused is the two of
    them meeting the IMAGE path - a transaction that has done DDL.

    It also found where the ISOLATION MODEL first shows: the outer
    transaction reading what the block committed answers 0 in the engine
    (its snapshot predates the block) and 1 here (a reader counts what is
    committed when it reads). Snapshot isolation is not converted; the
    gate asserts the divergence rather than letting it pass;
  * ~~`ROW_COUNT`~~ **DONE** with the slice above - the DML paths report
    what they touched back into the frame, and a statement that matched
    nothing answers 0 rather than leaving the previous count.

  Also found while gating: **fire-crab announces every procedure OUTPUT
  PARAMETER as BIGINT**, where the engine announces the declared type -
  the values agree, the column widths a client prints do not, which is
  visible the moment a procedure has two output columns; **an
  expression in a `DECLARE ... CURSOR FOR (...)` select list must be
  ALIASED** or the engine answers "Invalid command" (the identical
  SELECT runs standalone); **`SELECT ... INTO :v` - the STATIC singleton
  - is outside the surface**, which the dynamic form's gate found by
  contrast (the same query through `EXECUTE STATEMENT ... INTO` works);
  **a BIGINT literal is outside the PSQL surface** (`Expr::IntLiteral` is an `i32`, and widening it changes BLR
  encoding and type ranking - its own increment), **`INSERT ... VALUES`
  without a column list** is outside it too, and **`CREATE PROCEDURE` is
  not supported at all** - every gate builds its procedures with the engine
  and executes them through fire-crab, which is why the interpreter is
  well covered and the DDL is not.

  And one that had been hiding: **a COMMENT in a body refused the whole
  body**, because the statement walk skipped whitespace and not `/* */`
  or `--`. It survived this long because a body of nothing but
  ASSIGNMENTS never reaches the source parser at all - the BLR executor
  answers it - so only a body that also WRITES showed it. Fixed with the
  autonomous slice, whose gate found it by commenting one of its own
  procedures. **A comment INSIDE a statement is still outside the
  surface**: the statement text is taken verbatim between semicolons and
  handed to parsers that do not know comments either.

  **`gfix -write sync|async` is not a service at all.** Filing the
  tools under "as services" was a guess, and this one is wrong: gfix
  ATTACHES, carrying the mode in the DPB as `isc_dpb_force_write` (tag
  24, consts_pub.h:59), and detaches. A server that answered only the
  service manager would leave the switch silently doing nothing. What
  it asks for is one bit - `hdr_force_write` (ods.h:724) in the header
  page - which `fire_crab_pio::plan_for_header` has read since it was
  converted to decide whether a flush opens the file with SYNC; what
  was missing was only the ability to CHANGE it
  (`qa/serve-real-forcewrite.sh`, 9 checks, `gstat -h` as the oracle).

  The lesson generalises to the rest of the tier: **before writing a
  service, check whether the tool uses one.** gbak/nbackup genuinely
  are services; gfix is not, for any of its switches.

  *(second slice done)* The other three header items followed - `-use
  full|reserve` (`hdr_no_reserve`), `-buffers N` (`hdr_page_buffers`)
  and `-housekeeping N` (a CLUMPLET, which meant porting `storeClump`
  and maintaining `hdr_end` - the field only a writer needs, whose
  absence is silent corruption rather than a wrong answer). 23 checks
  in `qa/serve-real-gfixheader.sh`.

  It also corrected an assumption worth keeping visible: **gfix sends
  one item per run.** `buildDpb` (exe.cpp:207-344) is an else-if chain,
  so several switches collapse to whichever the CHAIN reaches first and
  the rest are dropped with rc=0.

  *(third slice done)* **`-mode read_only|read_write`** - the flag is one
  bit (`hdr_read_only`, 0x20) and the refusal path behind it was the
  work, which is why it went last. Three laws had to be measured rather
  than assumed, and each one is a place a converter guesses wrong:
  the mode switch takes the database EXCLUSIVELY and is the ONLY gfix
  switch that does (`-write`, `-buffers` and `-housekeeping` change the
  header with an attachment held; `-mode` answers `isc_lock_timeout` +
  `isc_obj_in_use` naming the file, immediately); it takes it BEFORE
  deciding whether the mode would change, so a no-op `-mode` still
  refuses while somebody is attached - the opposite of this server's own
  "a no-op gfix writes no page" rule; and a write on a read-only database
  gets `isc_read_only_database` in TWO shapes, bare for DML and behind
  `isc_dsql_error` for the DDL the engine refuses at prepare.
  `Database::work_copy` is the floor under all of it - the one funnel
  every write goes through - so a write path added later cannot forget
  the mode. 34 checks in `qa/serve-real-readonly.sh`.

  It also found a bug the other four switches could not reach: **the
  careful flush took its open mode from the image it was about to
  write**, so setting the read-only bit made the file refuse the very
  page that says "read only". The rule is the TRANSITION - a flush that
  CHANGES the bit is the switch and opens read-write - and it is not the
  same rule forced writes has, whose new promise deliberately governs
  the write that turns it on. And **an attach that could not do what its
  DPB asked was answering OK**: the refusal was traced and dropped,
  which made gfix report success (rc=0) for a switch that changed
  nothing.

  What is left of gfix is now only the page-walking and multi-attachment
  half: `-shut`/`-online` (`isc_dpb_shutdown`/`isc_dpb_online`, a mode
  plus a delay, and the attachment refusals that go with them - the
  attachment REGISTRY that `-mode` needed is in place now, which is most
  of what `-shut -attach` asks about), `-sweep` and `-validate` (whole
  page walks - `fcstat census` already does the reading half offline),
  and the limbo-transaction switches, which need two-phase commit first.

## A savepoint is a transaction (done)

This was the named architectural next step, and it is the one that
changes what the server IS rather than what it answers.

**The problem.** Every undo in this server was *put the image back*. It
worked, and for a transaction it was even cheap once snapshots became
refcount bumps - but it has three properties nothing can fix from
outside:

1. the image was taken **before the window's first write**, so another
   attachment committing inside the window is undone by putting it back
   (which is why an open savepoint had to HOLD the write side, and why
   nobody else could write while one was open);
2. it undoes a window by undoing the FILE, so anything that must survive
   the undo has to be carved out of it by hand - which is what the
   generator windows do, and what the autonomous block's `auto_pages`
   do, and each carve-out is a place to get the width wrong;
3. it cannot express *undo part of this transaction*, because one
   transaction id has one state.

**The mechanism, which was already there.** A transaction's rollback had
stopped being an image two days earlier: `tra_dead` in the TIP, two bits, and
every reader walks past a version whose transaction it does not count to
the one behind it. The version behind a savepoint's write **is** the
pre-savepoint value of the row. So an undo window only needs an id of
its own:

- each window that installs its writes as it goes - a `SAVEPOINT`, a
  PSQL body, `INSERT ... SELECT`, an `IN AUTONOMOUS TRANSACTION` block -
  reserves a nested id at its **first record write** (a window that
  writes nothing costs nothing, and a single-statement window never
  reserves one at all: its undo is dropping a working copy);
- undoing the window is `tra_dead` on that id;
- closing it successfully hands the id to the window around it, because
  the rows are the transaction's uncommitted work still;
- COMMIT flips **every** id the transaction holds in one work copy and
  one flush, so no other attachment can read half a commit.

Visibility therefore stopped being one number: `fire_crab_ods::tra::OwnTx`
is the set a reader counts as its own, and an AUTONOMOUS window stops
the walk INCLUSIVELY - which is where the engine's "a block cannot see
the uncommitted rows of the transaction around it" now comes from,
instead of a special case.

**What it lifted.** Both boundaries the autonomous slice recorded: a body
that had already written before the block, and a block inside a block.
Both are ordinary differential checks now, each held by the DIVISION it
turns on - the failed body's own UPDATE goes back, the block's INSERT
stays; the inner block commits, the outer one dies.

**What still needs the image, and why that is right.** DDL. A catalog row
here is settled as it is written - this server's DDL is not
transactional - so no transaction state can take it back.
`Database::ddl_undo` says an undo needs the image; `Database::image_undo`
now says only *hold the write side, because an image may still be put
back*. A savepoint sets the second and not the first: it keeps its base
image as the fallback for a transaction that later does DDL, and pays the
write side for it. Removing that last cost means making the fallback
image safe to take LATE, which is its own question.

**What was found on the way**, all of it by the gates rather than by
reading:

- **A writer must count the transaction's WHOLE set of ids.** A row
  inserted before a mark carries the transaction's id and the mark's
  rows a nested one, so a uniqueness check that consulted only the id it
  was writing under could not see the earlier row - and would accept a
  duplicate primary key. Asserted in both directions now: the key of an
  undone window can come back, the key of a pre-mark row cannot.
- **A statement after the undo must read the VISIBLE version.**
  `SET V = V + 1` after a `ROLLBACK TO` computes from the version behind
  the dead one (6) and not from the dead one (21). It was already right -
  `collect_dml_targets` carries the visible image - but nothing said so
  until this gate did.
- **Two ways to lose a nested id, both caught in the first gate run.**
  Window 0 IS the transaction (its records carry the transaction's own
  id, or every statement burns one), and the ids must live somewhere the
  window stack's reset at COMMIT cannot take with it - the reset ran
  BEFORE the transaction ended, so a committed batch of 200 rows read
  back as 2. Both are the same shape of bug: *an id nobody flips*, and
  its symptom is rows that quietly stop counting.

**Recorded divergence.** A writing window burns a transaction id the
engine does not: the engine's savepoint has no id of its own, so
`hdr_next_transaction` advances further here than there for the same
work. Nothing a client reads through SQL depends on it (fire-crab's
`CURRENT_TRANSACTION` was already "the header's next id + 1" rather than
a transaction-long constant), but `gstat -h` counts differently and that
is worth knowing before it is discovered. It also reaches the end of the
TIP chain sooner - this server cannot GROW that chain, and
`tip_bits_at` answers "transaction id beyond the TIP chain" rather than
writing outside it, so the limit fails closed. On an 8 KB page that is
some 32,000 ids, which no gate approaches; a workload that opens a
savepoint per statement would.

**What it opens.** Snapshot isolation is now the interesting gap rather
than an impossible one: a reader that counts a SET of transactions is one
step from a reader that counts *the set as of a moment*, which is what
`serve-real-autonomous.sh`'s last recorded boundary (the outer
transaction reading what the block committed: engine 0, fire-crab 1) is
waiting on. It also needs the TPB parsed, which nothing does yet.

## How these slices are gated

The existing gates change role. For a conversion slice they are the
deliverable; for these they are the **safety net**: the statement is
"the answers do not move", and the new evidence is that the subsystem is
on the path at all.

So each wiring slice needs a second gate of its own kind:

- a **coverage** check — the subsystem is actually exercised (an index
  scan counter that must be non-zero, a cache hit ratio, a lock
  enqueued), because "wired in but never used" passes every behaviour
  gate;
- and the existing behaviour gates, unchanged, as the floor.

That pairing is the lesson from the increment where eleven gates were
comparing the engine with itself: *a gate that cannot fail is not a
weaker check, it is a source of false confidence*. A wiring slice is
exactly where that failure mode lives.

## Order, and why

R1 first, because the tree is what R4–R7 and W1 all stand on: an index
scan is a row source, a derived table is a row source, and a recursive
CTE is a fixpoint over row sources. Wiring the optimizer into a server
that has no row-source tree would mean building the tree anyway, in the
optimizer's shape, and then again in the planner's.
