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
    # every NEW clause keyword is an alias-slurp bug until proven
    # otherwise (FROM T PLAN parsed PLAN as the alias) - grep the
    # stream parser's alias arm when adding grammar; and widening a
    # parser (val() for sort keys) can turn an old REFUSAL into
    # wrong bytes (ORDER BY 1 = a position) - re-check refusal tests
    # after every parser widening
    # when the compiler direction is converted, the EXECUTION
    # direction reuses every law backwards: the interleave rule you
    # probed to WRITE declares is the rule for READING them; write
    # the executor against the disassembly of the reference
    # compiler's own output, and gate BOTH arrows in one check
    # (recompile-and-diff the bytes, execute-and-diff the rows)
    # sort defaults are PROBED, not assumed: the reference engine
    # collates NULL LOW (first ascending, last descending) - one
    # ORDER BY over a nullable column settles it
    # legacy syntax may be ARITHMETIC in disguise: ROWS m TO n
    # compiles to unfolded add/subtract trees IN the first/skip
    # slots (the SUBSTRING -1 lesson at clause scale) - probe the
    # TREES the reference compiler builds, not the values they mean
    # a law probed at one oracle CARRIES: view DISTINCT (project
    # after the boolean) lands at body numbering unchanged, and the
    # INDEX plan form just swaps the sequential marker for a
    # counted-name verb - probe the carry once, let the gate hold
    # the variations; recursion is a union with a STREAM-LESS
    # branch reading its own output context by fid - hold the
    # transcript until the emission path exists
    # a positional law may really be a CONTRIBUTION law: the
    # aggregate map was never items-in-order but items-CONTRIBUTING
    # in order (fields or verbs, deduped) - the degenerate case hid
    # it for thirty slices; generalize the mechanism and let the old
    # pins prove the degenerate case still holds
    # a NEW keyword may be an OLD shape's spelling: WITH ctes
    # inline as the derived tables you already emit - before
    # building machinery for a feature, probe whether the reference
    # compiler REDUCES it to one you have; a token-span jump-parse
    # expands a definition at its use site without re-architecting
    # when a wrapper claims the FIRST slot (union before its
    # branches), a LOOKAHEAD reservation beats re-parsing: scan for
    # the keyword at depth 0, reserve, then parse normally; and an
    # old refusal may be a KNOWN shape in new clothes - INSERT..
    # SELECT is the slice-12 DML loop around a store
    # route special cases through the RESOLVER, not around it: the
    # bare-name fast paths that once mis-bound over joins gained
    # alias translation for FREE the moment they went through
    # field() - every parse site that builds a reference by hand is
    # a translation feature it will never receive
    # an UNPLANNED capability is an UNTESTED one: composable parsers
    # accept shapes nobody converted on purpose (derived tables in
    # subqueries rode along for nine slices) - inventory what the
    # grammar ACCEPTS and pin or refuse it, don't discover it later
    # a verb family may hold TWO generations: the framed window
    # re-encodes every v3 clause under subcodes and adds its own
    # terminator - when a feature was bolted on, expect the OLD
    # layout nested inside the NEW tagging; and argument fills are
    # CANONICALIZATION (LAG(x) emits three args) - probe the short
    # forms against the long ones to find what the compiler fills
    # a WINDOW is an aggregate that KEEPS its rows: same map/verb
    # machinery, but passthrough columns join the map and partition
    # keys appear TWICE (source form + remapped fid) - when a clause
    # emits the same operand in two encodings, the second is usually
    # a reference INTO the first's structure; find the indirection
    # completions COMPOUND: a stamp built for one law (cursor alias
    # infection) covers the next (joined cursors) with zero new
    # emission code, and a next-slot law (aggregate ctx) generalizes
    # by COUNTING PAST whatever sits before it - design mechanisms
    # around the INVARIANT, not the case that revealed it
    # a FAST PATH is a resolution POLICY in disguise: the
    # single-stream bare-name shortcut silently mis-binds the moment
    # a second stream appears - audit every hardcoded ctx when a
    # scope grows; and sibling verbs may count DIFFERENTLY
    # (function2 counts in a byte, exec_proc2 in u16s) - never
    # assume a family shares conventions
    # when a name isn't known until AFTER its clause parses (AS
    # CURSOR), stamp POST-PARSE: walk the finished tree and set a
    # slot - cheaper than threading context through every parser;
    # and a guard added for one reason (subqueries in ON clauses)
    # can silently fire in another regime (declare sections) - when
    # a flip refuses unexpectedly, find WHICH guard, not just where
    # an ALIAS CONVENTION can infect a whole rse: every stream under
    # a cursor's rse - subquery streams included - carries the
    # cursor's alias string; when a wrapper stamps its children,
    # probe the CHILDREN, and guard by STRUCTURE (stream-count
    # growth) when a law is known but not yet worth its plumbing
    # a formula probed in ONE regime may BE the general law: the
    # view subquery ctx (si + 1) was next-id-at-base all along -
    # write formulas in terms of the parser's base/offsets, and a
    # scope hole (outer refs from subqueries) may need one SLOT, not
    # a scope system: host = the enclosing statement's stream
    # the OLDEST refusals get cheap: an alias guard written in
    # slice 7 fell to three probes in slice 28 because every law it
    # feared (quoted-alias emission, qualified resolution, the
    # relation3 slot) had been converted for OTHER reasons since -
    # re-audit early refusals after the surface around them fills in
    # a context-dependent ENCODING may need only one switch: streams
    # inside subroutines swap relation/relation2 for relation3, and
    # a flag on the parsed stream let the WHOLE statement surface
    # through unchanged - convert the encoding, then let the gate
    # prove the compositions; and empty-operand conventions differ
    # BY VERB (a zero-arg function call keeps its tag at count 0,
    # a no-input procedure call drops it) - probe each verb's empties
    # a nested program is a BLOB: subroutines carry their whole
    # body's BLR as a counted payload compiled by the SAME machinery
    # on a fresh parser - refactor for reentrancy, then diff the
    # nested wrapper against the top-level one (stall, slot
    # reservation, send shapes all differ); and a law probed only on
    # size-1 cases may be TWO laws (locals group, outputs interleave)
    # - grow one probe dimension past every prior probe's size
    # branch chains nest BY POSITION: an if's else slot is simply
    # the next if, unmarked - only the innermost needs its bare end;
    # and one keyword can pick between THREE verbs by what the
    # statement CARRIES (EXECUTE STATEMENT: exec_sql, exec_into,
    # exec_stmt) - convert the dispatch, not just the shapes
    # ONE source clause can take THREE shapes by verb (RETURNING:
    # store2's second begin, modify2 under a singular rse, delete's
    # begin-wrapped PLAIN erase) - and a clause can change the verb
    # AND the rse (singular) at once; a sub-verb can outrank its
    # sibling (directed fetch = sub-verb 3 even for NEXT); operand
    # order can INVERT intuition (exec_into: variables AFTER the
    # loop body they feed) - probe the whole sentence, every time
    # a composite verb (MERGE) may be ONE probed sentence: a join,
    # a dbkey-missing test, an if - with LAWS where you'd expect
    # options (join type follows the branch SET, the rse boolean is
    # the branch-union in canonical order, SQL branch order is
    # traceless, branch contexts allocate by KIND not position);
    # probe the variants until the sentence stops changing
    # a marker byte can sit on EITHER side of its verb: positioned
    # DML trails its marks where loop DML leads them - and the same
    # SELECT machinery you built for FOR-loops (aggregates, maps,
    # alias resolution) transplants into a declaration verb with only
    # its OUTPUT convention changed (bare fids vs derived_expr); when
    # the reference demands a name (aggregate columns), demand it too
    # a NAME can ride in an ALIAS SLOT (cursors reuse the derived-
    # table alias convention) - and DECLARATION SECTIONS have their
    # own ordering laws (inits defer past cursor decls): when a gate
    # entry diffs on ORDER, pin the order with targeted probes before
    # touching the emitter
    # composite statements (upsert) are TRANSCRIPTS of their
    # execution plan: try-update, test row_count, store - and the
    # CONTEXT ORDER records the COMPILE order, not the run order
    # (the insert half claims its slot first); convert composites
    # from their probed transcript, never from their semantics
    # error handlers change the BLOCK's whole shape (a guarded block
    # is a different verb than a plain one) - and the same brace pair
    # compiles differently by POSITION (handler bodies nest the block
    # verb again); when one probe raises a question about an OLD
    # shape, spend the next probe settling it
    # the SAME source clause can compile to DIFFERENT shapes in
    # different stores (a domain CHECK is the raw boolean; a table
    # CHECK is a negated if-abort trigger) - and the SAME concept can
    # take different verbs by syntax alone (GEN_ID vs NEXT VALUE FOR)
    # - probe every store separately, never assume shape follows
    # meaning
    # a NEW battery angle on an OLD surface is still a probe: the
    # CHECK batteries exposed that IN-list items get CAST to the
    # column's catalog type - a law sixteen slices of view batteries
    # never hit because they only listed integers; when a new gate
    # contradicts an old assumption, probe the OLD oracle again
    # constraint checks are the reference compiler EATING ITS OWN
    # DOG FOOD: the CHECK condition compiles NEGATED through the same
    # fold your NOT uses, into a system trigger you can byte-compare
    # keep hunting oracles: the reference system stores compiled
    # output in MORE places than the obvious ones (views, procedures,
    # triggers, COLUMN defaults and computed expressions) - each new
    # store is free differential coverage; and when the reference
    # grammar is NARROW (defaults), mirror the narrowness - accepting
    # more than the reference is as wrong as accepting less
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
- **A two-arrow gate turns gaps into a work queue.** When executor
  checks pin BOTH the compiler's bytes and the runtime's rows, a
  missing compiler feature swaps a check out AND names it; a later
  compiler slice clears the list and the checks re-enable
  themselves. Triage the list before converting it: one "gap" was
  the reference engine's own syntax error, another a model boundary
  (catalog-typed casts in a catalog-free compiler) - name those as
  what they are instead of forcing them.
