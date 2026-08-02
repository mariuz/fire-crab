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

- **`EXECUTE PROCEDURE` on an ENGINE-created FB6 procedure fails "no
  such procedure".** Found by the out-BLR probe pass; fc-created
  procedures work, engine-created ones do not resolve — likely the
  PUBLIC-schema qualifier in the FB6 catalog row. Unclaimed.

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

- **Text LITERALS against numeric columns** — `N BETWEEN '1' AND '3'`
  → 1,2,3; `N IN ('1','2')`; `N = '2'`; `N > '1.5'` (fraction kept);
  `N92 = '0.5'` — engine answers all, fc refuses at prepare; and
  `N = 'x'` raises a conversion error UNLESS a dead group suppresses
  it (`N='x' AND 1=0` → []), the constant-evaluation law now
  implemented. The fix is routing typed_term's Rhs::Str through
  text_number for Int/Numeric columns with per-row error timing —
  unblocked, unclaimed. Param twins already agree.

- **A NON-TEXT parameter against a TEXT column** — `WHERE S_VC = 5`,
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

- **`RETURNING` comes back in a different shape.** Through node-firebird
  the engine answers an `INSERT ... RETURNING` as a single object and
  fire-crab as an array of one. The values agree; the statement's
  announced *type* apparently does not. Noticed while diffing 495
  conversions and set aside, not chased.

- ~~An IN-SUBQUERY refuses past ~10-100 inner rows~~ — *fixed*. It was
  exactly 64/65 DISTINCT values, and the cause was one constant doing
  two jobs: the DNF cap bounds the AND cross-product (multiplicative,
  must stay small) and was also bounding OR growth (additive, one group
  per value). Separate bounds now.

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
      token text to that call.
    - the JOIN's inner side.
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
