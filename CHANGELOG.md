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
