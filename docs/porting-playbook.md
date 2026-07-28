# Porting playbook: tips for the next agent, in any language

fire-crab is Rust, but nothing about the METHOD is. This document is
for the next agent (human or machine) porting Firebird's behavior into
another language — or continuing this conversion — written as the list
of things we wish we had known on day one, with the core algorithms in
language-agnostic pseudocode. The Rust is the reference implementation;
the engine's C++ is the specification; this file is the map between
them.

## The method, before any code

1. **Probe before you implement.** Every semantic here was established
   by running SQL through `isql` against the live engine FIRST, and the
   probe's output went into the code comments and the tests. If you
   cannot state the expected output before writing the function, you
   are about to guess — and the engine has thirty years of decisions
   you will guess wrong. (Examples that would have been guessed wrong:
   `MOD(12.50, 5) = 3`; `CHAR_LENGTH` of a `CHAR(5)` counts padding;
   `POSITION('', s, 99) = 0` but at 3 it is 3; an un-aliased IIF
   headers as `CASE`; `EXTRACT(YEARDAY ...)` is 0-based.)

2. **The engine is the oracle, differentially.** A gate is a script
   that runs IDENTICAL input through your port and the real engine on
   the SAME database file and compares outputs exactly. Value-for-value
   beats "looks right". Where the engine can validate your WRITES, let
   it: have `gfix -v -full` check the file, have the engine read your
   tables, have its own GC collect your version chains.

3. **Never answer wrong; refuse loudly.** The worst outcome is not a
   missing feature — it is a plausible wrong answer. Every unsupported
   shape must RAISE a clean SQL error at prepare. This project shipped
   a fixed placeholder answer (4242) early on, and closing the paths by
   which it could leak took six separate fixes; do not have a fixed
   answer at all if you can avoid it.

