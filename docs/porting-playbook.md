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
- **A field that is usually zero is a field whose offset is untested.**
  Half of a counter block reads 0 on a quiet system, so wrong offsets in
  it produce plausible dumps. Deliberately create activity (open
  attachments, take a reservation) before trusting an offset, and prefer
  comparing the dumper's whole TEXT over comparing the fields you thought
  to check.
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