- **Some mechanisms are a COUNTER wearing a message's clothes.**
  Firebird's events look like a pub/sub queue and are not: the block
  holds a count, the interest holds a threshold, and commit-time
  delivery, rollback swallowing, coalescing and one-shot interests
  all fall out of that. Find the state variable before modelling the
  protocol.
- **A differential can be SEMANTIC.** Where the transport is shared
  memory you have not converted, drive the reference through a real
  client, print the observable facts from both sides, and compare
  those - matching on the INVARIANT (a delta) rather than absolutes
  that carry history.
- **When a decision surface looks arbitrary, CHANGE AN INPUT you had
  not thought of.** An optimizer grid made no sense until statistics
  were refreshed - and then the reference's own formulas explained
  every cell. The shape you cannot model may be the model running on
  an input you did not know you were feeding it.
- **Reproduce the reference's IMPRECISION, not the truth.** Its
  cardinality estimator samples one data page and extrapolates, so
  500 rows come out as 628 - and every cost decision is made on THAT
  number. Converting a "better" estimator would diverge from the
  reference exactly where it matters. Port the formula, including
  the parts that look wrong.
- **For a partly-converted decision model, assert the SHAPE of the
  result: exact where you know, refuse where you don't, never
  wrong.** A grid of inputs with that three-way tally is a stronger
  gate than a handful of passing cases, and it tells you precisely
  how much of the model you have.
- **A gate on EMPTY tables cannot see a cost model.** Four slices of
  optimizer rules verified perfectly against empty relations and
  were wrong the moment rows existed: the reference engine drives
  the smaller stream and switches join methods by cardinality.
  POPULATE a database in the gate, and where the decision turns on
  statistics you have not converted, MEASURE the input (row counts)
  and refuse - naming the number - instead of printing a confident
  answer.
- **When a special case keeps growing, look for the general rule it
  is a case OF.** A two-stream join swap, a three-stream reordering
  and an ORDER BY that navigates the wrong table's index were three
  separate mysteries until equivalence classes explained all three -
  and the special-case code then DELETED itself (the swap is the
  general rule at n = 2). Convert the general rule and let the
  earlier cases fall out.
- **Before assuming a subsystem has no oracle, look for its
  EXPLAIN.** The optimizer seemed to need timing comparisons; the
  reference engine prints its chosen plan as text and executes
  nothing (SET PLANONLY ON). A decision printed as text is the
  cheapest oracle there is - and it makes the difference between
  converting selection rules and guessing at them.
- **Some differentials only run ONE WAY - say so.** Stream blobs
  reach disk through the API's blob-parameter block, never through
  SQL, so the reference engine cannot be asked to produce one for
  comparison. The honest gate holds the direction that exists (you
  write, it reads) and names the missing half in its header rather
  than faking a round trip.
- **The code is the specification; comments are testimony.** ods.h
  calls blh_max_sequence "Number of data pages"; the reading loop's
  `>` test makes it the LAST sequence (count minus one). Writing
  what the comment said produced a file the reference engine called
  corrupt. When a comment and a comparison operator disagree, the
  operator wins - and a both-directions gate (they write/you read,
  you write/they read) is what catches the disagreement.
- **Pin transcriptions against the SOURCE they transcribe.** A 49-cell
  boolean matrix is a transcription slip waiting to happen - so the
  gate re-parses the table out of the reference engine's own source
  and diffs every cell. When the artifact you copied lives in the
  vendored tree, make the copy mechanically checkable; and when the
  semantics are also OBSERVABLE (table reservations expose lock
  modes through SQL), hold the same cells against the live system
  from both directions.
- **An ordering that holds by ACCIDENT is a bug that has not
  happened yet.** The first crash matrix satisfied data-before-btree
  because the btree page happened to number higher and the flush
  walks ascending; the edge became explicit only when the indexed
  workload existed to need it. When a property matters, find the
  code that GUARANTEES it - if only the data guarantees it, write
  the edge.
- **A safety property is a MATRIX, not a happy path.** Careful-write
  ordering was proved by materializing EVERY write prefix and letting
  the engine's validator judge each one - and by running the same
  matrix in reverse to watch it break (corruption, short files,
  phantom rows). If the careless order doesn't fail your gate, the
  gate cannot see the property. Distinguish the reference tool's
  ERROR classes from its WARNING classes: the benign orphan window is
  part of the correct design, not a defect to engineer away.
- **A compound verb is usually your own plans in a trench coat - and
  its REFUSAL is part of the surface.** UPDATE OR INSERT desugars to
  try-update, test row_count, store: the UPDATE and INSERT paths the
  server already runs, with every constraint applying for free. But
  when the table has no primary key and no MATCHING, the engine
  refuses AT PREPARE with "Primary key required on table X" - ship
  that specific vector, not the generic refusal. The generic error is
  technically a refusal and practically a lie: it hides the one line
  that tells the user what to fix, and the report that prompted this
  feature was exactly that hidden line.
- **Case mapping, week numbers, and NULL rules are where "obvious"
  implementations diverge.** When your answer and the engine's differ,
  THE ENGINE WINS — even when your gate asserted otherwise (then the
  gate is wrong; fix the gate).

## Authentication has oracles nobody can argue with — use them

- **The credential store is a differential.** A user manager wrote
  verifiers into a table with a password you know. Recompute them. If
  your bytes equal the engine's bytes for a user the ENGINE created,
  your hash chain, your bignum, your encoding and your padding are all
  right at once — no protocol, no server, no argument. This beat every
  other check available for SRP, including a working login.
- **A client and a server you both wrote will agree on your mistakes.**
  Loopback tests prove internal consistency and nothing else. Get a
  third implementation (here node-firebird's own SRP, with a different
  bignum and a different SHA) to reproduce your intermediate values from
  fixed inputs, and get the real server to accept your proof. Those two
  disagree with you in different ways, which is the point.
- **Hunt the one-in-N case; do not wait for it.** Firebird writes every
  number as minimal hex (`BigInteger::getText`), so a salt with a
  leading zero nibble is 63 characters, not 64 — one user in sixteen.
  A gate over ordinary users passes with the padding bug in place. So
  the gate re-rolls the credential until the engine hands out the
  awkward case, then asserts that ONLY the correct encoding reproduces
  what the engine stored. Same for proofs: compare by VALUE, because a
  proof whose top nibble is zero arrives one digit short and a string
  comparison rejects a valid login every sixteenth attach.
- **The comment says xor; the code raises to a power.** srp.cpp's
  `clientProof` is annotated `H(prime) ^ H(g)` and computes
  `n1.modPow(n2, prime)`. Convert the code.
- **Read what the hash is parameterized ON, not what the plugin is
  called.** `Srp256` uses SHA-256 for the PROOF only; the scramble, the
  user hash and the session key are SHA-1 in both plugins, so Arc4 is
  keyed by 20 bytes either way. "Upgrade it all to SHA-256" is a client
  that can never log in.
- **When the server cannot exercise a path, say so with its own error.**
  A default `AuthServer = Srp256` will not negotiate the SHA-1 variant.
  Record the engine's `isc_login_error` and pin that path another way;
  do not edit the server's configuration until the gate goes green —
  that is a gate testing itself.
- **Storage-layer tools reach places SQL is forbidden to reach.** The
  security database refuses remote attach by configuration and refuses
  a local attach while the server holds it. A page decoder needs
  neither. If your conversion has a file reader, it can read the
  engine's own credentials store — and OCTETS columns must be read as
  BYTES, or every byte above 0x7F becomes U+FFFD.

## When the engine ships a client for the thing you converted, use it

- **Put the vendor's tool on BOTH sides.** The Services API has
  `fbsvcmgr`; a wire protocol has the driver; a page format has `gstat`.
  Point the tool at the real server and compare with your decoder
  (proves you READ the format), then point it at your server and let it
  print your answers (proves you WRITE it, with nothing of yours in the
  reading path). Two directions, one tool, no self-agreement.
- **One buffer format is often several grammars.** Firebird's clumplet
  buffers look identical and are not: the same `[tag][len][data]` is a
  one-byte length in an attach SPB, a two-byte length in a query's send
  items, and no length at all in its receive items - with control tags
  standing bare inside one of them. Find the reader's `kind` parameter
  before you write a parser, and make the grammar an explicit argument
  so a caller cannot pick it by accident. Then test that the same bytes
  under a different grammar do NOT parse to the same items.
