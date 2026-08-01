# Changelog

fire-crab has no version numbers yet — the unit of progress is the
**increment**: one converted piece with its differential gate against the
live C++ engine, one commit each. This file groups those increments by
day and theme, newest first. The full per-increment record is the git
history (each commit message carries the differential's numbers); the
deep narrative lives in [docs/qa-and-benchmarks.md](docs/qa-and-benchmarks.md)
and [docs/methodology.md](docs/methodology.md).

Format inspired by [Keep a Changelog](https://keepachangelog.com/); the
categories are the project's own: **Converted** (a new engine behavior,
differential-gated), **Fixed** (a divergence from the engine, and how it
was caught), **Guarded** (a wrong-answer path closed by refusal).

## 2026-08-01 — The grid had a hole in it

Four edits to `opt`'s join cost model, shipped as one increment because
each of them alone regresses a measured fixture — which is exactly why
four independent investigations of this had contradicted each other, each
having isolated one term and validated it on its own row counts.

### Fixed
- **`loop_cost` charged the row term twice.** The engine charges two
  terms and they are *not the same quantity*: `Retrieval.cpp:385` is
  `DEFAULT_INDEX_COST + selectivity * scratch.cardinality`, an index
  **page** count, and `Retrieval.cpp:1145` adds `cardinality *
  selectivity` against the **table's**. Reading both as the table's
  doubled a keyed loop's price and pushed the HASH/loop crossover out by
  a factor of two. The page term is dropped rather than converted — for a
  4-byte key at 8 KB pages it is `card/1359`, a coefficient of 1.0007
  against 1.0, and converting it needs `irtd_itype` plumbing `ods` does
  not have. That is in the roadmap, with the arithmetic.

- **The driver was free.** `InnerJoin.cpp:323` seeds `findBestOrder(0,
  ..., 0.0, 1.0)`, which *looks* like a zero — but `:377` calls
  `estimateCost(position = 0, ...)` under no guard and `:192` charges
  `loopCost = candidate->cost * cardinality` with `cardinality == 1.0`,
  and a bare natural scan's candidate cost is the stream's own row count.
  Comparing inner-side costs only cancels the driver's price: harmless
  when the sides are similar, wrong when they differ hundredfold — which
  is the shape a keyed join exists for.

- **Only one hash arrangement was priced.** fcopt costed "larger drives,
  smaller hashed" and nothing else. The engine reaches both through its
  two starting streams (`InnerJoin.cpp:318-323`), pricing the stream at
  `position` as the hashed one against the priors probing. `formRiver`'s
  swap (`:575-581`) is **post-decision** — it sits behind
  `equiMatches.hasData()`, which `:269-270` fills only after `hashCost <=
  loopCost` has already passed — so it renormalises the printed sides
  rather than restricting what gets costed.

- **A unique hashed side was over-charged.** `InnerJoin.cpp:210-211`
  caps `currentCardinality` at `MINIMUM_CARDINALITY` when the candidate
  is unique, so a unique hashed side contributes one row per probe
  however large the table is. Without it, hashing a large unique inner
  looked enormously expensive and fcopt preferred a loop where the engine
  hashes.

### The gate is the finding
`qa/opt-plans.sh`'s cost grid ran over table sizes `{0, 1, 5, 50, 500,
3000}` — and **that set has a hole from 5 to 50 that straddles the
engine's crossover**. A model can score 36/36 on it while being wrong at
every cardinality in between, and one did: against a widened set of
thirteen sizes `{0, 1, 2, 5, 8, 20, 30, 50, 120, 500, 900, 3000, 5000}`,
169 cells, the model this increment replaces scores **153/169 — and all
sixteen of its errors are in the 2-120 band the narrow set skipped**.

After the four edits: **169/169, zero refusals.** The grid in the gate is
now the widened one, in both its fresh and stale phases.

A grid that cannot fail is not a grid. Two claims about this cost model
were previously asserted twice and refuted twice, both times because the
evidence was a full score on a set too narrow to disagree.

### Not done, deliberately
- **The `DEFAULT_SELECTIVITY = 0.1` substitution is NOT in this
  increment**, though it is read, understood and quoted
  (`Retrieval.cpp:1019-1026`: a **value** test `selectivity <= 0`, per
  matched segment, and for the leading segment the `minSelectivity` floor
  is provably inert so the answer is exactly 0.1). Adding it to
  `index_selectivity` would make the stale-statistics guard *unreachable*
  as a side effect — which is the very step that was asserted twice and
  refuted twice. It goes in with the guard's removal, judged against the
  widened stale grid, as its own increment.

  That grid now exists as ground truth: on the 169 stale cells the engine
  answers every one, and fcopt today answers 4 and **refuses 165, with
  zero wrong**. The guard is load-bearing and measurably so.

- **None of this changes an executed plan.** A fleet established the
  mechanism by reading the code: `server.rs` discards any plan that is
  not a one-element `Access::Index | Access::Order` stream,
  `plan_join_bound` pushes a `TableScan` for every base side without
  calling `choose_index`, and there is no hash-join row source. This is
  plan-text fidelity — the crate's stated purpose, and a prerequisite for
  the keyed join — and the commit says so rather than implying otherwise.

## 2026-08-01 — Two ways of being slow, both measured

A fleet sent to settle three recorded gaps in `opt`'s cost model came
back having reordered its own list. Its relevance lens — an agent whose
only job was to ask "grant this finding is true; does it change any plan
fire-crab would execute differently?" — answered *no* for all three, and
then found something none of the four investigations had been looking
for. Both items below are live and user-visible; the cost-model work is
plan-text fidelity only, and is now scheduled behind them.

### Fixed
- **Taking the index cost more than ignoring it.** `records_at_in` built
  the relation's whole `sequence -> page` map — a walk of the file and a
  decode of every data page — and `records_for` called it with a
  **one-element slice per accepted record**. O(rows × pages), paid inside
  the loop. Measured on a 200,000-row / 26 MB database, the same
  statement with the index path against `FC_NO_INDEX=1`:

  | rows returned | index | scan |
  |---|---|---|
  | 99 | 100 ms | 157 ms |
  | 499 | 184 ms | 185 ms |
  | 999 | 283 ms | 149 ms |
  | 4999 | **1132 ms** | 152 ms |

  fire-crab was executing the retrieval it and the engine both chose and
  paying **7.4× the cost of ignoring it**. After hoisting the map to once
  per retrieval — the shape `dml_targets_at` already used — and replacing
  `records_for`'s linearly-scanned `Vec` dedup with a `HashSet`: 4999
  rows in **111 ms against 166 ms**, the index now faster at every size.
  A slower plan, never a wrong answer, and all three index gates stay at
  zero DIFFs.

- **Nagle was never turned off.** `grep set_nodelay crates/` returned
  nothing. The wire protocol is strictly request/response and a response
  is written in several pieces, so the kernel held each response tail
  waiting to coalesce while the client — with nothing to send until it
  had the whole answer — held its ACK under delayed-ACK. Neither side
  blocked on anything either could see; both waited on a timer. Measured:
  **200 sequential `SELECT 1 FROM RDB$DATABASE` took 17,092 ms through
  fire-crab against 293 ms through the real engine.** The engine sets
  `TCP_NODELAY` (`remote/inet.cpp:1039`); so does this now.

### Corrected
- **An earlier conclusion of this project's was right for the wrong
  reason.** "600 inserts in 38.4s with Forced Writes on vs 38.3s off —
  the sync was never the cost" still holds, but both numbers were
  dominated by ~85 ms per statement of delayed-ACK, not by the work
  either measurement was about. Every end-to-end timing this project has
  ever taken had that floor under it.

### Measured, not fixed
- **A second per-statement stall remains, and it is not the socket.**
  After `TCP_NODELAY` the same 200 statements take 8,689 ms — still 37×
  the engine. About 3.8 s of that is server CPU and the rest is waiting;
  forcing the *client* socket to `noDelay` changes nothing, and the cost
  barely scales with database size (2.3 MB → 8.9 s, 25 MB → 11.1 s), so
  it is a fixed ~44 ms per statement of something else. Named here rather
  than left as a good number.

New `qa/serve-real-idxcost.sh` (5 checks). It builds its own 200,000-row
database, because every existing gate runs on ~2.5 MB fixtures where this
pathology is invisible — they would have stayed green through all of it.
It asserts a **ratio** rather than a millisecond budget, so a loaded
machine cannot make it flaky; the defect it exists to catch was 7.4× and
the bound is 1.5×. And it uses the same three-way oracle as the rest of
the index work: the binary with the feature on, **the same binary** with
`FC_NO_INDEX=1`, and the real engine — so a row-set difference is the
index path's fault by construction, and here the comparison is a time as
well as a row set.

381 unit tests, 91 plan checks.

## 2026-08-01 — The batching swallowed the generators

A full sweep of all 191 gates — run to check the character-set work —
turned up one failure that predated it. `qa/serve-real-genrow.sh` had
been failing on seven of its eight checks, and a worktree build of HEAD
confirmed it: not a regression from that day's work, a regression from
the fetch-batching increment before it.

### Fixed
- **`NEXT VALUE FOR` in a select list answered NULL and advanced
  nothing.** When `op_fetch` began materialising every cursor through
  `branch_rows` — to bound the batch, which a 2300-row deadlock required
  — `branch_rows`'s `Plan::Project` arm destructured with `..` and
  dropped `gen_cols` on the floor. The streaming path that did the
  advance was simply never reached again.

  What made it hide: the special case for `SELECT NEXT VALUE FOR <seq>
  FROM RDB$DATABASE` has its own code path and went on working
  perfectly, so the feature looked alive from the outside.

  The advance now lives in one function, `advance_generators`, called
  from both paths. It previously existed as one copy and one omission,
  which is exactly the shape that broke. The two callers write into
  different coordinate systems — the streaming path into a decoded
  record at the synthetic `value_index`, the materialising path into an
  already-projected row at the column's output position — so the slot is
  a parameter, and that is the whole reason the function takes one.

- **The advance was persisted by a code path the fetch no longer
  reaches.** The batch path returns to the client before the single
  persistence site at the bottom of the handler, so even a correct
  advance would not have survived. `persist_generators` is now called
  from both, and writes the whole set atomically — a statement that
  advanced two sequences never persists one of them.

- **Both generator spellings were announced wrongly.** Probed with `SET
  SQLDA_DISPLAY ON`: `NEXT VALUE FOR S` describes as **NEXT_VALUE**,
  sqltype 580; `GEN_ID(S, 1)` describes as **GEN_ID**, sqltype 581 — the
  nullable form. fire-crab said GEN_ID/581 for both. A generator can
  never yield NULL either way; the engine simply announces the two
  differently, and the announcement is what a client builds its message
  from.

`qa/serve-real-genrow.sh` grows 8 → 14 checks. The new ones are the two
halves the old fixture could not reach: a **2500-row** generator SELECT,
past the ~2300 where a fetch must be split, which pins that the advance
happens at materialisation and happens ONCE rather than once per batch;
and a direct comparison of the **declared column**, which every existing
check was blind to because they compare values positionally and a wrong
name is invisible to them.

### Stated rather than hidden
- **A generator inside an EXPRESSION is still refused.** The engine
  answers `SELECT (NEXT VALUE FOR S) + 100` and `(NEXT VALUE FOR S) ||
  'x'`; fire-crab's select-list parser recognises the generator only as a
  whole item. An outage, not a wrong answer, and the gate asserts the
  refusal so it cannot quietly become one.

- **`name` and `alias` are two fields and fire-crab sets both to the
  alias.** Found while probing the above, and it is not
  generator-specific: for `SELECT X + 1 AS Y` the engine answers `name:
  ADD alias: Y`, for `UPPER('a') AS U` it answers `name: UPPER alias: U`,
  and for a plain `X AS Z` it answers `name: X alias: Z`. fire-crab
  answers the alias in both fields, for every aliased column. That is a
  projection-wide slice of its own; it is in the roadmap.

381 unit tests, 91 plan checks, 14 generator checks.

## 2026-08-01 — A CHAR(5) was twenty characters wide

A database created `DEFAULT CHARACTER SET UTF8` — the ordinary case —
stores a `CHAR(5)` in twenty bytes. fire-crab read only the byte half of
a text descriptor, and the comment where that assumption lived said so
out loud: *"byte length == character length here: charset NONE."* It was
true of every fixture and false of every real database.

### Fixed
- **A `CHAR` came back padded to its BYTE length.** `SELECT C5` returned
  twenty characters where the engine returns five — `'abc'` as `"abc"`
  plus seventeen blanks — and `OCTET_LENGTH` and `CHAR_LENGTH` answered
  `20`/`20` against the engine's `5`/`5`. On rows the **engine** had
  written. Every `CHAR` value in a UTF8 database was wrong on the wire.

- **The describe announced charset 0 for every text column.** The
  on-disk `sub_type` *is* the ttype — the character set in the low byte,
  the collation in the high one, probed: `CHAR(5) CHARACTER SET UTF8
  COLLATE UNICODE_CI` reads `772 = 0x0304`. Announcing zero told every
  client the column was `CHARACTER SET NONE`; node-firebird then widened
  the declared length four-fold, its own compensation for exactly that
  claim, and the value arrived at twenty characters.

- **An over-long text parameter was stored, and the engine could not
  read the row back.** Eleven characters fit in a `VARCHAR(10)`'s forty
  bytes, so the byte check passed. The engine refuses that parameter —
  *string right truncation, expected length 10, actual 11* — and when
  fire-crab wrote the row anyway, `SELECT` through the engine's own isql
  failed on the way **out**. A row the reference implementation cannot
  read is worse than any missing feature; the declared **character**
  width is now the first bound, with the byte bound kept behind it.

New `crates/ods/src/intl.rs` holds the character-set half of a
descriptor: the ttype split, the bytes-per-character table, the declared
character length, and the `CHAR` fit. The table is a claim about the
engine, so `qa/serve-real-charset.sh` checks it against
`RDB$CHARACTER_SETS` row by row — all 52 — before it checks anything
else, then compares reads, writes and accept/refuse across four sets
chosen for their widths (UTF8 4, UNICODE_FSS 3, WIN1252 and NONE 1), and
finishes by opening fire-crab's own database with the engine's isql and
with `gfix -v -full`.

### Guarded
- **The engine's silent 4× truncation is deliberately not copied.** A
  text value of exactly four times the declared character length is
  accepted and quietly cut down — `CHAR(5)` ← 20 characters stores
  `"abcde"`, reproducible at every width and independent of content. It
  is an engine buffer-sizing bug, and reproducing it would mean silently
  storing a value nobody asked for. fire-crab refuses, and the gate
  **asserts the divergence** rather than leaving it unsaid.

### Converted
- **A bare `?` as a whole predicate.** `WHERE ?`, `WHERE ? AND ID > 1`,
  `WHERE NOT (? OR ?)`. The engine describes it as `SQL_BOOLEAN` and
  answers it as ordinary three-valued logic, so it is exactly `TRUE = ?`
  with the `TRUE =` elided — a leaf the parser already built, with its
  describe, bind and NULL-is-UNKNOWN behaviour already probed. One
  `else` branch; nothing downstream needed to learn anything.
  `WHERE ? IS NULL`, `WHERE ? LIKE 'o%'`, `WHERE ? BETWEEN 1 AND 3` and
  `WHERE ? IN (1,2)` are different shapes the engine also answers and
  this parser covers none of — they keep refusing rather than being
  mis-read.

- **A number written as text, into every numeric column and every
  numeric filter.** The largest single hole in the parameter surface.
  Probed exhaustively — 54 spellings × 9 column types — and three of the
  rules are not what a hand-written parser would do:

  * `'1.999999'` goes into an `INTEGER` as 2 and is **refused** by a
    `SMALLINT`. The rounded result fits both; the *mantissa* (1999999) is
    range-checked before the rescale, and only the SMALLINT is too narrow
    for it. Same string, same rounded result, different answer per column.
  * a hex string is sized by its **digit count**, not its value.
    `'0x0000000000000001'` is one, and an `INTEGER` refuses it because
    sixteen digits is a BIGINT-shaped literal. The digits are then read
    as a **signed** integer at the *target's* width, so `'0xFFFF'` is −1
    in a SMALLINT and 65535 in an INTEGER.
  * the store side and the filter side **disagree with each other**.
    `'1.999999'` into a SMALLINT column is a conversion error, but
    `WHERE N_SM = ?` with the same string returns *no rows* — a filter
    asks a question, and "none" is an answer. And hex, which the store
    side takes, is a conversion error on the filter side.

  The filter comparison is **exact, not through a double**: the two
  BIGINTs `9223372036854775806` and `…807` are one single `f64`, and the
  engine picks a different row for each of those strings.

  Also reaching the filter side: text → `BOOLEAN` by the engine's name
  match (`'true'`, `'FALSE'`, `' True '`; `'t'` and `'1'` are errors),
  and text → `FLOAT`/`DOUBLE`.

### Stated rather than hidden
- **The engine's string→double is not correctly rounded.** It answers
  `100000000000000020` for `'99999999999999999'` where the nearest double
  is `100000000000000000` — one ulp high, and again for twenty nines.
  fire-crab is correctly rounded and therefore *more* accurate; copying a
  one-ulp error to match would make it less so. `qa/serve-real-textnum.sh`
  splits the check in two: twin agreement up to sixteen significant
  digits (the measured boundary — seventeen digits of `'12345678901234567'`
  agree, seventeen *nines* do not), and beyond it fire-crab is measured
  against the true nearest double instead of against the engine.

- **A non-text parameter against a TEXT column still refuses.** The
  engine does not render the value as text — it coerces the **column** to
  a number, per row: `WHERE S_VC = 5` matches `'5'`, `' 5'`, `'5.0'` and
  `'05'` alike, and *raises mid-scan* if any row holds a non-numeric
  string (adding one `'TRUE'` row makes the whole statement fail). That
  is a comparison rule rather than a conversion, it is in the roadmap,
  and the gate asserts the refusal so it cannot quietly become a wrong
  answer.

- **Transliteration is not implemented.** The engine converts a WIN1252
  column's bytes into the connection's character set on the way out;
  fire-crab passes the stored bytes through. Identical for ASCII content
  — which is what every fixture uses — and not for a high byte. It is a
  codepage-table job and `crates/ods/src/intl.rs` says so rather than
  pretending otherwise.

Two stale unit-test assertions were corrected rather than worked around:
both encoded fire-crab's *refusal* of a text parameter into a numeric
column as if it were the engine's behaviour. It never was.

381 unit tests, 91 plan checks, and two new behaviour gates —
`qa/serve-real-charset.sh` (18) and `qa/serve-real-textnum.sh` (6 over
~650 cases). `qa/gate-selfcheck.sh` caught a defect in the first of them
before any of this was committed: its second server start had no
liveness assertion, so a lost port would have produced a green run that
measured nothing.

## 2026-08-01 — The optimizer was reading the wrong selectivity

A fleet sent to teach `opt` to key an indexed inner join reported, first,
that it **already does** once statistics are fresh — correcting a premise
an earlier fleet had left me with and I had repeated. Then it found what
is actually wrong.

### Fixed
- **`index_selectivity` returned the WHOLE-INDEX figure where the engine
  uses the MATCHED SEGMENT's.** `RDB$INDICES.RDB$STATISTICS` is the
  statistic for the whole key; the engine costs a retrieval with
  `idx_rpt[j].idx_selectivity`, the figure for the segments the predicate
  actually matched. On `INDEX (K, B)` over 5000 rows with 10 distinct K
  those are **0.0002 and 0.1 — five hundred times apart**.

  It produced a plan the engine does not choose, today, with no
  contrivance:

  ```
  SELECT O.ID, I.ID FROM OUTR O JOIN INNR I ON I.K = O.K
  engine:  PLAN HASH ("I" NATURAL, "O" NATURAL)
  fcopt:   PLAN JOIN ("O" NATURAL, "I" INDEX (INNR_KB))
  ```

  A predicate is only ever matched against an index's leading segment
  here, so segment 0's figure is the one to read;
  `RDB$INDEX_SEGMENTS.RDB$STATISTICS` holds it per position, and the
  whole-index column stays as the fallback for an index whose segments
  carry nothing.

`qa/opt-plans.sh` grows to 91 checks with a fixture nothing else in it
had: 5000 rows and a **skewed** leading column, which is the only shape
that can tell the two readings apart. Four of them are the join plans
either side of the crossover.

### Also fixed: my own gate
`serve-real-carefulflush.sh` named `$srv2` in a trap it could reach
before the variable existed — under `set -u` that is a gate failing for
its own reasons. And a stray server from an interrupted run held the
port the async check needed, which the liveness assertion correctly
refused to measure around.

372 unit tests, 91 plan checks, 8 behaviour gates.

## 2026-08-01 — One cap was doing two jobs

`SELECT ... WHERE ID IN (SELECT ...)` refused as soon as the subquery
returned **65 distinct values**, on a statement the engine answers. A
fleet bisected it to exactly 64/65 and named the cause: not the
subquery, and not its desugaring into a literal list — the DNF group cap.

### Fixed
- **`DNF_MAX_GROUPS = 64` was bounding two different quantities.**
  `cross_dnf` is MULTIPLICATIVE — `(a OR b) AND (c OR d)` is a product,
  and a chain of them squares and cubes, so 64 is where that must stop.
  `concat_dnf` is ADDITIVE: `x IN (v1..vn)` grows by ONE per value, and
  65 values is an ordinary list rather than an explosion. They have
  separate bounds now, 64 and 4096.
- **The product is checked BEFORE it is built.** With a larger additive
  cap a branch can be thousands of groups wide, and multiplying first to
  refuse afterwards would allocate exactly the explosion the cap exists
  to prevent.

A 4000-value `IN` subquery answers in 0.15s — the union-of-bands
retrieval takes it in its stride. Whether it drives an index is `opt`'s
call, and `opt` refuses parenthesised predicates, so a literal `IN` list
scans; the gate asserts the answer rather than the path.

`qa/serve-real-index.sh` is 359 checks. 372 unit tests and 10 gates.

## 2026-08-01 — W3: platform I/O, and a rule my flush had got wrong

### Converted
- **The careful flush writes through `fire-crab-pio`.**
  `crates/wire` depends on it now, leaving `-lck` and `-evt` as the only
  subsystems the server never calls.

### Fixed by wiring it
- **Forced Writes is an OPEN MODE, not an fsync per write.** My flush
  synced every page unconditionally, which is *stricter* than the engine:
  `PIO_open` adds SYNC to the open mode when the header's Forced Writes
  flag is set, and does nothing per write when it is not. `pio` has held
  that rule — with the offset arithmetic and the retry count — since it
  was converted, with nothing calling it. The flush now opens with
  `plan_for_header(<the header's flags>)` and flushes at the end only
  when Forced Writes is off, which is what the engine leaves to the
  operating system.

### Measured
600 inserts in 38.4s with Forced Writes on and 38.3s with it off — the
sync was never the cost. The whole-file copy each statement makes is,
and that is a different slice. Recording it because the obvious
expectation (a per-page fsync is expensive) turned out not to be where
the time goes.

`qa/serve-real-carefulflush.sh` grows to 21 checks: the trace names which
open mode each flush ran in, a copy of the database has Forced Writes
turned off with `gfix -write async` and is written again, and `gfix`
validates both files. 372 unit tests and 11 gates.

## 2026-08-01 — Four conversions the engine makes and fire-crab refused

A fleet probing around the boolean parameter found four statements the
engine accepts and fire-crab rejected. Refusing what the engine takes is
the outage direction, so each was probed against the engine for the value
it STORES, not just for acceptance.

### Fixed
| parameter | column | the engine stores |
|---|---|---|
| `'true'` / `'FALSE'` / `' True '` | BOOLEAN | TRUE / FALSE — a NAME match, case-insensitive, blanks ignored |
| `'t'`, `'1'`, `'yes'`, `''` | BOOLEAN | **refused** — it is not a truthiness test |
| a boolean | VARCHAR / CHAR | `'1'` or `'0'`, not the word |
| an integer | VARCHAR / CHAR | its decimal digits, and **refused** rather than truncated when too long |

- `CAST(<boolean> AS VARCHAR)` renders **`TRUE`**, in capitals, while
  isql DISPLAYS the same column as `<true>`. Two renderings of one value,
  and only the cast's is a value the SQL surface can be asked about — so
  `Value::render`, which the dumpers share, keeps the lower-case form and
  the cast overrides it.

### Still refused, and now recorded rather than assumed
A bare boolean parameter as a whole predicate — `SELECT ... WHERE ?` —
which the engine answers. That is the predicate parser rather than a
conversion, and it is in the roadmap.

### A second gate with the same expired premise
`qa/serve-real-boolean.sh` also asserted "a boolean PARAMETER is refused
by both — this driver cannot encode one". Same driver update, same
expiry. It now asserts that the two servers AGREE, which is what it was
always for, and carries the seven conversions above.

372 unit tests and 11 gates.

## 2026-08-01 — A SELECT returning 2400 rows hung forever

Not a roadmap item. A fleet sent to design the index-driven join
measured the current one first, and reported that it could not: the
server stopped answering above about 2300 rows.

### Fixed
- **The fetch ignored the client's row count and answered every
  `op_fetch` with the WHOLE result.** Below ~2300 rows that is invisible —
  it all fits in the socket. Above it the server's write BLOCKS; the
  client, having read the batch it asked for, stops reading to send its
  next `op_fetch`; and neither side ever moves again.
- **A batch also has to be TERMINATED**, which is why bounding it alone
  was not enough — the first fix made *every* size hang. The client's
  decode loop runs while `count && status != 100`, so it needs one of the
  two to stop reading:

  | | |
  |---|---|
  | end of BATCH, rows still to come | `count = 0`, ordinary status |
  | end of CURSOR | `status = 100` |

- The cursor is materialised once and drained in batches. `Plan::Rows`
  was already "a materialised cursor, consumed by its fetch"; that is the
  general rule now rather than a special case.

### Two mistakes made fixing it, both caught by gates
- Materialised rows come back ALREADY PROJECTED, so their columns must
  be re-indexed positionally. Keeping the original field ids made every
  column read a record it no longer had, and **every value came back
  NULL** — eight gates said so at once.
- Materialising ran the retrieval *before* a parameterised statement's
  bands were built, so `WHERE ID = ?` quietly went back to scanning. The
  answers stayed right and only the coverage assertion noticed, which is
  exactly what it is for.

New `qa/serve-real-fetchbatch.sh` (17 checks) over a 6000-row fixture:
every shape that materialises differently, the rows either side of the
old cliff, and exact multiples of the batch size. It compares **digests**
— the first version pasted 6000 rows into a shell variable and reported
DIFFs that were its own truncation.

372 unit tests and 20 gates confirm nothing moved.

## 2026-08-01 — A gate's premise expired, and I reported it as a defect

`qa/serve-real-params.sh` asserted that a boolean PARAMETER is refused,
"as the engine refuses this driver's encoding". I found it failing, saw
fire-crab accepting where the gate expected a refusal, and recorded a
defect: *fire-crab accepts what the engine rejects*.

**That was inferred from the gate, not from the engine.** Asked directly,
the engine accepts it too, and the two databases come out byte-identical
— node-firebird 2.14.1 made boolean encoding metadata-directed, so a
BOOLEAN target now receives a real `blr_bool`. The premise was true when
it was written and had expired since.

Four failures, every one of them pointing at fire-crab, and none of them
fire-crab's. The gate now asks the engine rather than remembering what it
once answered, and its literal mirror script carries the row the
parameterised statement writes.

## 2026-08-01 — W2: the careful write order, called at last

`fire-crab-cch` has modelled the engine's precedence graph — content
before the reference to it — since it was converted, and
`qa/cch-crash-harness.sh` has gated it that whole time. **Nothing called
it.** The server flushed a modified database with one `fs::write` of the
whole file, which is correct when it completes and arbitrary when it does
not: a crash part-way through leaves whatever the operating system
happened to flush, in whatever order it chose.

### Converted
- **The DML flush writes PAGES, in precedence order.** `careful_plan`
  builds the graph from the before/after images, `flush` drains it, and
  each page is written at its offset and `sync_data`'d before the page
  that references it — an ordering that exists only in memory is not an
  ordering.
- `crates/wire` depends on `fire-crab-cch` for the first time. That
  leaves `-lck`, `-evt` and `-pio` as the subsystems the server still
  never calls.
- A file that GREW is still written whole: extending a file is its own
  careful-write question, and answering it by guessing would be worse
  than not answering it.

### Measured, not assumed
Five pages per statement instead of the whole file, and 1200 inserts in
74.1s against 79.1s before — so the per-page `sync_data` very nearly
cancels the smaller writes. **This slice does not buy speed.** It buys
the property the harness has been checking all along: every prefix of the
write sequence is a database the engine can open.

New `qa/serve-real-carefulflush.sh` (17 checks): the flush is ordered,
it touches only the pages that changed, the engine opens the result,
`gfix` validates it — and `FC_NO_CAREFUL` turns the ordering off so the
assertions can be seen to fail, the same trick `FC_NO_INDEX` earns its
keep with. 372 unit tests and 11 gates, including the ones that run
`gfix` and `gbak` over the written file.

## 2026-08-01 — W1p: a parameter's value arrives after the plan

### Converted
- **`WHERE ID = ?` reaches an index.** It could not before: a band needs
  a value, and the plan is built while the value is still a `?`. The plan
  now carries the two things `choose_index` cannot recover from a bound
  predicate — the table's name and the statement text `opt` reads — and
  the bands are built at EXECUTE, from the filter in which binding has
  already turned each `?` into a literal. Same function, same rules, one
  moment later.
- It matters because that is how a prepared-statement client asks almost
  everything. Equalities, ranges, two bounds from two parameters, and an
  `OR` of parameters all retrieve now; a parameter on an unindexed
  column still scans, and so does a NULL one.

### Found while widening the sweep, and NOT caused by this work
`qa/serve-real-params.sh` fails, and has been failing since before the
index programme began — bisected to R7 and earlier. fire-crab **accepts a
boolean parameter INSERT that the engine rejects**, so its table gains a
row the engine's has not, and the two counts diverge. It is in the
roadmap with the reproducer. The gate was never in any sweep here: I had
been running `serve-real-typedparams.sh` and assumed it covered the same
ground.

`qa/serve-real-index.sh` is 356 checks. 372 unit tests and 7 gates
confirm nothing moved.

## 2026-08-01 — W1o: the check that could not tell the difference

### Fixed
- **An INT128 key could be one byte too long.** The BCD compressor
  pushes the 4th byte of each cycle unconditionally; when the last
  3-digit group lands there and is a multiple of 256, that byte is a
  trailing `0x00` the engine's `makeBcdKey` does not write. About 2 in
  3000 random `NUMERIC(38,6)` values — which is why it took random
  full-range data to find, and why repeating digit patterns never did.

### Contained — the more important half
`entry_is_current` **cannot tell "this entry is stale" from "my encoder
disagrees with the engine"**, and it treated both as staleness. Every
encoder difference it met therefore became a MISSED ROW rather than a
wasted fetch: a scaled `DECIMAL`, a `FLOAT` segment, `i64::MIN`, and now
an INT128 one byte too long — four separate bugs, one failure mode.

The check has exactly two jobs: stop a moved row coming back twice, and
stop it appearing at its old key's position in a navigated walk. **The
first is already done by the record-number dedup.** So the check now runs
only when the walk IS the order. Outside navigation a differing key costs
a fetch and the ordinary predicate decides — the same contract the index
has everywhere else.

That does not excuse the encoder bugs, and all four are fixed. It means
the next one is a performance bug instead of a data-loss bug.

`qa/serve-real-index.sh` is 338 checks. 372 unit tests and 8 gates
confirm nothing moved.

## 2026-08-01 — W1n: three keys the engine never wrote

The fleet's full report named root causes my previous fix had only
softened. Two of these were corrupting the WRITE path as well.

### Fixed
- **A scaled value's key MULTIPLIED where the engine DIVIDES.**
  `MOV_get_double` divides by the power of ten; `raw * 10^-n` is a
  different double in the last ulp for about a third of the raws — 0.3,
  0.6, 0.7, 1.2, 1.4, 1.7 among them. So a `DECIMAL`/`NUMERIC` column
  produced keys the engine never wrote, and every row carrying such a
  value fell out of the index that held it — **in both directions**: our
  retrieval could not find them, and the engine could not find what
  fire-crab wrote.
- **A `FLOAT` column's value form was not accepted at all**, so
  `key_for` returned None for every candidate from an index holding one
  and the index answered the **empty set**. (`Value::Float` is kept
  apart from `Double` for printing; the key encoder only knew `Double`.)
  A single-segment FLOAT index scans, so this needed a compound index to
  surface.
- **`i64::MIN` now ABSTAINS at the source.** `int64_key` returns None for
  it, which makes the search key unbuildable (so the retrieval scans) and
  the candidate unjudgeable (so it is kept). The previous guard covered
  only the search key, so a row that merely *contained* `i64::MIN` in an
  indexed segment was still rejected by verification.

### Gated
The index gate carries the raws where multiply and divide disagree, a
compound index with a FLOAT segment, and a column holding `i64::MIN`.
The write gate — the one that asks the ENGINE — now writes scaled
DECIMAL keys through fire-crab and has the engine find them through its
own index, with `gfix` after.

`qa/serve-real-index.sh` is 332 checks, `qa/serve-real-descwrite.sh` 36.
372 unit tests and 7 gates confirm nothing moved.

## 2026-08-01 — W1m: fire-crab was corrupting descending indexes

The worst defect the fleets have found, and it has nothing to do with
retrieval — it is the WRITE path, and it predates every index slice.

### Fixed
- **A descending key is stored COMPLEMENTED, so plain byte order almost
  works.** It fails on exactly one shape: where one key is a byte PREFIX
  of another. Ordinary lexicographic comparison pads the shorter key
  with `0x00` and puts it FIRST; the engine pads it with `0xFF` and puts
  it LAST. `insert_index_entry` used the ordinary one, so every entry
  whose key prefixed or was prefixed by another went into the wrong
  place in the tree.

  fire-crab could not see the damage — it reads back what it wrote. The
  engine could:

  ```
  SELECT COUNT(*) FROM T WHERE D = 3    -> 0, on a table that holds it
  SELECT D FROM T ORDER BY D DESC       -> 2, 256, 257, 17, 16, 5, ...
  gfix -v -full                         -> Number of index page errors: 2
  ```

- `insert_index_entry` takes the index's direction now, and
  `node_cmp_desc` implements the engine's rule.

New `qa/serve-real-descwrite.sh` (29 checks). It asks fire-crab nothing:
fire-crab does the WRITING — over the value pairs where one encoded key
prefixes another, 16/256 and 17/257 — then the server stops and **the
engine** reads, with `SET PLAN ON` so the PLAN line proves an index was
used, and `gfix` finishes, since gfix is what named the corruption.

372 unit tests and 6 gates confirm nothing moved.

## 2026-07-31 — W1l: an entry the server cannot judge is not a stale one

The fleet's first hunter came back with four failures against the new
union-of-bands surface. Three of them were one mistake.

### Fixed
- **A key that cannot be rebuilt was read as "the entry is stale", which
  DROPS the row.** A candidate survives only if the fetched record still
  carries the entry's key — and that means rebuilding the key from the
  record. When the rebuild fails, the check has nothing to say, and it
  must therefore say nothing.

  It said plenty. A **FLOAT** column anywhere in an index made every
  retrieval over that index return the **empty set**. A scaled
  **DECIMAL** lost most of its values. And **`i64::MIN` came back**
  through this door after the search-key guard had closed the other one.
  The predicate above still decides and the record-number dedup still
  collapses duplicates, so keeping an unjudgeable candidate costs a
  comparison; dropping one costs a row.
- **Row order without an `ORDER BY` is not arbitrary — it is the
  engine's.** Its non-navigational retrieval ORs the branches into a
  record-number bitmap and returns rows in RECORD order; ours came back
  in band order, then key order within a band. With no `ORDER BY` that is
  an unordered result either way, until `FIRST 2` makes it a different
  **set of rows**. Candidates are sorted by record number now unless the
  walk *is* the order.
- **Navigation is restricted to key families the server can rebuild
  exactly.** Trusting a walk's order means trusting that its entries can
  be judged.

### And a regression I introduced fixing them
Deduplicating candidates when they are COLLECTED rather than when they
are ACCEPTED let a stale entry shadow the valid one: a record named first
by its stale entry was skipped as a duplicate when its current entry
arrived, and the row vanished. The moved-key checks caught it
immediately, which is what they are for.

`qa/serve-real-index.sh` grows to 322 checks. 371 unit tests and 7 gates
confirm nothing moved.

## 2026-07-31 — W1k: OR is a union of bands, and so is IN

### Converted
- **A disjunction retrieves through one band per branch.**
  `A = 1 OR A = 2` is two bands of one index; `A = 1 OR B = 2` is one
  band of each of two. `IN (...)` desugars to exactly that at parse
  time, which is where most of the value is.
- New `IndexAccess` — the access path for a retrieval is a *set* of
  bands, and the plan carries it. `choose_index` splits into a
  per-branch `pick_for_terms`.

### Guarded
Two rules, both of which decide correctness rather than speed:
- **Every branch must be servable, or the whole statement scans.** A
  partial union is a *missing set of rows*, not a slower answer. One
  branch on an unindexed column, or one shape no band can express, and
  the retrieval declines entirely.
- **Candidates are deduplicated ACROSS bands.** A row can satisfy two
  branches — most obviously when the branches use different indexes —
  and would otherwise be returned twice. The gate asks for it directly:
  the same branch twice, and `ID = 1 OR DEPT_ID = 1` where one row
  answers both.
- Navigation belongs to the single-band case only: a union of bands has
  no single order to inherit.

`qa/serve-real-index.sh` grows to 306 checks. 371 unit tests and the
write-path gates confirm nothing moved.

## 2026-07-31 — W1j: the wrong record, not the missing one

The adversarial fleet's full report arrived after the previous fix, and
corrected it. The deleted-row failure was real but the cause was not the
one I fixed.

### Fixed
- **`records().nth(slot)` is not the record at slot `n`.**
  `DataPage::records()` filters out RELEASED slots, so once a deleted
  row's version is garbage-collected — which any ordinary read does —
  the iterator shifts and every entry after the hole fetches **someone
  else's record**. That is worse than a missed row: a wrong record can
  satisfy the predicate and be returned, or written. `record(slot)`
  indexes the slot directly.
- The sequence→page mapping fixed in the previous increment was also
  wrong, and both were needed; only this one produced wrong ROWS.

### Gated where it could not be gated before
Both remaining reproducers need **the engine** to do the writing —
fire-crab performing the same statements does not produce either. So the
fixture now mutates through `isql` before any server starts: a delete
followed by a read that collects the dead version and releases its slot,
and a key that leaves and returns inside one engine transaction (which
leaves two live entries with the same key and record — what a stored
procedure touching a column twice produces).

`qa/serve-real-index.sh` grows to 306 checks. 371 unit tests and the
write-path gates confirm nothing moved.

### On the fleet
Six agents, ~17,000 statements, one report that named a root cause I had
guessed wrong. The three-way oracle is what did it: the second server is
the same binary with `FC_NO_INDEX=1`, so "index bug or SQL-surface
difference" was never a question anyone had to argue about.

## 2026-07-31 — W1i: four more the fleet found, and one capability withdrawn

### Fixed
- **A deleted row moved every later row out of reach.** A record number
  names its page by SEQUENCE, and the sequence is not the page's
  POSITION in the relation's page list — a freed page leaves a gap. The
  lookup read the wrong page, failed its own sanity check, and dropped
  the row: **one deleted row hid every key stored after it**. The mapping
  is a lookup now, not an index.
- **A key that leaves and comes back was returned twice.** The writer
  skips an entry it already holds, but only within the leaf page it
  descended to — so `K 20 → 25 → 20` can leave two identical entries in
  different pages, **both of them current**. Verification cannot separate
  those: same key, same record. One row per record, however many entries
  name it.

### Withdrawn
- **A DESCENDING index is no longer keyed at all**, and that is measured
  rather than cautious. Complementing the key reverses byte order, which
  the bounds could swap for — but it also destroys the PREFIX
  relationship variable-length keys rely on: with `'ab'` and `'abc'` in
  one descending text index, equality on `'ab'` found **nothing**, and
  equality on a descending integer index missed rows too. Two measured
  misses in one piece of arithmetic is enough. It scans until the layout
  has been read back off the engine's own index.

### How they were found
An adversarial fleet of six agents, each with its own strategy, ran
~17,000 statements through a three-way oracle: fire-crab with index
retrieval, **the same binary with `FC_NO_INDEX=1`**, and the real engine.
That middle server is what makes the method sharp — a difference between
it and the first is an index bug by construction, with no argument about
whether the SQL surface agrees with Firebird. Every failure above needed
a shape no fixture in this gate had: a page boundary, a freed page, a key
that returns, a value that extends another.

`qa/serve-real-index.sh` grows to 291 checks. 12 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — i64::MIN: a key the engine builds through an overflow

### Fixed
- **`WHERE A = -9223372036854775808` returned nothing** where the engine
  returns its rows. With the index path switched off the same server
  answered correctly, which localised it immediately: the key, not the
  comparison. The engine's `make_int64_key` negates the value before
  choosing a scale factor, and negating `i64::MIN` overflows — so its
  scale-control choice differs from the arithmetically correct one and
  our key lands elsewhere in the tree.
- Retrieval refuses to key that one value and scans instead, which is the
  standing rule: a key that cannot be built exactly must not be used,
  because the failure is a missed row rather than a refusal.

### Named, not fixed
The WRITE path still stores our key for `i64::MIN`, so a row fire-crab
inserts with exactly that value carries an index entry the engine's own
lookups may not find. Closing it means reading the engine's actual key
bytes for that value. It is in the roadmap with the reproducer.

`qa/serve-real-index.sh` grows to 275 checks, with both BIGINT extremes
in the fixture — the largest keyed, the smallest asserted to scan.

## 2026-07-31 — W1h: a duplicate run that spans leaf pages lost 2306 of 2310 rows

Found by an adversarial fleet, not by a gate — and no gate here could
have found it.

### Fixed
- **The B-tree descent landed on the LAST interior node with the target
  key, not the first.** A non-leaf node's key is the LOWEST key of its
  child page, so when one value's duplicates span several leaf pages,
  *several* non-leaf nodes carry that same key. Advancing while
  `key <= target` walks past every earlier page that also holds it. The
  child that can contain the first occurrence is the last one whose key
  is **strictly less** than the target.

  ```
  2310 rows, all A = 1, PAGE_SIZE 4096:
  SELECT COUNT(*), MIN(ID) FROM H2310 WHERE A = 1
      -->  4 | 2307        the engine:  2310 | 1
  ```

  The rows were not filtered out — they never became candidates, so the
  predicate above never saw them. Aggregates, `FIRST`, `GROUP BY` and
  the DML target walk all inherited it.

### Why no gate caught it
Every fixture in `qa/serve-real-index.sh` was a handful of rows, and a
handful of rows is **one leaf page** — the page-boundary behaviour was
untestable by construction. The gate now carries a 6000-identical-key
run and asks eight questions across it. The same reasoning killed a
planned unit test: building such a tree in memory means letting the
writer split, which needs a page-inventory page, and a hand-built one
produced a tree the writer walked forever. The comment in `btr.rs` says
so, so the next person does not re-attempt it blindly.

`qa/serve-real-index.sh` grows to 271 checks. 9 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — W1g: a compound index's leading segment, and text keys

### Converted
- **An equality on the LEADING SEGMENT of an ascending compound index.**
  A compound key stuffs its segments together, so `A = 1` on an `(A, B)`
  index names a contiguous BAND: the lower bound is the key of
  `(1, NULL, ...)` — which is exactly what the engine writes for that row,
  so it cannot miss the NULL-tailed ones — and the upper bound is that
  prefix's **exclusive successor** (`prefix_successor`: increment the
  last byte, dropping trailing `0xFF`s and carrying left).