4. **A gate proves its cases and says nothing about the queries just
   outside them.** Two standing bugs survived dozens of green gates
   because the fixtures were too uniform: conditionals typed from their
   first branch alone (`COALESCE(A, 0.5)` — every gate had written the
   literal at the column's own scale), and the query splitter took the
   first `FROM` in the statement (no gate had put `SUBSTRING(x FROM 1)`
   in a select list). Diversify fixture SHAPES, not just values.

5. **Prove a new gate fails on the old binary.** A gate that passes
   before the fix is vacuous. Stash, build the pre-change binary, run
   the gate, expect red; then apply the change and expect green.

## The core algorithms, in pseudocode

### Expression pipeline (two-stage AST)

    # Stage 1: parse against NAMES (no schema yet)
    RawExpr := Col(name) | Int(n) | Dec(raw, scale) | Str(s) | Null
             | Neg(e) | Bin(a, op, b) | Concat(a, b) | Cast(e, target)
             | Coalesce([e]) | NullIf(a, b) | Iif(cond, a, b)
             | Case([(cond, e)], else?) | Func(kind, [e])
             | DateLit(days) | TimeLit(units) | TsLit(days, units)

    # Stage 2: resolve against a relation -> typed Expr
    resolve(raw, columns, descriptors):
        Col(name) -> look up field id; REFUSE unknown, computed,
                     unsupported-dtype columns
        every other node -> resolve children

    # Four functions on the resolved tree; keep them CONSISTENT:
    type_of(e)      -> Int | Text | Numeric | Temporal(kind) | REFUSE
    result_scale(e) -> the scale the describe announces (numerics only)
    rank_of(e)      -> storage width (long / int64 / int128) for the
                       describe's INT128 promotion
    eval(e, row)    -> Value | NULL | Error(engine_status_vector)

    # THE INVARIANT THE WIRE DEPENDS ON: whatever type_of/result_scale
    # announced, the emitted value must match. Align at the emit point:
    emit(col, row):
        v = eval(col.expr, row)
        if v is numeric and scale(v) != col.announced_scale:
            v.raw *= 10^(scale(v) - col.announced_scale)   # min-scale
                          # announce means this only ever multiplies
        if v does not fit the announced width: raise integer-overflow
        encode(v, col.wire_form)

### Dialect-3 numeric arithmetic (scales are NEGATIVE: 12.50 is -2)

    add/sub(a@sa, b@sb): s = min(sa, sb)
                         align both raws to s (multiply by powers of 10)
                         result = a ± b @ s          # checked, no wrap
    mul(a@sa, b@sb):     result = a*b @ (sa+sb)
    div(a@sa, b@sb):     if b == 0: raise divide-by-zero
                         result = (a * 10^(-2*sb)) / b @ (sa+sb)
                         # integer division truncating toward zero

    # conditionals (COALESCE/IIF/CASE): result scale = MIN over branch
    # scales (the widest); result type = Numeric if ANY branch is
    # exact-numeric and none is text; refuse mixed temporal kinds

### Three-valued logic (the whole predicate surface hangs on this)

    # a condition evaluates to TRUE | FALSE | UNKNOWN
    cmp(a, b):    UNKNOWN if either is NULL, else compare
                  (numerics align exactly in wide integers; text
                  ignores TRAILING blanks; LIKE does NOT)
    NOT u:        UNKNOWN stays UNKNOWN
    AND:          FALSE dominates, then UNKNOWN, then TRUE
    OR:           TRUE dominates, then UNKNOWN, then FALSE
    WHERE keeps a row only on TRUE
    IIF/CASE take a branch only on TRUE (false AND unknown move on)
    NOT pushed into comparison leaves flips the operator - sound,
    because the inverse of UNKNOWN is still UNKNOWN
    simple CASE desugars to '=' conditions -> WHEN NULL never matches

### Predicate normalization

    parse WHERE into: OR over AND over NOT/parens over leaves
    desugar: BETWEEN -> (>= AND <=); IN -> OR of '='; their NOT forms
             fall out of De Morgan
    normalize to DNF (OR of AND-groups), pushing NOT into leaves
    CAP the group count (cross-products explode); past the cap REFUSE
    parameter slots are claimed at PARSE time in textual order, so a
    leaf duplicated by the DNF cross-product keeps its one slot

    # expression sides in predicates: lex calls as single tokens (scan
    # to the MATCHING paren, skipping string literals); fold arithmetic
    # operator tokens back into expression trees with a token-level
    # precedence parser; a side that reduces to a bare column or
    # literal keeps the fast paths (parameter binding, index-friendly
    # terms)
    # MAKE THE PREDICATE FALLIBLE: matches(row) -> TRUE | FALSE | Error
    # and PROPAGATE the error through every consumer - the row walk,
    # DML target collection, CHECK enforcement, HAVING, group filters.
    # The tempting alternative (skip the erroring row) silently drops
    # exactly the row the engine raises on. A closure that cannot
    # propagate captures the first error and the caller re-raises it
    # after the walk.
    # keyword-span lexing: CASE has no parens - balance the KEYWORDS
    # (CASE opens, END closes, word boundaries only, string literals
    # skipped) and hand the whole span to the expression parser
    # parameters against expression sides: synthesize the BIND TARGET
    # from the expression's type (the client encodes against it), then
    # substitute the arrived value as a LITERAL and re-resolve the term
    # - binding machinery stays in one place, evaluation in another
    # ERRORS ARE VALUES WITH PAYLOADS: the conversion error carries the
    # offending STRING (the client's message formatter needs it as a
    # vector argument - a code alone prints a placeholder), and every
    # error channel between evaluator and wire must carry the VECTOR,
    # not flatten it to text - a DML path that stringifies its errors
    # answers a generic code where the engine ships 22012.

### Civil-date math (MJD epoch: day 0 = 1858-11-17)

    # Howard Hinnant's algorithms; verify with round-trip tests over
    # leap days and era boundaries
    civil_of(days)  -> (y, m, d)        # via the 400-year era cycle
    days_of_civil(y, m, d) -> days      # the exact inverse
    weekday(days)   = (days + 3) mod 7  # day 0 was a Wednesday;
                                        # 0 = Sunday, the engine's rule
    yearday(days)   = days - days_of_civil(year, 1, 1)     # 0-BASED
    iso_week(days):
        thursday = days + 3 - ((weekday(days) + 6) mod 7)  # Mon-based
        return (thursday - days_of_civil(year_of(thursday), 1, 1)) / 7 + 1
    # time of day travels as units of 1/10000 second
    EXTRACT(SECOND)      = units mod 600000 @ scale -4     # 12.3456
    EXTRACT(MILLISECOND) = units mod 10000  @ scale -1     # 345.6

    # DATEADD: calendar units move the CIVIL date with month-end
    # CLAMPING (Jan 31 +1 MONTH = Feb 29/28); clock units move the
    # (days, units) total with euclidean carry; project back onto the
    # operand's kind - a DATE drops the time (so +25 HOUR moves one
    # day), a TIME drops the days (the midnight wrap)
    dateadd(unit, n, d, u, kind):
        YEAR|MONTH: idx = y*12 + (m-1) + months(n)
                    y,m = idx divmod 12;  day = min(day, last_of(y,m))
        WEEK|DAY:   d += n * (7|1)
        clock:      total = d*UNITS_PER_DAY + u + n*per_unit
                    d, u = total divmod UNITS_PER_DAY   # euclidean!
    # DATEDIFF is b - a SIGNED: YEAR/MONTH diff calendar COMPONENTS
    # (not durations); WEEK = day_diff / 7 truncating; clock units
    # count BOUNDARY CROSSINGS: floor(total/per_unit) each side, then
    # subtract; MILLISECOND keeps the sub-ms digit at scale -1
    # native operators: DATE-DATE = days (int); TIME-TIME = unit diff
    # @ -4 (seconds); TIMESTAMP diff = unit_diff * 1e9 / UNITS_PER_DAY
    # truncating, @ -9 (nanodays); date ± number rounds the number
    # half away from zero FIRST (CVT), then adds days

### Aggregates (one fold per function, NULL rules first)

    # every fold SKIPS NULLs; empty/all-NULL input -> NULL
    # (COUNT -> 0; COUNT(*) counts rows regardless)
    COUNT(col):          count of non-NULL values
    COUNT(DISTINCT col): distinct non-NULL values - compare with the
                         SAME equality the predicates use (exact
                         numeric alignment, pad-trimmed text), never
                         a hash of the raw bytes
    MIN/MAX(col):        keep the winning VALUE under the one shared
                         comparison; result type = the COLUMN's type
    SUM(col):            fold numeric raws WIDE (128-bit) at the
                         column's scale; announce the engine's
                         NUMERIC(18, scale) widening
    AVG(col):            SUM and non-NULL count in one pass, then
                         divide TRUNCATING TOWARD ZERO at the
                         operand's scale (ints: AVG(1,2) = 1;
                         negatives: -2.95/2 = -1.47, not -1.48)

    # aggregate ARGUMENTS are expressions: evaluate per row BEFORE the
    # fold, and let an eval error ABORT the fetch with the engine's
    # vector (SUM(A/0) is the divide-by-zero, not a wrong sum) - so
    # the fold must be fallible, not a silent skip
    # SUM's result widens ONE step over the source's storage width;
    # AVG keeps the width; both keep the source's scale

    # GROUP BY: bucket rows by key values (NULL keys share a bucket),
    # run every fold per bucket; HAVING filters the COMPUTED output
    # rows and may reference aggregates NOT in the select list -
    # append them as hidden outputs, computed but never emitted.
    # A value wider than the announced wire form must RAISE at emit,
    # never encode truncated bytes.

    # EXPRESSION keys: evaluate each key expression per input row into
    # a SYNTHETIC value slot past every real field - bucketing and
    # output then read it like a field, and nothing else changes.
    # Match select-list expressions to keys STRUCTURALLY: parse both,
    # normalize column names (uppercase them - string literals keep
    # their case), compare the trees. Text comparison of raw SQL is
    # the tempting wrong answer (spacing, case, comments).
    # HAVING terms compare by the aggregate's OUTPUT shape: integers
    # directly, numerics through exact scale alignment, text through
    # the pad-trimming compare; expression aggregates fold as hidden
    # output items.

