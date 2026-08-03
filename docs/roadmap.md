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
| **converted, NOT wired** | `lck`, `evt` | a real conversion of a real law, with a gate — that the server never calls |
| **being wired** | `opt`, `cch`, `pio` | the server asks `opt` for the access path and takes an index when it says so (W1); it flushes through `cch`'s careful write order (W2), and writes those pages with `pio`, in the open mode the header's Forced Writes flag calls for (W3) |

That third row was the honest headline, and W1 has begun on it.
`crates/wire/Cargo.toml` still does not depend on `-lck` or `-evt`. It DOES depend on `fire-crab-opt` now, and the optimizer's
choice is executed rather than merely printed — for the one shape W1
covers so far. The lock manager
decodes a lock table it never enqueues into. The page cache models a
careful-write graph the read path does not go through.

And inside the SQL layer there is a second structural gap: the server
answers views, CTEs and constant subqueries by **rewriting SQL text and
re-planning it**, where the engine builds a tree of record sources. That
approach has worked far better than it has any right to — but it is why
a CTE body that GROUPs refused, why `FROM (SELECT ...)` did not exist,
why `WITH RECURSIVE` could not work, and why a qualifier-stripping pass
had to be taught not to reach inside a subquery. R1–R6 have closed all
four; R7 is the removal of what they replaced.

## Measured gaps that are nobody's slice yet

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
  spelling raise, so fc sides with the strict grammar and the gate
  excludes the index-dependent spellings), e-notation goes through
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

  *Found while fixing, recorded not fixed*: a VIEW inside a nested
  query expression answered `[]` at HEAD — **unqualified too**, where
  the engine answers every row, because a subquery never expanded one,
  it just scanned the view's empty storage. It REFUSES now (the same
  fail-closed guard), which trades a wrong answer for a boundary;
  expanding it needs the subquery evaluator to accept a planned row
  source the way `plan_over_source` does, which is its own slice.

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

- **The generator-durability class stays recorded** — the engine treats
  generators as non-transactional: an advance survives ROLLBACK,
  ROLLBACK TO SAVEPOINT, a PSQL `WHEN ANY` undo, statement undo, and a
  statement that FAILED (a PK-violating identity INSERT moves GEN_ID
  2→3 *before* raising 335544665), and `ALTER SEQUENCE ... RESTART
  WITH n` / `SET GENERATOR ... TO n` survive a rollback verbatim — the
  post-image wins, not the maximum. fire-crab's only undo is the
  whole-image snapshot in `restore_db`, so every advance inside the
  undone window retreats with the file. Matching it needs two
  deliberate carve-outs fire-crab does not have — carrying the
  generator vector FORWARD across a restore, and writing a drawn value
  forward out of a failed statement's discarded work buffer — in a
  design whose whole isolation story is "the image is the truth", and
  they interact with DDL rollback. Its own slice, with its own gate;
  the reasoning is pinned at `restore_db`. Unclaimed. **Re-measured,
  and it is worse than "recorded": the divergence is READABLE. After
  an identity INSERT that fails the PK check identically on both
  sides, `SELECT GEN_ID(G1,0)` answers 0 here and 12 on the engine —
  a wrong ANSWER to an ordinary SELECT, not merely a durability
  footnote. (And a PSQL `WHEN ANY` block that draws then divides by
  zero answers `X = 5` on the engine, leaving the generator at 5,
  where fire-crab refuses the whole block.) It should be priced as a
  wrong answer when the queue is next ordered.**

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

- **A text→number conversion longer than 52 characters raises the wrong
  CLASS** — measured beside the escaping matrix: at 53 source
  characters the engine stops with 22001 (`string right truncation -
  expected length 52, actual 53`) BEFORE its conversion error can be
  built, while fire-crab has no cap and raises 22018 carrying the whole
  string. The boundary is exact (52 agrees byte for byte, 53 diverges)
  and it is CAST-specific — the comparison vector has no cap on either
  side. Both sides fail, so no wrong write. Unclaimed.

