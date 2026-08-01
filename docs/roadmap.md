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
  was one the parser already built. One `else` branch, nothing downstream
  changed. `WHERE ? IS NULL`, `WHERE ? LIKE 'o%'`, `WHERE ? BETWEEN 1 AND 3`
  and `WHERE ? IN (1,2)` are *different shapes* the engine also answers
  and this parser covers none of — still refused, deliberately, rather
  than mis-read as `TRUE = ?` with tokens left over.

- ~~A text parameter into a numeric column or filter~~ — *fixed*. It was
  the largest single hole in the parameter surface (82 of 119 measured
  disagreements). See `qa/serve-real-textnum.sh`; the store side and the
  filter side turned out to have different rules, and the filter
  comparison is exact rather than through a double.

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

- **fire-crab refuses to WRITE a row that would fragment.** A cross-page
  store it does not implement. `qa/serve-real-fragment.sh` asserts the
  refusal so it cannot quietly become a half-written row.

- **`STARTING WITH` is not in the predicate parser.** Noticed while
  building the fragment gate; the engine answers it. Unrelated to
  fragments, small, and unclaimed.

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

- **`name` and `alias` are two describe fields, and fire-crab sets both
  to the alias.** For `SELECT X + 1 AS Y` the engine answers `name: ADD
  alias: Y`; for `UPPER('a') AS U`, `name: UPPER alias: U`; for a plain
  `X AS Z`, `name: X alias: Z`. fire-crab answers the alias in both, for
  every aliased column. Invisible to a client that reads `alias` (which
  node-firebird does) and visible in isql. Projection-wide, so it needs
  `ProjCol` to carry both names and the describe writer to emit them
  separately — its own slice, not a patch.

- **A generator inside an EXPRESSION.** `SELECT (NEXT VALUE FOR S) + 100`
  and `(NEXT VALUE FOR S) || 'x'` are answered by the engine and refused
  by fire-crab, whose select-list parser recognises a generator only as a
  WHOLE item. `qa/serve-real-genrow.sh` asserts the refusal.

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
    - `eval_subquery` / `build_correlated_lookup` — a subquery's own
      retrieval.
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
