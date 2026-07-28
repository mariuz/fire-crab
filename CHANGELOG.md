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