- **`CAST('<TAB>2' AS INTEGER)` answers 2 where the engine raises**
  — found beside the escaping slice: the cast/literal grammar trims
  Rust's whitespace class (TAB, LF, VT, FF, CR), the engine's skips
  only 0x20, so every control byte the WHERE-literal path correctly
  refuses converts silently through a CAST. A wrong ANSWER, not a
  message. (The same probe found the parameter-bind path answering a
  bare `Dynamic SQL Error` where the engine raises 22018 with the
  escaped argument — `SELECT ... WHERE N = ?` bound `'<TAB>2'`.)
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
  - Scope so far: a single-segment integer index at scale 0, on the
    projection's retrieval — equality and RANGES (`>`, `>=`, `<`, `<=`,
    `BETWEEN`), including descending indexes (their keys are
    complemented, so the bounds swap) and multiple bounds on one column
    (a conjunction narrows), and DESCENDING indexes are NOT keyed - two
    measured misses (equality on a descending integer index, and
    equality on a descending text index holding a value that extends
    the searched one) say the complement's arithmetic has not been
    established. Both the PROJECTION's retrieval and the
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
      inner sides the engine INDEXES and this probe declines — a
      DESCENDING index, `NUMERIC(9,2)`, `NUMERIC(38,0)`, a VIEW inner
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
  - **Compound prefixes and text keys** *(done)*: an equality on an
    ascending compound index's LEADING segment is a band whose upper
    bound is the prefix's EXCLUSIVE SUCCESSOR (an inclusive one drops
    every row with a non-NULL trailing segment), and text equality is
    keyed for ASCII literals on `idx_string` and `idx_metadata`.
  - **A named, measured write-path divergence at `i64::MIN`.**
    `btw::int64_key` builds a key for `-9223372036854775808` that is not
    the one the engine wrote: the engine's `make_int64_key` NEGATES the
    value before choosing a scale, and negating `i64::MIN` overflows, so
    its choice differs from the arithmetically correct one. Retrieval
    now SCANS for that value, which restores the right answers; the
    WRITE path still stores our key, so a row fire-crab inserts with a
    BIGINT of exactly `i64::MIN` carries an index entry the engine's own
    lookups may not find. Closing it means reading the engine's actual
    key bytes for that value, which is a probe of its own.
    **Re-measured: the stated hazard is UNREACHABLE, because a prior
    refusal blocks the write.** `INSERT INTO BM VALUES
    (-9223372036854775808,…)`, the `CAST('…' AS BIGINT)` spelling and a
    string-bound parameter all get a Dynamic SQL Error here where the
    engine writes the row — the literal parse overflows on the unsigned
    half before the key is ever built. Retrieval is fine (after isql
    wrote the row into fire-crab's own file, fire-crab found it). So
    what is actually open is SMALLER and different from what the entry
    says: fire-crab refuses a value the engine accepts. Fix the literal
    parse and the write-key divergence becomes live again — do both in
    one slice, or neither.
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
- **W2 — the page cache.** *(the write order done)* The server's DML
  flush writes PAGES in `cch`'s precedence order and syncs each before
  the page that references it, instead of dumping the whole file — so
  every prefix of the write sequence is a database the engine can open,
  which is exactly what `qa/cch-crash-harness.sh` had been checking
  about a model nothing called. `crates/wire` depends on
  `fire-crab-cch` now. Measured: five pages per statement instead of the
  whole file, and no speed change (the per-page sync cancels the smaller
  write) — this buys crash behaviour, not throughput. Still to do: a
  file that GROWS is written whole (extending is its own careful-write
  question), and the READ path still slices the image directly rather
  than fetching through buffers.
- **W3 — platform I/O.** *(the write path done)* The careful flush
  writes its pages through `fire-crab-pio`, opened with
  `plan_for_header(<the header's flags>)`. That fixed a rule the flush
  had got wrong on its own: **Forced Writes is an OPEN MODE, not an
  fsync per write** — the engine adds SYNC to the open mode when the
  header says so and does nothing per write when it does not, while the
  flush had been syncing every page unconditionally. Measured: 38.4s
  with it on against 38.3s off, so the sync was never the cost. Still to
  do: the READ path (the server still slices the image directly).
- **W4 — the lock manager participating** (`lck`): enqueue, dequeue,
  AST callbacks. This is what makes concurrent attachments correct
  rather than accidentally correct.
- **W5 — event delivery** (`evt`): the shared-memory arena, the watcher,
  and the wire path.
- **W6 — depth in `exe` and `svc`**: the request lifecycle, cursors and
  exceptions; then gbak/gfix/nbackup as services.

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