- **When nothing in the bytes distinguishes two encodings, that
  knowledge is code.** Service answers are length-prefixed strings or
  bare four-byte numbers, chosen per item, and the buffer does not say
  which; the engine knows because the writer chose a macro. Convert that
  choice as a table (`item_is_numeric`), because a decoder that guesses
  reads a length as data and mis-parses everything after it.
- **Off-by-one room checks are load-bearing; measure them live.** The
  engine's `INF_put_item` reserves `length + 4` and compares with `>=`,
  so the client's last buffer byte is never used. A `>` fits an answer
  the engine would have truncated. Do not read the boundary off the
  source alone - ask the live server with n+4 and n+5 bytes of buffer
  and let it tell you where it breaks. (And note when two paths in the
  same file disagree by a byte: the numeric check really does use `>`.
  Convert both as written instead of unifying them.)
- **A clean acknowledgement is a lie about work you did not do.** The
  service manager used to answer `op_service_start` - "back up this
  database" - with a clean response so the client would not desync. To
  the client that reads as "the backup finished". Refuse with the
  engine's own code (`isc_wish_list`), and gate it against the real
  server performing the same action, so the refusal is provably yours
  and not the request's.
- **How the engine says "not implemented" is itself a behaviour to
  convert.** For an unknown info item svc.cpp RAISES rather than
  skipping the item or writing a marker; skipping would make the client
  read the next item's bytes as this item's answer. Check that both
  servers refuse the same request with the same status code.
- **Let the gate re-capture its own byte pins.** Trace the buffers the
  vendor's tool actually sends and feed them back through your parser on
  every run. A frozen hex constant tests what the tool sent the day you
  copied it; a re-derived one tests what it sends today.

## The I/O floor is small, so cover all of it — and check the checks

- **Convert the ABSENCE of a feature too.** Firebird once had multi-file
  databases with a starting page per file; Firebird 6 does not, and its
  `seek_file` is a bare `page * page_size`. A converter working from an
  older book (or from memory) would subtract a base that no longer
  exists and place every page slightly wrong. Read the CURRENT struct:
  if there is no `fil_next` and no `fil_min_page`, the law is simpler
  than you remember.
- **Find the counter the engine publishes about itself.** For page
  counting it is `MON$DATABASE.MON$PAGES`; for page identity it is
  `RDB$PAGES`, which records a type per page. An engine that publishes
  its own accounting has handed you the differential — you do not need to
  invent one.
- **Every positional formula needs a shifted control.** "84 of 84 page
  types matched" means nothing until you also show that reading one page
  LATER matches 0 of 84. Without the control you have measured that the
  file is self-consistent, not that your arithmetic is right.
- **Integer division hides damage; check the remainder.** The engine
  computes pages as `size / page_size` and never asks whether it divided
  evenly. A healthy file always does, so testing the remainder catches a
  truncation the engine's own arithmetic would sail past — and a gate can
  prove that check works by truncating a copy half a page short.
- **A flag may be an OPEN MODE, not a policy.** "Forced writes" sounds
  like an fsync per write and is actually `O_DSYNC` at open time, decided
  from a bit on the header page. That is why turning it on reopens the
  file and flushes first. Follow the flag from where it is STORED to
  where it is USED, and gate the whole chain in one check: the stored
  bit, your derived mode, and what the vendor's tool prints.
- **Know which lock you are not taking.** The engine flocks a database
  file exclusively; fire-crab's readers take no lock, which is the only
  reason they can read a live database. That is a legitimate design
  choice, but write it down and test both halves - the lock is visible
  (BUSY) and the read still works - because the cost is real: a lock-free
  read can catch a page mid-write, and every gate that reads a live file
  then needs its own freshness signal.
- **A vacuous check is worse than a missing one.** A growth test whose
  inserts silently failed (a recursive CTE past the engine's 1024-level
  cap) reported three identical page counts as three passes. If a phase
  is supposed to CHANGE something, assert that it changed before you
  trust anything measured around it.

## Make the vendor's tool print your answer

- **The strongest differential is indistinguishability.** Not "my output
  looks right" but "the vendor's own tool, run two ways, prints the same
  bytes". If the tool can be pointed at a server (`gstat host/port:db`),
  implement the server side of what it asks for and diff its output
  against the local run. Nothing of yours is in the printing path, and
  the comparison is exact text.
- **Read stream conventions off the wire before writing them.** An output
  stream that returns "one line per call" sounds obvious and is not: this
  engine replaces the line's NEWLINE WITH A SPACE (so a blank line is a
  single space) and reserves the zero-length answer for end-of-stream.
  The natural guess — blank line = empty answer — collides with EOF and
  would hang a client. One `--raw` probe against the real server settles
  it; the source comment then confirms it.
- **A report's text has laws too.** `Flags` printing a different field
  than the one with that name (`pag_flags`, not `hdr_flags`), a LABEL
  printed unconditionally while its value is conditional (so the line
  dangles when empty), "dialect 1" meaning "no dialect information
  recorded" — none of these are visible from field names. Convert the
  printer, not your idea of the report, and keep a fixture for each
  awkward branch (a database with no attributes, in this case).
- **Name tables are part of the format.** The implementation triple in
  Firebird's header is three indexes into hardware/OS/compiler NAME
  LISTS. Dropping or reordering an entry renames every later platform, so
  the lists get converted verbatim, in order, with the source cited.
- **Convert the vendor's validation, with the vendor's error number.**
  "-h is incompatible with -d" is enforced by the SERVICE, and it arrives
  as a facility-coded number (gstat message 38 = 336920614), not an
  `isc_*` code. Refuse the same combinations with the same number, and
  run that check BEFORE your own capability check - a malformed request
  should get the engine's answer, not "not implemented".
- **When a refusal is the point, prove whose refusal it is.** "We refuse
  data-page statistics" is only meaningful beside "the engine performs
  them". Ask the real server for the SAME thing in the same gate - and
  make sure you are asking for what you think: asked together with `-h`,
  the engine refuses data-page statistics too, and a gate built on that
  combination would prove nothing.

## Shared memory is a format too — and its dumper is your oracle

- **If the vendor ships a dumper, the shared memory is checkable.** A lock
  table, a monitoring arena, an event table: none of them are documented
  formats, but a tool that prints one turns it into an exact-text
  differential. Decode the same bytes, print the same words.
- **Snapshot before comparing anything live.** Two reads of live shared
  memory are two different objects - counters move between them. Copy the
  file (or the region), then point BOTH readers at the copy. Without this
  the diff is noise and you will start "fixing" fields that were right.
- **Self-relative offsets, and the offset the dumper subtracts.** Shared
  structures cannot hold addresses, so every pointer is an offset from the
  region's base. When a queue node sits inside the block it links, the
  dumper prints the BLOCK - i.e. the stored offset MINUS the field's
  offset within the struct. Miss that and every number in your dump is
  consistently, invisibly wrong by a constant.
- **A field that is usually zero — or a queue that is usually EMPTY — is a
  field whose offset is untested.** Half a counter block reads 0 on a quiet
  system, and an empty queue prints "*empty*" with no offset in it to be
  wrong about, so bad offsets produce perfect dumps. This bit twice in two
  slices: three queue-field offsets were each shifted by one field and
  nothing noticed until a second transaction was made to BLOCK on the
  first, filling the pending queue. Deliberately create the state you are
  trying to observe — contention, activity, a full buffer — before
  trusting an offset, and prefer comparing the dumper's whole TEXT over
  the fields you thought to check.
- **A value transcribed from a numbered listing is an off-by-one waiting
  to happen.** An enum that starts at 1 makes each constant's value its
  POSITION, and copying from a listing whose line numbers start at the
  file's first line shifts everything. Mine shifted every lock series past
  the fifth, and it surfaced on exactly one line in 636 output lines —
  the one series whose key is printed in a split format. Convert enums by
  counting the enum, not the listing, and pick a check that exercises the
  branch each value selects.
- **Watch for statistics that are NEARLY right.** A hash distribution off
  by one chain, a maximum bucket length of 131072: those are the failures
  that survive review, because nothing looks broken. If a derived
  statistic is even slightly off, treat it as a wrong offset rather than
  rounding.
- **Bound every walk by the region's size, and stop on a self-loop.** A
  snapshot can catch a queue mid-update. A dumper that hangs on a torn
  structure is worse than one that prints a short queue.
- **Know which numbers belong to libc.** If a shared struct embeds a
  mutex or a condition variable, its later field offsets depend on the C
  library, and the region is not portable across builds. Isolate that
  assumption in one named constant instead of spreading it through
  offsets.

## A converted decision has a SHAPE, not just a choice

- **Watch for structure in the vendor's own output.** Firebird prints an
  inner-join chain flat (`JOIN (a, b, c)`) and an outer-join chain nested
  (`JOIN (JOIN (a, b), c)`). That is not formatting - it is the semantics
  showing through, because an outer join's two sides are one result that
  later joins cannot reorder into. If your model can only express the
  flat shape, you will produce plausible output for a query whose meaning
  you have not represented.