- **Text equality**, on `VARCHAR` and `CHAR`, with an ASCII literal. The
  encoder strips trailing blanks on both sides, which is the same
  pad-insensitivity the comparison has, so a CHAR value and a VARCHAR
  literal meet at the same key.

### Guarded
- **The upper bound is the whole slice.** An INCLUSIVE bound at the
  prefix itself admits only the all-NULL-tail key and silently drops
  every row with a value in its trailing segments. Every compound check
  in the gate has rows on both sides of that line.
- A **range** on a compound leading segment still scans: `<= v` ends at
  the successor of v's band while `< v` ends at the band's start, and two
  rules for two adjacent operators is how a missed row ships.
- A **descending** compound index still scans: the complement covers the
  markers and the padding, so the successor would have to be computed
  before it, with the bounds swapped.
- A **non-ASCII** literal still scans: above `0x7F` a charset or
  collation decides the bytes, and a key that differs from the stored one
  does not refuse — it misses.

`qa/serve-real-index.sh` grows to 247 checks. 27 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — W1f: a row that moved was returned twice

### Fixed
- **An index entry outlives the version that wrote it, and that is not
  merely a wasted fetch.** An UPDATE adds the new key and leaves the old
  one for garbage collection, so a record whose key changed is named by
  **both** entries. A range covering both fetched it twice — and the
  predicate cannot catch that, because the row genuinely matches. In a
  navigating retrieval it was worse: the row also appeared at the OLD
  key's position, so the order was wrong too.

  ```
  UPDATE T SET ID = 20 WHERE ID = 1;
  SELECT ID FROM T ORDER BY ID;   -- [20, 2, 20]   engine: [2, 20]
  ```

  This was live for two increments — ranges, then navigation — and no
  gate caught it, because none of them changed a key column and then
  asked a question whose range spanned both keys.
- **The fix is the engine's own rule**: `btr::lookup_range` returns
  `(key, record number)` pairs now, and a candidate is kept only when the
  fetched record STILL CARRIES that key (`IndexPick::entry_is_current`,
  which rebuilds the key from the record with the same encoder). That
  makes the earlier claim true rather than approximately true.

### Converted
- **`UPDATE`/`DELETE ... WHERE` retrieve through the index.** A write
  reads before it writes, and `collect_dml_targets` had been walking
  every page — it never appeared in any count of retrieval sites because
  it has its own scan rather than calling `for_each_record`.

`qa/serve-real-index.sh` grows to 200 checks, with a section that moves a
key to the far end of the tree and asks every question whose range spans
both places. 28 gates and 370 unit tests confirm nothing else moved.

## 2026-07-31 — A UTF8 database could not be written to at all

### Fixed
- **A text index on a UTF8 column is stamped `idx_metadata` (itype 4),
  not `idx_string`**, and `resolve_index_ops` did not list itype 4. It
  returns None for the WHOLE RELATION when any index carries an itype the
  write path cannot key, and the INSERT planner takes that with `?` — so
  on a UTF8 database, **the default character set in this project's own
  hands-on samples**, a table with a text index accepted no INSERT and no
  UPDATE whatsoever. The engine took both. Reads worked, which is exactly
  why it went unnoticed: every gate here builds its scratch database in
  the default NONE charset.
- `btw::index_key` had encoded itype 4 correctly all along
  (`INTL_string_to_key` for `ttype_metadata`: plain bytes, trailing
  spaces stripped, an empty value padding to `0x00` rather than the blank
  `idx_string` uses). The conversion was right; the accept-list was one
  name short.

New `qa/serve-real-utf8index.sh` (20 checks). Its decisive check is not
that fire-crab accepts the write: the server is stopped and **the engine
reads the file back through its own index**, with `SET PLAN ON` so the
PLAN line proves an index was used rather than a scan — a key written
differently from the engine's would find nothing there — and `gfix -v
-full` then validates the pages.

## 2026-07-31 — W1e: the foreign-key check stops scanning

### Converted
- **`fk_partner_has` drives the parent's own index.** "Does a parent row
  with this key exist" is an EXISTENCE test, and the referenced side
  always carries a unique index because SQL requires one. It had been
  answered by scanning the whole referenced relation **once per written
  row** — its own comment already said *the engine compares partner
  index keys*.
- **The whole key is known here, so a COMPOUND index is a point lookup**
  rather than a prefix range. This is the one place where a
  multi-segment key is the easy case, and the write path's encoder
  already stuffs compound keys byte-exactly.
- Same safety rule as every other retrieval: the index names candidates
  and the same pad-insensitive comparison still decides. A text key
  cannot be built byte-exactly yet, so it **scans** — and the gate
  asserts that it scans.

### Fixed
- **The roadmap's "30 `for_each_record` sites" was a remembered number,
  not a measurement.** There are 21, and most are catalog walks that are
  not query retrieval at all. The sites that matter are four, and two
  had never been named: this one, and `collect_dml_targets` — which
  walks every page for `UPDATE`/`DELETE ... WHERE` and never appeared in
  the count because it has its own scan rather than calling
  `for_each_record`.

`qa/serve-real-index.sh` grows to 186 checks, with an `fk lookup:` trace
line and assertions in both directions. A `both_refuse` helper joins it:
fire-crab has no constraint-violation TEXT of its own (a generic error
where the engine names the constraint and the offending key), which is a
pre-existing gap, so those checks assert that both sides refuse rather
than pretending the wording matches.

21 gates and 369 unit tests confirm nothing moved.

## 2026-07-31 — W1d: the sort an index makes unnecessary

`Access::Order` — the engine's navigation. An index walk already
delivers its rows in key order, so the sort above it re-establishes an
order that is already there.

### Converted
- **A navigating retrieval drops the `Sort`.** `ORDER BY <primary key>`
  walks the index and streams; `WHERE ID > 2 ORDER BY ID` bounds the
  same walk; `FIRST 3 ... ORDER BY ID` reads three rows' worth of the
  tree instead of sorting the relation.
- **An ORDER BY alone is now reason enough to use an index** — until
  now a predicate was required, so the commonest ordered query in the
  language could not reach one.
- **BOUNDS BEAT NAVIGATION.** When the predicate's index and the order's
  index differ, the bounded retrieval wins and the sort runs: reading a
  few records beats walking the whole relation to save a sort. When they
  are the *same* index you get both. That is opt's rule too.

### Guarded
Row order is part of the answer, and a sort dropped wrongly does not
lose rows — it returns the right rows in an order the engine did not
choose. So navigation is taken only where the index's order is **total
and identical** to the clause: one ascending key, no explicit NULLS
placement, a plain field, an ascending single-segment index that is
**unique**, and a **NOT NULL** column. Each exclusion is gated:

- a DESCENDING order (the walk goes the other way);
- a NON-UNIQUE index — duplicates come back in record-number order, which
  the engine has never promised;
- a **unique index on a NULLABLE column**, because an all-NULL key is
  exempt from uniqueness, so two rows can share the empty key and tie;
- two keys where the index has one; an explicit `NULLS LAST`; a column
  with no index.

The index-vs-scan-vs-engine equivalence checks now compare *sequences*
over navigated orders, which is what makes those exclusions checkable
rather than argued.

`qa/serve-real-index.sh` grows to 171 checks. 33 gates and 369 unit
tests confirm nothing moved.

## 2026-07-31 — W1c: the fold reads through a retrieval too

### Converted
- **A grouped query's leaf is chosen the same way** as a projection's.
  `Plan::Group` carries the access path, and both trees that build a
  fold (`branch_rows` and the emit) take it — so `GROUP BY` over an
  indexed `WHERE` looks up instead of scanning.
- **The prepare-time aggregate walk** — the fast path a lone `COUNT`,
  `SUM`, `MIN` or `MAX` takes — reads its candidates through the same
  leaf. It was the one retrieval site the previous slice named and left
  scanning, with the gate saying so.
- One function, `leaf_source`, now states "index or scan" for every site
  that builds a tree.

### Fixed
- **The aggregate's choice was made and never logged**, so the coverage
  check could not see it: the gate reported a scan for a statement that
  was using an index. A coverage assertion is only as good as what it
  can read, and an unlogged decision is invisible to it in exactly the
  same way as a decision never made.

### Guarded
- **A `HAVING` clause makes the whole statement scan**, because `opt`
  does not parse one and declines it — even though the `WHERE` beside it
  is the same indexable predicate that drives an index without the
  HAVING. That is the right way round: a component that cannot read the
  statement must not be asked to bless it. The retrieval inherits the
  optimizer's limits, and the gate asserts the scan so the day opt
  learns HAVING, the check notices.

`qa/serve-real-index.sh` grows to 146 checks. 29 gates and 369 unit
tests confirm nothing moved.

## 2026-07-31 — W1b: ranges, and the bound that was never asked for

### Converted
- **`btr::lookup_range`** — one descent, then a forward walk to the
  upper bound. Each bound is optional and carries its own inclusivity,
  so `>`, `>=`, `<`, `<=` and `BETWEEN` are one code path. `lookup_key`
  is now the degenerate case where both bounds are the same key,
  inclusive: the descent and the stop condition are the part that is
  easy to get subtly wrong, and there is one of each.
- **A conjunction NARROWS**, so several comparisons on one column
  combine into a single range: `ID >= 2 AND ID >= 4` starts at 4, and an
  equality beside a range collapses to a point.
- **A DESCENDING index is served by swapping the bounds.** Its keys are
  complemented, so the tree's byte order is the reverse of the value
  order — and `key_for` has already complemented the bytes, which makes
  the swap the whole adjustment.

### Fixed
- **Every range on a primary key was still scanning.** `opt` answers
  `Access::Order` — not `Access::Index` — when an index NAVIGATES the
  `ORDER BY`, and `SELECT ... WHERE ID > 3 ORDER BY ID` is exactly that.
  So the shape that most obviously wants an index was the one shape
  refusing it, while `WHERE DEPT_ID > 3 ORDER BY ID` used one, purely
  because its ORDER BY named a different index. Both answers mean "an
  index serves this"; the retrieval half is taken and the sort still
  runs above it.

### Guarded
- A column with NULLs under an upper-bounded range: NULLs are stored as
  a **zero-length key**, which sorts before every value, so the range
  sweeps them up as candidates and the predicate throws them out. A
  wasted fetch, never a wrong row — the same property the whole slice
  rests on, gated explicitly.

`qa/serve-real-index.sh` grows to 125 checks (17 of them ranges, plus
the index-vs-scan-vs-engine equivalence over a range, a range with NULLs
below it, and an empty one). 48 gates and 369 unit tests confirm nothing
moved.

## 2026-07-31 — W1: the first index-driven retrieval

Programme W begins. Every query here was a full scan; a converted
optimizer chose access paths that nothing executed. Both of those are
now less true.

### Converted
- **`btr::lookup_key`** — the retrieval half of `BTR_lookup`: descend to
  a key, collect the record numbers of the entries that equal it,
  following the sibling chain while duplicates continue. `ods` could
  walk a whole leaf level before this; it can now find a key.
- **The server asks `fire-crab-opt` for the access path.**
  `crates/wire/Cargo.toml` depends on it for the first time, and
  `plan_query` — the same converted cost model whose PLAN output is
  gated against the live engine — decides. When it answers NATURAL, this
  scans, whatever the predicate looks like.
- **`RowSource::IndexScan`**, a leaf beside `TableScan`. The tree above
  it is identical either way: the same `Filter`, the same `Sort`. An
  index narrows what is READ and never what is ANSWERED, which is what
  makes "the answers do not move" a property of the shape.
- The choice is made at PREPARE and carried on `Plan::Project`, which is
  where the engine makes it too.

### Fixed
- **Re-inserting a deleted key was refused**, against an engine that
  accepts it. Uniqueness was read from the index ENTRIES, and entries
  outlive their records — an UPDATE adds the new key and leaves the old,
  a DELETE removes nothing. The conflicting records are fetched and
  their keys recomputed now; only a live record that still carries the
  key is a duplicate. The cheap entry-level check still runs first and
  only its REJECTION is re-examined, so a duplicate this cannot disprove
  is still a duplicate.

### Guarded
- The mechanics are deliberately narrow — single-segment integer indexes
  at scale 0, against an integer literal — because a key this cannot
  build byte-exactly is not a refusal but a **missed row**, the one
  failure the predicate above cannot catch. Scaled numerics, text (a
  collation makes the key a collation key), compound prefixes, ranges,
  `IS NULL`, `OR` and parameters all scan.

New `qa/serve-real-index.sh` (90 checks) is gated twice: the answers
against the engine, and **the access path itself**, read from the
server's own log — because "wired in but never used" passes every
behaviour gate. It asserts an index for the shapes that have one and a
scan for the shapes that do not, runs a second server with the index
path switched off (`FC_NO_INDEX`) to prove the coverage checks can fail,
and interleaves DML so a stale entry has to be survived rather than
assumed away. 45 gates and 368 unit tests confirm nothing moved.

## 2026-07-31 — R7: the textual rewriting is gone

The end of Programme R. A view was answered by **rewriting the query
against its base table**; it is a **row source** now, like everything
else the tree reaches.

### Converted
- **A VIEW is planned, not expanded.** Its stored SELECT is planned on
  its own; the outer query resolves against that plan's DESCRIBE; its
  declared column names are laid over the body's, positionally. In a
  join it is a SIDE, which is R5a serving a second caller.
- **~870 lines deleted**: `expand_view`, `expand_view_join`,
  `qualify_idents`, `replace_qualified_col`, `mentions_bare`,
  `replace_table_ref`, `replace_idents` — and with them the laws they
  implemented by hand. The view's own WHERE going into a join step's ON
  when the side can be NULL-padded, and into the outer WHERE when it
  cannot, was an emulation of *the filter sits inside the inner plan,
  below the padding*. The tree gets that by construction.
- **The derived-table planner and the CTE planner became ONE
  function** (`plan_over_source`): a query over a bound name, whose
  source is either materialised rows or an inner plan. R6's recursive
  CTE, R4's derived table and R7's view all enter through it.
- **Three shapes the rewriting could not express now answer**: a view
  whose own body JOINs (there was no single table to rewrite to), a view
  under a RIGHT or FULL join, and a bare renamed column in a join.
- **GROUP BY over a derived table** — a refusal R4 recorded — answers:
  the fold above a materialised base is what a grouped join with no
  parts already is.
- **A derived table may name its own columns**: `(SELECT ...) X (A, B)`,
  probed against the engine. That is also how a renaming CTE keeps its
  names now, instead of the rewriting refusing it.
- Every CTE is materialised as a derived table; the INLINING pass is
  gone. A chain of CTEs is spliced into the next body in declaration
  order, so each inner query names only real relations.

### Fixed
- **`qa/serve-real-alias.sh` could not pass.** Its second-phase liveness
  check tested `$srv` — the first server's pid, cleared two lines
  earlier — so the gate exited 1 before phase 2 ever ran. Twelve checks
  had never executed. The mirror of a gate that cannot fail is a gate
  that cannot pass, and both report something untrue.
- **`ident_ok` accepts `3`**, so a derived table's column list would have
  taken a numeric literal as a column name. An unquoted identifier starts
  with a LETTER; a delimited one may be anything, and the callers that
  have already stripped the quotes cannot tell the two apart. New
  `bare_ident_ok` for the unquoted case. (The central fix breaks `"3"`,
  which the engine accepts — the trap is worth stating rather than
  papering over.)

44 gates and 366 unit tests are the safety net; four gates promoted
refusals to comparisons.

## 2026-07-31 — R6: WITH RECURSIVE, a fixpoint over the tree

The capability the whole row-source programme was built toward: the one
CTE shape that **cannot** be answered by rewriting text, because the name
it must resolve is its own.

### Converted
- **`WITH RECURSIVE` evaluates as a FIXPOINT.** The seed runs once; the
  recursive branch is then evaluated against the last level's rows until
  a round produces nothing; the accumulated rows are the CTE. The loop is
  a dozen lines — R5a is what made it expressible.
- **The hierarchy walk goes to the ORDINARY join planner.** `FROM ORG O
  JOIN C ON O.PARENT = C.ID` binds `C` to the rows in hand as a join
  side (`RowSource::Rows`), and nothing else about the join changes: not
  the ON, not the outer padding, not the qualifiers, not a grouping above
  it. The same binding serves the final query, so the CTE joined to a
  real table — and to *itself* — needed nothing of their own.
- **Aggregating the accumulated rows reuses the grouped join.**
  `SELECT COUNT(*) FROM C` is a fold over a materialised base, which is a
  `Plan::JoinGroup` with no parts; GROUP BY, HAVING and every aggregate
  arrived together.
- **A CTE may name its own columns** — `WITH RECURSIVE C(X, Y) AS ...` —
  where the seed supplies only the values.
- **`Plan::Scalar` is a row source** in `branch_rows`: a lone aggregate
  plans to a scalar, and `SELECT MIN(ID) FROM T` is an ordinary seed.
- `WITH RECURSIVE` on a body that never names itself is an **ordinary
  CTE** and takes the ordinary path — the keyword is a declaration, not a
  fact.

### Guarded
- **Two self-references answered.** `FROM C C1 JOIN C C2` is a fixpoint
  over a product; the engine rejects it, and binding both sides to the
  same rows produced a plausible answer instead. Now counted: exactly one
  reference in the recursive branch, which is the engine's rule.
- **`ORDER BY` inside a branch answered.** A union branch carries no sort
  of its own; the engine rejects it and this sorted the branch.
- Non-termination is bounded at **1024 levels**, the engine's own limit,
  so a runaway fixpoint raises rather than hangs.

Both wrong answers were found by PROBING, not by reasoning — each looked
entirely reasonable. The new gate therefore asserts the refusal *and*
asserts that the engine rejects the same statement, so it cannot drift
into enforcing a refusal the engine does not share.

New `qa/serve-real-recursive.sh` (43 checks). `qa/serve-real-cte.sh`
grows to 35 with its `WITH RECURSIVE` refusal promoted to a comparison.
23 planner gates and 365 unit tests confirm nothing moved.

## 2026-07-31 — R5a: a derived table as a side of a join

The prerequisite R6 turned out to need, and the refusal both R4 and R5
had recorded.

### Converted
- **A join side may now be a DERIVED TABLE.** `JoinSide`, `JoinPart` and
  `Plan::Join` carried a relation id and its formats; they carry a **row
  source** now, so a side is either a scan or an inner plan. On the left,
  on the right, on both, under an outer join, with the join grouped above
  it.
- **The execution half needed nothing.** `RowSource::NestedLoopJoin`
  already took a `RowSource` per side and never cared where the rows came
  from — that was R3's shape paying for itself. The work was all in
  planning: a derived side's columns and descriptors come from the inner
  plan's DESCRIBE rather than from a relation.
- **A materialised CTE can be a join side**, which was R5's stated
  refusal: the CTE's name is spliced in that position like any other,
  with the splices applied in descending offset order so an earlier one
  cannot move a later one.
- New `RowSource::PlanRows` — an inner plan as a leaf, evaluated when the
  tree is pulled rather than when it is built, so a plan is still a plan
  at prepare time.

### Fixed
- **`FROM (SELECT A, B FROM T) X JOIN ...` was read as a COMMA JOIN
  LIST.** `parse_from` tested `from_s.contains(',')` — and a derived
  table's own select list has commas in it. The depth-aware split was
  already there and already used two lines later; only the TEST was
  naive. It is the third clause-splitting bug this programme has found in
  the same shape: a keyword or separator inside a nested query is not
  this query's.
- `parse_table_ref` and the JOIN scan are paren-aware for the same
  reason.

`qa/serve-real-derived.sh` grows to 41 checks and `qa/serve-real-cte.sh`
to 35, with the CTE refusal promoted to three comparisons. 13 join and
subquery gates plus 363 unit tests confirm nothing moved.

## 2026-07-31 — R5: the materialised CTE

### Converted
- **A CTE body the inlining cannot rewrite is MATERIALISED** — because a
  CTE whose body cannot be inlined **is a derived table by another
  name**. `FROM C` becomes `FROM (<body>) C`, and R4's machinery plans it
  properly: inner query planned on its own, columns from its describe,
  rows as a leaf.
- So a CTE body that **GROUPS**, **stars**, or **JOINS** now answers.
  Those three were refusals one increment ago, and the fix is a rewrite
  of one FROM item — because the hard part was already built.
- **A grouped PLAN became a row source.** It could not be one before the
  fold was a node: materialising a grouped query meant repeating
  scan-filter-aggregate-sort by hand, so nothing did, and a grouped CTE
  or derived table had nowhere to get its rows. `branch_rows` now builds
  the same `TableScan → Filter → Aggregate → Sort` the emit path does.

### Guarded
- A CTE with an explicit **renaming** column list AND an unexpandable
  body refuses: a derived table carries the body's own names, so
  answering under the renamed ones would be wrong. The list is detected
  as explicit by DIFFERING from what the body itself names, which is the
  only signal available at that point.
- A materialised CTE as one **side of a join** still refuses — that needs
  derived tables in joins, a later slice, and it must keep refusing
  rather than half-work.

**The bug worth recording**: the rewrite spliced the body in by searching
for the CTE's name with `cur.find(table_s)` — and for a CTE named `C`
that found the **C inside `SELECT`**, producing `SELE(SELECT ...) CT
COUNT(*)`. The position has to come from the slice itself
(`table_s.as_ptr() - cur.as_ptr()`), since `split_query` returns
subslices of the text. A one-letter identifier is not an unusual name for
a CTE, and a text search for one is never safe.

`qa/serve-real-cte.sh` grows from 29 checks to 33; three of its refusals
become comparisons. 17 gates and 363 unit tests confirm nothing moved.

## 2026-07-31 — R4: derived tables

**The first capability the row-source tree unlocks**, and the reason it
could not be reached before is worth stating: every earlier "query over a
query" here worked by SUBSTITUTING A NAME. A view has a catalog entry; a
CTE has one written in the statement. Both could be expanded into the
FROM and re-planned. **A derived table has neither** — its columns exist
only because the inner query ANNOUNCES them, and its rows exist only
because something RAN it.

### Converted
- **`SELECT ... FROM (SELECT ...) X`**, with the outer projection, WHERE
  and ORDER BY resolved against a synthetic view built from the inner
  plan's **describe** — the same move the join makes with its combined
  row and the group makes with its folded one. The describe is the right
  source: if the outer query and the CLIENT disagree about a column's
  type, one of them is wrong.
- The inner plan's rows become a materialised leaf, with the outer WHERE
  and ORDER BY as nodes above it: `Rows → Filter → Sort`.
- Renamed and computed inner columns work, because they are exactly what
  an announcement is for; so do nested derived tables, FIRST/SKIP/
  DISTINCT above one, and a derived table as a row source for
  `INSERT ... SELECT`.

### Fixed
- **The clause splitter was not paren-aware.** It found the first
  `WHERE`/`GROUP BY`/`HAVING`/`ORDER BY` keyword ANYWHERE in the text, and
  a derived table puts one inside parentheses — so the outer statement
  was torn in half at the inner query's WHERE. `FROM` had been found at
  paren depth 0 since `SUBSTRING(S FROM 2)` needed it; now every clause
  keyword is. That change touches EVERY statement, which is why the new
  gate ends with subquery, grouped and `SUBSTRING` checks that have
  nothing to do with derived tables.

### Guarded
- A column the inner query did not project refuses rather than answering
  NULL; `GROUP BY` over a derived table refuses (the fold has to run
  above the leaf — a later slice); and a derived table with no alias
  refuses, because SQL requires the name.

`qa/serve-real-derived.sh` is new, 32 checks. 38 behaviour gates and 363
unit tests confirm nothing else moved.

## 2026-07-31 — R3: NestedLoopJoin is a node

### Converted
- **`RowSource::NestedLoopJoin`** — every left row against every right
  row, kept when the ON answers TRUE, with the KIND deciding what
  happens to a row that finds no partner. `join_rows` no longer folds:
  it **builds a left-deep tree** and pulls it.
- **Left-deep is the point.** `A JOIN B ... JOIN C ...` is `(A ⋈ B) ⋈ C`,
  so the second ON may name A or B and each step's kind applies to
  everything accumulated so far. The fold expressed that by carrying an
  accumulated width; the tree makes it **true by construction**, and the
  width is just where the right side's fields begin.
- **The WHERE is a `Filter` above the whole join, not inside a step** —
  a predicate pushed into a step would see a row before its outer
  padding existed. That was already true and is now structural.
- `TableScan` gained the stream's record **width**: a join side's rows
  are padded so the combined row's field offsets are the same for every
  row, matched or padded. The single-relation scans pass `None`.

The node's unit test decides the ON with a constant rather than
resolving one, because what has no analogue elsewhere is the KIND: with
a false ON an INNER join drops the row and a LEFT keeps it **padded to
the combined width** — which is the check that gives the width field a
reason to exist.

11 join gates green, 363 unit tests, no behaviour change.

## 2026-07-31 — R2: Aggregate is a node

### Converted
- **`RowSource::Aggregate`** — the engine's aggregated stream as a tree
  node: `input` folded into one row per distinct key, with HAVING
  filtering the FOLDED rows rather than the input ones. A query with no
  GROUP BY is the single global group, which is the same node with no
  keys.
- `group_output` now *builds* `TableScan → Filter → Aggregate` rather
  than spelling those three out, and both grouped emit paths build the
  full `… → Sort` above it. **The fold itself (`group_rows`) has exactly
  one caller now — the node.** Before this it had three.
- The grouped JOIN path composes the same nodes over a materialised
  leaf: `Rows(joined) → Aggregate → Sort`. That is the first place the
  tree is seen STACKING rather than replacing a single loop, and it is
  why the `Rows` leaf earned its place in R1.

**Where Sort sits is a claim, not a detail.** It goes ABOVE the
Aggregate, because a grouped query's ORDER BY keys are OUTPUT indexes
and the folded rows are aligned with `gitems`/`cols` — while a plain
projection's ORDER BY indexes the RECORD's fields, so there the Sort
goes BELOW the projection. Both facts were already true and each was
explained where it happened; the tree makes them structural.

No behaviour change, again the whole claim: 20 grouping-and-aggregate
gates and 363 unit tests, with the node's own unit test now folding
`Rows → Aggregate → Sort` over a fixture whose two keys have different
row counts.

## 2026-07-31 — R1: the row-source tree exists

The first increment of a PROGRAMME rather than a feature — see the new
[docs/roadmap.md](docs/roadmap.md), which says plainly where the project
stands: nine subsystems are converted, and **five of them
(`opt`, `cch`, `lck`, `evt`, `pio`) are not linked by the server at
all**. The optimizer picks access paths nothing executes; the lock
manager decodes a table it never enqueues into; every query is answered
by a full scan. Alongside that, the SQL layer answers views, CTEs and
constant subqueries by **rewriting SQL text**, where the engine builds a
tree of record sources.

### Converted
- **`RowSource`** — the engine's execution shape (`RecordSource`/rsb in
  `src/jrd/`) as a real tree: `TableScan`, `Filter`, `Sort`, and a
  materialised `Rows` leaf. The node set is deliberately the engine's,
  not a convenient one.
- The two places that hand-rolled scan-filter-sort — the ordinary fetch
  and `branch_rows` — now build a tree and pull it. **No behaviour
  change: that is the whole claim**, and 38 gates plus 363 unit tests are
  the proof.
- The sort stays INSIDE the tree, below the projection, because ORDER BY
  indexes the record's fields rather than the projection's. Both call
  sites had that right and each said so in its own words; now the tree
  says it once.

What is deliberately NOT here, named so the shape is not mistaken for
finished: `Aggregate`, `NestedLoopJoin`, `Union`, and an `IndexScan`
leaf — the last being what makes `fire-crab-opt`'s choices executable
instead of advisory.

The `Rows` leaf is not decoration: a derived table, a materialised CTE
and a recursive one all stand on it, and it is what lets the tree be
unit-tested without a database behind it — which is how the sort's
"orders by the key, not by the row order" check is written over a
fixture whose two fields disagree on every pair.

## 2026-07-31 — a `?` on the left of a comparison

### Converted
- **`WHERE ? < SALARY`.** A parameter bound on the LEFT of a comparison
  refused; only `SALARY > ?` worked. The engine describes the parameter
  from the OTHER side whichever way round it is written, so the leaf is
  now read from that side too: the sides SWAP and **the operator
  MIRRORS**.
- The mirroring is the whole point. Moving the operator instead of
  mirroring it — reading `? < S` as `S < ?` — answers a different set of
  rows and does it quietly, so the gate checks every ordering operator in
  both spellings, over a fixture where the two answers DIFFER.
- **A `?` is POSITIONAL**: its number is its place in the TEXT, not its
  place in the rewritten leaf. The slot is registered before the right
  side is parsed, so `WHERE ? < DP AND DP < ?` binds the client's two
  values in the order they were written.

`qa/serve-real-typedparams.sh` grows from 26 checks to 39, including a
left-side parameter beside a right-side one, two left-side ones, a text
column, and one in a DML WHERE with the table compared afterwards.

Probed and NOT converted, so it is not mistaken for covered: a `?` inside
an arithmetic operand (`WHERE SALARY > ? + 100`) and inside a CASE
condition still refuse — the expression parser has no parameter counter
to register a slot with, which is a different change from this one. A
lone `?` in a select list errors on BOTH servers, so that is agreement
rather than a gap.

## 2026-07-31 — one statement of "which side is which"

### Converted
- **A correlated `EXISTS` whose INNER table is aliased** — the refusal
  the previous increment named. `SELECT COUNT(*) FROM EMP E WHERE EXISTS
  (SELECT 1 FROM DEPT D WHERE D.ID = E.DEPT_ID)` is how the shape is
  normally written, and it refused while the SAME correlation worked
  through `IN`, through a scalar comparison and in the select list.

**The cause is worth more than the fix.** The EXISTS arm recovers the
outer column with a helper that carried its **own copy** of the
"which side of this equality is the inner one" rule — and that copy
compared a qualifier against the inner table's NAME only, never its
alias. The rule had been written three times: once in `eval_subquery`,
once in that helper, and once (extracted two increments ago) in
`split_correlation`. Two of the three learned about aliases; the third
did not, and it was the one that failed last.

The helper is now four lines that call `split_correlation`. A rule
stated twice is a rule that drifts; a rule stated three times drifts
twice, and the copies fail at different times, which is what makes the
symptom look like a different bug each time.

### Fixed
- `qa/gate-selfcheck.sh`'s squatter check conflated "the gate failed for
  the RIGHT reason" with "the gate failed" — a transient scratch-database
  failure inside the squatted gate read as the guard not firing. It now
  retries the setup once and reports the two cases differently.

`qa/serve-real-subqalias.sh` grows from 29 checks to 32; its two
refusals become comparisons, including the negated form and the shape
with an inner residual beside the correlation.

## 2026-07-31 — subqueries whose tables carry aliases

### Fixed
- **A rewrite reached into a nested query's SCOPE.** The pass that
  strips a table's qualifiers rewrote the WHOLE statement, including the
  text inside a subquery — and `(SELECT 1 FROM DEPT D WHERE D.ID =
  EMP.DEPT_ID)` names the OUTER table there on purpose. Stripping that
  qualifier left a bare `DEPT_ID`, which the inner table does not have
  (and in other shapes DOES have, meaning something else). A nested query
  is a different scope; the rewrite now copies such a span verbatim.
- **A subquery's own clauses may qualify by the INNER table's name or
  alias** (`SELECT D.ID FROM DEPT D WHERE D.ID > 1`) and its resolver
  looked those up unqualified. They come off AFTER the correlation split,
  which needs them to tell the two sides apart — an ordering the code now
  states, because reversing it silently changes which column the
  correlation names.
- Together these fix `IN`, `NOT IN`, a scalar subquery on the right of a
  comparison, and a subquery in the select list, in every combination of
  aliased and unaliased tables. That is how most people write them.

- **`NOT EXISTS` dropped the row whose key is NULL.** This one is a wrong
  answer, found by the new gate and PRE-EXISTING — unrelated to aliases,
  which is why both spellings failed. `NOT EXISTS` is a **two-valued**
  test on rows ("no inner row matches"), while the `NOT IN` it rewrites
  to is three-valued and answers UNKNOWN for a NULL left side. An outer
  key that is NULL matches nothing and therefore SATISFIES `NOT EXISTS`;
  fire-crab answered 0 where the engine answers 1. The rewrite now emits
  `(<key> IS NULL OR <key> NOT IN (...))`.
  - The code already handled the mirror case — inner NULLs are filtered
    out of the list — so half of the classic NOT IN / NOT EXISTS
    divergence was closed and the other half was not. A literal
    `NOT IN (SELECT ...)` still poisons on NULL, correctly, and the gate
    checks that too.

### Guarded
- A correlated `EXISTS` whose INNER table is aliased still refuses: the
  correlation split reads the alias, but something later in that one path
  resolves against the inner table's own name. It refuses rather than
  answering, the same correlation works through `IN`, through a scalar
  comparison and in the select list, and the gate names it as the next
  slice rather than leaving it to be rediscovered.

`qa/serve-real-subqalias.sh` is new, 29 checks, each shape run in its
unaliased spelling too — the aliases are the variable under test, so
everything else has to be identical.

## 2026-07-31 — the declared width of a numeric function

### Fixed
- **The engine announces a width PER FUNCTION, not BIGINT for every
  integer result.** fire-crab announced BIGINT throughout, so isql laid
  out a 20-wide column where the engine lays out 6. Probed with
  `SET SQLDA_DISPLAY ON`:
  - `SIGN` is **SHORT**, whatever its argument.
  - `CHAR_LENGTH`, `OCTET_LENGTH`, `POSITION` are **LONG**, always.
  - `MOD` keeps the **first operand's** own width.
  - `ABS` is **one step wider** than its source (SMALLINT→INTEGER,
    INTEGER→BIGINT).

### Corrected
- **The "standing deviation" the previous increment recorded was not
  one.** That gate softened a numeric check and blamed fire-crab's
  integer arithmetic for announcing BIGINT where the engine announces
  INTEGER. Probing it directly says otherwise: `ID + 1`, `S + S`,
  `ID * 2` and `ID + BG` all announce **INT64** on the engine too. The
  widening fire-crab does for arithmetic is exactly the engine's; the
  divergence was only ever in the FUNCTIONS. The softened check is
  restored in full.

`qa/serve-real-funcwidth.sh` grows from 32 checks to 48 and its fixture
gains SMALLINT and BIGINT columns, so a function's declared width can be
varied by its source.

**A note on how nearly this shipped unverified.** The new unit test did
not compile — `Wire` derived neither `Debug` nor `PartialEq`, which
`assert_eq!` needs — and `cargo build --release` still succeeded, because
the test module is `cfg(test)`. The greps that summarise "N tests passed"
matched nothing and printed an empty count, which reads like a pass at a
glance. This is the same silent-skip shape the playbook already records
for gates, in the unit-test path: a summary that can be EMPTY as well as
ZERO needs to distinguish the two.

## 2026-07-31 — the width of a text FUNCTION's result

### Fixed
- **A text function's result has a derived width, and fire-crab declared
  the catch-all 32765 for all of them.** The values agreed, so no driver
  twin could see it — but isql lays its columns out FROM THE DESCRIBE, so
  `SELECT UPPER(V) FROM T` printed a **32765-wide column** where the
  engine prints a 6-wide one, in the engine's own client.
- The rules, each probed with `SET SQLDA_DISPLAY ON`:
  - `UPPER`/`LOWER` keep the argument's FORM and width — so
    `UPPER(<CHAR(6)>)` is CHAR(6) and pads.
  - `TRIM` is VARYING at the argument's width.
  - `LEFT`/`RIGHT`/`REVERSE` take the **source's** width, not the count:
    `LEFT(V, 3)` over a VARCHAR(6) is VARYING(6).
  - `SUBSTRING` takes its literal FOR length, or the source's width when
    there is no FOR.
  - `LPAD`/`RPAD` take their pad length.
  - `a || b` is VARYING at the **sum** of the two widths.
- `REPLACE` is deliberately left unsized: its bound is some function of
  the search and replacement lengths, and one probe is not a law. It
  keeps the catch-all declaration and the gate says so.

`qa/serve-real-funcwidth.sh` is new, 32 checks, and it is the first gate
here to compare **isql's rendered output verbatim** — header and
separator included, because those lines ARE the width. A declared width
is not a value, so the usual driver twin cannot see it; the engine's own
tool can.

It also names a standing deviation rather than hiding it: fire-crab
computes integer arithmetic at full i64 and announces BIGINT where the
engine announces INTEGER, so an arithmetic column's isql layout differs
even though every value matches. That predates this increment, and the
gate's numeric check is a plain column with a comment explaining why.

## 2026-07-31 — the width and form of a text result

### Fixed
- **A conditional's text result is CHAR of its WIDEST branch, and is
  PADDED to it.** `CASE WHEN ... THEN 'other' ELSE 'isnull' END` answers
  `'other '`; fire-crab announced VARCHAR(32765) for every text
  expression and padded nothing, so it answered `'other'`. A wrong VALUE,
  not just a wrong describe. The previous increment found this and said
  so rather than encoding around it; this is the fix.
- The rules, probed with `SET SQLDA_DISPLAY ON`: a LITERAL is `CHAR(n)`;
  a conditional's WIDTH is the maximum over its branches; its FORM is
  VARYING if ANY branch is varying, else CHAR — and only a CHAR result
  pads. `COALESCE(NAME, 'zzzzzzzzzz')` is VARYING(10);
  `COALESCE('ab', 'cdef')` is CHAR(4).
- **The padding applies wherever the value is used, not only in a select
  list**: `CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END || 'X'` answers
  `'ab    X'`. So it is applied where the node is RESOLVED, and the
  padded value then flows into concatenations, comparisons and sort keys
  by itself. The gate found that — the first attempt padded only the
  top-level projection.
- It is applied by wrapping in the CAST that already implements padding
  (`CAST(x AS CHAR(n))`), rather than by a second implementation of the
  same law.

**Three unit tests had encoded the old, unpadded values** —
`CASE ... 'pos'/'neg'/'zero'` asserting `"neg"`, `IIF(..., 'long',
'short')` asserting `"long"`. They were the bug, written down and
protected. Each is now the engine's own answer, with a note saying why.

`qa/serve-real-textwidth2.sh` is new, 30 checks, every one over branches
of DIFFERENT widths so the padding is visible in the string itself. The
shapes this driver cannot decode from the engine (a CHAR column, several
text columns in one row) are compared against isql instead.

## 2026-07-31 — DECODE, and EXISTS as a value

### Converted
- **`DECODE(<subject>, <search>, <result>, ..., [<default>])`** — it IS a
  simple CASE (the engine compiles it to the same node), so it desugars
  to the searched form the parser already builds, one `=` comparison per
  pair. An ODD number of arguments after the subject ends with a
  DEFAULT; an even number has none, and no match answers NULL.
- **`EXISTS(SELECT ...)` as a select-list value**, folded to TRUE or
  FALSE at prepare through the same subquery lifting the select list
  already uses — it asks only whether a row survives.

**The law worth probing**, because it is the one a converter inherits
wrongly: **Firebird's DECODE does not match a NULL subject to a NULL
search value.** Oracle's does. Here the comparison is `=` and `NULL =
NULL` is UNKNOWN, so a NULL subject matches nothing and takes the
default — which the simple-CASE desugar gives for free, and which a
desugar written to Oracle's semantics would have got wrong.

**The other law is about names, not values**: DECODE compiles to a CASE
and is still described as **DECODE**, while a simple CASE is described as
CASE. The gate puts both in one select list, which is the only place the
difference shows — and the naming applies only when the whole item is the
call, since `DECODE(...) + 1` is an ADD like any other expression.

### Found, not fixed
- **A conditional's TEXT result takes the width of its WIDEST branch and
  is padded to it.** `CASE WHEN ... THEN 'other' ELSE 'isnull' END`
  describes as `CHAR(6)` (sqltype 452, len 6 — confirmed with
  `SET SQLDA_DISPLAY`) and answers `'other '`; fire-crab announces a
  VARCHAR and does not pad. This is **pre-existing** and belongs to plain
  CASE as much as to DECODE — both differ identically — so the new gate
  uses branches of EQUAL width and says why, rather than quietly encoding
  a known-wrong expectation. It is the next slice.

### Guarded
- DECODE inside a WHERE refuses: the predicate tokenizer spans a CASE by
  its balancing END and has no rule for a DECODE call, so the desugar the
  select list gets never reaches it. Named rather than left unexplained.

`qa/serve-real-decode.sh` is new, 29 checks.

## 2026-07-31 — WITH: a view that lives in the statement

### Converted
- **Common table expressions** — `WITH C AS (SELECT ...) SELECT ... FROM
  C`. A CTE is a VIEW that lives in the STATEMENT rather than the
  catalog: the same source text, the same column names, the same
  substitution into the FROM. So it is not a new mechanism — it is the
  view expansion with a different place to look the name up, and
  everything that expansion learned over several increments arrives with
  it at once: an alias on the FROM item, RENAMED columns, the CTE's own
  WHERE ANDed into the outer one, and a CTE as a side of a JOIN.
- Two things are specific to CTEs and are parsed here: the **column
  list** (`WITH C (A, B) AS ...`) renames positionally, which is what a
  view does through `RDB$RELATION_FIELDS` but written very differently;
  and a CTE **shadows** a table of the same name for its statement.
- `FIRST`, `SKIP` and `DISTINCT` sit BETWEEN `SELECT` and the select
  list, so the expansion cannot read the projection past them. They come
  off before the rewrite and go back on after, in the engine's own order.

### Guarded
- **A CTE name left in the FROM refuses.** If a CTE's body is one the
  view expansion cannot rewrite (a GROUP BY inside, a `SELECT *`, a join),
  its name stays in the FROM — where it names no relation at all, so
  falling through would reach the fixed-answer fallback and reply 4242 to
  a query over real tables. `WITH RECURSIVE` refuses too: it is a
  fixpoint, not a substitution.

`qa/serve-real-cte.sh` is new, 29 checks. Each has a view-shaped twin
that already passed — which is the point of the framing, and the reason
this cost one function rather than a subsystem.

## 2026-07-31 — a correlated subquery in the select list

### Converted
- **`SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID)
  FROM DEPT D`** — the refusal the previous increment recorded. A
  correlated subquery has no single value to fold into the text: it has
  one per outer row. So it is not folded, it is **precomputed as a
  LOOKUP TABLE** — the inner table is scanned once at prepare, its rows
  bucketed by the correlation column, each bucket folded into the one
  value that key answers, and each outer row then looks its own key up.
  A correlated aggregate IS a group keyed by the correlation column, so
  the fold is the same `compute_group` a GROUP BY runs.
- Covered: COUNT/MIN/MAX/SUM/AVG and a bare column; the inner table by
  name or alias; the equality either way round; a residual inner filter
  beside the correlation; several correlated items in one select list;
  an outer WHERE, an alias, and ORDER BY over the looked-up column.

**The law this turns on**: a key with NO matching inner rows is **not
always NULL**. `COUNT` answers 0 there and every other function answers
NULL — and both appear in the SAME ROW of one query, which is how the
fixture pins it: department 9 has no employees and answers `0` and
`<null>` side by side. A lookup defaulting to NULL is right for three of
the four functions and wrong for the one people use most.

### Fixed
- **The inner table's ALIAS is its qualifier.** `FROM EMP E ... WHERE
  E.DEPT_ID = D.ID` correlates through `E`, and the correlation split
  compared only the table NAME — so it found no correlation at all and
  every aliased correlated subquery refused, which is nearly all of them
  as people write them. This also widens the correlated EXISTS/IN path,
  which shares the split.
- **`SUM(E.SALARY)` parses as an EXPRESSION target**, not a column one —
  the dot stops it looking like an identifier — so the qualified
  spelling took a different path from `SUM(SALARY)` and refused while the
  bare one worked.

### Guarded
- A **non-equality** correlation (`WHERE E.SALARY > D.BUDGET`) refuses: a
  keyed table cannot express it, and the engine answers it by re-running
  the subquery per row. So does a GROUP BY inside the subquery.

`qa/serve-real-corrsubq.sh` is new, 27 checks. The two correlated
refusals `qa/serve-real-selectsubq.sh` recorded one increment ago are
promoted there from refusals to comparisons.

## 2026-07-31 — a subquery in the select list

### Converted
- **`SELECT ID, (SELECT COUNT(*) FROM D) FROM T`.** The WHERE clause has
  taken subqueries for many increments — lifted out of the text,
  evaluated, folded back in as ordinary tokens. The select list could not
  hold one at all. The conversion reuses that lifting: a subquery naming
  no outer column is a CONSTANT for the whole statement, so it is
  evaluated once and folded back into the query TEXT as the literal it
  computed, and the statement re-planned. Every select-list shape then
  works over it for free — an alias, arithmetic around it, a CASE, a
  CAST, COALESCE, a grouped query, ORDER BY, FIRST.
- Three laws, probed first: **no rows answers NULL**; **more than one row
  raises** "multiple rows in singleton select" (SQLSTATE 21000, the
  engine's own message, byte for byte); and the output column is named by
  the **subquery's own select item** — `(SELECT COUNT(*) ...)` describes
  as COUNT, `(SELECT ID ...)` as ID — not by the literal it folded to.

### Fixed
- **`SELECT 3 FROM T` refused.** An unquoted SQL identifier cannot start
  with a digit, but `ident_ok` accepted `"3"`, so a numeric literal in
  the select list was read as a COLUMN NAMED 3 and never found. `SELECT
  NULL` and `SELECT 'x'` worked, which is exactly what kept it hidden for
  so long — and a folded subquery lands precisely there, so the fold
  could not work until this did.
- **`SELECT -3` described as blank**; the engine names a negated LITERAL
  `CONSTANT` and only a negated column blank (probed). 

### Guarded
- A **correlated** subquery in the select list refuses. Its value differs
  per outer row, so folding it once for the statement would put one row's
  answer in every row — a wrong answer where a refusal is honest.

`qa/serve-real-selectsubq.sh` is new, 34 checks, comparing whole JSON
objects because half this increment is a naming law. The text-column case
is compared against isql rather than the twin: node-firebird cannot
decode the ENGINE's own answer for it.

## 2026-07-31 — an aggregate inside an expression

### Converted
- **`SUM(A) + 1`, `MAX(A) - MIN(A)`, `COUNT(*) * 2`, `CAST(SUM(A) AS
  VARCHAR(10))`, `CASE WHEN COUNT(*) > 2 THEN ...`.** The select list
  could hold an aggregate or an expression but never one INSIDE the
  other: an aggregate was a select-list ITEM while an expression is a
  TREE, and the tree had no leaf for a fold. Every such shape refused.
- The conversion is one idea: **an aggregate is a leaf with no value for
  a ROW, only for a GROUP.** Each one becomes a SLOT of the group row,
  and the surrounding expression is then an ordinary expression over that
  row — the same trick the join uses to run the ordinary expression
  resolver over a combined row. With no GROUP BY the query is the single
  global group, which is what makes `SELECT SUM(A) + 1 FROM T` one row.
- Two aggregates in one expression need two slots, and the second is a
  HIDDEN one appended past the output columns, so the group row is wider
  than the select list. A grouped KEY inside the expression
  (`DEPT_ID + SUM(SALARY)`) gets a slot too, though no output column
  selects it.

### Fixed
- **`ORDER BY` a COMPUTED output column** — by alias or by ordinal — used
  to refuse. A computed column has no field of its own to sort by, so its
  `field_id` is a placeholder and sorting by it would be wrong; the
  refusal was right *while nothing evaluated expression sort keys*, and
  wrong the moment the previous increment made `sort_rows` live. The key
  is now the column's OWN expression, on all three paths.
- A grouped `ORDER BY` reached its keys by pairing output columns with
  group-row slots, which cannot see a slot past the last output column —
  exactly the hidden slots this increment introduces. It indexes the
  group row directly now.

### Guarded
- `COUNT(DISTINCT c)` and an EXPRESSION argument (`SUM(A + 1)`) inside a
  folded aggregate refuse: their result type is not derived here, and a
  guessed type decodes as the wrong number rather than failing.

`qa/serve-real-aggexpr2.sh` is new, 45 checks. Its department 2 has one
employee, so `MAX - MIN` over it is 0 — the value a fold reading the
wrong slot is least likely to produce by accident — and its salaries do
not divide evenly by the row count, so `SUM/COUNT` shows the dialect-3
truncation (650/4 is 162, not 163).

**The bug worth naming**: a synthetic descriptor built for an aggregate's
slot defaulted its `offset` to 0, and `is_computed_fid` reads
`offset == 0 && length != 0` as "this is a COMPUTED column" — so every
expression naming that slot refused. It was invisible for MIN and MAX,
which clone the SOURCE column's descriptor and inherit its real offset,
and failed for SUM, AVG and COUNT, which build a fresh one. A field whose
zero value means something else is a field you cannot default.

## 2026-07-31 — the rest of the SELECT, over a join

### Converted
- **EXPRESSIONS in a join's select list.** The join had projections, a
  WHERE, ON predicates, chains, GROUP BY and aggregates — and a select
  list that took BARE COLUMNS AND NOTHING ELSE. `SELECT E.SALARY + 1
  FROM ... JOIN ...` refused, and so did every CASE, CAST, function,
  COALESCE, IIF and condition-as-value. The combined view (a join's rows
  seen as one synthetic relation) already existed for the ON resolver, so
  the ordinary `build_expr_col` runs over it unchanged.
- **`DISTINCT`, `FIRST`, `SKIP` and `ROWS` over a join**, including over
  a grouped join and a join through a view. `branch_rows` is what
  materialises rows for those wrappers and it knew Project, Union and
  ProcRows; teaching it Join and JoinGroup gave `INSERT ... SELECT` and
  `FOR SELECT` the same sources at the same time.
- **`ORDER BY <expression>` over a join** — arithmetic, a CASE, a
  function, an expression spanning both sides, alone or beside a column
  key, and composing with FIRST and DISTINCT.

### Fixed
- **An expression sort key was accepted and then IGNORED.** `sort_rows`
  — the sort that EVALUATES a key's expression — existed in this file
  with NO CALLERS. `Plan::Join`, `Plan::JoinGroup` and `Plan::Group` all
  sorted with `order_cmp`, which reads a key's FIELD and ignores its
  expression, so the moment the join accepted `ORDER BY E.SALARY + 0` it
  sorted by field 0 instead. Wiring the ORDER BY parser up without this
  would have turned a refusal into a wrong answer, which is the worse of
  the two.

None of these are join FEATURES: each is a capability the single-relation
path has had for increments and the join path never learned. That is the
failure shape this project keeps meeting, and it is why
`qa/serve-real-joinexpr.sh` (new, 46 checks) is organised by CAPABILITY
rather than by join shape — every check has a single-table twin, and
those twins are re-run in the same file so a fix on one path cannot
quietly break the other.

The fixture's lowest salary belongs to its highest id, so every
expression sort puts that row where the natural row order never would —
a sort that ignored the expression answers the id order, visibly.

## 2026-07-31 — a view's columns keep the view's names

### Fixed
- **A view with RENAMED columns answered under the BASE table's names.**
  `SELECT EID FROM VREN` returned the right value in a column called ID.
  Every value was right and every NAME was wrong — and a driver builds
  its row objects from those names, so `row.EID` was undefined. The
  sharpest case is a view that SWAPS two names (`SELECT NAME AS ID, ID AS
  NAME`): the values then land on each other's names, so `row.ID` is a
  number on one server and a string on the other. Rewriting a view's
  column to its base's is only half the job; the select list has to alias
  the view's name back on, because that name is the whole contract.
- **`SELECT E.ID FROM EMP E` refused.** The join resolver has always
  understood qualified names — it must, since that is the only way to say
  which side you mean — but the single-relation path never did. So
  qualifying a column in a one-table query, which is ordinary SQL and
  also what the view rewrite produces, was an error: in the select list,
  the WHERE, GROUP BY, HAVING and ORDER BY alike. A qualifier naming
  THIS relation is now stripped and the statement re-planned; one naming
  anything else is left alone, since a correlated subquery names its
  outer table that way.
- **An ALIAS on a joined column was dropped**, and that was not only a
  wrong name: `SELECT E.ID AS EMPID, D.ID AS DEPTID` produced two output
  columns both called ID, and a driver keying its rows by name kept one
  of them. Two columns asked for, one column delivered.
- **A grouped key now answers to BOTH names.** `SELECT DEPT_ID AS D2 ...
  GROUP BY DEPT_ID ORDER BY DEPT_ID` sorts by the key, which the engine
  allows. It looks exotic written by hand and is exactly what a renamed
  view produces once expanded.

### Converted
- **A view with renamed columns may now be a SIDE OF A JOIN** — the
  refusal `qa/serve-real-viewjoin.sh` recorded one increment ago. The
  reference is rewritten under its QUALIFIER (`V.DID` → `V.DEPT_ID`),
  which is what keeps two sides apart, and the select list aliases the
  view's name back on.

### Guarded
- **A BARE reference to a renamed view column inside a join refuses.**
  With more than one side in scope the same word can be this view's
  renamed column and another table's real one, and only the qualifier
  says which. The engine resolves it; guessing a side would be a wrong
  answer, so this is a refusal with a reason rather than a gap.

`qa/serve-real-viewrename.sh` is new, 46 checks. It compares the whole
JSON — KEYS included — because every bug in this increment was visible
only in the keys: the values were right throughout.

## 2026-07-31 — the gates that measured nothing

### Fixed
- **Eleven gates defaulted to port 3050 — the real engine's own.** Every
  differential here starts `fcwire` on a port, waits for the port to
  answer with `nc -z`, then runs its checks. But `nc` answers "SOMETHING
  is listening", which is not the question: when the port was already
  taken, fcwire exited at bind with `Address already in use` and `nc`
  succeeded anyway — against the OTHER server. Since the other server on
  a machine running these gates is the engine, a twin gate then compared
  **the engine with itself** and passed. Perfectly, every time.
- That is the worst failure a differential has — not a wrong answer but a
  green run that measured nothing — and it had already produced a wrong
  conclusion: yesterday's slice reported a "pre-existing VARCHAR
  length-metadata bug" in `qa/serve-real-{project,join}.sh`. There is no
  such bug. Both gates were talking to the engine, and the truncation was
  node-firebird mis-decoding the ENGINE's own answer, a limit this
  project had already documented. Run on their own ports, both are green.
- Each of the eleven now has its own default port, and **every one of the
  149 gates that starts a server now asserts the server is running**
  (`kill -0 $srv`) after the readiness probe, so a failed bind is fatal
  instead of invisible.
- **Five gates carried a `#!/bin/sh` shebang while using bash-only
  syntax**, so running them the way their own headers say failed at
  parse. Same lost coverage by another route.

