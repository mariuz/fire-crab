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
`qa/serve-real-case.sh` (CASE, and cross-branch typing). Each check in
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
3. **Predicate expressions pass a no-raise fence** (`expr_no_raise`): a
   WHERE term answers only true/false and cannot carry the engine's
   mid-cursor error, so anything whose per-row evaluation could raise
   (MOD by a non-literal or zero divisor, a length read from a column,
   a text operand under a numeric function, CAST) refuses at prepare.
   The select list has no such fence — there an eval error IS reported
   mid-cursor with the engine's own status vector, which is what the
   engine does too.

Known refusals that the engine supports (named next slices, each a
refusal today rather than a silent gap): `EXTRACT` and the date/time
function family, `AVG` and `LIST` aggregates, function calls in HAVING
and in join predicates, arithmetic inside WHERE terms, `?` parameters
against expression sides, CASE inside WHERE, `DECODE`, `COALESCE` in
the simple-CASE operand position of an INSERT list.

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