- **A dialect's syntactic sugar is usually a REWRITE - find it.** RIGHT
  JOIN is LEFT JOIN with the sides exchanged, and the engine performs
  that swap before planning, so the plan it prints drives the OTHER
  stream. The predicate needs no rewriting, which is what makes the swap
  sound. Convert the rewrite, not the surface.
- **When a construct means "both directions", say both.** A FULL join
  plans as the union of the two nested loops and the engine prints both
  halves. Printing one is a different answer that looks like a rounding
  difference.
- **"Right by accident" is a bug waiting for a new database.** Keeping
  the SQL order when both join keys are indexed matched the engine on
  every database the gate had - and disagreed on the first one built for
  a different purpose. When two arrangements are legal and the vendor
  decides by machinery you have not converted, refuse and name it;
  a refusal that is later lifted costs a slice, a wrong plan costs trust.
- **New fixtures are new coverage.** Both wrong answers here surfaced
  because a probe database happened to index both sides of a join - a
  shape none of the gate's four databases had. When you build a scratch
  database for an unrelated experiment, run the existing checks against
  it; that is nearly free and it is where the surprises live.
- **Symmetric fixtures hide asymmetric laws.** Those four databases all
  paired like with like - both sides of every join indexed the same way -
  so no check could ever ask which KIND of index the engine prefers to
  look through. One fixture with a primary key on one side and a plain
  index on the other exposed two wrong answers and an entire cost rule.
  When a decision has a "which of these two" shape, build a fixture where
  the two are DIFFERENT.
- **A cost model can be counter-intuitive on purpose - read the
  comment.** Firebird prices a UNIQUE lookup at a fixed 4 and a
  non-unique one at 3 + rows-it-names, "independent from a possibly
  outdated statistics". On an unanalysed database that makes the unique
  index the DEARER one, and the engine drives the stream you expected to
  be the inner. Converting the formula reproduced it; guessing the intent
  never would have.
- **A greedy search can quietly exclude the right answer.** The
  arrangement search placed remaining streams in index order, so a chain
  driven from its far end - which reaches its neighbours in the opposite
  direction - was discarded before it could be costed. If your search
  rejects candidates, log or test what it rejected: an arrangement never
  costed cannot lose on cost, and its absence looks exactly like a
  cost-model disagreement.

## When a statement both writes and returns, compare the table too

- **Run the same statement against both servers, then look at what
  CHANGED.** A DML with a RETURNING clause can hand back perfectly
  plausible rows while writing something the vendor's engine would not
  have written - or writing at all where the engine refuses. Comparing
  rows alone passes; comparing the TABLE afterwards is what fails. Build
  twin databases and diff both.
- **A vendor's grammar is narrower than its concepts.** `NEW.`/`OLD.`
  exist in Firebird's PSQL and NOT in its DSQL RETURNING clause, though
  every instinct says they should. Accepting a superset means accepting
  statements the engine rejects - and then performing their side effects.
  When in doubt, ask the engine: one probe settles it.
- **A statement type is a DISPATCH, not a label.** The client decides
  whether to fetch rows, fetch one row, or fetch nothing from the type
  the prepare announced. A DML-with-RETURNING is a cursor in Firebird 5
  and must be typed as a SELECT; type it as an UPDATE and a correct
  implementation returns nothing.
- **A materialised cursor must be CONSUMED.** Rows computed at execute
  and re-emitted on every fetch turn a driver's fetch-until-empty loop
  into duplicates - which looks like an off-by-one in the row count and
  is really a missing state transition.
- **Plan the statement WITHOUT its clause.** Stripping `RETURNING` and
  planning the plain DML keeps every default, constraint, index and
  trigger path identical to the unadorned statement's; the clause then
  only decides what to hand back. Anything else duplicates the write
  path and drifts from it.

## NULL is not a value and not an absence - it is a THIRD answer

- **A default is a LAW, not an accident.** "ORDER BY puts NULLs first"
  is wrong; "NULLs are LOW" is right, and it predicts that a descending
  key puts them last. State the rule that generates the behaviour, or
  the first descending query will disagree with you.
- **An explicit clause may not be the default's mirror.** `NULLS FIRST`
  states a position that does not flip with ASC/DESC, so the four
  combinations are four orders. Testing two of them proves nothing about
  the other two.
- **Desugar new predicates into shapes the rest of the pipeline already
  knows.** `IS NOT DISTINCT FROM` becomes an OR of comparisons and NULL
  tests at PARSE time, exactly as BETWEEN and IN do - so index matching,
  evaluation and refusal all keep working without a new case each.
- **A grammar that matched on token COUNTS stops working when items grow.**
  An ORDER BY item was `[name]`, `[name, dir]`, `[name, NULLS, pos]` - a
  tidy shape match until keys could be expressions, and `AMT + 1` is
  three tokens that look exactly like `ID NULLS LAST`. Strip the trailing
  CLAUSES first, then ask what the head is. Shape matches on token counts
  are a bet that the grammar will not grow.
- **Compute a sort key before sorting, not inside the comparator.** If
  the key can raise (an expression, a conversion), a comparator has
  nowhere to report it - and swallowing the error silently reorders the
  result. Decorate, then sort.
- **Write the three-valued rule out before coding it.** `A IS DISTINCT
  FROM v` is `A IS NULL OR A <> v`, NOT `NOT (A = v)`: under three-valued
  logic the negation of UNKNOWN is UNKNOWN and the row vanishes. Put the
  near-miss predicate in the gate NEXT to the real one, so the
  difference is a visible row count instead of a claim.

## The missing piece is often a PASS, not a feature

- **When one path answers a shape and another refuses it, compare the
  PIPELINES before writing any logic.** `WHERE ID IN (SELECT ...)` worked
  in SELECT and failed in UPDATE - not because the predicate was
  unimplemented, but because the DML planner tokenized the WHERE directly
  while the SELECT planner ran a subquery-lifting pass first. Moving the
  pass, not the logic, brought IN, NOT IN and the scalar forms in at
  once.
- **A statement that returns nothing needs the STATE as its assertion.**
  A DML's reply is identical whether its filter chose the right rows or
  the wrong ones. Compare the tables after every statement - and compare
  the OTHER table too, to show it was only read.

- **Two implementations of one thing will differ; delete one.** A scalar
  aggregate had a prepare-time i64 fold of its own beside the group
  machinery's. The narrow one refused AVG and could not have carried a
  NUMERIC's scale - so the same expression answered in a SELECT list and
  refused in a subquery. A scalar aggregate IS one group of one item;
  building that and calling the existing code brought AVG, text MIN/MAX,
  COUNT(DISTINCT) and expression arguments in together.
- **Refuse in every position or answer in every position.** If the
  planner refuses `SELECT AVG(D) FROM T`, a subquery must refuse
  `(SELECT AVG(D) FROM T)` too. Legal in one place and illegal in
  another is a bug report waiting to be filed, and the cheapest guard is
  a single gate check that asserts BOTH refusals at once, so they cannot
  drift.
- **`continue` on an unrecognized value is a silent wrong answer.** The
  exact fold skipped anything that was not an integer or a scaled
  numeric - which meant a DOUBLE column contributed NOTHING and AVG
  answered NULL over a table full of numbers. Skipping is only safe for
  values you have decided to skip (NULL); everything else must widen the
  fold or refuse the statement.
- **A value nobody sees still decides the answer.** A subquery's
  aggregate never appears in a row - a wrong one just returns a
  different SET of rows, with no error and a perfectly plausible reply.
  Build the fixture so the right value and the likely wrong one pick
  different rows (put a row BETWEEN the truncated and the rounded
  average, and between the NULL-ignored and NULL-counted one), or the
  gate proves only that the query ran.
- **NULL and 0 are different empty answers.** Over no rows, MIN/MAX/SUM/
  AVG are NULL (so a comparison is UNKNOWN and selects nothing) while
  COUNT is 0 (so `> 0` selects nearly everything). One "the aggregate
  found nothing" branch gets one of the two backwards.

- **A refusal on the SIMPLEST shape means the route is missing, not the
  rule.** `WHERE D IS NULL` refused on a server that already sorted by
  D and extracted its year. Nothing about NULL tests was unimplemented -
  the predicate resolver classified columns through a function that
  answers Int or Text and nothing else, so every temporal column fell
  out. When a trivial case fails and hard ones pass, look for the
  classifier, not the logic.
- **A LAST-RESORT comparison is where wrong answers hide.** Comparing
  two values by their RENDERED TEXT is a reasonable fallback and a trap:
  ISO date text orders like dates, so the comparisons LOOKED right while
  `D = '2021-6-15'` (the same date, a different string) answered false
  and `D > 'garbage'` returned rows where the engine raises. Convert at
  PREPARE and refuse what will not convert; a fallback that can answer
  anything will answer everything.
- **Half an implementation must refuse, not approximate.** The engine
  promotes a TIME to a TIMESTAMP using the CURRENT DATE. Not doing that
  is fine; text-comparing the two instead is not, because it answers
  every row with no error. Refuse the shape and PIN THE REFUSAL in the
  gate, so it stays a refusal instead of drifting into a wrong answer.