### Converted
- **`qa/mktypesdb.sh`** builds the wiretypes scratch database, and
  `qa/serve-real-types.sh` runs for the first time — 10 checks green. It
  is the gate for the one thing only a typed client can see: that
  fire-crab describes and encodes each type in the engine's own wire form
  (SMALLINT natively rather than widened, scaled numerics as raw integers
  with the scale in the DESCRIBE, IEEE floats, raw temporal units,
  BOOLEAN as an XDR int slot). Like the join gates before `qa/mkjoindb.sh`,
  it had been unrunnable for want of a database that lived nowhere. Its
  values are picked against the canonicalisation rules the two sides
  force: SMALLINT at both extremes (a widened type still round-trips, so
  only the extremes prove the describe), BIGINT inside 2^53 (or the gate
  measures the driver), no scaled value ending in a zero decimal digit,
  floats exactly representable in binary, DATE including **1858-11-17**
  (the MJD epoch — the value an off-by-one in the day conversion cannot
  hide in), and no midnight time or 1970-01-01 timestamp, both of which
  the gate's formatter reads as type sentinels.

### Guarded
- **`qa/gate-selfcheck.sh`** is new: the gate that checks the gates. Five
  properties — no gate's own server defaults to the engine's port, every
  server start is guarded, default ports are distinct, every gate parses
  under its own shebang, and the one with teeth: it starts a squatter on
  a gate's port, runs that gate for real, and requires a non-zero exit
  with a spoken reason. A guard that is present and does not work looks
  exactly like a guard that works, until the day it matters.

## 2026-07-30 — a view as a side of a join

### Converted
- **A VIEW may now stand on either side of a JOIN** — the last gap in
  the FROM clause. A view standing alone was already expanded (its name
  swapped for its base table, its own WHERE ANDed into the outer one);
  with a second table present that rewrite is wrong twice over, and both
  corrections are the increment:
  - **Where the view's predicate goes depends on whether that side can be
    NULL-PADDED.** `DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID` must keep
    every department. Push the view's `SALARY > 150` into the outer WHERE
    and the padded row — whose SALARY is NULL — is thrown away, and the
    LEFT join has quietly become an inner one. The predicate belongs in
    that step's ON, which filters the view's rows BEFORE the padding.
  - **An unaliased view still owns its name as a qualifier**: in
    `FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID` the ON says VEMP, so
    the base table takes the VIEW's name as its alias and the
    substitution happens in TABLE POSITION ONLY (`replace_table_ref`). A
    rewrite that also renamed the qualifier produced `EMP VEMP.DEPT_ID`.
- Both sides may be views, a view may appear in a three-table chain, in
  a CROSS join and in a comma list, and the rewritten query flows on into
  WHERE, GROUP BY, HAVING, ORDER BY and the aggregates unchanged.

### Guarded
- **A view the server cannot expand answered ZERO ROWS instead of
  refusing** whenever it was not the FIRST table of the FROM. A view is a
  relation with a relation id and no records of its own, so an
  unexpanded one scans its empty storage: `DEPT D RIGHT JOIN VEMP V`
  answered `COUNT = 0` where the engine answers 3, and a FULL join
  answered 4. The refusal guard checked only the base table; it now
  checks every side. This is the failure shape the project keeps
  meeting — the wrong answer that looks like a legitimate empty result.
- Three shapes refuse for stated reasons rather than by omission: a view
  with RENAMED columns (every reference would need rewriting, not the
  table name), a view over a JOIN (no single base table to become), and
  a RIGHT or FULL join with any view (it makes an EARLIER side nullable,
  so which side a predicate belongs to stops being a local question).

`qa/serve-real-viewjoin.sh` is new, 32 checks. Its fixture is built so
that department 3's only employee is BELOW the view's threshold — that
row is what tells the two predicate placements apart, and a fixture
where every department either qualifies or is empty would have passed
either way.

## 2026-07-30 — the values an UPDATE could compute but not store

### Fixed
- **`UPDATE T SET FLAG = (A > 5)` answered "expression type cannot be
  stored".** The SET path evaluates its expression per row and then maps
  the result to a wire value — and that mapping was a list of value
  shapes written before the expression surface learned booleans, the
  temporal types and INT128. Everything computed correctly and then had
  nowhere to go.
- A condition IS a value in Firebird, so filling a boolean column from
  one is the ordinary way to write it: `SET FLAG = (A > 5)`,
  `SET FLAG = NOT FLAG`, `SET FLAG = (A IS NULL)`, `SET FLAG = (S LIKE
  'a%')`. Dates and timestamps store from arithmetic and from a CAST the
  same way.

`qa/serve-real-setexpr.sh` grew from 26 checks to 35, and its fixture
gained a BOOLEAN and a DATE column — the two families it could not
exercise before. It compares the TABLE after every statement, read back
by the engine, which is what makes a wrongly encoded value visible at
all.

## 2026-07-30 — NATURAL JOIN: a condition made of names

### Converted
- **`NATURAL [LEFT|RIGHT|FULL [OUTER]] JOIN`** — the last shape the FROM
  clause refused. It has no ON: the condition is DERIVED from the column
  names the two sides share, one equality per shared name. Sharing
  nothing makes it a cross join (probed).
- **The shared columns become ONE column.** A bare `K` after a natural
  join is not ambiguous — it means the merged column — while `NR.K`
  still reaches the other side's copy, which is what the engine allows.
  `SELECT *` emits the pair once.
- **In an OUTER natural join the merged column shows whichever side has
  a value.** `NATURAL RIGHT JOIN` preserves the right, so a padded left
  would show NULL for a column the right has a value for; the engine
  shows the value, so the star projection builds those columns as a
  COALESCE of the two sources.

The FROM clause now answers every join shape the engine has except a
join over a VIEW: inner and the three outer kinds, chains of any length,
CROSS, comma lists, and NATURAL — with the ON generalised to a predicate
two increments ago.

`qa/serve-real-joinchain.sh` grew from 24 checks to 33, and
`qa/mkjoindb.sh` gained two tables built for this: they share K and G by
name, only one pair agrees on both, and a row whose shared columns are
NULL never joins — because NULL = NULL is UNKNOWN, which is the rule a
derived condition inherits rather than restates.

## 2026-07-30 — CROSS JOIN, comma lists, and where an item's ON can look

### Converted
- **`CROSS JOIN`** and **`FROM a, b, c`** — the two spellings of the same
  thing, and with the chain in place both are just a step whose ON keeps
  every pair. `FROM a, b WHERE a.k = b.k` is then the old-style join it
  has always been, computed the same way as the ON form.
- Either spelling composes with the rest of a chain: a CROSS before an
  ON-join, after one, and a comma item that is itself a join.