### SQL LIKE (character-based, backtracking)

    match(value_chars, pattern_chars, escape?):
        '%'  try every split point (recurse)
        '_'  exactly one character
        esc  next pattern char is literal
        else exact character
    # multi-byte text: per CHARACTER, never per byte
    # comparisons pad-trim; LIKE matches the STORED value, padding
    # included (a CHAR(5) 'abc' matches 'abc  ' and 'abc%', NOT 'abc')

### SQL -> BLR (the compiler itself, when you get there)

    # THE ORACLE IS FREE: CREATE VIEW makes the original compiler run
    # on your exact input and store its output in the catalog
    # (RDB$VIEW_BLR) - compare BYTES, never structure descriptions
    compile(select):
        emit version, rse, stream-count
        emit relation(counted-name, context-id)   # names UPPERCASED
        if where: emit boolean-clause, tree
        emit end, eoc
    # the select list compiles to NOTHING in a view - resist emitting
    # a projection; the mapping is positional catalog data
    negate(tree):          # the compiler folds NOT at compile time
        cmp     -> inverse verb          # NOT (a > b)  =>  a <= b
        and/or  -> De Morgan on negated children
        between -> or(lss(lo), gtr(hi))
        not     -> cancel
        like, missing -> keep a real NOT node
    # literals: integers little-endian at their storage width; decimals
    # keep the WRITTEN scale; strings carry charset + length words
    # a SIGN before a numeric literal FOLDS into it - emit blr_negate
    # only before non-literals; IN compiles to a dedicated list verb
    # with a count word, and NOT IN keeps a real NOT node
    # joins NEST: an explicit JOIN is a stream-like node inside the
    # rse, carrying its ON clause as its own boolean sub-clause;
    # aliases store UPPERCASED IN DOUBLE QUOTES (read the bytes, not
    # the docs); NEVER guess a bare field's context in a multi-stream
    # statement without the catalog - a wrong context compiles a
    # DIFFERENT query that still executes
    # join CHAINS nest LEFT (join2's node holds join1's node as its
    # first stream slot); the OUTER-join type marker is a sub-clause
    # on its own node only, and INNER emits NO marker at all - probe
    # which variants are byte-identical (LEFT == LEFT OUTER)
    # functions: probe every operand-layout byte - a length-kind byte
    # (CHAR vs OCTET), a trim-where byte, a spec byte; SUBSTRING's
    # start is 0-based and the reference compiler emits the -1
    # arithmetic UNFOLDED (subtract(from,1), not a folded constant) -
    # match the tree it builds, not the value it means
    # an unknown name before '(' is a function you have NOT converted:
    # REFUSE - falling back to 'it must be a field' compiles garbage
    # that parses
    # conditionals carry the reference compiler's TYPE ALGEBRA: the
    # searched CASE compiles as cast(unify(branches), value_if chain)
    # - probe the unification law (ignored NULLs, max text width, max
    # int-digits + min scale with the dtype that FITS: two longs can
    # unify to an int64) and REFUSE any branch whose descriptor you
    # cannot know without the catalog (fields); sugar forms (IIF,
    # NULLIF) reuse the same nodes - probe WHICH operands count as
    # branches (NULLIF's comparand does not)
    # cast targets do not follow the obvious table: NUMERIC(4) and
    # DECIMAL(4) compile to DIFFERENT dtypes - probe every target
    # DISTINCT is the ONE select-list trace: a projection clause
    # AFTER the boolean; a scalar subselect is via(singular(rse),
    # value, null); a derived table is an rse IN A STREAM SLOT with
    # ONE context shared by inner and outer references - and its
    # alias text carries the schema-qualified table (read the bytes:
    # a plain alias does not)
    # UNION claims its OWN context BEFORE any branch stream - scan
    # for it before assigning contexts; each branch is rse + a map of
    # field numbers; only the DISTINCT form projects (over fid)
    # when the FIRST oracle runs dry (views cannot hold ORDER BY or
    # parameters), find the SECOND: procedure bodies are compiled by
    # the same DSQL and stored verbatim too - and the engine's own
    # BLR disassembler (isql SET BLOB ALL) reads the wrapper for you
    # procedure-body laws: contexts number from 0 (views from 1!) -
    # carry a context BASE, not two parsers; message = per-param dsc
    # + null-flag short + one trailing EOF short; ORDER BY = a sort
    # clause after the boolean with a direction marker per key; the
    # INTO names choose the VARIABLE per column - order matters
    # calls are counted lists (name, in-count+values, out-count+
    # targets); EXIT is just leave-the-outermost-label - control
    # verbs COMPOSE from what you already have; and when a refusal
    # falls to a new probe, GENERALISE the law (aggregate ctx =
    # stream+1 anywhere) instead of special-casing the new point
    # unify statement machines EARLY: the single-statement wrapper
    # you converted first is a special case of the general body -
    # refactor toward one machine and let the accumulated byte-pins
    # prove the refactor emits every old shape identically
    # name resolution SPLITS BY SCOPE: outside stream scopes bare
    # names are variables-then-parameters; inside a select or DML
    # WHERE they are COLUMNS and variables need their marker - one
    # resolver with a scope flag, not two resolvers
    # PSQL control is MORE compiled sugar: a WHILE is a labelled
    # loop whose body IF leaves on failure; event predicates
    # (INSERTING) are comparisons against an internal-info call, so
    # your negation law already handles NOT INSERTING; and the SAME
    # declare section can be grouped or interleaved DEPENDING ON THE
    # BODY KIND - probe each wrapper separately, symmetry lies
    # the DML verbs split one statement across TWO contexts: UPDATE
    # reads the org stream and writes a new-record context that was
    # allocated FIRST - probe the allocation order, not just the
    # verbs; the reference compiler STAMPS its own DML loops (marks)
    # - emit the stamp, don't reason about it; an INSERT without a
    # column list is a catalog lookup in disguise: refuse it
    # the THIRD oracle (triggers) is the leanest: record contexts
    # (OLD/NEW) are just STREAMS by another name - model them as
    # pseudo-streams and the whole field machinery carries over; the
    # trigger header compiles to NOTHING; a missing ELSE is a bare
    # end-marker byte in the else slot; a nested block DOUBLES the
    # begin - read the bytes, not the grammar
    # a singular select is the SAME loop verb over a singular-wrapped
    # rse - and the row-send is NOT part of the loop: SUSPEND is its
    # own statement, sibling to the for; probe what a missing SUSPEND
    # removes
    # row limits are rse sub-clauses with a probed ORDER (stream,
    # first, skip, boolean, sort); some DISTINCT aggregates get their
    # own verbs while MIN/MAX fold it away - probe each one
    # input parameters are a MESSAGE, not variables: references
    # compile straight to message slots (value slot, null slot), the
    # loop waits under a RECEIVE, and the messages differ - inputs
    # have no EOF slot, outputs do; probe which sends sit inside vs
    # outside the receive
    # aggregation RECASTS the query: the aggregate is a STREAM with
    # its own context; the WHERE belongs to the SOURCE rse inside it,
    # and everything after the aggregation (loop body, HAVING, ORDER
    # BY) addresses OUTPUT SLOTS, not source fields - HAVING is just
    # the outer boolean over slot refs; probe the TWO orders (group
    # list = clause order, map = select order) and the slot DEDUP
    # rule (an equal aggregate reuses its slot); count-star and
    # count-of-values are DIFFERENT verbs
    # subquery predicates come in TWO shapes: existence (one verb +
    # one rse, the subquery WHERE as its boolean) and quantified (a
    # DOUBLE-nested rse: the outer rse's single stream IS the
    # subquery's rse, the comparison the outer boolean) - and
    # negation FLIPS the quantifier while INVERTING the comparison
    # (NOT IN == <> ALL); subquery streams take the NEXT context ids
    # in the statement's numbering but must stay INVISIBLE to outer
    # bare names - and inside the subquery a bare name binds to the
    # innermost scope, the one rule you may assume without a catalog