- **A gate's refusal list is a claim with a shelf life.** One entry in
  the date-math gate asserted that a temporal comparison RAISED. It was
  true when written and became a false claim the moment this slice
  landed - and it failed loudly, which is the good outcome. Write
  refusals as `both servers error` rather than `we error` where you
  can, and expect to promote them to comparisons later.

- **Keep EXACT and APPROXIMATE numerics in different types.** They are
  both "numbers" and they answer differently: an exact AVG truncates at
  the source's scale, an approximate one divides in f64. One shared type
  makes one of the two wrong in every fold, and the wrongness is
  plausible - a value, not an error.
- **Types with no decomposition find your fallback.** The exact
  comparison asks a value for `(raw, scale)`; an f64 has none, so every
  mixed pair fell past it into a rendered-text compare. Ask what happens
  to a value your fast path DECLINES, because that is where the last
  resort lives - and a last resort that can compare anything will
  compare everything, including the pairs it gets wrong.
- **Pick fixture values where two plausible rules DISAGREE.** Under text
  ordering `"1.5" > "1"` is right and `"1.5" < "10"` is wrong. A gate
  with only the first case passes with the wrong implementation. Look
  for the input that splits the readings, and put it in.

- **A conversion is a rounding rule, and rounding rules differ on
  exactly one input.** Truncation, half-up and half-even all agree on
  12.54; they separate on 12.55 and on -12.55. Pick the value where they
  disagree, and put its NEGATIVE in too - half-away-from-zero and
  half-up are the same rule until the sign changes.
- **Printing a number is a law, not a detail.** The engine renders a
  DOUBLE at 16 significant digits with trailing zeros kept; Rust's
  default prints the shortest round-tripping form. Same value, different
  STRING - and the string is what a CAST to text and a concatenation
  both hand the client. Any type whose text form the language decides
  for you deserves a probed rule of its own.
- **If two widths PRINT differently, they are two types.** A FLOAT
  renders at 8 significant digits and a DOUBLE at 16, and 1.5 is
  exactly representable in both - so no examination of the VALUE can
  recover which one stored it. The decoder has to keep them apart even
  though every arithmetic path treats them identically.
- **When a gate says "skipping", that is a TODO with a date on it.** The
  row differential had been visibly skipping float columns for many
  increments because the Rust side could not render them. Un-skipping
  them is what found the FLOAT/DOUBLE digit difference. Read your own
  gates' skip lists when you touch the area they mention.
- **Prefer the oracle with the fewest layers.** The same rendering law
  was checkable through the wire (driver, describe, decode) or straight
  from the file against isql's text. The second found the bug, because
  nothing in between could absorb it.

- **When the TYPE is what changed, compare the TEXT.** Promoting an
  exact operand to approximate leaves the value alone - 11.75 either way
  - and a driver decodes both into the same number. The rendering is
  where the difference lives, so route the check through the engine's
  own printing rather than the driver's decode.
- **IEEE returns where the engine raises.** Floating-point division by
  zero and overflow produce infinities and NaNs in every language you
  will write this in, and an arithmetic exception in the engine. Letting
  the language decide gives you a plausible number in a result set the
  engine never returns - no exception, no diff in a value-only gate.
- **Two errors that share a SQLSTATE are still two errors.** The integer
  and floating divide-by-zero both report 22012 with different gds codes
  and different text. A gate that asks "did it fail?" passes with either
  one; ask which one.
- **A second lexer is a second grammar.** This server lexes numbers in
  two places - the expression parser and the predicate tokenizer. Teach
  only one about exponents and `1e3` becomes a DOUBLE in the select list
  and an integer in the WHERE, in the same statement. Any literal rule
  has to land in every lexer that can see it.

- **A parameter's DESCRIBE is a specification, not a label.** The
  client encodes from it. Announce the wrong type and you do not get a
  wrong answer - you get a wrongly encoded message, and the values that
  survive are the ones whose two encodings coincide. Test parameters by
  sending real values and comparing rows, never by reading the describe
  back.
- **Check a bound parameter against the same statement written out.**
  Both servers can agree with each other while the value lands in the
  wrong internal shape; the parameter form and the literal form running
  on YOUR server must select the same rows.
- **The input BLR is value-derived.** Drivers encode from the VALUE's
  language type, not from the descriptor you published - a JS Date
  arrives as a timestamp whether you asked for a DATE, a TIME or a
  TIMESTAMP. So the bind has to decide what a mismatched shape MEANS,
  and where the engine's rule for that pair is one you have not
  implemented, refuse. Converting it to the obvious thing answers a
  different set of rows with no error anywhere.

- **A type that is also a predicate needs both grammars.** BOOLEAN is
  the only one, and `WHERE B` is a complete clause meaning `B = TRUE`.
  Getting the desugaring right is what decides where the NULL rows go -
  in the bare form, under NOT, and in `IS NOT TRUE`, which is NOT the
  negation of `IS TRUE`.
- **A one-line grammar rule can un-parse everything else.** Making a
  bare column a leaf hit two traps in one commit: the existing
  end-of-SIDE test counts an operator as a boundary (so every `ID > 2`
  became `ID = TRUE`), and letting an EXPRESSION side qualify broke
  parenthesised arithmetic, whose inner group ends at `)`. Run the full
  unit suite after touching a parser, not just the new cases.
- **A fixed-expectation gate can assert what the ORACLE cannot do.** Two
  gates sent a boolean parameter their driver cannot encode and the
  engine itself rejects, and stayed red for dozens of increments while
  looking like our bug. A twin comparison would have shown both sides
  failing on day one. Where a gate must state an expectation, state what
  the ENGINE answers - and check it.
- **When a gate goes red, date it.** Rebuilding the tree at older
  commits (a throwaway `git worktree` and one `cargo build`) is minutes
  of work and turns "did I break this?" into a fact. Both of these
  turned out to predate the slice being checked.

- **Two grammars for one language will disagree.** A predicate parser
  and an expression parser that both exist will eventually be asked the
  same question - `B AND C` in a select list, `CASE WHEN B` in an
  expression - and each will answer for the shapes it knows. Give them
  ONE typing check (here `cmp_sides`) even while their parsers stay
  separate, or one of them will quietly answer what the other refuses.
- **Three-valued logic hides inside a WHERE clause.** False and unknown
  both mean "row excluded", so a predicate engine can be wrong about
  which one it computed for years. The moment a condition becomes a
  VALUE the difference is visible - and the Kleene rules (`FALSE AND
  UNKNOWN` is FALSE, `TRUE OR UNKNOWN` is TRUE) are exactly where a
  naive "any NULL operand makes NULL" implementation breaks. Build the
  fixture with one row for each half.
- **A total comparison function is a liability.** Three separate slices
  in this run found `value_cmp`'s rendered-text fallback quietly
  answering a comparison the type system had not yet learned to refuse -
  approximate against exact, temporal against text, text against
  boolean. A function that can compare anything will compare the pairs
  you have not thought about, and it will not tell you.

- **The shape you test first is the shape that works.** Aliases were
  honoured on expressions and dropped on plain columns for dozens of
  increments, because `SELECT A + B AS TOTAL` is what anyone writes when
  checking aliases. Enumerate the ITEM TYPES a clause accepts and check
  the feature against each, not against the one that comes to mind.
- **A name is not a value, and a gate that compares values will not see
  it.** A wrong alias produces correct rows under a key the client
  cannot find. Compare the describe - the keys, the types - separately
  from the data.
- **A whitespace split is a parser, and it will meet operators.** The
  bare trailing alias (`NAME X`) is a split on the last space, which
  happily turns `NOT B` into `NOT` aliased as `B`. Guard it on what the
  head ENDS with, and remember the literals that pass an
  identifier test: TRUE, FALSE, UNKNOWN, NULL.

- **A gate that cannot run is worse than no gate.** Five of these
  depended on a scratch database that existed in one workspace, so they
  failed identically forever and everyone learned to look past them.
  Build fixtures with a SCRIPT, committed beside the gate, and have the
  script ASSERT the properties the checks depend on - a fixture that
  quietly loses its dangling foreign key makes every anti-join check
  vacuous.
- **A fixture detail can impersonate a bug.** A NUMERIC column where the
  gate expected an INTEGER produced eleven diffs that all looked like
  join failures. It was masking a real routing gap - and only the
  differential could tell the two apart, because both sides of a
  self-comparison would have agreed.
- **Check a feature at every ENTRY POINT, not just the main one.** The
  predicate resolver learned NUMERIC, temporal, approximate and boolean
  columns over four increments. The JOIN resolver - a second, older copy
  of the same classification - learned none of them, and nothing noticed
  because its gate could not run.

- **When a second input needs the same fold, split the function, do not
  copy it.** Grouping over a join is grouping - the only difference is
  where the rows come from. Splitting the scan from the fold (and the
  item rules from both) meant the joined case inherited every rule the
  single-relation one had learned over a dozen increments, including the
  ones nobody remembers writing.