### Guarded
- **An item's ON may only name tables within that item.** `FROM A, B
  JOIN C ON C.x = A.x` is an error on the engine — the join binds
  tighter than the comma, so A is not in scope — and fire-crab answered
  it, having flattened the list into one chain where every later ON saw
  everything. Each step now carries the index of the first side visible
  to it, and a comma item's steps start at that item's own base.
- **`NATURAL JOIN` refuses.** It joins on every SHARED COLUMN NAME and
  then collapses those columns into one — a rule about names rather than
  a condition, and not one this server answers.

`qa/serve-real-joinchain.sh` grew from 15 checks to 24. One more of
`qa/serve-real-outerjoin.sh`'s checks changed verdict: its CROSS JOIN
case has now been a fixed scalar, then a refusal, and now a comparison —
the property it defends (never wrong rows) has not moved once.

## 2026-07-30 — a CHAIN of joins: three tables and more

### Converted
- **`FROM a JOIN b ON ... JOIN c ON ...`** — the FROM clause refused a
  second JOIN outright. It parses into one step per join now, and the
  rows are FOLDED: each step joins everything accumulated so far with
  the next table.
- **A step's ON may name any earlier table.** `A JOIN B ON ... JOIN C ON
  B.Y = C.Y` resolves the second condition against A, B and C together,
  which is what makes a chain different from two independent joins.
- **Each step's KIND applies to the accumulation**, so `LEFT JOIN` in
  the middle of a chain pads what came before it — and the padded rows'
  columns are NULL, so an INNER step after a LEFT one drops them again.
  Every kind combination has a different row count and the gate compares
  all of them.
- Projections, WHERE, GROUP BY/HAVING, ORDER BY and the aggregates all
  work over a chain, because they were already written against the
  combined row.

### Fixed
- **A side's offset in the combined row was the FIRST side's width**,
  not the sum of every previous one. Right for two tables and silently
  wrong for three: the third table's columns landed on top of the
  second's, so every three-table inner join returned no rows while the
  outer variants quietly padded.

`qa/serve-real-joinchain.sh` (15 checks) and `qa/mkjoindb.sh` gained a
REGION table whose row 50 no department references, so the chain's
second step has something of its own to drop. The gate's centre is a
table of row COUNTS: INNER/INNER, INNER/LEFT, LEFT/INNER, LEFT/LEFT and
a RIGHT second step all differ, and a mis-folded chain lands on the
wrong one.

## 2026-07-30 — the ON clause is a predicate, not a list of pairs

### Converted
- **`ON` beyond equality**: `ON A.K > C.K` (a theta join), `<>`, `>=`,
  an `AND` mixing operators, and an `OR` in the ON. All refused before.
- **`ON` over any column family** — NUMERIC, DATE, DOUBLE, BOOLEAN —
  where it accepted only INTEGER and TEXT keys.
- The ON is now resolved by the SAME code the WHERE clause uses and
  evaluated over the concatenated row, instead of being a list of
  `(left index, right index)` equality pairs. NULL semantics come out
  unchanged for free: a comparison with NULL is UNKNOWN, `matches`
  answers false, and an unmatched row is padded by an outer join exactly
  as before.

### Fixed
- **A join's evaluation errors were collected and dropped.** `join_rows`
  accumulated an error from the WHERE into a local and returned the rows
  it had computed anyway — a wrong answer with no error attached. It
  returns a `Result` now, and the ON's errors travel the same way.

### Guarded
- A `?` in an ON refuses: the parameter would have to bind before the
  join runs, and this server has no path for that.

`qa/serve-real-jointypes.sh` grew from 20 checks to 28, with the new
operators alongside the equi-join they generalise, and both halves of
the NULL-key rule — an inner join drops the row, an outer join pads it.

## 2026-07-30 — the other half of the condition/value duality

### Converted
- **`LIKE` as a VALUE** — `SELECT NAME LIKE 'a%'`, `NOT LIKE`, with
  `ESCAPE`, inside a `CASE` condition and under `AND`/`NOT`. It was the
  one predicate form the condition-as-a-value slice left out, because
  `RawCond`/`Cond2` had no LIKE leaf to put it in.
- **A CONDITION as a comparison SIDE** — `WHERE (ID > 2) = TRUE`,
  `(B = TRUE) = TRUE`, `(NAME LIKE 'a%') = TRUE`. If a predicate is a
  value, a comparison between two of them is just a comparison. The
  predicate tokenizer now looks past a parenthesised group: followed by
  a comparison operator it is an OPERAND and lexes as one expression;
  followed by anything else it stays the sub-predicate it always was.

### Fixed
- **`SELECT CASE ... ELSE LOWER(S) END` refused.** The bare trailing
  alias added two increments ago split it at the last space and read
  `END` as the alias, leaving a CASE with no END. The rule guarded
  keywords at the end of the HEAD (`NOT B`, `B AND C`) but not the TAIL,
  which is where this one is. Caught by an existing gate.

### Guarded
- `qa/serve-real-boolvalue.sh` now COUNTS the checks it ran and fails if
  fewer than expected. Adding this slice's checks with a mistyped helper
  name made eight of them vanish — a shell "command not found" does not
  touch the failure flag, so the gate reported success while doing less
  work than it claimed. A gate that can silently skip is a gate that can
  silently pass.

`qa/serve-real-boolvalue.sh` grew from 33 checks to 51.

## 2026-07-30 — aggregates and GROUP BY over a JOIN

### Converted
- **`SELECT SUM(E.SALARY) FROM EMP E JOIN DEPT D ON ...`** and the
  grouped form — `GROUP BY`, `HAVING`, `ORDER BY` over the groups, on an
  INNER or an OUTER join. Only a lone `COUNT(*)` worked before; every
  other aggregate shape refused.
- The fold is the SAME machinery a single relation's grouping uses.
  `group_output` split into a scan and a `group_rows` fold, and the
  select-list item rules (a bare column must be a group key, an
  expression item must BE one of the expression keys, an aggregate's
  output type follows its function and source) came out as
  `build_group_items`. Only the INPUT differs: `join_rows` produces what
  the scan produced there.
- **The combined view now carries QUALIFIED names too.** That is what
  lets a grouped join name `D.ID` when BOTH sides have an ID — the bare
  name is ambiguous and dropped, so only the qualified spelling can mean
  one of them. A qualified key describes by its column name with the
  qualifier dropped, as the engine does.
- Along the way: `GROUP BY D.ID` (a qualified key, which the group
  parser read as an expression), and `SUM(E.SALARY)` (a qualified
  aggregate argument, which the item parser read as an expression
  argument because a dotted name is not an identifier).

`qa/serve-real-joingroup.sh` (18 checks) runs against the same scratch
database, where the three employees with no department and the
department with no employees are what tell an inner fold from an outer
one: `GROUP BY D.ID` over a LEFT join has a NULL group of exactly those
three, and `COUNT(D.ID)` over it counts 97 where `COUNT(*)` counts 100.

Five of the gate's own first-draft checks were wrong rather than the
server: two selected two columns both titled COUNT (this driver keys a
row by name, so one clobbered the other), one grouped by a name that is
a column of BOTH tables, and two ordered the reference query by
something other than the key the data was grouped on. Worth recording
because each looked exactly like a server bug until read closely.

## 2026-07-30 — the join gates, restored and what they found

### Fixed
- **Five gates had no database to run against.** `qa/serve-real-{join,
  outerjoin,project,insert,syscat}.sh` were written against a "join
  scratch db" that existed in one workspace and nowhere else, so they had
  been failing for want of it. `qa/mkjoindb.sh` builds it from a script -
  DEPT with a department no employee references, EMP with NULL and
  DANGLING department keys, and CHAR/VARCHAR key tables with duplicates
  and NULLs - and gbak-restores the clean copy the gates want. A gate
  nobody can run is a gate that stops telling the truth.

### Converted
Everything below was found by those gates within minutes of their
running again.

- **`FROM EMP AS E`** — the keyword form of a table alias, which the FROM
  parser accepted only as `FROM EMP E`.
- **`ORDER BY E.ID`** — a QUALIFIED name as a sort key. The parser
  classified anything containing a dot as an expression, and a join's
  expression resolver is `|_| None`, so every aliased join with an
  ordered result refused.
- **A join whose WHERE names a NUMERIC, DATE, DOUBLE or BOOLEAN column.**
  The single-table resolver learned those families over several
  increments; the join resolver still classified its columns through
  `col_kind`, which answers Int or Text and nothing else. So a join was
  not "broken for NUMERIC columns" but broken for any QUERY whose WHERE
  mentioned one — and a NUMERIC salary in the new fixture hid a
  perfectly working join until the column was made an INTEGER to match
  what the gates expected.
- The same for a QUALIFIED such column (`WHERE A.D > DATE'2020-01-01'`),
  whose literal makes the term an expression comparison and so takes a
  different branch — one that resolves against a combined view holding
  only BARE names.

### Guarded
- `qa/serve-real-outerjoin.sh` asserted that a CROSS JOIN answers the
  fixed scalar 4242. A later increment made unplannable queries RAISE
  instead, on the grounds that a made-up row is worse than an error, so
  the check now asserts the refusal. Same property, different expression.

`qa/serve-real-jointypes.sh` (20 checks, twin servers) covers the typed
columns directly, deliberately dully: each check is a join that works
with a WHERE naming one column of one family, bare and qualified, so
what it measures is the ROUTING and not the comparison rules, which have
their own gates.

## 2026-07-30 — column aliases in the select list

### Converted
- **`SELECT NAME AS X`** and the bare form **`SELECT NAME X`**, on a
  plain column, an expression, an aggregate and a grouped column. A
  quoted alias keeps its case; an unquoted one folds up, the way every
  unquoted identifier does.
- **`ORDER BY <alias>`** and **`GROUP BY <alias>`** — the engine
  resolves an alias in both, and a real column of that name wins over
  one, which is what makes a shadowing alias harmless.
- Two items over the SAME column with different aliases are TWO output
  columns.

### Fixed
- **The alias was dropped for the item type where it is most often
  written.** A plain column described as its own name — the parser even
  said so in a comment — `SELECT NAME X` refused outright, and
  `SELECT COUNT(*) AS N` refused because the alias was split off AFTER
  the aggregate parser had already failed on the whole text. Expressions
  honoured their aliases, which is what made the gap easy to miss: the
  shape people reach for first was the shape that worked.

`qa/serve-real-colalias.sh` (30 checks, twin servers). Nothing in it
compares values — every check compares the KEYS of the returned objects,
which is what a driver builds from the describe.

Two traps, both caught by existing gates rather than the new one. A bare
trailing alias must not swallow an OPERAND: `NOT B` is one item whose
last token only looks like a name, and so is `B AND C`; the rule now
refuses to split when the head ends in an operator keyword. And
`TRUE`/`FALSE`/`UNKNOWN`/`NULL` look like identifiers but are LITERALS,
so they must not take the column path — aliased or not.

## 2026-07-30 — a CONDITION used as a VALUE

### Converted
- **`SELECT B AND C`, `SELECT ID > 2`** — in Firebird every predicate is
  also an expression of type BOOLEAN, so the two grammars this server
  keeps apart (the WHERE parser and the select-list expression parser)
  meet in the select list. Comparisons, `AND`/`OR`/`NOT`, `IS [NOT]
  NULL`, `BETWEEN`, `IN`, parenthesised and nested — as select-list
  items, as `ORDER BY` and `GROUP BY` keys, and anywhere else an
  expression goes.
- **The fold is Kleene's, and only a VALUE can show it.** `FALSE AND
  UNKNOWN` is FALSE and `TRUE OR UNKNOWN` is TRUE — a decided dominant
  value wins over the unknown one. A WHERE clause collapses false and
  unknown into "row excluded", so none of that is visible until the
  condition is a value; every check in the new gate reads the value.
- **`BETWEEN` and `IN` in the condition grammar**, desugared into
  comparisons the way the predicate grammar already does — so `CASE WHEN
  ID BETWEEN 2 AND 3` and `IIF(ID IN (1, 4), ...)` work now too.
- **A bare boolean column is a condition** there as well: `CASE WHEN B
  THEN ...`, `IIF(B, ...)`.
- Every boolean-valued expression describes as **BOOL** — `B AND C`,
  `ID > 2`, `NOT B`, `B IS NULL`, `ID BETWEEN 1 AND 2`, `ID IN (1, 2)`
  (probed). A bare column keeps its own name, which it does by never
  becoming a condition in the select list.

### Fixed
- **`CASE WHEN NAME THEN ...` answered 0 for every row.** The condition
  resolver built the comparison without the side typing the predicate
  resolver applies, so a Text-against-Bool comparison fell to
  `value_cmp`'s rendered-text last resort and quietly compared `"aa"`
  with `"true"`. The engine raises `Invalid usage of boolean
  expression`; both resolvers now run the same `cmp_sides` check, which
  also gives `CASE`/`IIF` conditions the temporal and approximate typing
  rules the WHERE clause already had.

`qa/serve-real-boolvalue.sh` (33 checks, twin servers). Its fixture has
one `(NULL, FALSE)` row and one `(TRUE, NULL)` row, one for each half of
the Kleene rule: an implementation that answered NULL whenever an operand
was NULL fails the first, and one that answered FALSE fails the second.

## 2026-07-30 — BOOLEAN, the type that is also a predicate

### Converted
- **Boolean literals as VALUES**: `INSERT ... VALUES (TRUE)`, `UPDATE
  SET B = FALSE`, `SELECT TRUE`. This was the gap keeping
  `qa/serve-real-params.sh` red for dozens of increments — the LITERAL,
  not the parameter.
- **Boolean columns as PREDICATES.** `WHERE B` is a complete WHERE
  clause; so are `WHERE B AND C`, `WHERE NOT B` and `WHERE (B OR C) AND
  ID > 1`. A bare column means `B = TRUE`, which is why the NULL rows
  drop — and drop under `NOT` as well.
- **`IS [NOT] TRUE|FALSE|UNKNOWN`.** `IS TRUE` and `IS FALSE` are
  TWO-valued (a NULL is simply not true), so they desugar to `=`. Their
  negations are NOT the negated comparison: `B IS NOT TRUE` RETURNS the
  NULL rows where `B <> TRUE` and `NOT (B = TRUE)` both drop them, so it
  desugars to the explicit `IS NULL OR <>`, exactly as `IS DISTINCT
  FROM` does. `IS UNKNOWN` is `IS NULL` by another name.
- Comparison against another boolean column, `IN`, a boolean answer from
  a subquery, `ORDER BY`, `GROUP BY`, and `MIN`/`MAX`/`COUNT` over one.

### Guarded
- **A number is not a boolean.** `B = 1` raises a conversion error on
  the engine, so it refuses here rather than answering. A string DOES
  convert (`B = 'TRUE'`, case-insensitively).
- A bare non-boolean column is not a predicate: `WHERE NAME` refuses on
  both servers.

### Fixed
- **Two gates that had been red for dozens of increments**, both for the
  same reason and neither of them fire-crab's fault beyond the missing
  literal. `qa/serve-real-params.sh` and `qa/serve-real-ddl.sh` each sent
  a JS `true` as a BOOLEAN parameter — an encoding node-firebird cannot
  produce, and one the REAL ENGINE rejects with `Conversion error from
  string "1"`. Their expectations asked fire-crab to out-do the engine.
  Both now pass a boolean LITERAL where the value is needed and assert
  the parameter's refusal on BOTH servers, which is what that fact
  actually is.

`qa/serve-real-boolean.sh` (46 checks, twin servers). Its centre is the
run of predicates that differ only on the NULL row — `IS TRUE`, `IS NOT
TRUE`, `<> TRUE`, `NOT (= TRUE)` — kept side by side so the difference
shows as a row count rather than an error.

## 2026-07-30 — `?` parameters over the temporal and approximate families

### Converted
- **A `?` against a DATE, TIME, TIMESTAMP, FLOAT or DOUBLE side.**
  `WHERE D = ?`, `WHERE DP > ?`, `BETWEEN ? AND ?`, a parameter against
  approximate arithmetic (`WHERE DP * 2 > ?`) and against an expression
  (`WHERE D + 1 > ?`), in a SELECT and in a DML.
- Two halves had to agree. The **describe** now announces the slot's own
  type — SQL_DATE, SQL_TIME, TIMESTAMP, DOUBLE — because the client
  builds its encoder from it, so a wrong announcement does not produce a
  wrong answer but a wrongly ENCODED message. The **bind** turns the
  arrived value into a literal EXPRESSION rather than one of the exact
  `Rhs` shapes, which a DATE or a DOUBLE is not; the bound term is then
  the same three-valued comparison a written-out literal produces, and
  the gate checks the two select the same rows.
- An exact value arriving for an approximate slot converts (a driver may
  send `1` where a DOUBLE was announced), and a NULL parameter is
  UNKNOWN rather than an error, as before.

### Guarded
- **A TIMESTAMP value for a TIME slot refuses.** The input BLR is
  VALUE-derived, not descriptor-derived: node-firebird sends any JS Date
  as `blr_timestamp` whatever the describe said. Against a DATE column
  that is harmless — a DATE reads as midnight against a TIMESTAMP — but
  against a TIME column the engine promotes the TIME with the CURRENT
  DATE (probed: every stored row then sorts above a 1970 timestamp), and
  reading the timestamp's time half instead would answer a different set
  of rows with no error anywhere. A driver that honours the announced
  descriptor and sends a real TIME binds normally.

`qa/serve-real-typedparams.sh` (26 checks, twin servers on identical
databases), which also runs each parameter form beside its written-out
literal on the same server: a bind that lands the value in the wrong
shape shows up there even when both servers agree with each other.

## 2026-07-30 — approximate ARITHMETIC, and the literal that makes one

### Converted
- **Arithmetic over FLOAT and DOUBLE**: `DP * 2`, `DP / 3`, `DP + N`,
  `I / DP`, nested and parenthesised, in a WHERE, under an aggregate, as
  a GROUP BY key, in ORDER BY, in a subquery's value and on the right of
  a SET. `Expr::Bin` had arms for integers, exact numerics and the
  temporal types and nothing for this family.
- **ONE approximate operand makes the whole result approximate** — the
  engine's descriptor promotion. `DP + N` is a DOUBLE, not a
  NUMERIC(9,2), and there is no scale to carry.
- **An EXPONENT makes a literal approximate**, whatever the digits look
  like: `1e3` is a DOUBLE 1000, not the integer, and `1.5e0` is a DOUBLE
  where a bare `1.5` is an exact NUMERIC. Both lexers learned it — the
  select list's character parser and the predicate tokenizer — because
  either one alone would make the same literal mean two things.

### Guarded
- **The engine RAISES on float division by zero and on overflow.** It
  does not answer an IEEE infinity or a NaN, so a value there would be a
  wrong answer rather than a lenient one: new `EvalErr::FloatDivideByZero`
  (`isc_exception_float_divide_by_zero`) and `EvalErr::FloatOverflow`
  (`isc_exception_float_overflow`), each with its own gds code. The
  integer divide-by-zero shares SQLSTATE 22012 but is a different code
  with different text, and the gate checks the two do not collapse into
  one.
- A NULL operand is still NULL, never a division error — the NULL check
  runs before the divisor is looked at.

`qa/serve-real-approxmath.sh` (39 checks, twin servers). Every arithmetic
result is concatenated into TEXT before comparing, so the check sees the
engine's own rendering: an exact 11.75 and an approximate
11.75000000000000 are the same number to a driver that decodes both into
a JS number, and the promotion is only visible in the digits.

## 2026-07-30 — CAST's target list, and how an approximate number PRINTS

### Converted
- **`CAST(<expr> AS <type>)` across the whole target list**: `NUMERIC(p,
  s)` / `DECIMAL(p, s)` (including a precision past 18, which stores and
  announces as INT128), `FLOAT` / `DOUBLE PRECISION`, `DATE`, `TIME` and
  `TIMESTAMP` — alongside the integer and CHAR/VARCHAR targets that were
  already there. Conversions in every direction the engine allows,
  nested, in a WHERE, and inside an aggregate.
- The rounding is the engine's: **HALF AWAY FROM ZERO**, at the declared
  scale. `CAST(12.55 AS NUMERIC(9,1))` is 12.6 and `-12.55` is `-12.6`;
  `CAST(2.5 AS INTEGER)` is 3 and `CAST(-2.5 AS INTEGER)` is -3.
  Truncation and banker's rounding each answer one of those differently
  and neither raises.

### Fixed
- **An approximate value printed as the wrong STRING.** The engine
  renders a DOUBLE at 16 significant digits and a FLOAT at 8, trailing
  zeros kept, scientific outside the fixed range — C's `%#.16g` /
  `%#.8g`. Rust's default float formatting prints the shortest
  round-tripping form, `1.5` where the engine writes
  `1.500000000000000`: the same number, a different string, and this
  text is what `CAST ... AS VARCHAR` and `||` both produce.
- **FLOAT needed its own `Value` variant to say so.** 1.5 is exactly
  representable at either width, so nothing about the NUMBER says which
  one stored it — only the column does. `Value::Float(f32)` now decodes
  from REAL; every arithmetic path asks `approx_of` for the f64 behind
  it, and only `render` cares which it was.

### Guarded
- A TIME does not CAST to a DATE or a TIMESTAMP: the engine fills the
  date from the CURRENT DATE, which this server does not do — the same
  reason the two do not compare.
- An unknown target (`CAST(I AS BLOB)`) refuses rather than falling back
  to another conversion.

`qa/serve-real-cast.sh` (53 checks, twin servers). Every check runs over
all three rows, one of which is the negative of another, because a
rounding rule that is right for the positive and wrong for the negative
is exactly what half-away-from-zero distinguishes.

`qa/diff-rows.sh` stopped SKIPPING float and double columns. It compares
the raw file's decoded text against isql's own — no wire protocol in
between — which makes it a second, independent oracle for the rendering
above, and it was the run that caught the FLOAT/DOUBLE digit difference
in the first place.

`qa/serve-real-approx.sh` lost its `CAST AS DOUBLE PRECISION` refusal
and gained two comparisons — the third refusal-list entry promoted this
way in four slices.

## 2026-07-30 — the wire server: FLOAT and DOUBLE PRECISION as operands

### Converted
- **Approximate numerics in a predicate**: every operator against an
  exact literal, against another column (exact or approximate),
  `IS [NOT] NULL`, `BETWEEN`, `IN`, unary minus and `ABS` — in a SELECT
  and in a DML.
- **Aggregates over them**: `SUM`/`AVG`/`MIN`/`MAX` over `DOUBLE
  PRECISION` and over `FLOAT`, global and grouped, in `HAVING`, and as a
  subquery's value. All describe as DOUBLE, which is what the engine
  announces for a FLOAT source too (probed).
- A new `ExprType::Approx` keeps the family apart from `Numeric`, which
  is EXACT and folds in i128. The two answer differently and must:
  `AVG(N)` truncates at the source's scale, `AVG(DP)` is 1.875.

### Fixed
- **Mixed comparisons fell to the RENDERED-TEXT last resort.** An
  approximate value has no exact `(raw, scale)` decomposition, so
  `num_cmp` declined every mixed pair and `value_cmp` compared the two
  by their printed form. Text ordering is not numeric ordering — `"1.5"`
  sorts after `"10"` — so the comparisons that looked right were right
  by luck. `value_cmp` now promotes the exact side to f64, the engine's
  own conversion.

### Guarded
- A string literal against an approximate side is CONVERTED at prepare
  (`DP > '1.25'`), and one that does not parse refuses — where the
  engine raises SQLSTATE 22018. Neither returns rows.
- `CAST(... AS DOUBLE PRECISION)` still refuses: the CAST target list
  holds only integer and text types, a separate surface.
- An approximate branch may not share a `CASE`/`COALESCE` describe with
  another family yet, and there is no approximate `?` parameter path.

`qa/serve-real-approx.sh` (46 checks, twin servers on identical
databases). Its values are chosen so text ordering and numeric ordering
DISAGREE — `DP < 10` with a 1.5 row in the table is the check that a
text compare cannot pass. `qa/serve-real-subqagg.sh` lost its
approximate-source REFUSAL pair and gained two comparisons instead: both
positions answer now, and the property being defended (a subquery and a
select list treat one expression the same way) is unchanged.

## 2026-07-30 — the wire server: a DATE/TIME/TIMESTAMP column in a WHERE

### Converted
- **Temporal columns in a predicate.** Every operator against a typed
  literal (`WHERE D > DATE'2021-01-01'`), `IS [NOT] NULL`, `BETWEEN`,
  `IN`, `LIKE`, in a SELECT and in a DML alike. Until now a temporal
  column refused the whole statement — `WHERE D IS NULL` included.
- The comparison RULES were already one layer down: the expression path
  compares `Value`s and `value_cmp` reads a DATE as MIDNIGHT against a
  TIMESTAMP, the engine's own conversion. What was missing was the ROUTE
  to them (the predicate resolver classified columns through `col_kind`,
  which answers Int or Text and nothing else) and the lexer's temporal
  literal: `DATE'...'` was two tokens, so the keyword became a column
  name and the WHERE refused. Both are now one token — as are the clock
  keywords `CURRENT_DATE`, `LOCALTIME`, `LOCALTIMESTAMP`.
- **A temporal answer from a subquery** — `WHERE D = (SELECT MAX(D) FROM
  T)`. A lifted subquery folds its value back into the token stream, and
  a DATE now folds back as a temporal LITERAL rather than not at all.

### Fixed
- **A string literal against a temporal column is CONVERTED, not
  text-compared.** `value_cmp`'s last resort compares two values by
  rendered text, and ISO date text happens to order like dates — so
  `D > '2021-01-01'` was right by accident while `D = '2021-6-15'` (which
  the engine accepts as the same date) compared unequal. The literal is
  now parsed at prepare, per the column's kind.

### Guarded
- `D > 'garbage'` and `D > 20200101` refuse at prepare where the engine
  raises SQLSTATE 22018 at run time. Both are an error to the client;
  what neither may do — and what the text fallback DID — is return a row
  set.
- **TIME against DATE or TIMESTAMP is refused.** The engine promotes a
  TIME to a TIMESTAMP using the CURRENT DATE; this server does not do
  that yet, and a render-compare of the two would have answered every
  row confidently and wrongly.

`qa/serve-real-temporalwhere.sh` (47 checks, twin servers on identical
databases). The fixture's row 1 carries a TIMESTAMP of 08:30 on its own
DATE, so `TS > D` returns it and `D = TS` does not — the case that
separates a real conversion from a text compare. `qa/serve-real-datemath.sh`
lost a refusal and gained two comparisons: `WHERE DATEADD(1 DAY TO D) >
DATE '2024-01-01'` was on its refusal list and is a comparison now.

## 2026-07-30 — the wire server: an aggregate inside a scalar subquery

### Converted
- **`WHERE AMT > (SELECT AVG(AMT) FROM T)`** — an aggregate as the value
  of a scalar subquery, in a SELECT and in a DML alike. AVG, and with it
  MIN/MAX over TEXT, `COUNT(DISTINCT col)`, `AVG(<expression>)` and any
  NUMERIC source's SCALE.
- The subquery no longer folds through the prepare-time integer helper
  (`Option<Option<i64>>`, which refused AVG outright and would have
  flattened `AVG(NUM)` from 11.30 to 11). It builds a **one-item,
  no-key GROUP** and runs the group machinery — because a scalar
  aggregate *is* one group of one item, this is the same code
  `SELECT AVG(NUM) FROM T` already ran, and the argument forms arrived
  with it rather than one at a time.

### Fixed
- **SUM/AVG silently DROPPED approximate values.** The exact fold asked
  `numeric_parts` for `(raw, scale)` and skipped anything that answered
  None — so a DOUBLE column contributed nothing and `AVG(D)` folded to
  NULL over a table full of numbers. The fold now promotes: one
  approximate input makes the whole fold approximate (carrying the exact
  rows that arrived before it), the way the engine's descriptor
  arithmetic does.

### Guarded
- An approximate source is refused in the SUBQUERY as well, because the
  top-level `SELECT AVG(D) FROM T` is refused: one expression cannot be
  legal in one position and illegal in the other. The gate checks both
  positions in a single case.
- `AVG(DISTINCT ...)` and `SUM(<text>)` refuse rather than fold.

The gate (`qa/serve-real-subqagg.sh`, 30 checks) is built around one
property: a subquery's value is a number nobody ever sees, so a wrong
average is not an error — it is a different SET OF ROWS. Each fixture
row is placed so the engine's answer and a plausible wrong one select
different rows: `AVG(AMT)` is 32/4 = 8 with the NULL row ignored and
32/5 = 6 with it counted, and a row sits between them; the average of 10
and 11 is 10 truncated and 11 rounded, and a row sits between those too.
`COUNT(*)` over a system relation is in the gate as well, since routing
subqueries through the group machinery must not lose the record-header
count those relations depend on.

## 2026-07-30 — the wire server: subqueries in a DML WHERE

### Converted
- **`UPDATE`/`DELETE ... WHERE <col> IN (SELECT ...)`**, `NOT IN`, and a
  scalar subquery on the right of a comparison
  (`WHERE ID = (SELECT MIN(UID) FROM U)`,
  `WHERE AMT < (SELECT MAX(N) FROM U)`).
- The predicate was never the missing piece - the SELECT path has
  answered these shapes for slices. What the DML planners lacked was the
  LIFTING pass in front of the parser: each subquery is evaluated once
  and folded back into the token stream as ordinary values before the
  predicate parser ever sees it. Both DML planners now run the same pass
  the SELECT path runs, which is why `IN`, `NOT IN` and the scalar forms
  all arrived together.

The gate (`qa/serve-real-dmlsubq.sh`, 17 checks) is mostly TABLE
comparisons on purpose: a DML returns no rows, so a subquery filter that
selects the wrong rows deletes the wrong rows and nothing in the reply
shows it. Every statement runs against both servers on identical
databases, and after each one both tables are compared - including the
subquery's own table, to prove it was only read.

## 2026-07-30 — the wire server: where NULL sits, and ORDER BY expressions

### Converted
- **`ORDER BY ... NULLS FIRST | LAST`.** The DEFAULT placement was
  already right and is worth naming: it is not "first" or "last" but
  LOW - NULLs sort below every value, so they come FIRST ascending and
  LAST descending. An explicit `NULLS FIRST`/`NULLS LAST` states a
  POSITION instead, and that position does NOT flip with the direction,
  so the four combinations are four different orders. A converter that
  reads the clause as "reverse the default" gets two of them wrong.
  Every ORDER BY key carries its own placement, including a UNION's
  ordinal form.
- **`IS [NOT] DISTINCT FROM`**, the null-safe comparison, desugared at
  parse time the way `BETWEEN` and `IN` already are, so every later
  stage sees shapes it knows:

  ```text
  A IS NOT DISTINCT FROM NULL  ==  A IS NULL
  A IS NOT DISTINCT FROM v     ==  A = v                    (v not null)
  A IS DISTINCT FROM v         ==  A IS NULL OR A <> v
  A IS NOT DISTINCT FROM B     ==  A = B OR (A IS NULL AND B IS NULL)
  ```

  The third line is the one worth stating: `NOT (A = v)` is a DIFFERENT
  predicate, because a NULL A makes the comparison UNKNOWN and drops the
  row - while the engine returns it. The gate keeps `<>` and `NOT (=)`
  beside the new operator to show the three apart.

### Converted (same slice, second half)
- **`ORDER BY <expression>`**: `ORDER BY AMT + 1`,
  `ORDER BY CASE WHEN AMT IS NULL THEN 1 ELSE 0 END`,
  `ORDER BY UPPER(NAME) NULLS LAST` - the key is computed per row, by the
  same parser and resolver the select list uses, so an expression that
  can be projected can also be sorted by. It carries the same direction
  and NULLS clauses a column key does.
- Every key's value is computed ONCE per row (a decorate-sort pass), not
  inside the comparator: an expression that raises mid-sort must fail the
  fetch the way it would fail a projection, and a comparator has nowhere
  to report that.

### Fixed
- The ORDER BY item parser matched on TOKEN COUNTS, which cannot work
  once items may be expressions: `AMT + 1` is three tokens and looks
  exactly like `ID NULLS LAST` to a shape match. It now strips the
  trailing `[ASC|DESC]` and `[NULLS FIRST|LAST]` clauses first and then
  decides what the head is - a bare identifier, an ordinal, or an
  expression. An expression it cannot resolve refuses the statement
  rather than sorting by something else.

The gate (`qa/serve-real-nulls.sh`, 25 checks) runs every statement
through the SAME driver against TWO servers - fire-crab and the live
engine - on identical databases: the two default orders, all four
explicit combinations, a second key with its own placement, a text
column, the ordinal form, both directions of the comparison against
values, NULLs and other columns, and a refusal for a NULLS position that
is neither FIRST nor LAST.

## 2026-07-30 — the wire server: DML with RETURNING

### Converted
- **`INSERT` / `UPDATE` / `DELETE ... RETURNING <columns>` over the
  wire.** The statement plans WITHOUT its clause - so every default,
  NOT NULL, CHECK, FK and index path stays exactly the one an unadorned
  write takes - and the clause wraps the result.
- **It is a CURSOR, not a singleton.** In Firebird 5 an UPDATE that
  touches three rows returns three; the statement is therefore typed
  `isc_info_sql_stmt_select` and its rows are fetched. That type is not
  cosmetic: node-firebird dispatches on it, fetching all rows for a
  select and exactly one for an exec_procedure, so announcing the DML
  type instead makes a client fetch nothing.
- **Which row each statement gives back** (probed): an INSERT returns
  the row as stored (defaults filled in), an UPDATE the row as it
  stands AFTER the update, a DELETE the row as it WAS.
- The DML runs at op_execute like every other write, and the rows it
  touched become the cursor the next fetch drains - once. A
  materialised cursor that re-emits its rows turns a driver's
  fetch-until-empty loop into duplicates.

### Guarded
- **`NEW.`/`OLD.` qualifiers are refused, because the engine refuses
  them.** They are the PSQL trigger contexts and do not exist in DSQL:
  `RETURNING NEW.ID` answers `Column unknown, "NEW"."ID"`. fire-crab
  accepted them at first - and so returned rows for a statement the
  engine rejects AND wrote a row the engine never wrote. The gate
  caught it because it compares the TABLE afterwards, not just the
  rows. A qualifier naming the target table (`RETURNING T.ID`) is fine
  and works on both.
- An expression in the list (`RETURNING AMT * 2`) is refused at PREPARE,
  so the write does not happen: running the DML and handing back an
  empty cursor is the worst possible outcome for this clause.

The gate (`qa/serve-real-returning.sh`, 14 checks) runs every statement
through the SAME driver against TWO servers - fire-crab and the live
engine - on two identical databases, and compares both the rows and the
resulting table.

## 2026-07-30 — fire-crab-opt slice 9: a unique lookup costs a fixed four

### Converted
- **The retrieval-cost law that decides join orders.**
  `Retrieval::getInversion` (Retrieval.cpp:371-384) prices a UNIQUE
  equality retrieval at a FIXED `DEFAULT_INDEX_COST * indexes + 1` = 4,
  with the comment "independent from a possibly outdated statistics",
  and a non-unique one at `index scan + cardinality * selectivity`.
  `IndexInfo` therefore grew a `unique` flag (`RDB$UNIQUE_FLAG`), and
  both the two-stream cost model and the chain's arrangement search now
  use it.
- **The consequence is counter-intuitive and it is the engine's**: on a
  database whose statistics are zero a unique lookup (4) costs MORE than
  a non-unique one (3), so the engine drives the stream whose inner
  lookup is NON-unique. Probed: with `A.BX` indexed and `B.ID` a primary
  key it plans `JOIN (B NATURAL, A INDEX (A_BX))` in BOTH SQL orders,
  while two symmetric indexes keep the SQL order - because
  `findJoinOrder` replaces its best arrangement only on a STRICTLY
  smaller cost (InnerJoin.cpp:366).
- **A chain drives from its FAR end** for the same reason: two
  non-unique lookups (3 + 3) beat two unique ones (4 + 4). Reaching that
  arrangement also needed the placement search fixed - it demanded the
  remaining streams in index order, which threw away every arrangement
  that reaches its neighbours in the opposite direction.

### Fixed
- **The refusal added in slice 8 is lifted**: a two-stream join with both
  keys indexed is planned again, now by cost rather than by keeping the
  SQL order. The refusal was the honest placeholder for exactly one
  slice.
- A shape from the probed cardinality BANDS no longer overrides the
  per-arrangement costing when it merely says "keep the SQL order". The
  bands were probed on databases with symmetric indexes, where that was
  always right; a real cost decision still wins, as it should.

### Guarded
- The stale-statistics refusal is untouched: a zero selectivity on a
  POPULATED index still refuses, because there the engine keeps costing
  with state this crate has not converted.

The gate grew a FIFTH database whose join sides are indexed
ASYMMETRICALLY - a primary key against a plain index - which is the shape
none of the other four had, and the one that exposed both of slice 8's
wrong answers and this slice's law. 87 checks.

## 2026-07-30 — fire-crab-opt slice 8: outer joins, and two wrong answers they exposed

### Converted
- **Outer joins in chains**, the frontier item this row named. An inner
  join can be reordered, so a chain of them FLATTENS into one
  `JOIN (a, b, c)` list; an outer join cannot, so it makes a plan NODE
  and the chain NESTS:
  `JOIN (JOIN (A NATURAL, B INDEX ...), C INDEX ...)`. The plan model
  grew a `PlanNode` for exactly that shape.
- Inside such a chain the INNER join at the head is still free to swap
  before the outer join wraps it - probed:
  `A JOIN B ON A.BX=B.ID LEFT JOIN C ON B.CX=C.ID` plans
  `JOIN (JOIN (B NATURAL, A INDEX (A_BX)), C INDEX (PK_C))`.

### Fixed
- **RIGHT JOIN was answered as if it were LEFT.** It is LEFT with the
  sides exchanged: the PRESERVED side drives, so `A RIGHT JOIN B ON
  A.BX = B.ID` plans `JOIN (B NATURAL, A INDEX (A_BX))` and fire-crab
  printed `JOIN (A NATURAL, B INDEX (PK_B))`. The ON clause needs no
  rewriting - `A.BX = B.ID` means the same either way round - which is
  what makes the engine's own parser-level rewrite sound.
- **FULL JOIN was answered as a single nested loop.** It is BOTH
  directions, and the engine prints both:
  `JOIN (JOIN (A NATURAL, B INDEX ...), JOIN (B NATURAL, A INDEX ...))`.
  A plan showing one half answers a different question.

### Guarded
- **A two-stream join whose BOTH keys are indexed is now REFUSED**
  instead of answered by keeping the SQL order. Probed: with `A.BX`
  indexed and `B.ID` a primary key the engine drives B in BOTH SQL
  orders - the choice is a property of the streams, decided by
  `StreamInfo::cheaperThan` (independence, then previousExpectedStreams,
  then baseCost; Optimizer.h:895) and by which arrangement costs less.
  That ordering is not converted, so the old answer was right only by
  accident. The refusal names the two indexes and the reason.
- RIGHT and FULL joins INSIDE a chain refuse: the nesting is converted,
  the direction-swap within a chain is not.

The gate grew from 68 to 78 checks: LEFT chains in three shapes,
inner-then-outer and outer-then-inner, RIGHT in both SQL orders, FULL in
two, an outer chain with a driving filter, and the two new refusals.

## 2026-07-30 — fire-crab-lck slice 5: the whole dump, and three offsets that hid in empty queues

### Converted
- **The rest of `fb_lock_print`.** Slice 4 matched the header and owner
  sections; this one adds `-l` (lock blocks with their keys), `-r` (the
  request blocks inside each owner) and `-h` (the history rings), so
  every switch - and `-a`, 1990 lines on a contended table - is
  byte-identical to the engine's tool on the same snapshot.
- **A lock's KEY is where its bytes become meaning**, and its shape
  depends on the SERIES: a page lock prints `space:page` (with the stored
  order reversed - the key holds the page number first), a relation lock
  `relation:instance`, a transaction or attachment lock one 64-bit
  number, a record-GC lock `page:line` packed in one key, an index-rescan
  lock `relation:index` packed in four bytes, and anything else either a
  plain number, `<none>`, or printable bytes with `<NNN>` escapes.
- **Two history rings, not one**: `lhb_history` under the title `History`
  and `shb_history` under `Event log` (print.cpp:885-886). The rings are
  circular and pre-allocated - operation 0 is an unused slot, skipped but
  still advancing the walk, and the walk ends when a next pointer returns
  to the head rather than at a null.

### Fixed
- **Three queue-field offsets from slice 4 were wrong, and every check
  passed anyway.** `offsetof(lrq, lrq_lbl_requests)`, `lrq_own_blocks`
  and `lrq_own_pending` were each shifted by one field - invisible
  because those queues (`Free requests`, `Blocks`, `Pending`) are EMPTY
  on a server with no contention, and an empty queue prints `*empty*`,
  which has no offset in it to be wrong about. Making the server contend
  - a second transaction taking `WAIT RESERVING ... FOR PROTECTED WRITE`
  while the first holds it - filled the pending queue and the dump
  disagreed by exactly eight bytes (91216 against 91224). The gate now
  creates that contention before comparing, so the offsets are held by
  something. Second slice in a row where a field that is usually empty
  turned out to be a field whose offset was never tested.
- **A series enum transcribed from a numbered listing was off by one**
  past `LCK_attachment`. `lck_t` starts at `LCK_database = 1`, so a
  series' value is its position - and every single-number key printed
  correctly regardless, so the error showed up on exactly ONE line in
  636: series 22's four-byte key, which the engine splits as `0004:0000`
  and fire-crab printed as `262144`.
- **A quirk reproduced rather than corrected**: `prt_request` writes
  `"AST: 0x%p"` and glibc's `%p` already emits `0x`, so the engine's real
  output is `AST: 0x0xeb781933e044`. fire-crab prints the double prefix
  too - the differential is the tool's text, not the text it meant.

### Guarded
- The AST line prints pointers into the server's address space. They are
  meaningless outside that process and match only because both readers
  read the same snapshot; the docs say so rather than implying otherwise.
- `-w` (the wait-for cycles) and `lbl_counts[LCK_max]` stay unconverted,
  and so does writing to the table.

## 2026-07-30 — fire-crab-lck slice 4: the shared lock table, in fb_lock_print's words

### Converted
- **The lock manager's other half.** Slices 1-3 converted the POLICY (the
  compatibility matrix, the queues, the verdicts) as an in-process model.
  This one converts the BYTES several processes share: the file the
  server maps as its lock table (`/tmp/firebird/fb_lock_<id>`), decoded
  from `src/lock/lock_proto.h` and printed in `fb_lock_print`'s own text
  (`src/lock/print.cpp`). `fclck dump <file> [-o]` produces the
  `LOCK_HEADER BLOCK` with its counters, the hash-length distribution,
  the four queues and an `OWNER BLOCK` per owner - **byte-identical to
  the engine's tool on the same snapshot**, tabs and column widths
  included.
- **Self-relative queues, and the offset the tool does not print.**
  Every pointer is a byte offset from the start of the table (`SRQ_PTR`,
  que.h:108) because each process maps the region elsewhere. A queue
  node sits INSIDE its block, so `prt_que` prints
  `srq_forward - offsetof(own, own_lhb_owners)` - the BLOCK. On a live
  table the queue held 78408 and the tool printed 78392: sixteen bytes,
  and without them a dump refers to nothing.
- Owner blocks with their three queues (granted, blocking, pending), the
  process block behind each owner, and the `Alive`/`Dead` check - the
  engine's `kill(pid, 0)` becomes a `/proc/<pid>` lookup, which answers
  the same question for the only processes this table can hold.

### Fixed
- **The counter run hid three wrong offsets behind zeros.** `lhb` has
  eleven `FB_UINT64` counters, then `lhb_operations[LCK_MAX_SERIES]`,
  then seven more. My first guesses for `Rejects`, `Blocks`,
  `Deadlock scans` and `Deadlocks` were all four wrong, and three still
  printed a plausible `0` on a quiet server. Only `Deadlock scans` -
  whose wrong offset read into the hash table - printed garbage and gave
  it away. A field that is usually zero is a field whose offset is
  usually untested.
- **A near-miss in a statistic is a real failure.** `lhb_hash` sits after
  `srq lhb_data[LCK_MAX_SERIES]`; with its offset wrong the distribution
  came out *nearly* right - 53 chains of length one where the engine
  counted 52 - with a maximum chain length of 131072, which is not a
  plausible bucket. Nobody reading the dump would have noticed the 53.

### Guarded
- The comparison is made on a SNAPSHOT (`cp` the file, then
  `fb_lock_print -f`), because reading live shared memory twice gives two
  different tables - `Enqs` and `Acquires` move between the readings.
- Queue walks are bounded by the table's own size and stop on a
  self-pointing node: a snapshot of live memory can catch a queue
  mid-update, and a dump must still terminate.
- `own_flags`'s offset depends on libc (`event_t` embeds a
  `pthread_mutex_t` and a `pthread_cond_t`), so a lock table is not
  portable across builds. `shm::EVENT_T_SIZE` is that assumption, alone
  and labelled.
- Lock blocks, request details, the history ring and the wait-for cycles
  (`-l`, `-r`, `-h`, `-w`) stay unconverted; writing to the table stays
  out entirely.

## 2026-07-30 — fire-crab-svc slice 2: gstat asks fire-crab for statistics

### Converted
- **A service ACTION, end to end.** `isc_action_svc_db_stats` with
  `isc_spb_sts_hdr_pages`: the engine's own `gstat`, pointed at
  fire-crab's service manager, now prints a database's header
  statistics that fire-crab computed from the file and streamed back —
  and the gate requires that text to be IDENTICAL to what the same
  `gstat` prints when it reads the file itself.
- **`gstat -h`'s report text** (`fire_crab_ods::header_report`, the
  conversion of `PPG_print_header`, ppg.cpp:56-287), which needed three
  details a converter can easily get backwards:
  - **`Flags` is the PAGE's flags** (`hdr_header.pag_flags`, usually 0),
    not `hdr_flags`. The interesting bits come out below as
    `Attributes`. Printing `hdr_flags` there gives 18 where gstat gives 0.
  - **The `Attributes` label is unconditional, its value is not**: the
    label goes out with no newline and only an existing attribute adds
    text and the line break, so a database with none leaves the line
    dangling. The gate keeps a `gfix -w async` database to cover exactly
    that.
  - **`Database dialect 1` means "no dialect information in the
    header"** — the absence IS the answer (ppg.cpp:81-87).
