# The expression surface: engine sources, converted semantics, refusal policy

The SQL expression evaluator inside `fire-crab-wire::server` is a
conversion of several engine subsystems that meet in one place — the
DSQL parser's expression grammar, the expression node tree, the system
function table, and the conversion (CVT) rules. This document maps each
converted behavior to the C++ source it came from, records the laws
that were PROBED against the live engine before being written down, and
states the refusal policy that keeps the unconverted remainder honest.

Companion gates: `qa/serve-real-selectexpr.sh` (arithmetic, `||`, CAST,
numeric scale rules), `qa/serve-real-conditional.sh` (COALESCE/NULLIF/
IIF), `qa/serve-real-functions.sh` (the built-in scalar functions),
`qa/serve-real-wherefn.sh` (function calls in WHERE),
`qa/serve-real-case.sh` (CASE, and cross-branch typing),
`qa/serve-real-extract.sh` (the temporal surface),
`qa/serve-real-aggfn.sh` (the aggregate surface),
`qa/serve-real-aggexpr.sh` (aggregates over expressions),
`qa/serve-real-groupexpr.sh` (GROUP BY expressions, HAVING breadth),
`qa/serve-real-datemath.sh` (temporal arithmetic),
`qa/serve-real-wherexpr.sh` (expression predicate sides, the fallible
fold), `qa/serve-real-predfull.sh` (CASE in WHERE, expression-side
parameters, join-predicate expressions). Each check in
those gates runs identical SQL through fire-crab and `isql` against the
same database file.

## Where each piece comes from