- **Ambiguity is the joined case's real difference.** Names, not
  semantics: a bare column that means one thing over one table means
  nothing over two. Carry BOTH spellings - bare where unambiguous,
  qualified always - and let the resolver refuse what it cannot place.
- **Write the reference query as the same QUESTION, not a convenient
  one.** Five checks in one gate failed because the reference ordered by
  a rendered COALESCE, or by an ordinal a single-column reference did
  not have, or selected two columns the driver keys by the same name.
  Every one looked like a server bug. If the reference has to be written
  differently, make the DIFFERENCE the thing you reason about.

- **Count what your gate actually ran.** A mistyped helper name is a
  shell "command not found" that leaves the failure flag alone, so the
  gate reports success having done less work than it claims. Eight
  checks disappeared from one gate that way and the run still passed.
  Track a counter and assert a floor.
- **A grammar rule that splits on whitespace must guard BOTH sides.**
  The bare trailing alias guarded keywords at the end of the head, so
  `NOT B` stayed whole - and read `END` as an alias in `CASE ... END`,
  because nothing checked the TAIL. Both ends of a split are the same
  question.

- **A special-cased sub-language will fall behind the general one.**
  The ON clause was a list of equality pairs over Int-or-Text columns
  while the WHERE clause learned four numeric families, three temporal
  ones and booleans. Resolving the ON with the WHERE's own code did not
  just add operators - it inherited every rule the other had learned,
  and deleted the NULL handling that had to be written twice.
- **A gate that fails EVERYWHERE at once is usually not a regression.**
  Both times it happened here the binary was stale: `cargo test` leaves
  `target/release/` untouched when the test file does not compile, so
  the gates exercised the previous build. Rebuild before you debug.

- **"The previous one" and "the sum so far" are the same number until
  there are three.** A join side's offset in the combined row was the
  FIRST side's width - correct for two tables, and for three it put the
  third table's columns on top of the second's. The symptom was that
  inner joins returned nothing while outer ones looked right, because
  padding hid the mismatch. Any accumulator written against the previous
  element has this bug waiting.
- **A list of two is not a list.** `left`/`right` fields, `[T; 2]`,
  `(a, b)` - each one is a decision that there will never be a third.
  Turning them into a fold made the chain's other rules (a later ON may
  name any earlier table; a kind applies to the accumulation) expressible
  at all.

- **Being MORE permissive is also a divergence.** Flattening a comma
  list let a later ON name a table from an earlier item, which the
  engine rejects outright. Accepting what the engine refuses means every
  answer to those queries is invented - and no gate that only compares
  ANSWERS will catch it, because there is nothing to compare against.
  Check the refusals too.
- **Scope is data, not structure.** The fix was one number per join step
  - the first side its condition may look at - rather than a different
  plan shape for comma lists. Rules about VISIBILITY usually want a
  range, not a special case.

- **"Hidden" is a flag, not a deletion.** A NATURAL join merges two
  columns into one, and removing the second from its side's column list
  looks right until a QUALIFIED name needs it back - and until something
  built its own view of the columns before the removal. A flag, read by
  each consumer that asks a different question, survives both.
- **A derived condition inherits the semantics of the operator it is
  built from.** The NULL rule for NATURAL JOIN needed no code: the
  condition is an equality, and `NULL = NULL` is UNKNOWN. When you find
  yourself writing a special case for NULLs in a derived predicate, check
  whether the operator already says it.

- **A conversion table is a list of what you knew when you wrote it.**
  The UPDATE SET path computed booleans and dates perfectly and then hit
  a match on value shapes that predated both, answering "expression type
  cannot be stored". Every place that maps YOUR value type to a wire or
  storage form is such a list - when a new family lands, grep for the
  ones that will silently refuse it, because they will not fail to
  compile.

- **A rewrite that is right for one table can be wrong for two, and the
  difference is usually about NULL PADDING.** Expanding a view is a
  textual rewrite: swap the name, AND the view's own WHERE into the outer
  one. Add a join and that second half is wrong whenever the view's side
  can be padded - a padded row is all NULLs, so the view's predicate in
  the outer WHERE deletes it and the outer join has quietly become an
  inner one. The predicate belongs to the ON when its side can be padded
  and to the WHERE when it cannot. Any rewrite that MOVES a predicate
  outward across a join has this bug available to it.

- **A fixture where the right and the wrong answer agree is not a
  fixture.** The above was invisible against a fixture whose every group
  either qualified or was empty: sixteen probes agreed with the engine
  while the placement was wrong. What made it visible was one row - a
  department whose ONLY member falls below the view's threshold, so it is
  padded through the view and present through the base table. Build the
  row that separates the two implementations before you trust the ones
  that pass.

- **An identifier's POSITION is part of its meaning.** Replacing a view's
  name with its base table's is a table-position substitution only: an
  unaliased view lends its name to the base table as an ALIAS, so
  `VEMP.DEPT_ID` in the ON must survive untouched. A blind
  search-and-replace produced `EMP VEMP.DEPT_ID`. A dot on either side of
  a word says it is a qualifier or a column, never a table - that one
  test is the whole difference between a rewrite and a corruption.

- **A refusal you cannot reach is a wrong answer.** A view is a relation
  with a relation id, a format, and no records - so an unexpanded view
  does not fail to resolve, it scans its empty storage and answers ZERO
  ROWS. The guard existed and checked the first table of the FROM,
  because that is where a view could appear when it was written; a view
  as the second side of a join walked straight past it and answered
  plausible numbers. When you extend WHERE a construct may appear, the
  guards that mention it are part of the construct.

- **A readiness probe is not an identity check.** Every differential here
  waited for its server with `nc -z <port>`, which answers "something is
  listening" — and when the port was already taken, the something was the
  REFERENCE implementation. Eleven gates defaulted to the reference
  server's own port, so they started a server that died at bind and then
  compared the reference with itself. They passed, always. Whenever you
  wait for a service you just started, assert that the process you
  started is the one that answered (`kill -0 $pid`), because "the port
  responds" and "my server responds" differ exactly when it matters.

- **A gate that cannot fail is worse than a missing gate.** A missing one
  is a known hole. One that cannot fail is a SOURCE OF FALSE FINDINGS:
  these produced a written-down "pre-existing bug in the isql describe"
  that did not exist, complete with a stash-to-HEAD "confirmation" —
  which confirmed nothing, because the same wrong invocation was used
  both times. A reproduction is not a diagnosis. Before recording any
  divergence as a frontier, check that the gate that found it was
  measuring what its name says.

- **Check the checkers, and give that check teeth.** A guard that is
  present and does not work is indistinguishable from one that works. So
  the meta-gate here does not only scan for the guard's text: it starts a
  squatter on a real gate's port, runs that gate, and requires a non-zero
  exit and a spoken reason. Any invariant you enforce by convention
  across many files needs one executable check that the convention
  actually bites.

- **Fixtures rot in the same way binaries do.** Two gates in this
  codebase were written against scratch databases that lived in one
  workspace and nowhere else, and both were discovered by accident, years
  of increments apart. If a check needs data, the data needs a SCRIPT
  that builds it and asserts its own properties — otherwise the check
  degrades into a check of whether someone still has the file.

- **A rewrite that preserves VALUES can still change ANSWERS.** Expanding
  a view by substituting its columns for the base table's is correct in
  every row and wrong in every NAME, and the name is what a client keys
  its rows by. When you rewrite one query into another, the output
  CONTRACT - names, order, types, arity - is part of what has to survive,
  not just the data. Compare the metadata, not only the values: this
  increment's gate compares whole JSON objects for exactly that reason.

- **Build the input where the two failure modes disagree.** A view that
  SWAPS two column names separates "corrupted by a two-pass rewrite" from
  "correct values under the wrong names" - the first scrambles the data,
  the second leaves every value right and every label wrong. One fixture
  row distinguished two bugs that a hundred ordinary rows could not.

- **A capability learned on one path is not learned.** Qualified column
  names worked in joins for many increments while `SELECT E.ID FROM EMP E`
  refused, and a column ALIAS worked on a single relation while the join
  projection silently discarded it - after a dedicated alias increment,
  because that increment's gate used one table. When you add a feature,
  enumerate the PATHS that should have it, not the cases you happened to
  test.

- **A refusal has a shelf life, and so does the check that pins it.**
  Converting the renamed-view-in-a-join case turned a passing refusal
  check into a passing check of the wrong thing - it now had to be
  promoted to a comparison. Whenever you lift a refusal, grep the gates
  for the ones that assert it: a refusal test that keeps passing after
  the refusal is gone is worse than a deleted one.

- **Dead code that SHOULD be live is a bug waiting for its caller.** The
  expression-aware sort here existed, was correct, was unit-testable, and
  had NO CALLERS - three plans sorted with the field-only comparator
  instead. Nothing failed, because nothing yet produced an expression
  sort key. The day one did, the feature "worked" and sorted by the wrong
  column. When you add a capability, grep for the helper that already
  implements it before writing the wiring, and grep for the helper's
  CALLERS before trusting that it runs.