- **The header fields that report needs**, new in the ODS decoder: the
  implementation triple (`hdr_db_impl` through `DbImplementation`'s
  hardware/OS/compiler NAME TABLES — an index into a list, so the tables
  are part of the format), the creation date, the shadow count, the
  crypt plugin name, and the **variable header clumplets** after the
  fixed part (`hdr_data` at offset 148, `<type><length><data>` until
  `HDR_end`) where the sweep interval, the backup difference file and
  the replication sequence live.
- **The output stream, and the strangest law in this subsystem.**
  `isc_info_svc_line` returns the bytes up to and including the newline
  with **the newline replaced by a space** (svc.cpp:2404, comment and
  all), so a blank line arrives as a single space — `3e 01 00 20 01` —
  and "nothing" is reserved: a ZERO-length item is end-of-stream.
  `isc_info_svc_to_eof` returns the raw bytes, newlines intact. Both
  conventions were read off the live engine's wire with
  `fcsvc stats --raw` BEFORE being implemented, and the gate compares
  the engine's bytes with fire-crab's for the same poll.
- **The real `SpbStart` grammar**: a per-(action, tag) framing table
  (`ClumpletReader::getClumpletType`), because a start SPB mixes
  2-byte-length strings with bare 4-byte integers and nothing in the
  bytes says which is which. An unknown pair is refused rather than
  guessed — guessing a length turns the next tag into data.
- A service session is **stateful**: start, then poll until the stream
  ends. The server now holds that output per connection.

### Guarded
- **The engine's own validation, with the engine's own code.** `-h`
  combined with any other analysis is refused — *"option -h is
  incompatible with options -a, -d, -i, -r, -schema, -s and -t"*, gstat
  message 38, arriving as gds **336920614** (facility-coded, not an
  `isc_*` number). fire-crab converts the rule and refuses the same
  combinations with the same code; the check runs BEFORE fire-crab's own
  capability check, so a malformed request gets the engine's answer
  rather than "fire-crab cannot do that".
- Statistics fire-crab cannot compute (data pages, index pages, record
  versions, encryption, the log) are refused with `isc_wish_list`, and
  the gate requires the REAL server to PERFORM the same request — so the
  refusal is provably ours and not the request's. An empty section would
  have read as "this database has no data pages".
- The service timestamps fire-crab prints are UTC where the engine
  prints the server's local time. Stated in the code and in the docs
  rather than faked; the gate compares the report, not gstat's own
  timestamp lines.

## 2026-07-29 — fire-crab-pio slice 1: the floor, and the last planned row

### Converted
- **A NEW CRATE for `src/jrd/os/posix/unix.cpp`** — the `PIO_*` layer
  every page read and write passes through. Very little code, and
  everything above it assumes all of it:
  - `offset = page * page_size` (`seek_file`), ABSOLUTE, with no
    rebasing — because **Firebird 6 has no multi-file databases**.
    `jrd_file` is one descriptor: no chain, no `fil_min_page`, no
    `fil_max_page`, and `PageSpace` holds a single file. A converter
    carrying an older engine's file chain would subtract a base that no
    longer exists and place every page in the wrong spot. Converting the
    current engine means converting its absence.
  - `PIO_get_number_of_pages` = `file_size / page_size`, INTEGER
    division: a trailing partial page is invisible, not rounded up and
    not an error. Which is why a healthy database's length is a whole
    number of pages — a check fire-crab adds, since the division alone
    hides a truncation.
  - `openFile`'s three flags, and the finding that **Forced Writes is an
    OPEN MODE**: `SYNC` in the open flags, decided from
    `hdr_force_write` (header offset 22), not an fsync after each write.
    That is why changing it at runtime reopens the file, and why
    `PIO_force_write` FLUSHES FIRST when switching it on — the pages
    already in the OS cache were written under the old promise.
  - `PIO_extend`'s fallocate arithmetic, and `PIO_init_data`'s floor: it
    never writes below PAGE 8, which holds the header, the first PIP and
    the first pointer page. fire-crab refuses such a request instead of
    silently returning zero.
- **The lock law, which explains this project's own foundations.**
  `lockDatabaseFile` flocks the whole file — `LOCK_EX` when
  `getServerMode() == MODE_SUPER` — and reports a busy lock as
  `isc_already_opened`, the *"Database already opened with engine
  instance"* error this repository has now hit twice. fire-crab's readers
  take NO lock, which is exactly what lets every differential here read a
  database the server holds open; the gate proves both halves at once
  (BUSY while attached, and a successful read at the same moment).

### Guarded
- A page past the end of the file is an ERROR, never a zero-filled
  buffer. Zeros for a page that does not exist are indistinguishable,
  one layer up, from a page that legitimately holds zeros.
- O_DIRECT is reported but not applied: it requires every buffer, offset
  and length aligned to the device block size, which this reader does not
  guarantee. Stating the law without obeying it beats pretending.
- Shadowing, nbackup difference files, raw-device page counts (an ioctl,
  not `stat`) and the Windows half of the layer stay unconverted.

### Fixed (in the gate, before it could lie)
- The growth phase inserted its rows with a 4000-level recursive CTE.
  Firebird caps recursion at 1024, so the insert failed silently and the
  gate then "verified" a page count that had not moved — three identical
  checks wearing different labels. Now the generator cross-joins a
  500-level recursion, and the gate ASSERTS that the file grew
  (313 → 401 pages for 12 000 rows) before trusting the comparisons.

### Milestone
- With this row, **every subsystem in `docs/subsystem-map.md` has a
  converted first slice with a live differential**. That is breadth, not
  completeness: what remains is depth inside each row, and the frontier
  paragraph on each row says what.

## 2026-07-29 — fire-crab-svc slice 1: the engine's own fbsvcmgr, on both sides

### Converted
- **A NEW CRATE for `src/jrd/svc.cpp`** — the Services API, which is a
  second protocol living inside the first: a client attaches to the name
  `service_mgr` instead of a database, and from then on every request
  and every answer is a byte buffer of tagged items. No statements, no
  BLR, no rows. `gbak`, `gfix`, `gstat`, `nbackup`, `fbsvcmgr` and every
  driver's service class are all this one interface, so converting the
  buffers converts the tools.
- **The four grammars the same-looking bytes follow**
  (`ClumpletReader`'s kinds, ClumpletReader.cpp:262-310): the attach SPB
  is TAGGED with 1-byte lengths, the query's "send" items carry 2-byte
  lengths except the control codes which stand alone, the "receive"
  items are bare tags with no lengths and no terminator, and a start SPB
  is a state machine keyed by its action byte. Read a send buffer as an
  attach buffer and a length becomes a tag.
- **The two answer shapes, chosen per item.** Strings go through
  `INF_put_item` (`[tag][u16 LE len][bytes]`), numerics through
  `ADD_SPB_NUMERIC` (`[tag][4 bytes LE]`, no length at all). NOTHING in
  the bytes says which, so `item_is_numeric` carries that knowledge,
  read off which macro svc.cpp uses at each site.
- **The `isc_info_svc_svr_db_info` cluster**: a BARE opening tag
  (svc.cpp:1163 writes `*info++ = item`), then `isc_spb_num_att` and
  `isc_spb_num_db` as numerics, then a `isc_spb_dbname` string per
  database, closed by `isc_info_flag_end`. The old hand-rolled responder
  did not answer this item at all; `fbsvcmgr -info_svr_db_info` now
  works against fire-crab.
- **fire-crab's own service client** (`fcsvc`): op_connect with SRP
  (through `fire-crab-auth`), `op_crypt` Arc4, then op_service_attach /
  op_service_info / op_service_detach against a live server. A client
  that declares the wire-crypt stance ENABLED and then sends plaintext
  is refused by the default server with `isc_miss_wirecrypt` (335545065)
  — the declaration is a promise.

### Fixed
- **The truncation boundary was off by one, and the engine said so.**
  `INF_put_item`'s room test is `ptr + length + 4 >= end` — a `>=`, so
  the last byte of the client's buffer is never used and an n-byte
  answer needs n + 5. The first implementation used `>` and fit an
  answer the engine would have truncated. Caught by asking the LIVE
  server for its 35-byte version banner with a 39-byte buffer (it
  answers `isc_info_truncated`, `isc_info_end`) and a 40-byte one (it
  answers the string). The numeric path's `ck_space_for_numeric` really
  does use a strict `>`, one byte apart from the string path's; both are
  converted as written rather than unified.

### Guarded
- **A service ACTION is refused, where it used to be acknowledged.**
  `op_service_start` answered a clean `op_response` with the comment
  "acknowledge so the client does not desync" — but a clean response to
  a backup request means "done": the client then polls an empty output
  stream and reports a successful backup that never happened. Now
  `fbsvcmgr` prints *"feature is not supported"* (`isc_wish_list`) for
  `action_db_stats` against fire-crab and the real statistics against
  the engine, and the gate requires exactly that pair.
- **An unimplemented info item refuses the whole query**, because that
  is what the engine does: `query2`'s `default:` arm is
  `status << Arg::Gds(isc_wish_list)`, not a marker and not silence.
  Both servers refuse `isc_info_svc_get_license` with the same
  335544378. Skipping the item would be worse than either — the client
  would read the NEXT item's bytes as this item's answer.
- The actions themselves (gbak/gfix/gstat behind an SPB) and the
  `isc_info_svc_line`/`to_eof` output stream stay unconverted, as
  constants only.

### Fixed (the auth gate, from re-running it)
- `qa/auth-srp.sh` read the security database by copying the file and
  waiting for the user it had just written to APPEAR. Existence is not
  freshness: on a re-run the name already existed, so the copy returned
  the PREVIOUS run's row and the gate reported a verifier mismatch that
  was really a race (the engine writes the data page before it flips the
  TIP, and the security database is written by an attachment the engine
  caches). Now every user carries the run's pid, so existence does imply
  freshness, and after an ALTER the gate waits for the SALT to change -
  a signal that is not the answer being checked. Waiting for "the
  verifier matches" would have been a gate that agrees with itself.

## 2026-07-29 — fire-crab-auth slice 1: the engine's own verifiers as the oracle

### Converted
- **A NEW CRATE for `src/auth/SecureRemotePassword`** — and the split is
  the engine's own: `src/remote/` never authenticates, it CARRIES
  opaque blobs to a named plugin (`Srp256`, `Srp`, `Legacy_Auth`) and
  asks whether it is satisfied. So SRP and the from-scratch
  SHA-1/SHA-256/bignum/Arc4 under it moved out of `fire-crab-wire`
  into `fire-crab-auth`, where one implementation now serves four
  roles: CLIENT (fire-crab logs in to the engine), SERVER (`fcwire
  serve` accepts node-firebird, isql and the OO drivers), USER MANAGER
  (the verifier `CREATE USER` stores — new in this slice), and ORACLE
  (`fcauth`).
- **Both plugin variants.** `Algo::{Srp, Srp256}` parameterizes exactly
  what the engine parameterizes — the proof hash and nothing else
  (`RemotePasswordImpl<SHA>::makeProof`, srp.h:134). The scramble u,
  the user hash x and the session key K = SHA1(S) are SHA-1 in both
  (srp.h:91), so Arc4 is keyed by 20 bytes either way.
- **The verifier half.** `compute_verifier` is
  `RemotePassword::computeVerifier` (srp.cpp:103) — v = g^x mod N, the
  bytes `CREATE USER` writes into `plg$srp.plg$srp` beside a random
  salt — and `SrpVerifier::from_stored` is the engine's server path,
  which holds only `(salt, v)` and never a password.
- **The differential is the ENGINE'S OWN STORED BYTES.** The engine
  computed those verifiers; fire-crab recomputes them from the same
  password and must reproduce them exactly, through `ALTER USER`
  re-salting and all. Reading them needs no SQL and cannot use it:
  `databases.conf` ships the `security.db` alias with
  `RemoteAccess = false`, and a direct attach collides with the running
  server — so `fcauth stored` reads the security database with
  fire-crab's own ODS decoder, as BYTES (`OCTETS` columns, via the new
  `fire_crab_ods::field_bytes`).
- **The live handshake, alone.** `fcauth login` does op_connect →
  op_cond_accept → op_cont_auth against the real server and stops
  before attaching, so an `AUTH OK` means one thing only: the engine's
  own plugin recomputed our proof from its stored verifier and agreed.

### Fixed
- **Every number travels as `BigInteger::getText`, not as padded hex.**
  Our A was 256 hex digits where the engine's client (srp.cpp:110,
  `getText`) sends 255 — no leading zero. The number was right and the
  login worked, but the bytes were not what a real client sends. A, B
  and M are now all `hex_text`. Caught by the cross-implementation
  vectors: node-firebird's independent SRP agreed on the VALUE and
  disagreed on the digits.

### Guarded
- **The one-in-sixteen salt is hunted, not hoped for.** The salt is
  stored as 32 raw bytes and sent as `getText` (SrpServer.cpp:325), so
  one user in sixteen has a 63-character salt. The gate ALTERs a user
  until the engine hands out such a salt (9–11 tries in practice) and
  then shows that only the minimal form reproduces the stored verifier
  — the padded 64-character form and the raw bytes do not — and that a
  live login as that user still succeeds. Without the hunt the law is
  untested by construction.
- **The engine's refusals are recorded, not papered over.** A default
  `firebird.conf` serves `AuthServer = Srp256` only, so offering just
  `Srp` cannot reach a proof: the gate asserts the engine's own
  `isc_login_error` (335545106) at op_connect and pins the SHA-1
  variant's arithmetic by loopback and vectors instead. Editing the
  server's configuration to make the check pass would be a gate testing
  itself.
- Legacy_Auth (DES over an 8-character password), the ChaCha wire-crypt
  plugins, cleartext `isc_dpb_password` attach and identity MAPPING stay
  unconverted — the first would add a weak path for no differential
  value, the rest are separate subsystems.

## 2026-07-29 — fire-crab-evt slice 1: an event is a counter