| Behavior | C++ source | Rust counterpart |
|---|---|---|
| operator precedence: `||` over unary `-` over `*`/`/` over `+`/`-` | `src/dsql/parse.y:742-745` | `expr_add` → `expr_mul` → `expr_unary` → `expr_concat` → `expr_atom` |
| arithmetic scale rules (dialect 3): `+`/`-` take the finer scale, `*`/`/` add scales, division pre-scales the dividend by `10^(-2*s2)` | `src/dsql/ExprNodes.cpp` (`getDescDialect3`), probed first | `numeric_bin`, `Expr::result_scale` |
| INT128 width promotion: `*`/`/` promote on ANY int64-ranked operand, `+`/`-` only when an operand already IS int128 | `src/common/dsc.cpp` (`DSC_multiply_result`), `ExprNodes.cpp` | `NumRank`, `Expr::rank_of`, `Expr::is_wide` |
| integer division truncates toward zero; divide by zero raises | `ExprNodes.cpp:2615`, `iberror.h` | `ArithOp::Div`, `EvalErr::DivideByZero` → `isc_arith_except` + `isc_exception_integer_divide_by_zero` |
| CAST to integer rounds half away from zero; to text renders and width-checks | `src/common/cvt.cpp` | `round_scaled_to_int`, `CastTarget`, `EvalErr::ConversionError` (`isc_convert_error`, 22018) |
| string intrinsics UPPER/LOWER/SUBSTRING/TRIM/CHAR_LENGTH compile to their own BLR verbs | `parse.y` → `blr_upcase`, `blr_lowcase`, `blr_substring`, `blr_trim`, `blr_strlen` | `SysFn::{Upper, Lower, Substring, Trim, CharLength}` |
| the system function table: ABS, MOD, SIGN, LEFT, RIGHT, REPLACE, REVERSE, LPAD, RPAD, POSITION, OCTET_LENGTH | `src/jrd/SysFunction.cpp` | the remaining `SysFn` variants |
| LEFT/RIGHT route through SUBSTRING (their negative-length error NAMES it) | `SysFunction.cpp` (`makeLeftRight`) | `substring_impl` shared by all three |
| argument coercion: numbers render to text under string functions, strings parse to numbers under numeric ones | `src/common/cvt.cpp` | `fn_text` (= `Value::render`), `fn_int` |
| IIF is sugar for a searched CASE (an un-aliased IIF columns as `CASE`) | `parse.y` (IIF production builds a `CASE` node) | `RawExpr::Iif` headers as `"CASE"`; `RawExpr::Case` is the general node |
| simple CASE compares its operand with `=` per branch, so `WHEN NULL` never matches | `src/dsql/ExprNodes.cpp` (`DecodeNode`) | simple-CASE desugar into `RawCond::Cmp(op, Eq, value)` at parse |
| three-valued booleans (Kleene AND/OR/NOT) in conditions | `src/jrd/evl.cpp` boolean evaluation | `Cond2::{And, Or, Not}` |
| negative SUBSTRING length: `isc_bad_substring_length` (22011), the value as a message argument; a LITERAL one fails while the describe is computed | `msg/jrd.h:534`, `StrNodes` describe | `EvalErr::InvalidLength`, `Plan::RefusedEval` at prepare, `raw_bad_substring_len` |
| DECFLOAT rendering (cohort preserved, plain/scientific boundary) | the engine's embedded decNumber (`decNumberToString`) | `fire-crab-ods::decfloat` |
| `EXTRACT` parts and result types (SECOND = NUMERIC(9,4), MILLISECOND = NUMERIC(9,1)); a part invalid for the operand's kind fails at prepare (-105) | `src/jrd/ExprNodes.cpp` (`ExtractNode`), probed | `SysFn::Extract(ExtractPart)`, `ExtractPart::valid_for` |
| civil-date math (MJD day 0 = 1858-11-17); WEEKDAY 0 = Sunday, YEARDAY 0-based, ISO 8601 week | `src/common/TimeStamp.cpp`, probed conventions | `civil_of`, `days_of_civil`, `weekday_of`, `iso_week_of` |
| temporal literals `DATE '...'` / `TIME '...'` / `TIMESTAMP '...'`; the clock keywords fixed per statement | `parse.y`, `src/jrd/CurrentDateNode` et al. | `RawExpr::{DateLit, TimeLit, TsLit, CurrentDate, LocalTime, LocalTimestamp}` |
| aggregate result types: AVG/SUM widen to NUMERIC(18,s) (BIGINT width at the operand scale), MIN/MAX keep the column's type, COUNT is BIGINT | `src/jrd/AggNodes.cpp` (`makeDesc`), probed | the `SelItem::Agg` arm of `plan_group` |
| AVG = SUM/COUNT with TRUNCATING division toward zero; folds skip NULLs; empty/all-NULL input is NULL; COUNT(DISTINCT) counts distinct non-NULLs | `src/jrd/AggNodes.cpp` (`AvgAggNode::execute` et al.), probed | `compute_group`, `aggregate` |
| an APPROXIMATE input makes SUM/AVG approximate (the exact fold no longer SKIPS a DOUBLE and answers NULL); AVG over NUMERIC divides at the source's scale | `dsc.cpp` descriptor promotion, probed (`AVG(D)` = 2.6666666666666665, `AVG(NUM)` = 7.27) | the two accumulators in `compute_group`'s SUM/AVG arm |
| an aggregate SUBQUERY takes every argument a select-list aggregate takes - a column, `COUNT(DISTINCT col)`, an expression - and its empty answer is NULL for MIN/MAX/SUM/AVG but 0 for COUNT | the engine has one aggregate implementation, not one per position | `eval_subquery`'s aggregate branch: a one-item, no-key `group_output` |
| aggregates take EXPRESSION arguments, evaluated per row before the fold; an eval error in the argument raises mid-fetch; SUM widens ONE step (LONG source → BIGINT, INT64-ranked → INT128), AVG keeps its width unless the source is INT128 | `AggNodes.cpp` + the expression nodes, probed | `AggTarget::Expr`, `AggSrc::Expr`, the fallible `compute_group` |
| a lone aggregate's output column is NAMED by its function (COUNT/MIN/MAX/SUM/AVG); a bare literal is CONSTANT, a generator read GEN_ID | probed via isql headers | `Plan::Scalar(value, name)`, `output_cols_of` |
| DATEADD/DATEDIFF (both syntaxes each); month-end clamping; TIME wraps midnight; DATEDIFF components vs boundary crossings; MILLISECOND at NUMERIC(18,1) | `src/jrd/SysFunction.cpp` (`makeDateAdd`/`makeDateDiff`), probed | `SysFn::DateAdd`/`DateDiff`, `dateadd_impl`, `datediff_impl` |
| native temporal operators: DATE ± n (numeric addend CVT-rounds), DATE−DATE = days, TIME−TIME = seconds @ −4, TIMESTAMP diff = days @ −9 truncating | `ExprNodes.cpp` arithmetic over temporal descs, probed | the temporal arms of `Expr::Bin` typing/scale/eval |
| WHERE comparison sides are full expressions (arithmetic, functions, CAST, conditionals, column vs column); per-row eval errors raise mid-statement with the engine's vector | `src/jrd/evl.cpp` boolean evaluation over expression nodes, probed | `texpr` (token-level sides), the fallible `Predicate::matches` |
| CASE inside WHERE - the span lexes to its balancing END, keyword-matched (nested CASEs nest, literals skipped) | `parse.y` (CASE is an expression production; the predicate grammar just holds it) | `matching_case_end`, the CASE arm of `tokenize` |
| `?` against an expression side - the bind target descriptor synthesizes from the expression's TYPE (text → VARCHAR, int → BIGINT, numeric → BIGINT at the scale); the arrived value substitutes as a literal | the engine describes parameters from the comparison's other side | `Term::ExprParam`, the param arm of `resolve_expr_term`, `Predicate::bind` |
| expressions in JOIN predicates evaluate against the combined row through a synthetic single-relation view (bare unambiguous names; ambiguous names refuse) | the engine's joined-stream contexts | `resolve_join_predicate`'s combined view |
| GROUP BY takes expression keys, computed per row; a select-list expression must BE one of them (else the engine's -104 "not contained..."); NULL keys share a bucket; `GROUP BY <ordinal>` may name an expression item | `src/jrd/AggNodes.cpp` / DSQL grouping validation, probed | `parse_group_by` (synthetic key slots), `normalize_raw` structural matching |
| HAVING compares numeric aggregates through exact scale alignment, text MIN/MAX through the pad-trimming compare, and takes expression aggregates as hidden folds | `AggNodes.cpp`, probed (AVG(N) > 0 works; MIN(D) has no literal to meet here) | `resolve_having` (`HKind`), `Term::NumCmp` |

## Laws probed against the live engine

Every one of these was established by running SQL through `isql`
BEFORE the Rust was written, and each is pinned by a gate check and
usually a unit test too:

- **`CHAR_LENGTH` counts characters, padding included.** A `CHAR(5)`
  holding `'ab'` answers 5; `CHAR_LENGTH(TRIM(C))` answers 2. fire-crab
  decodes CHAR fields padded exactly as stored, so the padding travels
  through every function (`UPPER(C)` is `'AB   '`).
- **Numbers render before string functions see them.** `UPPER(A)` with
  `A = -7` is `'-7'`; `CHAR_LENGTH(A)` is 2; `LPAD(A, 6, '0')` is
  `'0000-7'`.
- **`SUBSTRING` is a window, not a bounds check.** `FROM 0 FOR 3` on
  `'Hello'` is `'He'` — a start below 1 eats into the length; a window
  past the end is empty; `FOR 0` is empty. Only a NEGATIVE length
  raises.
- **`TRIM` strips repetitions of the whole `<what>` string.**
  `TRIM(BOTH 'ab' FROM 'ababXab')` is `'X'`; an empty `<what>` strips
  nothing.
- **`MOD` rounds non-integer operands half away from zero FIRST.**
  `MOD(12.50, 5)` is 3 (12.50 → 13), then a truncated `%` with C's
  sign rule (`MOD(-7, 3)` is -1, `MOD(7, -3)` is 1).
- **`POSITION`'s empty needle answers its start while a match could
  still begin there.** `POSITION('', 'Hello', 3)` is 3; at 99 it is 0.
  A start below 1 is an argument error.
- **`LPAD`/`RPAD` truncate a past-length value** (`LPAD('Hello', 3)` =
  `'Hel'`), cycle a multi-character pad (`LPAD('Hello', 9, 'ab')` =
  `'ababHello'`), and leave a short string alone under an empty pad.
- **Only a TRUE condition takes a branch.** IIF and CASE alike: false
  and UNKNOWN both move on; the ELSE takes the rest; a missing ELSE is
  NULL. `CASE x WHEN NULL THEN ...` never fires (x = NULL is UNKNOWN)
  even when x IS NULL.
- **Kleene three-valued booleans.** FALSE dominates AND, TRUE dominates
  OR, UNKNOWN dominates the recessive value, NOT of UNKNOWN is UNKNOWN
  — so `WHERE x = 'Q' OR NOT x = 'Q'` keeps every non-NULL row and
  drops the NULL one.
- **A conditional types from its branches together.** ANY exact-numeric
  branch beside integer ones makes the result Numeric at the branches'
  MINIMUM (widest) scale — the engine announces `COALESCE(A, 0.5)` at
  scale -1 and prints `-7.0`. Scales are negative, so "widest" is
  `min()`; anything narrower would truncate a branch's value.
- **The describe's scale is the wire contract.** Each branch's value is
  aligned to the announced scale at emit — `0.5` announced at -2
  travels as raw 50. (The standing bug this law closed: raw 5 decoded
  as 0.05.)
- **Un-aliased output columns take the engine's names.** `ADD`,
  `SUBTRACT`, `MULTIPLY`, `DIVIDE`, `CONCATENATION`, `CAST`,
  `COALESCE`, `NULLIF`, `CASE` (for CASE *and* IIF), the function's own
  name for calls (`CHARACTER_LENGTH` headers as `CHAR_LENGTH`), blank
  for unary minus, `CONSTANT` for a bare literal.
- **EXTRACT's conventions.** `WEEKDAY` is 0 = Sunday (2024-02-29 → 4);
  `YEARDAY` is 0-based (Jan 1st → 0); `WEEK` is the ISO 8601 week
  number (1999-01-01 → 53, of 1998); `SECOND` keeps its fraction at
  scale -4 (12.3456); `MILLISECOND` is the fraction in ms at scale -1
  (345.6). A part that does not exist in the operand's kind fails at
  PREPARE (the engine's -105); so does EXTRACT over a non-temporal.
- **A DATE against a TIMESTAMP converts as midnight.** And a temporal
  branch must not mix with any other family in a conditional - the
  wire form could not carry both (the engine refuses at prepare too).
- **The clock keywords are fixed per statement.** `CURRENT_DATE`,
  `LOCALTIME` (fractional second truncated - probed), `LOCALTIMESTAMP`.
  fire-crab captures them at PLAN time - identical for a client that
  executes right after preparing (isql does), divergent for
  prepare-once-execute-many; an accepted, documented difference.
  `CURRENT_TIME`/`CURRENT_TIMESTAMP` are TIME ZONE types and refuse.
- **AVG divides truncating toward zero at the operand's scale.**
  AVG over integers 1, 2 is 1; over NUMERIC(9,2) values summing -2.95
  across two rows it is -1.47 (floor would say -1.48). SUM and AVG
  over NUMERIC(p,s) announce the engine's NUMERIC(18,s) widening;
  MIN/MAX keep the COLUMN's own type and wire form (a VARCHAR stays a
  VARCHAR, a DATE a DATE). Every fold skips NULLs; an empty or
  all-NULL input answers NULL (COUNT answers 0). `COUNT(DISTINCT col)`
  counts distinct NON-NULL values - NULL is not a value.
- **Aggregate arguments are expressions, folded per row.**
  `SUM(A + ID)`, `MIN(UPPER(S))`, `COUNT(NULLIF(G, 1))`,
  `SUM(IIF(cond, 1, 0))` (the conditional counter). An eval error in
  the argument - `SUM(A / 0)` - raises MID-FETCH with the engine's own
  vector, which is why the group fold is fallible. SUM widens one step
  (a LONG source announces BIGINT, an INT64-ranked one INT128 - probed:
  `SUM(K BIGINT)` and `SUM(A + ID)` both describe INT128-wide); AVG
  keeps BIGINT width unless the source is already INT128; both keep the
  source's scale.
- **Known difference:** the conversion error (22018) raises with the
  matching SQLSTATE but WITHOUT the offending string as a vector
  argument (the engine prints `conversion error from string "pear"`;
  fire-crab's client prints a missing-argument placeholder). Carrying
  the string means a non-Copy error payload - a named later slice.
- **A grouping key can be any typeable expression.** `GROUP BY
  UPPER(S)` merges 'Apple' and 'apple' into one bucket; NULL keys
  share one, exactly as with column keys. A select-list expression
  must BE one of the group's expression keys, matched STRUCTURALLY -
  both sides parse and the trees compare, column names
  case-insensitively, string literals exactly - so `GROUP BY
  upper( s )` matches `SELECT UPPER(S)` while `SELECT LOWER(S)` is
  the engine's -104. `GROUP BY 1` may name an expression select item.
- **Temporal arithmetic laws.** MONTH/YEAR adds CLAMP to the target
  month's end (2024-01-31 +1 MONTH → 2024-02-29; the leap day +1 YEAR
  → 02-28). A TIME wraps around midnight; a DATE absorbs clock units
  by truncation (+25 HOUR moves one day). DATEDIFF is b−a signed:
  YEAR/MONTH difference calendar COMPONENTS, WEEK truncates the day
  difference over 7, the clock units count BOUNDARY CROSSINGS, and
  MILLISECOND keeps its 0.1-ms digit (NUMERIC(18,1)). The native
  differences: DATE−DATE integer days, TIME−TIME seconds at −4, any
  TIMESTAMP pair days at −9 (truncating to 9 exact digits). A numeric
  addend on a date CVT-rounds half away first (D + 0.5 moves a day).
  DATEDIFF is admitted to WHERE (it cannot raise); DATEADD is not (an
  out-of-range result raises).
- **Text comparisons ignore trailing blanks; LIKE does not.** A
  comparison pad-trims both sides (CHAR vs VARCHAR equality); LIKE
  matches the STORED value, padding included — `CHAR(5) 'abc'` matches
  `'abc  '` and `'abc%'` but not `'abc'`.

## The refusal policy

The surface is bounded, and the boundary is enforced by REFUSAL — a
clean SQL error at prepare — never by a wrong answer. The three
mechanisms:

1. **The fixed-answer fallback is closed at the root**: a query the
   planner cannot resolve RAISES (`plan_query`); the 4242 scalar
   survives only for a connection with no database behind it.
   `qa/serve-real-nofallback.sh` hunts leaks across every surface.
2. **A malformed call refuses by name**: once a select list NAMES a
   conditional or function call (`names_expr_call`), any failure to
   resolve it refuses — a broken `UPPER()` must never be read as a
   column named "UPPER()".
3. **Predicates are FALLIBLE** (`Predicate::matches` returns a
   result): a per-row evaluation error inside a WHERE term — `A / 0`,
   a negative length from a column, a failed CAST — PROPAGATES through
   every predicate consumer (the row walk, DML target collection,
   CHECK enforcement, HAVING, group input filters) and reaches the
   client with the engine's own status vector, exactly where the
   engine raises it. This replaced an earlier "no-raise fence" that
   refused could-raise shapes at prepare; the fence's one survivor is
   the type check (a text operand under MOD still refuses) and the
   `?`-parameter-against-expression-side refusal. The error CHANNEL is
   exact now: the conversion error carries its OFFENDING STRING as an
   `isc_arg_string` (isql prints `conversion error from string "pear"`
   identically on both sides), and a DML statement whose WHERE raises
   answers the engine's own vector (`ExecErr::Eval` routes it to the
   status-vector responder). One known difference remains, documented
   not silent: the engine surfaces some cursor errors at EXECUTE where
   fire-crab surfaces them at first FETCH - one leading blank line in
   isql's output.