- **Turning a refusal into a wrong answer is the one direction you must
  never move.** Wiring an ORDER BY parser to accept expressions took ten
  minutes; without the sort fix it would have shipped a query that
  answers confidently in the wrong order. When you lift a refusal, the
  first probe should be one whose CORRECT answer differs from the answer
  the old code path would produce - if you cannot construct that probe,
  you cannot tell the two apart.

- **A field whose ZERO value means something else is a field you cannot
  default.** Here `offset == 0 && length != 0` was the encoding for "this
  is a computed column", so every freshly built descriptor - the natural
  way to describe a synthetic slot - claimed to be one, and every
  expression over it refused. Half the cases worked, because MIN and MAX
  describe their result by CLONING the source column's descriptor and
  inherit a real offset while SUM, AVG and COUNT build a fresh one. When
  a struct doubles as a tagged union through a sentinel value, building
  one from scratch is a decision, not a default.

- **When half the cases work, the difference between the halves IS the
  bug.** `MAX(A) - MIN(A)` answering while `SUM(A) + 1` refused looked
  like a parser problem and was a descriptor problem. Before theorising,
  enumerate what the working and failing sets have in common - the
  partition is usually a single line of code, and it is rarely the line
  you were editing.

- **A refusal encodes an assumption about the rest of the system.** "Do
  not sort by a computed column's placeholder field id" was correct while
  nothing evaluated expression sort keys; one increment later that was no
  longer true, and the refusal had become a missing feature. When you
  make a capability real, grep for the refusals that existed BECAUSE it
  was not.

- **A new feature often lands on an old bug.** Folding a constant
  subquery into the query text produces `SELECT ID, 3 FROM T` - and that
  refused, because `ident_ok` accepted "3" and a numeric literal was read
  as a column NAMED 3. The feature could not work until a years-old
  parsing gap did. When a rewrite emits text, the emitted text is a new
  INPUT to your parser: try it by hand before assuming the rewrite is the
  hard part.

- **A gap that shows for ONE of three sibling forms is the one nobody
  tests.** `SELECT NULL` and `SELECT 'x'` worked while `SELECT 3`
  refused, because each takes a different branch. When you find a
  refusal, enumerate its siblings and check them all - the working ones
  are what kept it invisible.

- **When you fold a value back into TEXT, the literal must round-trip.**
  A scaled numeric written without its decimal point multiplies the
  answer by a power of ten; a text value containing a quote ends the
  literal early. Rendering a value as source is a conversion like any
  other and deserves its own unit test, not a `to_string`.

- **"Absent" is not one value - it is a value per FUNCTION.** A lookup
  table keyed by a correlation column has no entry for a key with no
  rows, and what that answers depends on the aggregate: COUNT says 0,
  everything else says NULL. Defaulting the missing case to NULL is right
  three times in four and wrong on the most common one. Whenever you
  build a keyed cache of a computation, ask what the computation answers
  for the EMPTY input, not just for a missing key.

- **Put the two disagreeing cases in ONE statement.** Checking COUNT and
  MAX over the same empty key in separate queries lets a wrong default
  pass one and fail the other, which reads like a bug in that function. In
  one row, side by side, it reads as what it is.

- **A rewrite correct for one scope is not correct for a nested one.**
  The pass that strips a table's qualifiers rewrites the WHOLE statement,
  including the text inside a subquery - where the stripped name resolves
  against a DIFFERENT table. Any textual rewrite needs to know where its
  scope ends, and a nested query is where it ends.

- **Ask what the new construct IS before asking how to build it.** A CTE
  is a view that lives in the statement instead of the catalog; framed
  that way it cost one lookup function, and every capability the view
  expansion had already accumulated - aliases, renamed columns, joins,
  outer padding - arrived with it unwritten. The same feature framed as
  "a new kind of derived table" would have been a subsystem. When a
  construct feels large, look for the one you already have that it is a
  respelling of.

- **When a rewrite consumes a query, it must consume the WHOLE grammar of
  one.** `FIRST`, `SKIP` and `DISTINCT` sit between SELECT and the select
  list, so a clause splitter reading the projection sees them as part of
  it. Anything that takes a query apart and puts it back together has to
  know every position a keyword can occupy, not just the clauses it cares
  about.

- **A construct borrowed from another dialect may not have borrowed its
  SEMANTICS.** Firebird's DECODE looks like Oracle's and differs where it
  matters: Oracle's matches a NULL subject to a NULL search value, and
  Firebird's does not, because it compiles to a simple CASE whose
  comparison is `=`. Writing the desugar from the other dialect's
  documentation would have produced a wrong answer on exactly the rows
  people use DECODE for. Probe the construct in the system you are
  converting, not in the system it came from.

- **When you find a divergence your slice did not cause, say so in the
  gate rather than encoding around it silently.** A conditional's text
  result is CHAR of the widest branch and pads; this increment's gate
  uses equal-width branches and a header comment naming the law and the
  evidence. Choosing inputs that dodge a known bug is fine; choosing them
  without recording why turns the gate into a claim that the bug does not
  exist.

- **A unit test states what you BELIEVED; a differential states what the
  system DOES.** Three unit tests here asserted the unpadded result of a
  CASE and passed for many increments - they were the bug, written down
  and protected. When a differential and a unit test disagree, the unit
  test is the suspect, and the disagreement marks exactly where a law was
  never probed.

- **A type is a property of the VALUE, not of the place it is used.**
  Padding the select list made every projection check pass while
  `CASE ... END || 'X'` was still wrong: the conditional's type is
  CHAR(n) wherever it appears, so the padding belongs where the node is
  BUILT. Whenever a rule is applied at the point of USE, ask what happens
  when the value is used somewhere you did not enumerate.

- **Follow the value into other constructs when writing the gate.** The
  concatenation check is the one that caught the above, and it existed
  only because the gate was written to ask "and what does this value do
  next?" rather than to stop at the select list.

- **Some differences are invisible to your oracle - pick a different
  one.** A declared WIDTH is not a value, so a driver twin that returns
  strings cannot see it; fire-crab announced 32765 for every text
  function result and every value-comparing gate passed. The engine's own
  command-line tool lays its columns out from the describe, so it renders
  the difference as plain text: a 32765-wide column beside a 6-wide one.
  When a property does not reach your comparison, find the consumer that
  does surface it and compare THAT.

- **Do not turn one probe into a law.** REPLACE's result width is some
  function of the search and replacement lengths; one measurement fits
  many formulas, so it keeps the catch-all declaration and the gate says
  why. A rule you cannot state is a rule you should not encode - the
  refusal to guess is itself worth writing down, or the next person
  assumes it was checked.

- **A "known deviation" is a claim, and claims expire.** This codebase
  carried "fire-crab announces BIGINT for integer arithmetic where the
  engine announces INTEGER" as a documented difference, and a gate was
  softened around it. One probe showed the engine announces INT64 for
  arithmetic too - the deviation was in a handful of FUNCTIONS, not in
  arithmetic at all. Re-probe a recorded deviation before you design
  around it; the note may be older than the evidence.

- **A summary that can be EMPTY as well as ZERO hides failure.** A unit
  test here failed to compile, the release build succeeded anyway
  (`cfg(test)`), and the grep that counts "N passed" matched nothing and
  printed a blank - which reads like success. Any check that reports by
  counting must distinguish "counted zero" from "counted nothing", or it
  reports loudest when it is working least.

- **A textual rewrite must know where its SCOPE ends.** Stripping a
  table's qualifiers across a whole statement reached inside a subquery,
  where the outer table's name appears ON PURPOSE - and the stripped name
  either vanished or, worse, matched a different table's column. Every
  pass that rewrites SQL text needs an answer to "what happens when this
  text contains another query", and "nothing, it is copied" is a fine
  answer as long as it is written down.

- **Half a NULL law is not a NULL law.** The NOT IN / NOT EXISTS
  divergence has two halves - inner NULLs poisoning the list, and an
  OUTER NULL key that matches nothing and therefore satisfies NOT EXISTS.
  This codebase had closed the first, with a comment explaining it, and
  left the second. When you find yourself writing "the classic X/Y
  divergence" in a comment, enumerate BOTH directions before moving on.

- **A rule stated three times drifts twice.** "Which side of this
  equality belongs to the inner table" lived in three places here. Two
  learned that a table answers to its ALIAS as well as its name; the
  third did not, and it was the one that failed last - so the symptom
  arrived an increment after the cause looked fixed, in a different
  shape. When you extract a rule into a helper, grep for the OTHER copies
  in the same breath: the extraction is only half the fix.

- **When a capability works on three paths and fails on a fourth, look
  for a duplicated rule rather than a missing feature.** The correlation
  worked through IN, through a scalar comparison and in the select list,
  and failed through EXISTS. That pattern - most paths fine, one path
  not - almost never means the feature is missing; it means one caller
  has its own copy of something.

- **When you read a construct "from the other side", MIRROR the
  operator - and prove it with a fixture where the two answers differ.**
  `? < S` is `S > ?`, not `S < ?`. Both compile, both run, and only one
  is right; a fixture where the comparison happens to select the same
  rows either way cannot tell you which you wrote.