### Converted
- **A NEW CRATE for `src/jrd/event.cpp`** — and the insight the whole
  surface follows from: an event is not a message but a COUNTER
  (`evnt_count`, event.h:105), while a client's interest carries the
  count it has already seen (`rint_count`). From that alone:
  delivery is COMMIT-TIME; ROLLBACK swallows posts because they were
  never counted; several posts of one name COALESCE into ONE delivery
  carrying the new counter (a client learns "it happened, and the
  counter is now N", never "here are three messages"); a fired
  interest comes DOWN until the client re-queues; and a fresh
  interest below the current count fires AT ONCE, which is exactly
  how a subscribing client learns its baseline.
- **The differential is SEMANTIC, and it uses the paper's own
  sample**: `samples/nodejs/events.js` prints those facts against a
  real server over a real auxiliary connection, `fcevt replay` prints
  them from the converted table, and the gate asserts they agree —
  matching on the counter DELTA, the invariant that survives a
  database's own history where absolute counters do not.

### Guarded
- The shared-memory arena (self-relative queues, process and session
  blocks, the watcher thread) and the wire delivery path (the
  auxiliary connection carrying op_event) are transport and stay
  unconverted; cross-process posting and the AST callback are named
  for later. Gate: `qa/evt-semantics.sh` (4 checks); 6 unit tests;
  287 workspace tests.

## 2026-07-29 — fire-crab-opt slice 7: the cost model closes, on fresh statistics

### The experiment that cracked it
- Slice 6 left a refusing band and a puzzle: the 6×6 grid's shape
  looked arbitrary. Running `SET STATISTICS` on every index and
  re-probing changed the WHOLE grid — and the new one is exactly what
  the engine's formulas predict. The bands were never the law; they
  were the formulas' behaviour on STALE statistics.

### Converted
- **Index selectivity from the catalog** (`RDB$INDICES.RDB$STATISTICS`
  — the number `SET STATISTICS` refreshes, 1/distinct-keys).
- **The cost arithmetic itself**: an indexed retrieval costs
  `DEFAULT_INDEX_COST` (3) plus `selectivity × cardinality` for the
  index scan and the same again for fetching the records
  (Retrieval.cpp:1147 and :384); a nested loop pays that per outer
  row (InnerJoin.cpp:192); a hash pays the inner's unfiltered scan,
  the hashing at MEMCOPY + HASHING (0.5 each), and per outer row a
  probe plus match copies (InnerJoin.cpp:229). The engine takes the
  cheapest of {loop either way, hash} — and `avoidHashJoin`
  (InnerJoin.cpp:217) removes the hash entirely when a side looks
  empty or single-rowed at prepare time, because the engine
  distrusts its own cardinality there.
- **With fresh statistics the model is EXACT: all 36 grid cells**,
  including the diagonal's hashes, both swap directions, and the
  tie-break where an EMPTY index looks cheaper than a one-row one.

### Guarded
- A ZERO selectivity on a POPULATED index means the statistics were
  never computed for the data present; the engine keeps costing with
  internal state this crate has not converted, so fcopt refuses and
  says so — `SET STATISTICS makes it plannable`. Gate phase 4 is the
  same grid left stale: 4 exact, 32 refused, ZERO wrong. Gate:
  `qa/opt-plans.sh` 67 → 68 checks across four databases; 281
  workspace tests.

## 2026-07-29 — fire-crab-opt slice 6: the cost model, as far as the engine's own formulas take it

### Converted
- **The engine's CARDINALITY ESTIMATE** — `DPM_cardinality`
  (dpm.epp:262), line for line: count the relation's data pages;
  walk to the first non-secondary page holding primaries and take
  its record count and compressed length; with exactly ONE data page
  the count is EXACT ("too imprecise to be useful, therefore rely on
  the record count"); otherwise
  `dataPages * (page_size - DPG_SIZE) / recordSize`, where
  recordSize rounds the average compressed record plus its header to
  ODS alignment and adds the slot and SPACE_FUDGE. Never below
  MINIMUM_CARDINALITY. It reproduces the engine's imprecision
  faithfully — 500 rows estimate as 628, 3000 as 3770 — which is the
  point: cost decisions are made on THESE numbers, not on true
  counts.
- **The join decision's cardinality BANDS**, mapped by probing a
  6×6 grid of table sizes against the live optimizer: a TINY driver
  (≤ 1) keeps SQL order — the engine is deliberately pessimistic
  about a relation that "looks empty during preparation"
  (InnerJoin.cpp:217) — a TINY inner side makes it SWAP, and once
  BOTH sides are large the HASH wins. **And hash joins have an order
  too**: the LARGER stream is listed first because it PROBES while
  the smaller is hashed into the table (probed — the plan text swaps
  with the sizes).
- **The band in between refuses**, naming both cardinalities: that is
  where `hashCost <= loopCost` turns on index retrieval costs from
  `Retrieval.cpp`, which this slice does not convert.

### Guarded
- Gate phase 3 is the whole 6×6 GRID, and its assertion is the
  property that matters for a partly-converted cost model: **29 of
  36 cells planned exactly, 7 refused, ZERO wrong**. Exactness where
  it knows, silence where it does not. Gate: `qa/opt-plans.sh` 66 →
  67 checks across three databases; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 5: the cost boundary, measured and enforced

### The finding
- Slices 1-4 verified their rules on EMPTY tables, and the rules are
  right there. On a POPULATED database they are not: with 3000 rows
  against 5, the engine drives the SMALLER stream regardless of SQL
  order; with 3000 against 50 it abandons the nested loop for a HASH
  JOIN even though BOTH sides are indexed (3000 x 600 and 3000 x
  2500 likewise). fcopt would have printed a confident nested-loop
  plan where the engine hashes — a wrong answer the gate could not
  see, because every table in it was empty.

### Converted
- **The boundary is now MEASURED, not assumed.** `row_count` reads
  each joined stream's committed rows through
  `ods::count_primary_records`, and a join whose streams hold ANY
  rows is REFUSED with its cardinality in the message: the decision
  there belongs to a cost model this crate has not converted.
  Single-table access paths stay unconditional — verified structural
  at three thousand rows, including a predicate on a column with one
  distinct value still taking its index.
- **The gate grew a second phase on a populated database**: the
  single-table plans that must still match with data, and the
  populated joins where fcopt refuses — each refusal RECORDING the
  engine's own plan beside it, so the frontier is documented with
  evidence rather than asserted.

### Guarded
- Cost/selectivity arithmetic (cardinality-driven driver choice,
  hash-versus-loop) remains the crate's named frontier — now with
  probe data attached. Gate: `qa/opt-plans.sh` 58 → 66 checks across
  two databases; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 4: equivalence classes

### Converted
- **The reordering slice 3 refused.** Every equi-join predicate
  feeds an EQUIVALENCE CLASS — `D.Z = B.UID` and `A.ID = B.UID` put
  A.ID, B.UID and D.Z in one class — and a stream is reachable when
  it has an index on a column of a class it SHARES WITH AN
  ALREADY-PLACED stream. The engine tries drivers in SQL order and
  keeps the rest in SQL order, which is exactly why an unindexable
  link ends up DRIVING: no arrangement starting anywhere else
  completes. Four probed shapes, all four now planned identically.
- **The order transfers through the class too**: `ORDER BY B.UID`
  navigates A's index on A.ID, because the class proves them equal.
- **One planner for all inner joins.** The two-stream swap turned
  out to be the same rule with n = 2, so plan_join now delegates to
  the general planner and keeps only what is genuinely its own: the
  HASH fallback (the general planner's "no arrangement" answer) and
  the OUTER-join case, whose preserved side cannot be reordered.
- Type families gate CLASS MEMBERSHIP now, not just the two-stream
  key: an equality across families proves nothing an index can use,
  so the VARCHAR = INTEGER join still hashes.

### Guarded
- Outer joins in chains, unions, subqueries, cost/selectivity.
  Gate: `qa/opt-plans.sh` 54 → 58 checks (the slice-3 refusal became
  five checks); 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 3: compound indexes and three-stream chains

### Converted
- **Compound-index matching, by the LEADING-SEGMENT rule**: an
  `(X, Y)` index serves a predicate on X (alone or with anything
  else) but NOT one on Y alone — probed, and the same prefix rule
  governs navigation: `ORDER BY X` and `ORDER BY X, Y` both ride
  the index, while `ORDER BY X, Z` and `ORDER BY Y` sort. Multi-
  column ORDER BY is therefore no longer refused outright — it is
  navigable exactly when it is an index PREFIX with matching
  directions.
- **Chains of three or more streams**: every stream after the first
  reaches its rows through an index on ITS side of ITS OWN ON
  clause, the driver keeping its filter/order access.

### Guarded — with the reason named
- The engine REORDERS a chain whose link is unindexed by deriving a
  new equality through an EQUIVALENCE CLASS (`D.Z = B.UID` and
  `A.ID = B.UID` give `D.Z = A.ID`, and it drove from D). This
  slice refuses that shape rather than guessing at a derivation it
  has not converted — the gate pins the refusal beside the engine's
  plan so the frontier is documented rather than implied. Outer
  joins inside chains likewise. Gate: `qa/opt-plans.sh` 42 → 54
  checks; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 2: join plans, the swap, and the hash

### Converted
- **Two-stream join plans** — `PLAN JOIN (<driver>, <inner> INDEX
  (...))`, streams named by their ALIAS when the query gives one.
  The decision the engine makes and this slice now makes: the inner
  stream must reach its rows through the join key's index, so the
  optimizer **SWAPS the SQL order** when only the FIRST stream's key
  is indexed (`T A JOIN U B ON A.ID = B.UA` plans as
  `JOIN ("B" NATURAL, "A" INDEX (IDX_T_ID))`).
- **The hash fallback** (FB5+): when NEITHER key is indexed the
  engine hashes — `PLAN HASH ("A" NATURAL, "B" NATURAL)` — but an
  OUTER join keeps its nested loop, because the preserved side must
  drive and cannot be swapped away. Both probed, both converted.
- **Type families gate index use**: a `VARCHAR = INTEGER` join
  hashes even though one side is indexed. The bug this caught in
  passing is worth the note: catalog `RDB$FIELD_TYPE` codes and ODS
  DESCRIPTOR dtypes are DIFFERENT NUMBERINGS (37 means VARCHAR in
  one and nothing in the other), and mixing them made a VARCHAR look
  numeric.
- **The driving stream keeps its own access**: a WHERE filter gives
  it INDEX, a navigable ORDER BY gives it ORDER (and cancels the
  SORT), else NATURAL. A conjunct with BOTH sides qualified is the
  JOIN KEY, not a filter — the comma-join form carries its join
  predicate in the WHERE.

### Guarded
- Three-plus-stream chains, ORDER BY on the non-driving stream
  (which the engine answers through equivalence-class reasoning),
  unions and subqueries. Gate: `qa/opt-plans.sh` 31 → 42 checks;
  280 workspace tests.

## 2026-07-29 — fire-crab-opt slice 1: the optimizer's access paths, and oracle number five

### Converted
- **A NEW CRATE for the optimizer** — and with it, ORACLE NUMBER
  FIVE. `SET PLANONLY ON` makes the engine PREPARE a statement and
  print the plan it chose, without executing anything: a complete,
  textual, side-effect-free statement of the optimizer's decision.
  `fcopt plan <db> "<sql>"` prints the same line for the same
  statement, and the gate diffs them.
- **The rules, every one probe-found**: NATURAL when nothing is
  index-matchable — including the OR law (one unmatchable branch
  spoils the whole clause, while an AND keeps its matchable half);
  INDEX (a, b, ...) in INDEX-ID order for matchable conjuncts
  (`=`, ranges, BETWEEN, IS NULL, STARTING WITH, prefix LIKE — but
  not `<>`, IS NOT NULL or a leading-wildcard LIKE); ORDER \<idx\>
  — navigation instead of a sort — only when the ORDER BY column's
  index DIRECTION MATCHES (the engine took the descending twin for
  DESC and fell to a sort when none existed) and any predicate
  rides that same index; SORT (...) wrapping otherwise. The select
  list provably does not influence the plan.
- One parse law the gate taught immediately: **BETWEEN's `AND` is
  not a conjunction** — the naive split cut a predicate in half.

### Guarded
- Joins, unions, subqueries, multi-table FROMs, multi-column ORDER
  BY, compound-index matching — and COST/SELECTIVITY arithmetic
  explicitly: where the engine's choice depends on statistics
  rather than structure, this slice refuses rather than guesses.
  Gate: `qa/opt-plans.sh` (31 checks); 4 unit tests; 280 workspace
  tests.

## 2026-07-29 — fire-crab-exe slice 16: blr_recurse — the executor runs the recursions

### Converted
- **`blr_recurse`**, one slice after the compiler learned to emit
  it: the context, the secondary recursive-context byte, the ANCHOR
  branch (a real rse + map) and the STREAM-LESS recursive branch
  whose boolean and map read the recursion's own output by fid.
- **The fixpoint**: the anchor seeds the output, then each wave's
  rows are bound at the recursion's own context and fed through the
  recursive branch, breadth-first, until a wave yields nothing —
  with the engine's depth cap (1024) as an ERROR rather than a
  hang. Multi-column recursions work by construction (the maps are
  positional), and the recursion tower's framing law had to be
  learned the hard way: it is TWO rses deep and the inner one
  DOES close with its own end, unlike the union and window towers.
- **Over the wire**: recursive procedures now serve BLR-first —
  `SELECT * FROM <recursive proc>` and a multi-column recursion
  both node-verified against the engine (the source interpreter
  never learned WITH RECURSIVE at all).

### Guarded
- Gates: `qa/exe-run-blr.sh` 111 → 115, `qa/serve-real-exeproc.sh`
  10 → 12; psql 55, nofallback 54; 276 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 47: multi-column recursive ctes

### Converted
- **Multi-column recursive ctes** (flip seventy-one — the slice-45
  refusal): per-column anchor and recursive item lists, the outer
  select reading each column's fid, and column references
  resolving to their DECLARED POSITION in the cte's list rather
  than a fixed slot.
- **The unification law, refined by the probe: it is PER COLUMN.**
  A two-column recursion where one column steps (`N.ID + 1`) and
  the other rides plain (`N.AMT`) stores `cast(int64)` on the FIRST
  anchor item only — the sibling stays bare, both inside one map.
  Four appearances now (CASE, unions, single-column recursion, and
  here), each narrowing the rule: the promotion belongs to the
  COLUMN whose own branches disagree, not to the union.

### Guarded
- Outer ORDER BY over a recursion, undeclared cte columns. Gates:
  proc 274 → 278 (mixed stepping columns and a no-arithmetic
  two-column recursion pinned), view 128, exe 111, trig 48, field
  39; 74 dsql tests; 396 pins; 276 workspace tests.

## 2026-07-29 — fire-crab-blb slice 4: stream blobs, and a one-way differential

### Converted
- **Stream-blob creation** (`create_stream_blob`, `fcblb write ...
  0`): content rides RAW — no `[u16 length]` frames at all — with
  `rhd_stream_blob` set, `blh_count` 1 and `blh_max_segment` the
  whole length (a stream blob is "one segment" by bookkeeping).
  Level selection, page chunking and the record's bid are the
  shared path; only the framing differs.
- **A one-way differential, named as such.** Stream blobs arrive
  from the API's BPB (`isc_bpb_type_stream`), never from SQL — the
  probe confirmed the engine stores an SQL literal blob SEGMENTED
  (stream flag 0), so the engine cannot be made to WRITE one
  through isql. The gate therefore runs the direction that exists:
  fire-crab writes, the ENGINE reads every byte back (25 B, 8500 B
  and 120 KB, level 0 and level 1) — and the unframed content must
  not be mistaken for frames, which a segmented reader would turn
  into garbage. gfix and gbak still bless the file.

### Guarded
- The BPB parameter surface (requested type/charset
  transliteration) remains the crate's only named item. Gate:
  `qa/blb-levels.sh` 17 → 20 checks; blb-gc 5; 274 workspace tests.

## 2026-07-29 — fire-crab-exe slice 15: GEN_ID, with the persistence boundary drawn

### Converted
- **GEN_ID / NEXT VALUE FOR** (`blr_gen_id` 101 with a step
  expression, `blr_gen_id2` 210 with the sequence's own increment
  from RDB$GENERATORS): read-and-advance through an IN-MEMORY
  overlay — consecutive reads in one execution see each other's
  steps, the file is never written. The persistence boundary is
  drawn explicitly, in three places: fcexe documents itself as a
  non-persisting harness; the parsed Request carries a
  `uses_generators` flag; and the WIRE server excludes
  generator-writing requests from the BLR path, letting its
  persisting interpreter (the GenIdIncrement machinery) serve them
  — correctness over adoption.
- **The restart-paired gate protocol**: a generator-advancing body
  cannot use the standard check (each side's run steps the
  sequence), so the gate RESTARTS the sequence before each side —
  engine rows, restart, fcexe rows — and both count 2, 4, 6, 8, 10
  in lockstep.

### Guarded
- Gate: `qa/exe-run-blr.sh` → 111 checks (the GEN_ID refusal
  flipped to two restart-paired checks); serve-real exeproc 10,
  psql 55, genstep 11 intact; 274 workspace tests.

## 2026-07-29 — fire-crab-lck slice 3: knock events and lock timeouts

### Converted
- **Blocking-AST knocks as events**: a freshly parked request posts
  a knock to every owner standing in its way — deduplicated per
  (owner, lock), carrying the wanted mode — and `take_knocks`
  drains an owner's queue. The classic protocol is unit-pinned:
  holder reads the knock, downgrades, the waiter grants on the
  regrant sweep. The decision half of the AST is now consumable
  data; delivery remains transport.
- **Lock timeouts**: pending requests may carry a DEADLINE tick
  (`enqueue_deadline`), and `expire(now)` brings every overdue
  parked request down — leaving no trace, like a NO WAIT reject —
  returning who timed out where. The live differential is gate
  phase 5: A holds PW, B waits with `SET TRANSACTION WAIT LOCK
  TIMEOUT 2`, and the ENGINE expires the wait with "lock time-out
  on wait transaction" while A still holds — the same expiry the
  crate's unit test pins, deadline-less waiters unaffected.

### Guarded
- Series semantics and the cross-process dump differential remain.
  Gate: 5 phases; 13 unit tests; 272 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 46: the unification law converted, PLAN ORDER

### Converted
- **Union type-unification** (flip sixty-nine — the law the gate
  found in slice 44, converted): one arithmetic branch (`+`/`-`/`*`
  with an integer literal) types the union int64 — dialect-3
  integer arithmetic is width-independent, so the typing is
  CATALOG-FREE — and every PLAIN branch wraps in `cast(int64)`.
  The slice-44 named refusal flipped to a live check; a three-way
  union mixing `+ 5`, a plain column and `- 1` (with a parameter in
  a branch WHERE) pins the general shape.
- **PLAN (tbl ORDER idx)** (flip seventy): `blr_navigational`
  (0x8F) + ONE counted index name — no count byte, unlike
  blr_indices — and a probe-found engine rule: the plan is only
  legal beside a MATCHING ORDER BY ("index cannot be used in the
  specified plan" without it).

### Guarded
- DIVISION in union branches (scale-rule promotion), field-by-field
  branch arithmetic. Gates: proc 271 → 274, view 128, exe 110, trig
  48, field 39; 72 dsql tests; 395 pins; 272 workspace tests.

## 2026-07-29 — fire-crab-blb slice 3: blob GC and the blob crash workload

### Converted
- **The blob GC differential** (`qa/blb-gc.sh`): fcblb writes a
  level-0 and three level-1 blobs with their records; the ENGINE
  deletes two rows, commits, and runs its own garbage collector
  (`gfix -sweep`) over the fire-crab-written file. The dead rows'
  blobs die with them: validation silent, the survivors read in
  full through BOTH readers — and the TEETH count PIP free BITS,
  which rose by exactly the dead blobs' fifty pages. (A sweep that
  "worked" but freed nothing would pass a validity-only check; and
  the pip_used counter proved unreliable for this — the BITMAP is
  the allocation truth.)
- **The blob crash workload** (`fccch crash-matrix ... blob`): rows
  referencing fresh level-1 blobs written through fire-crab-blb's
  own path. Fourteen writes — header, NINE blob pages, data, pip,
  pointer, tip — with the blob-before-data edge finally carrying
  real weight: a record's bid never names a blob whose pages are
  not on disk. All fifteen careful prefixes engine-valid; the
  naive order breaks at twelve.

### Guarded
- Stream-blob creation and the bpb surface remain named. Crash
  harness now FOUR workloads; 270 workspace tests.

## 2026-07-29 — fire-crab-exe slice 14: EXECUTE PROCEDURE adopted, runtime errors surfaced

### Converted
- **EXECUTE PROCEDURE, BLR-first** — at BOTH wire sites: the
  OP_EXECUTE arm isql drives and the op_execute2 arm the OO clients
  drive (the second was found the honest way: the first gate run's
  node call died on it). Semantics are the engine's: a selectable
  body answers its FIRST suspended row, a non-suspending one its
  final output state — the executor runs the whole (read-only) body
  and the wire layer picks the row, observationally identical.
- **Runtime errors surface as SQL errors.** The BLR path now
  distinguishes three outcomes: OUTSIDE the surface (silent
  fallback to the interpreter, as before), ROWS, and RUNTIME error
  — divide-by-zero and overflow ship the engine's own vectors to
  the client instead of falling back. A body that fails must FAIL:
  an interpreter that answered rows there would mask the engine's
  behavior. The gate holds `SELECT * FROM PW8` (a divide-by-zero
  body) erroring on BOTH sides.
- Gate helper fix with a lesson attached: node-firebird returns an
  OBJECT for EXECUTE PROCEDURE, an array for SELECT — the gate's
  row printer assumed arrays and manufactured CONN_ERR.

### Guarded
- Gate: `qa/serve-real-exeproc.sh` 7 → 10 checks; regressions psql
  55, modifiers 41, nofallback 54; 270 workspace tests.

## 2026-07-29 — fire-crab-exe slice 13: the wire adoption

### Converted
- **The two paths meet.** `SELECT FROM <procedure>` over the wire
  now serves BLR-FIRST: the server reads the stored
  RDB$PROCEDURE_BLR — the same bytes fcdsql matches byte-for-byte
  and the engine itself executes — parses it in fire-crab-exe's
  surface, and takes the suspended rows straight from the
  message-1 sends. Anything outside the surface falls back to the
  source interpreter unchanged.
- **The payoff**: procedure bodies the interpreter NEVER learned
  now serve over the wire — running-SUM windows, RANK/DENSE_RANK,
  LAG, ROWS BETWEEN frames, correlated EXISTS, FULL JOINs,
  parameterized procedures — each answer node-fetched from fcwire
  and equal to the engine running the same procedure
  (`qa/serve-real-exeproc.sh`, 7 checks, green first run).
- exe's `execute` split into a value-typed core
  (`bind_and_execute` — what the server binds) and the CLI's
  string-parsing wrapper; `procedure_blr` moved to the library.

### Guarded
- EXECUTE PROCEDURE (ProcInvoke) stays on the interpreter — its
  first-suspended-row semantics ride a later slice. Regressions:
  psql 55, modifiers 41, nofallback 54, selectexpr 88, exe gate
  110; 270 workspace tests.

## 2026-07-29 — fire-crab-lck slice 2: teardown, lock data, the blocking set

### Converted
- **Owner teardown** (`purge_owner`): the engine's purge on detach —
  every granted and pending request comes down, each affected lock
  regranting FIFO. Live-verified (gate phase 4): A holds PW, B's
  WAIT reservation parks, A DETACHES WITHOUT COMMITTING — and B
  proceeds the moment the engine's purge fires, the same
  release-all-and-regrant the crate's unit test pins.
- **Lock data words** (`write_data`/`read_data`): `lbl_data` — the
  writer must HOLD the lock, anyone reads, an absent lock reads
  zero. The probe caught the mechanism live: a transaction lock
  carrying `Data: 134` in fb_lock_print on this very box.
- **The blocking set** (`blockers`): the owners whose granted,
  incompatible requests park a waiter — exactly who would receive
  the blocking AST; the decision is now data, the delivery stays
  transport.
- **A SuperServer finding re-scoped the roadmap**: fb_lock_print
  shows NO relation locks — relation arbitration is in-process, the
  shared table carries only cross-process series. The structural
  dump differential is bounded accordingly; reservations remain the
  relation-lock oracle.

### Guarded
- AST delivery, timeouts, series semantics. Gate grew phase 4
  (teardown-unblock); 11 unit tests; 267 workspace tests.

## 2026-07-29 — fire-crab-cch slice 2: the matrix learns indexes and deletes

### Converted
- **The indexed workload**: the crash matrix's inserts now maintain
  T's B-tree per row (the same `btw::insert_index_entry` path the
  wire server drives), so btree pages join the careful-write
  ensemble. The slice-1 matrix had ordered btree-after-data by
  PAGE-NUMBER LUCK; the edge is now law — an index entry names a
  record NUMBER, so the data page holding the record precedes the
  btree page holding the entry. Order: header → data → pip →
  pointer → btree → tip, every prefix engine-valid.
- **The delete workload**: version-chain stubs over the same pages —
  header → data → tip, three writes, and the TIP-last law shows its
  other face: every interrupted prefix answers the ORIGINAL rows,
  the full sequence zero, and the naive order makes rows VANISH
  EARLY (a premature commit flip). The file is never wrong, only
  ever behind — in both directions.
- **The gate caught a workload invalidity**: with an index on the
  table, the plain (un-indexed) insert workload's own END state is
  inconsistent — gfix flagged missing index entries at the full
  prefix. The gate now runs two scratch databases, and the finding
  is documented in it: an insert that skips index maintenance is
  not a valid operation on an indexed table.

### Guarded
- Page DEALLOCATION (the pip-freed-last chain) waits for a
  fire-crab operation that frees pages (sweep). Gate:
  `qa/cch-crash-harness.sh` — 3 workloads × (all-prefixes-valid +
  naive teeth); 267 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 45: recursive ctes

### Converted
- **WITH RECURSIVE** (flip sixty-eight — the transcript banked in
  slice 42, cashed at last): `blr_recurse` carries the context, the
  SECONDARY recursive-context byte (GEN_stuff_context emits both
  when CTX_recursive — the secondary claims the slot BELOW the
  recursion's), and the branch count; the ANCHOR branch is a real
  rse + map with the cte name riding the relation2 alias exactly
  like every inlined cte; the RECURSIVE branch is an rse with ZERO
  streams whose boolean and map read `fid(recurse ctx, 0)`; no
  terminator of its own — the wrapper rse's END closes it. Context
  law: secondary, recursion, anchor claim consecutive slots.
- **The unification law, third appearance**: a `+ 1` recursive item
  types int64 (dialect-3 integer ADD — width-independent, so
  CATALOG-FREE), and the anchor's bare field wraps in
  `cast(int64)`; the no-arithmetic recursion carries no casts. Both
  shapes pinned. Multiplication refuses — its promotion rule
  depends on operand rank.

### Guarded
- Multi-column recursive ctes, a plain cte beside a recursive one,
  outer WHERE over the recursion, `*` in the recursive item. Gate:
  `qa/dsql-proc-blr.sh` 267 → 271 (the slice-42 named refusal
  flipped); 70 dsql tests; 393 pins; 267 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 44: unions as quantified subqueries

### Converted
- **UNION ALL as a quantified subquery's stream** (flip sixty-seven
  — the banked transcript cashed): the union claims the subquery's
  reserved context slot (the slice-38 lookahead law in subquery
  clothing — the reservation must land before any branch stream
  numbers), branches carry rse + positional map at the following
  slots, and the comparison reads `fid(union ctx, 0)`. NOT IN
  negates to ansi_all + neq as everywhere; parameters ride branch
  WHEREs; three-branch unions hold.
- **A law the gate's own battery found**: expression branch items
  UNIFY the union's type — a `* 2` branch promotes to int64 and the
  engine wraps every plain branch in `cast(int64, ...)` — the
  CASE-unification law in union clothing. Named as a refusal with
  the transcript in the gate comment; the same catalog-typing
  boundary as NULLIF applies to FIELD-typed branches, so the
  convertible slice is literal/param-typed unification.

### Guarded
- The DISTINCT union form, EXISTS over a union, derived branches,
  expression branch items (above). Gate: `qa/dsql-proc-blr.sh`
  262 → 267; 68 dsql tests; 391 pins; 265 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 43: the executor's frontier list, cleared

### Converted
- Five flips (sixty-two through sixty-six), every one a shape the
  EXECUTOR's two-arrow gate had named while its compiler half was
  missing: **STARTING [WITH]** (`blr_starting`; NOT keeps a real
  blr_not, like LIKE), **FIRST/SKIP (:param)** (a PARENTHESIZED
  parameter compiles to the bare parameter2 — and `FIRST :P` is a
  syntax error in the ENGINE too: the old refusal had been correct
  all along, only the parenthesized spelling was missing),
  **DISTINCT over a derived table** (the project's field translates
  through the derived list — one guard term fell), **FOR-less
  SUBSTRING** (the engine fills the length with INT MAX — probed
  literal 0x7FFFFFFF), and **expression select items in quantified
  subqueries** (the comparand wraps in `blr_derived_expr` over the
  subquery stream — the two-phase span parse, again).
- The 2-arg SUBSTRING flip reached the VIEW surface through the
  shared parser: the view gate's old refusal now compiles, and
  RDB$VIEW_BLR confirmed the same INT-MAX byte live.
- Every re-enabled EXECUTOR check went green on the first run —
  the frontier list worked exactly as designed: gate names gap,
  compiler slice clears it, executor check comes back by itself.

### Guarded
- Union-in-subquery stays named WITH its transcript (the wrapper's
  stream is a blr_union; the comparison reads fid(union ctx, 0)).
  General limit expressions, expression items in SCALAR subselects.
  NULLIF/IIF over field branches is documented as a MODEL BOUNDARY,
  not a gap: the unifying cast's target needs the field's catalog
  type, and this compiler is catalog-free by design. Gates:
  qa/dsql-proc-blr.sh 253 → 262, view 128 (one refusal flipped to
  a live check), exe 105 → 110; 66 dsql tests; 390 unit pins; 263
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 12: the string functions

### Converted
- **UPPER / LOWER** (`blr_upcase`/`blr_lowcase`, unary),
  **CHAR_LENGTH / OCTET_LENGTH** (`blr_strlen` + the length-type
  byte the dsql side probed years of slices ago, read back),
  **SUBSTRING** (`blr_substring` — the 0-based start arriving as
  the reference compiler's unfolded `subtract(from, 1)`, exactly
  the tree the playbook says to match; negative start or length is
  a runtime error, past-the-end is empty, NULL propagates through
  all three operands) and **TRIM** (the where byte: both / leading
  / trailing over spaces).

### Guarded
- TRIM-by-character (spec 1) refuses; GEN_ID stays named — a
  SELECT that WRITES, against fcexe's read-only file model, is a
  design decision rather than a parse arm. One frontier swap:
  two-argument SUBSTRING (FROM without FOR) is a dsql-side gap.
  Gate: 98 → 105 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 11: simple CASE, cross-family casts, RANGE value bounds

### Converted
- **RANGE value bounds**: key arithmetic over the single sort key —
  the frame is the contiguous run of rows whose key lies within
  cur∓v along the traversal's own axis (PRECEDING subtracts along
  it, FOLLOWING adds, DESC flips the sign). A NULL current key
  frames its peer group alone, and NULL keys never qualify for a
  value edge (their comparisons are UNKNOWN). Ascending, DESC and
  CURRENT-to-FOLLOWING forms all hold against the engine.
- **Cross-family casts**: int→text renders plain decimal; text→int
  parses, a bad string raising the engine's conversion error. Width
  and range violations error as before — never silent.
- **The simple CASE** (`blr_decode`): an operand, counted condition
  values, counted results with the extra one as ELSE; a NULL
  operand matches nothing and takes the else (or NULL without one).

### Guarded
- GEN_ID and the built-in string functions (UPPER et al) are the
  new named frontier. Gate: 92 → 98 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 10: frame extents

### Converted
- **The v4 framed window** (`blr_window_win`): subcoded clauses —
  partition (the v3 layout under a tag), order, map, extent unit
  (RANGE 0 / ROWS 1), frame bounds (preceding 0 / following 1 /
  current row 2, values optional) — closing with its OWN `blr_end`
  where the v3 window leans on the rse's; a single bound implies
  CURRENT ROW as the second, the dsql-probed law read back. Both
  generations mix freely in one statement, and parse through one
  shared map/sort-key reader.
- **Execution**: every fold and every valued function now runs over
  a per-row FRAME SPAN — the default reproduces slice 8's peer
  semantics exactly (no order: the partition; order: unbounded
  through the current peers), ROWS frames offset by row position,
  and RANGE keeps its value-less peer forms. Sliding sums (`ROWS
  BETWEEN 1 PRECEDING AND CURRENT ROW` walking through a NULL),
  lookahead sums, CURRENT-to-UNBOUNDED tails, a framed LAST_VALUE
  and an explicit RANGE UNBOUNDED..CURRENT all hold against the
  engine row for row.

### Guarded
- RANGE frames with VALUE bounds (the key-arithmetic form) and
  cross-family casts remain named. Gate: 86 → 92 checks. 261
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 9: conditionals and the valued window functions

### Converted
- **CAST** (`blr_cast` + a dsc): integer range checks ERROR rather
  than wrap, text width overflow is the engine's string-truncation
  error rather than a silent cut, NULL passes through; cross-family
  conversions refuse by name. **COALESCE** takes the first
  non-NULL. **blr_value_if** — the conditional the searched CASE
  compiles to under its unifying cast — where UNKNOWN takes the
  else branch.
- **The valued window functions**: LAG/LEAD (the row an offset
  ago/ahead in partition order, the third argument when the
  partition runs out — the canonicalized three-argument form the
  dsql side probed, read back), FIRST_VALUE, LAST_VALUE — the
  default RANGE frame's famous trap, engine-verified: it answers
  the CURRENT PEER GROUP's last value, not the partition's — and
  NTH_VALUE (the nth only if the frame reaches it).

### Guarded
- Frame extents (blr_window_win) and cross-family casts (int↔text)
  remain named. Two frontier swaps: NULLIF and IIF over FIELD
  branches are dsql-side guards (the unify-typing law needs the
  catalog). Gate: 78 → 86 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 8: windows — the last named refusal falls

### Converted
- **Windows** (`blr_window`): a window is an aggregate that KEEPS
  its rows — every source row survives, each window's context
  binding a slot-row of computed values the body reads by fid.
  Per window (`blr_partition_by`): whole-partition aggregates when
  the window has no ORDER; RUNNING aggregates over the default
  RANGE frame when it does — peers included, rows with equal sort
  keys sharing the value (the gate's running SUM walks straight
  through a NULL, which contributes nothing, exactly as the
  engine's does); and ROW_NUMBER / RANK / DENSE_RANK
  (`blr_agg_function`, counted name) by peer-group position. The
  remap fids after the partition keys are bookkeeping and parse
  away. Windows process in declaration order, each re-sorting the
  row set — the LAST window's order is the emission order, the
  engine's sort-per-window pipeline, and the multi-window check
  (a running SUM beside a partition COUNT) held.
- Like the union, the window consumes the rse's closing end itself
  — no clauses follow a window in this wrapper.

### Guarded
- Frame extents (`blr_window_win` — the v4 subcoded form) and
  CAST/CASE value verbs are the new frontier, named by fresh
  refusals. Gate: 70 → 78 checks. 261 workspace tests. With this,
  every refusal the executor's slice 1 declared has been flipped
  by a later slice — the roadmap ate itself in eight steps.

## 2026-07-29 — fire-crab-exe slice 7: subquery predicates, scalar subselects

### Converted
- **EXISTS / SINGULAR**: `blr_any` / `blr_unique` over one rse.
  Correlation cost NOTHING: the outer row's frames are already on
  the evaluation stack when the inner scan runs, so `U.UID = T.ID`
  resolves through the ordinary frame search - the design dividend
  of the binding model, third time paying.
- **Quantified comparisons**: `blr_ansi_any` / `blr_ansi_all` over
  a wrapper rse whose single STREAM is the subquery (the
  derived-table arm parses it) and whose boolean is the comparison.
  ANY: true beats unknown beats false; ALL the mirror; the empty
  set answers false/true. NOT IN's famous trap holds: one NULL in
  the subquery poisons every row to UNKNOWN, and the gate's
  `ID NOT IN (SELECT AMT FROM T)` answers EMPTY exactly as the
  engine does - the wrong-in-most-hand-rolled-executors case.
- **Scalar subselects**: `blr_via(singular-rse, value, else)` - one
  row binds and the value evaluates, none and the else (NULL) does,
  a second row is sing_err. `blr_derived_expr` (191) is a
  bookkeeping wrapper - stream ids, then the expression - parsing
  straight through.

### Guarded
- Windows are the last named refusal. Two checks swapped at the
  frontier (expression subquery items, union-in-subquery - both
  dsql-side guards). Gate: 63 → 70 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 6: UNION and the remaining simple booleans

### Converted
- **UNION**: `blr_union` standing in the stream slot — its own
  context, per-branch rse + positional map, branches concatenating
  in order onto slot-indexed union frames. Two byte-level laws:
  the opcode is 76 — `blr_eoc`'s — disambiguated purely by
  POSITION; and a union has NO terminator of its own — the branch
  count bounds it, and the next `blr_end` belongs to the OUTER rse
  (the first parse consumed one end too many and refused its own
  probe to learn this). The DISTINCT form needed nothing: it is
  the outer rse's `blr_project` over the union's fids, and the
  existing project machinery dedupes union frames unchanged.
- **The remaining simple booleans**: IN-list (`blr_in_list`,
  u16-counted, three-valued — no match beside a NULL comparand is
  UNKNOWN, not false), BETWEEN (3VL on both bounds), LIKE
  (character-based backtracking — the porting playbook's own
  pseudocode, executable at last) and STARTING WITH. `blr_text2`
  literals (charset-carrying) decode alongside.

### Guarded
- Windows and subquery predicates (EXISTS et al) remain named. One
  check swapped: STARTING WITH executes but fcdsql does not compile
  it yet — another cross-crate frontier the two-arrow gate named.
  Gate: 54 → 63 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 5: join chains, index retrievals

### Converted
- **Join chains**: `blr_rs_stream` nests as a SOURCE of the outer
  rs_stream — the left-nested shape the dsql crate emits. Join
  sources went recursive (`JoinSource::Rel | Nested`), a nested
  join's bindings splice whole into the outer product, and an outer
  join over a chain pads EVERY context the nested side binds. A
  mixed chain — `T JOIN T LEFT JOIN U` — holds against the engine.
- **Index retrievals**: `PLAN (T INDEX (names))` executes as the
  real BitmapTableScan. The B-tree walk (`ods::walk_index_leaves`)
  yields record numbers; records fetch by number; and VISIBILITY IS
  DECIDED ON THE RECORD ITSELF — the index only says where records
  might be, the paper's own law about Firebird's index
  architecture, now executable. The index name resolves through
  RDB$INDICES to its 0-based index-root slot (the catalog's
  RDB$INDEX_ID is 1-based). `PLAN (T NATURAL)` runs the plain scan.

### Guarded
- Windows and UNION remain named refusals. Gate: 49 → 54 checks
  (three-stream chains, chain + WHERE, mixed LEFT chain, PLAN
  INDEX with a parameter, PLAN INDEX + ORDER, PLAN NATURAL). 261
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 4: outer joins, derived tables

### Converted
- **Outer joins**: `blr_join_type` (80) with operands left/right/
  full (1/2/3, probed after a wrong first guess — the numbers live
  in blr.h, not intuition). A preserved-side row with no ON match
  emits once with the other side's frame an EMPTY row — and the
  binding model makes null-padding free: a field read off an empty
  frame answers NULL through the ordinary lookup, no special record
  needed. The anti-join (`WHERE B.UA IS NULL` over the padded side)
  and `COUNT(*)` over it hold against the engine.
- **Derived tables**: a nested rse standing in the stream slot. Its
  bindings pass straight through — the inner stream's context IS
  what outer references name — so the feature is one parser arm and
  ZERO executor code. Outer WHERE, ORDER BY and aggregates over
  derived tables compose as they always did.

### Guarded
- Windows, 3+-stream join chains (nested rs_stream), outer joins
  over more than two streams, explicit PLANs (blr_plan awaits the
  index-retrieval slice). One check swapped when phase A refused:
  DISTINCT-over-derived is a dsql-side guard, so its byte-pin
  cannot hold until the dsql crate flips it — the gate's two-arrow
  design surfaces cross-crate frontiers exactly. Gate: 41 → 49
  checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 3: expressions, joins, DISTINCT

### Converted
- **Value expressions**: blr_add / subtract / multiply / divide /
  negate / concatenate — NULL propagates through every verb, integer
  division truncates toward zero, and divide-by-zero and overflow
  are runtime ERRORS, not wrong numbers.
- **Inner joins**: `blr_rs_stream` — the NestedLoopJoin — with
  aliased `blr_relation2` streams and the ON boolean evaluated over
  the joined frames. The executor's core generalized from
  single-frame rows to BINDINGS (one frame per joined stream), so
  the whole tower — filters, DISTINCT, sorts, aggregates, FIRST/
  SKIP — composes over joins with no per-feature work: COUNT(*)
  over a join ran the moment joins parsed.
- **DISTINCT**: `blr_project` as the rse clause it is — sort-based
  unique over the projected values, NULL grouping WITH NULL; the
  engine's null-first output order held unprompted (the nulls-low
  law reaching the project sort).

### Guarded
- LEFT/outer joins (blr_join_type refuses in the join clause loop),
  derived tables, windows. Gate: `qa/exe-run-blr.sh` 32 → 41
  checks (three refusals flipped; join+WHERE, aggregate-over-join,
  DISTINCT+ORDER, expression params). 262 workspace tests.

## 2026-07-29 — fire-crab-exe slice 2: parameters, aggregates, singular, FIRST/SKIP

### Converted
- **Three of slice 1's own refusals flipped** by the same gate
  machinery that installed them. INPUT PARAMETERS: message 0 binds
  up front from fcexe's CLI arguments (typed by the message slots),
  `blr_receive` is transparent to the synchronous looper, and
  `blr_parameter2` joins the value expressions. AGGREGATES:
  `blr_aggregate` as a stream with its own context — group-by keys
  fold rows with NULL grouping WITH NULL (set semantics), the map's
  verbs (count / count2 / total / average / min / max) carry the
  engine's empty-set rules: COUNT of nothing is 0 but SUM/AVG/MIN/
  MAX are NULL, a keyless aggregate of an empty set still yields ONE
  row, integer AVG truncates; outputs read `blr_fid`, and HAVING is
  just the outer rse's boolean evaluated over the aggregate frame.
  SINGULAR selects: a second row is a runtime ERROR (the engine's
  sing_err), never a truncation. FIRST/SKIP: rse clauses executed in
  the tower's order — sort, then skip, then first.
- The rse parser split into entry/body so `blr_singular` wraps and
  aggregate sources nest without double-consuming tags; frames now
  carry an optional relation (aggregate frames are slot-indexed,
  read by fid — a bare field over one refuses).

### Guarded
- Joins, value expressions, DISTINCT (blr_project) and windows
  remain named refusals. Gate: `qa/exe-run-blr.sh` grew 20 → 32
  checks (13 fresh incl. three flips; text CLI arguments quote on
  the SQL side — the engine parsed a bare `bb` as a column and
  fcexe was right first). 5 unit tests; 262 workspace tests.

## 2026-07-29 — fire-crab-blb slice 2: level-2 creation + wire adoption

### Converted
- **Level-2 blob creation.** The pointer-page layout was probed off
  the engine's own 36 MB level-2 blob before a byte was written:
  data pages keep the blob-wide lead page and their GLOBAL sequence;
  pointer pages are type 8 with `blp_pointers`, carry the blob-wide
  lead, SEQUENCE 0 (the engine writes 0 on every pointer page), and
  a `blp_length` counting the entry BYTES of their u32 data-page
  vectors; `blh_max_sequence` still counts data pages (last
  sequence). The gate writes an 18 MB blob through this path and
  the engine reads all eighteen million bytes back - gfix silent,
  gbak happy. "Level-3 does not exist" is now an explicit refusal.
- **Wire adoption.** The server's SEVEN blob call sites now read
  through `fire_crab_blb::read_blob_content` - op_open_blob /
  op_get_segment serve level-2 blobs no earlier reader could. Gate
  phase C: node-firebird fetches every fcblb-written blob over the
  wire (the 18 MB level 2 included) and the assembled content
  equals the source files. The pre-existing `qa/serve-real-blob.sh`
  differential stays green on the swapped reader.

### Guarded
- Blob GC, filters, stream creation, temporary blobs (unchanged
  refusals). Gate `qa/blb-levels.sh` grew to 17 checks; serve-real
  blob/show/nofallback regressions green; 260 workspace tests.

## 2026-07-29 — fire-crab-blb slice 1: blob storage, both directions

### Converted
- **A NEW CRATE for `src/jrd/blb.cpp`'s on-disk addressing.** `blh`
  headers and `blp` blob pages as typed codecs — every `ods.h`
  static_assert mirrored as a unit test, so a drifted offset fails
  before it mis-reads a byte. Reading at ALL THREE levels: 0
  (inline), 1 (page vector), 2 (pointer pages) — the gate's 36 MB
  engine-created blob is a genuine level 2, read byte-for-byte
  against the engine's own OCTET_LENGTH / SUBSTRING answers.
  Creation at levels 0 and 1 through fire-crab's own placement
  (`ods::insert_blob_slot` + the now-public `ods::allocate_page`),
  segment framing intact, plus the referencing record's `bid` laid
  into the image — and the ENGINE reads every fcblb-written blob
  back in full, `gfix -v -full -n` finds neither errors nor
  warnings, `gbak` backs the file up.
- **Three probe-settled laws**: `blh_max_sequence` is the LAST page
  sequence, not the count — ods.h's "Number of data pages" comment
  misleads, `blb.cpp:2377`'s `>` test decides, and the engine
  reading one page past a count-valued vector (then declaring the
  file corrupt) is how the law announced itself. `blh_length`
  counts payload with framing excluded (OCTET_LENGTH equals it at
  every level). And `rhd_blob`/`rhd_stream_blob` are 16/32 — a
  first-guess 8 made every real blob "not a blob".
- **Extensive companion documentation**:
  [docs/blob-conversion.md](docs/blob-conversion.md) — placement,
  the three levels, pinned layouts, framings, the probe log, the
  two-direction oracle design, scope table and roadmap.

### Guarded
- Level-2 CREATION (refuses past the level-1 vector ceiling), blob
  GC, blob filters, stream-blob creation, temporary blobs. 8 unit
  tests (offset pins, round-trips, zero-length segments, stream
  truncation, empty blobs, vector termination, ceiling math); gate
  `qa/blb-levels.sh` (15 checks, both directions, levels asserted
  0/0/null/0/1/2); 260 workspace tests.

## 2026-07-29 — fire-crab-lck slice 1: the lock table's policy

### Converted
- **A NEW CRATE for `src/lock/lock.cpp`** — the lock table that
  arbitrates every shared resource: modes (`LCK_none..LCK_EX`,
  values identical), the compatibility matrix (transcribed from
  `lock.cpp:150`), the `lbl_counts` + `lbl_state` single-aggregate
  grant probe (`lock.cpp:2228` — sound because granted sets are
  mutually compatible; the companion doc carries the argument),
  enqueue with WAIT / NO WAIT, convert (tested against everyone
  ELSE's aggregate, `lock.cpp:2535`), dequeue with the FIFO
  `post_pending` regrant, queue fairness (a late compatible arrival
  parks behind a blocked head — no starvation), and the wait-for
  deadlock scan with the scanning request as victim.
- **Two oracles.** The SOURCE pin: `fclck pin-source` re-parses the
  `compatibility[LCK_max][LCK_max]` initializer out of the vendored
  engine and diffs all 49 cells against the crate's constant — the
  transcription itself is under differential test. And the LIVE
  matrix: `SET TRANSACTION RESERVING` maps reservation modes onto
  LCK_SR/SW/PR/PW, so four fifo-held modes probed by four `NO WAIT`
  reservations give 16 engine-arbitrated cells, every one equal to
  `fclck compat` — including the famous SR-beside-PW COMPATIBLE
  (protected write excludes other writers, not MVCC readers). A
  live two-attachment cross-update then draws the engine's own
  SQLSTATE 40001 deadlock — the cycle the crate's scan denies.
- **Extensive companion documentation**:
  [docs/lock-manager-conversion.md](docs/lock-manager-conversion.md)
  — the two layers, the scope table, the matrix's meaning, the
  aggregate-soundness argument, the three verbs, FIFO fairness, the
  deadlock scan, both oracles, the probe log and the roadmap.

### Guarded
- The arena (shared memory, hash chains), blocking-AST delivery,
  lock data words, timeouts and series semantics ride later slices.
  8 unit tests; gate `qa/lck-reserving-matrix.sh` (source pin + 16
  live cells + live deadlock, all green first run — the embedded
  engine refuses a second attachment, so the gate drives the REAL
  server); 252 workspace tests.

## 2026-07-29 — fire-crab-cch slice 1: the careful-write precedence graph

### Converted
- **A NEW CRATE for the mechanism that replaces a write-ahead log.**
  `fire-crab-cch` converts cch.cpp's precedence graph: `CCH_fetch` /
  `CCH_mark`, `CCH_precedence`/`check_precedence` (the referenced
  page reaches disk before the page that references it; an edge that
  would close a cycle is not added — the window page is written
  immediately instead), `write_buffer`'s recursive higher-queue
  drain (what makes the graph load-bearing rather than advisory) and
  `clear_precedence`.
- **The crash-matrix differential**: `fccch crash-matrix` runs a
  relation-growing insert batch through fire-crab's own write path
  (header, TIP, PIP, pointer and data pages all change), flushes
  through the graph, and materializes every crash prefix. The ENGINE
  judges each one: `gfix -v -full -n` — no errors at any careful
  prefix; `isql` — exactly the pre-operation committed rows on every
  partial prefix (the TIP commit flip goes LAST, so the interrupted
  work is simply not there), all 122 on the full one.
- **The teeth**: the naive reverse order breaks at 5 of 8 prefixes —
  wrong-page-type corruption, file-shorter-than-expected read
  failures, and PHANTOM ROWS from the uncommitted insert (a
  readable, validating-adjacent file answering rows that were never
  committed — the class careful writes exist to prevent).
- **A rule the gate itself probed**: the PIP bit goes out AFTER the
  data page it allocates but BEFORE the pointer that names it. The
  draft had PIP last; a pointer-ahead-of-PIP prefix validated with
  page ERRORS. The right side's window shows only a benign orphan
  WARNING — space leaked, data never harmed, the artifact a real
  kill -9 can leave.

### Guarded
- 4 unit tests (chain drain order, cycle fallback, clean pages
  impose no order, prefixes grow the file like a disk); 244
  workspace tests; exe gate 20/20 intact.

## 2026-07-29 — fire-crab-exe slice 1: the BLR request executor

### Converted
- **A NEW CRATE, and the third direction of the same oracle.** The
  dsql crate PRODUCES the engine's bytes; the ods crate READS the
  engine's pages; `fire-crab-exe` now RUNS the bytes against the
  pages — `src/jrd/exe.cpp`'s statement looper over the
  `src/jrd/recsrc/` record sources. `fcexe <db> <proc>` reads
  `RDB$PROCEDURE_BLR` (the blob fcdsql matches byte-for-byte),
  parses the `FOR SELECT ... DO SUSPEND` wrapper — messages,
  INTERLEAVED declares+inits (the law the dsql side probed, read
  back), stall, labels, the for-loop, the twin sends with the EOF
  short — and executes it: FullTableScan (`visible_rows`, the
  VIO_get visibility rule) under FilteredStream (three-valued
  booleans: wide-integer numeric alignment, PAD-SPACE text, Kleene
  AND/OR) under SortedStream (blr_sort; **NULLs sort LOW — first
  ascending, last descending — probed against the live engine, the
  draft had it backwards**).
- **The loop closes**: SQL → (fcdsql, byte-checked at the catalog)
  BLR → (fcexe) rows `==` `SELECT * FROM <proc>` on the C++ engine.
  Gate: `qa/exe-run-blr.sh` — 15 checks each asserting BOTH arrows
  (fcdsql still matches the stored bytes, fcexe's rows match the
  engine's), plus 5 refusals.

### Guarded
- Input parameters (blr_receive), aggregates, joins, value
  expressions, the singular SELECT INTO shape — unknown verbs
  refuse, never guess. 240 workspace tests; all dsql/wire gates
  green.

## 2026-07-29 — fire-crab-wire: UPDATE OR INSERT

### Converted
- **`UPDATE OR INSERT INTO t (cols) VALUES (...) [MATCHING (cols)]`** —
  the engine's upsert, desugared at prepare into the UPDATE and INSERT
  plans the server already runs: try the update whose WHERE is the
  MATCHING columns, store when no row moved — the same execution plan
  `UpdateOrInsertNode` compiles. The MATCHING list defaults to the
  table's PRIMARY KEY columns, read from the catalog (multi-column
  keys included); the statement types as an INSERT, as the engine
  types it.
- **The engine's specific error where the key is missing**: a PK-less
  table without MATCHING refuses AT PREPARE with `isc_dsql_error` +
  `isc_primary_key_required` — `Primary key required on table
  "PUBLIC"."T"`, SQLSTATE 22000 — the one line that names what to
  fix, where the generic Dynamic SQL Error would hide it. (This came
  in as a user report: the upsert on a PK-less table "should work" —
  the engine itself requires MATCHING there, and now fire-crab says
  so in the engine's words.)

### Guarded
- `?` parameters (the two desugared plans would double-bind one
  client message), NULL matching values (the engine compares MATCHING
  with null-safe `blr_equiv`; a plain `=` would silently mis-match),
  RETURNING, a missing column list. Gate: `qa/serve-real-upsert.sh`
  (17 checks — the same script through fcwire and the C++ engine
  leaves two files the engine reads identically; gfix + gbak
  validate); 6 regression gates + 237 workspace tests green.

## 2026-07-29 — fire-crab-dsql slice 42: DISTINCT, PLAN INDEX, ROWS m TO n

### Converted
- **DISTINCT in body FOR SELECTs** (flip fifty-nine): `blr_project`
  over the select columns AFTER the boolean — the slice-6 view law
  landing at body numbering unchanged; multi-column and ORDER BY
  variants live-verified by the gate, never separately probed.
- **PLAN (tbl INDEX (names))** (flip sixty — a slice-41 refusal):
  `blr_indices` + a count + counted index names standing where
  `blr_sequential` stood; two-index plans battery-verified.
- **ROWS m TO n** (flip sixty-one): the legacy row limits desugar
  to UNFOLDED arithmetic — first = add(subtract(n, m), 1), skip =
  subtract(m, 1) — literal expression trees in the same rse slots
  OFFSET/FETCH fills.

### Guarded
- Recursive CTEs probed and named: WITH RECURSIVE = `blr_recurse`,
  a union-like whose anchor branch is an ordinary rse + map but
  whose RECURSIVE branch has ZERO streams — it reads the
  recursion's own context by fid. Transcript held. Also: ROWS n
  alone, ROWS with parameter bounds, DISTINCT in the singular
  form / over aggregates / over joins, empty index lists, PLAN
  JOIN. Gate: `qa/dsql-proc-blr.sh` grew to 253 checks (11
  fresh); 381 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 41: five doors - sort exprs, window exprs, OFFSET/FETCH, PLAN, params in HAVING

### Converted
- **Expression sort keys** (flip fifty-four): the raw expression in
  the sort clause — bare literals refuse (the engine reads them as
  POSITIONS, a wrong-bytes hazard closed at the same stroke).
- **Window passthrough expressions** (flip fifty-five): fields into
  the default window's map, the item rebuilt over the fids — the
  group-expression law in window clothing.
- **OFFSET/FETCH** (flip fifty-six): the standard spelling of SKIP
  and FIRST — the same rse clauses in the same probed order. PLAN,
  NATURAL, OFFSET, ROWS and ONLY joined the keyword list (PLAN was
  being slurped as a table ALIAS — the alias trap again).
- **PLAN (tbl NATURAL)** (flip fifty-seven): `blr_plan` +
  `blr_retrieve` + the stream re-emitted + `blr_sequential`, LAST
  in the rse after the sort. Other plan forms refuse.
- **Parameters in HAVING** (flip fifty-eight — a slice-9 refusal,
  thirty-two slices old, felled by the gate's own battery
  statement): parameters and variables pass through the aggregate
  boundary plainly.
- **HAVING without GROUP BY** — pinned: an aggregate with zero
  group keys, live through composition all along.

### Guarded
- ORDER BY positions, PLAN INDEX/ORDER/JOIN forms, OFFSET/FETCH
  with parameters. Gate: `qa/dsql-proc-blr.sh` grew to 243 checks
  (7 fresh); 369 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 40: item expressions, group-expr keys, multi-ctes

### Converted
- **Select-item expressions** (flip fifty-one): body FOR SELECT and
  SELECT INTO items are FULL value expressions at the stream
  context — parsed by the general val() (bare names resolve as
  COLUMNS there; the stream scope is set), plain columns keeping
  their shape for the aggregate/cursor paths.
- **GROUP BY expressions** (flip fifty-two — slice 39's transcript
  cashed): the group list takes the raw expression, the map carries
  its BARE fields, and select items REBUILD over the mapped fids —
  in SELECT-ITEM order, each item contributing its fields (deduped)
  or its aggregate verb, the slice-8 map law generalized. ORDER BY
  keys over aggregates rebuild the same way — the gate itself
  caught `ORDER BY SALARY / 1000` refusing and forced the fix.
- **Multiple ctes** (flip fifty-three): comma-separated WITH lists,
  each expanding once at its FROM reference — one pinned expanding
  inside a correlated subquery.

### Guarded
- Select items whose fields aren't group-key fields, non-aggregate
  expression ORDER keys, twice-referenced/unreferenced ctes,
  expression passthrough beside windows. Gate: `qa/dsql-proc-blr.sh`
  grew to 236 checks (5 fresh); 363 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 39: WITH ctes, expression INSERT..SELECT

### Converted
- **WITH ctes** (flip forty-nine): the engine INLINES a
  non-recursive cte as a DERIVED table — the cte name becomes the
  relation2 alias (`"W1" "PUBLIC"."U2"`), column aliases translate,
  inner WHERE inside, exactly the derived machinery by another
  syntax. The parser records the body's token SPAN at WITH and
  expands it at the FROM reference — one cte, referenced exactly
  once (recursion refuses because the expansion consumes the single
  use). Works in the singular SELECT INTO and FOR loops.
- **Expression INSERT..SELECT** (flip fifty — the FIFTIETH refusal
  to fall): source items are FULL value expressions at the source
  stream, via the same two-phase list parse every select uses.

### Probed, unconverted
- **GROUP BY expressions**: the expression rides the group list but
  the map carries the BARE fields, and select items are REBUILT
  over the mapped fids — a named refusal with its transcript.

### Guarded
- GROUP BY expressions, multiple ctes, twice-referenced ctes,
  unreferenced ctes, INSERT..SELECT over aggregates. Gate:
  `qa/dsql-proc-blr.sh` grew to 232 checks (6 fresh — a
  two-column cte, one correlated through EXISTS from the cte's
  derived stream); 360 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 38: body unions, INSERT..SELECT

### Converted
- **UNION in body FOR SELECTs** (flip forty-seven — slice 37's
  transcript cashed): `blr_union` claims the statement's FIRST
  slot — a lookahead reserves it before the branch streams number —
  with per-branch rses (each WHERE inside) and maps; a DISTINCT
  union appends `blr_project` over the union fids; duplicate select
  columns keep separate slots; INTO reads union fids. UNION ALL
  chains of any length; mixed ALL/distinct refuses.
- **INSERT ... SELECT** (flip forty-eight — a refusal named in
  slice 12, twenty-six slices ago): a marks(1, 4)-stamped FOR loop
  over the source rse storing one row per source row — the SOURCE
  stream numbers FIRST, the target claims the next slot. Plain and
  qualified source columns, a source WHERE, working in procedures,
  subroutines and triggers.

### Guarded
- Mixed ALL/distinct unions, unions beside every other structure
  (sorts, cursors, locks, aggregates, windows, joins, derived),
  INSERT..SELECT with expressions or aggregates. Gate:
  `qa/dsql-proc-blr.sh` grew to 226 checks (6 fresh — a
  three-branch union with aliases, INSERT..SELECT inside a
  subroutine), `qa/dsql-trig-blr.sh` holds 48 with the trigger
  INSERT..SELECT flipped; 353 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 37: derived-column aliases

### Converted
- **Derived-column aliases** (flip forty-six — slice 36's refusal,
  transcript in hand): `(SELECT UID AS X FROM U2) D` records an
  outer-to-inner name map, and every outer reference to `X` —
  qualified or bare, in select items, WHEREs, ORDER keys or
  correlated subqueries — TRANSLATES to the inner column at the
  shared context: `D.X` emits the underlying `UID`. One translation
  point in the field resolver; the three hardcoded bare-name parse
  sites now route through it (which also carries their join-refusal
  and gains the translation for free).

### Probed, unconverted
- **UNION in body FOR SELECTs**: `blr_union` claims the statement's
  FIRST slot with branch streams following and fid outputs — a
  named refusal with the transcript. **Named windows** (WINDOW W
  AS): the engine's own resolver rejected both probe placements —
  guarded as an engine-side blocker.

### Guarded
- UNION in bodies, named windows, derived expressions/stars. Gate:
  `qa/dsql-proc-blr.sh` grew to 220 checks (6 fresh — a two-alias
  derived pair, one under IN (SELECT), one correlated through
  EXISTS); 349 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 36: NTH_VALUE, derived tables in bodies

### Converted
- **NTH_VALUE** (flip forty-four): canonicalizes like its LAG/LEAD
  siblings — a FROM FIRST indicator (literal 0) appended as the
  third `blr_agg_function` argument.
- **Derived tables in body FOR SELECTs** (flip forty-five): the
  view convention at body numbering — the inner rse in the stream
  slot with alias text `"D" "PUBLIC"."U2"`, the inner WHERE inside
  it, the outer WHERE at the rse level, ONE shared context.
  Pass-through column lists only (a derived-column alias needs
  outer-to-inner name mapping — guarded with the transcript).
- **Derived tables in subqueries** — pinned: the shape was LIVE
  through composition since the subquery slice (stream_item always
  could return a derived stream), compiling byte-identical without
  a single covering test until now.

### Guarded
- Derived-column aliases, derived streams beside aggregates/
  windows/joins/cursors/locks, named windows (the WINDOW clause —
  the engine's own placement rules resisted the probe). Gate:
  `qa/dsql-proc-blr.sh` grew to 214 checks (6 fresh); 347 unit
  byte-pins.

## 2026-07-29 — fire-crab-dsql slice 35: windowed argument functions, frame extents

### Converted
- **LAG / LEAD / FIRST_VALUE / LAST_VALUE** (flip forty-two):
  argument-taking window functions under `blr_agg_function` — a
  counted name and true argument count. LAG and LEAD canonicalize
  to THREE arguments: the value, the offset (filled with literal 1
  when omitted), and the default (filled with blr_null) — probed
  against explicit-argument forms sharing one window.
- **Frame extents** (flip forty-three — slice 34's refusal): a
  framed window switches to the v4 `blr_window_win` verb with
  subcoded clauses — 1 partition (the v3 layout under a tag), 2
  order, 3 map, 4 extent unit (RANGE 0 / ROWS 1), 5 frame bound
  (frame number + bound code: 0 preceding / 1 following / 2
  current row), 6 frame value — and its OWN blr_end where the v3
  form leans on the shared rse end. UNBOUNDED is a bound sans
  value; a single-bound frame implies CURRENT ROW as frame two.
  v3 and v4 windows mix freely in one statement.

### Guarded
- NTH_VALUE, exclusion clauses, frames without an ORDER BY, named
  windows (the WINDOW clause). Gate: `qa/dsql-proc-blr.sh` grew to
  208 checks (7 fresh — among them LAST_VALUE over an
  UNBOUNDED-to-UNBOUNDED range and a mixed framed/unframed pair);
  343 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 34: window functions

### Converted
- **Window functions** (flip forty-one): `<fn> OVER ([PARTITION BY
  ...] [ORDER BY ...])` in FOR SELECT bodies — `blr_window` wraps
  the inner rse (its WHERE inside), then a window count and per
  window `blr_partition_by`: context, partition keys as source
  fields then REMAPPED as fids into the window's own map, a sort
  clause, the map. The laws: passthrough columns live in the
  DEFAULT (empty-spec) window beside empty-spec OVER () functions;
  each distinct (partition, order) spec gets its own window, in
  ENCOUNTER order, claiming the contexts after the stream; a
  window's map holds its items in select order with the partition
  keys appended; outputs read fids at per-window contexts. The
  aggregate verbs work windowed, and the named zero-argument
  functions (ROW_NUMBER, RANK, DENSE_RANK) ride
  `blr_agg_function` — a counted name and an argument count. The
  battery's RANK / DENSE_RANK / three-item multi-window /
  two-key-partition checks were never probed — green on the
  convention alone.

### Guarded
- Frame extents (ROWS/RANGE BETWEEN — the v4 `blr_window_win`
  verb), windows beside aggregates/GROUP BY/joins/statement ORDER
  BY, the singular form, named windows. Gate: `qa/dsql-proc-blr.sh`
  grew to 201 checks (7 fresh); 337 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 33: aggregates over joins, joined cursors

### Converted
- **Aggregates over joins** (flip thirty-nine — slice 32's own
  refusal): the join chain sits INSIDE the aggregate's inner rse
  with the WHERE after it, and the aggregate claims the slot after
  ALL the join streams (a joined COUNT put it at 2 over streams 0
  and 1) — the slice-8 next-slot law counting past a chain. GROUP
  BY with qualified keys, HAVING and ORDER BY ride the existing
  map machinery.
- **Joins in cursor declarations** (flip forty): BOTH streams carry
  the cursor pairing — `"CX" "A"` and `"CX" "B"` — the slice-31
  infection reaching the chain via the same cur stamp; each
  output's derived_expr wrap names its column's OWN stream (probed:
  `BF 01 00` then `BF 01 01`), and FETCH reads fields at per-stream
  contexts. Positioned DML on a joined cursor refuses (not
  updatable), as do aggregate joined cursors and WITH LOCK over
  chains.

### Guarded
- Aggregate cursors over joins, positioned DML on joined cursors,
  joins under AS CURSOR, subqueries in joined-cursor WHEREs (the
  scope refuses them). Gate: `qa/dsql-proc-blr.sh` grew to 194
  checks (6 fresh); 327 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 32: joins in body FOR SELECTs, packaged calls

### Converted
- **Joins in body FOR SELECTs** (flip thirty-seven): INNER/LEFT/
  RIGHT/FULL join chains compile in FOR SELECT and the singular
  SELECT INTO — the view's left-nested chain at body numbering, ON
  at the join level, WHERE at the rse level, join_type absent for
  INNER. The MERGE scope generalized to a RANGE of stream indexes:
  qualified names resolve across the chain, and BARE names refuse —
  the gate itself caught a bare column binding to the FIRST stream
  where the engine resolves through the catalog (a wrong-bytes
  hazard closed before it shipped). A three-stream chain and a FULL
  OUTER under the singular form pinned.
- **Packaged routine calls** (flip thirty-eight):
  `EXECUTE PROCEDURE PKG.P` = `blr_exec_proc2` (counted package +
  name, exec_proc-style u16 counts); `PKG.F(x)` in expressions =
  `blr_function2` (package, name, a count BYTE, the arguments) —
  compact verbs, not the invoke forms subroutines take.

### Guarded
- Aggregates over joins, joins under AS CURSOR, bare columns
  across a join, subqueries inside ON clauses, derived streams in
  chains. Gate: `qa/dsql-proc-blr.sh` grew to 188 checks (6
  fresh); 323 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 31: the cursor-alias infection, DISTINCT scalars

### Converted
- **Subqueries inside cursor rses** (flip thirty-five — slice 30's
  guarded law, converted with its transcript): every stream under a
  cursor's rse — subquery streams included — carries the cursor's
  concatenated alias: the cursor name paired with the stream's own
  alias (`"CX" "X"`) or its schema-qualified name
  (`"CX" "PUBLIC"."T"`). Implemented as a post-parse STAMP walking
  the boolean tree (the AS CURSOR name isn't known until after its
  WHERE parses), a `cur` slot on the stream, and one emission
  branch; relation3 takes the same string in its alias slot inside
  subroutines — DECLARE CURSOR, AS CURSOR, and cursor-in-subroutine
  all pinned. Found on the way: subselect's ON-clause guard
  (`outer` = None) also fired during declare sections — `outer`
  now sets before the declares.
- **DISTINCT aggregate scalars** (flip thirty-six): the dedicated
  verbs for COUNT/SUM/AVG, MIN/MAX folding DISTINCT away — the
  slice-10 law reaching the scalar-subselect surface.

### Guarded
- Quantified comparisons over aggregate output, derived tables in
  subqueries, subqueries in MERGE ON clauses. Gate:
  `qa/dsql-proc-blr.sh` grew to 182 checks (4 fresh + slice 30's
  refusal flipped); 314 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 30: aggregate scalar subselects

### Converted
- **Aggregate scalar subselects** (flip thirty-four — slice 29's
  refusal, transcript in hand): `(SELECT MAX(ID) FROM T [WHERE])`
  as a value compiles to `via(singular, rse1(aggregate at the NEXT
  slot over the inner rse — its WHERE INSIDE — zero group keys, a
  one-slot map), fid(agg, 0), null)`. The aggregate claims the slot
  after its stream, as everywhere; in a FOR's WHERE the subquery
  stream lands at 1 over the FOR's 0 with the aggregate at 2. All
  five verbs plus COUNT(*)/COUNT(col); works in assignments, WHERE
  comparisons, SET values, and inside subroutine bodies (battery).
- EXISTS inside subroutine bodies pinned by composition —
  relation3's empty alias slot on the subquery stream.

### Guarded
- Subqueries inside a CURSOR's rse — their streams INHERIT the
  cursor alias string (probed: the EXISTS stream carried
  `"CX" "PUBLIC"."T"`), a peculiar law left with its transcript;
  quantified comparisons over aggregate output; DISTINCT aggregate
  scalars. Gate: `qa/dsql-proc-blr.sh` grew to 178 checks (8
  fresh); 311 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 29: subqueries in bodies, aliased AS CURSOR

### Converted
- **Subqueries in body statements** (flip thirty-two — the second
  slice-7 refusal to fall in two slices): EXISTS/SINGULAR,
  IN (SELECT)/ANY/ALL and scalar subselects work in body WHEREs and
  assignments. The whole view-compiler subquery machinery carried
  over on TWO changes: the subquery stream takes the NEXT context
  id in the statement's numbering (`si + base` — the view formula
  was this law at base 1 all along), and the enclosing statement's
  stream stays visible to QUALIFIED names (a `host` slot in the
  field resolver — probed: an EXISTS correlated on the FOR's table
  by name). A scalar subselect in an assignment claims ctx 0.
- **Aliased AS CURSOR** (flip thirty-three): the cursor name pairs
  with the table ALIAS — `"CU" "E"` — the DECLARE CURSOR law; in a
  subroutine the same string rides relation3's alias slot (battery,
  by composition).

### Guarded
- Aggregate scalar subselects (`(SELECT MAX(..) ...)` — transcript
  in hand), joins/comma-FROM inside subqueries, subqueries in ON
  clauses. Gate: `qa/dsql-proc-blr.sh` grew to 170 checks (9
  fresh — among them NOT EXISTS, > ALL, IF (EXISTS ...) and
  back-to-back scalar subselects); 305 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 28: aliased streams, subroutines in triggers

### Converted
- **Aliased streams in body statements** (flip thirty — one of the
  OLDEST refusals, named in slice 7): `FOR SELECT ... FROM T E`,
  `DELETE FROM T E`, `UPDATE T E SET ...` all compile — relation2
  with the quoted alias at top level, relation3 with the alias in
  its always-present slot inside subroutines (the QV4 transcript),
  qualified references resolving through the one stream with the
  field machinery unchanged. Aliased aggregate sources with
  qualified group keys ride along.
- **Subroutines in trigger bodies** (flip thirty-one): DECLARE
  PROCEDURE/FUNCTION takes the same grouped-declare slot cursors do
  — the sub_decl machinery shared verbatim, sub calls working from
  trigger statements (a probe passed NEW.ID as a sub-function
  argument, resolved in the OUTER trigger scope).

### Guarded
- Aliased streams under AS CURSOR (the alias string's shape
  unprobed), aliased positioned DML, derived FOR streams. Gate:
  `qa/dsql-proc-blr.sh` grew to 161 checks (7 fresh + the slice-7
  alias refusal flipped to a check), `qa/dsql-trig-blr.sh` to 48;
  302 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 27: streams inside subroutines

### Converted
- **blr_relation3** (flip twenty-nine — slice 26's refusal, the
  transcript already in hand): inside a SUBROUTINE body every
  stream qualifies itself — counted schema `PUBLIC`, counted EMPTY
  package, the name, then the alias slot relation2 would carry (the
  quoted alias, a cursor's name string) or a counted empty when
  relation-plain, then the context. The layout read from the
  engine's own `RelationSourceNode::genBlr` — the mystery byte
  between schema and name was the empty package string. ONE
  emission switch (a `sub` flag on the stream, set at parse) turns
  the whole converted surface loose inside subroutines: INSERT,
  DELETE/UPDATE loops, singular SELECT INTO over aggregates,
  FOR SELECT, DECLAREd cursors, AS CURSOR loops with positioned
  DML, UPDATE OR INSERT and MERGE — the battery runs them all,
  most never probed in subroutine clothing.
- **Zero-argument sub-function calls** flipped with the gate's own
  find: `F()` compiles — the argument tag rides along with count 0
  where invoke_procedure omits its empty tags.

### Guarded
- Derived tables inside subroutines, nested subroutines, aliased
  FOR streams (top level and sub alike — the relation3-with-alias
  transcript is in hand). Gate: `qa/dsql-proc-blr.sh` grew to 155
  checks (8 fresh + slice 26's streams refusal flipped to a check);
  296 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 26: subroutines, named ES parameters - and a latent fix

### Converted
- **DECLARE FUNCTION** (flip twenty-six): `blr_subfunc_decl` —
  counted name, type 0, a deterministic/aggregate flag byte,
  u16-counted parameter-name lists (the return slot an UNNAMED
  output), then the WHOLE inner body's BLR as a u32-counted blob —
  compiled by the same body machinery as top-level procedures on a
  fresh parser. RETURN <expr> = begin(assign the unnamed slot 0,
  the no-EOF send, blr_leave 0); function sends DROP the EOF
  assignment their message still declares. Calls are
  `blr_invoke_function` value expressions: id clause (4 sub, 3
  counted name), u16-counted arguments.
- **DECLARE PROCEDURE** (flip twenty-seven): `blr_subproc_decl`,
  same frame with a SELECTABLE flag (a SUSPEND anywhere inside);
  calls take `blr_invoke_procedure` with input values (tag 3) and
  output variables (tag 5). A void subroutine goes WITHOUT
  blr_stall where a top-level body keeps it.
- **Named EXECUTE STATEMENT parameters** (flip twenty-eight,
  slice 25's refusal): tag 12 with a counted name before each
  value; plus the modifiers ON EXTERNAL (5) / AS USER (6) /
  PASSWORD (7) / ROLE (14) — clause order from the engine's own
  genBlr; a modifier alone forces the FULL blr_exec_stmt form even
  on a parameterless literal.

### Fixed
- **The declare-section law, re-read**: a two-local probe showed
  procedure LOCALS group — declare, declare, init, init — NOT the
  per-variable interleave sixteen slices had assumed (outputs DO
  interleave; single-local bodies can't tell the difference, and no
  battery statement had two inited locals). The slice-21 "deferral"
  law was this grouping all along. A latent wrong-bytes path,
  closed with pins at top level, in sub-procedures and in
  sub-functions.

### Guarded
- Streams inside subroutine bodies (they emit blr_relation3 with an
  explicit schema — probed, unconverted), nested subroutines,
  zero-argument sub-function calls, RETURN outside functions,
  SUSPEND inside them, mixed named/unnamed ES parameters. Two more
  subroutine laws pinned on the way: a SUBROUTINE's inputs RESERVE
  variable slots (locals number past them — top-level bodies don't)
  — gate: `qa/dsql-proc-blr.sh` grew to 147 checks (12 fresh); 291
  unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 25: MERGE branch chains, parameterized EXECUTE STATEMENT, WITH LOCK

### Converted
- **Multi-branch MERGE** (flip twenty-three): branches of one kind
  form an if-else CHAIN in SQL order — each conditional branch
  `if(cond, action, <next>)` where the next if fills the else slot
  BY POSITION, the last conditional getting a bare end, an
  unconditional LAST branch filling the else directly. The rse
  boolean ORs kind-terms built from left-nested or-chains:
  `and(not(missing), or(c1, c2, ...))` matched /
  `and(missing, or-chain)` not-matched, each simplified to its bare
  missing-test when the kind has an unconditional branch. Contexts
  allocate BY KIND in branch order — every matched UPDATE claims a
  new-record slot, then every INSERT its store slot. A branch after
  its kind's unconditional one refuses (unreachable — one else slot).
- **Parameterized EXECUTE STATEMENT** (flip twenty-four):
  `('<sql>') (vals)` compiles the FULL `blr_exec_stmt` — tag-prefixed
  clauses in fixed order: 1 in-count, 2 out-count, 3 sql, 4 the FOR
  form's DO statement, 11 input values, 13 output variables,
  blr_end. The literal no-param forms keep their compact verbs
  (exec_sql / exec_into).
- **WITH LOCK** (flip twenty-five): `blr_writelock` between the
  stream and the boolean — in FOR SELECT, DECLAREd cursors and AS
  CURSOR loops alike; the battery drives locked cursors through
  positioned UPDATEs in both cursor forms.

### Guarded
- WITH LOCK over aggregates or beside ORDER BY (unprobed emission
  order), named EXECUTE STATEMENT parameters (`a := :v`), branches
  after an unconditional one. Gate: `qa/dsql-proc-blr.sh` grew to
  135 checks (12 fresh); 279 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 24: conditional MERGE, scroll fetch, RETURNING, EXECUTE STATEMENT

### Converted
- **WHEN [NOT] MATCHED AND <cond>**: the condition joins the rse
  boolean's branch term — `and(not(missing), cond)` /
  `and(missing, cond)`, bare cond for a matched-only merge — and
  wraps the branch action in `if(cond, action, bare end)` nested in
  its slot (flip twenty; slice 23's refusal in the gate flipped to
  a check).
- **SCROLL cursors + FETCH directions**: `blr_scrollable` before
  the dcl_cursor rse; `FETCH <dir> FROM c` is cursor_stmt sub-verb
  3 + a direction byte (0 next, 1 prior, 2 first, 3 last, 4
  absolute, 5 relative) + an offset value — `blr_null` unless
  ABSOLUTE/RELATIVE. NEXT works unscrolled; the rest demand SCROLL
  (flip twenty-one).
- **DML RETURNING ... INTO**: three different shapes for one clause
  — INSERT = `blr_store2` with a second returning begin at the
  store's context; UPDATE = `blr_modify2` under a SINGULAR rse,
  returning reading the NEW record; DELETE = NO erase2 at all — a
  begin holding the returning assigns then the PLAIN erase, under a
  singular rse. RETURNING makes the loops singular.
- **EXECUTE STATEMENT**: plain = `blr_exec_sql` + the sql literal;
  `[FOR] ... INTO` = `blr_exec_into` with u16 out-count, the sql,
  flag 1 (singleton) or flag 0 + the labeled loop's DO statement,
  then the variables LAST (flip twenty-two).

### Guarded
- Multiple same-kind MERGE branches (if-else chains, probed but
  unconverted), backward fetch on unscrolled cursors, RETURNING on
  positioned DML, RETURNING expressions, EXECUTE STATEMENT with
  expression sql / USING / external sources. Gate:
  `qa/dsql-proc-blr.sh` grew to 123 checks (13 fresh); 271 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 23: MERGE, AS CURSOR, cursors in triggers

### Converted
- **MERGE**: one probed sentence — `for(marks(1, 6), rse(join2(
  source@0, target@1, [LEFT], ON-boolean), [branch-union boolean]),
  if(<matched test>, ...))`, branching on `missing(dbkey(target))`.
  The join is LEFT only when a NOT MATCHED branch needs unmatched
  rows — matched-only merges compile an INNER join with NO rse
  boolean. The rse boolean ORs the branch conditions in canonical
  order (matched first); SQL branch order leaves NO trace. Branch
  contexts allocate UPDATE's new record first, then INSERT's store
  (update+insert = 2,3; anything-else+insert = 2). The UPDATE half
  is `blr_modify(target, new) + marks(1, 2)` (MARK_MERGE), DELETE is
  the positioned-erase shape with marks(1, 2), INSERT re-emits the
  TARGET stream — alias and all — under `blr_store`. Sources read
  ctx 0, target-org fields ctx 1; bare names refuse (catalog-free).
- **FOR SELECT ... [INTO ...] AS CURSOR name**: the ordinary labeled
  FOR loop whose relation2 alias carries the CURSOR NAME exactly
  like a DECLAREd cursor's — no dcl_cursor, no outputs section. The
  INTO clause becomes OPTIONAL; its assign-sources wrap in
  blr_derived_expr. WHERE CURRENT OF in the DO body targets the
  FOR's own context, in scope for the body only.
- **Cursors in TRIGGER bodies**: DECLARE CURSOR works in triggers —
  the declaration keeps its SOURCE slot among the grouped declares
  (the trigger flavor of the deferral law), numbering past OLD/NEW
  (probed at ctx 2). MERGE and AS CURSOR loops ride along.

### Guarded
- WHEN MATCHED AND <cond>, multiple same-kind MERGE branches,
  sub-select sources, bare names in MERGE scope; ORDER BY on an AS
  CURSOR loop; OPEN/FETCH/CLOSE against a FOR cursor; a FOR cursor
  named outside its loop. Gate: `qa/dsql-proc-blr.sh` grew to 110
  checks (12 fresh), `qa/dsql-trig-blr.sh` to 46 (4 fresh — among
  them a trigger MERGE and a trigger AS-CURSOR positioned update,
  neither probed directly); 261 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 22: cursors completed - aliases, aggregates, positioned DML

### Converted
- **WHEN SQLSTATE '<s>'**: handler code 8 + counted string — flip
  thirteen.
- **Handlers carrying handlers**: a handler's block body with its
  OWN WHEN nests `blr_block` again WITH its own error-handler
  section — the slice-20 refusal flipped (fourteen) by one probe.
- **Cursor table aliases + qualified columns**: with `FROM T A` the
  relation2 alias string becomes `"CX" "A"` — cursor name + table
  alias — replacing the schema-qualified table; qualified columns,
  WHERE and ORDER BY refs resolve through the one visible stream
  (flip fifteen).
- **AGGREGATE cursors**: `blr_aggregate` nests inside the
  dcl_cursor rse at ctx+1 — claiming a SECOND context slot (probed
  on a two-cursor body) — with the WHERE inside the inner rse,
  group_by + map as in FOR SELECT, and the outputs and
  fetch-sources as BARE `blr_fid` slots: no blr_derived_expr
  wrapper (flip sixteen). The engine itself demands AS names for
  aggregate columns — the parser requires them too.
- **Positioned DML**: `DELETE ... WHERE CURRENT OF` is `blr_erase`
  at the CURSOR's own context — no fresh slot — with
  `blr_marks(1, 1)` (MARK_POSITIONED) TRAILING the erase, where a
  DML loop's marks(1, 4) LEAD its rse. `UPDATE ... WHERE CURRENT
  OF` is `blr_modify` from the cursor's context to ONE fresh slot,
  marks(1, 1), then the assignments — SET sources read the
  cursor's context (probed: `SALARY = SALARY + 1`). The INTO-less
  `FETCH` that positions them carries an empty begin/end.

### Guarded
- DISTINCT aggregates, HAVING and ORDER BY in aggregate cursors;
  positioned DML against the wrong table or an aggregate cursor.
  Gate: `qa/dsql-proc-blr.sh` grew to 98 checks (11 fresh — among
  them a WHILE-driven sweep pairing FETCH INTO with a multi-column
  positioned UPDATE, never probed directly); 247 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 21: autonomous transactions and cursors

### Converted
- **IN AUTONOMOUS TRANSACTION DO**: `blr_auto_trans`, a sub-code
  byte (0), the statement — composing with blocks and POST_EVENT in
  the battery.
- **Multi-column MATCHING**: one `blr_equiv` per column, left-nested
  under `blr_and` (probed on two, batteried on a three-column upsert
  matching two).
- **WHEN SQLCODE <n>**: handler code 1 + i16 little-endian — flip
  twelve.
- **CURSORS**: `DECLARE name CURSOR FOR (SELECT ...)` is
  `blr_dcl_cursor` — u16 number, the rse whose relation2 alias
  carries the CURSOR NAME like a derived table's, u16 output count,
  `blr_derived_expr`-wrapped outputs. OPEN/CLOSE/FETCH are
  `blr_cursor_stmt` sub-verbs 0/1/2, fetch carrying its
  into-assignments. The battery drives a cursor through a WHILE loop
  guarded by ROW_COUNT.
- **A new ordering law, pinned three ways**: a variable's INIT is
  DEFERRED past cursor declarations that follow it — flushing before
  the next variable's declare or at the section end. Found by the
  gate (a cursor-after-variable battery statement), settled by two
  targeted probes.

### Guarded
- WHEN SQLSTATE (unprobed layout), qualified cursor columns,
  aggregate cursor selects. Gate: `qa/dsql-proc-blr.sh` grew to 87
  checks; 236 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 20: UPDATE OR INSERT and settled probes

### Converted
- **UPDATE OR INSERT**, from the shape slice 19 probed: a begin
  holding a marks-stamped modify-loop whose boolean is `blr_equiv`
  (0x2E — null-safe equality) on the MATCHING column, then
  `if(row_count = 0, store)`. Contexts allocated store, modify-new,
  rse-org IN THAT ORDER — the INSERT half claims its slot first.
  MATCHING is REQUIRED (the default needs the primary key — the
  catalog) and single-column (more are unprobed). The battery runs
  one with an expression VALUES (`:P1 * 10`).
- **CURRENT_CONNECTION / CURRENT_TRANSACTION**: internal_info(1) and
  (2) — the context-code family grows (5=ROW_COUNT, 6=trigger
  action).
- **Slice 19's named probes settled — flips ten and eleven**:
  MULTIPLE handlers per block emit one error-handler section per
  WHEN, sequential; a BLOCK as a handler's body nests blr_block
  AGAIN with no handler section of its own. Both pinned.

### Guarded
- UPDATE OR INSERT without MATCHING (a primary-key catalog lookup),
  multi-column MATCHING, handlers that carry their own handlers.
  Gate: `qa/dsql-proc-blr.sh` grew to 80 checks (6 fresh); 225 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 19: error handling

### Converted
- **WHEN handlers**: a BEGIN..END carrying WHEN becomes `blr_block`
  — a begin with the guarded statements, `blr_error_handler` with a
  u16 code count and the code, the handler STATEMENT, blr_end. Three
  code kinds probed: WHEN ANY = blr_default_code (4); WHEN EXCEPTION
  <name> = 9, 0, counted name; WHEN GDSCODE <name> = 0, counted
  UPPERCASED name. Handlers work in procedures and triggers alike.
- **The plain-block law confirmed**: a nested BEGIN..END WITHOUT
  handlers stays a DOUBLE begin in both body kinds — blr_block
  belongs to handler-carrying blocks only (a proc IF-block probe
  settled it).
- **ROW_COUNT**: blr_internal_info(5) — beside the trigger-action
  code 6, one family of context codes. The battery feeds it from
  UPDATE and DELETE and guards an EXCEPTION with it.
- **UPDATE OR INSERT probed**, not yet converted: a modify-loop plus
  a row_count-guarded store, with blr_equiv (0x2E — null-safe
  equality) for MATCHING. It holds a named refusal until the next
  slice.

### Guarded
- A BLOCK as a handler body (blr_block nests differently there),
  WHEN SQLCODE/SQLSTATE, multiple handlers per block, UPDATE OR
  INSERT. Gate: `qa/dsql-proc-blr.sh` grew to 73 checks (6 fresh:
  WHEN ANY DO EXIT, division guarded by a parameter, ROW_COUNT into
  IF/EXCEPTION); 220 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 18: domain validation, sequences, events

### Converted
- **The SEVENTH catalog store: domain validation.** A DOMAIN's CHECK
  lands in `RDB$FIELDS.RDB$VALIDATION_BLR` — and its shape DIFFERS
  from a table CHECK's system trigger: the RAW boolean, NOT negated,
  no abort wrapper, between blr_version5 and blr_eoc, with VALUE
  compiling to `blr_fid(0, 0)`. The same clause keyword, two stores,
  two shapes — routed by whether the clause speaks of VALUE.
- **Sequences, two verbs for one concept**: `GEN_ID(seq, inc)` is
  blr_gen_id (counted name + increment value) while
  `NEXT VALUE FOR seq` is blr_gen_id2 (the name alone) — the verb
  chosen by SYNTAX, not semantics.
- **POST_EVENT <value>;**: blr_post + the event-name value, a
  statement in either body kind (a conditional POST_EVENT under IF
  is in the battery).

### Guarded
- (nothing new — the surface grew cleanly.) Gates:
  `qa/dsql-field-blr.sh` grew to 39 checks (5 validations incl.
  VALUE IN (1,2,3) — integer items stay uncast even against a fid)
  and `qa/dsql-trig-blr.sh` to 42; 214 unit byte-pins across seven
  stores.

## 2026-07-28 — fire-crab-dsql slice 17: constraints and two more stores

### Converted
- **Domain defaults**: `RDB$FIELDS.RDB$DEFAULT_VALUE` — the same
  minimal frame as column defaults, read from the domain's catalog
  row (`compile_default` unchanged; the gate grew a domain section).
- **Expression indexes**: `RDB$INDICES.RDB$EXPRESSION_BLR` — a
  COMPUTED BY expression byte-shaped exactly like a computed
  column's (`compile_computed` unchanged; new gate section).
- **CHECK constraints**: the engine's OWN system triggers
  (RDB$TRIGGERS types 1 and 3 — byte-identical): begin, blr_if over
  the NEGATED condition — `CHECK (A < B)` stores blr_geq, the NOT
  fold reused — whose then-branch is blr_abort with blr_gds_code
  'check_constraint', a bare-end else, fields at CONTEXT 1 (the NEW
  record). `compile_check` handles the clause.

### Fixed
- **The CHECK battery exposed a LATENT VIEW-COMPILER GAP**: the
  engine CASTS non-integer IN-list items to the left side's CATALOG
  type — `S IN ('a','b')` stores blr_cast varying2(10) per item, the
  column's declared type, in views and CHECKs alike — and fire-crab
  had only ever pinned integer IN-lists, so a string IN-list would
  have emitted UNCAST bytes. Probed in both stores, then closed:
  integer literals and input parameters (both probed uncast) stay;
  everything else refuses. A refusal slot went into the view gate
  beside the fix.

### Guarded
- String and decimal IN-list items (catalog casts), CHECKs with
  string IN-lists. Gate: `qa/dsql-field-blr.sh` grew to 34 checks
  (12 fresh: 3 domains, 3 indexes, 5 CHECKs incl. BETWEEN and
  compound AND); 207 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 16: the fourth oracle — column BLR

### Converted
- **Oracle number four: column BLR.** A DEFAULT clause is stored
  verbatim in `RDB$RELATION_FIELDS.RDB$DEFAULT_VALUE`, a COMPUTED BY
  expression in `RDB$FIELDS.RDB$COMPUTED_BLR` — both with the
  SMALLEST wrapper of the four oracles: `blr_version5, the value,
  blr_eoc`.
- **Defaults are as narrow as the engine's own grammar**: literals
  (signs folding), NULL, and the niladic context functions —
  CURRENT_DATE 0xA0, CURRENT_TIME 0xA2, CURRENT_TIMESTAMP 0xA1, one
  verb each (`DEFAULT 3 + 4` is an ENGINE syntax error, so fcdsql
  refuses it too).
- **COMPUTED BY takes the whole converted expression surface** with
  the table's columns as bare fields at CONTEXT 0 — arithmetic,
  functions, concatenation, COALESCE, CAST, SUBSTRING, a
  cast-wrapped CASE — the stream is anonymous, so qualified names
  refuse.
- The context functions are Val variants now, usable everywhere the
  expression surface reaches.

### Guarded
- Non-grammar defaults, qualified names in computed expressions, and
  a CASE with FIELD branches in a computed — the engine compiles it,
  but its cast descriptor needs the CATALOG's column types, so the
  catalog-free line holds. New gate: `qa/dsql-field-blr.sh` — 22
  checks; 200 unit byte-pins across four oracles.

## 2026-07-28 — fire-crab-dsql slice 15: calls, exceptions, exit

### Converted
- **EXECUTE PROCEDURE**: `blr_exec_proc` — a counted name, u16 input
  count + values, u16 output count + blr_variable targets
  (`RETURNING_VALUES :v, ...`). Arg-less calls carry two zero words.
- **EXCEPTION <name>**: `blr_abort, 2, counted name`. **EXIT**:
  `blr_leave 0` — it leaves the WRAPPER's label, the same leave verb
  WHILE uses.
- **(FOR) SELECT inside TRIGGER bodies**: the stream takes the next
  context after OLD/NEW, labels share the numbering, and the DO body
  is any statement (no row-send — that is SUSPEND's, and SUSPEND is
  procedure-only).
- **The aggregate-context law GENERALISED**: the aggregate node takes
  stream ctx + 1 wherever the stream lands — probed at 1-over-0
  (slice 8), 3-over-2 (a trigger's singular aggregate select) and
  2-over-1 (an aggregate after a DML). The slice-14 refusal of
  aggregates at nonzero contexts fell to a probe — flip nine — and
  HAVING/ORDER-BY fids now carry the right context everywhere.

### Guarded
- (nothing new — the slice REMOVED a refusal). Gates:
  `qa/dsql-proc-blr.sh` grew to 67 checks, `qa/dsql-trig-blr.sh` to
  38 (12 fresh battery statements incl. RETURNING_VALUES into a
  local and EXCEPTION raised from a trigger); 189 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 14: general procedure bodies

### Converted
- **The statement surfaces UNIFIED**: procedure bodies now run the
  same statement machine as triggers — bodies mix FOR SELECT loops,
  singular SELECT INTOs (into locals too), DML, IF/WHILE and
  SUSPENDs freely, with FOR labels numbering alongside the WHILEs.
  Every prior single-statement shape re-emits byte-identically
  through the general machine (the 174 existing pins are the
  regression net that proved it).
- **Outputs ARE variables**: `R1 = 5;` assigns variable 0; locals
  continue the numbering (interleaved declare/init in procedures
  where triggers group). SUSPEND anywhere is the row send.
- **RETURNS is OPTIONAL**: a no-output procedure carries a ONE-SLOT
  message 1 — just the EOF short — and a flag-only final send
  (probed).
- **Name resolution split**: outside stream scopes a bare name
  resolves local variables FIRST, then input parameters (probed:
  `IF (I1 > 0)` compiles the message reference bare); inside
  selects, subqueries and DML WHEREs a bare name stays a COLUMN —
  variables need their colon — and `:name` reaches locals and
  outputs as blr_variable.

### Guarded
- SUSPEND without outputs, aggregate selects after stream-claiming
  statements (the aggregate-context law is probed only at 0). Gate:
  `qa/dsql-proc-blr.sh` grew to 59 checks (10 fresh multi-statement
  battery statements incl. two-SUSPEND bodies and IF THEN INSERT
  ELSE DELETE); 182 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 13: PSQL control

### Converted
- **DECLARE [VARIABLE]**: declares sit between the outer begin and
  label 0, each null-initialised UNLESS an initialiser replaces the
  null. With several variables, **triggers group ALL declares first,
  THEN the inits — where procedures interleave per variable** (both
  probed: read the bytes, not the symmetry). Bare names resolve to
  local variables FIRST; `v = expr;` assigns to blr_variable.
- **WHILE (c) DO stmt**: blr_label N, blr_loop, begin, blr_if(c,
  body, blr_leave N), end — labels number in ENCOUNTER order after
  the wrapper's 0; nested loops probed (outer 1, inner 2, leaves
  matching).
- **INSERTING / UPDATING / DELETING**: eql(blr_internal_info(literal
  6), literal 1/2/3) — so NOT INSERTING folds to neq through the
  ordinary inverse law, and the predicates compose under AND/OR
  (battery: UPDATING OR DELETING, UPDATING AND v > 100). Multi-event
  headers (BEFORE INSERT OR UPDATE OR DELETE) leave no trace like
  the rest of the header.

### Guarded
- Assignments to undeclared names, bare LEAVE (loop control beyond
  WHILE's own is unconverted). Gate: `qa/dsql-trig-blr.sh` grew to
  34 checks (8 fresh PSQL battery statements); 174 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 12: the DML verbs

### Converted
- **INSERT is `blr_store`(relation, assignments)** — no for-wrapper;
  the target claims the next context and assignments follow the
  column list's order. The list is REQUIRED (without it the mapping
  needs the catalog). VALUES read OLD/NEW freely.
- **DELETE is `blr_for` over a `blr_marks(1, 4)`-stamped rse, then
  `blr_erase(ctx)`** — blr_marks is the DSQL's loop stamp, probed on
  every UPDATE/DELETE and absent on store.
- **UPDATE is the same loop with `blr_modify(org, new,
  assignments)`** — and the NEW-record context is allocated BEFORE
  the rse stream's (probed: modify 3,2 with the rse at 3). SET
  targets write the new context; SET sources and the WHERE read the
  ORG stream (`SET UA = UA + 1` reads ctx 3, writes ctx 2 — pinned).
- Inside a DML's WHERE a bare name binds to the DML's own stream —
  the innermost-scope rule again (battery: `WHERE DEPT_ID =
  OLD.DEPT_ID AND SALARY = 0`, engine-agreed). Contexts keep
  counting across multiple DML statements (a two-DML trigger is in
  the battery); DML composes under IF.

### Guarded
- INSERT without a column list, column/value miscounts (an engine
  error), INSERT ... SELECT (unprobed). Gate: `qa/dsql-trig-blr.sh`
  grew to 24 checks (8 fresh DML battery statements); 166 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 11: the third oracle — triggers

### Converted
- **Oracle number three: `RDB$TRIGGER_BLR`.** A trigger body is
  compiled by the same DSQL and stored verbatim — with the leanest
  wrapper of the three oracles: blr_begin, blr_label 0, a DOUBLE
  blr_begin holding the statements, three ends, eoc. The HEADER
  (table, BEFORE/AFTER, event, POSITION) leaves NO trace — catalog
  data, like a view's select list.
- **OLD is CONTEXT 0, NEW is CONTEXT 1** — modelled as two
  pseudo-streams, so qualified fields resolve through the ordinary
  path and bare names refuse (ambiguous between the two records).
- **Statements**: `NEW.col = <value>;` is blr_assignment(value,
  field); `IF (cond) THEN stmt [ELSE stmt]` is blr_if — with a bare
  blr_end byte in a MISSING else slot (probed); a nested BEGIN..END
  block is a DOUBLE blr_begin (probed); statements concatenate. The
  whole converted expression surface rides on trigger fields — the
  battery runs UPPER, SUBSTRING, CHAR_LENGTH, a cast-wrapped CASE
  and IN lists against OLD/NEW columns.

### Guarded
- OLD targets (read-only in the engine), bare column names, empty
  bodies, database-level triggers (ON CONNECT — a different
  wrapper). New gate: `qa/dsql-trig-blr.sh` — 14 checks, all
  byte-identical on the first run; 158 unit byte-pins across three
  oracles.

## 2026-07-28 — fire-crab-dsql slice 10: SELECT INTO, FIRST/SKIP, DISTINCT aggregates

### Converted
- **The SINGULAR `SELECT ... INTO`** (no FOR): `blr_for` over
  `blr_singular(rse)` with NO label 1; the for's body holds only the
  assignments, and a trailing `SUSPEND;` compiles as a SIBLING send
  after the for — without it only the final EOF send remains (both
  probed). The whole rse surface (WHERE, aggregates, inputs) rides
  inside.
- **FIRST <n> / SKIP <n>**: rse sub-clauses carrying one value each;
  probed order stream, FIRST, SKIP, boolean, sort.
- **The DISTINCT aggregate verbs**: COUNT/SUM/AVG get dedicated
  verbs (agg_count_distinct 0x5E, agg_total_distinct 0x5F,
  agg_average_distinct 0x60) while **MIN(DISTINCT) and MAX(DISTINCT)
  FOLD to the plain verbs** — probed byte-identical. Two prior
  refusals became features (COUNT(DISTINCT), the bare SELECT INTO
  body) — flips seven and eight.

### Guarded
- `FIRST :param` without parens (an ENGINE syntax error),
  parenthesised FIRST expressions, FIRST/SKIP over aggregate streams
  or in the singular form (unprobed placements). Gate:
  `qa/dsql-proc-blr.sh` grew to 48 checks (11 fresh battery
  statements incl. singular+input+aggregate and a grouped
  COUNT(DISTINCT) with an input); 149 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 9: input parameters

### Converted
- **Input parameters are MESSAGE 0**: one dsc + null-flag blr_short
  per parameter and NO EOF slot (outputs' message 1 has one); the
  whole loop block sits under `blr_receive 0` — its begin's own
  blr_end doubles as the receive's end, and the final EOF send stays
  outside it (probed).
- **`:name` is a direct message reference**: blr_parameter2(0, 2i,
  2i+1) used STRAIGHT as a value — no variable is declared for
  inputs, unlike outputs. Inputs ride anywhere a value does in the
  FOR select: comparisons, arithmetic (`A + :I1`), IN lists,
  BETWEEN two inputs inside an aggregate's source WHERE — all in
  the battery, beside ORDER BY and GROUP BY.
- The slice-7 refusal of input parameters became this feature; its
  gate slot flipped to a positive check (an UNUSED input still
  shapes message 0 and the receive wrapper — checked
  differentially). The sixth refusal-to-feature flip.

### Guarded
- `:name` that misses the input list, inputs inside HAVING (they
  would cross the aggregate boundary — unprobed), and `:name`
  outside a procedure body refuse. Gate: `qa/dsql-proc-blr.sh` grew
  to 37 checks (7 fresh input battery statements); 138 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 8: aggregates and GROUP BY

### Converted
- **The aggregate is a STREAM**: `blr_aggregate` with its OWN context
  (1) wrapping the source rse (ctx 0) — and the WHERE stays the
  SOURCE rse's boolean, inside the aggregate. Then `blr_group_by`
  (count byte + keys — present even with ZERO keys) and `blr_map`.
- **The verbs**: agg_count (COUNT(*)), agg_count2 (COUNT(v) — counts
  non-null values, a DIFFERENT verb), agg_max/min/total/average.
  Arguments take full value expressions (`SUM(SALARY * 12)` in the
  battery).
- **Two order laws**: the group_by list follows the GROUP BY CLAUSE
  order while the map follows the SELECT-LIST order — probed to
  differ on one statement (`SELECT A, S ... GROUP BY S, A`).
- **Everything downstream speaks blr_fid(1, slot)**: the DO body's
  assignments, ORDER BY's sort keys, and HAVING — the OUTER rse's
  boolean — where a group-key column becomes its slot's fid and an
  aggregate call DEDUPS against the map: a structurally equal
  aggregate REUSES its select-list slot (probed: HAVING COUNT(*)
  beside SELECT COUNT(*) stores fid 1,1 — no third slot) while a
  fresh one APPENDS (HAVING COUNT(*) beside SELECT MAX adds slot 2).

### Guarded
- A plain column beside an aggregate without GROUP BY, GROUP BY
  without aggregates, select columns missing from GROUP BY,
  `COUNT(DISTINCT ...)` (the distinct agg verbs), non-grouped columns
  in HAVING, and LIKE/IN/subqueries over aggregate output refuse.
  Gate: `qa/dsql-proc-blr.sh` grew to 29 checks (10 fresh aggregate
  battery statements incl. a compound HAVING with AND); 134 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 7: the second oracle — procedures and ORDER BY

### Converted
- **Oracle number two: `RDB$PROCEDURE_BLR`.** A procedure's
  `FOR SELECT ... DO SUSPEND` body holds what a view cannot — ORDER
  BY — and the engine stores its compiled BLR verbatim too.
  `compile_procedure` emits the WHOLE body byte-identically:
  blr_message 1 with 2n+1 dscs (each parameter's dsc FOLLOWED BY a
  null-flag blr_short, then one final blr_short — the EOF flag; the
  dsc encodings are the CAST ones, byte for byte), a blr_declare +
  NULL-init per parameter, blr_stall, two blr_labels, blr_for over
  the rse, field→variable assignments (INTO names pick the
  variables — an out-of-order INTO is in the battery), and twin
  blr_sends: each variable through blr_parameter2 (value slot 2i,
  null slot 2i+1), the EOF flag (parameter 2n) literal short 1
  inside the loop and 0 after it.
- **ORDER BY**: `blr_sort` after the rse's boolean — a count byte,
  then per key blr_ascending or blr_descending and the value. Mixed
  directions probed (DESC, ASC on one statement).
- **The context-base law**: procedure bodies number streams from
  CONTEXT 0 where view BLR numbers from 1 (probed: the FOR stream is
  `blr_relation 'T' 0`). One parser serves both — `P.base` is 1 for
  views, 0 for procedures. The body's WHERE reuses the whole
  converted expression surface (functions, CASE, IN — all at ctx 0).

### Guarded
- Input parameters (they add a second message), subqueries inside
  procedure bodies (contexts unprobed), aliased FOR streams,
  `ORDER BY <position>`, sort expressions, INTO names that miss the
  RETURNS list or miscount the columns, and multi-statement bodies
  all refuse. New gate: `qa/dsql-proc-blr.sh` — 17 checks, every
  battery statement fresh; 121 unit byte-pins across both oracles.

## 2026-07-28 — fire-crab-dsql slice 6: DISTINCT, scalar subselects, derived tables, UNION

### Converted
- **DISTINCT**: `blr_project` after the boolean — a count byte and
  the SELECT LIST's columns. The one place the select list leaves a
  trace in view BLR (everywhere else it compiles away).
- **Scalar subselects as values**: `blr_via(blr_singular(rse),
  value, blr_null)` — usable anywhere a value is: both comparison
  sides, inside arithmetic (`SALARY + (SELECT ...)`), beside other
  subquery predicates.
- **Derived tables**: an rse IN THE STREAM SLOT whose relation2
  alias text is `"ALIAS" "PUBLIC"."TABLE"` — the schema-qualified
  underlying table rides along in the alias (probed; a PLAIN alias
  stays short `"X"`). The whole derived table has ONE context,
  shared by inner and outer references. Rides anywhere a stream can
  (probed as a join's left side). Pass-through column lists only;
  the alias is required.
- **UNION [ALL]**: the statement rse's single stream is `blr_union`
  — its own context byte (1, claimed BEFORE any branch stream, which
  is why the compiler pre-scans for a top-level UNION), a branch
  count, then per branch an rse (branch WHERE inside) and a
  `blr_map` (u16 count, then u16-field-number/value pairs). The
  DISTINCT form appends `blr_project` over `blr_fid(1, 0..n)`;
  UNION ALL does not. Three-branch chains probed (contexts 2, 3, 4).

### Guarded
- Mixed `UNION`/`UNION ALL` chains (they bind by precedence rules
  not yet probed), column-count mismatches (an engine error),
  DISTINCT inside union branches, `DISTINCT *`, DISTINCT over
  expressions, alias-less derived tables and derived union branches
  all refuse. The slice-5 refusal of scalar subselects became a
  feature — its gate slot flipped to a positive check. Gate:
  `qa/dsql-view-blr.sh` grew to 127 checks (17 fresh slice-6 battery
  statements; 3 new refusal slots); 115 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 5: subquery predicates

### Converted
- **EXISTS / SINGULAR**: `blr_any` / `blr_unique` over ONE rse — the
  subquery's WHERE is that rse's boolean and its select list leaves
  no trace, exactly like a view's (`SELECT 1` ≡ `SELECT *`, probed).
  NOT keeps a REAL `blr_not` over both: no inverse verbs.
- **IN (SELECT ...) and the quantified comparisons**: `blr_ansi_any`
  / `blr_ansi_all` with a DOUBLE-NESTED rse — the outer rse's single
  STREAM IS the subquery's rse (which carries the subquery's own
  WHERE), and the quantified comparison is the OUTER rse's boolean.
  `= ANY` compiles byte-identical to IN; SOME to ANY; ALL keeps the
  WRITTEN comparison.
- **The negation law**: the quantifier FLIPS and the comparison
  INVERTS — `NOT IN` is ansi_all + neq, `NOT (A = ANY ...)` the
  same, `NOT (A > ALL ...)` is ansi_any + leq (all probed).
- **Scoping**: subquery streams JOIN the statement's context
  numbering (T=1, U2=2, a subquery's V3T takes 3 — probed) but stay
  INVISIBLE to outer bare names; inside a subquery a bare name binds
  to the subquery's OWN stream (innermost-scope-first; an outer
  reference must be qualified). Aliased subquery streams are
  blr_relation2. Subqueries compose: under AND/OR, inside CASE
  conditions, with expression left-hand sides.

### Guarded
- Scalar subselects as VALUES (`A = (SELECT ...)`), subqueries inside
  ON clauses (they would interleave the join chain's stream
  numbering), multi-stream subqueries and multi-column select lists
  refuse as unconverted. Gate: `qa/dsql-view-blr.sh` grew to 108
  checks (16 fresh slice-5 battery statements; 4 new refusal slots);
  101 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 4: CAST and the conditionals

### Converted
- **CAST**: `blr_cast` + a dsc, each target's layout probed:
  SMALLINT/INTEGER/BIGINT are dtype + scale; NUMERIC(p≤4) is SHORT
  but DECIMAL(p≤9) is ALWAYS LONG (SQL's "at least p"); p 10..=18 is
  INT64 and beyond refuses; VARCHAR/CHAR carry a charset word and a
  length word; DATE/TIME/TIMESTAMP are a bare dtype.
- **Searched CASE and IIF** (byte-identical sugar): ONE `blr_cast`
  over a `blr_value_if` chain — each further WHEN nests in the ELSE
  slot, a missing ELSE is `blr_null`. The cast's descriptor is the
  branches' UNIFIED type, law probed case by case: NULL branches are
  ignored; text branches take blr_text2 at the MAX length
  ('yes'/'no' → CHAR(3)); exact numerics take MAX integer digits +
  MIN scale and the dtype that FITS the total (≤4 short, ≤9 long,
  else int64) — so long(0) ∪ long(-1) WIDENS to int64 (9+1=10
  digits): `CASE ... THEN 1.5 ELSE 0 END` casts to int64 scale -1.
- **Simple CASE**: `blr_decode` — count byte, comparands, count byte,
  results; the ELSE is one extra result and its absence is unmarked.
  NO cast wrapper (probed). **COALESCE**: `blr_coalesce`, count byte
  + values, also wrapper-free — so field arguments are fine there.
- **NULLIF(a, b)**: `cast(value_if(a = b, NULL, a))` — the dsc comes
  from the BRANCHES (NULL and a); b NEVER shapes it (probed:
  NULLIF(1, 2.55) casts to long scale 0).

### Guarded
- A FIELD branch under a cast wrapper refuses — its descriptor lives
  in the catalog and this compiler never guesses one (COALESCE and
  decode take fields freely: no descriptor to compute). Single-arg
  COALESCE (an engine syntax error), FLOAT/NUMERIC(>18) casts,
  all-NULL branch lists and text/numeric mixtures refuse as unprobed.
  Gate: `qa/dsql-view-blr.sh` grew to 90 checks (24 fresh slice-4
  battery statements; 4 new refusal slots); 85 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 3: outer joins, chains, functions

### Converted
- **Outer joins**: `blr_join_type` follows the join's streams and
  precedes its ON boolean, carrying 1=LEFT, 2=RIGHT, 3=FULL — and is
  ABSENT for INNER (probed). `LEFT OUTER JOIN` compiles byte-identical
  to `LEFT JOIN`.
- **Join chains**: each ON binds to its LEFT, so the chain nests left —
  the second join's `blr_join` node holds the first join's node as its
  first stream slot (probed on a three-table chain), and a type byte
  sits only on its own node in a mixed inner/outer chain.
- **INT64 literals**: a literal past blr_long's 32 bits emits
  `blr_int64` (dtype 0x10, one scale byte, 8 little-endian bytes); the
  sign still folds into the literal.
- **The first built-in functions in compiled BLR**: `blr_upcase` /
  `blr_lowcase` (one operand); `blr_strlen` with its length-type byte
  (CHAR_LENGTH=1, OCTET_LENGTH=2 — probed, not assumed); `blr_substring`
  whose start is 0-BASED and compiled as `blr_subtract(<from>, 1)`
  UNFOLDED (probed: `FROM 1` stores subtract(1,1), not literal 0);
  `blr_trim` with a where byte (0=BOTH, 1=LEADING, 2=TRAILING) and a
  spec byte (0=spaces, 1=explicit <what>); a bare `TRIM('a' FROM s)`
  is BOTH. Functions compose (UPPER(TRIM(x)), functions inside ON).

### Fixed
- A hand-written expected pin for `A = -5000000000` was WRONG — the
  compiler was right and the pin invented. The engine probe settled
  it (the pinned bytes now come from RDB$VIEW_BLR, per the project
  rule: never pin what was not probed).

### Guarded
- An unknown name followed by `(` — a UDF or an unconverted built-in —
  refuses instead of falling back to a field read; `SUBSTRING` without
  `FOR` and `CROSS JOIN` refuse as unprobed layouts. Gate:
  `qa/dsql-view-blr.sh` grew to 62 checks (19 fresh slice-3 battery
  statements incl. UPPER-inside-ON and a NULL-hunting outer join);
  52 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 2: expressions, IN, streams

### Converted
- **Value expressions** in the compiled BLR: blr_add / subtract /
  multiply / divide / negate / concatenate with the engine's
  precedence; a sign before a NUMERIC LITERAL folds into it (probed:
  `A = -1` stores the negative literal, no negate verb) while
  blr_negate survives before fields; parens reshape the tree.
- **IN lists**: FB5's dedicated `blr_in_list` (value, little-endian
  u16 count, values); `NOT IN` keeps a real blr_not — and the De
  Morgan folder treats InList like LIKE/MISSING.
- **Multi-stream RSEs**: comma-FROM lists emit streams side by side
  with 1-based contexts; `[INNER] JOIN ... ON` emits `blr_join`
  nesting like an rse with the ON clause as its own boolean
  sub-clause; aliases emit `blr_relation2` with the alias UPPERCASED
  IN DOUBLE QUOTES (probed: `FROM T x` stores `"X"`). Qualified
  fields resolve to their stream's context; a BARE field in a
  multi-stream statement refuses — the engine resolves those through
  the catalog, and this catalog-free compiler never guesses a
  context. Gate: `qa/dsql-view-blr.sh` grew to 41 checks (15 fresh
  slice-2 battery statements; LEFT JOIN and bare multi-stream fields
  hold refusal slots); 31 unit byte-pins.

## 2026-07-28 — fire-crab-dsql: SQL → BLR, first slice

### Converted
- **The `fire-crab-dsql` crate** — the beginning of `src/dsql/`'s
  conversion, with the purest oracle in the project: `CREATE VIEW`
  makes the ENGINE's DSQL compile the SELECT and store the BLR
  verbatim in `RDB$VIEW_BLR`, so fire-crab-dsql's output is compared
  BYTE FOR BYTE against the original compiler's for the identical
  statement. First slice: the view-shaped single-relation SELECT with
  WHERE booleans. Probed compilation laws, each pinned: the select
  list leaves NO trace (mapping is positional catalog data); NOT
  compiles away — inverse verbs for comparisons, De Morgan through
  AND/OR — surviving only over LIKE and MISSING; `NOT BETWEEN`
  expands to `lss OR gtr` while BETWEEN stays `blr_between`; IS NULL
  is `blr_missing`; decimal literals keep their written scale; text
  literals are `blr_text2` with charset and length words; AND/OR
  chains nest left. Gate: `qa/dsql-view-blr.sh`, 26 checks — a
  battery deliberately beyond the unit-test pins, plus refusals
  (ORDER BY, arithmetic values, IN, aggregates, joins) that must
  refuse rather than guess.

## 2026-07-28 — predicate-surface completion

### Converted
- **CASE inside WHERE**: the tokenizer lexes the `CASE .. END` span by
  balancing the KEYWORDS (nested CASEs nest, an 'end' inside a string
  literal is skipped) and hands it whole to the expression parser —
  searched, simple, and nested forms as filters.
- **`?` against expression sides**: `WHERE UPPER(S) = ?` claims its
  slot with a bind descriptor SYNTHESIZED from the expression's type;
  at execute the value substitutes as a literal and the term evaluates
  three-valued (`Term::ExprParam` → `ExprCond` at bind).
- **Expressions in JOIN predicates**: arithmetic, functions, CASE and
  column-vs-column over the combined row, through a synthetic
  single-relation view (bare unambiguous names; ambiguous names
  refuse rather than guess a side). Gate:
  `qa/serve-real-predfull.sh`, 20 checks (node-firebird drives the
  parameter phase); wherexpr/nofallback stale refusals flipped
  (36 / 54).

## 2026-07-28 — status-vector fidelity

### Fixed
- **The 22018 conversion error carries its offending string** as an
  `isc_arg_string` in the status vector (`EvalErr::ConversionError`
  gained a payload; the vector writer ships an XDR counted string) —
  isql now prints `conversion error from string "pear"` identically on
  both sides, closing the missing-argument placeholder difference.
- **DML errors gained a vector channel**: `execute_dml` returns
  `ExecErr { Text, Eval }`, and a per-row eval error in a DML's WHERE
  (`UPDATE ... WHERE A / 0 = 1`) answers the engine's own 22012 vector
  instead of a generic SQL error. The wherexpr/aggexpr gates' SQLSTATE
  workarounds flipped back to exact differential checks.

## 2026-07-28 — fallible predicates, expressions everywhere in WHERE

### Converted
- **Full expression comparison sides in WHERE**: `A + 1 > B`, column
  vs column, parenthesised sides, `(A + B) * 2 = 6`, arithmetic
  BETWEEN/IN bounds, CAST/COALESCE/NULLIF/IIF as predicate sides —
  a token-level precedence parser folds operator tokens back into
  expression trees; bare columns and literals keep the classic fast
  paths (parameters, exact numeric terms). Gate:
  `qa/serve-real-wherexpr.sh`, 35 checks.

### Fixed
- **`Predicate::matches` became FALLIBLE** — the architectural change
  under the feature. A per-row eval error (`WHERE A / 0 = 1`, a
  negative length from a column, a failed CAST) now PROPAGATES through
  every predicate consumer and reaches the client with the engine's
  own vector, mid-statement. The "no-raise fence" is gone: previously
  fenced shapes (runtime MOD divisors, column lengths, CAST, DATEADD
  in WHERE) are admitted; the wherefn gate's refusal entries moved to
  differential checks (51).

### Guarded
- Type fences remain (text under MOD/SIGN/ABS), as does the
  `?`-against-expression-side refusal and CASE-in-WHERE. Documented
  differences: some errors surface at EXECUTE in the engine vs first
  FETCH here (one leading blank in isql); a DML WHERE error answers a
  generic SQL error (text channel, not a vector).

## 2026-07-28 — temporal arithmetic

### Converted
- **`DATEADD` / `DATEDIFF`** (both syntaxes each) and the **native
  temporal operators** (`D + 7`, `7 + D`, `TS + 1`, `DATE − DATE`,
  `TS − TS`, `TIME − TIME`). Probed laws: month-end clamping, TIME
  wrapping midnight, DATE absorbing clock units by truncation,
  DATEDIFF's calendar-component YEAR/MONTH vs boundary-crossing clock
  units (signed), MILLISECOND at NUMERIC(18,1), TIME−TIME seconds at
  −4, TIMESTAMP differences as nanodays truncating to 9 exact digits,
  and numeric addends CVT-rounding (D + 0.5 moves a day). DATEDIFF is
  admitted to WHERE (it cannot raise); DATEADD refuses there (range
  errors are mid-cursor). Composes with EXTRACT, CASE, aggregates and
  GROUP BY expressions. Gate: `qa/serve-real-datemath.sh`, 40 checks.

## 2026-07-28 — GROUP BY expressions

### Converted
- **Expression grouping keys**: `GROUP BY UPPER(S)` /
  `EXTRACT(YEAR FROM D)` / `MOD(A, 2)` / `CASE ... END`, and
  `GROUP BY <ordinal>` naming an expression select item — each key
  computed per row into a synthetic value slot, bucketed like a field
  (NULL keys share a bucket). Select-list expressions match group keys
  STRUCTURALLY (parsed trees compare; column names case-insensitive,
  literals exact), so `GROUP BY upper( s )` matches `SELECT UPPER(S)`.
- **HAVING breadth**: expression aggregates (`HAVING SUM(A + ID) > 5`,
  `COUNT(NULLIF(A, 1))`, `SUM(IIF(...))`) fold as hidden items;
  NUMERIC aggregates compare through exact scale alignment
  (`HAVING AVG(N) > 0`, `SUM(N) > 0.10`); text MIN/MAX compare
  pad-trimmed (`HAVING MIN(S) = 'apple'`). Gate:
  `qa/serve-real-groupexpr.sh`, 30 checks; the aggexpr gate's HAVING
  refusal moved to its answered list (38 checks).

### Fixed
- The HAVING aggregate lexer scanned to the FIRST close paren, so a
  nested call (`COUNT(NULLIF(A, 1))`) broke the token; it scans to the
  MATCHING paren now.
- `GROUP BY` split its list on every comma, so `MOD(A, 2)`'s argument
  comma broke the key; top-level commas only now.

## 2026-07-28 — aggregates over expressions

### Converted
- **Expression arguments in every aggregate**: `SUM(A + ID)`,
  `AVG(N * 2)`, `MIN(UPPER(S))`, `MAX(S || '!')`,
  `COUNT(NULLIF(G, 1))`, `SUM(IIF(...))`, `SUM(CASE ... END)`,
  `MIN(EXTRACT(YEAR FROM D))` — evaluated per row before the fold,
  lone and grouped. The group fold became FALLIBLE: an eval error in
  the argument (`SUM(A / 0)`) aborts the fetch with the engine's own
  vector. SUM widens one step (probed: LONG → BIGINT, INT64-ranked →
  INT128 — `SUM(K)` and `SUM(A + ID)` both describe INT128); AVG keeps
  its width. Gate: `qa/serve-real-aggexpr.sh`, 37 checks.

### Fixed
- A lone aggregate's output column was headed `CONSTANT`; the engine
  names it by FUNCTION. `Plan::Scalar` now carries its header name
  (COUNT/MIN/MAX/SUM, GEN_ID for generator reads, CONSTANT for the
  bare-literal case) — the standing difference the previous slice
  documented.
- `GEN_ID(<missing generator>, 0)` answered NULL where the engine
  raises "generator is not defined" — caught by this slice's header
  probes; it now refuses.

### Guarded
- Expression aggregates in HAVING refuse (a later slice); the
  conversion error inside an aggregate raises with the matching
  SQLSTATE 22018 but without the engine's offending-string argument —
  a documented difference, not a silent one.

## 2026-07-28 — the aggregate surface beyond integers

### Converted
- **`AVG`** (SUM/COUNT with truncating-toward-zero division at the
  operand's scale — probed: AVG(1,2)=1, AVG(-3.00, 0.05)=-1.47),
  **MIN/MAX over text and temporal columns** (the column's own type and
  wire form on the wire), **SUM/AVG over scaled numerics** (the
  engine's NUMERIC(18,s) widening), and **`COUNT(DISTINCT col)`**
  (distinct non-NULLs, compared with the predicates' exact equality).
  All of it in lone aggregates, WHERE-filtered, GROUP BY buckets and
  HAVING (including hidden AVG items). Gate: `qa/serve-real-aggfn.sh`,
  36 checks.

### Fixed
- A value wider than its announced wire form now RAISES at emit on the
  plain-output path too (a group's SUM spilling past BIGINT would have
  encoded zero bytes).

### Guarded
- `SUM/AVG/MIN/MAX(DISTINCT ...)`, `AVG` over text, `SUM` over dates
  refuse at prepare. The lone COUNT/MIN/MAX/SUM fast path still headers
  its column `CONSTANT` where the engine names the function — made
  visible by this slice's header checks, kept for now (the COUNT(*)
  fast path is what system relations depend on), AVG routes through
  the group machinery and headers correctly.

## 2026-07-28 — the temporal expression surface

### Converted
- **`EXTRACT`**, temporal literals (`DATE '...'`, `TIME '...'`,
  `TIMESTAMP '...'`), the clock keywords (`CURRENT_DATE`, `LOCALTIME`,
  `LOCALTIMESTAMP`), and DATE/TIME/TIMESTAMP columns as expression
  operands — through conditionals, concatenation, arithmetic on
  extracted parts, and WHERE predicates. Probed conventions: WEEKDAY
  0 = Sunday, YEARDAY 0-based, ISO 8601 week, SECOND at NUMERIC(9,4),
  MILLISECOND at NUMERIC(9,1); wrong parts fail at prepare; DATE vs
  TIMESTAMP converts as midnight. Gate: `qa/serve-real-extract.sh`,
  42 checks.
- **`docs/porting-playbook.md`** — tips for the next agent porting to
  another language: the method (probe first, engine as oracle, refuse
  loudly, diversify fixtures, prove gates fail pre-fix), the core
  algorithms in language-agnostic pseudocode (expression pipeline and
  its emit invariant, dialect-3 scale arithmetic, three-valued logic,
  DNF predicates with the no-raise fence, civil-date math, LIKE), the
  traps that cost real time, and the porting order that worked.

### Guarded
- Mixed temporal kinds (or a temporal beside a number) in a
  conditional refuse at prepare — the wire form could not carry both.
  `CURRENT_TIME`/`CURRENT_TIMESTAMP` (TIME ZONE types) refuse; the
  clock capture happens at plan time, a documented divergence for
  prepare-once-execute-many clients.

## 2026-07-28 — CASE, and the conditional typing law

### Converted
- **CASE expressions**, searched and simple, with full boolean
  conditions (`OR`/`AND`/`NOT`/parenthesised groups, three-valued
  Kleene) — and `IIF` upgraded to the same condition grammar (the
  engine parses IIF into a searched CASE; both header as `CASE`). The
  simple form desugars to `=` conditions, so `WHEN NULL` never matches
  — the engine's rule, for free. Gate: `qa/serve-real-case.sh`,
  44 checks.
- **`docs/expression-surface.md`** — the converted expression subsystem
  documented against its engine sources (`parse.y` precedence,
  `ExprNodes.cpp` scale/promotion laws, `SysFunction.cpp`, CVT
  coercions, the IIF→CASE lowering), with every probed law and the
  refusal policy in one place.

### Fixed
- **The conditional typing law**: a conditional typed from its FIRST
  branch alone, so `COALESCE(A, 0.5)` — integer first, scaled second —
  announced scale 0 and the scaled branch's raw value could not decode
  (0.5 read as 0.05, or an overflow refusal). Probed: the engine
  announces scale −1 and prints `-7.0`. Two rules close it: any
  exact-numeric branch beside integer ones types the conditional
  Numeric at the branches' minimum scale, and every branch value is
  ALIGNED to the announced scale at emit (`value_of`). A latent bug in
  ALL the older conditionals, exposed by the new gate's mixed-scale
  branches.

## 2026-07-28 — the scalar-function surface

### Converted
- **Built-in scalar functions** in the select list, computed columns and
  everywhere expressions go: `UPPER`, `LOWER`, `CHAR_LENGTH` /
  `CHARACTER_LENGTH`, `OCTET_LENGTH`, `SUBSTRING (FROM/FOR)`, `TRIM`
  (sides, multi-character `<what>`), `LEFT`, `RIGHT`, `REPLACE`,
  `POSITION` (both syntaxes, optional start), `REVERSE`, `ABS`, `MOD`,
  `SIGN`, `LPAD`, `RPAD` — the parser's string intrinsics
  (`blr_upcase`, `blr_substring`, `blr_trim`, `blr_strlen`) plus the
  `SysFunction.cpp` table. Every semantic probed against the engine
  before implementation; a literal negative `SUBSTRING` length fails at
  PREPARE with the engine's own `isc_bad_substring_length` vector
  (`Plan::RefusedEval`). Gate: `qa/serve-real-functions.sh`, 80 checks.
- **Function calls in WHERE** — a call on either side of a comparison,
  under `IS [NOT] NULL`, as a `LIKE` subject, inside `BETWEEN`/`IN`,
  under `AND`/`OR`/`NOT`, in SELECT and DML alike; evaluated per row
  through the select-list expression machinery with the predicate
  surface's three-valued logic and pad-insensitive text compare. Gate:
  `qa/serve-real-wherefn.sh`, 51 checks.

### Fixed
- The query splitter took the FIRST `FROM` in the statement —
  `SUBSTRING(S FROM 2)` and `TRIM(x FROM y)` carry their own `FROM`
  inside the select list's parentheses and broke the split. The clause
  `FROM` is now the first at paren depth zero on a literal-masked copy,
  which also stops a `' FROM '` inside a string literal splitting the
  query (a latent bug the new tests pin).
- An un-aliased `IIF` output column was headed `IIF`; the engine parses
  IIF into a searched CASE and heads it `CASE`. Invisible until now
  because the conditionals gate compares with headings off.

### Guarded
- A WHERE term answers only true/false and cannot carry the engine's
  mid-cursor error, so any predicate expression whose per-row
  evaluation could RAISE (`MOD` by a non-literal or zero divisor, a
  length from a column, a text operand under a numeric function, `CAST`)
  refuses at prepare — never admitted to silently exclude a row the
  engine would have raised on.
- A malformed call (`UPPER()`, `TRIM(LEADING S)`) refuses at prepare via
  the `names_expr_call` guard — the conditionals' malformed-call rule
  extended to every function name — rather than being misread as a
  column name.

## 2026-07-27 — the query surface rounds out

### Converted
- Subqueries in WHERE: `IN` / `NOT IN` / `EXISTS` / `NOT EXISTS` /
  scalar, evaluated up front and folded into the outer predicate
  (a correlated `EXISTS` runs as a semi-join).
- PSQL execution: `EXECUTE PROCEDURE` interpreted from the stored
  source; DML inside bodies; selectable procedures (`SUSPEND`, a
  procedure as a row source); `FOR SELECT` cursor loops.
- `UPDATE ... SET col = <expression>`, evaluated per row against the
  pre-statement row (SQL's simultaneous assignment: `SET A = B, B = A`
  swaps).
- Views: `RDB$VIEW_SOURCE` expanded and re-planned against the base
  table (positional rename map from `RDB$RELATION_FIELDS`).
- `UNION` / `UNION ALL`; `INSERT ... SELECT` through one shared
  row-source path; result modifiers `FIRST` / `SKIP` / `DISTINCT` /
  `ROWS` in the engine's grammar order.
- Conditional expressions `COALESCE` / `NULLIF` / `IIF` — the three NULL
  rules probed and pinned.
- Transaction rollback, statement-level rollback, and `SAVEPOINT`
  (whose bug was the statement-TYPE code: clients dispatch on it).

### Fixed
- Per-handle statement state — the server had served one statement per
  connection, which made a second prepare clobber the first and
  libfbclient segfault in teardown (found by the firebird-qa tree run).
- Record images are `fmt_length` exactly, no 4-byte rounding — the
  engine BUGCHECKed (sqz.cpp:179) once an UPDATE packed a slack image.

### Guarded
- The fixed-answer fallback (4242) closed at the root: an unplannable
  query RAISES; `qa/serve-real-nofallback.sh` hunts the leak across
  every surface. Writing the gate found five leaks the per-surface
  gates had missed, one a real correctness bug (a qualified outer
  column in a correlated `EXISTS`).
- Refusals fail at PREPARE, not mid-cursor — mid-cursor refusals made
  clients report "request synchronization error" and drop the
  connection (which is what libfbclient segfaults on).

## 2026-07-25/26 — DDL breadth, triggers, INT128

### Converted
- Expression→BLR compiler: computed columns (`COMPUTED BY`) through
  CREATE/ALTER/DROP; CHECK constraints (the boolean layer, a negated
  De-Morgan trigger pair); user `CREATE TRIGGER` — all six events,
  `DECLARE VARIABLE`, `WHILE`, `EXCEPTION`, nested blocks, `WHEN`
  handlers (named, `GDSCODE`/`SQLCODE`, `ANY`), embedded
  UPDATE/DELETE — byte-exact BLR the engine then executes.
- FK referential actions: `CASCADE`, `SET NULL`, `SET DEFAULT`,
  multi-column keys; NO-ACTION partner checks enforced in the DML path;
  the FK-parent DML guard.
- INT128 end to end: declarations (`NUMERIC(19..38)`), expression
  results with the engine's dtype promotion rules, index keys
  (`idx_bcd` BCD encoding, PMAX 39), WHERE predicates over scaled
  NUMERIC/DECIMAL/INT128 with exact i128 scale alignment.
- Column DEFAULTs applied on fire-crab's own INSERT, session-dependent
  defaults (`USER`, `CURRENT_CONNECTION`, ...) evaluated per attachment.
- IDENTITY columns (both kinds, RESTART, SET GENERATED, DROP IDENTITY),
  column POSITION, GLOBAL TEMPORARY TABLEs, domain-typed columns with
  overrides, `COMMENT ON DATABASE`, GRANT/REVOKE on
  procedures/functions/sequences/exceptions.
- `op_drop_database`, database aliases via `databases.conf`,
  `op_disconnect`/`op_execute2`, real-width text describes, the SRP
  proof compared by value (an auth flake fixed).

## 2026-07-24 — the security catalog and the object zoo

### Converted
- GRANT / REVOKE with the engine's recomputed ACLs — including the full
  per-column ACL compiler ported from `grant.epp` (squeeze-and-reappend
  ordering), role membership with the admin option, and
  `REVOKE GRANT OPTION FOR`.
- CREATE / DROP / ALTER for sequences, exceptions, roles, domains;
  `COMMENT ON` across the object zoo (a text blob whose charset byte
  only a byte-compare could catch); `SET STATISTICS`; ALTER INDEX
  ACTIVE/INACTIVE with index selectivity written the way the engine
  computes it.
- FOREIGN KEY in CREATE TABLE and by ALTER (the gbak-restore blocker
  solved); named PRIMARY KEY / UNIQUE constraints; DROP CONSTRAINT with
  the engine's deferred index drop.
- `RDB$FIELD_LENGTH` is the BYTE length — a divergence found by the
  domain slice and then fixed everywhere, making fire-crab's
  `RDB$RUNTIME` blob byte-identical to the engine's.

## 2026-07-23 — ALTER TABLE, and the expression surface begins

### Converted
- ALTER TABLE ADD / DROP COLUMN / ALTER TYPE — catalog amendment via new
  format versions, the field-id hole, RLE-packed in-place updates;
  SET/DROP NOT NULL (the first constraint the engine enforces on a
  fire-crab-written file without a restore).
- Select-list expression surface: `/` and `||`, `CAST`, numeric
  operands, dialect-3 scale arithmetic (probed rules), decimal
  literals; `GEN_ID(name, step)` / `NEXT VALUE FOR` — a SELECT that
  writes; auto-id INSERTs; SHOW PROCEDURE source.

## 2026-07-22 — from first SELECT to the firebird-qa milestone

### Converted
- The wire SERVER grew from answering `SELECT COUNT(*)` to: projections,
  WHERE (three-valued), ORDER BY (engine NULL order), aggregates,
  GROUP BY, HAVING, INNER and OUTER equi-joins, native wire types,
  BLOB content over the blob ops, INT128 + DECFLOAT (decNumber-exact
  rendering), TIME ZONE types, system-table projections through
  formats computed the way `ini.epp` computes them.
- The write path: INSERT into real pages, UPDATE/DELETE version chains
  the engine's own sweep collects, page allocation, B-tree index
  maintenance with splits, multi-segment and DESCENDING keys, parameter
  binding with engine-CVT coercions, the LIKE/BETWEEN/IN predicate
  surface, CREATE TABLE the engine adopts, PK/NOT NULL/CREATE
  INDEX/DROP TABLE the engine enforces and navigates.
- The outside faces: the python firebird-driver, the Services API +
  `op_create`, MON$ virtual tables — **the official firebird-qa pytest
  suite bootstraps against fire-crab and tests pass**; `SHOW` over the
  legacy BLR request API (a request-execution subsystem beside DSQL),
  generator reads and writes.

## 2026-07-21 — the storage layer, bottom-up

### Converted
- ODS page structures (header, TIP, PIP, pointer, data pages) with a
  gstat differential across 123 real databases; record RLE compression
  round-tripped; full-row decoding through `RDB$FORMATS` (blob
  assembly included) against live SELECTs; B-tree leaf walks against
  live ORDER BY; the transaction system (TIP chain, delta
  back-versions, MVCC visibility) against a file frozen
  mid-uncommitted-work; GC/sweep prediction against `gfix -sweep`;
  BLR decoding against the engine's own printer; the wire protocol as
  a CLIENT — XDR, SRP-256 from scratch, Arc4 — logging in to the real
  engine and running SELECTs that match isql row-for-row.