Known refusals that the engine supports (named next slices, each a
refusal today rather than a silent gap): `LIST` (its result is a
blob, which an expression cannot serve yet), `?` parameters INSIDE an
expression (only a bare `?` on a comparison side binds), QUALIFIED
names in join-predicate expressions, temporal aggregates in HAVING,
temporal parameters against expression sides, `DECODE`, `TIME + n`,
and `CURRENT_TIME`/`CURRENT_TIMESTAMP` (TIME ZONE results). An
aggregate over an APPROXIMATE column (`AVG(D)` where D is DOUBLE) is
refused in every position - the planner has no approximate result type
yet, and refusing it in the subquery too keeps one expression from being
legal in one place and illegal in another. A DATE column in a WHERE
comparison is refused as well, which is why `WHERE DT = (SELECT MAX(DT)
FROM T)` refuses: the gap is the predicate's typing, not the subquery.

## The evaluator's shape

One AST, two stages. `RawExpr` (with `RawCond` for conditions) is the
parse product — column NAMES, no types; `parse_raw_expr` builds it with
a recursive-descent parser whose precedence mirrors `parse.y`.
`resolve_expr` turns it into `Expr` against a relation's columns and
descriptors — field ids, refusing unknown columns, computed columns
(no record bytes to read) and unsupported column types. Typing then
runs entirely on `Expr`:

- `type_of` → `Int` | `Text` | `Numeric` (what the describe announces:
  BIGINT, VARCHAR, or a scaled INT64/INT128);
- `result_scale` → the static scale a Numeric result is announced and
  emitted at;
- `rank_of` → `Long`/`I64`/`I128` storage rank, driving the INT128
  describe promotion;
- `eval` → a `Value` per row, `Err(EvalErr)` for the runtime errors,
  each mapped to the engine's own status vector
  (`write_eval_error`/`respond_eval_error`).

The invariant the wire depends on: **whatever `type_of`/`result_scale`
announced, `value_of` delivers** — values align to the announced scale,
an INT64-announced value past `i64` raises the engine's integer
overflow rather than truncating, and a NULL is a NULL in any type.

WHERE predicates reuse the same `Expr`/`Cond2` machinery inside
`Term::ExprCond`/`Term::ExprLike` leaves of the DNF the predicate
parser produces — one evaluator, one set of semantics, gates on both
sides of it.