- **A construct that cannot be REWRITTEN is telling you the structure is
  missing, not the feature.** Views, CTEs and constant subqueries can all
  be answered by splicing text and re-planning, and that carried this
  server a very long way. `WITH RECURSIVE` cannot be, for a reason no
  amount of parser work fixes: the name it must resolve is ITS OWN, and
  there is no text to substitute for rows that exist only while the query
  runs. Once the planner built a TREE of row sources, the fixpoint was a
  dozen lines — and the hierarchy walk needed nothing at all, because a
  level's rows were already a legal side of an ordinary join. The lesson
  is the ordering: the shapes that refuse under rewriting are a map of
  which structure you have not built yet.

- **Ask what the engine REJECTS, not only what it answers.** A twin gate
  compares two answers, so it is blind by construction to a statement the
  engine refuses and you accept — the wrong-answer direction. Two of
  those turned up in one slice: a recursive branch naming the CTE twice
  (a fixpoint over a product, which bound both sides to the same rows and
  produced something entirely plausible), and `ORDER BY` inside a union
  branch. Neither was reasoned out; both were found by sending them.
  Assert the refusal AND assert that the engine rejects the same
  statement, or the gate will one day enforce a refusal the engine does
  not share.

- **A keyword is a declaration, not a fact.** `WITH RECURSIVE` on a body
  that never names itself is an ordinary CTE and must answer like one.
  Branching on the word rather than on the property refused a statement
  the engine answers — and the check that fixes it (count the references
  to the CTE in its recursive branch) is the same one the engine's own
  rule needs, since exactly one is legal.

- **When the emulation works, the structure is still missing — and the
  bill arrives as a list of refusals.** A view answered by rewriting the
  query against its base table passed hundreds of checks. What it could
  not do was not a list of missing features: a view whose body JOINed had
  no single table to rewrite to, a view under an outer join had nowhere
  to put its own WHERE that was right for both the matched and the padded
  rows, and a bare renamed column had no qualifier to say which side it
  came from. Those are all one thing said three ways. Replacing the
  rewriting with a nested row source deleted ~870 lines and answered all
  three, because *the filter is inside the inner plan, below the padding*
  is something a tree has by construction and text has to emulate.

- **Three planners doing the same thing is a design, not a duplication —
  until you write the third.** A derived table, a bound CTE and a view
  are the same question: plan a query whose FROM is a name standing for
  a row source. Merging them was not tidying; it moved capabilities
  between them for free, because each had learned something the others
  had not.

- **The mirror of a gate that cannot fail is a gate that cannot pass.**
  One gate here checked the wrong process id for liveness and exited
  before its second phase ran; twelve checks had never executed. Both
  failure modes report something untrue, and this one is easier to leave
  in place, because a red gate looks like outstanding work rather than a
  broken instrument. When a gate fails, find out WHICH check failed
  before you find out why.

- **An accelerator must name CANDIDATES, not answers.** An index in
  Firebird outlives the rows it describes: an UPDATE adds the new key
  and leaves the old, a DELETE removes nothing. So the retrieval fetches
  the records and re-applies the predicate that would have run over a
  full scan. Keep that shape and a stale entry costs a wasted fetch; drop
  it and the same entry is a wrong row. The rule generalises past
  indexes: whenever a faster path narrows a set, decide whether it is
  allowed to be *approximate in one direction only*, and build so the
  slow path still has the last word.

- **Then notice that the same rule applies to the WRITER.** Uniqueness
  here was decided from the index entries, which are exactly the thing
  that outlives its record — so deleting a row and re-inserting its key
  was refused against an engine that accepts it. One sentence, two
  places, and the second was found only because the first was being
  written down.

- **A wiring slice needs a gate a behaviour gate cannot be.** "The
  answers do not move" is necessary and says nothing about whether the
  new subsystem was called at all — *wired in but never used* passes
  every differential. Assert the path itself, in both directions (it
  must be taken where it should be and NOT taken where it should not),
  and then prove the assertion can fail: run a second server with the
  new path disabled and check that it reports nothing. A coverage check
  you have never seen fail is a coverage check you have not written.

- **When a faster path can only be wrong by MISSING something, scope it
  by what you can build exactly.** A refusal is visible; a missing row
  is not. So the first index slice keys only the types whose encoding
  was already gated byte-exact, and everything else scans — with the
  gate asserting the scan, so the boundary is a checked claim rather
  than a comment.

- **Ask the converted component ALL the ways it can say yes.** The
  optimizer here has three access verdicts, and the wiring accepted one
  of them. The result was that the most obvious shape in the language —
  a range over a primary key with an ORDER BY on it — was the single
  shape that would not use an index, while the same range on another
  column did. It looked like a bug in the range code; it was a missing
  arm in the caller's `match`. When a converted decision is an enum, the
  caller has to account for every variant, not the one the first test
  happened to produce.

- **A coverage check reads what the code SAYS, so silence looks like
  absence.** One retrieval path here chose an index correctly and never
  logged the choice; the gate duly reported a scan. Nothing was broken
  except the instrument, which is the failure that wastes the most time,
  because it points at the code that works. When you assert on a
  component's own reporting, make emitting the report part of the change
  that makes the decision.

- **Let the wiring inherit the converted component's limits rather than
  routing around them.** The optimizer here cannot parse a HAVING, so a
  statement with one scans — even though its WHERE is the same
  indexable predicate that drives an index without it. The tempting fix
  is to strip the clause before asking; the honest one is to accept the
  refusal and gate it, so the coverage check becomes the thing that
  notices when the component learns more.

- **Some optimisations cannot lose data — they can only lie about
  order.** Skipping a sort because a walk is already sorted returns the
  right rows in the wrong sequence, which no row-set comparison catches
  and no "did we lose anything" check notices. Before allowing one, write
  down what makes the cheap order TOTAL and identical to the requested
  one, then gate every way two rows can tie: a duplicate key, a NULL key,
  a second sort column, an explicit NULLS clause, the opposite direction.
  The list of exclusions is the deliverable as much as the optimisation.

- **A faster path that reads less beats one that merely saves work.**
  When the predicate's index and the ORDER BY's index differ, bounding
  the retrieval wins and the sort stays: reading a handful of records
  beats walking the whole relation to avoid sorting a handful. Both are
  "use the index", and choosing the wrong one is a pessimisation that
  every correctness gate passes.

- **"The slow path still decides" protects against wrong rows, not
  against wrong MULTIPLICITY.** An index entry here outlives the record
  version that wrote it, so a row whose key changed is named twice, and
  re-applying the predicate cannot help: the row matches both times. Any
  accelerator that maps one logical row to several physical entries owes
  you a second check — that the entry still describes the record it
  names — and it is separate from the filter, not a special case of it.

- **When every fixture shares a setting, that setting is untested.**
  Every scratch database in this project is created in the default
  character set, so a text index on a UTF8 column — the character set the
  project's own samples use — was never once exercised. The failure was
  not subtle when finally provoked: no INSERT and no UPDATE succeeded on
  such a table at all. Ask what your fixtures have in common, and build
  one that does not.

- **A refusal can be an outage.** The accept-list that skipped the UTF8
  index type did not narrow an optimisation; it made a resolver return
  None, and its caller turned that into "refuse the statement". A
  conservative default is only conservative where its caller treats it as
  one — trace what happens to your "I cannot do this safely" value before
  trusting it to be safe.

- **When a lookup becomes a RANGE, the bound that ends it is the whole
  job.** An equality on a compound index's leading segment is not a point
  — it is every key beginning with that prefix — and closing that band
  with an inclusive bound at the prefix returns only the rows whose
  remaining segments are all NULL. The rows are not refused, they are
  absent. Whenever a change turns "find this" into "find this range",
  write the boundary case into the fixture first: a row exactly at the
  bound, and a row just past it.

- **Adjacent operators can need different arithmetic, and that is a
  reason to ship one of them.** `<= v` over a prefix band ends at the
  successor of v's band; `< v` ends at that band's start. Implementing
  both together invites using one rule for two cases. Ship the operator
  whose rule you have measured, gate the others as scanning, and let the
  gate be what tells you when that changes.

- **The sharpest differential is your own binary with the feature
  switched off.** A flag that disables the new path costs a line, and it
  turns every "is this a bug in the new thing or a pre-existing
  difference?" argument into a two-line experiment. It was added here
  only to prove a coverage check could fail; it then localised four
  separate defects in minutes, because a disagreement between the
  feature-on and feature-off builds of the SAME binary is the feature's
  fault by construction.

- **A convenience iterator that skips holes is not an index.** Fetching
  "the nth item" from an iterator that filters out released slots
  silently returns a DIFFERENT item once a hole appears — not an error,
  not an absence, someone else's data. When a positional API and a
  filtered view live side by side, the position must come from the API
  that keeps the holes.

- **Fix the failure you reproduced, not the cause you guessed.** A
  delete-then-lookup failure had two plausible causes here, one page-
  level and one slot-level. I fixed the page-level one, the reproducer
  passed, and the slot-level one — the more serious, because it returned
  the WRONG row rather than none — survived until the full report
  arrived. A reproducer passing after a change is evidence about the
  reproducer, not about the diagnosis.

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