## Traps that cost real time (all found the hard way)

- **FIELD_ID is not FIELD_POSITION.** Catalog rows order columns by
  position; records store by field id; DROP COLUMN leaves ID HOLES.
- **The clause splitter must be paren- and literal-aware.** `FROM`
  appears inside `SUBSTRING(x FROM 1)` and inside string literals;
  `AS` appears inside `CAST(x AS INT)`; `WHERE`/`ORDER` can sit inside
  literals. Mask literals, count parens, then search.
- **Clients DISPATCH on metadata you might think is cosmetic.** The
  statement-type code decides whether a client opens a cursor
  (announcing 6 for SAVEPOINT made isql roll back the transaction);
  the nullable bit decides whether NULL renders (its absence rendered
  every NULL as 0); the prepare must answer the client's REQUESTED
  info items in order.
- **Refuse at PREPARE, not mid-cursor.** A refusal after the describe
  reads as "request synchronization error" and some clients drop the
  connection — which is what libfbclient segfaults on. Runtime data
  errors (divide by zero on row 7) ARE mid-cursor; unsupported
  statements are NOT.
- **One statement handle per statement.** Serving every prepare from
  one slot works until a client interleaves two statements, then it
  reads the WRONG statement's rows.
- **Comparing mixed numeric shapes needs exact alignment.** `0` vs
  `0.00` differ in raw form; align raws in a wide integer before
  comparing. Text-comparing rendered forms is the tempting wrong
  answer.
- **Case mapping, week numbers, and NULL rules are where "obvious"
  implementations diverge.** When your answer and the engine's differ,
  THE ENGINE WINS — even when your gate asserted otherwise (then the
  gate is wrong; fix the gate).

## Suggested porting order

The order that worked here, each stage differentially testable with
the tools of the previous one: on-disk structures against `gstat` →
record decoding against live SELECTs → transactions/MVCC against a
frozen file → the wire protocol as a CLIENT of the real server (this
validates your codec before you serve) → a server answering COUNT(*)
→ projections → predicates → sorting/grouping → writes (with the
engine validating the file) → DDL → expressions → PSQL. At every
stage there is a real differential; no stage trusts the previous one's
unproven parts.
