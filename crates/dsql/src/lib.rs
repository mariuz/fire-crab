//! SQL -> BLR: the conversion of the engine's `src/dsql/` - the
//! compiler that turns a SQL statement into the BLR the executor runs.
//!
//! THE ORACLE IS `RDB$VIEW_BLR`. When the ENGINE runs `CREATE VIEW v AS
//! <select>`, its own DSQL compiles the SELECT and stores the resulting
//! BLR verbatim in the catalog - so every byte this crate emits can be
//! compared against the engine's own output for the identical statement
//! (`qa/dsql-view-blr.sh`). No layout here is guessed: each was read
//! back from a probe view and pinned in the unit tests below.
//!
//! The first slice covers the single-relation SELECT shape a view
//! stores:
//!
//!   blr_version5,
//!   blr_rse, 1,
//!     blr_relation, <len>, '<TABLE>', <context 1>,
//!     [ blr_boolean, <boolean tree> ]
//!     blr_end,
//!   blr_eoc
//!
//! Probed laws (each a unit test and a gate check):
//!
//!   * the view's BLR is the RSE ALONE - the select list leaves no
//!     trace (`SELECT ID` and `SELECT ID, A` compile identically; the
//!     column mapping lives positionally in RDB$RELATION_FIELDS)
//!   * NOT is compiled AWAY where an inverse exists: `NOT (A > 5)`
//!     stores blr_leq, and De Morgan pushes through AND/OR
//!     (`NOT (x OR y)` stores blr_and of the negations); blr_not
//!     survives only over LIKE and MISSING
//!   * `NOT BETWEEN lo AND hi` expands to `blr_or(blr_lss lo,
//!     blr_gtr hi)` while plain BETWEEN stays blr_between
//!   * IS NULL is blr_missing; IS NOT NULL is blr_not(blr_missing)
//!   * an integer literal is blr_long scale 0, little-endian; a decimal
//!     literal keeps its written scale (12.50 -> scale -2, raw 1250);
//!     a string literal is blr_text2 with a 2-byte charset and a
//!     2-byte length (charset 0 in a NONE-charset database)
//!   * AND/OR chains nest LEFT-associatively
//!
//! Slice 2 (same oracle) added VALUE EXPRESSIONS (blr_add/subtract/
//! multiply/divide/negate/concatenate - a sign before a numeric
//! literal FOLDS into it, blr_negate survives only before fields),
//! IN lists (blr_in_list with a little-endian u16 count; NOT IN keeps
//! a real blr_not), and MULTI-STREAM RSEs: comma-FROM lists and INNER
//! JOIN ... ON (blr_join nesting like an rse, its ON clause a
//! boolean sub-clause), with aliases stored as blr_relation2 whose
//! alias text is the UPPERCASED name in DOUBLE QUOTES (probed:
//! `FROM T x` stores alias "X", quotes included). Fields carry their
//! stream's context id; in a multi-stream statement every field must
//! be QUALIFIED (the engine resolves bare names through the catalog;
//! this catalog-free slice refuses them rather than guess a context).
//!
//! Slice 3 (same oracle) added OUTER JOINS (blr_join_type after the
//! streams, before the ON boolean: 1=LEFT, 2=RIGHT, 3=FULL - absent
//! for INNER; `LEFT OUTER JOIN` compiles byte-identical to `LEFT
//! JOIN`), JOIN CHAINS (each ON binds LEFT, so the second join's node
//! holds the first join's node as its first stream slot - the chain
//! nests left, and a type byte sits only on its own node), INT64
//! LITERALS (blr_int64: dtype 0x10, one scale byte, 8 little-endian
//! bytes - the sign still folds in), and the first BUILT-IN FUNCTIONS:
//! blr_upcase/blr_lowcase (one operand), blr_strlen with a length-type
//! byte (CHAR_LENGTH=1, OCTET_LENGTH=2), blr_substring whose start is
//! 0-BASED and compiled as `blr_subtract(<from>, 1)` UNFOLDED (probed:
//! `FROM 1` stores subtract(1,1), not literal 0), and blr_trim with a
//! where byte (0=BOTH, 1=LEADING, 2=TRAILING) and a spec byte (0=trim
//! spaces, 1=an explicit <what> operand follows; a bare
//! `TRIM('a' FROM s)` is BOTH). An unknown name followed by `(` is a
//! UDF or an unconverted built-in and REFUSES - it must never fall
//! back to being read as a field.
//!
//! Slice 4 (same oracle) added CAST (blr_cast + a dsc whose layouts
//! were probed target by target: NUMERIC(p<=4) is SHORT but
//! DECIMAL(p<=9) is ALWAYS LONG, p 10..=18 is INT64, texts carry a
//! charset word and a length word, temporals are a bare dtype) and
//! the CONDITIONALS with their two compiled shapes: the searched CASE
//! and IIF (byte-identical sugar) are ONE blr_cast over a blr_value_if
//! chain - each further WHEN nests in the ELSE slot, a missing ELSE is
//! blr_null - where the cast's descriptor is the branches' UNIFIED
//! type; the simple CASE is blr_decode (count byte, comparands, count
//! byte, results; the ELSE is one extra result) and COALESCE is
//! blr_coalesce (count byte, values), both WITHOUT a cast wrapper.
//! NULLIF(a, b) is cast(value_if(a = b, NULL, a)) - its dsc comes from
//! the BRANCHES (NULL and a), never from b. The unification law,
//! probed: NULL branches are ignored, text branches take blr_text2 at
//! the MAX length, exact numerics take MAX integer digits + MIN scale
//! and the dtype that FITS the total (<=4 short, <=9 long, else
//! int64) - so long(0) united with long(-1) WIDENS to int64. A FIELD
//! branch under a cast wrapper refuses: its descriptor lives in the
//! catalog, and this compiler never guesses one.

/// The BLR bytes this slice emits, every constant read back from the
/// engine's own stored view BLR (see the module doc).
mod blr {
    pub const VERSION5: u8 = 0x05;
    pub const RSE: u8 = 0x43;
    /// the relation stream verb the engine stores for a view's table
    /// (counted name + context id)
    pub const RELATION: u8 = 0x4A;
    /// the rse sub-clause introducing the WHERE tree
    pub const BOOLEAN: u8 = 0x47;
    pub const END: u8 = 0xFF;
    pub const EOC: u8 = 0x4C;
    pub const FIELD: u8 = 0x17;
    pub const LITERAL: u8 = 0x15;
    /// literal dtypes
    pub const LONG: u8 = 0x08;
    pub const TEXT2: u8 = 0x0F;
    /// booleans
    pub const AND: u8 = 0x3A;
    pub const OR: u8 = 0x39;
    pub const NOT: u8 = 0x3B;
    pub const MISSING: u8 = 0x3D;
    pub const BETWEEN: u8 = 0x38;
    pub const LIKE: u8 = 0x3F;
    pub const ADD: u8 = 0x22;
    pub const SUBTRACT: u8 = 0x23;
    pub const MULTIPLY: u8 = 0x24;
    pub const DIVIDE: u8 = 0x25;
    pub const NEGATE: u8 = 0x26;
    pub const CONCATENATE: u8 = 0x27;
    /// FB5+'s dedicated IN-list verb: value, u16 count, values
    pub const IN_LIST: u8 = 0x40;
    /// an explicit join: stream count, streams, sub-clauses, blr_end -
    /// nested inside the rse like a stream
    pub const JOIN: u8 = 0x77;
    /// a relation WITH AN ALIAS: counted name, counted alias (the
    /// alias travels UPPERCASED IN DOUBLE QUOTES - probed), context
    pub const RELATION2: u8 = 0x92;
    /// an ARRAY element: blr_index <array value> <u8 count> <subscripts>
    pub const INDEX: u8 = 0x6B;
    /// a SELECTABLE PROCEDURE as a stream: blr_procedure <counted name>
    /// <ctx> <u16 input count> <inputs>
    pub const PROCEDURE: u8 = 0x7C;
    /// the same WITH AN ALIAS: blr_procedure2 <counted name> <counted
    /// quoted alias> <ctx> <u16 input count> <inputs> (measured: `FROM
    /// PS(1) P` is `85 02 "PS" 03 "\"P\"" 00 01 00 ..`)
    pub const PROCEDURE2: u8 = 0x85;
    /// join-type sub-clause inside blr_join: absent for INNER,
    /// 1=LEFT, 2=RIGHT, 3=FULL (probed)
    pub const JOIN_TYPE: u8 = 0x50;
    /// 64-bit literal dtype: one scale byte, 8 little-endian bytes
    pub const INT64: u8 = 0x10;
    pub const UPCASE: u8 = 0x67;
    pub const LOWCASE: u8 = 0xB5;
    /// blr_strlen with a length-type byte: CHAR_LENGTH=1,
    /// OCTET_LENGTH=2 (probed)
    pub const STRLEN: u8 = 0xB6;
    /// blr_substring: source, 0-BASED start, length - the engine
    /// compiles `FROM 1` as blr_subtract(literal 1, literal 1),
    /// UNFOLDED (probed)
    pub const SUBSTRING: u8 = 0x28;
    /// blr_trim: where byte (0=BOTH, 1=LEADING, 2=TRAILING), spec
    /// byte (0=spaces, 1=an explicit <what> operand follows), [what],
    /// source (probed)
    pub const TRIM: u8 = 0xB7;
    /// blr_cast: a dsc (dtype byte + its parameters), then the value
    pub const CAST: u8 = 0x83;
    /// blr_value_if: condition, then-value, else-value; the DSQL wraps
    /// the OUTERMOST value_if of a searched CASE / IIF / NULLIF in a
    /// blr_cast to the branches' UNIFIED descriptor (probed)
    pub const VALUE_IF: u8 = 0x69;
    /// blr_decode - the simple CASE: value, count byte, comparands,
    /// count byte, results (the ELSE is one extra result; without it
    /// the result count simply equals the comparand count). No cast
    /// wrapper (probed)
    pub const DECODE: u8 = 0xCB;
    /// blr_coalesce: count byte, values. No cast wrapper (probed)
    pub const COALESCE: u8 = 0xCA;
    /// blr_null - also the missing ELSE of a searched CASE
    pub const NULL: u8 = 0x2D;
    /// dsc dtypes seen only inside blr_cast
    pub const SHORT: u8 = 0x07;
    pub const VARYING2: u8 = 0x26;
    pub const DATE: u8 = 0x0C;
    pub const TIME: u8 = 0x0D;
    pub const TIMESTAMP: u8 = 0x23;
    /// blr_any - EXISTS: the verb and ONE rse, the subquery's WHERE
    /// as that rse's boolean (probed; the subquery's select list
    /// leaves no trace, like a view's)
    pub const ANY: u8 = 0x3C;
    /// blr_unique - SINGULAR, same single-rse shape as EXISTS
    pub const UNIQUE: u8 = 0x3E;
    /// blr_ansi_any / blr_ansi_all - IN (SELECT ...) and quantified
    /// comparisons: the verb, an rse whose SINGLE STREAM IS ANOTHER
    /// RSE (the subquery, carrying its own WHERE), then the
    /// quantified comparison as the OUTER rse's boolean (probed)
    pub const ANSI_ANY: u8 = 0x97;
    pub const ANSI_ALL: u8 = 0x9E;
    /// DISTINCT - an rse sub-clause after the boolean: count byte,
    /// then the SELECT LIST's values (the one place the list leaves
    /// a trace - probed)
    pub const PROJECT: u8 = 0x45;
    /// a scalar subselect as a value: blr_via(blr_singular(rse),
    /// selected value, blr_null) (probed)
    pub const VIA: u8 = 0x2B;
    pub const SINGULAR: u8 = 0x7F;
    /// blr_union as an rse STREAM: context byte, branch count, then
    /// per branch an rse and a blr_map. Same byte as EOC - position
    /// disambiguates (probed)
    pub const UNION: u8 = 0x4C;
    /// blr_map: u16 count, then (u16 field number, value) pairs
    pub const MAP: u8 = 0x4D;
    /// blr_fid: context byte, u16 field id - how the distinct-union's
    /// project addresses the union's OWN columns (probed)
    pub const FID: u8 = 0x18;
    /// the procedure-body wrapper verbs (probed via the engine's own
    /// disassembly of RDB$PROCEDURE_BLR)
    pub const BEGIN: u8 = 0x02;
    /// blr_message: message number byte, u16 count, dscs - one dsc
    /// per output parameter EACH FOLLOWED BY a null-flag blr_short,
    /// then one final blr_short: the EOF flag
    pub const MESSAGE: u8 = 0x04;
    /// blr_declare: u16 variable number, dsc
    pub const DECLARE: u8 = 0x03;
    pub const ASSIGNMENT: u8 = 0x01;
    /// blr_variable: u16 number
    pub const VARIABLE: u8 = 0x1A;
    pub const STALL: u8 = 0x9B;
    /// blr_label: label number byte, statement
    pub const LABEL: u8 = 0x11;
    pub const FOR: u8 = 0x07;
    /// blr_send: message number byte, statement
    pub const SEND: u8 = 0x0E;
    /// blr_parameter: message byte, u16 parameter
    pub const PARAMETER: u8 = 0x19;
    /// blr_parameter2: message byte, u16 parameter, u16 null-flag
    /// parameter
    pub const PARAMETER2: u8 = 0x29;
    /// ORDER BY: an rse sub-clause after the boolean - count byte,
    /// then per key blr_ascending/blr_descending and the value
    pub const SORT: u8 = 0x46;
    pub const ASCENDING: u8 = 0x48;
    pub const DESCENDING: u8 = 0x49;
    /// the aggregate STREAM: its own context byte, a source rse,
    /// blr_group_by (count byte + key values - present even with 0
    /// keys), and a blr_map whose entries are the group keys and the
    /// aggregate functions in SELECT-LIST order; HAVING is the outer
    /// rse's boolean over blr_fid refs, ORDER BY its sort (probed)
    pub const AGGREGATE: u8 = 0x4F;
    pub const GROUP_BY: u8 = 0x4E;
    pub const AGG_COUNT: u8 = 0x53;
    pub const AGG_MAX: u8 = 0x54;
    pub const AGG_MIN: u8 = 0x55;
    pub const AGG_TOTAL: u8 = 0x56;
    pub const AGG_AVERAGE: u8 = 0x57;
    /// COUNT(<value>) - counts non-null values
    pub const AGG_COUNT2: u8 = 0x5D;
    /// blr_receive: message number byte, one statement - wraps the
    /// whole loop when the procedure has INPUT parameters (probed)
    pub const RECEIVE: u8 = 0x0C;
    /// FIRST <n> / SKIP <n>: rse sub-clauses between the streams and
    /// the boolean, each carrying one value (probed)
    pub const FIRST: u8 = 0x44;
    pub const SKIP: u8 = 0xAF;
    /// the DISTINCT aggregate verbs; MIN/MAX(DISTINCT) FOLD to the
    /// plain verbs (probed)
    pub const AGG_COUNT_DISTINCT: u8 = 0x5E;
    pub const AGG_TOTAL_DISTINCT: u8 = 0x5F;
    pub const AGG_AVERAGE_DISTINCT: u8 = 0x60;
    /// blr_if: condition, then-statement, else-statement - a MISSING
    /// else is a bare blr_end byte in the else slot (probed)
    pub const IF: u8 = 0x08;
    /// INSERT: blr_store(relation, statement) - the assignments in
    /// column-list order, no FOR wrapper (probed)
    pub const STORE: u8 = 0x0F;
    /// UPDATE: blr_modify(org context, new context, statement) -
    /// inside a blr_for; the NEW context is allocated BEFORE the
    /// rse's stream context (probed: modify 3,2 with the rse at 3)
    pub const MODIFY: u8 = 0x0A;
    /// DELETE: blr_erase(context), inside a blr_for (probed)
    pub const ERASE: u8 = 0x05;
    /// blr_marks: count byte, mark byte - the DSQL stamps its
    /// UPDATE/DELETE loops with marks(1, 4) (probed)
    pub const MARKS: u8 = 0xD9;
    /// WHILE: blr_label N, blr_loop, begin, blr_if(cond, body,
    /// blr_leave N), end (probed)
    pub const LOOP: u8 = 0x09;
    pub const LEAVE: u8 = 0x12;
    /// blr_continue_loop: label byte - `CONTINUE` to the loop's top (probed)
    pub const CONTINUE_LOOP: u8 = 197;
    /// INSERTING/UPDATING/DELETING: eql(blr_internal_info(literal 6),
    /// literal 1/2/3) (probed)
    pub const INTERNAL_INFO: u8 = 0xB1;
    /// EXECUTE PROCEDURE: counted name, u16 input count + values,
    /// u16 output count + variable targets (probed)
    pub const EXEC_PROC: u8 = 0x78;
    /// EXCEPTION <name>: blr_abort, 2, counted name (probed)
    pub const ABORT: u8 = 0x80;
    /// GEN_ID(seq, inc): counted name + increment value; NEXT VALUE
    /// FOR seq is blr_gen_id2 with the name alone (probed)
    pub const GEN_ID: u8 = 0x65;
    pub const GEN_ID2: u8 = 0xD2;
    /// POST_EVENT: blr_post + the event-name value (probed)
    pub const POST: u8 = 0x14;
    /// a BEGIN..END carrying WHEN handlers: blr_block, a begin with
    /// the guarded statements, then per handler blr_error_handler +
    /// u16 code count + codes + the handler statement, then blr_end
    /// closing the block (probed)
    pub const BLOCK: u8 = 0x81;
    pub const ERROR_HANDLER: u8 = 0x82;
    /// handler codes: WHEN ANY = blr_default_code; WHEN EXCEPTION =
    /// 9, 0, counted name; WHEN GDSCODE = 0, counted UPPERCASED name
    pub const DEFAULT_CODE: u8 = 0x04;
    pub const EXCEPTION_CODE: u8 = 0x09;
    pub const GDS_CODE: u8 = 0x00;
    /// the niladic context functions (probed in DEFAULT clauses)
    pub const CURRENT_DATE: u8 = 0xA0;
    pub const CURRENT_TIMESTAMP: u8 = 0xA1;
    pub const CURRENT_TIME: u8 = 0xA2;
    /// blr_equiv - null-safe equality, MATCHING's comparator (probed)
    pub const EQUIV: u8 = 0x2E;
    /// IN AUTONOMOUS TRANSACTION DO: blr_auto_trans, a sub-code byte
    /// (0), the statement (probed)
    pub const AUTO_TRANS: u8 = 0xBB;
    /// DECLARE ... CURSOR: blr_dcl_cursor, u16 number, the rse (whose
    /// relation2 alias carries the CURSOR NAME like a derived
    /// table's), u16 output count, blr_derived_expr-wrapped outputs
    pub const DCL_CURSOR: u8 = 0xA6;
    /// blr_derived_expr: count byte, stream byte, value (probed
    /// wrapping cursor outputs)
    pub const DERIVED_EXPR: u8 = 0xBF;
    /// OPEN/CLOSE/FETCH: blr_cursor_stmt, sub-verb (0=open, 1=close,
    /// 2=fetch + into-assignments), u16 cursor number (probed)
    pub const CURSOR_STMT: u8 = 0xA7;
    /// WHEN SQLCODE <n>: handler code 1 + i16 little-endian (probed)
    pub const SQLCODE_CODE: u8 = 0x01;
    /// WHEN SQLSTATE '<s>': handler code 8 + counted string (probed)
    pub const SQLSTATE_CODE: u8 = 0x08;
    /// blr_dbkey + context byte - MERGE's matched test is
    /// missing(dbkey(target)) on the left-joined row (probed)
    pub const DBKEY: u8 = 0x16;
    /// DECLARE ... SCROLL CURSOR: blr_scrollable before the
    /// dcl_cursor's rse (probed)
    pub const SCROLLABLE: u8 = 0x6D;
    /// INSERT ... RETURNING: blr_store2 - relation, assigns begin,
    /// returning-assigns begin (probed)
    pub const STORE2: u8 = 0x13;
    /// UPDATE ... RETURNING: blr_modify2 - org, new, set begin,
    /// returning begin - under a blr_singular rse (probed)
    pub const MODIFY2: u8 = 0xAC;
    /// EXECUTE STATEMENT '<sql>'; - blr_exec_sql + the sql value
    pub const EXEC_SQL: u8 = 0xB0;
    /// [FOR] EXECUTE STATEMENT INTO: blr_exec_into, u16 out-count,
    /// sql, flag (1 = singleton; 0 = loop + the DO statement),
    /// then the variables (probed both flags)
    pub const EXEC_INTO: u8 = 0xA4;
    /// the PARAMETERIZED forms: blr_exec_stmt + tag-prefixed
    /// clauses - 1 in-count, 2 out-count, 3 sql, 4 the loop's DO
    /// statement, 11 input values, 13 output variables, blr_end
    /// (probed; tag order fixed)
    pub const EXEC_STMT: u8 = 0xBD;
    /// WITH LOCK: blr_writelock, an rse sub-clause between the
    /// stream and the boolean (probed)
    pub const WRITELOCK: u8 = 0xB3;
    /// DECLARE PROCEDURE: blr_subproc_decl - counted name, type 0
    /// (PSQL), selectable flag, u16-counted param-name lists (each
    /// name + default flag 0), u32 blob length, the WHOLE inner
    /// body's BLR (probed)
    pub const SUBPROC_DECL: u8 = 0xCD;
    /// DECLARE FUNCTION: blr_subfunc_decl - same frame; the flag
    /// byte carries deterministic(1)/aggregate(2) and the single
    /// return slot is an UNNAMED output param (probed)
    pub const SUBFUNC_DECL: u8 = 0xCF;
    /// EXECUTE PROCEDURE on a subroutine: blr_invoke_procedure with
    /// sub-tags - 1 (id: 4 sub, 3 counted name, end), 3 u16-counted
    /// input values, 5 u16-counted output variables, blr_end
    pub const INVOKE_PROCEDURE: u8 = 0xE1;
    /// a sub-function call site - blr_invoke_function, same id
    /// clause, 3 u16-counted argument values, blr_end (probed)
    pub const INVOKE_FUNCTION: u8 = 0xE0;
    /// window functions: blr_window wraps the inner rse (its WHERE
    /// inside), then a count of windows, each blr_partition_by -
    /// context, partition keys (source fields then REMAPPED fids
    /// into the window's own map), a sort clause, the map - and ONE
    /// trailing end (all probed)
    pub const WINDOW: u8 = 0xC3;
    pub const PARTITION_BY: u8 = 0xC4;
    /// named window functions (ROW_NUMBER, RANK, ...):
    /// blr_agg_function - counted name + an argument-count byte
    pub const AGG_FUNCTION: u8 = 0xC7;
    /// a FRAMED window takes the v4 verb: blr_window_win with
    /// subcodes - 1 partition, 2 order, 3 map, 4 extent unit
    /// (RANGE 0 / ROWS 1), 5 frame bound (frame#, bound: 0
    /// preceding / 1 following / 2 current row), 6 frame value -
    /// and its OWN blr_end (probed)
    pub const WINDOW_WIN: u8 = 0xD3;
    /// packaged calls: blr_exec_proc2 - counted package, counted
    /// name, u16 in-count + values, u16 out-count + variables; and
    /// blr_function2 - package, name, a count BYTE, the arguments
    /// (both probed)
    pub const EXEC_PROC2: u8 = 0xC1;
    pub const FUNCTION: u8 = 0x64;
    pub const FUNCTION2: u8 = 0xC2;
    /// PLAN (tbl NATURAL): blr_plan, blr_retrieve, the stream
    /// re-emitted, blr_sequential - last in the rse (probed)
    pub const PLAN: u8 = 0x8B;
    pub const RETRIEVE: u8 = 0x91;
    pub const SEQUENTIAL: u8 = 0x8E;
    /// PLAN (tbl INDEX (names)): blr_indices + a count byte + the
    /// counted index names (probed)
    pub const INDICES: u8 = 0x90;
    /// streams inside SUBROUTINE bodies: blr_relation3 - counted
    /// schema, counted package (empty), counted name, then the alias
    /// string relation2 would carry OR a counted empty, ctx (probed;
    /// layout from the engine's RelationSourceNode::genBlr)
    pub const RELATION3: u8 = 0x94;
    pub const EQL: u8 = 0x2F;
    pub const NEQ: u8 = 0x30;
    pub const GTR: u8 = 0x31;
    pub const GEQ: u8 = 0x32;
    pub const LSS: u8 = 0x33;
    pub const LEQ: u8 = 0x34;
}

/// A value expression in a boolean leaf.
#[derive(Clone, Debug, PartialEq)]
enum Val {
    /// a field with its stream CONTEXT id and UPPERCASED name
    Field(u8, String),
    /// integer literal - blr_long holds 32 bits; wider refuses
    Int(i32),
    /// decimal literal as (raw, scale): 12.50 is (1250, -2)
    Dec(i32, i8),
    Str(String),
    Add(Box<Val>, Box<Val>),
    Sub(Box<Val>, Box<Val>),
    Mul(Box<Val>, Box<Val>),
    Div(Box<Val>, Box<Val>),
    /// blr_negate - survives only before a FIELD; a sign before a
    /// numeric literal folds into it at parse (probed: A = -1 stores
    /// the literal 0xFFFFFFFF, no negate verb)
    Neg(Box<Val>),
    Concat(Box<Val>, Box<Val>),
    /// a literal past blr_long's 32 bits: blr_int64
    Int64(i64),
    Upper(Box<Val>),
    /// `EXTRACT(<part> FROM <value>)`: blr_extract, the part code
    /// (blr_extract_year 0 .. blr_extract_week 9), the value - measured
    /// on 2196: an index COMPUTED BY (EXTRACT(YEAR FROM DT)) stores
    /// 05 9F 00 17 00 02 'DT' 4C
    Extract(u8, Box<Val>),
    Lower(Box<Val>),
    /// blr_strlen with its length-type byte (1=CHAR, 2=OCTET)
    StrLen(u8, Box<Val>),
    /// blr_substring(source, start, length) - START IS 0-BASED and the
    /// engine emits `subtract(<from>, 1)` unfolded, so the parser
    /// builds exactly that Sub node
    Substring(Box<Val>, Box<Val>, Box<Val>),
    /// blr_trim(where, [what], source)
    Trim(u8, Option<Box<Val>>, Box<Val>),
    Null,
    /// blr_cast to an explicit target descriptor
    Cast(Dsc, Box<Val>),
    /// blr_value_if(condition, then, else) - built by searched CASE,
    /// IIF and NULLIF, always under a Cast to the unified branch dsc
    ValueIf(Box<Bool>, Box<Val>, Box<Val>),
    /// blr_decode - the simple CASE: selector, comparands, results
    /// (the ELSE, when present, is the extra last result)
    Decode(Box<Val>, Vec<Val>, Vec<Val>),
    /// a scalar subselect: blr_via(blr_singular(rse), value, null)
    ScalarSub(Box<SubQ>),
    /// `col[i, j]` - an array element of a field (blr_index)
    ArrayElem(Box<Val>, Vec<Val>),
    /// blr_fid - a stream's own column by number; how HAVING, ORDER
    /// BY and the DO body address an aggregate's output
    Fid(u8, u16),
    /// a DECLAREd sub-function call: blr_invoke_function, the id
    /// clause (sub + counted name), counted argument values (probed)
    SubFn(String, Vec<Val>),
    /// a PACKAGED function call: blr_function2, counted package +
    /// name, a count BYTE, the arguments (probed)
    PkgFn(String, String, Vec<Val>),
    /// a PLAIN (non-packaged) user function call: blr_function, counted
    /// name, a count byte, the arguments
    Fn(String, Vec<Val>),
    /// `:name` - an INPUT parameter, referenced straight out of
    /// message 0 as blr_parameter2 (value slot 2i, null slot 2i+1);
    /// no variable is declared for inputs (probed)
    InParam(u16),
    /// blr_derived_expr over one subquery stream: the wrapper an
    /// EXPRESSION select item takes in a quantified subquery
    /// (probed: BF 01 <ctx> <expr>)
    DerivedWrap(u8, Box<Val>),
    /// cast(int64, <val>) - the UNIFYING cast a plain branch takes
    /// when a sibling's dialect-3 arithmetic types the union int64
    /// (probed three times over: CASE, unions, recursion)
    CastInt64(Box<Val>),
    /// a local variable declared in the body - blr_variable
    LocalVar(u16),
    /// blr_internal_info(literal 6) - the trigger-action code the
    /// INSERTING/UPDATING/DELETING predicates compare against
    TrigAction,
    /// CURRENT_DATE / CURRENT_TIME / CURRENT_TIMESTAMP - one niladic
    /// verb each (probed)
    CurrentDate,
    CurrentTime,
    CurrentTimestamp,
    /// ROW_COUNT - blr_internal_info(literal 5) (probed)
    RowCount,
    /// CURRENT_CONNECTION / CURRENT_TRANSACTION -
    /// blr_internal_info(1) / (2) (probed)
    CurrentConnection,
    CurrentTransaction,
    /// CURRENT_USER / USER - blr_user_name (0x2C); CURRENT_ROLE -
    /// blr_current_role (0xAE) (measured: an engine view over
    /// `S = CURRENT_USER` stores `2F 17 01 01 'S' 2C`)
    UserName,
    CurrentRole,
    /// TRUE / FALSE - blr_literal blr_bool 1 / 0 (measured: `15 17 01`)
    Bool(bool),
    /// DATE / TIME / TIMESTAMP '<iso>' - blr_literal with the dtype and its
    /// value bytes (measured: DATE '2024-02-01' is `15 0C B5 EB 00 00`, the
    /// MJD day; TIME is 1/10000 s ticks; TIMESTAMP is both)
    TemporalLit(Vec<u8>),
    /// GEN_ID(sequence, increment)
    GenId(String, Box<Val>),
    /// NEXT VALUE FOR sequence - blr_gen_id2, the name alone
    GenId2(String),
    /// blr_coalesce
    Coalesce(Vec<Val>),
    /// a SYSTEM function - blr_sys_function, the name counted, then the
    /// counted arguments ([SYS_FUNCTIONS]; the special spellings of
    /// DATEADD / DATEDIFF / FIRST_DAY / LAST_DAY / POSITION / OVERLAY /
    /// CRYPT_HASH are rewritten to the argument order the engine stores)
    SysFn(String, Vec<Val>),
    /// an exponent literal, the source text the engine's blr_double
    /// literal carries
    DoubleLit(String),
    /// a hex literal's bytes - text2 in OCTETS
    Bytes(Vec<u8>),
    /// a text literal stamped with an EXPLICIT set (CRYPT_HASH's algorithm
    /// name is text2 in ASCII, charset 2 - measured)
    StrCs(String, u16),
    /// a SORT KEY written with NULLS FIRST (blr_nullsfirst 0xB2) or NULLS
    /// LAST (0xB4): the byte goes BEFORE the key's direction byte, in a
    /// statement's ORDER BY, an aggregate's and a window's alike (measured);
    /// only [emit_sort_key] reads it - it never stands as a value
    NullsPlaced(u8, Box<Val>),
    /// a window function met INSIDE a select item's expression: the index
    /// of its spec in the parser's `win_found`, resolved to a window fid
    /// when the windows are built (never emitted)
    WinRef(u16),
    /// blr_derived_expr over SEVERAL contexts: an expression column of a
    /// derived table with windows inside names every window stream
    /// (measured: `BF 02 01 02` beside two windows, `BF 01 01` for a
    /// constant beside one)
    DerivedWrapN(Vec<u8>, Box<Val>),
}

/// One sort key: `[nulls byte] <ascending|descending> <value>`.
fn emit_sort_key(out: &mut Vec<u8>, descending: bool, key: &Val) {
    let key = match key {
        Val::NullsPlaced(nulls, inner) => {
            out.push(*nulls);
            inner.as_ref()
        }
        other => other,
    };
    out.push(if descending { blr::DESCENDING } else { blr::ASCENDING });
    emit_val(out, key);
}

/// A cast target descriptor, exactly the dsc bytes blr_cast carries
/// (each layout probed: numerics are dtype + scale, texts carry a
/// 2-byte charset then a 2-byte length, temporals are the dtype alone)
#[derive(Clone, Copy, Debug, PartialEq)]
enum Dsc {
    /// blr_short / blr_long / blr_int64 with a scale byte
    Num(u8, i8),
    /// blr_text2 / blr_varying2 in an EXPLICIT set: (characters, set id) -
    /// `CHAR(n) CHARACTER SET <name>`, whatever the database's default
    TextCs(u16, u16),
    VaryingCs(u16, u16),
    /// blr_dec64 / blr_dec128 - DECFLOAT(16) / DECFLOAT(34): the dtype
    /// byte alone (probed: a DECFLOAT(16) parameter's message slot is `18`)
    Dec64,
    Dec128,
    /// blr_text2, charset 0 (a NONE-charset database), length
    Text(u16),
    /// blr_varying2, charset 0, length
    Varying(u16),
    Date,
    Time,
    Timestamp,
    /// blr_double (27) / blr_float (10): the dtype byte alone
    Double,
    Float,
    /// blr_bool (23): the dtype byte alone (measured: a BOOLEAN output's
    /// message slot is `17`)
    Boolean,
}

/// Every character set the engine carries: (name or alias, RDB$CHARACTER_SET_ID),
/// read off 6.0.0.2196's RDB$CHARACTER_SETS and the RDB$TYPES aliases of
/// RDB$CHARACTER_SET_NAME - an explicit `CHARACTER SET <name>` in a type.
const CHARSET_NAMES: &[(&str, u16)] = &[
    ("ANSI", 21),
    ("ASCII", 2),
    ("ASCII7", 2),
    ("BIG5", 56),
    ("BIG_5", 56),
    ("BINARY", 1),
    ("CP943C", 68),
    ("CYRL", 50),
    ("DOS437", 10),
    ("DOS737", 9),
    ("DOS775", 15),
    ("DOS850", 11),
    ("DOS852", 45),
    ("DOS857", 46),
    ("DOS858", 16),
    ("DOS860", 13),
    ("DOS861", 47),
    ("DOS862", 17),
    ("DOS863", 14),
    ("DOS864", 18),
    ("DOS865", 12),
    ("DOS866", 48),
    ("DOS869", 49),
    ("DOS_437", 10),
    ("DOS_737", 9),
    ("DOS_775", 15),
    ("DOS_850", 11),
    ("DOS_852", 45),
    ("DOS_857", 46),
    ("DOS_858", 16),
    ("DOS_860", 13),
    ("DOS_861", 47),
    ("DOS_862", 17),
    ("DOS_863", 14),
    ("DOS_864", 18),
    ("DOS_865", 12),
    ("DOS_866", 48),
    ("DOS_869", 49),
    ("DOS_936", 57),
    ("DOS_949", 44),
    ("DOS_950", 56),
    ("EUCJ", 6),
    ("EUCJ_0208", 6),
    ("GB18030", 69),
    ("GB2312", 57),
    ("GBK", 67),
    ("GB_2312", 57),
    ("ISO-8859-13", 40),
    ("ISO-8859-2", 22),
    ("ISO-8859-3", 23),
    ("ISO-8859-4", 34),
    ("ISO-8859-5", 35),
    ("ISO-8859-6", 36),
    ("ISO-8859-7", 37),
    ("ISO-8859-8", 38),
    ("ISO-8859-9", 39),
    ("ISO88591", 21),
    ("ISO885913", 40),
    ("ISO88592", 22),
    ("ISO88593", 23),
    ("ISO88594", 34),
    ("ISO88595", 35),
    ("ISO88596", 36),
    ("ISO88597", 37),
    ("ISO88598", 38),
    ("ISO88599", 39),
    ("ISO8859_1", 21),
    ("ISO8859_13", 40),
    ("ISO8859_2", 22),
    ("ISO8859_3", 23),
    ("ISO8859_4", 34),
    ("ISO8859_5", 35),
    ("ISO8859_6", 36),
    ("ISO8859_7", 37),
    ("ISO8859_8", 38),
    ("ISO8859_9", 39),
    ("KOI8R", 63),
    ("KOI8U", 64),
    ("KSC5601", 44),
    ("KSC_5601", 44),
    ("LATIN1", 21),
    ("LATIN2", 22),
    ("LATIN3", 23),
    ("LATIN4", 34),
    ("LATIN5", 39),
    ("LATIN7", 40),
    ("NEXT", 19),
    ("NONE", 0),
    ("OCTETS", 1),
    ("SJIS", 5),
    ("SJIS_0208", 5),
    ("SQL_TEXT", 3),
    ("TIS620", 66),
    ("UNICODE_FSS", 3),
    ("USASCII", 2),
    ("UTF-8", 4),
    ("UTF8", 4),
    ("UTF_FSS", 3),
    ("WIN1250", 51),
    ("WIN1251", 52),
    ("WIN1252", 53),
    ("WIN1253", 54),
    ("WIN1254", 55),
    ("WIN1255", 58),
    ("WIN1256", 59),
    ("WIN1257", 60),
    ("WIN1258", 65),
    ("WIN_1250", 51),
    ("WIN_1251", 52),
    ("WIN_1252", 53),
    ("WIN_1253", 54),
    ("WIN_1254", 55),
    ("WIN_1255", 58),
    ("WIN_1256", 59),
    ("WIN_1257", 60),
    ("WIN_1258", 65),
    ("WIN_936", 57),
    ("WIN_949", 44),
    ("WIN_950", 56),
];

/// RDB$BYTES_PER_CHARACTER of each set ([CHARSET_NAMES]).
const CHARSET_BPC: &[(u16, u16)] = &[
    (0, 1),
    (1, 1),
    (2, 1),
    (3, 3),
    (4, 4),
    (5, 2),
    (6, 2),
    (9, 1),
    (10, 1),
    (11, 1),
    (12, 1),
    (13, 1),
    (14, 1),
    (15, 1),
    (16, 1),
    (17, 1),
    (18, 1),
    (19, 1),
    (21, 1),
    (22, 1),
    (23, 1),
    (34, 1),
    (35, 1),
    (36, 1),
    (37, 1),
    (38, 1),
    (39, 1),
    (40, 1),
    (44, 2),
    (45, 1),
    (46, 1),
    (47, 1),
    (48, 1),
    (49, 1),
    (50, 1),
    (51, 1),
    (52, 1),
    (53, 1),
    (54, 1),
    (55, 1),
    (56, 2),
    (57, 2),
    (58, 1),
    (59, 1),
    (60, 1),
    (63, 1),
    (64, 1),
    (65, 1),
    (66, 1),
    (67, 2),
    (68, 2),
    (69, 4),
];

/// An explicit set's (id, bytes per character), or None for a name the
/// engine does not carry.
/// A collation's id within its character set: UTF8's five (measured on
/// 2196: UTF8 0, UCS_BASIC 1, UNICODE 2, UNICODE_CI 3, UNICODE_CI_AI 4),
/// and for every set its own default - the set's name or alias, id 0.
/// Anything else (the other sets' named collations) is unprobed.
fn collation_id(cs: u16, name: &str) -> Option<u16> {
    if cs == 4 {
        let id = match name {
            "UTF8" => 0,
            "UCS_BASIC" => 1,
            "UNICODE" => 2,
            "UNICODE_CI" => 3,
            "UNICODE_CI_AI" => 4,
            _ => return None,
        };
        return Some(id);
    }
    match charset_by_name(name) {
        Some((id, _)) if id == cs => Some(0),
        _ => None,
    }
}

fn charset_by_name(name: &str) -> Option<(u16, u16)> {
    let id = CHARSET_NAMES.iter().find(|(n, _)| *n == name).map(|(_, i)| *i)?;
    let bpc = CHARSET_BPC.iter().find(|(i, _)| *i == id).map(|(_, b)| *b)?;
    Some((id, bpc))
}

/// A typed temporal literal's blr_literal tail - the dtype byte and the
/// value - for the STRICT ISO spelling only: `YYYY-MM-DD` for a DATE,
/// `HH:MM[:SS[.ffff]]` for a TIME, both (one blank between) for a
/// TIMESTAMP. The engine reads many more spellings (month names, other
/// separators, TODAY / NOW); every one of them refuses here.
fn temporal_literal_bytes(kind: &str, text: &str) -> Option<Vec<u8>> {
    let date = |t: &str| -> Option<i32> {
        let b = t.as_bytes();
        if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
            return None;
        }
        let y: i64 = t.get(0..4)?.parse().ok()?;
        let m: i64 = t.get(5..7)?.parse().ok()?;
        let d: i64 = t.get(8..10)?.parse().ok()?;
        if !(1..=12).contains(&m) || d < 1 {
            return None;
        }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let mdays = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][(m - 1) as usize];
        if d > mdays || !(1..=9999).contains(&y) {
            return None;
        }
        // days from the civil date (Howard Hinnant's algorithm), then to MJD
        let (y2, m2) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
        let era = y2.div_euclid(400);
        let yoe = y2 - era * 400;
        let doy = (153 * m2 + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let unix_days = era * 146097 + doe - 719468;
        i32::try_from(unix_days + 40587).ok()
    };
    let time = |t: &str| -> Option<u32> {
        let (hms, frac) = match t.split_once('.') {
            Some((a, f)) => (a, Some(f)),
            None => (t, None),
        };
        let parts: Vec<&str> = hms.split(':').collect();
        if parts.len() < 2 || parts.len() > 3 || parts.iter().any(|p| p.len() != 2 || !p.bytes().all(|c| c.is_ascii_digit())) {
            return None;
        }
        let h: u32 = parts[0].parse().ok()?;
        let mi: u32 = parts[1].parse().ok()?;
        let se: u32 = parts.get(2).map_or(Some(0), |p| p.parse().ok())?;
        if h > 23 || mi > 59 || se > 59 || (frac.is_some() && parts.len() != 3) {
            return None;
        }
        let f: u32 = match frac {
            None => 0,
            Some(f) if (1..=4).contains(&f.len()) && f.bytes().all(|c| c.is_ascii_digit()) => {
                f.parse::<u32>().ok()? * 10u32.pow(4 - f.len() as u32)
            }
            Some(_) => return None,
        };
        Some(((h * 60 + mi) * 60 + se) * 10000 + f)
    };
    let mut out = Vec::new();
    match kind {
        "DATE" => {
            out.push(blr::DATE);
            out.extend_from_slice(&date(text)?.to_le_bytes());
        }
        "TIME" => {
            out.push(blr::TIME);
            out.extend_from_slice(&time(text)?.to_le_bytes());
        }
        _ => {
            let (d, t) = text.split_once(' ')?;
            out.push(blr::TIMESTAMP);
            out.extend_from_slice(&date(d)?.to_le_bytes());
            out.extend_from_slice(&time(t)?.to_le_bytes());
        }
    }
    Some(out)
}

fn emit_dsc(out: &mut Vec<u8>, d: Dsc) {
    match d {
        Dsc::Num(dt, sc) => {
            out.push(dt);
            out.push(sc as u8);
        }
        Dsc::Text(l) => {
            let (cs, bpc) = DEFAULT_CS.with(|c| c.get());
            out.push(blr::TEXT2);
            out.extend_from_slice(&cs.to_le_bytes());
            out.extend_from_slice(&l.saturating_mul(bpc).to_le_bytes());
        }
        Dsc::Varying(l) => {
            let (cs, bpc) = DEFAULT_CS.with(|c| c.get());
            out.push(blr::VARYING2);
            out.extend_from_slice(&cs.to_le_bytes());
            out.extend_from_slice(&l.saturating_mul(bpc).to_le_bytes());
        }
        Dsc::TextCs(l, cs) | Dsc::VaryingCs(l, cs) => {
            // (the high byte is a COLLATION: the width is the set's)
            let bpc = CHARSET_BPC.iter().find(|(i, _)| *i == cs & 0xFF).map_or(1, |(_, b)| *b);
            out.push(if matches!(d, Dsc::TextCs(..)) { blr::TEXT2 } else { blr::VARYING2 });
            out.extend_from_slice(&cs.to_le_bytes());
            out.extend_from_slice(&l.saturating_mul(bpc).to_le_bytes());
        }
        Dsc::Dec64 => out.push(24),
        Dsc::Dec128 => out.push(25),
        Dsc::Date => out.push(blr::DATE),
        Dsc::Time => out.push(blr::TIME),
        Dsc::Timestamp => out.push(blr::TIMESTAMP),
        Dsc::Double => out.push(27),
        Dsc::Float => out.push(10),
        Dsc::Boolean => out.push(23),
    }
}

/// What a CASE / IIF / NULLIF / IN-list operand contributes to the
/// unified descriptor - the engine's DataTypeUtil::makeFromList, as
/// measured on 2196 through RDB$PROCEDURE_BLR (see [P::unify_branches]).
#[derive(Clone, Copy, Debug, PartialEq)]
enum BranchDsc {
    /// an exact numeric: its blr dtype (SHORT / LONG / INT64 / INT128)
    /// and scale
    Exact(u8, i8),
    /// FLOAT (false) or DOUBLE PRECISION (true)
    Approx(bool),
    /// a text: VARYING or not, its length in CHARACTERS, its set
    Text { varying: bool, chars: u16, cs: u16 },
    Date,
    Time,
    Timestamp,
    Boolean,
    /// NULL - shapes nothing
    Skip,
}

fn dsc_to_branch(d: Dsc) -> Option<BranchDsc> {
    Some(match d {
        Dsc::Num(dt, sc) if matches!(dt, blr::SHORT | blr::LONG | blr::INT64 | 26) => {
            BranchDsc::Exact(dt, sc)
        }
        Dsc::Num(..) | Dsc::Dec64 | Dsc::Dec128 => return None,
        Dsc::Text(l) => BranchDsc::Text { varying: false, chars: l, cs: DEFAULT_CS.with(|c| c.get()).0 },
        Dsc::Varying(l) => BranchDsc::Text { varying: true, chars: l, cs: DEFAULT_CS.with(|c| c.get()).0 },
        Dsc::TextCs(l, cs) => BranchDsc::Text { varying: false, chars: l, cs },
        Dsc::VaryingCs(l, cs) => BranchDsc::Text { varying: true, chars: l, cs },
        Dsc::Date => BranchDsc::Date,
        Dsc::Time => BranchDsc::Time,
        Dsc::Timestamp => BranchDsc::Timestamp,
        Dsc::Double => BranchDsc::Approx(true),
        Dsc::Float => BranchDsc::Approx(false),
        Dsc::Boolean => BranchDsc::Boolean,
    })
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum CmpOp {
    Eql,
    Neq,
    Gtr,
    Geq,
    Lss,
    Leq,
}

impl CmpOp {
    fn verb(self) -> u8 {
        match self {
            CmpOp::Eql => blr::EQL,
            CmpOp::Neq => blr::NEQ,
            CmpOp::Gtr => blr::GTR,
            CmpOp::Geq => blr::GEQ,
            CmpOp::Lss => blr::LSS,
            CmpOp::Leq => blr::LEQ,
        }
    }
    /// the inverse comparison - what the engine compiles `NOT <cmp>`
    /// into (probed: NOT (A > 5) stores blr_leq)
    fn inverse(self) -> CmpOp {
        match self {
            CmpOp::Eql => CmpOp::Neq,
            CmpOp::Neq => CmpOp::Eql,
            CmpOp::Gtr => CmpOp::Leq,
            CmpOp::Leq => CmpOp::Gtr,
            CmpOp::Lss => CmpOp::Geq,
            CmpOp::Geq => CmpOp::Lss,
        }
    }
}

/// The join "type" of a comma-listed stream: no ON, one flat rse.
const JOIN_COMMA: u8 = 0xFE;

#[derive(Clone, Debug, PartialEq)]
enum Bool {
    And(Box<Bool>, Box<Bool>),
    Or(Box<Bool>, Box<Bool>),
    /// survives only over Like and Missing - negate() folds the rest
    Not(Box<Bool>),
    Cmp(CmpOp, Val, Val),
    Missing(Val),
    Between(Val, Val, Val),
    Like(Val, Val),
    /// blr_in_list: value, u16 count, values (FB5+); NOT IN keeps a
    /// real blr_not over it (probed)
    InList(Val, Vec<Val>),
    /// EXISTS - blr_any over the subquery's rse
    Any(SubQ),
    /// SINGULAR - blr_unique, same shape
    Unique(SubQ),
    /// `<left> <cmp> ANY/SOME (SELECT <col> ...)` and IN (SELECT) -
    /// blr_ansi_any; the comparison is the outer rse's boolean
    /// STARTING [WITH]: blr_starting - NOT keeps a real blr_not,
    /// like LIKE (probed)
    Starting(Val, Val),
    /// `<a> IS NOT DISTINCT FROM <b>` - blr_equiv, the null-safe
    /// equality; `IS DISTINCT FROM` is blr_not over it, the parser's
    /// own shape (parse.y distinct_predicate), which NotBoolNode keeps
    /// because blr_equiv has no inverse verb
    Equiv(Val, Val),
    /// CONTAINING - blr_containing; NOT keeps a real blr_not (measured)
    Containing(Val, Val),
    /// SIMILAR TO [ESCAPE] - blr_similar: value, pattern, then a count
    /// byte (0 or 1) and the escape (measured)
    Similar(Val, Val, Option<Val>),
    /// LIKE .. ESCAPE - blr_ansi_like: value, pattern, escape (measured)
    AnsiLike(Val, Val, Val),
    AnsiAny(CmpOp, Val, SubQ),
    /// `<left> <cmp> ALL (SELECT ...)` and NOT IN - blr_ansi_all
    AnsiAll(CmpOp, Val, SubQ),
}

/// A UNION ALL standing as a quantified subquery's stream: the
/// union claims the subquery's context slot, branches take the next
/// ones, and the comparison reads fid(union ctx, 0) (probed).
#[derive(Clone, Debug, PartialEq)]
struct SubUnion {
    /// per branch: the stream, its context, its WHERE, and the
    /// single select item
    branches: Vec<(Stream, u8, Option<Box<Bool>>, Val)>,
}

/// A single-stream subquery: its stream (already holding a context id
/// in the statement's numbering, which CONTINUES across subqueries -
/// probed), its own WHERE, and for the quantified forms the selected
/// column.
#[derive(Clone, Debug, PartialEq)]
struct SubQ {
    stream: Stream,
    ctx: u8,
    wher: Option<Box<Bool>>,
    col: Option<Val>,
    /// an EXPRESSION select item (quantified subqueries only): the
    /// comparand wraps in blr_derived_expr over the subquery stream
    /// (probed: IN (SELECT UA / 25 ...) stores BF 01 <ctx> divide)
    expr: Option<Val>,
    /// a UNION ALL subquery: the stream slot holds the union
    union_: Option<SubUnion>,
    /// an AGGREGATE scalar subselect: the verb, its argument, and
    /// the aggregate's context - the slot AFTER the stream's, which
    /// it claims like every aggregate (probed)
    agg: Option<(u8, Option<Val>, u8)>,
}

/// Stamp every subquery stream under a cursor's rse with the cursor
/// name - the concatenated-alias infection (probed). Recurses into
/// the subqueries' own WHEREs.
fn stamp_bool(b: &mut Bool, cn: &str) {
    match b {
        Bool::And(l, r) | Bool::Or(l, r) => {
            stamp_bool(l, cn);
            stamp_bool(r, cn);
        }
        Bool::Not(x) => stamp_bool(x, cn),
        Bool::Cmp(_, a, c) | Bool::Like(a, c) | Bool::Starting(a, c) | Bool::Equiv(a, c)
        | Bool::Containing(a, c) | Bool::Similar(a, c, None) => {
            stamp_val(a, cn);
            stamp_val(c, cn);
        }
        Bool::Similar(a, c, Some(e)) | Bool::AnsiLike(a, c, e) => {
            stamp_val(a, cn);
            stamp_val(c, cn);
            stamp_val(e, cn);
        }
        Bool::Missing(v) => stamp_val(v, cn),
        Bool::Between(v, lo, hi) => {
            stamp_val(v, cn);
            stamp_val(lo, cn);
            stamp_val(hi, cn);
        }
        Bool::InList(v, items) => {
            stamp_val(v, cn);
            for it in items {
                stamp_val(it, cn);
            }
        }
        Bool::Any(sub) | Bool::Unique(sub) => stamp_subq(sub, cn),
        Bool::AnsiAny(_, left, sub) | Bool::AnsiAll(_, left, sub) => {
            stamp_val(left, cn);
            stamp_subq(sub, cn);
        }
    }
}

fn stamp_subq(sub: &mut SubQ, cn: &str) {
    sub.stream.cur = Some(cn.to_string());
    if let Some(w) = &mut sub.wher {
        stamp_bool(w, cn);
    }
    if let Some(u) = &mut sub.union_ {
        for (st, _, wher, _) in &mut u.branches {
            st.cur = Some(cn.to_string());
            if let Some(w) = wher {
                stamp_bool(w, cn);
            }
        }
    }
}

fn stamp_val(v: &mut Val, cn: &str) {
    match v {
        Val::ScalarSub(sub) => stamp_subq(sub, cn),
        Val::Add(a, b)
        | Val::Sub(a, b)
        | Val::Mul(a, b)
        | Val::Div(a, b)
        | Val::Concat(a, b) => {
            stamp_val(a, cn);
            stamp_val(b, cn);
        }
        Val::Neg(a) | Val::Upper(a) | Val::Lower(a) | Val::Extract(_, a) | Val::NullsPlaced(_, a) => stamp_val(a, cn),
        _ => {}
    }
}

/// Push a negation down the tree the way the engine's DSQL does
/// (probed): De Morgan through AND/OR, inverse verbs for comparisons,
/// `NOT BETWEEN` expanded to `< lo OR > hi`, blr_not kept only over
/// LIKE and MISSING, double negation cancelled.
fn negate(b: Bool) -> Bool {
    match b {
        Bool::And(l, r) => Bool::Or(Box::new(negate(*l)), Box::new(negate(*r))),
        Bool::Or(l, r) => Bool::And(Box::new(negate(*l)), Box::new(negate(*r))),
        Bool::Not(inner) => *inner,
        Bool::Cmp(op, a, b) => Bool::Cmp(op.inverse(), a, b),
        Bool::Between(v, lo, hi) => Bool::Or(
            Box::new(Bool::Cmp(CmpOp::Lss, v.clone(), lo)),
            Box::new(Bool::Cmp(CmpOp::Gtr, v, hi)),
        ),
        keep @ (Bool::Missing(_) | Bool::Like(..) | Bool::Starting(..)
        | Bool::InList(..) | Bool::Equiv(..) | Bool::Containing(..)
        | Bool::Similar(..) | Bool::AnsiLike(..)) => {
            Bool::Not(Box::new(keep))
        }
        // the quantifier FLIPS and the comparison INVERTS (probed:
        // NOT (A = ANY ...) stores ansi_all/neq - the NOT IN shape -
        // and NOT (A > ALL ...) stores ansi_any/leq)
        Bool::AnsiAny(op, l, s) => Bool::AnsiAll(op.inverse(), l, s),
        Bool::AnsiAll(op, l, s) => Bool::AnsiAny(op.inverse(), l, s),
        // EXISTS and SINGULAR have no inverse verb - blr_not survives
        keep @ (Bool::Any(_) | Bool::Unique(_)) => Bool::Not(Box::new(keep)),
    }
}

// ---------------------------------------------------------------- lexer

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Ident(String),
    Int(i64),
    Dec(i64, i8),
    /// an EXPONENT literal (`1e0`, `1.5E-3`): the engine stores it as a
    /// blr_double literal carrying the SOURCE TEXT (measured: `151B 0300
    /// "1e0"`), so the spelling is kept as written
    Double(String),
    /// a HEX literal `X'0A0B'`: blr_literal text2 in OCTETS (charset 1)
    /// over the decoded bytes (measured)
    Hex(Vec<u8>),
    Str(String),
    LParen,
    RParen,
    Cmp(CmpOp),
    Comma,
    Plus,
    Minus,
    Star,
    Slash,
    Concat,
    Dot,
    Colon,
    Semi,
    /// `[` / `]` - an ARRAY element's subscript list
    LBracket,
    RBracket,
}

fn lex(sql: &str) -> Option<Vec<Tok>> {
    let b: Vec<char> = sql.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        let c = b[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        match c {
            '(' => {
                out.push(Tok::LParen);
                i += 1;
            }
            ')' => {
                out.push(Tok::RParen);
                i += 1;
            }
            ',' => {
                out.push(Tok::Comma);
                i += 1;
            }
            '+' => {
                out.push(Tok::Plus);
                i += 1;
            }
            '-' => {
                out.push(Tok::Minus);
                i += 1;
            }
            '*' => {
                out.push(Tok::Star);
                i += 1;
            }
            '/' => {
                out.push(Tok::Slash);
                i += 1;
            }
            '|' if b.get(i + 1) == Some(&'|') => {
                out.push(Tok::Concat);
                i += 2;
            }
            '.' => {
                out.push(Tok::Dot);
                i += 1;
            }
            ':' => {
                out.push(Tok::Colon);
                i += 1;
            }
            ';' => {
                out.push(Tok::Semi);
                i += 1;
            }
            '=' => {
                out.push(Tok::Cmp(CmpOp::Eql));
                i += 1;
            }
            '<' => {
                if b.get(i + 1) == Some(&'=') {
                    out.push(Tok::Cmp(CmpOp::Leq));
                    i += 2;
                } else if b.get(i + 1) == Some(&'>') {
                    out.push(Tok::Cmp(CmpOp::Neq));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(CmpOp::Lss));
                    i += 1;
                }
            }
            '>' => {
                if b.get(i + 1) == Some(&'=') {
                    out.push(Tok::Cmp(CmpOp::Geq));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(CmpOp::Gtr));
                    i += 1;
                }
            }
            '\'' => {
                i += 1;
                let mut v = String::new();
                loop {
                    match b.get(i) {
                        None => return None,
                        Some('\'') if b.get(i + 1) == Some(&'\'') => {
                            v.push('\'');
                            i += 2;
                        }
                        Some('\'') => {
                            i += 1;
                            break;
                        }
                        Some(ch) => {
                            v.push(*ch);
                            i += 1;
                        }
                    }
                }
                out.push(Tok::Str(v));
            }
            '"' => {
                // a DELIMITED identifier: the name EXACTLY as written
                // (case, blanks, keywords), `""` one quote - the engine's
                // rule, and the spelling the compiled BLR names the
                // field by. An empty name is no name.
                i += 1;
                let mut v = String::new();
                loop {
                    match b.get(i) {
                        None => return None,
                        Some('"') if b.get(i + 1) == Some(&'"') => {
                            v.push('"');
                            i += 2;
                        }
                        Some('"') => {
                            i += 1;
                            break;
                        }
                        Some(ch) => {
                            v.push(*ch);
                            i += 1;
                        }
                    }
                }
                if v.is_empty() {
                    return None;
                }
                // a DELIMITED name that spells a context word ("USER",
                // "CURRENT_DATE", ..) is a COLUMN, which this token stream
                // cannot tell from the bare keyword - refused, never read
                // as the session value (or the bare word as the column)
                if matches!(
                    v.as_str(),
                    "CURRENT_USER" | "USER" | "CURRENT_ROLE" | "CURRENT_DATE" | "CURRENT_TIME"
                        | "CURRENT_TIMESTAMP" | "CURRENT_CONNECTION" | "CURRENT_TRANSACTION"
                        | "LOCALTIME" | "LOCALTIMESTAMP" | "ROW_COUNT" | "SQLCODE" | "GDSCODE"
                        | "SQLSTATE" | "TRUE" | "FALSE" | "UNKNOWN"
                ) {
                    return None;
                }
                out.push(Tok::Ident(v));
            }
            d if d.is_ascii_digit() => {
                let start = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if b.get(i) == Some(&'.') && b.get(i + 1).is_some_and(|c| c.is_ascii_digit()) {
                    i += 1;
                    let fs = i;
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                    let digits: String =
                        b[start..fs - 1].iter().chain(&b[fs..i]).collect();
                    out.push(Tok::Dec(digits.parse().ok()?, -((i - fs) as i8)));
                } else {
                    let n: i64 = b[start..i].iter().collect::<String>().parse().ok()?;
                    out.push(Tok::Int(n));
                }
                // an EXPONENT literal (`1e308`, `1.5E-3`): the mantissa
                // just lexed plus e/E, an optional sign and digits - kept
                // as its source text (the engine's double literal carries
                // the spelling). Any other letter RUN INTO a number is
                // refused - never a number followed by an alias named
                // `E308` (which answered 1.0 for `SELECT 1e308` once
                // aliases were accepted)
                if matches!(b.get(i), Some('e' | 'E')) {
                    let mut j = i + 1;
                    if matches!(b.get(j), Some('+' | '-')) {
                        j += 1;
                    }
                    if !b.get(j).is_some_and(|c| c.is_ascii_digit()) {
                        return None;
                    }
                    while j < b.len() && b[j].is_ascii_digit() {
                        j += 1;
                    }
                    if b.get(j).is_some_and(|c| c.is_alphanumeric() || *c == '_' || *c == '$' || *c == '.') {
                        return None;
                    }
                    out.pop();
                    out.push(Tok::Double(b[start..j].iter().collect()));
                    i = j;
                } else if b.get(i).is_some_and(|c| c.is_alphabetic() || *c == '_' || *c == '$') {
                    return None;
                }
            }
            // a HEX literal `X'0A0B'` / `x'..'`: pairs of hex digits (an odd
            // count is a syntax error in the engine) - the bytes of a text2
            // literal in OCTETS (measured: `150F 0100 0200 0A0B`)
            'x' | 'X' if b.get(i + 1) == Some(&'\'') => {
                i += 2;
                let mut digits = String::new();
                loop {
                    match b.get(i) {
                        None => return None,
                        Some('\'') => {
                            i += 1;
                            break;
                        }
                        Some(ch) if ch.is_ascii_hexdigit() => {
                            digits.push(*ch);
                            i += 1;
                        }
                        Some(_) => return None,
                    }
                }
                if digits.len() % 2 != 0 {
                    return None;
                }
                let bytes = (0..digits.len())
                    .step_by(2)
                    .map(|k| u8::from_str_radix(&digits[k..k + 2], 16).ok())
                    .collect::<Option<Vec<u8>>>()?;
                out.push(Tok::Hex(bytes));
            }
            a if a.is_alphabetic() || a == '_' || a == '$' => {
                let start = i;
                while i < b.len()
                    && (b[i].is_alphanumeric() || b[i] == '_' || b[i] == '$')
                {
                    i += 1;
                }
                // unquoted identifiers uppercase, exactly as the engine
                // stores them in the compiled BLR
                out.push(Tok::Ident(
                    b[start..i].iter().collect::<String>().to_ascii_uppercase(),
                ));
            }
            '[' => {
                out.push(Tok::LBracket);
                i += 1;
            }
            ']' => {
                out.push(Tok::RBracket);
                i += 1;
            }
            _ => return None, // outside this slice's lexicon
        }
    }
    Some(out)
}

// --------------------------------------------------------------- parser

/// One FROM stream: relation name, optional alias, 1-based context.
#[derive(Clone, Debug, PartialEq)]
struct Stream {
    name: String,
    alias: Option<String>,
    /// a SELECTABLE PROCEDURE called with arguments as the source
    /// (`FROM show_langs(:code, :grade, :country)`): emitted as
    /// blr_procedure with the inputs, no relation
    proc_args: Option<Vec<Val>>,
    /// a derived table `(SELECT cols FROM name [WHERE ...]) alias`:
    /// emitted as an rse-within-a-stream-slot whose relation2 alias
    /// text is `"ALIAS" "PUBLIC"."NAME"` - the schema-qualified
    /// underlying table rides along (probed); the WHOLE derived table
    /// has ONE context, shared by inner and outer references
    derived: Option<Box<Derived>>,
    /// inside a SUBROUTINE body every stream emits blr_relation3
    /// with an explicit schema and empty package (probed)
    sub: bool,
    /// inside a CURSOR's rse every stream - subquery streams
    /// included - carries the cursor's concatenated alias: the
    /// cursor name paired with the stream's alias or its
    /// schema-qualified name (probed); stamped post-parse
    cur: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
struct Derived {
    wher: Option<Bool>,
    /// the derived column list as (outer name, inner value): a pass-through
    /// column maps to itself, `col [AS] alias` maps the ALIAS to the inner
    /// column, an expression item to the expression - which every outer
    /// reference wraps in blr_derived_expr over the shared context
    /// (measured: `SELECT X + 1 FROM (SELECT N + 1 X FROM T) D` is
    /// `add(derived_expr(ctx, add(N, 1)), 1)`); outer references translate
    /// at the SAME context, the derived table having none of its own
    cols: Vec<(String, DCol)>,
    /// the inner relation's own alias: the nested relation2's alias text
    /// is then `"D" "A"` instead of `"D" "PUBLIC"."T"` (measured)
    inner_alias: Option<String>,
    /// the inner select's FIRST / SKIP, WHERE (`wher`), ORDER BY and
    /// DISTINCT (blr_project over the items) - inside the nested rse in
    /// that order (measured)
    first: Option<Val>,
    skip: Option<Val>,
    sort: Vec<(bool, Val)>,
    project: Option<Vec<Val>>,
    /// an AGGREGATE inside: the nested rse's stream is then the aggregate
    /// node over the relation (measured) - it takes the context AFTER the
    /// derived table's, so such a stream occupies TWO context slots; the
    /// outer columns read its map by fid
    agg: Option<DerivedAgg>,
    /// WINDOWS inside: the nested rse's stream is then blr_window over the
    /// relation (its WHERE inside), the windows taking the contexts after
    /// the relation's; the outer columns read their maps by fid (measured)
    wins: Vec<Win>,
}

#[derive(Clone, Debug, PartialEq)]
struct DerivedAgg {
    group_keys: Vec<Val>,
    map: Vec<MapEntry>,
    having: Option<Bool>,
}

#[derive(Clone, Debug, PartialEq)]
enum DCol {
    Col(String),
    Expr(Val),
    /// a map fid of the derived table's aggregate, read as is
    Fid(Val),
}

/// One slot of an aggregate's blr_map: a group-key value or an
/// aggregate function (verb + optional operand) - or, in a WINDOW's
/// map, a named function (blr_agg_function, zero arguments).
#[derive(Clone, Debug, PartialEq)]
enum MapEntry {
    Key(Val),
    Agg(u8, Option<Val>),
    Fn(String, Vec<Val>),
}

struct P<'a> {
    t: &'a [Tok],
    i: usize,
    streams: Vec<Stream>,
    /// the aggregate map under construction (procedure aggregate
    /// mode); HAVING's aggregate calls dedup against it - a
    /// structurally equal entry REUSES its slot (probed) - and new
    /// ones append
    agg_map: Vec<MapEntry>,
    /// set while parsing HAVING: aggregate calls in func() resolve
    /// to blr_fid slots against agg_map
    agg_mode: bool,
    /// set while a FOR SELECT item is parsed: (the stream depth, the
    /// stream context) - a window call met in func() at that depth is
    /// captured into `win_found` as a [Val::WinRef]
    win_cap: Option<(usize, u8)>,
    win_found: Vec<WinSpec>,
    /// the procedure's INPUT parameter names, in message-0 order;
    /// `:name` in an expression resolves against this
    in_params: Vec<String>,
    /// local variable names declared in a trigger body, in
    /// declaration order; a bare name resolves here FIRST
    local_vars: Vec<String>,
    /// the next free label number (0 is the body wrapper's)
    next_label: u8,
    /// labels of the loops enclosing the statement being parsed, innermost
    /// last - a bare LEAVE / CONTINUE targets `loop_labels.last()`, a
    /// labelled one the entry whose name matches (an outer loop by name)
    loop_labels: Vec<(Option<String>, u8)>,
    /// a `<name>:` label seen just before a loop, consumed when the loop
    /// pushes its entry
    pending_loop_label: Option<String>,
    /// procedure-body mode: SUSPEND and (FOR) SELECT become
    /// statements; the number of output parameters shapes the sends
    proc: Option<usize>,
    /// the current select's aggregate context (stream ctx + 1) -
    /// what HAVING/ORDER BY fids address
    agg_fid_ctx: u8,
    /// domain-validation mode: VALUE means blr_fid(0, 0)
    domain_value: bool,
    /// declared cursor names in declaration order (their numbers)
    cursors: Vec<String>,
    cursor_decls: Vec<CursorDecl>,
    /// FOR SELECT ... AS CURSOR names in scope: (name, ctx, table) -
    /// pushed around the DO body, targets for WHERE CURRENT OF
    for_cursors: Vec<(String, u8, String)>,
    /// while parsing a MERGE's ON/SET/VALUES or a JOINed FOR
    /// SELECT's clauses: the half-open RANGE of stream indexes
    /// qualified names may bind to - and bare column names refuse
    /// (catalog-free)
    merge_scope: Option<(usize, usize)>,
    /// a FUNCTION body: RETURN allowed, SUSPEND refused
    in_func: bool,
    /// a SUBROUTINE body: nested subroutine declarations refuse
    in_sub: bool,
    /// a SUSPEND was parsed - the subproc_decl's selectable flag
    saw_suspend: bool,
    /// inside a body-statement SUBQUERY: the enclosing statement's
    /// stream index - visible to qualified names (probed)
    host: Option<usize>,
    /// WITH ctes: (name, body token span start, end, used) - a FROM
    /// reference expands one as a DERIVED table with the cte name as
    /// alias (probed: the engine inlines exactly that); each cte
    /// must be referenced exactly once
    ctes: Vec<(String, usize, usize, bool)>,
    /// compiled subroutine declaration blobs, spliced in source order
    sub_decls: Vec<Vec<u8>>,
    /// DECLAREd sub-procedures in scope: (name, ins, outs)
    sub_procs: Vec<(String, usize, usize)>,
    /// DECLAREd sub-functions in scope: (name, args)
    sub_funcs: Vec<(String, usize)>,
    /// context of stream index 0: 1 in view BLR, 0 in procedure
    /// bodies (probed - the FOR SELECT stream is context 0)
    base: u8,
    /// how many of `streams` belong to the OUTER FROM (set when the
    /// WHERE begins); subquery streams keep their context ids but
    /// never become visible to outer-scope bare names
    outer: Option<usize>,
    /// the stream index of the subquery currently being parsed - a
    /// bare name inside a subquery binds to the subquery's OWN stream
    /// (the innermost-scope-first rule; an outer reference must be
    /// qualified)
    sub: Option<usize>,
    /// when compiling a PACKAGE BODY member: the package's own name, so an
    /// UNQUALIFIED call to a sibling member (`DBL(...)` inside package PK)
    /// compiles to blr_function2 with THIS package - what the engine emits
    package: Option<String>,
    /// the sibling FUNCTION members (uppercased name, input arity) an
    /// unqualified value call may bind to inside a package body; empty
    /// outside one. Procedures are NOT here - a bare `P(...)` in value
    /// position is not a sibling function and refuses, as the engine does.
    pkg_members: Vec<(String, usize)>,
    /// plain (non-packaged) user functions visible to the body - name
    /// (uppercased) and input arity - so a bare `F(...)` in value position
    /// binds to blr_function. Passed from the catalog by the server; empty
    /// when the caller has no catalog (the synthetic describe compiles).
    /// Each entry is (name, TOTAL arity, REQUIRED arity) - required is the
    /// inputs without a DEFAULT, so a body call may omit the defaulted tail.
    plain_funcs: Vec<(String, usize, usize)>,
    /// set when the body binds a bare plain user-function call (Val::Fn) -
    /// such a body must run through the exe executor (the arithmetic-only
    /// source interpreter cannot call a function), so the server refuses it
    /// if exe cannot convert the compiled BLR (a generator, etc.)
    saw_user_fn: bool,
}

impl<'a> P<'a> {
    /// a parser over `t` starting at 0 with every scope empty - the
    /// procedure-body default (base 0, no outer streams)
    fn fresh(t: &'a [Tok]) -> P<'a> {
        P {
            t,
            i: 0,
            streams: Vec::new(),
            base: 0,
            outer: None,
            sub: None,
            agg_map: Vec::new(),
            agg_mode: false,
            win_cap: None,
            win_found: Vec::new(),
            in_params: Vec::new(),
            local_vars: Vec::new(),
            next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
            proc: None,
            agg_fid_ctx: 1,
            domain_value: false,
            cursors: Vec::new(),
            cursor_decls: Vec::new(),
            for_cursors: Vec::new(),
            merge_scope: None,
            in_func: false,
            in_sub: false,
            saw_suspend: false,
            host: None,
            ctes: Vec::new(),
            sub_decls: Vec::new(),
            sub_procs: Vec::new(),
            sub_funcs: Vec::new(),
        }
    }

    /// `FOR UPDATE [OF <col> [, ..]]` - consumed and dropped: the engine's
    /// BLR is byte-for-byte the clause-less one (RDB$PROCEDURE_BLR on
    /// 2196, with and without `OF B`); only `WITH LOCK` writes a byte. A
    /// FOR not followed by UPDATE is left where it is.
    fn skip_for_update(&mut self) -> Option<()> {
        if !(matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "FOR")
            && matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "UPDATE"))
        {
            return Some(());
        }
        self.i += 2;
        if self.kw("OF") {
            loop {
                let Some(Tok::Ident(_)) = self.t.get(self.i) else { return None };
                self.i += 1;
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        Some(())
    }

    fn kw(&mut self, w: &str) -> bool {
        if matches!(self.t.get(self.i), Some(Tok::Ident(x)) if x == w) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    /// Resolve a field's stream context. Qualified names match a
    /// VISIBLE stream's ALIAS (which shadows the table name) or its
    /// table name - visible means the outer FROM streams plus, inside
    /// a subquery, that subquery's own stream. A bare name inside a
    /// subquery binds to the subquery's OWN stream (the
    /// innermost-scope-first rule; an outer reference must be
    /// qualified); a bare name in the outer scope is legal only with
    /// ONE outer stream - the engine resolves bare multi-stream names
    /// through the catalog, which this catalog-free compiler refuses
    /// rather than guessing.
    fn field(&self, qualifier: Option<&str>, name: &str) -> Option<Val> {
        // Which stream a reference names (then the tail translates a
        // DERIVED stream's outer name). A stream answers to its alias, else
        // to its relation's name - but an ALIAS-LESS DERIVED table answers to
        // no qualifier at all (the engine's -206 for `SELECT X.ID FROM
        // (SELECT ID FROM T)`); a bare name belongs to the one stream whose
        // relation has the column, or whose DERIVED list names it. Inside a
        // MERGE / JOIN scope only the scope's streams are asked; a subquery
        // asks its own stream first, then the host's.
        let hits_q = |st: &Stream, q: &str| {
            st.alias.as_deref().map_or(st.derived.is_none() && st.name == q, |a| a == q)
        };
        let has_col = |st: &Stream| match &st.derived {
            None => catalog_has(&st.name, name),
            Some(d) => d.cols.iter().any(|(o, _)| o == name),
        };
        let n_outer = self.outer.unwrap_or(self.streams.len());
        let ctx = if let Some((start, end)) = self.merge_scope {
            match qualifier {
                None => {
                    let hits: Vec<usize> = (start..end).filter(|&i| has_col(&self.streams[i])).collect();
                    if hits.len() != 1 {
                        return None;
                    }
                    hits[0] as u8 + self.base
                }
                Some(q) => {
                    let idx = (start..end).find(|&i| hits_q(&self.streams[i], q))?;
                    idx as u8 + self.base
                }
            }
        } else {
            match qualifier {
                Some(q) => {
                    let hit = |st: &Stream| hits_q(st, q);
                    let idx = self
                        .streams
                        .iter()
                        .take(n_outer)
                        .position(hit)
                        .or_else(|| self.host.filter(|&hi| hit(&self.streams[hi])))
                        .or_else(|| self.sub.filter(|&si| hit(&self.streams[si])))?;
                    idx as u8 + self.base
                }
                None => match self.sub {
                    Some(si) => si as u8 + self.base,
                    None => {
                        if n_outer != 1 {
                            let hits: Vec<usize> =
                                (0..n_outer).filter(|&i| has_col(&self.streams[i])).collect();
                            if hits.len() != 1 {
                                return None;
                            }
                            hits[0] as u8 + self.base
                        } else {
                            self.base
                        }
                    }
                },
            }
        };
        let idx = (ctx - self.base) as usize;
        if let Some(d) = &self.streams[idx].derived {
            let (_, inner) = d.cols.iter().find(|(o, _)| o == name)?;
            // an expression item wraps over the context its fields live in:
            // the relation's, or the inner aggregate's (ctx + 1)
            let expr_ctx = if d.agg.is_some() { ctx + 1 } else { ctx };
            return Some(match inner {
                DCol::Col(n) => Val::Field(ctx, n.clone()),
                DCol::Expr(e) => Val::DerivedWrap(expr_ctx, Box::new(e.clone())),
                DCol::Fid(v) => v.clone(),
            });
        }
        Some(Val::Field(ctx, name.to_string()))
    }

    /// `TABLE [alias]` in a FROM clause or a subquery, or a derived
    /// table `(SELECT cols FROM TABLE [WHERE ...]) ALIAS`
    fn stream_item(&mut self) -> Option<Stream> {
        if matches!(self.t.get(self.i), Some(Tok::LParen))
            && matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SELECT")
        {
            return self.derived_item();
        }
        // a WITH cte referenced by name expands as a DERIVED table
        // with the cte name as its alias (probed); one use each
        if let Some(Tok::Ident(w)) = self.t.get(self.i) {
            let hit = self
                .ctes
                .iter()
                .position(|(n, ..)| n == w)
                .map(|ci| (ci, self.ctes[ci].clone()));
            if let Some((ci, (name, start, end, used))) = hit {
                if used {
                    return None; // a second reference: unprobed
                }
                self.ctes[ci].3 = true;
                let after = self.i + 1;
                self.i = start;
                let st = self.derived_body(name)?;
                if self.i != end {
                    return None;
                }
                self.i = after;
                return Some(st);
            }
        }
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        self.i += 1;
        // `name(args)`: a selectable procedure as the source
        let proc_args = if matches!(self.t.get(self.i), Some(Tok::LParen)) {
            self.i += 1;
            let mut args = Vec::new();
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                loop {
                    args.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => break,
                        _ => return None,
                    }
                }
            }
            self.i += 1; // )
            Some(args)
        } else {
            None
        };
        let alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        Some(Stream { name, alias, derived: None, sub: self.in_sub, cur: None, proc_args })
    }

    /// A derived table: pass-through column list, ONE underlying
    /// table, an optional inner WHERE (whose bare names bind to the
    /// derived stream - it has the only visible context), a REQUIRED
    /// alias. The stream is pushed while the inner WHERE parses (its
    /// fields need the context id) and popped for the caller to
    /// re-push at the same index.
    fn derived_item(&mut self) -> Option<Stream> {
        self.i += 1; // (
        let st = self.derived_body(String::new())?;
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        // an alias-less derived table nests a plain blr_relation (measured)
        let alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        Some(Stream { alias, ..st })
    }

    /// The body of a derived table or a WITH cte: `SELECT cols FROM
    /// tbl [WHERE ...]` - the resulting stream carries the given
    /// alias and the recorded column pairs.
    /// The inner select of a derived table (or a CTE body), self.i on its
    /// SELECT. Measured on 2196: the whole of it nests as ONE blr_rse
    /// standing as a stream - FIRST, SKIP, the WHERE, the ORDER BY and a
    /// DISTINCT's blr_project in that order inside it; the inner relation
    /// takes the derived table's context, aliased `"D" "PUBLIC"."T"` (or
    /// `"D" "A"` over an inner alias); an item's expression is NOT stored
    /// here but at every outer reference ([DCol]). Parsed in two phases
    /// like a statement's select list: the FROM first, so the items see
    /// their stream. Still refused: `*`, an aggregate or a UNION or a join
    /// inside, a derived table in a subroutine, ORDER BY an ordinal.
    fn derived_body(&mut self, alias: String) -> Option<Stream> {
        if self.in_sub {
            return None; // derived tables in subroutines: unprobed
        }
        if !self.kw("SELECT") {
            return None;
        }
        let mut first = None;
        let mut skip = None;
        if self.kw("FIRST") {
            first = Some(self.limit_operand()?);
        }
        if self.kw("SKIP") {
            skip = Some(self.limit_operand()?);
        }
        let distinct = self.kw("DISTINCT");
        let list_start = self.i;
        let mut depth = 0i32;
        let list_end = loop {
            match self.t.get(self.i)? {
                Tok::LParen => {
                    depth += 1;
                    self.i += 1;
                }
                Tok::RParen => {
                    if depth == 0 {
                        return None;
                    }
                    depth -= 1;
                    self.i += 1;
                }
                Tok::Ident(w) if w == "FROM" && depth == 0 => break self.i,
                _ => self.i += 1,
            }
        };
        self.i = list_end + 1;
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        self.i += 1;
        let inner_alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        let after_from = self.i;
        self.streams.push(Stream {
            name: name.clone(),
            alias: inner_alias.clone(),
            derived: None,
            sub: self.in_sub,
            cur: None,
            proc_args: None,
        });
        let si = self.streams.len() - 1;
        let saved = self.sub.replace(si);
        let inner_ctx = si as u8 + self.base;
        // an AGGREGATE inside (an aggregate item, or a GROUP BY after the
        // FROM): the items parse in aggregate mode against a map of their
        // own, the aggregate taking the context after the relation's
        let agg_inner = {
            // (an aggregate verb followed by OVER is a WINDOW call)
            let mut found = (list_start..list_end).any(|k| {
                matches!(self.t.get(k), Some(Tok::Ident(w)) if matches!(w.as_str(), "COUNT" | "SUM" | "AVG" | "MIN" | "MAX"))
                    && matches!(self.t.get(k + 1), Some(Tok::LParen))
                    && self.window_call_end(k).is_none()
            });
            let mut j = after_from;
            let mut depth = 0i32;
            while let Some(t) = self.t.get(j) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => {
                        if depth == 0 {
                            break;
                        }
                        depth -= 1;
                    }
                    Tok::Ident(w) if depth == 0 && w == "GROUP" => {
                        found = true;
                        break;
                    }
                    Tok::Semi => break,
                    _ => {}
                }
                j += 1;
            }
            found
        };
        if agg_inner && (first.is_some() || skip.is_some() || distinct) {
            return None; // FIRST / SKIP / DISTINCT over an inner aggregate: unprobed
        }
        // WINDOWS inside: every item reads the window streams (measured);
        // FIRST / SKIP / DISTINCT beside them, or over an inner aggregate:
        // unprobed
        let win_inner = (list_start..list_end).any(|k| matches!(self.t.get(k), Some(Tok::Ident(w)) if w == "OVER"));
        if win_inner && (agg_inner || first.is_some() || skip.is_some() || distinct) {
            self.sub = saved;
            self.streams.pop();
            return None;
        }
        let outer_found = std::mem::take(&mut self.win_found);
        let saved_agg = (std::mem::take(&mut self.agg_map), self.agg_fid_ctx, self.agg_mode);
        let agg_ctx = inner_ctx + 1;
        if agg_inner {
            self.agg_fid_ctx = agg_ctx;
            self.agg_mode = true;
        }
        let restore_agg = |p: &mut Self, saved: (Vec<MapEntry>, u8, bool)| {
            p.agg_map = saved.0;
            p.agg_fid_ctx = saved.1;
            p.agg_mode = saved.2;
        };
        // the items, against the inner stream
        self.i = list_start;
        let mut cols: Vec<(String, DCol)> = Vec::new();
        let mut raw_items: Vec<(String, Val)> = Vec::new();
        let mut project: Vec<Val> = Vec::new();
        let mut any_expr = false;
        loop {
            // `*` alone, or `<inner stream>.*`: the relation's columns in
            // field-position order, as the hand-written list (measured)
            let star = match (self.t.get(self.i), self.t.get(self.i + 1), self.t.get(self.i + 2)) {
                (Some(Tok::Star), _, _) => Some((None, 1usize)),
                (Some(Tok::Ident(q)), Some(Tok::Dot), Some(Tok::Star)) => Some((Some(q.clone()), 3)),
                _ => None,
            };
            if let Some((q, width)) = star {
                let bare_alone = q.is_none() && self.i == list_start && self.i + 1 == list_end;
                let names_it = match &q {
                    None => true,
                    Some(q) => inner_alias.as_deref().map_or(*q == name, |a| a == q),
                };
                let ok = !agg_inner && !win_inner && (q.is_some() || bare_alone) && names_it;
                let Some(expanded) = catalog_columns(&name).filter(|_| ok) else {
                    restore_agg(self, saved_agg);
                    return None;
                };
                for n in expanded {
                    project.push(Val::Field(inner_ctx, n.clone()));
                    cols.push((n.clone(), DCol::Col(n)));
                }
                self.i += width;
                match self.t.get(self.i) {
                    Some(Tok::Comma) => {
                        self.i += 1;
                        continue;
                    }
                    Some(Tok::Ident(w)) if w == "FROM" => break,
                    _ => {
                        restore_agg(self, saved_agg);
                        return None;
                    }
                }
            }
            if win_inner {
                self.win_cap = Some((self.streams.len(), inner_ctx));
            }
            let v = self.val();
            self.win_cap = None;
            let Some(v) = v else {
                restore_agg(self, saved_agg);
                return None;
            };
            if agg_inner {
                // the plain fields an item names take their key slots in
                // order of appearance
                let mut ks = Vec::new();
                collect_fields(&v, &mut ks);
                for k in ks {
                    let e = MapEntry::Key(k);
                    if !self.agg_map.contains(&e) {
                        self.agg_map.push(e);
                    }
                }
            }
            let outer = if self.kw("AS") {
                let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(a) {
                    return None;
                }
                let a = a.clone();
                self.i += 1;
                a
            } else if let Some(Tok::Ident(a)) = self.t.get(self.i).filter(|t| matches!(t, Tok::Ident(a) if !is_keyword(a))) {
                let a = a.clone();
                self.i += 1;
                a
            } else {
                match &v {
                    Val::Field(_, inner) => inner.clone(),
                    _ => return None, // an expression needs its name
                }
            };
            if agg_inner || win_inner {
                raw_items.push((outer, v));
            } else {
                let dcol = match &v {
                    Val::Field(_, inner) => DCol::Col(inner.clone()),
                    other => {
                        any_expr = true;
                        DCol::Expr(other.clone())
                    }
                };
                project.push(v);
                cols.push((outer, dcol));
            }
            match self.t.get(self.i) {
                Some(Tok::Comma) => self.i += 1,
                Some(Tok::Ident(w)) if w == "FROM" => break,
                _ => {
                    restore_agg(self, saved_agg);
                    return None;
                }
            }
        }
        if self.i != list_end {
            restore_agg(self, saved_agg);
            return None;
        }
        self.i = after_from;
        // the WHERE reads the relation's columns, never the map
        let saved_mode_w = self.agg_mode;
        self.agg_mode = false;
        let wher = if self.kw("WHERE") {
            match self.bool_or() {
                Some(b) => Some(b),
                None => {
                    restore_agg(self, saved_agg);
                    return None;
                }
            }
        } else {
            None
        };
        self.agg_mode = saved_mode_w;
        let mut agg = None;
        if agg_inner {
            let mut group_keys: Vec<Val> = Vec::new();
            if self.kw("GROUP") {
                if !self.kw("BY") {
                    restore_agg(self, saved_agg);
                    return None;
                }
                self.agg_mode = false;
                loop {
                    match self.val() {
                        Some(k) => group_keys.push(k),
                        None => {
                            restore_agg(self, saved_agg);
                            return None;
                        }
                    }
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                    } else {
                        break;
                    }
                }
                self.agg_mode = true;
            }
            let mut gfields: Vec<Val> = Vec::new();
            for k in &group_keys {
                collect_fields(k, &mut gfields);
            }
            // every item lifts to the aggregate's map
            for (outer, v) in raw_items.drain(..) {
                let dcol = match &v {
                    Val::Fid(..) => DCol::Fid(v.clone()),
                    Val::Field(..) => match rebuild_over_keys(&mut self.agg_map, &v, &gfields, agg_ctx) {
                        Some(f) => DCol::Fid(f),
                        None => {
                            restore_agg(self, saved_agg);
                            return None;
                        }
                    },
                    other => match lift_over_agg(&mut self.agg_map, other, &gfields, agg_ctx) {
                        Some(e) => DCol::Expr(e),
                        None => {
                            restore_agg(self, saved_agg);
                            return None;
                        }
                    },
                };
                cols.push((outer, dcol));
            }
            let having = if self.kw("HAVING") {
                let b = self.bool_or().and_then(|b| map_bool_to_fids(&self.agg_map, b, agg_ctx));
                match b {
                    Some(b) => Some(b),
                    None => {
                        restore_agg(self, saved_agg);
                        return None;
                    }
                }
            } else {
                None
            };
            agg = Some(DerivedAgg { group_keys, map: std::mem::take(&mut self.agg_map), having });
        }
        // the windows, built exactly as a statement's: every item rebuilt
        // over them in order (a column into the default window, a call into
        // its spec's), contexts after the relation's, partition keys remapped
        let mut wins: Vec<Win> = Vec::new();
        if win_inner {
            let found = std::mem::take(&mut self.win_found);
            let mut rebuilt = Vec::new();
            for (outer, v) in raw_items.drain(..) {
                let Some(r) = rebuild_win_expr(&mut wins, &v, &found) else {
                    restore_agg(self, saved_agg);
                    return None;
                };
                rebuilt.push((outer, r));
            }
            for (k, w) in wins.iter_mut().enumerate() {
                w.ctx = inner_ctx + 1 + k as u8;
                let keys = w.part.clone();
                for key in keys {
                    let mut gf = Vec::new();
                    collect_fields_deep(&key, &mut gf);
                    let Some(r) = rebuild_over_keys(&mut w.map, &key, &gf, w.ctx) else {
                        restore_agg(self, saved_agg);
                        return None;
                    };
                    w.remap.push(r);
                }
            }
            if wins.is_empty() {
                restore_agg(self, saved_agg);
                return None;
            }
            let win_ctxs: Vec<u8> = wins.iter().map(|w| w.ctx).collect();
            for (outer, r) in rebuilt {
                let Some(f) = patch_fid_win(&r, &wins) else {
                    restore_agg(self, saved_agg);
                    return None;
                };
                // a column reads its fid; an expression (or a constant) is
                // wrapped in blr_derived_expr over EVERY window context
                let f = match f {
                    Val::Fid(..) => f,
                    other => Val::DerivedWrapN(win_ctxs.clone(), Box::new(other)),
                };
                cols.push((outer, DCol::Fid(f)));
            }
        }
        self.win_found = outer_found;
        let mut sort: Vec<(bool, Val)> = Vec::new();
        if self.kw("ORDER") {
            if !self.kw("BY") {
                return None;
            }
            loop {
                let key = self.val()?;
                if matches!(key, Val::Int(_) | Val::Int64(_) | Val::Dec(..)) {
                    return None; // an ordinal inside a derived table: unprobed
                }
                let descending = if self.kw("DESC") {
                    true
                } else {
                    let _ = self.kw("ASC");
                    false
                };
                let key = self.nulls_placement(key)?;
                sort.push((descending, key));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        self.sub = saved;
        self.streams.pop();
        restore_agg(self, saved_agg);
        if agg.is_some() && !sort.is_empty() {
            return None; // an ORDER BY beside an inner aggregate: unprobed
        }
        if !wins.is_empty() && !sort.is_empty() {
            return None; // an ORDER BY beside inner windows: unprobed
        }
        if distinct && any_expr {
            return None; // a projection over an expression item: unprobed
        }
        // two columns under one name: the engine refuses the statement
        // at prepare (isc_dsql_derived_field_dup_name, -104) - a CREATE
        // PROCEDURE over `(SELECT ID, ID FROM T)` must not be stored
        for (i, (n, _)) in cols.iter().enumerate() {
            if cols[..i].iter().any(|(m, _)| m == n) {
                return None;
            }
        }
        Some(Stream {
            name,
            alias: if alias.is_empty() { None } else { Some(alias) },
            derived: Some(Box::new(Derived {
                wher,
                cols,
                inner_alias,
                first,
                skip,
                sort,
                project: if distinct { Some(project) } else { None },
                agg,
                wins,
            })),
            sub: self.in_sub,
            cur: None,
            proc_args: None,
        })
    }

    /// The select list up to FROM. `Some(cols)` when every item is a
    /// plain (possibly qualified) column - the shape DISTINCT and
    /// UNION need; `None` when the list contains `*` or other
    /// traceless-only shapes.
    fn select_list(&mut self) -> Option<Option<Vec<(Option<String>, String)>>> {
        let mut cols: Option<Vec<(Option<String>, String)>> = Some(Vec::new());
        let mut expect_item = true;
        loop {
            match self.t.get(self.i)? {
                // an AGGREGATE in a view's select list is outside this
                // surface (the RSE would need a group) - refuse, as before
                Tok::Ident(w)
                    if matches!(w.as_str(), "COUNT" | "SUM" | "AVG" | "MIN" | "MAX" | "LIST")
                        && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) =>
                {
                    return None;
                }
                Tok::Ident(w) if w == "FROM" => {
                    self.i += 1;
                    return Some(cols);
                }
                Tok::Ident(w) if !is_keyword(w) => {
                    let a = w.clone();
                    self.i += 1;
                    if !expect_item {
                        // a bare column alias: traceless only
                        cols = None;
                        continue;
                    }
                    if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                        self.i += 1;
                        match self.t.get(self.i) {
                            Some(Tok::Ident(b)) if !is_keyword(b) => {
                                let b = b.clone();
                                self.i += 1;
                                if let Some(c) = &mut cols {
                                    c.push((Some(a), b));
                                }
                            }
                            Some(Tok::Star) => {
                                self.i += 1;
                                cols = None;
                            }
                            _ => return None,
                        }
                    } else if let Some(c) = &mut cols {
                        c.push((None, a));
                    }
                    expect_item = false;
                }
                Tok::Comma => {
                    if expect_item {
                        return None;
                    }
                    self.i += 1;
                    expect_item = true;
                }
                Tok::Star => {
                    self.i += 1;
                    cols = None;
                    expect_item = false;
                }
                // any other token: the item is an EXPRESSION (`V || 'x'`,
                // `UPPER(S)`, `N + 1 AS X`) - not a plain column list; the
                // tokens are skipped depth-aware up to the list's end, the
                // expression itself compiles in compile_view_columns
                Tok::LParen => {
                    let mut depth = 0i32;
                    loop {
                        match self.t.get(self.i)? {
                            Tok::LParen => depth += 1,
                            Tok::RParen => {
                                depth -= 1;
                                if depth == 0 {
                                    self.i += 1;
                                    break;
                                }
                            }
                            _ => {}
                        }
                        self.i += 1;
                    }
                    cols = None;
                    expect_item = false;
                }
                _ => {
                    self.i += 1;
                    cols = None;
                    expect_item = false;
                }
            }
        }
    }

    /// `(SELECT <one column | anything> FROM TABLE [alias]
    /// [WHERE <bool>])`, self.i ON the opening paren. The subquery's
    /// stream JOINS the statement's context numbering; with
    /// `need_col` the single select-list column is resolved (bare -
    /// against the subquery's own stream), without it the list
    /// compiles away exactly like a view's (probed: SELECT 1 and
    /// SELECT * leave no trace).
    /// A FIRST/SKIP operand: a bare integer literal, or a
    /// PARENTHESIZED parameter/variable - the engine's own grammar
    /// (`FIRST :P` is a syntax error THERE too; `FIRST (:P)` compiles
    /// to a bare parameter2 - probed)
    fn limit_operand(&mut self) -> Option<Val> {
        if let Some(Tok::Int(v)) = self.t.get(self.i) {
            let v = i32::try_from(*v).ok()?;
            self.i += 1;
            return Some(Val::Int(v));
        }
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        let v = self.val()?;
        if !matches!(v, Val::InParam(_) | Val::LocalVar(_)) {
            return None; // general limit expressions: unprobed
        }
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        Some(v)
    }

    fn subselect(&mut self, need_col: bool) -> Option<SubQ> {
        self.subselect_ex(need_col, false)
    }

    /// `allow_agg` admits a single aggregate call as the select item
    /// - the SCALAR caller only; quantified/IN comparisons over
    /// aggregate output are unprobed and refuse
    fn subselect_ex(&mut self, need_col: bool, allow_agg: bool) -> Option<SubQ> {
        // a window inside a subquery is the subquery's own: never captured
        // into the outer item
        let saved = self.win_cap.take();
        let r = self.subselect_ex_inner(need_col, allow_agg);
        self.win_cap = saved;
        r
    }

    fn subselect_ex_inner(&mut self, need_col: bool, allow_agg: bool) -> Option<SubQ> {
        if self.outer.is_none() || self.merge_scope.is_some() {
            // a subquery inside an ON clause (or any multi-stream
            // scope) would interleave the stream numbering: unprobed
            return None;
        }
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        if !self.kw("SELECT") {
            return None;
        }
        // a depth-0 UNION before the closing paren makes this a
        // UNION subquery: the union claims THIS context slot, so the
        // lookahead must run before any branch stream numbers (the
        // slice-38 reservation law in subquery clothing)
        {
            let mut depth = 0usize;
            let mut k = self.i;
            let mut has_union = false;
            while let Some(t) = self.t.get(k) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => {
                        if depth == 0 {
                            break;
                        }
                        depth -= 1;
                    }
                    Tok::Ident(w) if depth == 0 && w == "UNION" => {
                        has_union = true;
                        break;
                    }
                    _ => {}
                }
                k += 1;
            }
            if has_union {
                if !need_col {
                    return None; // EXISTS over a union: unprobed
                }
                return self.subselect_union();
            }
        }
        // capture the select list positionally; resolve after the
        // stream exists
        let mut col: Option<(Option<String>, String)> = None;
        let mut agg_raw: Option<(u8, Option<(Option<String>, String)>)> = None;
        // an item that is neither a plain column nor one aggregate
        // call is a full EXPRESSION: record its token span here and
        // jump-parse it AFTER the stream binds (the two-phase parse)
        let mut expr_span: Option<(usize, usize)> = None;
        if need_col {
            let item_start = self.i;
            // find the item's end: the depth-0 FROM
            let mut depth = 0usize;
            let mut fpos = None;
            let mut k = self.i;
            while let Some(t) = self.t.get(k) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => {
                        if depth == 0 {
                            break;
                        }
                        depth -= 1;
                    }
                    Tok::Ident(w) if depth == 0 && w == "FROM" => {
                        fpos = Some(k);
                        break;
                    }
                    _ => {}
                }
                k += 1;
            }
            let fpos = fpos?;
            let simple = matches!(
                &self.t[item_start..fpos],
                [Tok::Ident(_)] | [Tok::Ident(_), Tok::Dot, Tok::Ident(_)]
            ) || matches!(
                (self.t.get(item_start), self.t.get(item_start + 1)),
                (Some(Tok::Ident(a)), Some(Tok::LParen))
                    if matches!(a.as_str(), "COUNT" | "SUM" | "AVG" | "MIN" | "MAX")
            );
            if !simple {
                expr_span = Some((item_start, fpos));
                self.i = fpos;
            }
        }
        if need_col && expr_span.is_none() {
            let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(a) {
                return None;
            }
            let a = a.clone();
            self.i += 1;
            if allow_agg
                && matches!(
                    a.as_str(),
                    "COUNT" | "SUM" | "AVG" | "MIN" | "MAX"
                )
                && matches!(self.t.get(self.i), Some(Tok::LParen))
            {
                self.i += 1;
                // DISTINCT gets the dedicated verbs for COUNT/SUM/
                // AVG; MIN/MAX fold it away (the slice-10 law)
                let distinct = self.kw("DISTINCT");
                let arg = if a == "COUNT"
                    && !distinct
                    && matches!(self.t.get(self.i), Some(Tok::Star))
                {
                    self.i += 1;
                    None
                } else {
                    let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                        return None;
                    };
                    if is_keyword(c) {
                        return None;
                    }
                    let c = c.clone();
                    self.i += 1;
                    if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                        self.i += 1;
                        let Some(Tok::Ident(d)) = self.t.get(self.i) else {
                            return None;
                        };
                        let d = d.clone();
                        self.i += 1;
                        Some((Some(c), d))
                    } else {
                        Some((None, c))
                    }
                };
                if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    return None;
                }
                self.i += 1;
                let verb = match (a.as_str(), distinct) {
                    ("COUNT", false) if arg.is_none() => blr::AGG_COUNT,
                    ("COUNT", false) => blr::AGG_COUNT2,
                    ("COUNT", true) => blr::AGG_COUNT_DISTINCT,
                    ("SUM", false) => blr::AGG_TOTAL,
                    ("SUM", true) => blr::AGG_TOTAL_DISTINCT,
                    ("AVG", false) => blr::AGG_AVERAGE,
                    ("AVG", true) => blr::AGG_AVERAGE_DISTINCT,
                    ("MIN", _) => blr::AGG_MIN,
                    (_, _) => blr::AGG_MAX,
                };
                agg_raw = Some((verb, arg));
            } else if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                self.i += 1;
                let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                    return None;
                };
                col = Some((Some(a), b.clone()));
                self.i += 1;
            } else {
                col = Some((None, a));
            }
        } else {
            // EXISTS/SINGULAR: skip a traceless select list
            loop {
                match self.t.get(self.i)? {
                    Tok::Ident(w) if w == "FROM" => break,
                    Tok::Ident(w) if !is_keyword(w) => self.i += 1,
                    Tok::Int(_) | Tok::Comma | Tok::Dot | Tok::Star => self.i += 1,
                    _ => return None,
                }
            }
        }
        if !self.kw("FROM") {
            return None;
        }
        let stream = self.stream_item()?;
        self.streams.push(stream.clone());
        let si = self.streams.len() - 1;
        // the subquery stream takes the NEXT context id in the
        // statement's numbering - view and body alike (probed: a
        // body FOR's EXISTS put its stream at ctx 1 over the FOR's 0)
        let ctx = si as u8 + self.base;
        // an aggregate claims the slot after its stream, as always
        let agg_slot = if agg_raw.is_some() {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            (self.streams.len() - 1) as u8 + self.base
        } else {
            0
        };
        // the subquery scope: bare names bind to ITS stream; the
        // ENCLOSING statement's stream stays visible to QUALIFIED
        // names (probed: the subquery WHERE correlated on the FOR's
        // table by name)
        let saved = self.sub.replace(si);
        let saved_host = self.host;
        self.host = saved;
        let col = match col {
            None => None,
            Some((q, n)) => Some(self.field(q.as_deref(), &n)?),
        };
        let expr = match expr_span {
            None => None,
            Some((start, end)) => {
                let cur = self.i;
                self.i = start;
                let v = self.val()?;
                if self.i != end {
                    return None; // the item did not parse to FROM
                }
                self.i = cur;
                Some(Val::DerivedWrap(ctx, Box::new(v)))
            }
        };
        let agg = match agg_raw {
            None => None,
            Some((verb, None)) => Some((verb, None, agg_slot)),
            Some((verb, Some((q, n)))) => {
                Some((verb, Some(self.field(q.as_deref(), &n)?), agg_slot))
            }
        };
        let wher = if self.kw("WHERE") {
            Some(Box::new(self.bool_or()?))
        } else {
            None
        };
        self.sub = saved;
        self.host = saved_host;
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None; // joins, comma-FROM etc. in a subquery: unconverted
        }
        self.i += 1;
        Some(SubQ {
            stream,
            ctx,
            wher,
            col,
            expr,
            agg,
            union_: None,
        })
    }

    /// The UNION ALL subquery: `(SELECT c FROM t [WHERE ...] UNION
    /// ALL SELECT ...)`. The union takes the reserved context slot,
    /// each branch stream the next one; branch items are plain
    /// columns at their own branch's scope. The distinct form is
    /// unprobed and refuses.
    fn subselect_union(&mut self) -> Option<SubQ> {
        // reserve the union's slot before any branch stream numbers
        self.streams.push(Stream {
            name: String::new(),
            alias: None,
            derived: None,
            sub: self.in_sub,
            cur: None,
            proc_args: None,
        });
        let ctx = (self.streams.len() - 1) as u8 + self.base;
        let mut branches: Vec<(Stream, u8, Option<Box<Bool>>, Val)> = Vec::new();
        loop {
            // one branch: <col> FROM <stream> [WHERE ...]
            let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(a) {
                return None;
            }
            let a = a.clone();
            self.i += 1;
            let col = if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                self.i += 1;
                let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                    return None;
                };
                let b = b.clone();
                self.i += 1;
                (Some(a), b)
            } else {
                (None, a)
            };
            // an optional trailing +/-/* literal: dialect-3 integer
            // arithmetic types the item int64 and UNIFIES the union
            // there (probed - the plain branches then wrap in
            // cast(int64))
            let arith = match self.t.get(self.i) {
                Some(Tok::Plus) => Some('+'),
                Some(Tok::Minus) => Some('-'),
                Some(Tok::Star) => Some('*'),
                _ => None,
            };
            let arith = match arith {
                None => None,
                Some(op) => {
                    self.i += 1;
                    let Some(Tok::Int(n)) = self.t.get(self.i) else {
                        return None;
                    };
                    let n = i32::try_from(*n).ok()?;
                    self.i += 1;
                    Some((op, n))
                }
            };
            if !self.kw("FROM") {
                return None;
            }
            let stream = self.stream_item()?;
            if stream.derived.is_some() {
                return None; // derived branches: unprobed
            }
            self.streams.push(stream.clone());
            let si = self.streams.len() - 1;
            let bctx = si as u8 + self.base;
            let saved = self.sub.replace(si);
            let saved_host = self.host;
            self.host = saved;
            let base_item = self.field(col.0.as_deref(), &col.1)?;
            let item = match arith {
                None => base_item,
                Some(('+', n)) => {
                    Val::Add(Box::new(base_item), Box::new(Val::Int(n)))
                }
                Some(('-', n)) => {
                    Val::Sub(Box::new(base_item), Box::new(Val::Int(n)))
                }
                Some((_, n)) => {
                    Val::Mul(Box::new(base_item), Box::new(Val::Int(n)))
                }
            };
            let wher = if self.kw("WHERE") {
                Some(Box::new(self.bool_or()?))
            } else {
                None
            };
            self.sub = saved;
            self.host = saved_host;
            branches.push((stream, bctx, wher, item));
            if self.kw("UNION") {
                if !self.kw("ALL") {
                    return None; // the distinct form: unprobed
                }
                if !self.kw("SELECT") {
                    return None;
                }
                continue;
            }
            break;
        }
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        if branches.len() < 2 {
            return None;
        }
        // the unification law: one arithmetic branch types the union
        // int64, and every PLAIN branch wraps in cast(int64)
        let unified = branches
            .iter()
            .any(|(.., item)| matches!(item, Val::Add(..) | Val::Sub(..) | Val::Mul(..)));
        if unified {
            for (.., item) in branches.iter_mut() {
                if matches!(item, Val::Field(..)) {
                    let taken = std::mem::replace(item, Val::Int(0));
                    *item = Val::CastInt64(Box::new(taken));
                }
            }
        }
        Some(SubQ {
            stream: Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            },
            ctx,
            wher: None,
            col: None,
            expr: None,
            agg: None,
            union_: Some(SubUnion { branches }),
        })
    }

    /// expression grammar mirroring the engine's precedence:
    /// `+`/`-` over `*`/`/` over unary `-` over `||` over atoms
    /// `field[i, j]`: an ARRAY element of the field just parsed, when a
    /// subscript list follows (the employee sample's SHOW_LANGS reads
    /// `language_req[:i]`); the field itself otherwise.
    fn array_suffix(&mut self, base: Val) -> Option<Val> {
        if !matches!(self.t.get(self.i), Some(Tok::LBracket)) {
            return Some(base);
        }
        self.i += 1;
        let mut subs = vec![self.val()?];
        while matches!(self.t.get(self.i), Some(Tok::Comma)) {
            self.i += 1;
            subs.push(self.val()?);
        }
        if !matches!(self.t.get(self.i), Some(Tok::RBracket)) {
            return None;
        }
        self.i += 1;
        Some(Val::ArrayElem(Box::new(base), subs))
    }

    fn val(&mut self) -> Option<Val> {
        let mut left = self.val_mul()?;
        loop {
            match self.t.get(self.i) {
                Some(Tok::Plus) => {
                    self.i += 1;
                    left = Val::Add(Box::new(left), Box::new(self.val_mul()?));
                }
                Some(Tok::Minus) => {
                    self.i += 1;
                    left = Val::Sub(Box::new(left), Box::new(self.val_mul()?));
                }
                _ => return Some(left),
            }
        }
    }

    fn val_mul(&mut self) -> Option<Val> {
        let mut left = self.val_unary()?;
        loop {
            match self.t.get(self.i) {
                Some(Tok::Star) => {
                    self.i += 1;
                    left = Val::Mul(Box::new(left), Box::new(self.val_unary()?));
                }
                Some(Tok::Slash) => {
                    self.i += 1;
                    left = Val::Div(Box::new(left), Box::new(self.val_unary()?));
                }
                _ => return Some(left),
            }
        }
    }

    fn val_unary(&mut self) -> Option<Val> {
        if matches!(self.t.get(self.i), Some(Tok::Minus)) {
            self.i += 1;
            // a sign before a NUMERIC LITERAL folds into it (probed:
            // A = -1 stores the negative literal, no blr_negate);
            // before anything else, blr_negate survives
            return Some(match self.val_unary()? {
                Val::Int(n) => Val::Int(n.checked_neg()?),
                Val::Int64(n) => Val::Int64(n.checked_neg()?),
                Val::Dec(r, sc) => Val::Dec(r.checked_neg()?, sc),
                other => Val::Neg(Box::new(other)),
            });
        }
        if matches!(self.t.get(self.i), Some(Tok::Plus)) {
            self.i += 1;
            return self.val_unary();
        }
        self.val_concat()
    }

    fn val_concat(&mut self) -> Option<Val> {
        let mut left = self.val_atom()?;
        while matches!(self.t.get(self.i), Some(Tok::Concat)) {
            self.i += 1;
            left = Val::Concat(Box::new(left), Box::new(self.val_atom()?));
        }
        Some(left)
    }

    /// An atom, then `COLLATE <name>` after a COLUMN: a cast to the
    /// column's own type with the collation in the text type's high byte
    /// (measured: `U COLLATE UNICODE_CI` over a UTF8 VARCHAR(10) is `83 26
    /// 04 03 28 00 <field>`; a CHAR keeps blr_text2). A literal's COLLATE
    /// is the engine's 22021, an expression's unprobed: both refuse.
    fn val_atom(&mut self) -> Option<Val> {
        let v = self.val_atom_inner()?;
        if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "COLLATE") {
            return Some(v);
        }
        self.i += 1;
        let Some(Tok::Ident(cn)) = self.t.get(self.i) else {
            return None;
        };
        let cn = cn.clone();
        self.i += 1;
        let Val::Field(ctx, name) = &v else {
            return None;
        };
        let d = self.field_dsc(*ctx, name)?;
        let (text, len, cs) = match d {
            Dsc::TextCs(l, cs) => (true, l, cs),
            Dsc::VaryingCs(l, cs) => (false, l, cs),
            Dsc::Text(l) => (true, l, DEFAULT_CS.with(|c| c.get()).0),
            Dsc::Varying(l) => (false, l, DEFAULT_CS.with(|c| c.get()).0),
            _ => return None,
        };
        let coll = collation_id(cs & 0xFF, &cn)?;
        let ttype = (cs & 0xFF) | (coll << 8);
        let dsc = if text { Dsc::TextCs(len, ttype) } else { Dsc::VaryingCs(len, ttype) };
        Some(Val::Cast(dsc, Box::new(v)))
    }

    fn val_atom_inner(&mut self) -> Option<Val> {
        let v = match self.t.get(self.i)? {
            Tok::Ident(x) if x == "CASE" => {
                self.i += 1;
                return self.case_tail();
            }
            Tok::Ident(x) if x == "NULL" => Val::Null,
            Tok::Ident(x) if x == "VALUE" && self.domain_value => Val::Fid(0, 0),
            Tok::Ident(x) if x == "ROW_COUNT" => Val::RowCount,
            Tok::Ident(x) if x == "CURRENT_CONNECTION" => Val::CurrentConnection,
            Tok::Ident(x) if x == "CURRENT_TRANSACTION" => Val::CurrentTransaction,
            // a session context word, NOT a column: compiled as a field it
            // stored `blr_field 'CURRENT_ROLE'` - a view over `"CURRENT_ROLE"
            // = CURRENT_ROLE` compared the column with itself and answered
            // every row, and `S = CURRENT_USER` failed at use
            Tok::Ident(x) if x == "CURRENT_USER" || x == "USER" => Val::UserName,
            Tok::Ident(x) if x == "CURRENT_ROLE" => Val::CurrentRole,
            Tok::Ident(x)
                if matches!(x.as_str(), "DATE" | "TIME" | "TIMESTAMP")
                    && matches!(self.t.get(self.i + 1), Some(Tok::Str(_))) =>
            {
                let Some(Tok::Str(text)) = self.t.get(self.i + 1) else { return None };
                let bytes = temporal_literal_bytes(x, text)?;
                self.i += 2;
                return Some(Val::TemporalLit(bytes));
            }
            Tok::Ident(x) if x == "TRUE" => Val::Bool(true),
            Tok::Ident(x) if x == "FALSE" => Val::Bool(false),
            Tok::Ident(x) if x == "NEXT" => {
                self.i += 1;
                if !(self.kw("VALUE") && self.kw("FOR")) {
                    return None;
                }
                let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(name) {
                    return None;
                }
                let name = name.clone();
                self.i += 1;
                return Some(Val::GenId2(name));
            }
            Tok::Ident(x) if x == "CURRENT_DATE" => Val::CurrentDate,
            Tok::Ident(x) if x == "CURRENT_TIME" => Val::CurrentTime,
            Tok::Ident(x) if x == "CURRENT_TIMESTAMP" => Val::CurrentTimestamp,
            Tok::Colon => {
                // `:name` - an input parameter (message 0) or, in a
                // body, a local variable / output parameter
                self.i += 1;
                let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                    return None;
                };
                if let Some(idx) = self.in_params.iter().position(|n| n == name) {
                    self.i += 1;
                    return Some(Val::InParam(idx as u16));
                }
                let vi = self.local_vars.iter().position(|n| n == name)?;
                self.i += 1;
                return Some(Val::LocalVar(vi as u16));
            }
            // the system functions spelled with a reserved word: a call
            // is the word followed by its paren (a LEFT JOIN never is)
            Tok::Ident(x)
                if matches!(x.as_str(), "LEFT" | "RIGHT" | "POSITION")
                    && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) =>
            {
                let first = x.clone();
                self.i += 1;
                return self.func(&first);
            }
            Tok::Ident(x) if !is_keyword(x) => {
                let first = x.clone();
                self.i += 1;
                if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                    // a call: only the probed built-ins compile; an
                    // unknown name followed by '(' REFUSES (a UDF or
                    // unconverted function must never become a field)
                    return self.func(&first);
                }
                // a bare name resolves against LOCAL VARIABLES first
                // - but only OUTSIDE stream scopes: inside a select,
                // subquery or DML WHERE a bare name is a COLUMN and
                // a variable needs its colon
                if self.sub.is_none()
                    && !matches!(self.t.get(self.i), Some(Tok::Dot))
                {
                    if let Some(vi) =
                        self.local_vars.iter().position(|n| n == &first)
                    {
                        return Some(Val::LocalVar(vi as u16));
                    }
                    // bare input parameters work outside stream
                    // scopes too (probed: IF (I1 > 0) compiles the
                    // message reference)
                    if let Some(pi) =
                        self.in_params.iter().position(|n| n == &first)
                    {
                        return Some(Val::InParam(pi as u16));
                    }
                }
                // a qualified field: IDENT . IDENT - or a PACKAGED
                // function call when a paren follows
                if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                    self.i += 1;
                    let Some(Tok::Ident(f)) = self.t.get(self.i) else {
                        return None;
                    };
                    let f = f.clone();
                    self.i += 1;
                    if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                        self.i += 1;
                        let mut args = Vec::new();
                        if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                            self.i += 1;
                        } else {
                            loop {
                                args.push(self.val()?);
                                match self.t.get(self.i)? {
                                    Tok::Comma => self.i += 1,
                                    Tok::RParen => {
                                        self.i += 1;
                                        break;
                                    }
                                    _ => return None,
                                }
                            }
                        }
                        return Some(Val::PkgFn(first, f, args));
                    }
                    let v = self.field(Some(&first), &f)?;
                    return self.array_suffix(v);
                }
                let v = self.field(None, &first)?;
                return self.array_suffix(v);
            }
            Tok::Int(n) => match i32::try_from(*n) {
                Ok(v) => Val::Int(v),
                Err(_) => Val::Int64(*n),
            },
            Tok::Dec(r, s) => Val::Dec(i32::try_from(*r).ok()?, *s),
            Tok::Double(text) => Val::DoubleLit(text.clone()),
            Tok::Hex(bytes) => Val::Bytes(bytes.clone()),
            Tok::Str(s) => Val::Str(s.clone()),
            Tok::LParen => {
                // a scalar subselect as a value: blr_via(singular)
                if matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SELECT")
                {
                    let sub = self.subselect_ex(true, true)?;
                    if sub.expr.is_some() {
                        // an expression item in a SCALAR subselect:
                        // unprobed (the wrapper is pinned for the
                        // quantified forms only)
                        return None;
                    }
                    return Some(Val::ScalarSub(Box::new(sub)));
                }
                self.i += 1;
                let inner = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    return None;
                }
                self.i += 1;
                return Some(inner);
            }
            _ => return None,
        };
        self.i += 1;
        Some(v)
    }

    /// the built-in functions whose compiled BLR was probed; self.i
    /// sits ON the opening paren
    fn func(&mut self, name: &str) -> Option<Val> {
        // a window call inside a select item (measured: `ROW_NUMBER() OVER
        // (..) + 1`, `CAST(SUM(X) OVER (..) AS ..)`, `COALESCE(SUM(V) OVER
        // (..), 0)`): captured, resolved when the windows are built
        if let Some((depth, wctx)) = self.win_cap {
            if depth == self.streams.len()
                && is_window_name(name)
                && self.window_call_end(self.i - 1).is_some()
            {
                let spec = self.window_call(name, wctx)?;
                self.win_found.push(spec);
                return Some(Val::WinRef((self.win_found.len() - 1) as u16));
            }
        }
        if self.agg_mode
            && matches!(name, "COUNT" | "SUM" | "AVG" | "MIN" | "MAX")
        {
            // inside HAVING: an aggregate resolves to its map slot
            let (verb, arg) = self.parse_agg(name)?;
            let slot = self.agg_slot(verb, arg);
            return Some(Val::Fid(self.agg_fid_ctx, slot));
        }
        // a DECLAREd sub-function shadows nothing the surface knows:
        // parse its counted arguments - a zero-arg call still emits
        // the argument tag with count 0 (probed)
        if let Some(n_args) = self
            .sub_funcs
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, a)| *a)
        {
            self.i += 1; // (
            let mut args = Vec::new();
            if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                self.i += 1;
            } else {
                loop {
                    args.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
            }
            if args.len() != n_args {
                return None;
            }
            return Some(Val::SubFn(name.to_string(), args));
        }
        // an UNQUALIFIED call to a SIBLING package member: inside a package
        // body a bare `DBL(...)` names package member DBL, compiled to
        // blr_function2 with the CURRENT package - byte-identical to the
        // qualified `PK.DBL(...)` (probed against the engine's
        // RDB$FUNCTION_BLR). Only a declared sibling binds this way; any
        // other unknown name still refuses below.
        if let Some(pkg) = self.package.clone() {
            if let Some(&(_, arity)) =
                self.pkg_members.iter().find(|(m, _)| m == name)
            {
                self.i += 1; // (
                let mut args = Vec::new();
                if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    self.i += 1;
                } else {
                    loop {
                        args.push(self.val()?);
                        match self.t.get(self.i)? {
                            Tok::Comma => self.i += 1,
                            Tok::RParen => {
                                self.i += 1;
                                break;
                            }
                            _ => return None,
                        }
                    }
                }
                // the sibling's declared arity must match, as the engine
                // checks at compile - a wrong count refuses the member. A
                // sibling with a defaulted parameter cannot be called here
                // with the tail omitted (a recorded boundary: the header's
                // required arity is not reliably visible at body-compile).
                if args.len() != arity {
                    return None;
                }
                return Some(Val::PkgFn(pkg, name.to_string(), args));
            }
        }
        // a PLAIN user function the catalog knows: a bare `F(...)` binds to
        // blr_function (an unknown name still falls through to the built-in
        // dispatch and refuses there, as the engine does)
        if let Some(&(_, total, required)) = self.plain_funcs.iter().find(|(m, _, _)| m == name) {
            self.i += 1; // (
            let mut args = Vec::new();
            if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                self.i += 1;
            } else {
                loop {
                    args.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
            }
            if args.len() < required || args.len() > total {
                // too few (a required argument is missing) or too many
                // refuses, as the engine does; the omitted DEFAULTED tail is
                // filled by the executor from the callee's catalog at run
                return None;
            }
            self.saw_user_fn = true;
            return Some(Val::Fn(name.to_string(), args));
        }
        self.i += 1; // (
        let v = match name {
            "UPPER" => Val::Upper(Box::new(self.val()?)),
            "EXTRACT" => {
                let part = match self.t.get(self.i)? {
                    Tok::Ident(w) => match w.to_ascii_uppercase().as_str() {
                        "YEAR" => 0,
                        "MONTH" => 1,
                        "DAY" => 2,
                        "HOUR" => 3,
                        "MINUTE" => 4,
                        "SECOND" => 5,
                        "WEEKDAY" => 6,
                        "YEARDAY" => 7,
                        "MILLISECOND" => 8,
                        "WEEK" => 9,
                        _ => return None,
                    },
                    _ => return None,
                };
                self.i += 1;
                if !self.kw("FROM") {
                    return None;
                }
                Val::Extract(part, Box::new(self.val()?))
            }
            "LOWER" => Val::Lower(Box::new(self.val()?)),
            // blr_strlen's length-type byte: CHAR_LENGTH=1,
            // OCTET_LENGTH=2 (probed)
            "CHAR_LENGTH" | "CHARACTER_LENGTH" => {
                Val::StrLen(1, Box::new(self.val()?))
            }
            "OCTET_LENGTH" => Val::StrLen(2, Box::new(self.val()?)),
            "SUBSTRING" => {
                // SUBSTRING(src FROM a FOR b): blr_substring's start
                // is 0-BASED and the engine emits subtract(<a>, 1)
                // UNFOLDED (probed: FROM 1 stores subtract(1, 1),
                // not the literal 0) - build exactly that Sub node
                let src = self.val()?;
                if !self.kw("FROM") {
                    return None;
                }
                let from = self.val()?;
                // FOR-less substring: the engine fills the length
                // with INT MAX (probed: FROM 2 stores literal
                // 0x7FFFFFFF)
                let len = if self.kw("FOR") {
                    self.val()?
                } else {
                    Val::Int(0x7FFF_FFFF)
                };
                Val::Substring(
                    Box::new(src),
                    Box::new(Val::Sub(Box::new(from), Box::new(Val::Int(1)))),
                    Box::new(len),
                )
            }
            "TRIM" => {
                // where byte 0=BOTH 1=LEADING 2=TRAILING; a bare
                // `TRIM('a' FROM s)` is BOTH (probed byte-identical)
                let (wher, explicit) = if self.kw("LEADING") {
                    (1u8, true)
                } else if self.kw("TRAILING") {
                    (2u8, true)
                } else if self.kw("BOTH") {
                    (0u8, true)
                } else {
                    (0u8, false)
                };
                if self.kw("FROM") {
                    // TRIM(LEADING FROM s): a where-spec, no what
                    if !explicit {
                        return None;
                    }
                    Val::Trim(wher, None, Box::new(self.val()?))
                } else {
                    let v1 = self.val()?;
                    if self.kw("FROM") {
                        Val::Trim(wher, Some(Box::new(v1)), Box::new(self.val()?))
                    } else {
                        // plain TRIM(s) - a where-spec demands FROM
                        if explicit {
                            return None;
                        }
                        Val::Trim(0, None, Box::new(v1))
                    }
                }
            }
            "GEN_ID" => {
                // GEN_ID(sequence, increment) - the first argument is
                // a NAME, not a value
                let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(name) {
                    return None;
                }
                let name = name.clone();
                self.i += 1;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                Val::GenId(name, Box::new(self.val()?))
            }
            "CAST" => {
                let v = self.val()?;
                if !self.kw("AS") {
                    return None;
                }
                Val::Cast(self.cast_target()?, Box::new(v))
            }
            "COALESCE" => {
                // blr_coalesce with its count byte; a single argument
                // is a syntax error IN THE ENGINE, so it refuses here
                let mut vs = vec![self.val()?];
                while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                    vs.push(self.val()?);
                }
                if vs.len() < 2 {
                    return None;
                }
                Val::Coalesce(vs)
            }
            "NULLIF" => {
                // NULLIF(a, b) compiles as cast(value_if(a = b, NULL,
                // a)) - and the unified dsc comes from the BRANCHES
                // (NULL and a), so b never shapes it (probed:
                // NULLIF(1, 2.55) casts to long scale 0)
                let a = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let b = self.val()?;
                let dsc = self.unify_branches(&[&Val::Null, &a])?;
                Val::Cast(
                    dsc,
                    Box::new(Val::ValueIf(
                        Box::new(Bool::Cmp(CmpOp::Eql, a.clone(), b)),
                        Box::new(Val::Null),
                        Box::new(a),
                    )),
                )
            }
            // a SYSTEM function: blr_sys_function over the counted
            // arguments ([SYS_FUNCTIONS]), the special spellings rewritten
            // to the argument order the engine stores
            n if sys_function_arity(n).is_some() => self.sys_function(n)?,
            "IIF" => {
                // IIF is pure sugar: byte-identical to the searched
                // CASE WHEN c THEN a ELSE b END (probed)
                let c = self.bool_or()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let a = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let b = self.val()?;
                let dsc = self.unify_branches(&[&a, &b])?;
                Val::Cast(
                    dsc,
                    Box::new(Val::ValueIf(Box::new(c), Box::new(a), Box::new(b))),
                )
            }
            _ => return None,
        };
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        Some(v)
    }

    /// The values a `*` over stream `idx` stands for: a relation's or a
    /// selectable procedure's catalogued columns as fields of that
    /// context, a derived table's outer columns through the same mapping
    /// a qualified reference takes ([Self::field]). None when the
    /// catalog does not know the relation.
    /// Lift a value onto the aggregate's map for the window layer above it:
    /// a group field takes (or adds) its key slot, an aggregate's fid
    /// passes, an expression rebuilds over both ([lift_over_agg]).
    fn lift_to_agg(&mut self, v: &Val, gfields: &[Val], fid_ctx: u8) -> Option<Val> {
        match v {
            Val::Fid(..) | Val::Int(_) | Val::Int64(_) | Val::Dec(..) | Val::Str(_) | Val::Null | Val::InParam(_) | Val::LocalVar(_) => Some(v.clone()),
            Val::Field(..) => {
                if !gfields.contains(v) {
                    return None;
                }
                let e = MapEntry::Key(v.clone());
                let slot = match self.agg_map.iter().position(|x| *x == e) {
                    Some(i) => i,
                    None => {
                        self.agg_map.push(e);
                        self.agg_map.len() - 1
                    }
                };
                Some(Val::Fid(fid_ctx, slot as u16))
            }
            other => lift_over_agg(&mut self.agg_map, other, gfields, fid_ctx),
        }
    }

    /// The index of the paren closing the one at `open`.
    fn paren_close(&self, open: usize) -> Option<usize> {
        let mut depth = 0i32;
        let mut j = open;
        loop {
            match self.t.get(j)? {
                Tok::LParen => depth += 1,
                Tok::RParen => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(j);
                    }
                }
                _ => {}
            }
            j += 1;
        }
    }

    /// `<name>(..) OVER (..)` starting at `i`: the index just past the
    /// OVER clause's closing paren.
    fn window_call_end(&self, i: usize) -> Option<usize> {
        if !matches!(self.t.get(i), Some(Tok::Ident(_))) || !matches!(self.t.get(i + 1), Some(Tok::LParen)) {
            return None;
        }
        let close = self.paren_close(i + 1)?;
        if !matches!(self.t.get(close + 1), Some(Tok::Ident(w)) if w == "OVER") {
            return None;
        }
        if !matches!(self.t.get(close + 2), Some(Tok::LParen)) {
            return None;
        }
        Some(self.paren_close(close + 2)? + 1)
    }

    /// A window call with `self.i` ON its opening paren (the name already
    /// read): the aggregate verbs through parse_agg, the named functions
    /// canonicalized exactly as a whole window item's (LAG/LEAD to three
    /// arguments, NTH_VALUE with its FROM FIRST indicator), then OVER.
    fn window_call(&mut self, name: &str, ctx: u8) -> Option<WinSpec> {
        // a window INSIDE a window's arguments or keys is the engine's
        // 42000: nothing nested is captured, so the inner call refuses
        let saved = self.win_cap.take();
        let r = self.window_call_inner(name, ctx);
        self.win_cap = saved;
        r
    }

    fn window_call_inner(&mut self, name: &str, ctx: u8) -> Option<WinSpec> {
        let entry = if matches!(name, "COUNT" | "SUM" | "AVG" | "MIN" | "MAX") {
            let (verb, arg) = self.parse_agg(name)?;
            MapEntry::Agg(verb, arg)
        } else {
            self.i += 1;
            let mut args = Vec::new();
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                loop {
                    args.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => break,
                        _ => return None,
                    }
                }
            }
            self.i += 1;
            match name {
                "ROW_NUMBER" | "RANK" | "DENSE_RANK" => {
                    if !args.is_empty() {
                        return None;
                    }
                }
                "FIRST_VALUE" | "LAST_VALUE" => {
                    if args.len() != 1 {
                        return None;
                    }
                }
                "NTH_VALUE" => {
                    if args.len() != 2 {
                        return None;
                    }
                    args.push(Val::Int(0));
                }
                _ => {
                    if args.is_empty() || args.len() > 3 {
                        return None;
                    }
                    if args.len() < 2 {
                        args.push(Val::Int(1));
                    }
                    if args.len() < 3 {
                        args.push(Val::Null);
                    }
                }
            }
            MapEntry::Fn(name.to_string(), args)
        };
        if !self.kw("OVER") {
            return None;
        }
        let (part, ord, frame) = self.over_clause(ctx)?;
        Some((entry, part, ord, frame))
    }

    /// The NAMES of [star_fields]' columns, in the same order: a
    /// relation's columns, a derived table's outer column names.
    fn star_names(&self, idx: usize) -> Option<Vec<String>> {
        let st = &self.streams[idx];
        Some(match &st.derived {
            None => catalog_columns(&st.name)?,
            Some(d) => d.cols.iter().map(|(n, _)| n.clone()).collect(),
        })
    }

    fn star_fields(&self, idx: usize) -> Option<Vec<Val>> {
        let st = &self.streams[idx];
        let ctx = idx as u8 + self.base;
        Some(match &st.derived {
            None => catalog_columns(&st.name)?.into_iter().map(|n| Val::Field(ctx, n)).collect(),
            Some(d) => {
                let expr_ctx = if d.agg.is_some() { ctx + 1 } else { ctx };
                d.cols
                    .iter()
                    .map(|(_, inner)| match inner {
                        DCol::Col(n) => Val::Field(ctx, n.clone()),
                        DCol::Expr(e) => Val::DerivedWrap(expr_ctx, Box::new(e.clone())),
                        DCol::Fid(v) => v.clone(),
                    })
                    .collect()
            }
        })
    }

    /// A derived table with an aggregate inside occupies the context after
    /// its own too (the aggregate node's); claim it so later streams number
    /// past it (measured: a join to such a table takes context 2)
    fn claim_derived_agg_slot(&mut self, st: &Stream) {
        // a derived table's WINDOWS occupy the contexts after its own
        let n_wins = st.derived.as_ref().map_or(0, |d| d.wins.len());
        for _ in 0..n_wins {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
        }
        if st.derived.as_ref().is_some_and(|d| d.agg.is_some()) {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
        }
    }

    /// `NULLS FIRST` / `NULLS LAST` after a sort key's direction: wraps the
    /// key for [emit_sort_key] (measured: `B2` / `B4` before the direction
    /// byte, emitted whenever written - the default placement too)
    fn nulls_placement(&mut self, key: Val) -> Option<Val> {
        if !self.kw("NULLS") {
            return Some(key);
        }
        let b = if self.kw("FIRST") {
            0xB2
        } else if self.kw("LAST") {
            0xB4
        } else {
            return None;
        };
        Some(Val::NullsPlaced(b, Box::new(key)))
    }

    /// The catalog type of a column the statement reads: the stream the
    /// context numbers, then [catalog_type] of its relation. A derived
    /// table, a cursor or a procedure stream has no catalog type.
    fn field_dsc(&self, ctx: u8, name: &str) -> Option<Dsc> {
        let idx = ctx.checked_sub(self.base)? as usize;
        let st = self.streams.get(idx)?;
        if st.derived.is_some() || st.proc_args.is_some() || st.cur.is_some() {
            return None;
        }
        catalog_type(&st.name, name)
    }

    fn branch_dsc(&self, v: &Val) -> Option<BranchDsc> {
        Some(match v {
            // an integer literal is a LONG inside the engine's DSQL (an
            // INT64 once it no longer fits); a DECIMAL literal is an INT64
            // however few its digits, emitted narrow when it fits - which
            // is why CASE WHEN c THEN 1.5 ELSE 2.5 END casts to int64
            // scale -1 and `N IN (2.5, 1)` casts the 1 and not the 2.5
            // (measured)
            Val::Int(_) => BranchDsc::Exact(blr::LONG, 0),
            Val::Int64(_) => BranchDsc::Exact(blr::INT64, 0),
            Val::Dec(_, sc) => BranchDsc::Exact(blr::INT64, *sc),
            Val::DoubleLit(_) => BranchDsc::Approx(true),
            Val::Str(t) => {
                let cs = LIT_CS.with(|c| c.get());
                let cs = if t.is_ascii() || matches!(cs, 0 | 2..=4) { cs } else { 0 };
                BranchDsc::Text {
                    varying: false,
                    chars: u16::try_from(t.chars().count()).ok()?,
                    cs,
                }
            }
            Val::Null => BranchDsc::Skip,
            Val::Cast(d, _) => dsc_to_branch(*d)?,
            Val::Field(ctx, name) => {
                let d = typing_of(v).or_else(|| self.field_dsc(*ctx, name))?;
                dsc_to_branch(d)?
            }
            _ => return None,
        })
    }

    /// The descriptor a CASE / IIF / NULLIF casts its branches to, and
    /// an IN list's common item type. Measured on 2196:
    /// - exact numerics: the WIDEST dtype (short < long < int64 < int128)
    ///   with the SMALLEST scale - N INTEGER beside R NUMERIC(9,2) is long
    ///   scale -2, beside a BIGINT int64, beside 2.5 int64 scale -1 (the
    ///   decimal literal being an int64 inside DSQL), I128 beside 1.5
    ///   int128 scale -1;
    /// - DOUBLE beside anything numeric is DOUBLE; FLOAT beside a short,
    ///   long or FLOAT stays FLOAT (wider exacts beside a FLOAT: unmeasured,
    ///   refused);
    /// - texts: VARYING if any is, the length the LONGEST in characters,
    ///   the set the one non-NONE set among them (CH CHAR(5) NONE beside U
    ///   VARCHAR(10) UTF8 is varying 10 chars UTF8); two different real
    ///   sets refuse;
    /// - a temporal or BOOLEAN only beside its own kind (DATE beside
    ///   TIMESTAMP is the engine's -804); text beside a number: refused.
    fn unify_branches(&self, branches: &[&Val]) -> Option<Dsc> {
        let mut kinds: Vec<BranchDsc> = Vec::new();
        for b in branches {
            match self.branch_dsc(b)? {
                BranchDsc::Skip => {}
                k => kinds.push(k),
            }
        }
        if kinds.is_empty() {
            return None; // all-NULL: the engine's choice is unprobed
        }
        if kinds.iter().all(|k| matches!(k, BranchDsc::Exact(..) | BranchDsc::Approx(_))) {
            if kinds.iter().any(|k| matches!(k, BranchDsc::Approx(true))) {
                return Some(Dsc::Double);
            }
            if kinds.iter().any(|k| matches!(k, BranchDsc::Approx(false))) {
                return if kinds
                    .iter()
                    .all(|k| matches!(k, BranchDsc::Approx(false) | BranchDsc::Exact(blr::SHORT | blr::LONG, _)))
                {
                    Some(Dsc::Float)
                } else {
                    None
                };
            }
            let rank = |dt: u8| match dt {
                blr::SHORT => 0,
                blr::LONG => 1,
                blr::INT64 => 2,
                _ => 3,
            };
            let mut dt = blr::SHORT;
            let mut sc = 0i8;
            for k in &kinds {
                if let BranchDsc::Exact(d, s) = k {
                    if rank(*d) > rank(dt) {
                        dt = *d;
                    }
                    sc = sc.min(*s);
                }
            }
            return Some(Dsc::Num(dt, sc));
        }
        if kinds.iter().all(|k| matches!(k, BranchDsc::Text { .. })) {
            let mut varying = false;
            let mut chars = 0u16;
            let mut sets: Vec<u16> = Vec::new();
            for k in &kinds {
                if let BranchDsc::Text { varying: v, chars: c, cs } = k {
                    varying |= *v;
                    chars = chars.max(*c);
                    if *cs != 0 && !sets.contains(cs) {
                        sets.push(*cs);
                    }
                }
            }
            let cs = match sets.as_slice() {
                [] => 0,
                [one] => *one,
                _ => return None,
            };
            return Some(if varying { Dsc::VaryingCs(chars, cs) } else { Dsc::TextCs(chars, cs) });
        }
        let first = kinds[0];
        if kinds.iter().all(|k| *k == first) {
            return match first {
                BranchDsc::Date => Some(Dsc::Date),
                BranchDsc::Time => Some(Dsc::Time),
                BranchDsc::Timestamp => Some(Dsc::Timestamp),
                BranchDsc::Boolean => Some(Dsc::Boolean),
                _ => None,
            };
        }
        None
    }

    /// A system function call, self.i past the opening paren; leaves
    /// self.i ON the closing paren like every arm of [P::func]. The
    /// engine stores every spelling in ONE argument order (measured on
    /// 2196 through RDB$PROCEDURE_BLR):
    ///   DATEADD(<part>, v, d) == DATEADD(v <part> TO d)  -> [v, part, d]
    ///   DATEDIFF(<part>, a, b) == DATEDIFF(<part> FROM a TO b) -> [part, a, b]
    ///   FIRST_DAY / LAST_DAY (OF <part> FROM d)         -> [part, d]
    ///   POSITION(a IN b) == POSITION(a, b)              -> [a, b]
    ///   OVERLAY(a PLACING b FROM c [FOR d])             -> [a, b, c, (d)]
    ///   CRYPT_HASH(a USING alg)                         -> [a, 'alg' in ASCII]
    /// where <part> is a blr_long literal of the blr_extract code (DAY 2,
    /// WEEK 9, MILLISECOND 8 ..).
    fn sys_function(&mut self, name: &str) -> Option<Val> {
        let (min, max) = sys_function_arity(name)?;
        let part_code = |p: &mut Self| -> Option<Val> {
            let Some(Tok::Ident(w)) = p.t.get(p.i) else { return None };
            let code = extract_part_code(w)?;
            p.i += 1;
            Some(Val::Int(code as i32))
        };
        let args: Vec<Val> = match name {
            "DATEADD" => {
                // `<part>, v, d` when a part name is followed by a comma
                if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if extract_part_code(w).is_some())
                    && matches!(self.t.get(self.i + 1), Some(Tok::Comma))
                {
                    let part = part_code(self)?;
                    self.i += 1; // ,
                    let v = self.val()?;
                    if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        return None;
                    }
                    self.i += 1;
                    let d = self.val()?;
                    vec![v, part, d]
                } else {
                    let v = self.val()?;
                    let part = part_code(self)?;
                    if !self.kw("TO") {
                        return None;
                    }
                    let d = self.val()?;
                    vec![v, part, d]
                }
            }
            "DATEDIFF" => {
                let part = part_code(self)?;
                if self.kw("FROM") {
                    let a = self.val()?;
                    if !self.kw("TO") {
                        return None;
                    }
                    let b = self.val()?;
                    vec![part, a, b]
                } else {
                    if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        return None;
                    }
                    self.i += 1;
                    let a = self.val()?;
                    if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        return None;
                    }
                    self.i += 1;
                    let b = self.val()?;
                    vec![part, a, b]
                }
            }
            "FIRST_DAY" | "LAST_DAY" => {
                if !self.kw("OF") {
                    return None;
                }
                let part = part_code(self)?;
                if !self.kw("FROM") {
                    return None;
                }
                let d = self.val()?;
                vec![part, d]
            }
            "POSITION" => {
                let a = self.val()?;
                if self.kw("IN") {
                    vec![a, self.val()?]
                } else {
                    let mut args = vec![a];
                    while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        args.push(self.val()?);
                    }
                    args
                }
            }
            "OVERLAY" => {
                let a = self.val()?;
                if !self.kw("PLACING") {
                    return None;
                }
                let b = self.val()?;
                if !self.kw("FROM") {
                    return None;
                }
                let c = self.val()?;
                let mut args = vec![a, b, c];
                if self.kw("FOR") {
                    args.push(self.val()?);
                }
                args
            }
            "CRYPT_HASH" => {
                let a = self.val()?;
                if !self.kw("USING") {
                    return None;
                }
                let Some(Tok::Ident(alg)) = self.t.get(self.i) else { return None };
                let alg = alg.clone();
                self.i += 1;
                vec![a, Val::StrCs(alg, 2)]
            }
            _ => {
                let mut args = Vec::new();
                if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    args.push(self.val()?);
                    while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        args.push(self.val()?);
                    }
                }
                args
            }
        };
        if args.len() < min || args.len() > max {
            return None;
        }
        Some(Val::SysFn(name.to_string(), args))
    }

    /// CASE ... END, self.i past the CASE keyword. The searched form
    /// compiles to a value_if CHAIN (each further WHEN nests in the
    /// ELSE slot) under ONE cast to the branches' unified dsc; a
    /// missing ELSE is blr_null. The simple form compiles to
    /// blr_decode with NO cast wrapper (probed).
    fn case_tail(&mut self) -> Option<Val> {
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "WHEN") {
            // searched CASE
            let mut arms: Vec<(Bool, Val)> = Vec::new();
            while self.kw("WHEN") {
                let c = self.bool_or()?;
                if !self.kw("THEN") {
                    return None;
                }
                arms.push((c, self.val()?));
            }
            let els = if self.kw("ELSE") {
                self.val()?
            } else {
                Val::Null
            };
            if !self.kw("END") {
                return None;
            }
            let mut branches: Vec<&Val> = arms.iter().map(|(_, v)| v).collect();
            branches.push(&els);
            let dsc = self.unify_branches(&branches)?;
            let mut tree = els;
            for (c, v) in arms.into_iter().rev() {
                tree = Val::ValueIf(Box::new(c), Box::new(v), Box::new(tree));
            }
            return Some(Val::Cast(dsc, Box::new(tree)));
        }
        // simple CASE: blr_decode(selector, comparands, results); the
        // ELSE is one extra result and NOTHING marks its absence
        let sel = self.val()?;
        let mut comparands = Vec::new();
        let mut results = Vec::new();
        while self.kw("WHEN") {
            comparands.push(self.val()?);
            if !self.kw("THEN") {
                return None;
            }
            results.push(self.val()?);
        }
        if comparands.is_empty() {
            return None;
        }
        if self.kw("ELSE") {
            results.push(self.val()?);
        }
        if !self.kw("END") {
            return None;
        }
        Some(Val::Decode(Box::new(sel), comparands, results))
    }

    /// the cast targets whose dsc bytes were probed; anything else -
    /// FLOAT, BLOB, DECFLOAT, INT128, zones, explicit charsets -
    /// refuses
    fn cast_target(&mut self) -> Option<Dsc> {
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        let name = name.clone();
        self.i += 1;
        let paren_num = |p: &mut Self| -> Option<(i64, i8)> {
            if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
                return None;
            }
            p.i += 1;
            let Some(Tok::Int(prec)) = p.t.get(p.i) else {
                return None;
            };
            let prec = *prec;
            p.i += 1;
            let mut sc = 0i8;
            if matches!(p.t.get(p.i), Some(Tok::Comma)) {
                p.i += 1;
                let Some(Tok::Int(x)) = p.t.get(p.i) else {
                    return None;
                };
                sc = i8::try_from(*x).ok()?;
                p.i += 1;
            }
            if !matches!(p.t.get(p.i), Some(Tok::RParen)) {
                return None;
            }
            p.i += 1;
            Some((prec, sc))
        };
        Some(match name.as_str() {
            "SMALLINT" => Dsc::Num(blr::SHORT, 0),
            "INTEGER" | "INT" => Dsc::Num(blr::LONG, 0),
            "BIGINT" => Dsc::Num(blr::INT64, 0),
            "INT128" => Dsc::Num(26, 0),
            // NUMERIC(p<=4) is short; DECIMAL(p<=9) is ALWAYS long -
            // DECIMAL(4,1) probed as blr_long (SQL's "at least p")
            "NUMERIC" | "DECIMAL" => match paren_num(self) {
                None => Dsc::Num(blr::LONG, 0),
                Some((p, sc)) => {
                    let dt = if p <= 4 && name == "NUMERIC" {
                        blr::SHORT
                    } else if p <= 9 {
                        blr::LONG
                    } else if p <= 18 {
                        blr::INT64
                    } else if p <= 38 {
                        // blr_int128 (26) with its scale byte (measured: a
                        // NUMERIC(38,2) parameter's slot is `1A FE`)
                        26
                    } else {
                        return None;
                    };
                    Dsc::Num(dt, -sc)
                }
            },
            "VARCHAR" | "CHAR" | "CHARACTER" => {
                let (l, sc) = paren_num(self)?;
                if sc != 0 {
                    return None;
                }
                let l = u16::try_from(l).ok()?;
                let varying = name == "VARCHAR";
                // an explicit `CHARACTER SET <name>`: the set the engine
                // carries by that name or alias (a COLLATE after it is
                // unprobed and refuses)
                if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "CHARACTER")
                    && matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SET")
                {
                    self.i += 2;
                    let Some(Tok::Ident(cs_name)) = self.t.get(self.i) else {
                        return None;
                    };
                    let (cs, _) = charset_by_name(cs_name)?;
                    self.i += 1;
                    if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "COLLATE") {
                        return None;
                    }
                    if varying {
                        Dsc::VaryingCs(l, cs)
                    } else {
                        Dsc::TextCs(l, cs)
                    }
                } else if varying {
                    Dsc::Varying(l)
                } else {
                    Dsc::Text(l)
                }
            }
            "DATE" => Dsc::Date,
            "TIME" => Dsc::Time,
            "TIMESTAMP" => Dsc::Timestamp,
            "DOUBLE" => {
                if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "PRECISION") {
                    return None;
                }
                self.i += 1;
                Dsc::Double
            }
            // a bare FLOAT / REAL is the 4-byte single; FLOAT(p) unprobed
            "BOOLEAN" => Dsc::Boolean,
            "FLOAT" | "REAL" => {
                if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                    return None;
                }
                Dsc::Float
            }
            // DECFLOAT(16) / DECFLOAT(34); a bare DECFLOAT is 34
            "DECFLOAT" => match paren_num(self) {
                None => Dsc::Dec128,
                Some((16, 0)) => Dsc::Dec64,
                Some((34, 0)) => Dsc::Dec128,
                Some(_) => return None,
            },
            _ => return None,
        })
    }

    /// `COUNT(*)`, `COUNT(v)`, `SUM(v)`, `AVG(v)`, `MIN(v)`,
    /// `MAX(v)` - self.i ON the opening paren. DISTINCT inside an
    /// aggregate is unprobed and refuses.
    fn parse_agg(&mut self, name: &str) -> Option<(u8, Option<Val>)> {
        self.i += 1; // (
        // COUNT/SUM/AVG get dedicated DISTINCT verbs; MIN and MAX
        // fold DISTINCT away (probed byte-identical to the plain form)
        let distinct = self.kw("DISTINCT");
        let out = match name {
            "COUNT" if !distinct && matches!(self.t.get(self.i), Some(Tok::Star)) => {
                self.i += 1;
                (blr::AGG_COUNT, None)
            }
            "COUNT" if distinct => (blr::AGG_COUNT_DISTINCT, Some(self.val()?)),
            "COUNT" => (blr::AGG_COUNT2, Some(self.val()?)),
            "SUM" if distinct => (blr::AGG_TOTAL_DISTINCT, Some(self.val()?)),
            "SUM" => (blr::AGG_TOTAL, Some(self.val()?)),
            "AVG" if distinct => (blr::AGG_AVERAGE_DISTINCT, Some(self.val()?)),
            "AVG" => (blr::AGG_AVERAGE, Some(self.val()?)),
            "MIN" => (blr::AGG_MIN, Some(self.val()?)),
            "MAX" => (blr::AGG_MAX, Some(self.val()?)),
            _ => return None,
        };
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        // FILTER (WHERE c) is DSQL sugar (measured): the aggregate over
        // CAST(CASE WHEN c THEN <arg> END AS <arg's type>) - COUNT(*)
        // becoming blr_agg_count2 over CAST(CASE WHEN c THEN 1 END AS
        // INTEGER). A window's FILTER is unmeasured and refuses.
        let out = if self.kw("FILTER") {
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            if !self.kw("WHERE") {
                return None;
            }
            let cond = self.bool_or()?;
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "OVER") {
                return None;
            }
            match out {
                (verb, None) if verb == blr::AGG_COUNT => (
                    blr::AGG_COUNT2,
                    Some(Val::Cast(
                        Dsc::Num(blr::LONG, 0),
                        Box::new(Val::ValueIf(Box::new(cond), Box::new(Val::Int(1)), Box::new(Val::Null))),
                    )),
                ),
                (verb, Some(arg)) => {
                    let d = self.unify_branches(&[&arg, &Val::Null])?;
                    (verb, Some(Val::Cast(d, Box::new(Val::ValueIf(Box::new(cond), Box::new(arg), Box::new(Val::Null))))))
                }
                _ => return None,
            }
        } else {
            out
        };
        Some(out)
    }

    /// dedup-or-append an aggregate into the map; the slot index
    /// becomes a blr_fid on the aggregate's context (probed: HAVING
    /// COUNT(*) beside SELECT COUNT(*) REUSES slot 1)
    fn agg_slot(&mut self, verb: u8, arg: Option<Val>) -> u16 {
        // (the fid context is self.agg_fid_ctx - set by the select)
        let entry = MapEntry::Agg(verb, arg);
        if let Some(idx) = self.agg_map.iter().position(|e| *e == entry) {
            return idx as u16;
        }
        self.agg_map.push(entry);
        (self.agg_map.len() - 1) as u16
    }

    fn bool_or(&mut self) -> Option<Bool> {
        let mut left = self.bool_and()?;
        while self.kw("OR") {
            let right = self.bool_and()?;
            left = Bool::Or(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn bool_and(&mut self) -> Option<Bool> {
        let mut left = self.bool_not()?;
        while self.kw("AND") {
            let right = self.bool_not()?;
            left = Bool::And(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn bool_not(&mut self) -> Option<Bool> {
        if self.kw("NOT") {
            return Some(negate(self.bool_not()?));
        }
        if matches!(self.t.get(self.i), Some(Tok::LParen)) {
            // a paren opens a boolean group OR a parenthesised value
            // ((A + 1) * 2 = 8): try the group on a saved position,
            // fall through to the leaf parser otherwise
            let save = self.i;
            self.i += 1;
            if let Some(inner) = self.bool_or() {
                if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    self.i += 1;
                    return Some(inner);
                }
            }
            self.i = save;
        }
        self.leaf()
    }

    fn leaf(&mut self) -> Option<Bool> {
        for (kw, code) in [("INSERTING", 1), ("UPDATING", 2), ("DELETING", 3)] {
            if self.kw(kw) {
                return Some(Bool::Cmp(
                    CmpOp::Eql,
                    Val::TrigAction,
                    Val::Int(code),
                ));
            }
        }
        if self.kw("EXISTS") {
            return Some(Bool::Any(self.subselect(false)?));
        }
        if self.kw("SINGULAR") {
            return Some(Bool::Unique(self.subselect(false)?));
        }
        let left = self.val()?;
        if self.kw("IS") {
            let negated = self.kw("NOT");
            if self.kw("DISTINCT") {
                if !self.kw("FROM") {
                    return None;
                }
                let e = Bool::Equiv(left, self.val()?);
                return Some(if negated { e } else { Bool::Not(Box::new(e)) });
            }
            if !self.kw("NULL") {
                return None;
            }
            let m = Bool::Missing(left);
            return Some(if negated { Bool::Not(Box::new(m)) } else { m });
        }
        let negated = self.kw("NOT");
        if self.kw("BETWEEN") {
            let lo = self.val()?;
            if !self.kw("AND") {
                return None;
            }
            let hi = self.val()?;
            let body = Bool::Between(left, lo, hi);
            return Some(if negated { negate(body) } else { body });
        }
        if self.kw("LIKE") {
            let pat = self.val()?;
            // LIKE .. ESCAPE is a different verb (blr_ansi_like)
            let body = if self.kw("ESCAPE") {
                Bool::AnsiLike(left, pat, self.val()?)
            } else {
                Bool::Like(left, pat)
            };
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if self.kw("CONTAINING") {
            let pat = self.val()?;
            let body = Bool::Containing(left, pat);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if self.kw("SIMILAR") {
            if !self.kw("TO") {
                return None;
            }
            let pat = self.val()?;
            let esc = if self.kw("ESCAPE") { Some(self.val()?) } else { None };
            let body = Bool::Similar(left, pat, esc);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if self.kw("STARTING") {
            let _ = self.kw("WITH"); // WITH is optional sugar
            let pat = self.val()?;
            let body = Bool::Starting(left, pat);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if self.kw("IN") {
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            // IN (SELECT ...) is blr_ansi_any with an EQL boolean;
            // NOT IN negates to blr_ansi_all with NEQ (probed)
            if matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SELECT") {
                let sub = self.subselect(true)?;
                let body = Bool::AnsiAny(CmpOp::Eql, left, sub);
                return Some(if negated { negate(body) } else { body });
            }
            self.i += 1;
            let mut items = vec![self.val()?];
            while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
                items.push(self.val()?);
            }
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            // ONE item is a plain equality (measured: `IN (1 + 1)` is
            // blr_eql and NOT IN a blr_not over it; a lone text item is
            // not cast)
            if items.len() == 1 {
                let body = Bool::Cmp(CmpOp::Eql, left, items.pop()?);
                return Some(if negated { Bool::Not(Box::new(body)) } else { body });
            }
            let left_dsc = typing_of(&left).or_else(|| match &left {
                Val::Field(c, n) => self.field_dsc(*c, n),
                _ => None,
            });
            // a TEXT item is cast to the LEFT's own type (measured: `S IN
            // ('a', 'b')` casts each to varying(20) NONE, `U IN (..)` to
            // its UTF8 type - in views and CHECKs alike); without that
            // type the shape is unknown and refuses below
            // (`S IN ('a', N)` casts the INTEGER column too - every
            // non-text item takes the text operand's type; a text column
            // item is unmeasured and refuses)
            let items: Vec<Val> = match left_dsc {
                Some(d @ (Dsc::Text(_) | Dsc::Varying(_) | Dsc::TextCs(..) | Dsc::VaryingCs(..))) => items
                    .into_iter()
                    .map(|it| match it {
                        Val::Str(_) => Some(Val::Cast(d, Box::new(it))),
                        Val::Field(..) => match self.branch_dsc(&it) {
                            Some(BranchDsc::Exact(..) | BranchDsc::Approx(_)) => Some(Val::Cast(d, Box::new(it))),
                            _ => None,
                        },
                        other => Some(other),
                    })
                    .collect::<Option<Vec<Val>>>()?,
                _ => items,
            };
            // temporal LITERAL items beside a temporal operand stay raw
            // (measured: `D IN (DATE '..', DATE '..')` lists two date
            // literals uncast)
            if items.iter().all(|it| matches!(it, Val::TemporalLit(_))) {
                let body = Bool::InList(left, items);
                return Some(if negated { Bool::Not(Box::new(body)) } else { body });
            }
            let items: Vec<Val> = if items.iter().any(|it| matches!(it, Val::InParam(_) | Val::Cast(..))) {
                // a `?` has no type to unify with; the probed shape keeps
                // the items raw beside integer literals and casts
                if items.iter().any(|it| {
                    !matches!(it, Val::Int(_) | Val::Int64(_) | Val::InParam(_) | Val::Cast(..))
                }) {
                    return None;
                }
                items
            } else {
                // NUMERIC items are cast to the ITEMS' common type where
                // their own differs (measured: `N IN (1, SM)` casts SM to
                // long, `N IN (1, B)` casts the 1 to int64, `R IN (1.5, 2)`
                // casts the 2 to int64 scale -1 and leaves the 1.5 - the
                // left operand never shapes it: `B IN (1, N)` casts nothing)
                // ...and an approximate item widens the common type the
                // same way (measured: `N IN (1, DB)` casts the 1 to DOUBLE,
                // `N IN (1, F)` to FLOAT, the column itself staying raw)
                let kinds: Vec<BranchDsc> =
                    items.iter().map(|it| self.branch_dsc(it)).collect::<Option<_>>()?;
                if !kinds.iter().all(|k| matches!(k, BranchDsc::Exact(..) | BranchDsc::Approx(_))) {
                    return None;
                }
                let common = self.unify_branches(&items.iter().collect::<Vec<_>>())?;
                let own = |k: &BranchDsc| match k {
                    BranchDsc::Exact(dt, sc) => Some(Dsc::Num(*dt, *sc)),
                    BranchDsc::Approx(true) => Some(Dsc::Double),
                    BranchDsc::Approx(false) => Some(Dsc::Float),
                    _ => None,
                };
                items
                    .into_iter()
                    .zip(kinds)
                    .map(|(it, k)| if own(&k) == Some(common) { it } else { Val::Cast(common, Box::new(it)) })
                    .collect()
            };
            let body = Bool::InList(left, items);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if negated {
            return None;
        }
        if let Some(Tok::Cmp(op)) = self.t.get(self.i) {
            let op = *op;
            self.i += 1;
            // a quantifier keeps the WRITTEN comparison as the outer
            // rse's boolean; ANY and SOME are the same verb (probed)
            if self.kw("ANY") || self.kw("SOME") {
                return Some(Bool::AnsiAny(op, left, self.subselect(true)?));
            }
            if self.kw("ALL") {
                return Some(Bool::AnsiAll(op, left, self.subselect(true)?));
            }
            let right = self.val()?;
            return Some(Bool::Cmp(op, left, right));
        }
        None
    }
}

/// The engine's system functions this compiler emits as blr_sys_function
/// (SysFunction.cpp's table, minus the ones whose SQL spelling carries
/// more than a value list: ENCRYPT / DECRYPT, RSA_*, RDB$SYSTEM_PRIVILEGE
/// - and HASH .. USING, which 2196 refuses). Each with its (min, max)
/// argument count; the special spellings are rewritten in
/// [P::sys_function].
const SYS_FUNCTIONS: &[(&str, usize, usize)] = &[
    ("ABS", 1, 1), ("ACOS", 1, 1), ("ACOSH", 1, 1), ("ASCII_CHAR", 1, 1), ("ASCII_VAL", 1, 1),
    ("ASIN", 1, 1), ("ASINH", 1, 1), ("ATAN", 1, 1), ("ATAN2", 2, 2), ("ATANH", 1, 1),
    ("BASE64_DECODE", 1, 1), ("BASE64_ENCODE", 1, 1), ("BIN_AND", 2, 255), ("BIN_NOT", 1, 1),
    ("BIN_OR", 2, 255), ("BIN_SHL", 2, 2), ("BIN_SHL_ROT", 2, 2), ("BIN_SHR", 2, 2),
    ("BIN_SHR_ROT", 2, 2), ("BIN_XOR", 2, 255), ("BLOB_APPEND", 2, 255), ("CEIL", 1, 1),
    ("CEILING", 1, 1), ("CHAR_TO_UUID", 1, 1), ("COMPARE_DECFLOAT", 2, 2), ("COS", 1, 1),
    ("COSH", 1, 1), ("COT", 1, 1), ("CRYPT_HASH", 2, 2), ("DATEADD", 3, 3), ("DATEDIFF", 3, 3),
    ("EXP", 1, 1), ("FIRST_DAY", 2, 2), ("FLOOR", 1, 1), ("GEN_UUID", 0, 0), ("HASH", 1, 1),
    ("HEX_DECODE", 1, 1), ("HEX_ENCODE", 1, 1), ("LAST_DAY", 2, 2), ("LEFT", 2, 2), ("LN", 1, 1),
    ("LOG", 2, 2), ("LOG10", 1, 1), ("LPAD", 2, 3), ("MAKE_DBKEY", 2, 4), ("MAXVALUE", 1, 255),
    ("MINVALUE", 1, 255), ("MOD", 2, 2), ("NORMALIZE_DECFLOAT", 1, 1), ("OVERLAY", 3, 4),
    ("PI", 0, 0), ("POSITION", 2, 3), ("POWER", 2, 2), ("QUANTIZE", 2, 2), ("RAND", 0, 0),
    ("RDB$GET_CONTEXT", 2, 2), ("RDB$GET_TRANSACTION_CN", 1, 1), ("RDB$ROLE_IN_USE", 1, 1),
    ("RDB$SET_CONTEXT", 3, 3), ("REPLACE", 3, 3), ("REVERSE", 1, 1), ("RIGHT", 2, 2),
    ("ROUND", 1, 2), ("RPAD", 2, 3), ("SIGN", 1, 1), ("SIN", 1, 1), ("SINH", 1, 1),
    ("SQRT", 1, 1), ("TAN", 1, 1), ("TANH", 1, 1), ("TOTALORDER", 2, 2), ("TRUNC", 1, 2),
    ("UNICODE_CHAR", 1, 1), ("UNICODE_VAL", 1, 1), ("UUID_TO_CHAR", 1, 1),
];

fn sys_function_arity(name: &str) -> Option<(usize, usize)> {
    SYS_FUNCTIONS.iter().find(|(n, ..)| *n == name).map(|(_, lo, hi)| (*lo, *hi))
}

/// blr_extract's part codes, which DATEADD / DATEDIFF / FIRST_DAY /
/// LAST_DAY carry as a blr_long literal (measured: DAY 2, MONTH 1, WEEK
/// 9, MILLISECOND 8, YEAR 0, HOUR 3)
fn extract_part_code(w: &str) -> Option<u8> {
    Some(match w.to_ascii_uppercase().as_str() {
        "YEAR" => 0,
        "MONTH" => 1,
        "DAY" => 2,
        "HOUR" => 3,
        "MINUTE" => 4,
        "SECOND" => 5,
        "WEEKDAY" => 6,
        "YEARDAY" => 7,
        "MILLISECOND" => 8,
        "WEEK" => 9,
        _ => return None,
    })
}

fn is_keyword(w: &str) -> bool {
    matches!(
        w,
        "AND"
            | "OR"
            | "NOT"
            | "IS"
            | "NULL"
            | "BETWEEN"
            | "LIKE"
            | "STARTING"
            | "CONTAINING"
            | "SIMILAR"
            | "ESCAPE"
            | "FILTER"
            | "PLACING"
            | "NULLS"
            | "IN"
            | "WHERE"
            | "FROM"
            | "SELECT"
            | "JOIN"
            | "INNER"
            | "ON"
            | "LEFT"
            | "RIGHT"
            | "FULL"
            | "OUTER"
            | "FOR"
            | "LEADING"
            | "TRAILING"
            | "BOTH"
            | "CASE"
            | "WHEN"
            | "THEN"
            | "ELSE"
            | "END"
            | "AS"
            | "EXISTS"
            | "SINGULAR"
            | "ANY"
            | "SOME"
            | "ALL"
            | "DISTINCT"
            | "UNION"
            | "ORDER"
            | "BY"
            | "ASC"
            | "DESC"
            | "INTO"
            | "DO"
            | "SUSPEND"
            | "CREATE"
            | "PROCEDURE"
            | "RETURNS"
            | "BEGIN"
            | "GROUP"
            | "HAVING"
            | "TRIGGER"
            | "BEFORE"
            | "AFTER"
            | "POSITION"
            | "IF"
            | "INSERT"
            | "DELETE"
            | "UPDATE"
            | "VALUES"
            | "SET"
            | "DECLARE"
            | "WHILE"
            | "INSERTING"
            | "UPDATING"
            | "DELETING"
            | "EXECUTE"
            | "EXCEPTION"
            | "EXIT"
            | "DEFAULT"
            | "COMPUTED"
            | "CHECK"
            | "NEXT"
            | "VALUE"
            | "POST_EVENT"
            | "ROW_COUNT"
            | "GDSCODE"
            | "MATCHING"
            | "AUTONOMOUS"
            | "TRANSACTION"
            | "SQLCODE"
            | "CURSOR"
            | "OPEN"
            | "FETCH"
            | "CLOSE"
            | "MERGE"
            | "USING"
            | "MATCHED"
            | "RETURNING"
            | "WITH"
            | "LOCK"
            | "PLAN"
            | "NATURAL"
            | "OFFSET"
            | "ROWS"
            | "ONLY"
    )
}

// -------------------------------------------------------------- emitter

fn emit_val(out: &mut Vec<u8>, v: &Val) {
    match v {
        Val::Field(ctx, name) => {
            out.push(blr::FIELD);
            out.push(*ctx);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        // measured (SHOW_LANGS): blr_index, the field, a one-byte count,
        // then the subscripts
        Val::ArrayElem(field, subs) => {
            out.push(blr::INDEX);
            emit_val(out, field);
            out.push(subs.len() as u8);
            for sv in subs {
                emit_val(out, sv);
            }
        }
        Val::Add(a, b) => {
            out.push(blr::ADD);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Sub(a, b) => {
            out.push(blr::SUBTRACT);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Mul(a, b) => {
            out.push(blr::MULTIPLY);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Div(a, b) => {
            out.push(blr::DIVIDE);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Neg(a) => {
            out.push(blr::NEGATE);
            emit_val(out, a);
        }
        Val::Concat(a, b) => {
            out.push(blr::CONCATENATE);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Int64(n) => {
            out.push(blr::LITERAL);
            out.push(blr::INT64);
            out.push(0); // scale
            out.extend_from_slice(&n.to_le_bytes());
        }
        Val::Upper(a) => {
            out.push(blr::UPCASE);
            emit_val(out, a);
        }
        Val::Extract(part, a) => {
            out.push(159); // blr_extract
            out.push(*part);
            emit_val(out, a);
        }
        Val::Lower(a) => {
            out.push(blr::LOWCASE);
            emit_val(out, a);
        }
        Val::StrLen(kind, a) => {
            out.push(blr::STRLEN);
            out.push(*kind);
            emit_val(out, a);
        }
        Val::Substring(src, start, len) => {
            out.push(blr::SUBSTRING);
            emit_val(out, src);
            emit_val(out, start);
            emit_val(out, len);
        }
        Val::Trim(wher, what, src) => {
            out.push(blr::TRIM);
            out.push(*wher);
            match what {
                None => out.push(0),
                Some(w) => {
                    out.push(1);
                    emit_val(out, w);
                }
            }
            emit_val(out, src);
        }
        Val::Null => out.push(blr::NULL),
        Val::Cast(d, v) => {
            out.push(blr::CAST);
            emit_dsc(out, *d);
            emit_val(out, v);
        }
        Val::ValueIf(c, t, e) => {
            out.push(blr::VALUE_IF);
            emit_bool(out, c);
            emit_val(out, t);
            emit_val(out, e);
        }
        Val::Decode(sel, comparands, results) => {
            out.push(blr::DECODE);
            emit_val(out, sel);
            out.push(comparands.len() as u8);
            for c in comparands {
                emit_val(out, c);
            }
            out.push(results.len() as u8);
            for r in results {
                emit_val(out, r);
            }
        }
        Val::Coalesce(vs) => {
            out.push(blr::COALESCE);
            out.push(vs.len() as u8);
            for v in vs {
                emit_val(out, v);
            }
        }
        Val::Fid(ctx, id) => {
            out.push(blr::FID);
            out.push(*ctx);
            out.extend_from_slice(&id.to_le_bytes());
        }
        Val::DerivedWrap(ctx, inner) => {
            out.push(0xBF); // blr_derived_expr
            out.push(1);
            out.push(*ctx);
            emit_val(out, inner);
        }
        Val::DerivedWrapN(ctxs, inner) => {
            out.push(0xBF); // blr_derived_expr
            out.push(ctxs.len() as u8);
            out.extend_from_slice(ctxs);
            emit_val(out, inner);
        }
        Val::CastInt64(inner) => {
            out.push(0x83); // blr_cast
            out.push(0x10); // blr_int64
            out.push(0);
            emit_val(out, inner);
        }
        Val::InParam(i) => {
            out.push(blr::PARAMETER2);
            out.push(0);
            out.extend_from_slice(&(2 * i).to_le_bytes());
            out.extend_from_slice(&(2 * i + 1).to_le_bytes());
        }
        Val::LocalVar(i) => {
            out.push(blr::VARIABLE);
            out.extend_from_slice(&i.to_le_bytes());
        }
        Val::TrigAction => {
            out.push(blr::INTERNAL_INFO);
            emit_val(out, &Val::Int(6));
        }
        Val::CurrentDate => out.push(blr::CURRENT_DATE),
        Val::CurrentTime => out.push(blr::CURRENT_TIME),
        Val::CurrentTimestamp => out.push(blr::CURRENT_TIMESTAMP),
        Val::RowCount => {
            out.push(blr::INTERNAL_INFO);
            emit_val(out, &Val::Int(5));
        }
        Val::CurrentConnection => {
            out.push(blr::INTERNAL_INFO);
            emit_val(out, &Val::Int(1));
        }
        Val::CurrentTransaction => {
            out.push(blr::INTERNAL_INFO);
            emit_val(out, &Val::Int(2));
        }
        Val::UserName => out.push(0x2C),
        Val::Bool(b) => out.extend_from_slice(&[blr::LITERAL, 23, *b as u8]),
        Val::TemporalLit(b) => {
            out.push(blr::LITERAL);
            out.extend_from_slice(b);
        }
        Val::CurrentRole => out.push(0xAE),
        Val::GenId(name, inc) => {
            out.push(blr::GEN_ID);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            emit_val(out, inc);
        }
        Val::GenId2(name) => {
            out.push(blr::GEN_ID2);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        Val::ScalarSub(sub) => {
            out.push(blr::VIA);
            out.push(blr::SINGULAR);
            out.push(blr::RSE);
            out.push(1);
            if let Some((verb, arg, agg_ctx)) = &sub.agg {
                // the aggregate wrap: inner rse (its WHERE inside),
                // zero group keys, a one-slot map, the fid result
                out.push(blr::AGGREGATE);
                out.push(*agg_ctx);
                out.push(blr::RSE);
                out.push(1);
                emit_stream(out, &sub.stream, sub.ctx);
                if let Some(w) = &sub.wher {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, w);
                }
                out.push(blr::END);
                out.push(blr::GROUP_BY);
                out.push(0);
                out.push(blr::MAP);
                out.extend_from_slice(&1u16.to_le_bytes());
                out.extend_from_slice(&0u16.to_le_bytes());
                out.push(*verb);
                if let Some(a) = arg {
                    emit_val(out, a);
                }
                out.push(blr::END);
                emit_val(out, &Val::Fid(*agg_ctx, 0));
            } else {
                emit_stream(out, &sub.stream, sub.ctx);
                if let Some(w) = &sub.wher {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, w);
                }
                out.push(blr::END);
                emit_val(
                    out,
                    sub.col.as_ref().expect("scalar subselect has a column"),
                );
            }
            out.push(blr::NULL);
        }
        Val::Int(n) => {
            out.push(blr::LITERAL);
            out.push(blr::LONG);
            out.push(0); // scale
            out.extend_from_slice(&n.to_le_bytes());
        }
        Val::Dec(raw, scale) => {
            out.push(blr::LITERAL);
            out.push(blr::LONG);
            out.push(*scale as u8);
            out.extend_from_slice(&raw.to_le_bytes());
        }
        Val::Str(s) => {
            out.push(blr::LITERAL);
            out.push(blr::TEXT2);
            // the literal's set is the ATTACHMENT's ([set_literal_charset]):
            // its bytes here are UTF-8, so a set whose bytes they are -
            // or any set, for an all-ASCII literal - is stamped; another
            // (a non-ASCII literal under a codepage set) keeps NONE
            let cs = LIT_CS.with(|c| c.get());
            let cs = if s.is_ascii() || matches!(cs, 0 | 2..=4) { cs } else { 0 };
            out.extend_from_slice(&cs.to_le_bytes());
            out.extend_from_slice(&(s.len() as u16).to_le_bytes());
            out.extend_from_slice(s.as_bytes());
        }
        Val::SysFn(name, args) => {
            out.push(186); // blr_sys_function
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.push(args.len() as u8);
            for a in args {
                emit_val(out, a);
            }
        }
        Val::DoubleLit(text) => {
            out.push(blr::LITERAL);
            out.push(27); // blr_double: a counted string, the spelling
            out.extend_from_slice(&(text.len() as u16).to_le_bytes());
            out.extend_from_slice(text.as_bytes());
        }
        Val::Bytes(bytes) => {
            out.push(blr::LITERAL);
            out.push(blr::TEXT2);
            out.extend_from_slice(&1u16.to_le_bytes()); // OCTETS
            out.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
            out.extend_from_slice(bytes);
        }
        Val::StrCs(text, cs) => {
            out.push(blr::LITERAL);
            out.push(blr::TEXT2);
            out.extend_from_slice(&cs.to_le_bytes());
            out.extend_from_slice(&(text.len() as u16).to_le_bytes());
            out.extend_from_slice(text.as_bytes());
        }
        // a placement reaching a value position would be a parser slip:
        // emit the key it wraps (emit_sort_key is the one reader)
        Val::NullsPlaced(_, inner) => emit_val(out, inner),
        // a captured window call is always rebuilt to a window fid before
        // the emitter runs (only the window builder consumes WinRef items)
        Val::WinRef(_) => unreachable!("a window reference reached the emitter"),
        Val::Fn(name, args) => {
            out.push(blr::FUNCTION);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.push(args.len() as u8);
            for a in args {
                emit_val(out, a);
            }
        }
        Val::PkgFn(pkg, name, args) => {
            out.push(blr::FUNCTION2);
            out.push(pkg.len() as u8);
            out.extend_from_slice(pkg.as_bytes());
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.push(args.len() as u8);
            for a in args {
                emit_val(out, a);
            }
        }
        Val::SubFn(name, args) => {
            out.push(blr::INVOKE_FUNCTION);
            out.push(1); // id clause
            out.push(4); // ... a subroutine
            out.push(3); // ... by name
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.push(blr::END);
            out.push(3); // argument values
            out.extend_from_slice(&(args.len() as u16).to_le_bytes());
            for a in args {
                emit_val(out, a);
            }
            out.push(blr::END);
        }
    }
}

fn emit_bool(out: &mut Vec<u8>, b: &Bool) {
    match b {
        Bool::And(l, r) => {
            out.push(blr::AND);
            emit_bool(out, l);
            emit_bool(out, r);
        }
        Bool::Or(l, r) => {
            out.push(blr::OR);
            emit_bool(out, l);
            emit_bool(out, r);
        }
        Bool::Not(inner) => {
            out.push(blr::NOT);
            emit_bool(out, inner);
        }
        Bool::Cmp(op, a, bb) => {
            out.push(op.verb());
            emit_val(out, a);
            emit_val(out, bb);
        }
        Bool::Missing(v) => {
            out.push(blr::MISSING);
            emit_val(out, v);
        }
        Bool::Between(v, lo, hi) => {
            out.push(blr::BETWEEN);
            emit_val(out, v);
            emit_val(out, lo);
            emit_val(out, hi);
        }
        Bool::Like(v, p) => {
            out.push(blr::LIKE);
            emit_val(out, v);
            emit_val(out, p);
        }
        Bool::Equiv(a, bb) => {
            out.push(blr::EQUIV);
            emit_val(out, a);
            emit_val(out, bb);
        }
        Bool::Starting(v, p) => {
            out.push(0x37); // blr_starting
            emit_val(out, v);
            emit_val(out, p);
        }
        Bool::Containing(v, p) => {
            out.push(0x35); // blr_containing
            emit_val(out, v);
            emit_val(out, p);
        }
        Bool::Similar(v, p, esc) => {
            out.push(0xBC); // blr_similar
            emit_val(out, v);
            emit_val(out, p);
            match esc {
                Some(e) => {
                    out.push(1);
                    emit_val(out, e);
                }
                None => out.push(0),
            }
        }
        Bool::AnsiLike(v, p, e) => {
            out.push(0x6C); // blr_ansi_like
            emit_val(out, v);
            emit_val(out, p);
            emit_val(out, e);
        }
        Bool::InList(v, items) => {
            out.push(blr::IN_LIST);
            emit_val(out, v);
            out.extend_from_slice(&(items.len() as u16).to_le_bytes());
            for it in items {
                emit_val(out, it);
            }
        }
        Bool::Any(sub) | Bool::Unique(sub) => {
            out.push(if matches!(b, Bool::Any(_)) {
                blr::ANY
            } else {
                blr::UNIQUE
            });
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, &sub.stream, sub.ctx);
            if let Some(w) = &sub.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
        }
        Bool::AnsiAny(op, left, sub) | Bool::AnsiAll(op, left, sub) => {
            out.push(if matches!(b, Bool::AnsiAny(..)) {
                blr::ANSI_ANY
            } else {
                blr::ANSI_ALL
            });
            // the outer rse's single stream IS the subquery's rse -
            // which carries the subquery's own WHERE; the quantified
            // comparison is the OUTER rse's boolean (probed)
            out.push(blr::RSE);
            out.push(1);
            out.push(blr::RSE);
            out.push(1);
            if let Some(u) = &sub.union_ {
                // the subquery rse's stream is a UNION: it holds the
                // reserved context, branches carry rse + positional
                // map, and the comparison reads fid(union ctx, 0) -
                // no terminator of its own (probed)
                out.push(0x4C); // blr_union
                out.push(sub.ctx);
                out.push(u.branches.len() as u8);
                for (st, bctx, wher, item) in &u.branches {
                    out.push(blr::RSE);
                    out.push(1);
                    emit_stream(out, st, *bctx);
                    if let Some(w) = wher {
                        out.push(blr::BOOLEAN);
                        emit_bool(out, w);
                    }
                    out.push(blr::END);
                    out.push(0x4D); // blr_map
                    out.extend_from_slice(&1u16.to_le_bytes());
                    out.extend_from_slice(&0u16.to_le_bytes());
                    emit_val(out, item);
                }
                out.push(blr::END);
                out.push(blr::BOOLEAN);
                out.push(op.verb());
                emit_val(out, left);
                emit_val(out, &Val::Fid(sub.ctx, 0));
                out.push(blr::END);
                return;
            }
            emit_stream(out, &sub.stream, sub.ctx);
            if let Some(w) = &sub.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
            out.push(blr::BOOLEAN);
            out.push(op.verb());
            emit_val(out, left);
            emit_val(
                out,
                sub.col
                    .as_ref()
                    .or(sub.expr.as_ref())
                    .expect("quantified subquery has an item"),
            );
            out.push(blr::END);
        }
    }
}

/// One relation stream: plain (blr_relation) or aliased
/// (blr_relation2, the alias UPPERCASED IN DOUBLE QUOTES - probed).
/// How many streams the rse header counts: a comma list is flat (all of
/// its streams), a JOIN chain is one nested stream.
fn rse_stream_count(joins: &[(u8, Stream, u8, Bool)]) -> u8 {
    if !joins.is_empty() && joins.iter().all(|j| j.0 == JOIN_COMMA) {
        1 + joins.len() as u8
    } else {
        1
    }
}

/// The FROM streams: a flat comma list, or the left-nested JOIN chain
/// (n join heads, the first stream, then per join its stream, the type
/// (absent for INNER) and the ON).
fn emit_join_chain(out: &mut Vec<u8>, first: &Stream, ctx: u8, joins: &[(u8, Stream, u8, Bool)]) {
    if !joins.is_empty() && joins.iter().all(|j| j.0 == JOIN_COMMA) {
        emit_stream(out, first, ctx);
        for (_, st, jctx, _) in joins {
            emit_stream(out, st, *jctx);
        }
        return;
    }
    for _ in joins {
        out.push(blr::JOIN);
        out.push(2);
    }
    emit_stream(out, first, ctx);
    for (jt, st, jctx, on) in joins {
        emit_stream(out, st, *jctx);
        if *jt != 0 {
            out.push(blr::JOIN_TYPE);
            out.push(*jt);
        }
        out.push(blr::BOOLEAN);
        emit_bool(out, on);
        out.push(blr::END);
    }
}

/// The window list after a blr_window's source rse: the count, then each
/// window - blr_partition_by (or the v4 framed verb) with its keys, the
/// remapped keys, the sort and the map.
fn emit_window_list(out: &mut Vec<u8>, windows: &[Win]) {
    out.push(windows.len() as u8);
    for w in windows {
        if let Some((unit, b1, b2)) = &w.frame {
            // the v4 verb: subcoded clauses, then the
            // extent, then its OWN end (probed)
            out.push(blr::WINDOW_WIN);
            out.push(w.ctx);
            if !w.part.is_empty() {
                out.push(1); // win_partition
                out.push(w.part.len() as u8);
                for k in &w.part {
                    emit_val(out, k);
                }
                for r in &w.remap {
                    emit_val(out, r);
                }
            }
            if !w.ord.is_empty() {
                out.push(2); // win_order
                out.push(w.ord.len() as u8);
                for (desc, k) in &w.ord {
                    emit_sort_key(out, *desc, k);
                }
            }
            out.push(3); // win_map
            out.extend_from_slice(
                &(w.map.len() as u16).to_le_bytes(),
            );
            emit_map_entries(out, &w.map);
            out.push(4); // extent unit
            out.push(*unit);
            for (j, b) in [b1, b2].into_iter().enumerate() {
                out.push(5); // frame bound
                out.push(j as u8 + 1);
                out.push(b.0);
                if let Some(v) = &b.1 {
                    out.push(6); // frame value
                    out.push(j as u8 + 1);
                    emit_val(out, v);
                }
            }
            out.push(blr::END);
            continue;
        }
        out.push(blr::PARTITION_BY);
        out.push(w.ctx);
        out.push(w.part.len() as u8);
        for k in &w.part {
            emit_val(out, k);
        }
        for r in &w.remap {
            emit_val(out, r);
        }
        out.push(blr::SORT);
        out.push(w.ord.len() as u8);
        for (desc, k) in &w.ord {
            emit_sort_key(out, *desc, k);
        }
        out.push(blr::MAP);
        out.extend_from_slice(
            &(w.map.len() as u16).to_le_bytes(),
        );
        emit_map_entries(out, &w.map);
    }
}

fn emit_stream(out: &mut Vec<u8>, st: &Stream, ctx: u8) {
    // a selectable procedure source (measured, ALL_LANGS): blr_procedure,
    // the counted name, the context, a u16 input count, the inputs
    if let Some(args) = &st.proc_args {
        match &st.alias {
            None => {
                out.push(blr::PROCEDURE);
                out.push(st.name.len() as u8);
                out.extend_from_slice(st.name.as_bytes());
            }
            Some(a) => {
                out.push(blr::PROCEDURE2);
                out.push(st.name.len() as u8);
                out.extend_from_slice(st.name.as_bytes());
                let quoted = format!("\"{}\"", a);
                out.push(quoted.len() as u8);
                out.extend_from_slice(quoted.as_bytes());
            }
        }
        out.push(ctx);
        out.extend_from_slice(&(args.len() as u16).to_le_bytes());
        for a in args {
            emit_val(out, a);
        }
        return;
    }
    if let Some(d) = &st.derived {
        out.push(blr::RSE);
        out.push(1);
        if !d.wins.is_empty() {
            out.push(blr::WINDOW);
            out.push(blr::RSE);
            out.push(1);
        }
        if d.agg.is_some() {
            out.push(blr::AGGREGATE);
            out.push(ctx + 1);
            out.push(blr::RSE);
            out.push(1);
        }
        // a SYSTEM relation inside takes blr_relation3 (schema SYSTEM) with
        // the alias slot always present, and the qualified alias text names
        // SYSTEM (measured: `"Q" "SYSTEM"."RDB$DATABASE"`)
        let system = is_system_relation(&st.name);
        match &st.alias {
            // alias-less: a plain blr_relation inside (measured)
            None if system => {
                emit_relation3(out, &st.name);
                out.push(0);
            }
            None => {
                out.push(0x4A); // blr_relation
                out.push(st.name.len() as u8);
                out.extend_from_slice(st.name.as_bytes());
            }
            Some(alias) => {
                if system {
                    emit_relation3(out, &st.name);
                } else {
                    out.push(blr::RELATION2);
                    out.push(st.name.len() as u8);
                    out.extend_from_slice(st.name.as_bytes());
                }
                let text = match &d.inner_alias {
                    Some(ia) => format!("\"{}\" \"{}\"", alias, ia),
                    None => format!("\"{}\" \"{}\".\"{}\"", alias, relation_schema(&st.name), st.name),
                };
                out.push(text.len() as u8);
                out.extend_from_slice(text.as_bytes());
            }
        }
        out.push(ctx);
        if let Some(agg) = &d.agg {
            // the aggregate's own rse holds the WHERE; its map follows, then
            // the HAVING as the nested rse's boolean (measured)
            if let Some(w) = &d.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
            out.push(blr::GROUP_BY);
            out.push(agg.group_keys.len() as u8);
            for k in &agg.group_keys {
                emit_val(out, k);
            }
            out.push(blr::MAP);
            out.extend_from_slice(&(agg.map.len() as u16).to_le_bytes());
            emit_map_entries(out, &agg.map);
            if let Some(h) = &agg.having {
                out.push(blr::BOOLEAN);
                emit_bool(out, h);
            }
            out.push(blr::END);
            return;
        }
        if !d.wins.is_empty() {
            // the window's source rse holds the WHERE; the window list
            // follows and the derived rse closes (measured)
            if let Some(w) = &d.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
            emit_window_list(out, &d.wins);
            out.push(blr::END);
            return;
        }
        if let Some(v) = &d.first {
            out.push(blr::FIRST);
            emit_val(out, v);
        }
        if let Some(v) = &d.skip {
            out.push(blr::SKIP);
            emit_val(out, v);
        }
        if let Some(w) = &d.wher {
            out.push(blr::BOOLEAN);
            emit_bool(out, w);
        }
        if !d.sort.is_empty() {
            out.push(blr::SORT);
            out.push(d.sort.len() as u8);
            for (desc, k) in &d.sort {
                emit_sort_key(out, *desc, k);
            }
        }
        if let Some(pr) = &d.project {
            out.push(0x45); // blr_project
            out.push(pr.len() as u8);
            for v in pr {
                emit_val(out, v);
            }
        }
        out.push(blr::END);
        return;
    }
    if let Some(cn) = &st.cur {
        // inside a CURSOR's rse every stream carries the cursor's
        // concatenated alias - the cursor name paired with the
        // stream's own alias, or with its schema-qualified name
        // (probed; relation3's slot takes the same string in subs)
        let alias = match &st.alias {
            Some(a) => format!("\"{}\" \"{}\"", cn, a),
            None => format!("\"{}\" \"{}\".\"{}\"", cn, relation_schema(&st.name), st.name),
        };
        if st.sub || is_system_relation(&st.name) {
            emit_relation3(out, &st.name);
        } else {
            out.push(blr::RELATION2);
            out.push(st.name.len() as u8);
            out.extend_from_slice(st.name.as_bytes());
        }
        out.push(alias.len() as u8);
        out.extend_from_slice(alias.as_bytes());
        out.push(ctx);
        return;
    }
    // a subroutine body qualifies every relation: blr_relation3 with schema
    // PUBLIC, an empty package, and the alias slot ALWAYS present - the
    // quoted alias or a counted empty; a SYSTEM relation takes the same
    // form EVERYWHERE, schema SYSTEM (measured: `FROM RDB$DATABASE` is `94
    // 06 'SYSTEM' 00 0C 'RDB$DATABASE' 00 <ctx>`, aliased `.. 03 '"D"'`, in
    // a join, an EXISTS body, MON$ tables alike)
    if st.sub || is_system_relation(&st.name) {
        emit_relation3(out, &st.name);
        match &st.alias {
            Some(a) => {
                let quoted = format!("\"{}\"", a);
                out.push(quoted.len() as u8);
                out.extend_from_slice(quoted.as_bytes());
            }
            None => out.push(0),
        }
        out.push(ctx);
        return;
    }
    match &st.alias {
        None => {
            out.push(blr::RELATION);
            out.push(st.name.len() as u8);
            out.extend_from_slice(st.name.as_bytes());
        }
        Some(a) => {
            out.push(blr::RELATION2);
            out.push(st.name.len() as u8);
            out.extend_from_slice(st.name.as_bytes());
            let quoted = format!("\"{}\"", a);
            out.push(quoted.len() as u8);
            out.extend_from_slice(quoted.as_bytes());
        }
    }
    out.push(ctx);
}

/// The schema a relation lives in: the engine's own tables (RDB$, MON$,
/// SEC$) are SYSTEM's, everything a user creates here PUBLIC's.
fn relation_schema(name: &str) -> &'static str {
    if is_system_relation(name) {
        "SYSTEM"
    } else {
        "PUBLIC"
    }
}

fn is_system_relation(name: &str) -> bool {
    name.starts_with("RDB$") || name.starts_with("MON$") || name.starts_with("SEC$")
}

/// The blr_relation3 head: the relation's schema, empty package, the name -
/// the caller appends the alias slot and context.
fn emit_relation3(out: &mut Vec<u8>, name: &str) {
    let schema = relation_schema(name);
    out.push(blr::RELATION3);
    out.push(schema.len() as u8);
    out.extend_from_slice(schema.as_bytes());
    out.push(0);
    out.push(name.len() as u8);
    out.extend_from_slice(name.as_bytes());
}

/// Compile a view-shaped SELECT to the BLR the engine's DSQL stores in
/// `RDB$VIEW_BLR` - byte for byte. `None` for anything outside the
/// converted surface (the caller refuses; this crate never guesses).
/// The per-column BLR of a view's EXPRESSION columns - what the engine
/// stores in the auto-domain's `RDB$COMPUTED_BLR` (probed: `V || 'x'` in
/// `CREATE VIEW ... FROM T` is `05 27 17 01 01 'V' 15 0f 0000 0100 'x' 4c`:
/// the expression over the VIEW's stream contexts, 1..n in FROM order,
/// alias-aware, between blr_version5 and blr_eoc). One entry per select
/// list item: `None` for a plain (qualified) column, `Some(blr)` for an
/// expression. `None` overall when the SELECT is outside the converted
/// surface (a UNION, `*`, an item this compiler cannot parse).
pub fn compile_view_columns(sql: &str) -> Option<Vec<Option<Vec<u8>>>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: Vec::new(),
        base: 1,
        outer: None,
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    let mut depth = 0i32;
    for t in toks.iter() {
        match t {
            Tok::LParen => depth += 1,
            Tok::RParen => depth -= 1,
            Tok::Ident(w) if w == "UNION" && depth == 0 => return None,
            _ => {}
        }
    }
    if !p.kw("SELECT") {
        return None;
    }
    let _ = p.kw("DISTINCT");
    // the select list as token ranges, split on depth-0 commas up to FROM
    let mut items: Vec<(usize, usize)> = Vec::new();
    let mut start = p.i;
    let mut depth = 0i32;
    loop {
        match p.t.get(p.i)? {
            Tok::LParen => depth += 1,
            Tok::RParen => depth -= 1,
            Tok::Comma if depth == 0 => {
                items.push((start, p.i));
                start = p.i + 1;
            }
            Tok::Ident(w) if depth == 0 && w == "FROM" => {
                items.push((start, p.i));
                p.i += 1;
                break;
            }
            // a lone `*` (or `q.*`) selects all - not this slice; between
            // operands it multiplies
            Tok::Star if depth == 0 && (p.i == start || matches!(p.t.get(p.i - 1), Some(Tok::Dot))) => return None,
            _ => {}
        }
        p.i += 1;
    }
    // the streams, exactly as the view's RSE numbers them
    let first = p.stream_item()?;
    if first.derived.is_some() && first.alias.is_none() {
        return None; // an alias-less derived table in a VIEW: unmeasured
    }
    p.streams.push(first);
    if matches!(p.t.get(p.i), Some(Tok::Comma)) {
        while matches!(p.t.get(p.i), Some(Tok::Comma)) {
            p.i += 1;
            let st = p.stream_item()?;
            p.streams.push(st);
        }
    } else {
        loop {
            let jt = if p.kw("LEFT") || p.kw("RIGHT") || p.kw("FULL") {
                let _ = p.kw("OUTER");
                1u8
            } else if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "JOIN" || w == "INNER") {
                let _ = p.kw("INNER");
                0u8
            } else {
                break;
            };
            let _ = jt;
            if !p.kw("JOIN") {
                return None;
            }
            let st = p.stream_item()?;
            p.streams.push(st);
            if !p.kw("ON") {
                return None;
            }
            let _ = p.bool_or()?;
        }
    }
    p.outer = Some(p.streams.len());
    let end_of_list = p.i;
    let mut out: Vec<Option<Vec<u8>>> = Vec::with_capacity(items.len());
    for (a, b) in items {
        if a >= b {
            return None;
        }
        // a trailing `[AS] <alias>` is not part of the value
        let mut e = b;
        if e - a >= 2 {
            if let Some(Tok::Ident(al)) = p.t.get(e - 1) {
                if !is_keyword(al) {
                    if matches!(p.t.get(e - 2), Some(Tok::Ident(k)) if k == "AS") {
                        e -= 2;
                    } else if e - a >= 2 && !matches!(p.t.get(e - 2), Some(Tok::Dot)) && !is_operator_tok(p.t.get(e - 2)) {
                        e -= 1;
                    }
                }
            }
        }
        // a plain column: `name` or `q.name`
        let plain = match (e - a, p.t.get(a), p.t.get(a + 1), p.t.get(a + 2)) {
            (1, Some(Tok::Ident(w)), _, _) => !is_keyword(w),
            (3, Some(Tok::Ident(_)), Some(Tok::Dot), Some(Tok::Ident(_))) => true,
            _ => false,
        };
        if plain {
            out.push(None);
            continue;
        }
        p.i = a;
        let v = p.val()?;
        if p.i != e {
            return None;
        }
        let mut blr = vec![blr::VERSION5];
        emit_val(&mut blr, &v);
        blr.push(blr::EOC);
        out.push(Some(blr));
    }
    p.i = end_of_list;
    Some(out)
}

/// Whether a token ends a value (so a bare identifier after it is a
/// column alias, not an operand) - `X ID` aliases, `X + ID` does not.
fn is_operator_tok(t: Option<&Tok>) -> bool {
    !matches!(t, Some(Tok::Ident(_)) | Some(Tok::RParen) | Some(Tok::Int(_)) | Some(Tok::Str(_)) | None)
}

pub fn compile_view_select(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: Vec::new(),
        base: 1,
        outer: None,
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    // a top-level UNION restructures the whole statement: the union
    // node takes context 1 BEFORE any branch stream, so it must be
    // known before parsing begins
    let mut depth = 0i32;
    let mut has_union = false;
    for t in toks.iter() {
        match t {
            Tok::LParen => depth += 1,
            Tok::RParen => depth -= 1,
            Tok::Ident(w) if w == "UNION" && depth == 0 => has_union = true,
            _ => {}
        }
    }
    if has_union {
        return compile_union(&mut p);
    }
    if !p.kw("SELECT") {
        return None;
    }
    // the select list leaves NO trace in the view BLR (probed) -
    // EXCEPT under DISTINCT, which projects it; capture plain columns
    // when the list has them
    let distinct = p.kw("DISTINCT");
    let sel_cols = p.select_list()?;
    if distinct && sel_cols.as_ref().map_or(true, |c| c.is_empty()) {
        return None; // DISTINCT needs a concrete column list
    }
    // FROM: `T [alias]`, a comma-list `T [a], U [b], ...`, or a JOIN
    // chain `T [a] j U [b] ON <bool> j V [c] ON <bool> ...` where j is
    // [INNER] JOIN | LEFT/RIGHT/FULL [OUTER] JOIN - each ON binds the
    // join to its LEFT, so the chain nests left (probed: the second
    // join's node contains the first as its first stream slot)
    let first = p.stream_item()?;
    if first.derived.is_some() && first.alias.is_none() {
        return None; // an alias-less derived table in a VIEW: unmeasured
    }
    p.streams.push(first);
    // each chained join: (join-type byte - 0 for INNER, which emits NO
    // blr_join_type sub-clause; 1/2/3 for LEFT/RIGHT/FULL - and its ON)
    let mut joins: Vec<(u8, Bool)> = Vec::new();
    if matches!(p.t.get(p.i), Some(Tok::Comma)) {
        // the comma list: streams side by side in the rse
        while matches!(p.t.get(p.i), Some(Tok::Comma)) {
            p.i += 1;
            let st = p.stream_item()?;
            p.streams.push(st);
        }
    } else {
        loop {
            let jt = if p.kw("LEFT") {
                1u8
            } else if p.kw("RIGHT") {
                2u8
            } else if p.kw("FULL") {
                3u8
            } else if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "JOIN" || w == "INNER")
            {
                let _ = p.kw("INNER");
                0u8
            } else {
                break;
            };
            if jt != 0 {
                let _ = p.kw("OUTER"); // LEFT OUTER JOIN == LEFT JOIN (probed)
            }
            if !p.kw("JOIN") {
                return None;
            }
            let st = p.stream_item()?;
            p.streams.push(st);
            if !p.kw("ON") {
                return None;
            }
            joins.push((jt, p.bool_or()?));
        }
    }
    // everything pushed so far is the outer FROM; subquery streams
    // keep joining `streams` for context numbering but stay invisible
    // to outer bare names
    p.outer = Some(p.streams.len());
    // DISTINCT's projection: the select list resolved in the outer
    // scope (blr_project is the ONE place the list leaves a trace)
    let project = if distinct {
        let cols = sel_cols.as_ref()?;
        let mut vals = Vec::with_capacity(cols.len());
        for (q, n) in cols {
            vals.push(p.field(q.as_deref(), n)?);
        }
        Some(vals)
    } else {
        None
    };
    let boolean = if p.kw("WHERE") {
        Some(p.bool_or()?)
    } else {
        None
    };
    if p.i != p.t.len() {
        return None; // trailing clauses are outside this slice
    }

    let n_outer = p.outer.unwrap_or(p.streams.len());
    let mut out = vec![blr::VERSION5, blr::RSE];
    if joins.is_empty() {
        // plain OUTER streams, side by side (subquery streams live
        // inside their own rses)
        out.push(n_outer as u8);
        for (i, st) in p.streams.iter().take(n_outer).enumerate() {
            emit_stream(&mut out, st, (i + 1) as u8);
        }
    } else {
        // one rse stream holding the join chain, nested LEFT: join k's
        // node holds join k-1's node as its first stream slot, then
        // the new stream, then blr_join_type for an outer join (probed
        // absent for INNER), then its ON as a boolean sub-clause, then
        // its own blr_end
        out.push(1);
        fn emit_join_chain(
            out: &mut Vec<u8>,
            streams: &[Stream],
            joins: &[(u8, Bool)],
            k: usize,
        ) {
            if k == 0 {
                emit_stream(out, &streams[0], 1);
                return;
            }
            let (jt, on) = &joins[k - 1];
            out.push(blr::JOIN);
            out.push(2);
            emit_join_chain(out, streams, joins, k - 1);
            emit_stream(out, &streams[k], (k + 1) as u8);
            if *jt != 0 {
                out.push(blr::JOIN_TYPE);
                out.push(*jt);
            }
            out.push(blr::BOOLEAN);
            emit_bool(out, on);
            out.push(blr::END);
        }
        emit_join_chain(&mut out, &p.streams, &joins, joins.len());
    }
    if let Some(b) = &boolean {
        out.push(blr::BOOLEAN);
        emit_bool(&mut out, b);
    }
    // probed order: the boolean first, then the projection
    if let Some(vals) = &project {
        out.push(blr::PROJECT);
        out.push(vals.len() as u8);
        for v in vals {
            emit_val(&mut out, v);
        }
    }
    out.push(blr::END);
    out.push(blr::EOC);
    Some(out)
}

/// `SELECT cols FROM t [WHERE ...] UNION [ALL] SELECT ...` - the
/// statement rse's single STREAM is blr_union: its own context byte
/// (1 - claimed BEFORE any branch stream), a branch count, then per
/// branch an rse (with the branch's WHERE as its boolean) and a
/// blr_map assigning the branch's select columns to the union's field
/// numbers. A DISTINCT union (no ALL) appends a blr_project over
/// blr_fid(1, 0..n) as the statement rse's sub-clause; UNION ALL does
/// not. All probed.
fn compile_union(p: &mut P) -> Option<Vec<u8>> {
    // the union claims context 1
    p.streams.push(Stream {
        name: String::new(),
        alias: None,
        derived: None,
        sub: p.in_sub,
        cur: None,
        proc_args: None,
    });
    // no outer scope: qualified names resolve only through the
    // current branch's stream, bare names bind to it
    p.outer = Some(0);
    struct Branch {
        cols: Vec<Val>,
        wher: Option<Bool>,
    }
    let mut branches: Vec<Branch> = Vec::new();
    let mut all: Option<bool> = None;
    loop {
        if !p.kw("SELECT") {
            return None;
        }
        if p.kw("DISTINCT") {
            return None; // DISTINCT inside a union branch: unprobed
        }
        let cols = p.select_list()??;
        if cols.is_empty() {
            return None;
        }
        let st = p.stream_item()?;
        if st.derived.is_some() {
            return None; // derived branches: unprobed
        }
        p.streams.push(st);
        let si = p.streams.len() - 1;
        let saved = p.sub.replace(si);
        let mut vals = Vec::with_capacity(cols.len());
        for (q, n) in &cols {
            vals.push(p.field(q.as_deref(), n)?);
        }
        let wher = if p.kw("WHERE") {
            Some(p.bool_or()?)
        } else {
            None
        };
        p.sub = saved;
        branches.push(Branch { cols: vals, wher });
        if p.i == p.t.len() {
            break;
        }
        if !p.kw("UNION") {
            return None;
        }
        let this_all = p.kw("ALL");
        // mixed UNION / UNION ALL chains bind by their own precedence
        // rules: unprobed, refuse
        if *all.get_or_insert(this_all) != this_all {
            return None;
        }
    }
    let n = branches[0].cols.len();
    if branches.iter().any(|b| b.cols.len() != n) {
        return None;
    }
    let mut out = vec![blr::VERSION5, blr::RSE, 1, blr::UNION, 1];
    out.push(branches.len() as u8);
    for (bi, b) in branches.iter().enumerate() {
        out.push(blr::RSE);
        out.push(1);
        emit_stream(&mut out, &p.streams[bi + 1], (bi + 2) as u8);
        if let Some(w) = &b.wher {
            out.push(blr::BOOLEAN);
            emit_bool(&mut out, w);
        }
        out.push(blr::END);
        out.push(blr::MAP);
        out.extend_from_slice(&(n as u16).to_le_bytes());
        for (fi, v) in b.cols.iter().enumerate() {
            out.extend_from_slice(&(fi as u16).to_le_bytes());
            emit_val(&mut out, v);
        }
    }
    if all == Some(false) {
        // the distinct union: project the union's own fields
        out.push(blr::PROJECT);
        out.push(n as u8);
        for fi in 0..n {
            out.push(blr::FID);
            out.push(1);
            out.extend_from_slice(&(fi as u16).to_le_bytes());
        }
    }
    out.push(blr::END);
    out.push(blr::EOC);
    Some(out)
}

/// Rewrite a HAVING/ORDER-BY value against the aggregate's map: a
/// group-key column becomes blr_fid(1, its slot); fids (from
/// aggregate calls) pass through; literals and expressions over them
/// recurse. A column that is not a group key refuses.
/// Collect the bare fields a value references, first-appearance
/// order, deduped - the group keys' contribution to an aggregate map.
fn collect_fields(v: &Val, out: &mut Vec<Val>) {
    match v {
        Val::Field(..) => {
            if !out.contains(v) {
                out.push(v.clone());
            }
        }
        Val::Add(a, b)
        | Val::Sub(a, b)
        | Val::Mul(a, b)
        | Val::Div(a, b)
        | Val::Concat(a, b) => {
            collect_fields(a, out);
            collect_fields(b, out);
        }
        Val::Neg(a) => collect_fields(a, out),
        _ => {}
    }
}

/// [collect_fields] through every PURE node [map_children] walks (a
/// function's operands too) - what a window's passthrough expression
/// reads. Kept apart: the GROUP BY key sets stay on the arithmetic walk.
fn collect_fields_deep(v: &Val, out: &mut Vec<Val>) {
    match v {
        Val::Field(..) => {
            if !out.contains(v) {
                out.push(v.clone());
            }
        }
        _ => {
            let _ = map_children(v, &mut |c| {
                collect_fields_deep(c, out);
                Some(c.clone())
            });
        }
    }
}

/// An ORDER BY key at `j` that is ONE bare name standing alone - after BY
/// or a comma, before a comma, a direction, NULLS or the clause's end.
fn whole_sort_key(t: &[Tok], j: usize) -> bool {
    let before = j.checked_sub(1).and_then(|k| t.get(k));
    let after_ok = match t.get(j + 1) {
        None | Some(Tok::Comma) | Some(Tok::Semi) => true,
        Some(Tok::Ident(w)) => matches!(
            w.as_str(),
            "ASC" | "ASCENDING" | "DESC" | "DESCENDING" | "NULLS" | "INTO" | "ROWS" | "OFFSET" | "FETCH" | "PLAN" | "FOR" | "WITH" | "DO"
        ),
        _ => false,
    };
    matches!(t.get(j), Some(Tok::Ident(_)))
        && matches!(before, Some(Tok::Comma) | Some(Tok::Ident(_)))
        && match before {
            Some(Tok::Ident(b)) => b == "BY",
            _ => true,
        }
        && after_ok
}

fn is_window_name(n: &str) -> bool {
    matches!(
        n,
        "COUNT" | "SUM" | "AVG" | "MIN" | "MAX" | "ROW_NUMBER" | "RANK" | "DENSE_RANK"
            | "FIRST_VALUE" | "LAST_VALUE" | "NTH_VALUE" | "LAG" | "LEAD"
    )
}

fn contains_winref(v: &Val) -> bool {
    match v {
        Val::WinRef(_) => true,
        _ => {
            let mut hit = false;
            let _ = map_children(v, &mut |c| {
                hit |= contains_winref(c);
                Some(c.clone())
            });
            hit
        }
    }
}

/// An item expression holding window calls, rebuilt over the windows
/// under construction: each call takes (or reuses) its entry in the window
/// of its spec - created in encounter order - and a column its slot in the
/// DEFAULT window; every fid carries the WINDOW INDEX as its context until
/// [patch_fid_win] (measured: `SUM(N) OVER (PARTITION BY G) * 100 /
/// COUNT(*) OVER ()`, `ROW_NUMBER() OVER (..) - ROW_NUMBER() OVER (..)`)
fn rebuild_win_expr(windows: &mut Vec<Win>, v: &Val, found: &[WinSpec]) -> Option<Val> {
    let mut slot_in = |windows: &mut Vec<Win>, part: &Vec<Val>, ord: &Vec<(bool, Val)>, frame: &Option<(u8, (u8, Option<Val>), (u8, Option<Val>))>, e: MapEntry| -> Option<Val> {
        let wi = match windows.iter().position(|w| w.part == *part && w.ord == *ord && w.frame == *frame) {
            Some(i) => i,
            None => {
                windows.push(Win {
                    ctx: 0,
                    part: part.clone(),
                    ord: ord.clone(),
                    frame: frame.clone(),
                    map: Vec::new(),
                    remap: Vec::new(),
                });
                windows.len() - 1
            }
        };
        let map = &mut windows[wi].map;
        let slot = match map.iter().position(|x| *x == e) {
            Some(k) => k,
            None => {
                map.push(e);
                map.len() - 1
            }
        };
        Some(Val::Fid(u8::try_from(wi).ok()?, slot as u16))
    };
    match v {
        Val::WinRef(k) => {
            let (e, part, ord, frame) = found.get(*k as usize)?;
            let nested = |x: &Val| contains_winref(x);
            let in_entry = match e {
                MapEntry::Agg(_, Some(a)) => nested(a),
                MapEntry::Fn(_, args) => args.iter().any(nested),
                _ => false,
            };
            if in_entry || part.iter().any(nested) || ord.iter().any(|(_, x)| nested(x)) {
                return None;
            }
            slot_in(windows, part, ord, frame, e.clone())
        }
        Val::Field(..) | Val::Fid(..) => slot_in(windows, &Vec::new(), &Vec::new(), &None, MapEntry::Key(v.clone())),
        v if is_leaf_val(v) => Some(v.clone()),
        _ => map_children(v, &mut |c| rebuild_win_expr(windows, c, found)),
    }
}

/// [rebuild_win_expr]'s window indexes become the windows' contexts.
fn patch_fid_win(v: &Val, windows: &[Win]) -> Option<Val> {
    match v {
        Val::Fid(wi, slot) => Some(Val::Fid(windows.get(*wi as usize)?.ctx, *slot)),
        other if is_leaf_val(other) => Some(other.clone()),
        other => map_children(other, &mut |c| patch_fid_win(c, windows)),
    }
}

/// A value with NO child values: a literal, a parameter, a variable, a
/// context function. Every map/rebuild below passes these through.
fn is_leaf_val(v: &Val) -> bool {
    matches!(
        v,
        Val::Int(_)
            | Val::Int64(_)
            | Val::Dec(..)
            | Val::Str(_)
            | Val::StrCs(..)
            | Val::Null
            | Val::InParam(_)
            | Val::LocalVar(_)
            | Val::DoubleLit(_)
            | Val::Bytes(_)
            | Val::Bool(_)
            | Val::TemporalLit(_)
            | Val::CurrentDate
            | Val::CurrentTime
            | Val::CurrentTimestamp
            | Val::UserName
            | Val::CurrentRole
            | Val::CurrentConnection
            | Val::CurrentTransaction
    )
}

/// Rebuild a PURE value node with every child value passed through `f` -
/// arithmetic, the string / cast / extract functions, COALESCE, DECODE,
/// the system functions, a NULLS placement. A node carrying anything
/// else (a boolean, a subquery, a stored function, a generator) is None:
/// what a map over it means is unprobed.
fn map_children(v: &Val, f: &mut dyn FnMut(&Val) -> Option<Val>) -> Option<Val> {
    let b = |x: Val| Box::new(x);
    Some(match v {
        Val::Add(x, y) => Val::Add(b(f(x)?), b(f(y)?)),
        Val::Sub(x, y) => Val::Sub(b(f(x)?), b(f(y)?)),
        Val::Mul(x, y) => Val::Mul(b(f(x)?), b(f(y)?)),
        Val::Div(x, y) => Val::Div(b(f(x)?), b(f(y)?)),
        Val::Concat(x, y) => Val::Concat(b(f(x)?), b(f(y)?)),
        Val::Neg(x) => Val::Neg(b(f(x)?)),
        Val::Upper(x) => Val::Upper(b(f(x)?)),
        Val::Lower(x) => Val::Lower(b(f(x)?)),
        Val::Extract(k, x) => Val::Extract(*k, b(f(x)?)),
        Val::StrLen(k, x) => Val::StrLen(*k, b(f(x)?)),
        Val::Substring(x, y, z) => Val::Substring(b(f(x)?), b(f(y)?), b(f(z)?)),
        Val::Trim(k, what, x) => {
            let what = match what {
                Some(w) => Some(b(f(w)?)),
                None => None,
            };
            Val::Trim(*k, what, b(f(x)?))
        }
        Val::Cast(d, x) => Val::Cast(d.clone(), b(f(x)?)),
        Val::CastInt64(x) => Val::CastInt64(b(f(x)?)),
        Val::NullsPlaced(k, x) => Val::NullsPlaced(*k, b(f(x)?)),
        Val::Coalesce(vs) => Val::Coalesce(vs.iter().map(|x| f(x)).collect::<Option<Vec<_>>>()?),
        Val::SysFn(n, vs) => Val::SysFn(n.clone(), vs.iter().map(|x| f(x)).collect::<Option<Vec<_>>>()?),
        Val::Decode(sel, cs, rs) => Val::Decode(
            b(f(sel)?),
            cs.iter().map(|x| f(x)).collect::<Option<Vec<_>>>()?,
            rs.iter().map(|x| f(x)).collect::<Option<Vec<_>>>()?,
        ),
        _ => return None,
    })
}

/// Rebuild a select item over an aggregate map being built: every
/// FIELD must appear in some group key and lands a (deduped) Key
/// slot; the rest recurses (probed on expression group keys).
fn rebuild_over_keys(
    map: &mut Vec<MapEntry>,
    v: &Val,
    gfields: &[Val],
    fid_ctx: u8,
) -> Option<Val> {
    match v {
        // an aggregate's fid reaching a WINDOW layer rides the window's map
        // as a key entry (measured: `DEPT_ID + 1, COUNT(*) OVER () .. GROUP
        // BY DEPT_ID` adds `fid(1,0)` to the window map and rebuilds over it)
        Val::Fid(..) => {
            let entry = MapEntry::Key(v.clone());
            let slot = match map.iter().position(|e| *e == entry) {
                Some(i) => i,
                None => {
                    map.push(entry);
                    map.len() - 1
                }
            };
            Some(Val::Fid(fid_ctx, slot as u16))
        }
        Val::Field(..) => {
            if !gfields.contains(v) {
                return None;
            }
            let entry = MapEntry::Key(v.clone());
            let slot = match map.iter().position(|e| *e == entry) {
                Some(i) => i,
                None => {
                    map.push(entry);
                    map.len() - 1
                }
            };
            Some(Val::Fid(fid_ctx, slot as u16))
        }
        v if is_leaf_val(v) => Some(v.clone()),
        // a function over the keys rebuilds over their slots like any
        // operator (measured: `UPPER(S), COUNT(*) OVER ()`, `ORDER BY
        // ABS(G)` beside a window, `UPPER(S) .. GROUP BY S`)
        _ => map_children(v, &mut |c| rebuild_over_keys(map, c, gfields, fid_ctx)),
    }
}

/// Stamp a context into every Fid of a rebuilt expression - the
/// window contexts are assigned after the maps are built.
/// [rebuild_over_keys] for the AGGREGATE layer under windows: a group field
/// takes its key slot, an aggregate's own fid passes through (it already
/// names a map slot), an expression rebuilds over both.
fn lift_over_agg(map: &mut Vec<MapEntry>, v: &Val, gfields: &[Val], fid_ctx: u8) -> Option<Val> {
    match v {
        Val::Fid(..) | Val::Int(_) | Val::Int64(_) | Val::Dec(..) | Val::Str(_) | Val::Null | Val::InParam(_) | Val::LocalVar(_) => Some(v.clone()),
        Val::Field(..) => rebuild_over_keys(map, v, gfields, fid_ctx),
        v if is_leaf_val(v) => Some(v.clone()),
        _ => map_children(v, &mut |c| lift_over_agg(map, c, gfields, fid_ctx)),
    }
}

fn patch_fid_ctx(v: &Val, ctx: u8) -> Val {
    match v {
        Val::Fid(_, slot) => Val::Fid(ctx, *slot),
        other => map_children(other, &mut |c| Some(patch_fid_ctx(c, ctx))).unwrap_or_else(|| other.clone()),
    }
}

fn map_val_to_fid(map: &[MapEntry], v: &Val, fid_ctx: u8) -> Option<Val> {
    match v {
        Val::Field(..) => {
            let idx = map
                .iter()
                .position(|e| matches!(e, MapEntry::Key(k) if k == v))?;
            Some(Val::Fid(fid_ctx, idx as u16))
        }
        // parameters and variables pass through an aggregate's
        // boundary plainly (probed: HAVING SUM(AMT) > :P1 - the
        // slice-9 refusal fell to the gate's own battery statement)
        Val::Fid(..)
        | Val::Int(_)
        | Val::Int64(_)
        | Val::Dec(..)
        | Val::Str(_)
        | Val::Null
        | Val::InParam(_)
        | Val::LocalVar(_) => Some(v.clone()),
        v if is_leaf_val(v) => Some(v.clone()),
        // a pure function over the aggregate's output maps its operands
        // (measured: `.. GROUP BY G HAVING ABS(G) > 1`, `ORDER BY ABS(G)`)
        _ => map_children(v, &mut |c| map_val_to_fid(map, c, fid_ctx)),
    }
}

fn map_bool_to_fids(map: &[MapEntry], b: Bool, fid_ctx: u8) -> Option<Bool> {
    Some(match b {
        Bool::And(l, r) => Bool::And(
            Box::new(map_bool_to_fids(map, *l, fid_ctx)?),
            Box::new(map_bool_to_fids(map, *r, fid_ctx)?),
        ),
        Bool::Or(l, r) => Bool::Or(
            Box::new(map_bool_to_fids(map, *l, fid_ctx)?),
            Box::new(map_bool_to_fids(map, *r, fid_ctx)?),
        ),
        Bool::Not(inner) => {
            Bool::Not(Box::new(map_bool_to_fids(map, *inner, fid_ctx)?))
        }
        Bool::Cmp(op, a, c) => Bool::Cmp(
            op,
            map_val_to_fid(map, &a, fid_ctx)?,
            map_val_to_fid(map, &c, fid_ctx)?,
        ),
        Bool::Missing(v) => Bool::Missing(map_val_to_fid(map, &v, fid_ctx)?),
        Bool::Between(v, lo, hi) => Bool::Between(
            map_val_to_fid(map, &v, fid_ctx)?,
            map_val_to_fid(map, &lo, fid_ctx)?,
            map_val_to_fid(map, &hi, fid_ctx)?,
        ),
        // LIKE / IN / subqueries over aggregate output: unprobed
        _ => return None,
    })
}

/// RETURNING col INTO :var - a begin of field-to-variable
/// assignments at the given context (probed: INSERT reads its store
/// context, UPDATE the NEW record, DELETE the erased stream).
fn emit_returning(out: &mut Vec<u8>, ctx: u8, ret: &[(String, u16)]) {
    out.push(blr::BEGIN);
    for (col, vi) in ret {
        out.push(blr::ASSIGNMENT);
        out.push(blr::FIELD);
        out.push(ctx);
        out.push(col.len() as u8);
        out.extend_from_slice(col.as_bytes());
        out.push(blr::VARIABLE);
        out.extend_from_slice(&vi.to_le_bytes());
    }
    out.push(blr::END);
}

/// blr_dcl_cursor: number, the rse (relation2 alias carrying the
/// CURSOR NAME - the table ALIAS when one is given, else the
/// schema-qualified table), u16 output count, then the outputs:
/// blr_derived_expr-wrapped fields for a plain select, BARE blr_fid
/// slots for an aggregate one. An aggregate select nests
/// blr_aggregate at ctx+1 around an inner rse (whose boolean carries
/// the WHERE), then group_by and the map - the FOR-SELECT layout in a
/// cursor's clothing (all probed).
fn emit_cursor_decl(out: &mut Vec<u8>, d: &CursorDecl) {
    out.push(blr::DCL_CURSOR);
    out.extend_from_slice(&d.num.to_le_bytes());
    if d.scroll {
        out.push(blr::SCROLLABLE);
    }
    out.push(blr::RSE);
    out.push(1);
    if let Some(agg_ctx) = d.agg {
        out.push(blr::AGGREGATE);
        out.push(agg_ctx);
        out.push(blr::RSE);
        out.push(1);
    }
    // a JOIN chain's heads precede the cursor's own stream; the
    // join streams carry the cursor pairing via their cur stamp
    for _ in &d.joins {
        out.push(blr::JOIN);
        out.push(2);
    }
    if d.sub || is_system_relation(&d.table) {
        emit_relation3(out, &d.table);
    } else {
        out.push(blr::RELATION2);
        out.push(d.table.len() as u8);
        out.extend_from_slice(d.table.as_bytes());
    }
    let alias = match &d.alias {
        Some(a) => format!("\"{}\" \"{}\"", d.name, a),
        None => format!("\"{}\" \"{}\".\"{}\"", d.name, relation_schema(&d.table), d.table),
    };
    out.push(alias.len() as u8);
    out.extend_from_slice(alias.as_bytes());
    out.push(d.ctx);
    for (jt, st, jctx, on) in &d.joins {
        emit_stream(out, st, *jctx);
        if *jt != 0 {
            out.push(blr::JOIN_TYPE);
            out.push(*jt);
        }
        out.push(blr::BOOLEAN);
        emit_bool(out, on);
        out.push(blr::END);
    }
    if d.lock {
        out.push(blr::WRITELOCK);
    }
    if let Some(b) = &d.boolean {
        out.push(blr::BOOLEAN);
        emit_bool(out, b);
    }
    if d.agg.is_some() {
        out.push(blr::END);
        out.push(blr::GROUP_BY);
        out.push(d.group_keys.len() as u8);
        for k in &d.group_keys {
            emit_val(out, k);
        }
        out.push(blr::MAP);
        out.extend_from_slice(&(d.map.len() as u16).to_le_bytes());
        emit_map_entries(out, &d.map);
    }
    if !d.sort.is_empty() {
        out.push(blr::SORT);
        out.push(d.sort.len() as u8);
        for (desc, key) in &d.sort {
            emit_sort_key(out, *desc, key);
        }
    }
    out.push(blr::END);
    out.extend_from_slice(&(d.outs.len() as u16).to_le_bytes());
    for o in &d.outs {
        if d.agg.is_none() {
            out.push(blr::DERIVED_EXPR);
            out.push(1);
            // the wrap names each column's OWN stream (probed on a
            // joined cursor: BF 01 00 then BF 01 01)
            out.push(match o {
                Val::Field(fctx, _) => *fctx,
                _ => d.ctx,
            });
        }
        emit_val(out, o);
    }
}

/// Compile a single-FOR-SELECT procedure to the BLR the engine's DSQL
/// stores in `RDB$PROCEDURE_BLR` - byte for byte. The accepted shape:
///
///   CREATE PROCEDURE <name> RETURNS (p1 TYPE [, ...]) AS
///   BEGIN
///     FOR SELECT <cols> FROM <table> [WHERE ...]
///         [ORDER BY key [ASC|DESC] [, ...]]
///         INTO :p1 [, ...]
///     DO SUSPEND;
///   END
///
/// The wrapper, read from the engine's own disassembly: blr_begin;
/// blr_message 1 with 2n+1 dscs (each parameter's dsc FOLLOWED BY a
/// null-flag blr_short, then one final blr_short - the EOF flag); a
/// begin declaring one variable per parameter and initialising each
/// to NULL; blr_stall; two labels; blr_for over the rse - whose
/// STREAM IS CONTEXT 0 (procedure bodies number from 0 where views
/// number from 1) and whose ORDER BY is blr_sort after the boolean
/// (count, then blr_ascending/blr_descending per key); the DO body
/// assigning each selected field to its variable and blr_send-ing
/// message 1 with every variable copied to its blr_parameter2 (value
/// slot, null slot) and the EOF flag set to literal short 1; then,
/// after the loop, the same send with EOF 0. All probed.
pub fn compile_procedure(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P::fresh(&toks);
    if !(p.kw("CREATE") && p.kw("PROCEDURE")) {
        return None;
    }
    // the procedure name leaves no trace in the BLR
    match p.t.get(p.i)? {
        Tok::Ident(w) if !is_keyword(w) => p.i += 1,
        _ => return None,
    }
    let bo = body_compile(&mut p, false, false)?;
    Some(bo.blob)
}

/// A compiled procedure/function body plus what a subroutine
/// declaration needs to describe it.
struct BodyOut {
    blob: Vec<u8>,
    ins: Vec<(String, Dsc)>,
    /// parallel to `ins` / `outs`: a NUMERIC(p, s) / DECIMAL(p, s)
    /// declaration's (sub_type 1|2, precision p) - the catalog keeps
    /// the declared spelling (measured: SUB_TOT_BUDGET's outputs are
    /// sub_type 2, precision 12), which the descriptor alone loses
    in_decls: Vec<Option<(i16, i16)>>,
    out_decls: Vec<Option<(i16, i16)>>,
    /// parallel to `ins`: an input parameter's DEFAULT value SOURCE
    /// (`5`, `'x'`, `NULL`), or None. Procedures only, literals only -
    /// the wire turns the source into RDB$DEFAULT_SOURCE / VALUE.
    in_defaults: Vec<Option<String>>,
    outs: Vec<(String, Dsc)>,
    selectable: bool,
    deterministic: bool,
}

/// Compile `[(inputs)] [RETURNS ...] AS <declares> BEGIN ... END`
/// from the parser's position into a complete `05 .. 4C` body -
/// top-level procedures and DECLAREd subroutines share every law.
/// `func` bodies take `RETURNS <type> [DETERMINISTIC]`, hold ONE
/// unnamed return variable (slot 0), refuse SUSPEND, accept RETURN,
/// and their sends drop the EOF assignment (probed). `sub` bodies
/// skip the end-of-input check, may end with a spare `;`, and emit
/// blr_stall only when they HAVE outputs - a void sub-procedure
/// goes without where a top-level one keeps it (probed).
/// The NUMERIC(p, s) / DECIMAL(p, s) spelling at the parser's position,
/// as (RDB$FIELD_SUB_TYPE 1|2, RDB$FIELD_PRECISION p); None for any
/// other type.
fn numeric_decl(p: &P) -> Option<(i16, i16)> {
    let Some(Tok::Ident(w)) = p.t.get(p.i) else { return None };
    let sub = match w.as_str() {
        "NUMERIC" => 1,
        "DECIMAL" => 2,
        _ => return None,
    };
    if !matches!(p.t.get(p.i + 1), Some(Tok::LParen)) {
        return None;
    }
    match p.t.get(p.i + 2) {
        Some(Tok::Int(prec)) => Some((sub, *prec as i16)),
        _ => None,
    }
}

fn body_compile(p: &mut P, func: bool, sub: bool) -> Option<BodyOut> {
    // optional INPUT parameters: message 0, one dsc + null-flag short
    // per parameter, NO EOF slot
    let mut inputs: Vec<(String, Dsc)> = Vec::new();
    let mut in_defaults: Vec<Option<String>> = Vec::new();
    let mut in_decls: Vec<Option<(i16, i16)>> = Vec::new();
    let mut out_decls: Vec<Option<(i16, i16)>> = Vec::new();
    if matches!(p.t.get(p.i), Some(Tok::LParen)) {
        p.i += 1;
        // `()` - an EMPTY list, the same as none (a function may say it)
        if matches!(p.t.get(p.i), Some(Tok::RParen)) {
            p.i += 1;
        }
        while !inputs.is_empty() || !matches!(p.t.get(p.i.wrapping_sub(1)), Some(Tok::RParen)) {
            let Some(Tok::Ident(name)) = p.t.get(p.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let name = name.clone();
            p.i += 1;
            in_decls.push(numeric_decl(p));
            let dsc = p.cast_target()?;
            // optional DEFAULT / = <literal>. Procedures only (a function
            // parameter default is refused for now); a literal only
            // (integer, optionally signed; string; NULL) - an expression
            // default refuses. Defaults must be TRAILING, as the engine
            // requires (a plain parameter after a defaulted one refuses).
            // the engine PRESERVES the form in RDB$DEFAULT_SOURCE
            // ("DEFAULT 5" vs "= 7"), so capture which one was written
            let form = if p.kw("DEFAULT") {
                Some("DEFAULT")
            } else if matches!(p.t.get(p.i), Some(Tok::Cmp(CmpOp::Eql))) {
                p.i += 1;
                Some("=")
            } else {
                None
            };
            let default = if let Some(form) = form {
                Some(format!("{} {}", form, param_default_source(p)?))
            } else {
                if in_defaults.iter().any(|d| d.is_some()) {
                    return None; // a plain parameter after a defaulted one
                }
                None
            };
            inputs.push((name, dsc));
            in_defaults.push(default);
            match p.t.get(p.i)? {
                Tok::Comma => p.i += 1,
                Tok::RParen => {
                    p.i += 1;
                    break;
                }
                _ => return None,
            }
        }
    }
    p.in_params = inputs.iter().map(|(n, _)| n.clone()).collect();
    // RETURNS: optional (name TYPE, ...) list for procedures - a
    // function takes ONE bare type, its return slot UNNAMED (probed:
    // the subfunc_decl carries an empty output name)
    let mut params: Vec<(String, Dsc)> = Vec::new();
    let mut deterministic = false;
    if func {
        if !p.kw("RETURNS") {
            return None;
        }
        let dsc = p.cast_target()?;
        params.push((String::new(), dsc));
        if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "DETERMINISTIC")
        {
            deterministic = true;
            p.i += 1;
        }
    } else if p.kw("RETURNS") {
        if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
            return None;
        }
        p.i += 1;
        loop {
            let Some(Tok::Ident(name)) = p.t.get(p.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let name = name.clone();
            p.i += 1;
            out_decls.push(numeric_decl(p));
            let dsc = p.cast_target()?;
            params.push((name, dsc));
            match p.t.get(p.i)? {
                Tok::Comma => p.i += 1,
                Tok::RParen => {
                    p.i += 1;
                    break;
                }
                _ => return None,
            }
        }
    }
    // variable numbering: outputs at 0..n, locals after - but in a
    // SUBROUTINE body (procedure and function alike) the INPUTS
    // reserve the slots between: no declares emitted for them, yet
    // locals number past them. A function's slot 0 is its unnamed
    // return. Top-level bodies do NOT reserve (all probed).
    p.local_vars = {
        let mut v: Vec<String> =
            params.iter().map(|(n, _)| n.clone()).collect();
        if sub {
            v.extend(std::iter::repeat_n(String::new(), inputs.len()));
        }
        v
    };
    // SUSPEND refuses in a function body (proc = Some(0) closes it)
    p.proc = Some(if func { 0 } else { params.len() });
    p.in_func = func;
    if !p.kw("AS") {
        return None;
    }
    // zero outer FROM streams from here on - set BEFORE the declare
    // section so cursor declarations may hold subqueries (subselect
    // refuses under a None outer, the ON-clause guard)
    p.outer = Some(0);
    // local DECLAREs: variable numbering CONTINUES after the outputs;
    // procedures INTERLEAVE declare/init per variable (probed - where
    // triggers group)
    let mut locals: Vec<(Dsc, Option<Val>)> = Vec::new();
    // source order of the declaration section: a variable's INIT is
    // DEFERRED past any cursor OR subroutine declarations that follow
    // it, flushing before the next variable's declare or at the
    // section end (probed on cursors and on a var-then-subproc)
    enum DeclItem {
        Var(usize),
        Cur(usize),
        Sub(usize),
    }
    let mut decl_seq: Vec<DeclItem> = Vec::new();
    while p.kw("DECLARE") {
        // DECLARE PROCEDURE / FUNCTION: a nested body compiled by
        // this same machinery into a counted blob
        if p.kw("PROCEDURE") {
            decl_seq.push(DeclItem::Sub(p.sub_decl(false)?));
            continue;
        }
        if p.kw("FUNCTION") {
            decl_seq.push(DeclItem::Sub(p.sub_decl(true)?));
            continue;
        }
        let _ = p.kw("VARIABLE");
        let Some(Tok::Ident(name)) = p.t.get(p.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        p.i += 1;
        // DECLARE <name> [SCROLL] CURSOR FOR (SELECT ...); - shared
        // with trigger bodies (numbering continues past OLD/NEW)
        let scroll = p.kw("SCROLL");
        if p.kw("CURSOR") {
            decl_seq.push(DeclItem::Cur(p.cursor_decls.len()));
            p.cursor_decl(name, scroll)?;
            continue;
        }
        if scroll {
            return None;
        }
        let dsc = p.cast_target()?;
        p.local_vars.push(name);
        let init = if matches!(p.t.get(p.i), Some(Tok::Cmp(CmpOp::Eql))) {
            p.i += 1;
            Some(p.val()?)
        } else {
            None
        };
        decl_seq.push(DeclItem::Var(locals.len()));
        locals.push((dsc, init));
        if !matches!(p.t.get(p.i), Some(Tok::Semi)) {
            return None;
        }
        p.i += 1;
    }
    if !p.kw("BEGIN") {
        return None;
    }
    let mut stmts: Vec<TrigStmt> = Vec::new();
    while !p.kw("END") {
        stmts.push(p.trig_stmt()?);
    }
    if sub {
        // a spare ; may follow a subroutine's END
        if matches!(p.t.get(p.i), Some(Tok::Semi)) {
            p.i += 1;
        }
    } else if p.i != p.t.len() {
        return None;
    }

    let n = params.len();
    // where local declares number from (see local_vars above)
    let var_base = n + if sub { inputs.len() } else { 0 };
    let mut out = vec![blr::VERSION5, blr::BEGIN];
    if !inputs.is_empty() {
        // message 0: the inputs - dsc + null-flag short each, no EOF
        out.push(blr::MESSAGE);
        out.push(0);
        out.extend_from_slice(&((2 * inputs.len()) as u16).to_le_bytes());
        for (_, d) in &inputs {
            emit_dsc(&mut out, *d);
            out.push(blr::SHORT);
            out.push(0);
        }
    }
    // message 1: per output dsc + null-flag short, then the EOF short
    // (a function's message keeps the EOF slot its sends never set)
    out.push(blr::MESSAGE);
    out.push(1);
    out.extend_from_slice(&((2 * n + 1) as u16).to_le_bytes());
    for (_, d) in &params {
        emit_dsc(&mut out, *d);
        out.push(blr::SHORT);
        out.push(0);
    }
    out.push(blr::SHORT);
    out.push(0);
    if !inputs.is_empty() {
        // with inputs, the WHOLE block sits under blr_receive 0; the
        // begin's own blr_end doubles as the receive's end and the
        // final EOF send stays outside it (probed)
        out.push(blr::RECEIVE);
        out.push(0);
    }
    out.push(blr::BEGIN);
    // outputs then locals, ONE variable space, INTERLEAVED
    // declare/init per variable (probed procedure style)
    for (vi, (_, d)) in params.iter().enumerate() {
        out.push(blr::DECLARE);
        out.extend_from_slice(&(vi as u16).to_le_bytes());
        emit_dsc(&mut out, *d);
        out.push(blr::ASSIGNMENT);
        out.push(blr::NULL);
        out.push(blr::VARIABLE);
        out.extend_from_slice(&(vi as u16).to_le_bytes());
    }
    // the declaration section: declares (variables, cursors,
    // subroutines) in SOURCE order, then ALL the variable inits
    // grouped after - the law slice 21 read as per-variable deferral
    // was really this grouping; a two-local probe settled it (the
    // outputs above DO interleave - a different rule for a
    // different slot kind)
    for item in &decl_seq {
        match item {
            DeclItem::Var(li) => {
                let vi = var_base + li;
                out.push(blr::DECLARE);
                out.extend_from_slice(&(vi as u16).to_le_bytes());
                emit_dsc(&mut out, locals[*li].0);
            }
            DeclItem::Cur(ci) => {
                emit_cursor_decl(&mut out, &p.cursor_decls[*ci]);
            }
            DeclItem::Sub(si) => {
                out.extend_from_slice(&p.sub_decls[*si]);
            }
        }
    }
    for (li, (_, init)) in locals.iter().enumerate() {
        out.push(blr::ASSIGNMENT);
        match init {
            Some(v) => emit_val(&mut out, v),
            None => out.push(blr::NULL),
        }
        out.push(blr::VARIABLE);
        out.extend_from_slice(&((var_base + li) as u16).to_le_bytes());
    }
    // a SUBROUTINE goes without the stall when it has no outputs;
    // top-level bodies always carry it (probed)
    if !sub || n > 0 {
        out.push(blr::STALL);
    }
    out.push(blr::LABEL);
    out.push(0);
    out.push(blr::BEGIN);
    // AN EMPTY BODY (`AS BEGIN END`) has no statement list at all - the
    // block is its wrapper alone (measured on 2196: P1 is `label 0, begin,
    // end, end` where a one-statement body is `label 0, begin, begin ..,
    // end, end, end`)
    if !stmts.is_empty() {
        out.push(blr::BEGIN);
        for st in &stmts {
            emit_trig_stmt(&mut out, st);
        }
        out.push(blr::END);
    }
    out.push(blr::END);
    out.push(blr::END);
    if func {
        emit_send_ret(&mut out);
    } else {
        emit_send(&mut out, n, 0);
    }
    out.push(blr::END);
    out.push(blr::EOC);
    Some(BodyOut {
        blob: out,
        ins: inputs,
        in_defaults,
        in_decls,
        out_decls,
        outs: params,
        selectable: p.saw_suspend,
        deterministic,
    })
}

/// Read an input parameter's DEFAULT literal into its SOURCE text - an
/// integer (optionally signed), a string literal, or NULL. Anything
/// else (an expression, a context function) refuses (the wire turns this
/// text into RDB$DEFAULT_SOURCE / VALUE with the same helpers a column
/// default uses).
fn param_default_source(p: &mut P) -> Option<String> {
    let neg = matches!(p.t.get(p.i), Some(Tok::Minus));
    if neg {
        p.i += 1;
    }
    let src = match p.t.get(p.i)? {
        Tok::Int(n) => {
            p.i += 1;
            if neg { format!("-{}", n) } else { format!("{}", n) }
        }
        Tok::Str(sv) if !neg => {
            let sv = sv.clone();
            p.i += 1;
            format!("'{}'", sv.replace('\'', "''"))
        }
        Tok::Ident(w) if !neg && w.eq_ignore_ascii_case("NULL") => {
            p.i += 1;
            "NULL".to_string()
        }
        // a session / clock CONTEXT default keyword - captured verbatim
        // (uppercased); the server stores the engine's keyword BLR and
        // resolves it per call. Kept in step with the server's
        // ctx_default_blr / eval_ctx_default: the forms it can fill.
        Tok::Ident(w)
            if !neg
                && matches!(
                    w.to_ascii_uppercase().as_str(),
                    "CURRENT_USER"
                        | "USER"
                        | "CURRENT_ROLE"
                        | "CURRENT_CONNECTION"
                        | "CURRENT_DATE"
                        | "CURRENT_TIME"
                        | "CURRENT_TIMESTAMP"
                ) =>
        {
            let s = w.to_ascii_uppercase();
            p.i += 1;
            s
        }
        _ => return None,
    };
    Some(src)
}

/// A function body's row send: message 1, the ONE unnamed return
/// variable through blr_parameter2 - and NO EOF assignment, though
/// the message declares the slot (probed)
fn emit_send_ret(out: &mut Vec<u8>) {
    out.push(blr::SEND);
    out.push(1);
    out.push(blr::BEGIN);
    out.push(blr::ASSIGNMENT);
    out.push(blr::VARIABLE);
    out.extend_from_slice(&0u16.to_le_bytes());
    out.push(blr::PARAMETER2);
    out.push(1);
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.push(blr::END);
}

/// A trigger-body statement.
enum TrigStmt {
    /// `NEW.col = <value>;` - blr_assignment(value, field). Only NEW
    /// fields are writable (the engine rejects OLD targets, and NEW
    /// in AFTER triggers - catalog-time errors, not BLR shapes)
    Assign(Val, Val),
    /// IF (<cond>) THEN <stmt> [ELSE <stmt>]
    If(Bool, Box<TrigStmt>, Option<Box<TrigStmt>>),
    /// BEGIN ... END - compiles as a DOUBLE blr_begin (probed)
    Block(Vec<TrigStmt>),
    /// INSERT INTO rel (cols) VALUES (vals) - blr_store
    /// the trailing list is RETURNING col INTO :var pairs - with
    /// any, INSERT = blr_store2 with a second returning begin,
    /// UPDATE = blr_modify2 under a blr_singular rse, DELETE = a
    /// begin(returning-assigns, erase) under a singular rse (probed)
    Insert(Stream, u8, Vec<(String, Val)>, Vec<(String, u16)>),
    /// DELETE FROM rel [WHERE ...] - for(marks(1,4), rse), erase
    Delete(Stream, u8, Option<Bool>, Vec<(String, u16)>),
    /// UPDATE rel SET ... [WHERE ...] - for(marks(1,4), rse),
    /// modify(org, new, assignments)
    Update(Stream, u8, u8, Vec<(Val, Val)>, Option<Bool>, Vec<(String, u16)>),
    /// WHILE (cond) DO stmt - blr_label N, blr_loop, begin,
    /// blr_if(cond, body, blr_leave N), end (probed)
    While(u8, Bool, Box<TrigStmt>),
    /// SUSPEND; - the row send: every output variable to its
    /// blr_parameter2 pair plus the EOF flag as literal short 1
    Suspend(usize),
    /// EXECUTE PROCEDURE name [(inputs)] [RETURNING_VALUES :v, ...]
    ExecProc(String, Vec<Val>, Vec<u16>),
    /// EXCEPTION name; - blr_abort by name
    ExceptionRaise(String, Option<String>),
    /// a bare `EXCEPTION;` inside a handler - RE-RAISE the caught
    /// exception: blr_abort with condition 5 (blr_raise), no name
    /// (probed from the engine's stored BLR for `WHEN ... DO EXCEPTION;`)
    ExceptionReraise,
    /// EXIT; - blr_leave 0: leaves the wrapper label
    Exit,
    /// `LEAVE;` - bare, ends the innermost loop: blr_leave <loop label>
    LeaveLoop(u8),
    /// `CONTINUE;` - bare, next iteration of the innermost loop:
    /// blr_continue_loop <loop label>
    ContinueLoop(u8),
    /// POST_EVENT <value>; - blr_post
    PostEvent(Val),
    /// BEGIN ... WHEN <code> DO <stmt> ... END - blr_block with one
    /// error-handler section PER WHEN (probed sequential)
    HandledBlock(Vec<TrigStmt>, Vec<(Vec<HandlerCode>, TrigStmt)>),
    /// UPDATE OR INSERT INTO rel (cols) VALUES (vals) MATCHING (m) -
    /// a begin holding a modify-loop (blr_equiv on the matching
    /// column) and a row_count==0-guarded store; contexts allocated
    /// store, modify-new, rse-org IN THAT ORDER (probed)
    UpdateOrInsert {
        rel: Stream,
        store_ctx: u8,
        new_ctx: u8,
        org_ctx: u8,
        cols: Vec<String>,
        vals: Vec<Val>,
        matching: Vec<(String, usize)>,
    },
    /// (FOR) SELECT - the whole probed select machinery as ONE
    /// statement inside a body
    ForSel(Box<ForSel>),
    /// IN AUTONOMOUS TRANSACTION DO <stmt>
    AutoTrans(Box<TrigStmt>),
    /// OPEN c; / CLOSE c; - blr_cursor_stmt sub-verbs 0 and 1
    CursorOp(u8, u16),
    /// FETCH c [INTO :v, ...]; - sub-verb 2 + the into-assignments
    /// (an INTO-less fetch carries an empty begin/end)
    CursorFetch(u16, Vec<(Val, u16)>),
    /// FETCH <direction> FROM c: sub-verb 3, direction byte, the
    /// offset value (blr_null unless ABSOLUTE/RELATIVE), assigns
    CursorFetchDir(u16, u8, Option<i32>, Vec<(Val, u16)>),
    /// EXECUTE STATEMENT '<sql>'; - blr_exec_sql + the sql literal
    ExecSql(Val),
    /// RETURN <expr>; in a function body: begin(assign to the
    /// unnamed slot 0, the no-EOF send, blr_leave 0) end (probed)
    Return(Val),
    /// EXECUTE PROCEDURE on a DECLAREd subroutine:
    /// blr_invoke_procedure, id clause (sub + counted name), input
    /// values, output variables (probed)
    SubCall(String, Vec<Val>, Vec<u16>),
    /// EXECUTE PROCEDURE PKG.P: blr_exec_proc2 - counted package +
    /// name, u16-counted values and variables (probed)
    PkgCall(String, String, Vec<Val>, Vec<u16>),
    /// [FOR] EXECUTE STATEMENT '<sql>' INTO :v, ...: blr_exec_into,
    /// u16 out-count, the sql, then flag 1 (singleton) or flag 0 +
    /// the labeled loop's DO statement; the variables LAST (probed)
    ExecInto {
        sql: Val,
        vars: Vec<u16>,
        run: Option<(u8, Box<TrigStmt>)>,
    },
    /// the FULL [FOR] EXECUTE STATEMENT - parameters (positional or
    /// name := value) and/or the ON EXTERNAL / AS USER / PASSWORD /
    /// ROLE modifiers: blr_exec_stmt with tag-prefixed clauses in
    /// fixed order - 1 in-count, 2 out-count, 3 sql, 4 the loop's
    /// DO statement, 5 data source, 6 user, 7 password, 14 role,
    /// 11 positional / 12 named input values, 13 output variables,
    /// blr_end (probed; order from the engine's own genBlr)
    ExecStmtFull {
        sql: Val,
        ins: Vec<(Option<String>, Val)>,
        vars: Vec<u16>,
        data_src: Option<Val>,
        user: Option<Val>,
        pwd: Option<Val>,
        role: Option<Val>,
        run: Option<(u8, Box<TrigStmt>)>,
    },
    /// INSERT INTO tgt (cols) SELECT ... - a marks(1, 4)-stamped
    /// FOR loop over the source rse storing one row per source row;
    /// the SOURCE stream numbers first, the target after (probed)
    InsertSel {
        src: Stream,
        src_ctx: u8,
        tgt: Stream,
        tgt_ctx: u8,
        cols: Vec<String>,
        vals: Vec<Val>,
        wher: Option<Bool>,
    },
    /// MERGE INTO tgt USING src ON <bool>: a marks(1, 6)-stamped
    /// for-loop over a JOIN of source and target - LEFT when a NOT
    /// MATCHED branch needs unmatched rows, INNER otherwise -
    /// branching on missing(dbkey(target)). Branches of one kind
    /// form an if-else CHAIN in SQL order; each conditional branch
    /// is if(cond, action, <next>), the last conditional one gets a
    /// bare end, an unconditional LAST branch fills the else slot
    /// directly. The rse boolean ORs the two kind-terms - matched
    /// first: [and(]not(missing)[, or-chain of conds)] and
    /// [and(]missing[, or-chain)] - each simplified to its bare
    /// missing-test when any branch of the kind is unconditional,
    /// and OMITTED entirely for an unconditional matched-only merge
    /// (all probed)
    Merge {
        src: Stream,
        src_ctx: u8,
        tgt: Stream,
        tgt_ctx: u8,
        on: Bool,
        /// WHEN MATCHED [AND cond] THEN <action>, in SQL order
        matched: Vec<(Option<Bool>, MergeAct)>,
        /// WHEN NOT MATCHED [AND cond] THEN INSERT: (cond, store
        /// ctx, columns, values), in SQL order
        notmatched: Vec<(Option<Bool>, u8, Vec<String>, Vec<Val>)>,
    },
    /// DELETE ... WHERE CURRENT OF c - blr_erase at the CURSOR's
    /// context, then marks(1, 1) - MARK_POSITIONED trails the erase
    /// where a DML loop's marks lead its rse (probed)
    PosDelete(u8),
    /// UPDATE ... SET ... WHERE CURRENT OF c - blr_modify from the
    /// cursor's context to a FRESH one, marks(1, 1), the assignments
    PosUpdate(u8, u8, Vec<(Val, Val)>),
}

/// A MERGE matched-branch action: UPDATE SET (each branch claims
/// its OWN new-record context, in branch order) or DELETE.
enum MergeAct {
    Upd(u8, Vec<(String, Val)>),
    Del,
}

/// A DECLARE ... CURSOR FOR (SELECT ...): the rse's relation2 alias
/// carries the CURSOR NAME (like a derived table's - with a table
/// alias the string is `"CX" "E"`, without it `"CX" "PUBLIC"."TBL"`).
/// Plain outputs wrap in blr_derived_expr; an AGGREGATE cursor nests
/// blr_aggregate at ctx+1 (a second stream slot) and its outputs are
/// BARE blr_fid slots - no wrapper (probed).
struct CursorDecl {
    name: String,
    num: u16,
    /// DECLARE ... SCROLL CURSOR - blr_scrollable before the rse;
    /// backward/positioned fetch directions demand it
    scroll: bool,
    /// (SELECT ... WITH LOCK) - blr_writelock in the cursor's rse
    lock: bool,
    /// declared inside a subroutine: the rse takes blr_relation3
    sub: bool,
    /// JOIN chain inside the cursor's rse: (join_type, right stream
    /// - pre-stamped with the cursor pairing - its ctx, the ON);
    /// each output's derived_expr wrap carries its column's OWN
    /// stream context (probed)
    joins: Vec<(u8, Stream, u8, Bool)>,
    table: String,
    alias: Option<String>,
    ctx: u8,
    /// Some(agg_ctx) marks an aggregate cursor
    agg: Option<u8>,
    map: Vec<MapEntry>,
    group_keys: Vec<Val>,
    /// fetch sources: Field(ctx, name) plain, Fid(agg_ctx, slot) agg
    outs: Vec<Val>,
    boolean: Option<Bool>,
    sort: Vec<(bool, Val)>,
}

/// What a WHEN clause catches.
enum HandlerCode {
    /// WHEN ANY - blr_default_code
    Any,
    /// WHEN EXCEPTION <name> - 9, 0, counted name
    Exception(String),
    /// WHEN GDSCODE <name> - 0, counted name (uppercased)
    Gds(String),
    /// WHEN SQLCODE <n> - 1, i16 little-endian
    SqlCode(i16),
    /// WHEN SQLSTATE '<s>' - 8, counted string (probed)
    SqlState(String),
}

/// A FOR SELECT / SELECT INTO inside a body: `label` is Some for the
/// looping form (blr_label N + blr_for) and None for the singular
/// (blr_for over blr_singular, no label).
/// A RECURSIVE cte in a body FOR SELECT: blr_recurse with an anchor
/// branch (a real stream, the cte name riding the relation2 alias
/// like every inlined cte) and a STREAM-LESS recursive branch whose
/// references read fid(recurse ctx, slot). Single-column, UNION ALL
/// (probed).
#[derive(Clone, Debug, PartialEq)]
struct RecCte {
    /// the context the recursion binds (fid reads); the SECONDARY
    /// recursive context (GEN_stuff_context's extra byte) sits one
    /// slot BELOW it
    ctx: u8,
    secondary: u8,
    /// the anchor: table name, its context, WHERE, the single item
    anchor_table: String,
    /// the alias text: "CTE" "PUBLIC"."TABLE" (the inlined-cte law)
    anchor_alias: String,
    anchor_ctx: u8,
    anchor_wher: Option<Bool>,
    /// one entry per cte column: the anchor's item and whether it
    /// wraps in cast(int64). The unification is PER COLUMN (probed
    /// on a two-column recursion): only the column whose RECURSIVE
    /// item is integer arithmetic promotes - its sibling stays bare
    anchor_items: Vec<(Val, bool)>,
    rec_wher: Option<Bool>,
    rec_items: Vec<Val>,
}

struct ForSel {
    label: Option<u8>,
    stream: Stream,
    ctx: u8,
    /// FOR SELECT ... AS CURSOR <name>: the name rides the rse's
    /// relation2 alias exactly like a DECLAREd cursor's, the
    /// into-assign sources wrap in blr_derived_expr, and positioned
    /// DML in the DO body may target it (probed)
    cursor: Option<String>,
    /// WITH LOCK: blr_writelock between the stream and the boolean
    lock: bool,
    /// JOIN chain: (join_type, right stream, its ctx, the ON) per
    /// join, left-nested exactly like a view's (probed at body
    /// numbering); qualified-only resolution across the chain
    joins: Vec<(u8, Stream, u8, Bool)>,
    /// WINDOW clause: per window (encounter order of distinct
    /// specs) its context, partition keys, order keys and map -
    /// passthrough columns live in the DEFAULT window (probed)
    windows: Vec<Win>,
    /// SELECT DISTINCT: blr_project over the select columns, after
    /// the boolean (probed at body numbering)
    distinct: bool,
    /// PLAN (tbl NATURAL | tbl INDEX (names)): blr_plan +
    /// blr_retrieve + the stream re-emitted + blr_sequential or
    /// blr_indices with counted names, last in the rse (probed)
    plan: Option<PlanKind>,
    /// UNION [ALL]: the union claims the statement's FIRST slot,
    /// branch streams follow; per branch its rse (WHERE inside) and
    /// map; a DISTINCT union appends blr_project over the fids
    /// (probed at body numbering)
    union_: Option<BodyUnion>,
    aggregate: bool,
    /// the aggregate node's context (the next free one after the FROM
    /// streams - a derived table with an aggregate inside takes two)
    agg_ctx: u8,
    map: Vec<MapEntry>,
    group_keys: Vec<Val>,
    boolean: Option<Bool>,
    having: Option<Bool>,
    sort: Vec<(bool, Val)>,
    first: Option<Val>,
    skip: Option<Val>,
    col_vals: Vec<Val>,
    into: Vec<u16>,
    do_stmt: Option<Box<TrigStmt>>,
    /// WITH RECURSIVE: the whole rse is the recursion tower
    recurse: Option<RecCte>,
}

/// The body of a blr_map: slot indexes then entries - group keys,
/// aggregate verbs, or named window functions.
fn emit_map_entries(out: &mut Vec<u8>, map: &[MapEntry]) {
    for (fi, e) in map.iter().enumerate() {
        out.extend_from_slice(&(fi as u16).to_le_bytes());
        match e {
            MapEntry::Key(v) => emit_val(out, v),
            MapEntry::Agg(verb, arg) => {
                out.push(*verb);
                if let Some(a) = arg {
                    emit_val(out, a);
                }
            }
            MapEntry::Fn(name, args) => {
                out.push(blr::AGG_FUNCTION);
                out.push(name.len() as u8);
                out.extend_from_slice(name.as_bytes());
                out.push(args.len() as u8);
                for a in args {
                    emit_val(out, a);
                }
            }
        }
    }
}

/// The probed PLAN shapes.
enum PlanKind {
    Natural,
    Index(Vec<String>),
    /// PLAN (tbl ORDER idx): blr_navigational + ONE counted name -
    /// no count byte, unlike blr_indices (probed); the engine
    /// demands a matching ORDER BY
    Order(String),
}

/// A body FOR SELECT's UNION: the union context, ALL or distinct,
/// and per branch its stream, context, WHERE and select columns.
struct BodyUnion {
    ctx: u8,
    all: bool,
    branches: Vec<(Stream, u8, Option<Bool>, Vec<Val>)>,
}

/// One window of a windowed select: blr_partition_by's operands -
/// or blr_window_win's when a FRAME rides along (unit, two bounds,
/// each a code and an optional value; probed).
/// A window call: the map entry, partition keys, order keys, frame.
type WinSpec = (
    MapEntry,
    Vec<Val>,
    Vec<(bool, Val)>,
    Option<(u8, (u8, Option<Val>), (u8, Option<Val>))>,
);

#[derive(Clone, Debug, PartialEq)]
struct Win {
    ctx: u8,
    part: Vec<Val>,
    /// each partition key REMAPPED onto the window's own map: a column's
    /// slot (shared by a repeat), an expression rebuilt over its columns'
    /// slots (measured: `PARTITION BY UPPER(S)` maps S, remaps UPPER(fid))
    remap: Vec<Val>,
    ord: Vec<(bool, Val)>,
    map: Vec<MapEntry>,
    frame: Option<(u8, (u8, Option<Val>), (u8, Option<Val>))>,
}

/// The row/EOF send of a procedure: message 1, every output variable
/// through blr_parameter2 (value slot 2i, null slot 2i+1), the EOF
/// flag (parameter 2n) as a literal short.
fn emit_send(out: &mut Vec<u8>, n: usize, eof: u16) {
    out.push(blr::SEND);
    out.push(1);
    out.push(blr::BEGIN);
    for vi in 0..n {
        out.push(blr::ASSIGNMENT);
        out.push(blr::VARIABLE);
        out.extend_from_slice(&(vi as u16).to_le_bytes());
        out.push(blr::PARAMETER2);
        out.push(1);
        out.extend_from_slice(&((2 * vi) as u16).to_le_bytes());
        out.extend_from_slice(&((2 * vi + 1) as u16).to_le_bytes());
    }
    out.push(blr::ASSIGNMENT);
    out.push(blr::LITERAL);
    out.push(blr::SHORT);
    out.push(0);
    out.extend_from_slice(&eof.to_le_bytes());
    out.push(blr::PARAMETER);
    out.push(1);
    out.extend_from_slice(&((2 * n) as u16).to_le_bytes());
    out.push(blr::END);
}

fn emit_trig_stmt(out: &mut Vec<u8>, st: &TrigStmt) {
    match st {
        TrigStmt::Assign(src, target) => {
            out.push(blr::ASSIGNMENT);
            emit_val(out, src);
            emit_val(out, target);
        }
        TrigStmt::If(cond, then, els) => {
            out.push(blr::IF);
            emit_bool(out, cond);
            emit_trig_stmt(out, then);
            match els {
                Some(e) => emit_trig_stmt(out, e),
                // a missing ELSE is a bare blr_end in the else slot
                None => out.push(blr::END),
            }
        }
        // an EMPTY block is its wrapper alone - `begin end` (measured on
        // 2196, nested and as an IF's branch alike)
        TrigStmt::Block(stmts) if stmts.is_empty() => {
            out.push(blr::BEGIN);
            out.push(blr::END);
        }
        TrigStmt::Block(stmts) => {
            out.push(blr::BEGIN);
            out.push(blr::BEGIN);
            for st in stmts {
                emit_trig_stmt(out, st);
            }
            out.push(blr::END);
            out.push(blr::END);
        }
        TrigStmt::Insert(rel, ctx, sets, ret) => {
            out.push(if ret.is_empty() {
                blr::STORE
            } else {
                blr::STORE2
            });
            emit_stream(out, rel, *ctx);
            out.push(blr::BEGIN);
            for (col, v) in sets {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                out.push(blr::FIELD);
                out.push(*ctx);
                out.push(col.len() as u8);
                out.extend_from_slice(col.as_bytes());
            }
            out.push(blr::END);
            if !ret.is_empty() {
                emit_returning(out, *ctx, ret);
            }
        }
        TrigStmt::Delete(rel, ctx, wher, ret) => {
            out.push(blr::FOR);
            out.push(blr::MARKS);
            out.push(1);
            out.push(4);
            if !ret.is_empty() {
                // RETURNING makes the loop SINGULAR (probed)
                out.push(blr::SINGULAR);
            }
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, rel, *ctx);
            if let Some(b) = wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, b);
            }
            out.push(blr::END);
            if ret.is_empty() {
                out.push(blr::ERASE);
                out.push(*ctx);
            } else {
                // DELETE's returning goes FIRST, in a begin wrapping
                // both it and the plain erase - no erase2 (probed)
                out.push(blr::BEGIN);
                emit_returning(out, *ctx, ret);
                out.push(blr::ERASE);
                out.push(*ctx);
                out.push(blr::END);
            }
        }
        TrigStmt::Suspend(n) => emit_send(out, *n, 1),
        TrigStmt::ExecProc(name, ins, outs) => {
            out.push(blr::EXEC_PROC);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&(ins.len() as u16).to_le_bytes());
            for v in ins {
                emit_val(out, v);
            }
            out.extend_from_slice(&(outs.len() as u16).to_le_bytes());
            for vi in outs {
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
        }
        TrigStmt::ExceptionRaise(name, message) => {
            out.push(blr::ABORT);
            match message {
                None => {
                    out.push(2); // condition 2: exception by name
                    out.push(name.len() as u8);
                    out.extend_from_slice(name.as_bytes());
                }
                Some(msg) => {
                    // condition 6: exception with a message override,
                    // then a blr_literal blr_text2 (charset 0, u16 length)
                    out.push(6);
                    out.push(name.len() as u8);
                    out.extend_from_slice(name.as_bytes());
                    out.push(21); // blr_literal
                    out.push(15); // blr_text2
                    out.extend_from_slice(&0u16.to_le_bytes());
                    out.extend_from_slice(&(msg.len() as u16).to_le_bytes());
                    out.extend_from_slice(msg.as_bytes());
                }
            }
        }
        TrigStmt::ExceptionReraise => {
            // condition 5 = blr_raise: re-raise the caught exception
            out.push(blr::ABORT);
            out.push(5);
        }
        TrigStmt::Exit => {
            out.push(blr::LEAVE);
            out.push(0);
        }
        TrigStmt::LeaveLoop(l) => {
            out.push(blr::LEAVE);
            out.push(*l);
        }
        TrigStmt::ContinueLoop(l) => {
            out.push(blr::CONTINUE_LOOP);
            out.push(*l);
        }
        TrigStmt::PostEvent(v) => {
            out.push(blr::POST);
            emit_val(out, v);
        }
        TrigStmt::HandledBlock(stmts, handlers) => {
            out.push(blr::BLOCK);
            out.push(blr::BEGIN);
            for st in stmts {
                emit_trig_stmt(out, st);
            }
            out.push(blr::END);
            for (codes, handler) in handlers {
                out.push(blr::ERROR_HANDLER);
                // one error-handler section may guard SEVERAL conditions
                // (WHEN EXCEPTION A, EXCEPTION B DO ...): the u16 count is
                // how many codes follow, then each code in order (probed)
                out.extend_from_slice(&(codes.len() as u16).to_le_bytes());
                for code in codes {
                    match code {
                        HandlerCode::Any => out.push(blr::DEFAULT_CODE),
                        HandlerCode::Exception(name) => {
                            out.push(blr::EXCEPTION_CODE);
                            out.push(0);
                            out.push(name.len() as u8);
                            out.extend_from_slice(name.as_bytes());
                        }
                        HandlerCode::Gds(name) => {
                            out.push(blr::GDS_CODE);
                            out.push(name.len() as u8);
                            out.extend_from_slice(name.as_bytes());
                        }
                        HandlerCode::SqlCode(n) => {
                            out.push(blr::SQLCODE_CODE);
                            out.extend_from_slice(&n.to_le_bytes());
                        }
                        HandlerCode::SqlState(s) => {
                            out.push(blr::SQLSTATE_CODE);
                            out.push(s.len() as u8);
                            out.extend_from_slice(s.as_bytes());
                        }
                    }
                }
                // a BLOCK as the handler's body nests blr_block AGAIN
                // with no handler section of its own (probed)
                match handler {
                    // ...but an EMPTY one is `begin end`, no blr_block
                    // (measured: `WHEN ANY DO BEGIN END` on 2196)
                    TrigStmt::Block(inner) if inner.is_empty() => {
                        out.push(blr::BEGIN);
                        out.push(blr::END);
                    }
                    TrigStmt::Block(inner) => {
                        out.push(blr::BLOCK);
                        out.push(blr::BEGIN);
                        for st in inner {
                            emit_trig_stmt(out, st);
                        }
                        out.push(blr::END);
                        out.push(blr::END);
                    }
                    other => emit_trig_stmt(out, other),
                }
            }
            out.push(blr::END);
        }
        TrigStmt::AutoTrans(inner) => {
            out.push(blr::AUTO_TRANS);
            out.push(0);
            emit_trig_stmt(out, inner);
        }
        TrigStmt::CursorOp(sub, num) => {
            out.push(blr::CURSOR_STMT);
            out.push(*sub);
            out.extend_from_slice(&num.to_le_bytes());
        }
        TrigStmt::CursorFetch(num, assigns) => {
            out.push(blr::CURSOR_STMT);
            out.push(2);
            out.extend_from_slice(&num.to_le_bytes());
            out.push(blr::BEGIN);
            for (src, vi) in assigns {
                out.push(blr::ASSIGNMENT);
                emit_val(out, src);
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
            out.push(blr::END);
        }
        TrigStmt::CursorFetchDir(num, code, off, assigns) => {
            out.push(blr::CURSOR_STMT);
            out.push(3);
            out.extend_from_slice(&num.to_le_bytes());
            out.push(*code);
            match off {
                Some(n) => emit_val(out, &Val::Int(*n)),
                None => out.push(blr::NULL),
            }
            out.push(blr::BEGIN);
            for (src, vi) in assigns {
                out.push(blr::ASSIGNMENT);
                emit_val(out, src);
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
            out.push(blr::END);
        }
        TrigStmt::ExecSql(sql) => {
            out.push(blr::EXEC_SQL);
            emit_val(out, sql);
        }
        TrigStmt::Return(v) => {
            out.push(blr::BEGIN);
            out.push(blr::ASSIGNMENT);
            emit_val(out, v);
            out.push(blr::VARIABLE);
            out.extend_from_slice(&0u16.to_le_bytes());
            emit_send_ret(out);
            out.push(blr::LEAVE);
            out.push(0);
            out.push(blr::END);
        }
        TrigStmt::PkgCall(pkg, name, ins, outs) => {
            out.push(blr::EXEC_PROC2);
            out.push(pkg.len() as u8);
            out.extend_from_slice(pkg.as_bytes());
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&(ins.len() as u16).to_le_bytes());
            for v in ins {
                emit_val(out, v);
            }
            out.extend_from_slice(&(outs.len() as u16).to_le_bytes());
            for vi in outs {
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
        }
        TrigStmt::SubCall(name, ins, outs) => {
            out.push(blr::INVOKE_PROCEDURE);
            out.push(1); // id clause
            out.push(4); // ... a subroutine
            out.push(3); // ... by name
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
            out.push(blr::END);
            if !ins.is_empty() {
                out.push(3); // input values
                out.extend_from_slice(&(ins.len() as u16).to_le_bytes());
                for v in ins {
                    emit_val(out, v);
                }
            }
            if !outs.is_empty() {
                out.push(5); // output variables
                out.extend_from_slice(&(outs.len() as u16).to_le_bytes());
                for vi in outs {
                    out.push(blr::VARIABLE);
                    out.extend_from_slice(&vi.to_le_bytes());
                }
            }
            out.push(blr::END);
        }
        TrigStmt::ExecInto { sql, vars, run } => {
            if let Some((label, _)) = run {
                out.push(blr::LABEL);
                out.push(*label);
            }
            out.push(blr::EXEC_INTO);
            out.extend_from_slice(&(vars.len() as u16).to_le_bytes());
            emit_val(out, sql);
            match run {
                Some((_, body)) => {
                    out.push(0);
                    emit_trig_stmt(out, body);
                }
                None => out.push(1),
            }
            for vi in vars {
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
        }
        TrigStmt::ExecStmtFull {
            sql,
            ins,
            vars,
            data_src,
            user,
            pwd,
            role,
            run,
        } => {
            if let Some((label, _)) = run {
                out.push(blr::LABEL);
                out.push(*label);
            }
            out.push(blr::EXEC_STMT);
            if !ins.is_empty() {
                out.push(1); // blr_exec_stmt_inputs
                out.extend_from_slice(&(ins.len() as u16).to_le_bytes());
            }
            if !vars.is_empty() {
                out.push(2); // blr_exec_stmt_outputs
                out.extend_from_slice(&(vars.len() as u16).to_le_bytes());
            }
            out.push(3); // blr_exec_stmt_sql
            emit_val(out, sql);
            if let Some((_, body)) = run {
                out.push(4); // blr_exec_stmt_proc_block
                emit_trig_stmt(out, body);
            }
            for (tag, v) in
                [(5u8, data_src), (6, user), (7, pwd), (14, role)]
            {
                if let Some(v) = v {
                    out.push(tag);
                    emit_val(out, v);
                }
            }
            if !ins.is_empty() {
                let named = ins[0].0.is_some();
                out.push(if named { 12 } else { 11 });
                for (n, v) in ins {
                    if let Some(n) = n {
                        out.push(n.len() as u8);
                        out.extend_from_slice(n.as_bytes());
                    }
                    emit_val(out, v);
                }
            }
            if !vars.is_empty() {
                out.push(13); // blr_exec_stmt_out_params
                for vi in vars {
                    out.push(blr::VARIABLE);
                    out.extend_from_slice(&vi.to_le_bytes());
                }
            }
            out.push(blr::END);
        }
        TrigStmt::InsertSel {
            src,
            src_ctx,
            tgt,
            tgt_ctx,
            cols,
            vals,
            wher,
        } => {
            out.push(blr::FOR);
            out.push(blr::MARKS);
            out.push(1);
            out.push(4);
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, src, *src_ctx);
            if let Some(b) = wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, b);
            }
            out.push(blr::END);
            out.push(blr::STORE);
            emit_stream(out, tgt, *tgt_ctx);
            out.push(blr::BEGIN);
            for (c, v) in cols.iter().zip(vals) {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                out.push(blr::FIELD);
                out.push(*tgt_ctx);
                out.push(c.len() as u8);
                out.extend_from_slice(c.as_bytes());
            }
            out.push(blr::END);
        }
        TrigStmt::Merge {
            src,
            src_ctx,
            tgt,
            tgt_ctx,
            on,
            matched,
            notmatched,
        } => {
            // one probed sentence: for(marks(1, MERGE|FOR_UPDATE),
            // rse(join2(source, target, [left], ON), [branch-union
            // boolean]), if(<matched test>, ...)). Branch chains and
            // union terms per the header comment on the variant.
            out.push(blr::FOR);
            out.push(blr::MARKS);
            out.push(1);
            out.push(6);
            out.push(blr::RSE);
            out.push(1);
            out.push(blr::JOIN);
            out.push(2);
            emit_stream(out, src, *src_ctx);
            emit_stream(out, tgt, *tgt_ctx);
            if !notmatched.is_empty() {
                out.push(blr::JOIN_TYPE);
                out.push(1);
            }
            out.push(blr::BOOLEAN);
            emit_bool(out, on);
            out.push(blr::END); // closes the join
            let miss = |out: &mut Vec<u8>| {
                out.push(blr::MISSING);
                out.push(blr::DBKEY);
                out.push(*tgt_ctx);
            };
            // or-chain of a kind's branch conditions: left-nested 39s
            let orchain = |out: &mut Vec<u8>, conds: &[&Bool]| {
                for _ in 1..conds.len() {
                    out.push(blr::OR);
                }
                for c in conds {
                    emit_bool(out, c);
                }
            };
            let m_conds: Vec<&Bool> =
                matched.iter().filter_map(|(c, _)| c.as_ref()).collect();
            let m_uncond = matched.iter().any(|(c, _)| c.is_none());
            let nm_conds: Vec<&Bool> =
                notmatched.iter().filter_map(|(c, ..)| c.as_ref()).collect();
            let nm_uncond = notmatched.iter().any(|(c, ..)| c.is_none());
            // the rse boolean - matched term first, each term
            // simplified to its bare missing-test when the kind has
            // an unconditional branch; a matched-only merge drops
            // even the not(missing) (its INNER join already filters)
            // and with an unconditional branch has NO boolean at all
            if notmatched.is_empty() {
                if !m_uncond {
                    out.push(blr::BOOLEAN);
                    orchain(out, &m_conds);
                }
            } else {
                out.push(blr::BOOLEAN);
                if !matched.is_empty() {
                    out.push(blr::OR);
                    if m_uncond {
                        out.push(blr::NOT);
                        miss(out);
                    } else {
                        out.push(blr::AND);
                        out.push(blr::NOT);
                        miss(out);
                        orchain(out, &m_conds);
                    }
                }
                if nm_uncond {
                    miss(out);
                } else {
                    out.push(blr::AND);
                    miss(out);
                    orchain(out, &nm_conds);
                }
            }
            out.push(blr::END); // closes the rse
            let emit_m_act = |out: &mut Vec<u8>, act: &MergeAct| match act {
                MergeAct::Upd(new_ctx, sets) => {
                    out.push(blr::MODIFY);
                    out.push(*tgt_ctx);
                    out.push(*new_ctx);
                    out.push(blr::MARKS);
                    out.push(1);
                    out.push(2);
                    out.push(blr::BEGIN);
                    for (col, v) in sets {
                        out.push(blr::ASSIGNMENT);
                        emit_val(out, v);
                        out.push(blr::FIELD);
                        out.push(*new_ctx);
                        out.push(col.len() as u8);
                        out.extend_from_slice(col.as_bytes());
                    }
                    out.push(blr::END);
                }
                MergeAct::Del => {
                    out.push(blr::ERASE);
                    out.push(*tgt_ctx);
                    out.push(blr::MARKS);
                    out.push(1);
                    out.push(2);
                }
            };
            // a kind's branches chain if(cond, action, <next>) in SQL
            // order; the last conditional branch gets a bare end, an
            // unconditional last branch fills the else slot directly
            // each intermediate if's else slot IS the next if by
            // position - only the innermost conditional needs the
            // bare end
            let emit_m_chain = |out: &mut Vec<u8>| {
                let mut has_cond = false;
                for (cond, act) in matched {
                    if let Some(c) = cond {
                        out.push(blr::IF);
                        emit_bool(out, c);
                        has_cond = true;
                    }
                    emit_m_act(out, act);
                }
                if !m_uncond && has_cond {
                    out.push(blr::END); // innermost bare else
                }
            };
            let emit_nm_chain = |out: &mut Vec<u8>| {
                let mut has_cond = false;
                for (cond, store_ctx, cols, vals) in notmatched {
                    if let Some(c) = cond {
                        out.push(blr::IF);
                        emit_bool(out, c);
                        has_cond = true;
                    }
                    out.push(blr::STORE);
                    emit_stream(out, tgt, *store_ctx);
                    out.push(blr::BEGIN);
                    for (c, v) in cols.iter().zip(vals) {
                        out.push(blr::ASSIGNMENT);
                        emit_val(out, v);
                        out.push(blr::FIELD);
                        out.push(*store_ctx);
                        out.push(c.len() as u8);
                        out.extend_from_slice(c.as_bytes());
                    }
                    out.push(blr::END);
                }
                if !nm_uncond && has_cond {
                    out.push(blr::END); // innermost bare else
                }
            };
            out.push(blr::IF);
            if notmatched.is_empty() {
                out.push(blr::NOT);
                miss(out);
                emit_m_chain(out);
                out.push(blr::END); // the outer if's bare else
            } else {
                miss(out);
                emit_nm_chain(out);
                if matched.is_empty() {
                    out.push(blr::END); // the outer if's bare else
                } else {
                    emit_m_chain(out);
                }
            }
        }
        TrigStmt::PosDelete(ctx) => {
            out.push(blr::ERASE);
            out.push(*ctx);
            out.push(blr::MARKS);
            out.push(1);
            out.push(1);
        }
        TrigStmt::PosUpdate(org, new, sets) => {
            out.push(blr::MODIFY);
            out.push(*org);
            out.push(*new);
            out.push(blr::MARKS);
            out.push(1);
            out.push(1);
            out.push(blr::BEGIN);
            for (target, v) in sets {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                emit_val(out, target);
            }
            out.push(blr::END);
        }
        TrigStmt::UpdateOrInsert {
            rel,
            store_ctx,
            new_ctx,
            org_ctx,
            cols,
            vals,
            matching,
        } => {
            out.push(blr::BEGIN);
            out.push(blr::FOR);
            out.push(blr::MARKS);
            out.push(1);
            out.push(4);
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, rel, *org_ctx);
            out.push(blr::BOOLEAN);
            // one blr_equiv per MATCHING column, left-nested under
            // blr_and (probed on two columns)
            for _ in 1..matching.len() {
                out.push(blr::AND);
            }
            for (mi, (mcol, midx)) in matching.iter().enumerate() {
                out.push(blr::EQUIV);
                out.push(blr::FIELD);
                out.push(*org_ctx);
                out.push(mcol.len() as u8);
                out.extend_from_slice(mcol.as_bytes());
                emit_val(out, &vals[*midx]);
                let _ = mi;
            }
            out.push(blr::END);
            out.push(blr::MODIFY);
            out.push(*org_ctx);
            out.push(*new_ctx);
            out.push(blr::BEGIN);
            for (c, v) in cols.iter().zip(vals) {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                out.push(blr::FIELD);
                out.push(*new_ctx);
                out.push(c.len() as u8);
                out.extend_from_slice(c.as_bytes());
            }
            out.push(blr::END);
            out.push(blr::IF);
            out.push(blr::EQL);
            out.push(blr::INTERNAL_INFO);
            emit_val(out, &Val::Int(5));
            emit_val(out, &Val::Int(0));
            out.push(blr::STORE);
            emit_stream(out, rel, *store_ctx);
            out.push(blr::BEGIN);
            for (c, v) in cols.iter().zip(vals) {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                out.push(blr::FIELD);
                out.push(*store_ctx);
                out.push(c.len() as u8);
                out.extend_from_slice(c.as_bytes());
            }
            out.push(blr::END);
            out.push(blr::END); // the if's missing else
            out.push(blr::END); // closes the wrapping begin
        }
        TrigStmt::ForSel(f) => {
            match f.label {
                Some(l) => {
                    out.push(blr::LABEL);
                    out.push(l);
                    out.push(blr::FOR);
                }
                None => {
                    out.push(blr::FOR);
                    out.push(blr::SINGULAR);
                }
            }
            out.push(blr::RSE);
            // a flat comma list counts every stream; a JOIN chain is one
            out.push(if f.aggregate { 1 } else { rse_stream_count(&f.joins) });
            if let Some(rc) = &f.recurse {
                // the recursion tower: a wrapper rse whose stream is
                // blr_recurse - context, the SECONDARY recursive
                // context byte, branch count - then the anchor branch
                // (a real rse + map, the cte name riding the
                // relation2 alias) and the STREAM-LESS recursive
                // branch (rse 0, its boolean over fids, map); no
                // terminator of its own - the wrapper's END closes
                // it, the shared END below closes the outer rse
                // (probed)
                out.push(blr::RSE);
                out.push(1);
                out.push(0xB9); // blr_recurse
                out.push(rc.ctx);
                out.push(rc.secondary);
                out.push(2);
                // anchor
                out.push(blr::RSE);
                out.push(1);
                if is_system_relation(&rc.anchor_table) {
                    emit_relation3(out, &rc.anchor_table);
                } else {
                    out.push(0x92); // blr_relation2
                    out.push(rc.anchor_table.len() as u8);
                    out.extend_from_slice(rc.anchor_table.as_bytes());
                }
                out.push(rc.anchor_alias.len() as u8);
                out.extend_from_slice(rc.anchor_alias.as_bytes());
                out.push(rc.anchor_ctx);
                if let Some(b) = &rc.anchor_wher {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
                out.push(blr::END);
                out.push(0x4D); // blr_map
                out.extend_from_slice(&(rc.anchor_items.len() as u16).to_le_bytes());
                for (i, (item, cast)) in rc.anchor_items.iter().enumerate() {
                    out.extend_from_slice(&(i as u16).to_le_bytes());
                    if *cast {
                        // this COLUMN's recursive item is integer
                        // arithmetic: it types int64 and the anchor
                        // field casts (per-column unification, probed)
                        out.push(0x83); // blr_cast
                        out.push(0x10); // blr_int64
                        out.push(0);
                    }
                    emit_val(out, item);
                }
                // the recursive branch: ZERO streams
                out.push(blr::RSE);
                out.push(0);
                if let Some(b) = &rc.rec_wher {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
                out.push(blr::END);
                out.push(0x4D);
                out.extend_from_slice(&(rc.rec_items.len() as u16).to_le_bytes());
                for (i, item) in rc.rec_items.iter().enumerate() {
                    out.extend_from_slice(&(i as u16).to_le_bytes());
                    emit_val(out, item);
                }
                out.push(blr::END); // the wrapper rse's end
            } else if f.aggregate && f.windows.is_empty() {
                out.push(blr::AGGREGATE);
                out.push(f.agg_ctx);
                out.push(blr::RSE);
                out.push(rse_stream_count(&f.joins));
                // the inner rse holds the JOIN chain when one exists,
                // its WHERE inside either way (probed)
                emit_join_chain(out, &f.stream, f.ctx, &f.joins);
                if let Some(b) = &f.boolean {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
                out.push(blr::END);
                out.push(blr::GROUP_BY);
                out.push(f.group_keys.len() as u8);
                for k in &f.group_keys {
                    emit_val(out, k);
                }
                out.push(blr::MAP);
                out.extend_from_slice(&(f.map.len() as u16).to_le_bytes());
                emit_map_entries(out, &f.map);
                if let Some(v) = &f.first {
                    out.push(blr::FIRST);
                    emit_val(out, v);
                }
                if let Some(v) = &f.skip {
                    out.push(blr::SKIP);
                    emit_val(out, v);
                }
                if let Some(h) = &f.having {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, h);
                }
            } else if let Some(u) = &f.union_ {
                // blr_union at the FIRST slot: count, per branch its
                // rse (WHERE inside) and map; a DISTINCT union
                // appends blr_project over the fids; the shared rse
                // END below closes it (probed)
                out.push(blr::UNION);
                out.push(u.ctx);
                out.push(u.branches.len() as u8);
                for (st, bctx, bwher, cols) in &u.branches {
                    out.push(blr::RSE);
                    out.push(1);
                    emit_stream(out, st, *bctx);
                    if let Some(b) = bwher {
                        out.push(blr::BOOLEAN);
                        emit_bool(out, b);
                    }
                    out.push(blr::END);
                    out.push(blr::MAP);
                    out.extend_from_slice(
                        &(cols.len() as u16).to_le_bytes(),
                    );
                    for (fi, c) in cols.iter().enumerate() {
                        out.extend_from_slice(
                            &(fi as u16).to_le_bytes(),
                        );
                        emit_val(out, c);
                    }
                }
                // a trailing ROWS / OFFSET / FETCH is the statement's: after
                // the union, before its sort (measured); the DISTINCT
                // union's project follows the sort, below
                if let Some(v) = &f.first {
                    out.push(blr::FIRST);
                    emit_val(out, v);
                }
                if let Some(v) = &f.skip {
                    out.push(blr::SKIP);
                    emit_val(out, v);
                }
            } else if !f.windows.is_empty() {
                // blr_window wraps the inner rse (its WHERE inside);
                // then the count and each window: blr_partition_by,
                // context, partition keys as source fields then
                // REMAPPED to the window's own map slots, the sort,
                // the map; the shared rse END below closes it all
                out.push(blr::WINDOW);
                out.push(blr::RSE);
                out.push(1);
                if f.aggregate {
                    // the aggregate node stands as the window's stream, its
                    // HAVING after its map (measured)
                    out.push(blr::AGGREGATE);
                    out.push(f.agg_ctx);
                    out.push(blr::RSE);
                    out.push(rse_stream_count(&f.joins));
                    emit_join_chain(out, &f.stream, f.ctx, &f.joins);
                    if let Some(b) = &f.boolean {
                        out.push(blr::BOOLEAN);
                        emit_bool(out, b);
                    }
                    out.push(blr::END);
                    out.push(blr::GROUP_BY);
                    out.push(f.group_keys.len() as u8);
                    for k in &f.group_keys {
                        emit_val(out, k);
                    }
                    out.push(blr::MAP);
                    out.extend_from_slice(&(f.map.len() as u16).to_le_bytes());
                    emit_map_entries(out, &f.map);
                    if let Some(h) = &f.having {
                        out.push(blr::BOOLEAN);
                        emit_bool(out, h);
                    }
                } else {
                    emit_stream(out, &f.stream, f.ctx);
                    if let Some(b) = &f.boolean {
                        out.push(blr::BOOLEAN);
                        emit_bool(out, b);
                    }
                }
                out.push(blr::END);
                emit_window_list(out, &f.windows);
                // FIRST / SKIP ride the outer rse after the window list,
                // before the sort (measured)
                if let Some(v) = &f.first {
                    out.push(blr::FIRST);
                    emit_val(out, v);
                }
                if let Some(v) = &f.skip {
                    out.push(blr::SKIP);
                    emit_val(out, v);
                }
            } else if let Some(cn) = &f.cursor {
                // AS CURSOR: the name rides the relation2 alias
                // exactly like a DECLAREd cursor's - relation3 with
                // the same alias string inside a subroutine (probed)
                if f.stream.sub || is_system_relation(&f.stream.name) {
                    emit_relation3(out, &f.stream.name);
                } else {
                    out.push(blr::RELATION2);
                    out.push(f.stream.name.len() as u8);
                    out.extend_from_slice(f.stream.name.as_bytes());
                }
                // with a table alias the cursor name pairs with IT -
                // the DECLARE CURSOR law (probed)
                let alias = match &f.stream.alias {
                    Some(a) => format!("\"{}\" \"{}\"", cn, a),
                    None => {
                        format!("\"{}\" \"{}\".\"{}\"", cn, relation_schema(&f.stream.name), f.stream.name)
                    }
                };
                out.push(alias.len() as u8);
                out.extend_from_slice(alias.as_bytes());
                out.push(f.ctx);
                if f.lock {
                    out.push(blr::WRITELOCK);
                }
                if let Some(b) = &f.boolean {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
            } else if !f.joins.is_empty() {
                // the view's left-nested chain at body numbering:
                // n join heads, the first stream, then per join its
                // stream, the type (absent for INNER), the ON - or the
                // flat comma list
                emit_join_chain(out, &f.stream, f.ctx, &f.joins);
                if let Some(b) = &f.boolean {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
            } else {
                emit_stream(out, &f.stream, f.ctx);
                if f.lock {
                    out.push(blr::WRITELOCK);
                }
                if let Some(v) = &f.first {
                    out.push(blr::FIRST);
                    emit_val(out, v);
                }
                if let Some(v) = &f.skip {
                    out.push(blr::SKIP);
                    emit_val(out, v);
                }
                if let Some(b) = &f.boolean {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, b);
                }
            }
            if !f.sort.is_empty() {
                out.push(blr::SORT);
                out.push(f.sort.len() as u8);
                for (desc, key) in &f.sort {
                    emit_sort_key(out, *desc, key);
                }
            }
            if let Some(u) = f.union_.as_ref().filter(|u| !u.all) {
                // a DISTINCT union: blr_project over its fids, after the
                // statement's sort (measured)
                out.push(blr::PROJECT);
                out.push(u.branches[0].3.len() as u8);
                for i in 0..u.branches[0].3.len() {
                    emit_val(out, &Val::Fid(u.ctx, i as u16));
                }
            }
            if f.distinct {
                // blr_project over the select columns, after the
                // boolean (probed at body numbering)
                out.push(blr::PROJECT);
                out.push(f.col_vals.len() as u8);
                for v in &f.col_vals {
                    emit_val(out, v);
                }
            }
            if let Some(pk) = &f.plan {
                out.push(blr::PLAN);
                out.push(blr::RETRIEVE);
                emit_stream(out, &f.stream, f.ctx);
                match pk {
                    PlanKind::Natural => out.push(blr::SEQUENTIAL),
                    PlanKind::Index(names) => {
                        out.push(blr::INDICES);
                        out.push(names.len() as u8);
                        for n in names {
                            out.push(n.len() as u8);
                            out.extend_from_slice(n.as_bytes());
                        }
                    }
                    PlanKind::Order(name) => {
                        out.push(0x8F); // blr_navigational
                        out.push(name.len() as u8);
                        out.extend_from_slice(name.as_bytes());
                    }
                }
            }
            out.push(blr::END);
            out.push(blr::BEGIN);
            // an INTO-less AS CURSOR loop has no assignments at all
            for (v, vi) in f.col_vals.iter().zip(&f.into) {
                out.push(blr::ASSIGNMENT);
                // an AS CURSOR loop wraps its into-assign sources in
                // blr_derived_expr, like a DECLAREd cursor's outputs
                if f.cursor.is_some() {
                    out.push(blr::DERIVED_EXPR);
                    out.push(1);
                    out.push(f.ctx);
                }
                emit_val(out, v);
                out.push(blr::VARIABLE);
                out.extend_from_slice(&vi.to_le_bytes());
            }
            if let Some(d) = &f.do_stmt {
                emit_trig_stmt(out, d);
            }
            out.push(blr::END);
        }
        TrigStmt::While(label, cond, body) => {
            out.push(blr::LABEL);
            out.push(*label);
            out.push(blr::LOOP);
            out.push(blr::BEGIN);
            out.push(blr::IF);
            emit_bool(out, cond);
            emit_trig_stmt(out, body);
            out.push(blr::LEAVE);
            out.push(*label);
            out.push(blr::END);
        }
        TrigStmt::Update(rel, org, new, sets, wher, ret) => {
            out.push(blr::FOR);
            out.push(blr::MARKS);
            out.push(1);
            out.push(4);
            if !ret.is_empty() {
                // RETURNING makes the loop SINGULAR (probed)
                out.push(blr::SINGULAR);
            }
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, rel, *org);
            if let Some(b) = wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, b);
            }
            out.push(blr::END);
            out.push(if ret.is_empty() {
                blr::MODIFY
            } else {
                blr::MODIFY2
            });
            out.push(*org);
            out.push(*new);
            out.push(blr::BEGIN);
            for (target, v) in sets {
                out.push(blr::ASSIGNMENT);
                emit_val(out, v);
                emit_val(out, target);
            }
            out.push(blr::END);
            if !ret.is_empty() {
                // UPDATE's returning reads the NEW record (probed)
                emit_returning(out, *new, ret);
            }
        }
    }
}

impl<'a> P<'a> {
    /// (FOR) SELECT as a body statement, self.i past SELECT. The
    /// whole probed select machinery: FIRST/SKIP, aggregates,
    /// GROUP BY/HAVING, ORDER BY, INTO variables, and for the FOR
    /// form a DO statement (its label numbers with the WHILEs).
    fn select_stmt(&mut self, is_for: bool) -> Option<TrigStmt> {
        let mut first: Option<Val> = None;
        let mut skip: Option<Val> = None;
        // (also set by the OFFSET/FETCH spelling after the sort)
        if self.kw("FIRST") {
            first = Some(self.limit_operand()?);
        }
        if self.kw("SKIP") {
            skip = Some(self.limit_operand()?);
        }
        if !is_for && (first.is_some() || skip.is_some()) {
            return None; // FIRST/SKIP in the singular form: unprobed
        }
        // SELECT DISTINCT - blr_project over the select columns
        // after the boolean (probed); beside everything structured
        // it refuses below
        let distinct = self.kw("DISTINCT");
        // two-phase select list: fields need the stream's context
        let list_start = self.i;
        let mut depth = 0i32;
        let list_end = loop {
            match self.t.get(self.i)? {
                Tok::LParen => {
                    depth += 1;
                    self.i += 1;
                }
                Tok::RParen => {
                    depth -= 1;
                    self.i += 1;
                }
                Tok::Ident(w) if w == "FROM" && depth == 0 => break self.i,
                _ => self.i += 1,
            }
        };
        self.i = list_end + 1;
        // a UNION ahead (depth-0, before INTO/DO) claims the
        // statement's FIRST slot - look ahead and reserve it so the
        // branch streams number after it (probed)
        let mut has_union = false;
        {
            let mut j = self.i;
            let mut depth = 0i32;
            while let Some(t) = self.t.get(j) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => depth -= 1,
                    Tok::Ident(w)
                        if depth == 0
                            && (w == "INTO" || w == "DO" || w == "AS") =>
                    {
                        break
                    }
                    Tok::Ident(w) if depth == 0 && w == "UNION" => {
                        has_union = true;
                        break;
                    }
                    Tok::Semi => break,
                    _ => {}
                }
                j += 1;
            }
        }
        let union_ctx = if has_union {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            Some((self.streams.len() - 1) as u8 + self.base)
        } else {
            None
        };
        let stream = self.stream_item()?;
        self.streams.push(stream.clone());
        let sidx = self.streams.len() - 1;
        let ctx = sidx as u8 + self.base;
        self.claim_derived_agg_slot(&stream);
        // JOIN chain - the view laws at body numbering (probed):
        // each ON resolves across the accumulated statement streams
        let mut joins: Vec<(u8, Stream, u8, Bool)> = Vec::new();
        loop {
            let jt = if self.kw("INNER") {
                if !self.kw("JOIN") {
                    return None;
                }
                0u8
            } else if self.kw("JOIN") {
                0
            } else if self.kw("LEFT") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                1
            } else if self.kw("RIGHT") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                2
            } else if self.kw("FULL") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                3
            } else {
                break;
            };
            let st2 = self.stream_item()?;
            self.streams.push(st2.clone());
            let ctx2 = (self.streams.len() - 1) as u8 + self.base;
            self.claim_derived_agg_slot(&st2);
            if !self.kw("ON") {
                return None;
            }
            let saved_scope = self.merge_scope;
            self.merge_scope = Some((sidx, self.streams.len()));
            let on = self.bool_or()?;
            self.merge_scope = saved_scope;
            joins.push((jt, st2, ctx2, on));
        }
        // a COMMA-SEPARATED stream list (`FROM sales s, customer c`, the
        // employee sample's SHIP_ORDER): the engine compiles it to ONE
        // flat rse with all the streams and the WHERE as its boolean
        // (measured), which [JOIN_COMMA] marks for the emitter; mixing it
        // with an explicit JOIN chain is unprobed and refuses
        while matches!(self.t.get(self.i), Some(Tok::Comma)) {
            if joins.iter().any(|j| j.0 != JOIN_COMMA) {
                return None;
            }
            self.i += 1;
            let st2 = self.stream_item()?;
            self.streams.push(st2.clone());
            let ctx2 = (self.streams.len() - 1) as u8 + self.base;
            self.claim_derived_agg_slot(&st2);
            joins.push((JOIN_COMMA, st2, ctx2, Bool::Missing(Val::Null)));
        }
        let after_from = self.i;
        self.i = list_start;
        enum Item {
            Col(Val),
            /// a full value expression at the stream context (probed)
            Expr(Val),
            Agg(u8, Option<Val>),
            /// <fn> OVER ([PARTITION BY] [ORDER BY] [frame])
            Win(
                MapEntry,
                Vec<Val>,
                Vec<(bool, Val)>,
                Option<(u8, (u8, Option<Val>), (u8, Option<Val>))>,
            ),
        }
        let saved_sub = self.sub.replace(sidx);
        // with a join chain, qualified-only resolution across the
        // statement's streams replaces the single-stream scope
        let saved_scope = self.merge_scope;
        if !joins.is_empty() {
            // every FROM stream - a derived aggregate's placeholder slot included
            self.merge_scope = Some((sidx, self.streams.len()));
        }
        // A GROUP BY ahead (depth 0, before INTO / DO / UNION): a WINDOW in
        // this list then sits OVER THE AGGREGATE (measured: blr_window's rse
        // holds the aggregate node, whose map carries, in order of
        // APPEARANCE, the group fields and inner aggregates the list and the
        // windows reference; each window reads them by fid). The aggregate's
        // context is claimed now so those references resolve while parsing.
        let grouped_ahead = {
            let mut j = after_from;
            let mut depth = 0i32;
            let mut found = false;
            while let Some(t) = self.t.get(j) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => depth -= 1,
                    Tok::Ident(w) if depth == 0 && (w == "INTO" || w == "DO" || w == "UNION") => break,
                    Tok::Ident(w) if depth == 0 && w == "GROUP" => {
                        found = true;
                        break;
                    }
                    Tok::Semi => break,
                    _ => {}
                }
                j += 1;
            }
            found
        };
        if grouped_ahead {
            self.agg_fid_ctx = self.streams.len() as u8 + self.base;
            self.agg_map = Vec::new();
        }
        let mut items: Vec<Item> = Vec::new();
        let mut aliases: Vec<String> = Vec::new();
        self.win_found.clear();
        // each item's NAME as an ORDER BY key sees it: its alias, else the
        // column a bare (or qualified) column reference names, else none
        let mut item_names: Vec<Option<String>> = Vec::new();
        loop {
            // under a GROUP BY the plain fields an item or a window's keys name
            // take their map slots in order of appearance
            let mut keys_seen: Vec<Val> = Vec::new();
            let item_start = self.i;
            let mut star_names: Option<Vec<String>> = None;
            // a window call that is NOT the whole item (an operand of an
            // expression, a function's argument) parses as a value below
            let win_whole = self.window_call_end(self.i).map_or(true, |e| {
                e == list_end
                    || matches!(self.t.get(e), Some(Tok::Comma))
                    || matches!(self.t.get(e), Some(Tok::Ident(a)) if a == "AS" || !is_keyword(a))
            });
            match self.t.get(self.i)? {
                Tok::Ident(w)
                    if matches!(
                        w.as_str(),
                        "COUNT" | "SUM" | "AVG" | "MIN" | "MAX"
                    ) && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) && win_whole =>
                {
                    let w = w.clone();
                    self.i += 1;
                    let saved_mode = self.agg_mode;
                    self.agg_mode = grouped_ahead;
                    let parsed = self.parse_agg(&w);
                    self.agg_mode = saved_mode;
                    let (verb, arg) = parsed?;
                    if self.kw("OVER") {
                        self.agg_mode = grouped_ahead;
                        let over = self.over_clause(ctx);
                        self.agg_mode = saved_mode;
                        let (part, ord, frame) = over?;
                        for k in part.iter().chain(ord.iter().map(|(_, k)| k)) {
                            collect_fields_deep(k, &mut keys_seen);
                        }
                        items.push(Item::Win(
                            MapEntry::Agg(verb, arg),
                            part,
                            ord,
                            frame,
                        ));
                    } else {
                        items.push(Item::Agg(verb, arg));
                    }
                }
                // the named window functions: ROW_NUMBER/RANK/
                // DENSE_RANK take no arguments; FIRST_VALUE/
                // LAST_VALUE one; LAG/LEAD canonicalize to THREE -
                // value, offset (default 1), default (NULL) (probed)
                Tok::Ident(w)
                    if matches!(
                        w.as_str(),
                        "ROW_NUMBER"
                            | "RANK"
                            | "DENSE_RANK"
                            | "FIRST_VALUE"
                            | "LAST_VALUE"
                            | "NTH_VALUE"
                            | "LAG"
                            | "LEAD"
                    ) && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) && win_whole =>
                {
                    let w = w.clone();
                    self.i += 2;
                    let mut args = Vec::new();
                    let saved_mode = self.agg_mode;
                    self.agg_mode = grouped_ahead;
                    if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                        loop {
                            let a = self.val();
                            let Some(a) = a else {
                                self.agg_mode = saved_mode;
                                return None;
                            };
                            args.push(a);
                            match self.t.get(self.i)? {
                                Tok::Comma => self.i += 1,
                                Tok::RParen => break,
                                _ => {
                                    self.agg_mode = saved_mode;
                                    return None;
                                }
                            }
                        }
                    }
                    self.agg_mode = saved_mode;
                    if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                        return None;
                    }
                    self.i += 1;
                    match w.as_str() {
                        "ROW_NUMBER" | "RANK" | "DENSE_RANK" => {
                            if !args.is_empty() {
                                return None;
                            }
                        }
                        "FIRST_VALUE" | "LAST_VALUE" => {
                            if args.len() != 1 {
                                return None;
                            }
                        }
                        "NTH_VALUE" => {
                            // canonicalizes with a FROM FIRST
                            // indicator - literal 0 (probed)
                            if args.len() != 2 {
                                return None;
                            }
                            args.push(Val::Int(0));
                        }
                        _ => {
                            // LAG/LEAD fill the canonical three
                            if args.is_empty() || args.len() > 3 {
                                return None;
                            }
                            if args.len() < 2 {
                                args.push(Val::Int(1));
                            }
                            if args.len() < 3 {
                                args.push(Val::Null);
                            }
                        }
                    }
                    if !self.kw("OVER") {
                        return None;
                    }
                    let saved_mode = self.agg_mode;
                    self.agg_mode = grouped_ahead;
                    let over = self.over_clause(ctx);
                    self.agg_mode = saved_mode;
                    let (part, ord, frame) = over?;
                    for k in part.iter().chain(ord.iter().map(|(_, k)| k)) {
                        collect_fields_deep(k, &mut keys_seen);
                    }
                    items.push(Item::Win(
                        MapEntry::Fn(w, args),
                        part,
                        ord,
                        frame,
                    ));
                }
                // `*` - alone in the list - or `<stream>.*`: the stream's
                // columns in field-position order, exactly as if written out
                // (measured: the engine's BLR for the star and for the
                // hand-written list are byte-identical over a relation, a
                // view, a selectable procedure, a derived table, a join and a
                // comma list; `*, 1` is refused by the engine, `T.*, 1` is not)
                Tok::Star => {
                    if self.i != list_start || self.i + 1 != list_end {
                        return None;
                    }
                    self.i += 1;
                    let mut names = Vec::new();
                    for idx in sidx..self.streams.len() {
                        if self.streams[idx].name.is_empty() && self.streams[idx].derived.is_none() {
                            continue; // a derived aggregate's placeholder slot
                        }
                        names.extend(self.star_names(idx)?);
                        for v in self.star_fields(idx)? {
                            collect_fields_deep(&v, &mut keys_seen);
                            items.push(match v {
                                Val::Field(..) => Item::Col(v),
                                other => Item::Expr(other),
                            });
                        }
                    }
                    star_names = Some(names);
                }
                Tok::Ident(q)
                    if matches!(self.t.get(self.i + 1), Some(Tok::Dot))
                        && matches!(self.t.get(self.i + 2), Some(Tok::Star)) =>
                {
                    let q = q.clone();
                    self.i += 3;
                    let hits: Vec<usize> = (sidx..self.streams.len())
                        .filter(|&k| {
                            let st = &self.streams[k];
                            st.alias.as_deref().map_or(st.derived.is_none() && st.name == q, |a| a == q)
                        })
                        .collect();
                    if hits.len() != 1 {
                        return None; // no such stream, or two of them: unprobed
                    }
                    star_names = Some(self.star_names(hits[0])?);
                    for v in self.star_fields(hits[0])? {
                        collect_fields_deep(&v, &mut keys_seen);
                        items.push(match v {
                            Val::Field(..) => Item::Col(v),
                            other => Item::Expr(other),
                        });
                    }
                }
                _ => {
                    // a full value expression at the stream context
                    // (bare names resolve as COLUMNS here - the
                    // stream scope is set); a plain column keeps its
                    // Col shape for the aggregate/cursor paths; a window call
                    // inside is captured (not under GROUP BY: unprobed)
                    if !grouped_ahead {
                        self.win_cap = Some((self.streams.len(), ctx));
                    }
                    let v = self.val();
                    self.win_cap = None;
                    let v = v?;
                    collect_fields_deep(&v, &mut keys_seen);
                    items.push(match v {
                        Val::Field(..) => Item::Col(v),
                        other => Item::Expr(other),
                    });
                }
            }
            if grouped_ahead {
                for k in keys_seen {
                    let e = MapEntry::Key(k);
                    if !self.agg_map.contains(&e) {
                        self.agg_map.push(e);
                    }
                }
            }
            // an item's ALIAS - `AS name` or a bare name - names the
            // column for the client and never reaches the BLR (measured:
            // a FOR SELECT with and without them compiles alike); an ORDER
            // BY key that IS one sorts on the item (resolved below)
            let expr_end = self.i;
            let mut alias: Option<String> = None;
            if self.kw("AS") {
                let Some(Tok::Ident(a)) = self.t.get(self.i) else { return None };
                alias = Some(a.clone());
                self.i += 1;
            } else if let Some(Tok::Ident(a)) = self.t.get(self.i) {
                if self.i != list_end && !is_keyword(a) {
                    alias = Some(a.clone());
                    self.i += 1;
                }
            }
            if let Some(names) = star_names {
                if names.len() != items.len() - item_names.len() {
                    return None;
                }
                item_names.extend(names.into_iter().map(Some));
            } else {
                let bare = match &self.t[item_start..expr_end] {
                    [Tok::Ident(n)] => Some(n.clone()),
                    [Tok::Ident(_), Tok::Dot, Tok::Ident(n)] => Some(n.clone()),
                    _ => None,
                };
                let bare = bare.filter(|_| matches!(items.last(), Some(Item::Col(_))));
                item_names.push(alias.clone().or(bare));
            }
            if let Some(a) = alias {
                aliases.push(a);
            }
            if self.i == list_end {
                break;
            }
            if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                return None;
            }
            self.i += 1;
        }
        self.i = after_from;
        // a GROUP BY / HAVING naming an alias resolves by the engine's own
        // rules (an alias beside a column of the same name): refused; so is
        // an alias INSIDE an ORDER BY expression (the engine does not see it
        // there - `ORDER BY X + 1` is column unknown). A WHOLE ORDER BY key
        // naming one is resolved against the item names in the sort loop
        if !aliases.is_empty() {
            let mut j = after_from;
            let mut depth = 0i32;
            let mut clause = 0u8; // 1 ORDER BY, 2 GROUP BY / HAVING
            while let Some(t) = self.t.get(j) {
                match t {
                    Tok::LParen => depth += 1,
                    Tok::RParen => depth -= 1,
                    Tok::Semi => break,
                    Tok::Ident(w) if depth == 0 && (w == "INTO" || w == "DO") => break,
                    Tok::Ident(w) if depth == 0 && w == "ORDER" => clause = 1,
                    Tok::Ident(w) if depth == 0 && (w == "GROUP" || w == "HAVING") => clause = 2,
                    Tok::Ident(w)
                        if clause != 0
                            && aliases.iter().any(|a| a == w)
                            && !matches!(self.t.get(j.wrapping_sub(1)), Some(Tok::Dot))
                            && !(clause == 1 && depth == 0 && whole_sort_key(&self.t, j)) =>
                    {
                        return None
                    }
                    _ => {}
                }
                j += 1;
            }
        }
        let cols_n = items.len();
        if cols_n == 0 {
            return None;
        }
        let has_aggs = items.iter().any(|it| matches!(it, Item::Agg(..)));
        let mut boolean = if self.kw("WHERE") {
            Some(self.bool_or()?)
        } else {
            None
        };
        // PLAN (tbl NATURAL) - the single-table sequential plan:
        // blr_plan/blr_retrieve/the stream again/blr_sequential,
        // LAST in the rse after the sort (probed); other plan forms
        // refuse
        let mut plan: Option<PlanKind> = None;
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "PLAN") {
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            let named_ok = matches!(
                self.t.get(self.i),
                Some(Tok::Ident(w)) if *w == stream.name
                    || stream.alias.as_deref() == Some(w)
            );
            if !named_ok {
                return None;
            }
            self.i += 1;
            if self.kw("NATURAL") {
                plan = Some(PlanKind::Natural);
            } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ORDER")
            {
                self.i += 1;
                let Some(Tok::Ident(n)) = self.t.get(self.i) else {
                    return None;
                };
                plan = Some(PlanKind::Order(n.clone()));
                self.i += 1;
            } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "INDEX")
            {
                self.i += 1;
                if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                    return None;
                }
                self.i += 1;
                let mut names = Vec::new();
                loop {
                    let Some(Tok::Ident(n)) = self.t.get(self.i) else {
                        return None;
                    };
                    names.push(n.clone());
                    self.i += 1;
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
                plan = Some(PlanKind::Index(names));
            } else {
                return None;
            }
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            if !joins.is_empty() || stream.derived.is_some() {
                return None;
            }
        }
        // UNION [ALL] branches: each a plain single-stream select -
        // items resolved at ITS stream, WHERE inside its rse; the
        // whole union refuses beside every other structure
        let mut union_ = None;
        if let Some(uctx) = union_ctx {
            if !self.kw("UNION") {
                return None; // the lookahead promised one
            }
            let all = self.kw("ALL");
            let first_cols: Vec<Val> = items
                .iter()
                .map(|it| match it {
                    Item::Col(v) => Some(v.clone()),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?;
            if has_aggs || !joins.is_empty() || stream.derived.is_some() {
                return None;
            }
            let mut branches = vec![(
                stream.clone(),
                ctx,
                boolean.take(),
                first_cols.clone(),
            )];
            loop {
                if !self.kw("SELECT") {
                    return None;
                }
                // the branch select list, positionally: plain columns, or
                // a `*` / `<stream>.*` standing for the branch stream's
                // columns (resolved once the stream is parsed)
                enum BrItem {
                    Col(Option<String>, String),
                    Star(Option<String>),
                }
                let mut raw: Vec<BrItem> = Vec::new();
                loop {
                    match (self.t.get(self.i), self.t.get(self.i + 1), self.t.get(self.i + 2)) {
                        (Some(Tok::Star), _, _) => {
                            if !raw.is_empty() {
                                return None; // `*` stands alone
                            }
                            self.i += 1;
                            raw.push(BrItem::Star(None));
                        }
                        (Some(Tok::Ident(q)), Some(Tok::Dot), Some(Tok::Star)) => {
                            raw.push(BrItem::Star(Some(q.clone())));
                            self.i += 3;
                        }
                        _ => {
                            let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                                return None;
                            };
                            if is_keyword(a) {
                                return None;
                            }
                            let a = a.clone();
                            self.i += 1;
                            if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                                self.i += 1;
                                let Some(Tok::Ident(b)) = self.t.get(self.i)
                                else {
                                    return None;
                                };
                                raw.push(BrItem::Col(Some(a), b.clone()));
                                self.i += 1;
                            } else {
                                raw.push(BrItem::Col(None, a));
                            }
                        }
                    }
                    match self.t.get(self.i)? {
                        Tok::Comma if !matches!(raw.first(), Some(BrItem::Star(None))) => self.i += 1,
                        Tok::Ident(w) if w == "FROM" => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
                let bst = self.stream_item()?;
                if bst.derived.is_some() {
                    return None;
                }
                self.streams.push(bst.clone());
                let bidx = self.streams.len() - 1;
                let bctx = bidx as u8 + self.base;
                let saved_b = self.sub.replace(bidx);
                let mut cols = Vec::with_capacity(raw.len());
                for it in &raw {
                    match it {
                        BrItem::Col(q, n) => cols.push(self.field(q.as_deref(), n)?),
                        BrItem::Star(q) => {
                            if let Some(q) = q {
                                let answers = bst.alias.as_deref().map_or(bst.name == *q, |a| a == q);
                                if !answers {
                                    return None;
                                }
                            }
                            cols.extend(self.star_fields(bidx)?);
                        }
                    }
                }
                if cols.len() != first_cols.len() {
                    return None;
                }
                let bwher = if self.kw("WHERE") {
                    Some(self.bool_or()?)
                } else {
                    None
                };
                self.sub = saved_b;
                branches.push((bst, bctx, bwher, cols));
                if !self.kw("UNION") {
                    break;
                }
                if all != self.kw("ALL") {
                    return None; // mixed ALL/distinct: unprobed
                }
            }
            // the branches' types UNIFY per column and every branch value of
            // another type is CAST to the common one (measured: `S UNION ALL
            // U` - a NONE VARCHAR(20) beside a UTF8 VARCHAR(10) - casts BOTH
            // to VARCHAR(20) UTF8; `ID UNION ALL S` casts the INTEGER to S's
            // type and leaves S raw). A branch of unknown type keeps the
            // plain map; known types that do not unify here refuse
            for i in 0..first_cols.len() {
                let owns: Option<Vec<Dsc>> = branches
                    .iter()
                    .map(|b| match &b.3[i] {
                        Val::Field(c, n) => self.field_dsc(*c, n),
                        _ => None,
                    })
                    .collect();
                let Some(owns) = owns else { continue };
                let bytes = |d: Dsc| {
                    let mut o = Vec::new();
                    emit_dsc(&mut o, d);
                    o
                };
                if owns.iter().all(|d| bytes(*d) == bytes(owns[0])) {
                    continue;
                }
                let vals: Vec<Val> = branches.iter().map(|b| b.3[i].clone()).collect();
                let common = self.unify_branches(&vals.iter().collect::<Vec<_>>())?;
                for (k, own) in owns.iter().enumerate() {
                    if bytes(*own) != bytes(common) {
                        let v = branches[k].3[i].clone();
                        branches[k].3[i] = Val::Cast(common, Box::new(v));
                    }
                }
            }
            union_ = Some(BodyUnion {
                ctx: uctx,
                all,
                branches,
            });
        }
        let mut group_keys: Vec<Val> = Vec::new();
        let grouped = self.kw("GROUP");
        if grouped {
            if !self.kw("BY") {
                return None;
            }
            // keys are full EXPRESSIONS (probed): the group list
            // holds them raw; the map carries their BARE fields
            loop {
                group_keys.push(self.val()?);
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        // a HAVING with neither aggregate item nor GROUP BY is still an
        // aggregate (measured: `SELECT 1 FROM T HAVING COUNT(*) > 1` maps
        // the count alone)
        let aggregate = has_aggs
            || grouped
            || matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "HAVING");
        let mut agg_vals: Option<Vec<Val>> = None;
        if union_.is_some()
            && (grouped || first.is_some() || skip.is_some())
        {
            return None;
        }
        let win_found = std::mem::take(&mut self.win_found);
        let has_wins = !win_found.is_empty() || items.iter().any(|it| matches!(it, Item::Win(..)));
        if union_.is_some() && has_wins {
            return None;
        }
        // a DERIVED stream beside a window: unprobed; a GROUP BY over an
        // EXPRESSION item of one: unprobed (the aggregate, FIRST / SKIP and
        // join shapes are measured - the nested rse stands as the stream)
        if stream.derived.is_some() && has_wins {
            return None;
        }
        if grouped
            && stream.derived.as_ref().is_some_and(|d| {
                d.cols.iter().any(|(_, c)| matches!(c, DCol::Expr(_) | DCol::Fid(Val::DerivedWrapN(..))))
            })
        {
            return None;
        }
        // windows beside aggregates, joins, FIRST/SKIP or in the
        // singular form: unprobed
        if has_wins && (!joins.is_empty() || !is_for) {
            return None;
        }
        // windows over an aggregate: only the GROUP BY form is measured
        if has_wins && aggregate && !grouped {
            return None;
        }
        // joins beside FIRST/SKIP: unprobed
        if !joins.is_empty() && (first.is_some() || skip.is_some()) {
            return None;
        }
        if aggregate && has_wins {
            // WINDOWS OVER THE AGGREGATE (measured): the aggregate takes the
            // next context and the windows the ones after it; every item and
            // every window key or argument is LIFTED to the aggregate's map
            // - a group field to its key slot, an aggregate to its verb's
            // slot, an expression rebuilt over them - and the window layer
            // below then runs over those fids exactly as over plain columns
            // (a plain item rides an empty window as a key entry there too)
            if stream.derived.is_some() {
                return None;
            }
            let fid_ctx = self.agg_fid_ctx;
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            let mut gfields: Vec<Val> = Vec::new();
            for k in &group_keys {
                collect_fields(k, &mut gfields);
            }
            let mut lifted: Vec<Item> = Vec::with_capacity(items.len());
            for it in items.drain(..) {
                let lift = |p: &mut Self, v: &Val| -> Option<Val> { p.lift_to_agg(v, &gfields, fid_ctx) };
                lifted.push(match it {
                    Item::Col(v) | Item::Expr(v) => {
                        let r = lift(self, &v)?;
                        if matches!(r, Val::Fid(..)) { Item::Col(r) } else { Item::Expr(r) }
                    }
                    Item::Agg(verb, arg) => {
                        let slot = self.agg_slot(verb, arg);
                        Item::Col(Val::Fid(fid_ctx, slot))
                    }
                    Item::Win(e, part, ord, frame) => {
                        let e = match e {
                            MapEntry::Agg(verb, Some(arg)) => MapEntry::Agg(verb, Some(lift(self, &arg)?)),
                            MapEntry::Fn(n, args) => {
                                let mut out = Vec::with_capacity(args.len());
                                for a in &args {
                                    out.push(lift(self, a)?);
                                }
                                MapEntry::Fn(n, out)
                            }
                            other => other,
                        };
                        let mut p2 = Vec::with_capacity(part.len());
                        for k in &part {
                            p2.push(lift(self, k)?);
                        }
                        let mut o2 = Vec::with_capacity(ord.len());
                        for (d, k) in &ord {
                            o2.push((*d, lift(self, k)?));
                        }
                        Item::Win(e, p2, o2, frame)
                    }
                });
            }
            items = lifted;
        }
        if aggregate && !has_wins {
            // grouped without an aggregate item (`SELECT 1 FROM T GROUP BY
            // ID`): an EMPTY map, measured; FIRST / SKIP ride the outer
            // rse after the map (measured: `FIRST 1 COUNT(*)` is `.. map
            // blr_first 1 end`)
            // the aggregate node takes the NEXT context - after the
            // stream AND any join streams (probed: a joined COUNT
            // put the aggregate at 2 over streams 0 and 1); claim
            // its slot so later statements keep counting correctly
            self.agg_fid_ctx = self.streams.len() as u8 + self.base;
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            // the map takes each select item's contribution in
            // SELECT-LIST order: a column or expression contributes
            // the BARE FIELDS it references (which must appear in
            // some group key), deduped; an aggregate its verb; the
            // items themselves REBUILD over the map's fids (probed
            // on expression keys)
            let mut gfields: Vec<Val> = Vec::new();
            for k in &group_keys {
                collect_fields(k, &mut gfields);
            }
            let fid_ctx = self.agg_fid_ctx;
            let mut map: Vec<MapEntry> = Vec::new();
            let mut vals: Vec<Val> = Vec::new();
            for it in &items {
                match it {
                    Item::Col(v) | Item::Expr(v) => {
                        vals.push(rebuild_over_keys(
                            &mut map, v, &gfields, fid_ctx,
                        )?);
                    }
                    Item::Agg(verb, arg) => {
                        let entry = MapEntry::Agg(*verb, arg.clone());
                        let slot = match map
                            .iter()
                            .position(|e| *e == entry)
                        {
                            Some(i) => i,
                            None => {
                                map.push(entry);
                                map.len() - 1
                            }
                        };
                        vals.push(Val::Fid(fid_ctx, slot as u16));
                    }
                    Item::Win(..) => return None, // guarded above
                }
            }
            self.agg_map = map;
            agg_vals = Some(vals);
        }
        let having = if self.kw("HAVING") {
            if !aggregate {
                return None;
            }
            self.agg_mode = true;
            let b = self.bool_or()?;
            self.agg_mode = false;
            Some(map_bool_to_fids(&self.agg_map, b, self.agg_fid_ctx)?)
        } else {
            None
        };
        let mut sort: Vec<(bool, Val)> = Vec::new();
        // the statement ORDER BY over windows: (descending, nulls byte,
        // the item's position or the key to compile over the windows)
        let mut win_sort: Vec<(bool, Option<u8>, Result<Val, usize>)> = Vec::new();
        if self.kw("ORDER") {
            if !self.kw("BY") {
                return None;
            }
            loop {
                // a WHOLE key that is a bare name looks at the select list
                // first: an item's alias, or the column a bare column item
                // names - one hit sorts on that item exactly as its position
                // would, two are the engine's 42702 (alias/alias, alias/field
                // and field/field alike), none falls through to the columns
                // (all measured on 2196)
                let named = match self.t.get(self.i) {
                    Some(Tok::Ident(w)) if whole_sort_key(&self.t, self.i) => {
                        let hits: Vec<usize> = item_names
                            .iter()
                            .enumerate()
                            .filter(|(_, n)| n.as_deref() == Some(w.as_str()))
                            .map(|(k, _)| k)
                            .collect();
                        if hits.len() > 1 {
                            return None;
                        }
                        hits.first().copied()
                    }
                    _ => None,
                };
                // under an aggregate a key may be an aggregate itself,
                // selected or not: it takes (or adds) its map slot (measured:
                // `SELECT COUNT(*) .. ORDER BY SUM(N)` sorts on fid 1)
                let key = if let Some(k) = named {
                    self.i += 1;
                    Val::Int(i32::try_from(k + 1).ok()?)
                } else if aggregate {
                    self.agg_mode = true;
                    let k = self.val();
                    self.agg_mode = false;
                    k?
                } else {
                    self.val()?
                };
                // over an aggregate the key REBUILDS against the
                // map; elsewhere the raw expression IS the sort key
                // (both probed) - and a bare integer is a POSITION in
                // the select list, compiled to the BLR of the item it
                // names: `ORDER BY 2 DESC, 1` is byte-for-byte `ORDER BY
                // N DESC, ID`, `ORDER BY 2` over `G, COUNT(*)` is `ORDER
                // BY COUNT(*)`, `ORDER BY 1` over `ID * 2` is `ORDER BY
                // ID * 2` (RDB$PROCEDURE_BLR on 2196). A scaled literal
                // is no position, and a window item has no such key:
                // both refuse.
                let position = match key {
                    Val::Int(n) => Some(n as i64),
                    Val::Int64(n) => Some(n),
                    _ => None,
                };
                if matches!(key, Val::Dec(..)) {
                    return None;
                }
                // over a UNION only a POSITION sorts - the union stream's
                // fid of that column (measured: `.. UNION ALL .. ORDER BY 1`
                // is `blr_sort 1 asc fid(union, 0)` after the union); a name,
                // even the first branch's alias, is the engine's -104
                // "invalid ORDER BY clause"
                if let Some(u) = &union_ {
                    if named.is_some() {
                        return None;
                    }
                    let i = usize::try_from(position?).ok()?.checked_sub(1)?;
                    if i >= items.len() {
                        return None;
                    }
                    let descending = if self.kw("DESC") {
                        true
                    } else {
                        let _ = self.kw("ASC");
                        false
                    };
                    let key = self.nulls_placement(Val::Fid(u.ctx, i as u16))?;
                    sort.push((descending, key));
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        continue;
                    }
                    break;
                }
                if has_wins {
                    // OVER WINDOWS a key is compiled once the windows are
                    // built: a position (or a name) sorts on the item's own
                    // value, anything else reads the window streams like an
                    // item would - lifted through the aggregate first when
                    // there is one (all measured)
                    let src = if let Some(n) = position {
                        let i = usize::try_from(n).ok()?.checked_sub(1)?;
                        if i >= items.len() {
                            return None;
                        }
                        Err(i)
                    } else if aggregate {
                        let mut gf = Vec::new();
                        for k in &group_keys {
                            collect_fields(k, &mut gf);
                        }
                        Ok(self.lift_to_agg(&key, &gf, self.agg_fid_ctx)?)
                    } else {
                        Ok(key)
                    };
                    let descending = if self.kw("DESC") {
                        true
                    } else {
                        let _ = self.kw("ASC");
                        false
                    };
                    let nulls = match self.nulls_placement(Val::Null)? {
                        Val::NullsPlaced(b, _) => Some(b),
                        _ => None,
                    };
                    win_sort.push((descending, nulls, src));
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        continue;
                    }
                    break;
                }
                let key = if let Some(n) = position {
                    let i = usize::try_from(n).ok()?.checked_sub(1)?;
                    if aggregate {
                        agg_vals.as_ref()?.get(i)?.clone()
                    } else {
                        match items.get(i)? {
                            Item::Col(v) | Item::Expr(v) => v.clone(),
                            _ => return None,
                        }
                    }
                } else if aggregate {
                    // an UNSELECTED group field as a sort key takes a new
                    // map slot after the items (measured: `SELECT COUNT(*) ..
                    // GROUP BY DEPT_ID ORDER BY DEPT_ID` maps the count, then
                    // the key, and sorts on fid 1)
                    if let Val::Field(..) = &key {
                        let mut gf = Vec::new();
                        for k in &group_keys {
                            collect_fields(k, &mut gf);
                        }
                        let entry = MapEntry::Key(key.clone());
                        if gf.contains(&key) && !self.agg_map.contains(&entry) {
                            self.agg_map.push(entry);
                        }
                    }
                    map_val_to_fid(&self.agg_map, &key, self.agg_fid_ctx)?
                } else {
                    key
                };
                let descending = if self.kw("DESC") {
                    true
                } else {
                    let _ = self.kw("ASC");
                    false
                };
                let key = self.nulls_placement(key)?;
                sort.push((descending, key));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        self.sub = saved_sub;
        self.merge_scope = saved_scope;
        // build the WINDOWS: one per distinct (partition, order)
        // spec in ENCOUNTER order, passthrough columns in the
        // DEFAULT (empty-spec) window; each window's map holds its
        // items in select order with the partition keys appended;
        // contexts claim the slots after the stream (all probed)
        let mut windows: Vec<Win> = Vec::new();
        let mut rebuilt_exprs: Vec<(usize, usize, Val)> = Vec::new();
        let mut sort_rebuilt: Vec<(usize, usize, Val)> = Vec::new();
        let mut win_exprs: Vec<(usize, Val)> = Vec::new();
        let win_slots: Vec<(usize, u16)> = if has_wins {
            let mut slots = Vec::new();
            for it in &items {
                // a passthrough EXPRESSION contributes its bare
                // fields to the default window's map and rebuilds
                // over the fids - the group-expression law in window
                // clothing (probed: UID + 1 beside COUNT(*) OVER ())
                enum WSlot {
                    Direct(MapEntry),
                    Rebuild(Val),
                }
                let (part, ord, frame, entry) = match it {
                    Item::Col(v) => (
                        Vec::new(),
                        Vec::new(),
                        None,
                        WSlot::Direct(MapEntry::Key(v.clone())),
                    ),
                    Item::Expr(v) if contains_winref(v) => {
                        let r = rebuild_win_expr(&mut windows, v, &win_found)?;
                        slots.push((0, u16::MAX));
                        win_exprs.push((slots.len() - 1, r));
                        continue;
                    }
                    Item::Expr(v) => (
                        Vec::new(),
                        Vec::new(),
                        None,
                        WSlot::Rebuild(v.clone()),
                    ),
                    Item::Win(e, p, o, fr) => (
                        p.clone(),
                        o.clone(),
                        fr.clone(),
                        WSlot::Direct(e.clone()),
                    ),
                    Item::Agg(..) => return None,
                };
                let wi = match windows.iter().position(|w| {
                    w.part == part && w.ord == ord && w.frame == frame
                }) {
                    Some(i) => i,
                    None => {
                        windows.push(Win {
                            ctx: 0,
                            part,
                            ord,
                            frame,
                            map: Vec::new(),
                            remap: Vec::new(),
                        });
                        windows.len() - 1
                    }
                };
                match entry {
                    WSlot::Direct(e) => {
                        // a window's map holds each entry ONCE: a repeated
                        // column or window function reads the same slot
                        // (measured: `ID, ID, COUNT(*) OVER ()` and two
                        // `COUNT(*) OVER ()` items map two entries)
                        let slot = match windows[wi].map.iter().position(|x| *x == e) {
                            Some(k) => k as u16,
                            None => {
                                windows[wi].map.push(e);
                                (windows[wi].map.len() - 1) as u16
                            }
                        };
                        slots.push((wi, slot));
                    }
                    WSlot::Rebuild(v) => {
                        // no key constraint: passthrough fields all
                        // land in the window's map
                        let mut gf = Vec::new();
                        collect_fields_deep(&v, &mut gf);
                        // ctx filled below; rebuild against slot ids
                        // with a placeholder ctx, fixed after
                        let rebuilt = rebuild_over_keys(
                            &mut windows[wi].map,
                            &v,
                            &gf,
                            0,
                        )?;
                        slots.push((wi, u16::MAX));
                        rebuilt_exprs.push((slots.len() - 1, wi, rebuilt));
                    }
                }
            }
            // the statement ORDER BY's own keys read the DEFAULT window -
            // created after the others when no item made it (measured:
            // `ROW_NUMBER() OVER (ORDER BY N) .. ORDER BY ID` is the
            // ROW_NUMBER window, then an empty one mapping ID); a column
            // already mapped there reuses its slot, a new one is appended
            for (k, (_, _, src)) in win_sort.iter().enumerate() {
                let Ok(v) = src else { continue };
                let wi = match windows.iter().position(|w| {
                    w.part.is_empty() && w.ord.is_empty() && w.frame.is_none()
                }) {
                    Some(i) => i,
                    None => {
                        windows.push(Win {
                            ctx: 0,
                            part: Vec::new(),
                            ord: Vec::new(),
                            frame: None,
                            map: Vec::new(),
                            remap: Vec::new(),
                        });
                        windows.len() - 1
                    }
                };
                let mut gf = Vec::new();
                collect_fields_deep(v, &mut gf);
                let rebuilt = rebuild_over_keys(&mut windows[wi].map, v, &gf, 0)?;
                sort_rebuilt.push((k, wi, rebuilt));
            }
            let win_base = self.streams.len() as u8 + self.base - 1;
            for (i, w) in windows.iter_mut().enumerate() {
                w.ctx = win_base + 1 + i as u8;
            }
            for _ in &windows {
                self.streams.push(Stream {
                    name: String::new(),
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
                    cur: None,
                    proc_args: None,
                });
            }
            // the partition keys join each window's map after its items:
            // a column (or an aggregate's fid) takes a slot, an expression
            // contributes its columns and remaps rebuilt over them (measured)
            for w in &mut windows {
                let keys = w.part.clone();
                for k in keys {
                    // a column already mapped reuses its slot (measured:
                    // `PARTITION BY G, G` and `UPPER(S), S` map S once)
                    let mut gf = Vec::new();
                    collect_fields_deep(&k, &mut gf);
                    w.remap.push(rebuild_over_keys(&mut w.map, &k, &gf, w.ctx)?);
                }
            }
            slots
        } else {
            Vec::new()
        };
        let col_vals: Vec<Val> = if let Some(u) = &union_ {
            (0..cols_n)
                .map(|i| Val::Fid(u.ctx, i as u16))
                .collect()
        } else if has_wins {
            let mut vals: Vec<Val> = win_slots
                .iter()
                .map(|(wi, slot)| Val::Fid(windows[*wi].ctx, *slot))
                .collect();
            // rebuilt passthrough expressions: patch the window ctx
            // into their fids now that contexts are assigned
            for (vi, wi, rebuilt) in &rebuilt_exprs {
                vals[*vi] = patch_fid_ctx(rebuilt, windows[*wi].ctx);
            }
            for (vi, r) in &win_exprs {
                vals[*vi] = patch_fid_win(r, &windows)?;
            }
            for (k, (desc, nulls, src)) in win_sort.iter().enumerate() {
                let v = match src {
                    Err(i) => vals.get(*i)?.clone(),
                    Ok(_) => {
                        let (_, wi, r) = sort_rebuilt.iter().find(|(j, _, _)| *j == k)?;
                        patch_fid_ctx(r, windows[*wi].ctx)
                    }
                };
                let v = match nulls {
                    Some(b) => Val::NullsPlaced(*b, Box::new(v)),
                    None => v,
                };
                sort.push((*desc, v));
            }
            vals
        } else if aggregate {
            agg_vals.take()?
        } else {
            items
                .iter()
                .map(|it| match it {
                    Item::Col(v) | Item::Expr(v) => Some(v.clone()),
                    Item::Agg(..) | Item::Win(..) => None,
                })
                .collect::<Option<Vec<_>>>()?
        };
        // OFFSET n ROW[S] / FETCH FIRST|NEXT n ROW[S] ONLY - the
        // standard spelling of SKIP and FIRST, same rse clauses in
        // the same probed order (probed)
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "OFFSET")
        {
            if skip.is_some() {
                return None;
            }
            self.i += 1;
            let Some(Tok::Int(n)) = self.t.get(self.i) else {
                return None;
            };
            skip = Some(Val::Int(i32::try_from(*n).ok()?));
            self.i += 1;
            if !(matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ROW" || w == "ROWS"))
            {
                return None;
            }
            self.i += 1;
        }
        if self.kw("FETCH") {
            if first.is_some() {
                return None;
            }
            if !(matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "FIRST" || w == "NEXT"))
            {
                return None;
            }
            self.i += 1;
            let Some(Tok::Int(n)) = self.t.get(self.i) else {
                return None;
            };
            first = Some(Val::Int(i32::try_from(*n).ok()?));
            self.i += 1;
            if !(matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ROW" || w == "ROWS"))
            {
                return None;
            }
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ONLY")
            {
                return None;
            }
            self.i += 1;
            // FIRST/SKIP refuse beside the structures they always
            // have - re-check now that they may have just appeared
            if !joins.is_empty() {
                return None;
            }
        }
        // ROWS m TO n - the legacy row limits: first = (n - m) + 1
        // and skip = m - 1, both UNFOLDED arithmetic (probed)
        if self.kw("ROWS") {
            if first.is_some() || skip.is_some() {
                return None;
            }
            let Some(Tok::Int(m)) = self.t.get(self.i) else {
                return None;
            };
            let m = i32::try_from(*m).ok()?;
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "TO") {
                self.i += 1;
                let Some(Tok::Int(n)) = self.t.get(self.i) else {
                    return None;
                };
                let n = i32::try_from(*n).ok()?;
                self.i += 1;
                first = Some(Val::Add(
                    Box::new(Val::Sub(
                        Box::new(Val::Int(n)),
                        Box::new(Val::Int(m)),
                    )),
                    Box::new(Val::Int(1)),
                ));
                skip = Some(Val::Sub(
                    Box::new(Val::Int(m)),
                    Box::new(Val::Int(1)),
                ));
            } else {
                // ROWS n alone is blr_first n (measured)
                first = Some(Val::Int(m));
            }
            if !joins.is_empty() {
                return None;
            }
        }
        self.skip_for_update()?;
        // WITH LOCK - probed beside a WHERE and alone; the shapes
        // beyond the probes (aggregates, FIRST/SKIP, ORDER BY) refuse
        let lock = if self.kw("WITH") {
            if !self.kw("LOCK")
                || aggregate
                || first.is_some()
                || skip.is_some()
                || !sort.is_empty()
                || !joins.is_empty()
                || has_wins
                || stream.derived.is_some()
            {
                return None;
            }
            true
        } else {
            false
        };
        // INTO :v, ... - output parameters and locals are ONE
        // variable space (outputs first); with AS CURSOR the INTO
        // clause is OPTIONAL (probed both ways)
        let mut into: Vec<u16> = Vec::new();
        if self.kw("INTO") {
            loop {
                // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
                // `RETURNING_VALUES N` are the engine's too (measured on 2196)
                if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                    self.i += 1;
                }
                let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                    return None;
                };
                let vi = self.local_vars.iter().position(|n| n == name)?;
                self.i += 1;
                into.push(vi as u16);
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
            if into.len() != cols_n {
                return None;
            }
        }
        // AS CURSOR <name> - looping form only; the shapes beyond
        // the probes (aggregates, FIRST/SKIP, ORDER BY) refuse
        let cursor = if self.kw("AS") {
            if !self.kw("CURSOR") || !is_for {
                return None;
            }
            if aggregate
                || first.is_some()
                || skip.is_some()
                || !sort.is_empty()
                || !joins.is_empty()
                || has_wins
                || stream.derived.is_some()
            {
                return None;
            }
            // the cursor's select is a DERIVED TABLE: every column needs a
            // name and no two may share one - the engine refuses at prepare
            // (measured: `FOR SELECT ID + 1 FROM T .. AS CURSOR C` is "no
            // column name specified for column number 1 in derived table
            // C", `SELECT ID, ID .. AS CURSOR C` a duplicate)
            for (k, n) in item_names.iter().enumerate() {
                let Some(n) = n else { return None };
                if item_names[..k].iter().any(|m| m.as_deref() == Some(n.as_str())) {
                    return None;
                }
            }
            let Some(Tok::Ident(cn)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(cn) {
                return None;
            }
            let cn = cn.clone();
            self.i += 1;
            Some(cn)
        } else {
            None
        };
        if cursor.is_none() && into.is_empty() {
            return None;
        }
        // AS CURSOR: subquery streams in the WHERE inherit the
        // cursor's alias, stamped now that the name is known
        if let (Some(cn), Some(b)) = (&cursor, &mut boolean) {
            stamp_bool(b, cn);
        }
        let (label, do_stmt) = if is_for {
            let label = self.next_label;
            self.next_label += 1;
            if !self.kw("DO") {
                return None;
            }
            if let Some(cn) = &cursor {
                self.for_cursors
                    .push((cn.clone(), ctx, stream.name.clone()));
            }
            self.loop_labels.push((self.pending_loop_label.take(), label));
            let body_opt = self.trig_stmt();
            self.loop_labels.pop();
            let body = body_opt?;
            if cursor.is_some() {
                self.for_cursors.pop();
            }
            (Some(label), Some(Box::new(body)))
        } else {
            if cursor.is_some() {
                return None; // AS CURSOR on the singular form
            }
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            (None, None)
        };
        let map = std::mem::take(&mut self.agg_map);
        if union_.is_some() && (lock || cursor.is_some()) {
            return None;
        }
        if plan.is_some()
            && (aggregate
                || has_wins
                || union_.is_some()
                || lock
                || cursor.is_some())
        {
            return None;
        }
        // DISTINCT in the singular form: unprobed
        if distinct && !is_for {
            return None;
        }
        // DISTINCT beside the structured shapes: unprobed
        // (DISTINCT over a DERIVED table: probed - the project's
        // fields translate through the derived list like any other
        // reference, so the guard term fell in slice 43)
        if distinct
            && (aggregate
                || union_.is_some()
                || !joins.is_empty()
                || cursor.is_some()
                || lock)
        {
            return None;
        }
        Some(TrigStmt::ForSel(Box::new(ForSel {
            label,
            stream,
            ctx,
            cursor,
            lock,
            joins,
            windows,
            distinct,
            plan,
            union_,
            aggregate,
            agg_ctx: self.agg_fid_ctx,
            map,
            group_keys,
            boolean,
            having,
            sort,
            first,
            skip,
            col_vals,
            into,
            do_stmt,
            recurse: None,
        })))
    }


    /// The parameterized EXECUTE STATEMENT head: ('<literal sql>')
    /// (val [, ...] | name := val [, ...]) - self.i at the opening
    /// paren of the sql. All parameters named or all unnamed (the
    /// two live under different tags - mixing refuses).
    /// The SQL operand of an EXECUTE STATEMENT: a `(literal) (params)`
    /// head, or - for the dynamic forms - any expression that yields the
    /// text (a bare literal, or a `||` concatenation of literals and
    /// variables). Returns the operand as a Val and the positional/named
    /// input parameters (empty unless it was a params head).
    fn exec_stmt_sql_arg(&mut self) -> Option<(Val, Vec<(Option<String>, Val)>)> {
        if matches!(self.t.get(self.i), Some(Tok::LParen)) {
            let save = self.i;
            if let Some((sql, ins)) = self.exec_stmt_head() {
                return Some((Val::Str(sql), ins));
            }
            self.i = save;
        }
        Some((self.val()?, Vec::new()))
    }

    fn exec_stmt_head(
        &mut self,
    ) -> Option<(String, Vec<(Option<String>, Val)>)> {
        self.i += 1; // (
        let Some(Tok::Str(sql)) = self.t.get(self.i) else {
            return None;
        };
        let sql = sql.clone();
        self.i += 1;
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        let mut ins: Vec<(Option<String>, Val)> = Vec::new();
        loop {
            // name := value (the lexer splits := into : =)
            let named = matches!(
                (self.t.get(self.i), self.t.get(self.i + 1), self.t.get(self.i + 2)),
                (
                    Some(Tok::Ident(n)),
                    Some(Tok::Colon),
                    Some(Tok::Cmp(CmpOp::Eql))
                ) if !is_keyword(n)
            );
            let name = if named {
                let Some(Tok::Ident(n)) = self.t.get(self.i) else {
                    return None;
                };
                let n = n.clone();
                self.i += 3;
                Some(n)
            } else {
                None
            };
            if ins.first().is_some_and(|(f, _)| f.is_some() != name.is_some())
            {
                return None; // mixed named/unnamed
            }
            ins.push((name, self.val()?));
            match self.t.get(self.i)? {
                Tok::Comma => self.i += 1,
                Tok::RParen => {
                    self.i += 1;
                    break;
                }
                _ => return None,
            }
        }
        Some((sql, ins))
    }

    /// EXECUTE STATEMENT's optional tail modifiers, any order:
    /// ON EXTERNAL <v>, AS USER <v>, PASSWORD <v>, ROLE <v>.
    fn exec_stmt_mods(
        &mut self,
    ) -> Option<(Option<Val>, Option<Val>, Option<Val>, Option<Val>)> {
        let (mut ds, mut user, mut pwd, mut role) = (None, None, None, None);
        loop {
            if self.kw("ON") {
                if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "EXTERNAL")
                    || ds.is_some()
                {
                    return None;
                }
                self.i += 1;
                ds = Some(self.val()?);
            } else if self.kw("AS") {
                if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "USER")
                    || user.is_some()
                {
                    return None;
                }
                self.i += 1;
                user = Some(self.val()?);
            } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "PASSWORD")
            {
                if pwd.is_some() {
                    return None;
                }
                self.i += 1;
                pwd = Some(self.val()?);
            } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ROLE")
            {
                if role.is_some() {
                    return None;
                }
                self.i += 1;
                role = Some(self.val()?);
            } else {
                break;
            }
        }
        Some((ds, user, pwd, role))
    }

    /// An optional RETURNING col [, ...] INTO :v [, ...] tail on a
    /// DML statement - plain unqualified columns into locals; an
    /// absent clause answers the empty list.
    fn returning_into(&mut self) -> Option<Vec<(String, u16)>> {
        if !self.kw("RETURNING") {
            return Some(Vec::new());
        }
        let mut cols = Vec::new();
        loop {
            let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(c) {
                return None;
            }
            cols.push(c.clone());
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        if !self.kw("INTO") {
            return None;
        }
        let mut out = Vec::new();
        for c in cols {
            // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
            // `RETURNING_VALUES N` are the engine's too (measured on 2196)
            if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                self.i += 1;
            }
            let Some(Tok::Ident(v)) = self.t.get(self.i) else {
                return None;
            };
            let vi = self.local_vars.iter().position(|n| n == v)? as u16;
            self.i += 1;
            out.push((c, vi));
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            }
        }
        Some(out)
    }

    /// A cursor WHERE CURRENT OF may target: a DECLAREd cursor
    /// (plain - the engine refuses positioned DML on aggregates) or
    /// an in-scope FOR SELECT ... AS CURSOR loop. Answers the
    /// cursor's context and table.
    fn find_pos_cursor(&self, name: &str) -> Option<(u8, String)> {
        if let Some(d) = self.cursor_decls.iter().find(|d| d.name == name) {
            if d.agg.is_some() || !d.joins.is_empty() {
                return None;
            }
            return Some((d.ctx, d.table.clone()));
        }
        // innermost scope first
        self.for_cursors
            .iter()
            .rev()
            .find(|(n, ..)| n == name)
            .map(|(_, ctx, tbl)| (*ctx, tbl.clone()))
    }

    /// DECLARE PROCEDURE/FUNCTION <name> ...: the nested body runs
    /// through body_compile on a FRESH parser (own variables,
    /// streams, labels - subroutines see nothing of the outer
    /// scope), then wraps in blr_subproc_decl/blr_subfunc_decl with
    /// the u32-counted blob. Streams inside emit blr_relation3 (see
    /// emit_stream); nested subroutines refuse.
    fn sub_decl(&mut self, func: bool) -> Option<usize> {
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        self.i += 1;
        if self.in_sub {
            return None;
        }
        let mut inner = P::fresh(self.t);
        inner.i = self.i;
        inner.in_sub = true;
        let bo = body_compile(&mut inner, func, true)?;
        self.i = inner.i;
        let mut blob = Vec::new();
        blob.push(if func {
            blr::SUBFUNC_DECL
        } else {
            blr::SUBPROC_DECL
        });
        blob.push(name.len() as u8);
        blob.extend_from_slice(name.as_bytes());
        blob.push(0); // SUB_ROUTINE_TYPE_PSQL
        blob.push(if func {
            bo.deterministic as u8
        } else {
            bo.selectable as u8
        });
        for list in [&bo.ins, &bo.outs] {
            blob.extend_from_slice(&(list.len() as u16).to_le_bytes());
            for (n, _) in list.iter() {
                blob.push(n.len() as u8);
                blob.extend_from_slice(n.as_bytes());
                blob.push(0); // no default clause
            }
        }
        blob.extend_from_slice(&(bo.blob.len() as u32).to_le_bytes());
        blob.extend_from_slice(&bo.blob);
        let idx = self.sub_decls.len();
        self.sub_decls.push(blob);
        if func {
            self.sub_funcs.push((name, bo.ins.len()));
        } else {
            self.sub_procs.push((name, bo.ins.len(), bo.outs.len()));
        }
        Some(idx)
    }

    /// DECLARE <name> CURSOR FOR (SELECT cols FROM tbl [alias]
    /// [WHERE] [GROUP BY] [ORDER BY]); - self.i past the CURSOR
    /// keyword. The rse's relation2 alias carries the CURSOR NAME;
    /// columns may be qualified by the table alias or name; aggregate
    /// selects (their columns AS-aliased - the engine demands a name)
    /// nest blr_aggregate and consume a SECOND context slot (all
    /// probed). Shared by procedure and trigger declaration sections.
    fn cursor_decl(&mut self, name: String, scroll: bool) -> Option<()> {
        if !self.kw("FOR") || !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        if !self.kw("SELECT") {
            return None;
        }
        // a select item: [qual.]col or COUNT(*)/COUNT/SUM/AVG/
        // MIN/MAX([qual.]col), each with an optional traceless
        // AS alias
        enum RawItem {
    /// `col[subs]` - an array element of a column
    ColIdx(Option<String>, String, Vec<Val>),
            Col(Option<String>, String),
            Agg(u8, Option<(Option<String>, String)>),
        }
        let qual_name = |p: &mut P| -> Option<(Option<String>, String)> {
            let Some(Tok::Ident(a)) = p.t.get(p.i) else {
                return None;
            };
            if is_keyword(a) {
                return None;
            }
            let a = a.clone();
            p.i += 1;
            if matches!(p.t.get(p.i), Some(Tok::Dot)) {
                p.i += 1;
                let Some(Tok::Ident(b)) = p.t.get(p.i) else {
                    return None;
                };
                if is_keyword(b) {
                    return None;
                }
                let b = b.clone();
                p.i += 1;
                Some((Some(a), b))
            } else {
                Some((None, a))
            }
        };
        let mut items: Vec<RawItem> = Vec::new();
        loop {
            let agg = match self.t.get(self.i) {
                Some(Tok::Ident(f))
                    if matches!(
                        f.as_str(),
                        "COUNT" | "SUM" | "AVG" | "MIN" | "MAX"
                    ) && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) =>
                {
                    Some(f.clone())
                }
                _ => None,
            };
            if let Some(f) = agg {
                self.i += 2;
                // DISTINCT / expression arguments: unprobed
                let (verb, arg) = if f == "COUNT"
                    && matches!(self.t.get(self.i), Some(Tok::Star))
                {
                    self.i += 1;
                    (blr::AGG_COUNT, None)
                } else {
                    let a = qual_name(self)?;
                    let verb = match f.as_str() {
                        "COUNT" => blr::AGG_COUNT2,
                        "SUM" => blr::AGG_TOTAL,
                        "AVG" => blr::AGG_AVERAGE,
                        "MIN" => blr::AGG_MIN,
                        _ => blr::AGG_MAX,
                    };
                    (verb, Some(a))
                };
                if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    return None;
                }
                self.i += 1;
                items.push(RawItem::Agg(verb, arg));
            } else {
                let (q, n) = qual_name(self)?;
                if matches!(self.t.get(self.i), Some(Tok::LBracket)) {
                    // an ARRAY element item: `language_req[:i]`
                    self.i += 1;
                    let mut subs = vec![self.val()?];
                    while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        subs.push(self.val()?);
                    }
                    if !matches!(self.t.get(self.i), Some(Tok::RBracket)) {
                        return None;
                    }
                    self.i += 1;
                    items.push(RawItem::ColIdx(q, n, subs));
                } else {
                    items.push(RawItem::Col(q, n));
                }
            }
            // an AS alias names the derived column - traceless,
            // but REQUIRED on an aggregate (the engine demands a
            // column name for it)
            if self.kw("AS") {
                let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(a) {
                    return None;
                }
                self.i += 1;
            } else if matches!(items.last(), Some(RawItem::Agg(..))) {
                return None;
            }
            match self.t.get(self.i)? {
                Tok::Comma => self.i += 1,
                _ => break,
            }
        }
        if items.is_empty() || !self.kw("FROM") {
            return None;
        }
        let Some(Tok::Ident(tbl)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(tbl) {
            return None;
        }
        let tbl = tbl.clone();
        self.i += 1;
        let alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        self.streams.push(Stream {
            name: tbl.clone(),
            alias: alias.clone(),
            derived: None,
            sub: self.in_sub,
            cur: None,
            proc_args: None,
        });
        let sidx = self.streams.len() - 1;
        let ctx = sidx as u8 + self.base;
        // JOIN chain - both streams carry the cursor pairing, the
        // ON resolving across the accumulated streams (probed)
        let mut joins: Vec<(u8, Stream, u8, Bool)> = Vec::new();
        loop {
            let jt = if self.kw("INNER") {
                if !self.kw("JOIN") {
                    return None;
                }
                0u8
            } else if self.kw("JOIN") {
                0
            } else if self.kw("LEFT") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                1
            } else if self.kw("RIGHT") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                2
            } else if self.kw("FULL") {
                let _ = self.kw("OUTER");
                if !self.kw("JOIN") {
                    return None;
                }
                3
            } else {
                break;
            };
            let Some(Tok::Ident(jn)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(jn) {
                return None;
            }
            let jn = jn.clone();
            self.i += 1;
            let jalias = match self.t.get(self.i) {
                Some(Tok::Ident(a)) if !is_keyword(a) => {
                    let a = a.clone();
                    self.i += 1;
                    Some(a)
                }
                _ => None,
            };
            let st2 = Stream {
                name: jn,
                alias: jalias,
                derived: None,
                sub: self.in_sub,
                cur: Some(name.clone()),
                proc_args: None,
            };
            self.streams.push(st2.clone());
            let ctx2 = (self.streams.len() - 1) as u8 + self.base;
            if !self.kw("ON") {
                return None;
            }
            let saved_scope = self.merge_scope;
            self.merge_scope = Some((sidx, self.streams.len()));
            let on = self.bool_or()?;
            self.merge_scope = saved_scope;
            joins.push((jt, st2, ctx2, on));
        }
        // a COMMA-SEPARATED stream list (`FROM sales s, customer c`, the
        // employee sample's SHIP_ORDER): the engine compiles it to ONE
        // flat rse with all the streams and the WHERE as its boolean
        // (measured), which [JOIN_COMMA] marks for the emitter; mixing it
        // with an explicit JOIN chain is unprobed and refuses
        while matches!(self.t.get(self.i), Some(Tok::Comma)) {
            if joins.iter().any(|j| j.0 != JOIN_COMMA) {
                return None;
            }
            self.i += 1;
            let st2 = self.stream_item()?;
            if st2.derived.is_some() {
                return None;
            }
            let mut st2 = st2;
            st2.cur = Some(name.clone());
            self.streams.push(st2.clone());
            let ctx2 = (self.streams.len() - 1) as u8 + self.base;
            joins.push((JOIN_COMMA, st2, ctx2, Bool::Missing(Val::Null)));
        }
        let aggregate = items
            .iter()
            .any(|it| matches!(it, RawItem::Agg(..)));
        // aggregates over a joined cursor: unprobed
        if aggregate && !joins.is_empty() {
            return None;
        }
        // the aggregate claims the NEXT context slot (probed:
        // a second cursor's aggregate sat at ctx 2 over its
        // stream's 1)
        let agg = if aggregate {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            Some((self.streams.len() - 1) as u8 + self.base)
        } else {
            None
        };
        let resolve = |q: &Option<String>, n: &str| -> Option<Val> {
            match q {
                Some(q) => {
                    let hit = |st_name: &str, st_alias: &Option<String>| {
                        st_alias.as_deref().map_or(st_name == q, |a| a == q)
                    };
                    if hit(&tbl, &alias) {
                        return Some(Val::Field(ctx, n.to_string()));
                    }
                    for (_, st, jctx, _) in &joins {
                        if hit(&st.name, &st.alias) {
                            return Some(Val::Field(*jctx, n.to_string()));
                        }
                    }
                    None
                }
                None => {
                    // bare names across a join: the catalog says which
                    // stream owns the column (exactly one)
                    if !joins.is_empty() {
                        let mut hits: Vec<u8> = Vec::new();
                        if catalog_has(&tbl, n) {
                            hits.push(ctx);
                        }
                        for (_, st, jctx, _) in &joins {
                            if catalog_has(&st.name, n) {
                                hits.push(*jctx);
                            }
                        }
                        if hits.len() != 1 {
                            return None;
                        }
                        return Some(Val::Field(hits[0], n.to_string()));
                    }
                    Some(Val::Field(ctx, n.to_string()))
                }
            }
        };
        let mut map: Vec<MapEntry> = Vec::new();
        let mut group_keys: Vec<Val> = Vec::new();
        let mut outs: Vec<Val> = Vec::new();
        if let Some(agg_ctx) = agg {
            // map slots in SELECT-LIST order: group keys as
            // blr_map keys, aggregates as their verbs; outputs
            // are bare fids on the aggregate context
            for it in &items {
                match it {
                    RawItem::Col(q, n) => {
                        map.push(MapEntry::Key(resolve(q, n)?))
                    }
                    RawItem::Agg(verb, arg) => map.push(MapEntry::Agg(
                        *verb,
                        match arg {
                            Some((q, n)) => Some(resolve(q, n)?),
                            None => None,
                        },
                    )),
                    RawItem::ColIdx(..) => return None, // an array element as a group key: unprobed
                }
                outs.push(Val::Fid(agg_ctx, (outs.len()) as u16));
            }
        } else {
            for it in &items {
                match it {
                    RawItem::Col(q, n) => outs.push(resolve(q, n)?),
                    RawItem::ColIdx(q, n, subs) => {
                        outs.push(Val::ArrayElem(Box::new(resolve(q, n)?), subs.clone()))
                    }
                    RawItem::Agg(..) => return None,
                }
            }
        }
        let saved = self.sub.replace(sidx);
        let saved_scope = self.merge_scope;
        if !joins.is_empty() {
            // every FROM stream - a derived aggregate's placeholder slot included
            self.merge_scope = Some((sidx, self.streams.len()));
        }
        let mut boolean = if self.kw("WHERE") {
            Some(self.bool_or()?)
        } else {
            None
        };
        self.merge_scope = saved_scope;
        // subquery streams inside a cursor's rse INHERIT the
        // cursor's concatenated alias (probed) - stamp them
        if let Some(b) = &mut boolean {
            stamp_bool(b, &name);
        }
        if self.kw("GROUP") {
            if !aggregate || !self.kw("BY") {
                return None;
            }
            loop {
                let (q, n) = qual_name(self)?;
                group_keys.push(resolve(&q, &n)?);
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        let mut sort: Vec<(bool, Val)> = Vec::new();
        if self.kw("ORDER") {
            // over an aggregate: unprobed
            if aggregate || !self.kw("BY") {
                return None;
            }
            loop {
                let (q, k) = qual_name(self)?;
                let key = resolve(&q, &k)?;
                let descending = if self.kw("DESC") {
                    true
                } else {
                    let _ = self.kw("ASC");
                    false
                };
                let key = self.nulls_placement(key)?;
                sort.push((descending, key));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        self.sub = saved;
        self.skip_for_update()?;
        // WITH LOCK - refused over aggregates and sorts (unprobed)
        let lock = if self.kw("WITH") {
            if !self.kw("LOCK")
                || aggregate
                || !sort.is_empty()
                || !joins.is_empty()
            {
                return None;
            }
            true
        } else {
            false
        };
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
            return None;
        }
        self.i += 1;
        let num = self.cursors.len() as u16;
        self.cursors.push(name.clone());
        self.cursor_decls.push(CursorDecl {
            name,
            num,
            scroll,
            lock,
            sub: self.in_sub,
            joins,
            table: tbl,
            alias,
            ctx,
            agg,
            map,
            group_keys,
            outs,
            boolean,
            sort,
        });
        Some(())
    }

    /// UPDATE rel SET ... WHERE CURRENT OF cur; - self.i past the
    /// relation name, the positioned tail already sighted. The modify
    /// runs from the CURSOR's context to one fresh slot; SET sources
    /// read the cursor's stream (probed: SALARY = SALARY + 1 kept its
    /// source field at the cursor's context).
    fn positioned_update(&mut self, rel: String) -> Option<TrigStmt> {
        // the cursor's name from the tail - the SET values need its
        // context before the tail is consumed
        let mut j = self.i;
        let cur = loop {
            match self.t.get(j)? {
                Tok::Ident(w) if w == "WHERE" => {
                    if let (Some(Tok::Ident(c)), Some(Tok::Ident(o)), Some(Tok::Ident(n))) = (
                        self.t.get(j + 1),
                        self.t.get(j + 2),
                        self.t.get(j + 3),
                    ) {
                        if c == "CURRENT" && o == "OF" && !is_keyword(n) {
                            break n.clone();
                        }
                    }
                    return None;
                }
                Tok::Semi => return None,
                _ => j += 1,
            }
        };
        let (org_ctx, ctbl) = self.find_pos_cursor(&cur)?;
        if ctbl != rel {
            return None;
        }
        let org_idx = (org_ctx - self.base) as usize;
        self.streams.push(Stream {
            name: String::new(),
            alias: None,
            derived: None,
            sub: self.in_sub,
            cur: None,
            proc_args: None,
        });
        let new_ctx = (self.streams.len() - 1) as u8 + self.base;
        if !self.kw("SET") {
            return None;
        }
        let saved = self.sub.replace(org_idx);
        let mut sets = Vec::new();
        loop {
            let Some(Tok::Ident(col)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(col) {
                return None;
            }
            let target = Val::Field(new_ctx, col.clone());
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::Cmp(CmpOp::Eql))) {
                return None;
            }
            self.i += 1;
            sets.push((target, self.val()?));
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        self.sub = saved;
        if !(self.kw("WHERE") && self.kw("CURRENT") && self.kw("OF")) {
            return None;
        }
        // the tail names the cursor sighted above
        if !matches!(self.t.get(self.i), Some(Tok::Ident(n)) if *n == cur) {
            return None;
        }
        self.i += 1;
        if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
            return None;
        }
        self.i += 1;
        Some(TrigStmt::PosUpdate(org_ctx, new_ctx, sets))
    }

    /// OVER ( [PARTITION BY cols] [ORDER BY key [ASC|DESC], ...] ) -
    /// keys resolve at the given (single) stream context (probed)
    #[allow(clippy::type_complexity)]
    fn over_clause(
        &mut self,
        ctx: u8,
    ) -> Option<(
        Vec<Val>,
        Vec<(bool, Val)>,
        Option<(u8, (u8, Option<Val>), (u8, Option<Val>))>,
    )> {
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        let mut key = |p: &mut P| -> Option<Val> {
            let Some(Tok::Ident(a)) = p.t.get(p.i) else {
                return None;
            };
            // over an AGGREGATE a key may be an aggregate itself (`RANK() OVER
            // (ORDER BY SUM(SALARY))`): it takes its slot in the aggregate's
            // map (measured) - the agg_mode interception in func()
            if p.agg_mode
                && matches!(a.as_str(), "COUNT" | "SUM" | "AVG" | "MIN" | "MAX")
                && matches!(p.t.get(p.i + 1), Some(Tok::LParen))
            {
                return p.val();
            }
            if is_keyword(a) {
                return None;
            }
            // anything but a bare or qualified column is an EXPRESSION key:
            // emitted as written in the window's sort, rebuilt over the map
            // as a partition key (measured: `PARTITION BY G + 1`, `ORDER BY
            // ABS(N)`)
            let col_end = if matches!(p.t.get(p.i + 1), Some(Tok::Dot)) { p.i + 3 } else { p.i + 1 };
            let bare = match p.t.get(col_end) {
                Some(Tok::Comma) | Some(Tok::RParen) => true,
                Some(Tok::Ident(w)) => matches!(
                    w.as_str(),
                    "ASC" | "ASCENDING" | "DESC" | "DESCENDING" | "NULLS" | "ORDER" | "ROWS" | "RANGE"
                ),
                _ => false,
            };
            if !bare {
                return p.val();
            }
            let a = a.clone();
            p.i += 1;
            if matches!(p.t.get(p.i), Some(Tok::Dot)) {
                p.i += 1;
                let Some(Tok::Ident(b)) = p.t.get(p.i) else {
                    return None;
                };
                let b = b.clone();
                p.i += 1;
                p.field(Some(&a), &b)
            } else {
                Some(Val::Field(ctx, a))
            }
        };
        let mut part = Vec::new();
        if self.kw("PARTITION") {
            if !self.kw("BY") {
                return None;
            }
            loop {
                part.push(key(self)?);
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        let mut ord = Vec::new();
        if self.kw("ORDER") {
            if !self.kw("BY") {
                return None;
            }
            loop {
                let k = key(self)?;
                let descending = if self.kw("DESC") {
                    true
                } else {
                    let _ = self.kw("ASC");
                    false
                };
                let k = self.nulls_placement(k)?;
                ord.push((descending, k));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        // the FRAME: ROWS(1)/RANGE(0), BETWEEN two bounds or one
        // bound with CURRENT ROW implied as the second; a bound is
        // UNBOUNDED PRECEDING(0)/FOLLOWING(1) - no value - CURRENT
        // ROW(2), or <value> PRECEDING/FOLLOWING (probed; demands
        // an ORDER BY)
        let mut frame = None;
        let unit = if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ROWS")
        {
            Some(1u8)
        } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "RANGE")
        {
            Some(0u8)
        } else {
            None
        };
        if let Some(unit) = unit {
            if ord.is_empty() {
                return None;
            }
            self.i += 1;
            let mut bound = |p: &mut P| -> Option<(u8, Option<Val>)> {
                if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "UNBOUNDED")
                {
                    p.i += 1;
                    if p.kw("PRECEDING") {
                        return Some((0, None));
                    }
                    if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "FOLLOWING")
                    {
                        p.i += 1;
                        return Some((1, None));
                    }
                    return None;
                }
                if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "CURRENT")
                {
                    p.i += 1;
                    if !matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "ROW")
                    {
                        return None;
                    }
                    p.i += 1;
                    return Some((2, None));
                }
                let v = p.val()?;
                if p.kw("PRECEDING") {
                    return Some((0, Some(v)));
                }
                if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "FOLLOWING")
                {
                    p.i += 1;
                    return Some((1, Some(v)));
                }
                None
            };
            if self.kw("BETWEEN") {
                let b1 = bound(self)?;
                if !self.kw("AND") {
                    return None;
                }
                let b2 = bound(self)?;
                frame = Some((unit, b1, b2));
            } else {
                let b1 = bound(self)?;
                frame = Some((unit, b1, (2, None)));
            }
        }
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        Some((part, ord, frame))
    }

    /// WITH <name> AS ( ... ) - records the body's token span; the
    /// FROM reference expands it as a derived table (probed). One
    /// cte, referenced exactly once; recursion refuses because the
    /// expansion consumes the single use.
    /// FOR WITH RECURSIVE <name> AS (SELECT <col> FROM <table>
    /// [WHERE ...] UNION ALL SELECT <item> FROM <name> [WHERE ...])
    /// SELECT [<name>.]<col> FROM <name> INTO :v DO <stmt> - the
    /// blr_recurse tower. Context law (probed): the SECONDARY
    /// recursive context claims the next slot, the recursion context
    /// the one after, the anchor stream the one after that.
    fn recursive_for(&mut self) -> Option<TrigStmt> {
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let cte = name.clone();
        self.i += 1;
        if !self.kw("AS") || !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        // contexts: secondary, recurse, anchor - in that order
        for _ in 0..3 {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
        }
        let secondary = (self.streams.len() - 3) as u8 + self.base;
        let ctx = secondary + 1;
        let anchor_ctx = secondary + 2;
        // ---- the anchor branch: SELECT <col> [, ...] FROM <table>
        if !self.kw("SELECT") {
            return None;
        }
        let mut acols: Vec<String> = Vec::new();
        loop {
            let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(c) {
                return None;
            }
            acols.push(c.clone());
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        let acol = acols[0].clone();
        if !self.kw("FROM") {
            return None;
        }
        let Some(Tok::Ident(table)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(table) {
            return None;
        }
        let table = table.clone();
        self.i += 1;
        // anchor WHERE: bare names bind the anchor stream - resolve
        // by hand (plain columns and literals only, this slice)
        let anchor_wher = if self.kw("WHERE") {
            Some(self.rec_bool(anchor_ctx, &cte, ctx, &acols, false)?)
        } else {
            None
        };
        if !self.kw("UNION") || !self.kw("ALL") || !self.kw("SELECT") {
            return None;
        }
        // ---- the recursive branch: <item> [, ...] FROM <name>
        let mut rec_items = Vec::new();
        loop {
            rec_items.push(self.rec_val(&cte, ctx, &acols)?);
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        if rec_items.len() != acols.len() {
            return None;
        }
        // the unification is PER COLUMN: a column whose RECURSIVE
        // item is integer arithmetic types int64 and its anchor
        // field casts; a plain column's does not (probed)
        let anchor_items: Vec<(Val, bool)> = acols
            .iter()
            .zip(&rec_items)
            .map(|(c, r)| {
                (
                    Val::Field(anchor_ctx, c.clone()),
                    matches!(r, Val::Add(..) | Val::Sub(..)),
                )
            })
            .collect();
        if !self.kw("FROM") {
            return None;
        }
        if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if *w == cte) {
            return None;
        }
        self.i += 1;
        let rec_wher = if self.kw("WHERE") {
            Some(self.rec_bool(0, &cte, ctx, &acols, true)?)
        } else {
            None
        };
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        // ---- the outer select: [<name>.]<col> [, ...] FROM <name>
        if !self.kw("SELECT") {
            return None;
        }
        let mut outs = Vec::new();
        loop {
            let v = self.rec_val(&cte, ctx, &acols)?;
            if !matches!(v, Val::Fid(..)) {
                return None; // outer expressions over the cte: unprobed
            }
            outs.push(v);
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        if !self.kw("FROM") {
            return None;
        }
        if !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if *w == cte) {
            return None;
        }
        self.i += 1;
        if !self.kw("INTO") {
            return None;
        }
        let mut into = Vec::new();
        loop {
            // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
            // `RETURNING_VALUES N` are the engine's too (measured on 2196)
            if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                self.i += 1;
            }
            let Some(Tok::Ident(vn)) = self.t.get(self.i) else {
                return None;
            };
            let vi = self.local_vars.iter().position(|n| n == vn)? as u16;
            into.push(vi);
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        let label = self.next_label;
        self.next_label += 1;
        if !self.kw("DO") {
            return None;
        }
        self.loop_labels.push((self.pending_loop_label.take(), label));
        let body_opt = self.trig_stmt();
        self.loop_labels.pop();
        let do_stmt = Some(Box::new(body_opt?));
        Some(TrigStmt::ForSel(Box::new(ForSel {
            label: Some(label),
            stream: Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            },
            ctx,
            cursor: None,
            lock: false,
            joins: Vec::new(),
            windows: Vec::new(),
            distinct: false,
            plan: None,
            union_: None,
            aggregate: false,
            agg_ctx: self.agg_fid_ctx,
            map: Vec::new(),
            group_keys: Vec::new(),
            boolean: None,
            having: None,
            sort: Vec::new(),
            first: None,
            skip: None,
            col_vals: outs,
            into,
            do_stmt,
            recurse: Some(RecCte {
                ctx,
                secondary,
                anchor_table: table.to_ascii_uppercase(),
                anchor_alias: format!(
                    "\"{}\" \"{}\".\"{}\"",
                    cte.to_ascii_uppercase(),
                    relation_schema(&table.to_ascii_uppercase()),
                    table.to_ascii_uppercase()
                ),
                anchor_ctx,
                anchor_wher,
                anchor_items,
                rec_wher,
                rec_items,
            }),
        })))
    }

    /// A value inside the recursive cte's scope: [<cte>.]<col> reads
    /// fid(recurse ctx, 0) when the column is the cte's one column;
    /// optional +/- integer literal (dialect-3 int64 arithmetic).
    fn rec_val(&mut self, cte: &str, ctx: u8, acols: &[String]) -> Option<Val> {
        let Some(Tok::Ident(a)) = self.t.get(self.i) else {
            return None;
        };
        let a = a.clone();
        if is_keyword(&a) {
            return None;
        }
        self.i += 1;
        let col = if a == cte && matches!(self.t.get(self.i), Some(Tok::Dot)) {
            self.i += 1;
            let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                return None;
            };
            let b = b.clone();
            self.i += 1;
            b
        } else {
            a
        };
        let slot = acols.iter().position(|c| *c == col)? as u16;
        let base = Val::Fid(ctx, slot);
        match self.t.get(self.i) {
            Some(Tok::Plus) => {
                self.i += 1;
                let Some(Tok::Int(n)) = self.t.get(self.i) else {
                    return None;
                };
                let n = i32::try_from(*n).ok()?;
                self.i += 1;
                Some(Val::Add(Box::new(base), Box::new(Val::Int(n))))
            }
            Some(Tok::Minus) => {
                self.i += 1;
                let Some(Tok::Int(n)) = self.t.get(self.i) else {
                    return None;
                };
                let n = i32::try_from(*n).ok()?;
                self.i += 1;
                Some(Val::Sub(Box::new(base), Box::new(Val::Int(n))))
            }
            _ => Some(base),
        }
    }

    /// A boolean inside the recursive tower: one comparison, left a
    /// column of the branch's scope (anchor field or recursion fid),
    /// right an integer literal.
    fn rec_bool(
        &mut self,
        field_ctx: u8,
        cte: &str,
        ctx: u8,
        acols: &[String],
        recursive: bool,
    ) -> Option<Bool> {
        let left = if recursive {
            self.rec_val(cte, ctx, acols)?
        } else {
            let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                return None;
            };
            let a = a.clone();
            if is_keyword(&a) {
                return None;
            }
            self.i += 1;
            Val::Field(field_ctx, a)
        };
        let Some(Tok::Cmp(op)) = self.t.get(self.i) else {
            return None;
        };
        let op = *op;
        self.i += 1;
        let Some(Tok::Int(n)) = self.t.get(self.i) else {
            return None;
        };
        let n = i32::try_from(*n).ok()?;
        self.i += 1;
        Some(Bool::Cmp(op, left, Val::Int(n)))
    }

    fn parse_cte(&mut self) -> Option<()> {
        loop {
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let name = name.clone();
            self.i += 1;
            if !self.kw("AS")
                || !matches!(self.t.get(self.i), Some(Tok::LParen))
            {
                return None;
            }
            self.i += 1;
            let start = self.i;
            let mut depth = 0i32;
            let mut j = self.i;
            let end = loop {
                match self.t.get(j)? {
                    Tok::LParen => depth += 1,
                    Tok::RParen => {
                        if depth == 0 {
                            break j;
                        }
                        depth -= 1;
                    }
                    _ => {}
                }
                j += 1;
            };
            self.ctes.push((name, start, end, false));
            self.i = end + 1;
            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
            } else {
                break;
            }
        }
        Some(())
    }

    /// one trigger-body statement; self.i past any leading keyword
    /// The label number a bare or labelled LEAVE/CONTINUE targets:
    /// bare (`;` next) is the innermost loop; `<name>` names an enclosing
    /// loop. Consumes the optional name and the terminating `;`.
    fn loop_target(&mut self) -> Option<u8> {
        let l = match self.t.get(self.i) {
            Some(Tok::Semi) => self.loop_labels.last()?.1,
            Some(Tok::Ident(name)) if !is_keyword(name) => {
                let name = name.clone();
                self.i += 1;
                self.loop_labels
                    .iter()
                    .rev()
                    .find(|(n, _)| n.as_deref() == Some(name.as_str()))?
                    .1
            }
            _ => return None,
        };
        if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
            return None;
        }
        self.i += 1;
        Some(l)
    }

    fn trig_stmt(&mut self) -> Option<TrigStmt> {
        // an optional loop label: `<name>: <WHILE|FOR ...>`
        if let (Some(Tok::Ident(x)), Some(Tok::Colon)) = (self.t.get(self.i), self.t.get(self.i + 1)) {
            if !is_keyword(x) {
                let name = x.clone();
                // a label may prefix only a loop
                let after = self.t.get(self.i + 2);
                let is_loop = matches!(after, Some(Tok::Ident(w)) if w == "WHILE" || w == "FOR");
                if is_loop {
                    self.i += 2;
                    self.pending_loop_label = Some(name);
                }
            }
        }
        if self.kw("BEGIN") {
            let mut stmts = Vec::new();
            loop {
                if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "END" || w == "WHEN")
                {
                    break;
                }
                stmts.push(self.trig_stmt()?);
            }
            // WHEN <code> DO <stmt>, repeatable: one error-handler
            // section per WHEN (probed sequential); a handler's body
            // may be a plain statement or a BEGIN..END block
            let mut handlers: Vec<(Vec<HandlerCode>, TrigStmt)> = Vec::new();
            while self.kw("WHEN") {
                // one WHEN may guard SEVERAL conditions, comma-separated
                // (WHEN EXCEPTION A, EXCEPTION B DO ...); the server
                // interpreter already splits on the comma, and the BLR
                // carries them as one error-handler with a count
                let mut codes: Vec<HandlerCode> = Vec::new();
                loop {
                    let code = if self.kw("ANY") {
                        HandlerCode::Any
                    } else if self.kw("EXCEPTION") {
                        let Some(Tok::Ident(n)) = self.t.get(self.i) else {
                            return None;
                        };
                        let n = n.clone();
                        self.i += 1;
                        HandlerCode::Exception(n)
                    } else if self.kw("GDSCODE") {
                        let Some(Tok::Ident(n)) = self.t.get(self.i) else {
                            return None;
                        };
                        let n = n.clone();
                        self.i += 1;
                        HandlerCode::Gds(n)
                    } else if self.kw("SQLCODE") {
                        let neg = matches!(self.t.get(self.i), Some(Tok::Minus));
                        if neg {
                            self.i += 1;
                        }
                        let Some(Tok::Int(v)) = self.t.get(self.i) else {
                            return None;
                        };
                        let v = i16::try_from(*v).ok()?;
                        self.i += 1;
                        HandlerCode::SqlCode(if neg { -v } else { v })
                    } else if self.kw("SQLSTATE") {
                        let Some(Tok::Str(s)) = self.t.get(self.i) else {
                            return None;
                        };
                        let s = s.clone();
                        self.i += 1;
                        HandlerCode::SqlState(s)
                    } else {
                        return None;
                    };
                    codes.push(code);
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                        continue;
                    }
                    break;
                }
                if !self.kw("DO") {
                    return None;
                }
                // a handler's body may itself carry handlers - the
                // nested block emits blr_block again, WITH its own
                // error-handler section (probed)
                let h = self.trig_stmt()?;
                handlers.push((codes, h));
            }
            if !self.kw("END") {
                return None;
            }
            // NO `;` after a block's END: a block is a compound statement,
            // which takes no terminator - `BEGIN BEGIN EXIT; END; END` is
            // the engine's -104 Token unknown at that `;` (measured on 2196
            // for procedures, triggers and EXECUTE BLOCK alike, after a
            // plain block, a WHILE's and an IF's). This accepted it.
            if matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            return Some(if handlers.is_empty() {
                TrigStmt::Block(stmts)
            } else {
                TrigStmt::HandledBlock(stmts, handlers)
            });
        }
        if self.kw("IF") {
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            let cond = self.bool_or()?;
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            if !self.kw("THEN") {
                return None;
            }
            let then = Box::new(self.trig_stmt()?);
            let els = if self.kw("ELSE") {
                Some(Box::new(self.trig_stmt()?))
            } else {
                None
            };
            return Some(TrigStmt::If(cond, then, els));
        }
        if let Some(n) = self.proc {
            if self.kw("SUSPEND") {
                if n == 0 || !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None; // SUSPEND without outputs: unprobed
                }
                self.i += 1;
                self.saw_suspend = true;
                return Some(TrigStmt::Suspend(n));
            }
            // RETURN <expr>; - function bodies only: assign the
            // unnamed return slot, send it, leave the wrapper label
            if self.in_func && self.kw("RETURN") {
                let v = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None;
                }
                self.i += 1;
                return Some(TrigStmt::Return(v));
            }
        }
        // (FOR) SELECT works in BOTH body kinds - a trigger's FOR
        // stream takes the next context after OLD/NEW (probed)
        if self.kw("FOR") {
            // FOR EXECUTE STATEMENT '<sql>' INTO ... DO <stmt> - the
            // loop form: flag 0, the DO statement, then the vars
            if self.kw("EXECUTE") {
                if !self.kw("STATEMENT") {
                    return None;
                }
                let (sql, ins) = self.exec_stmt_sql_arg()?;
                let (data_src, user, pwd, role) = self.exec_stmt_mods()?;
                let full = !ins.is_empty()
                    || data_src.is_some()
                    || user.is_some()
                    || pwd.is_some()
                    || role.is_some();
                if !self.kw("INTO") {
                    return None;
                }
                let mut vars = Vec::new();
                loop {
                    // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
                    // `RETURNING_VALUES N` are the engine's too (measured on 2196)
                    if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                        self.i += 1;
                    }
                    let Some(Tok::Ident(v)) = self.t.get(self.i) else {
                        return None;
                    };
                    let vi =
                        self.local_vars.iter().position(|n| n == v)? as u16;
                    vars.push(vi);
                    self.i += 1;
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                    } else {
                        break;
                    }
                }
                let label = self.next_label;
                self.next_label += 1;
                if !self.kw("DO") {
                    return None;
                }
                self.loop_labels.push((self.pending_loop_label.take(), label));
                let body_opt = self.trig_stmt();
                self.loop_labels.pop();
                let body = Box::new(body_opt?);
                if full {
                    return Some(TrigStmt::ExecStmtFull {
                        sql,
                        ins,
                        vars,
                        data_src,
                        user,
                        pwd,
                        role,
                        run: Some((label, body)),
                    });
                }
                return Some(TrigStmt::ExecInto {
                    sql,
                    vars,
                    run: Some((label, body)),
                });
            }
            // FOR WITH cte AS (...) SELECT ... - the cte expands as
            // a derived table at its FROM reference (probed)
            if self.kw("WITH") {
                if self.kw("RECURSIVE") {
                    return self.recursive_for();
                }
                self.parse_cte()?;
            }
            if !self.kw("SELECT") {
                return None;
            }
            let r = self.select_stmt(true);
            let ctes = std::mem::take(&mut self.ctes);
            if ctes.iter().any(|(.., used)| !used) {
                return None; // an unreferenced cte: unprobed
            }
            return r;
        }
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "SELECT") {
            self.i += 1;
            return self.select_stmt(false);
        }
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "WITH") {
            self.i += 1;
            self.parse_cte()?;
            if !self.kw("SELECT") {
                return None;
            }
            let r = self.select_stmt(false);
            let ctes = std::mem::take(&mut self.ctes);
            if ctes.iter().any(|(.., used)| !used) {
                return None;
            }
            return r;
        }
        if self.kw("EXECUTE") {
            // EXECUTE STATEMENT '<literal sql>' [INTO :v, ...]; -
            // expression sql, USING, external data sources: unprobed
            if self.kw("STATEMENT") {
                // sql: a bare literal or the parenthesized head with
                // parameters; then the optional modifiers - either
                // of which forces the FULL blr_exec_stmt form
                let (sql, ins) = self.exec_stmt_sql_arg()?;
                let (data_src, user, pwd, role) = self.exec_stmt_mods()?;
                let full = !ins.is_empty()
                    || data_src.is_some()
                    || user.is_some()
                    || pwd.is_some()
                    || role.is_some();
                let mut vars = Vec::new();
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    if !self.kw("INTO") {
                        return None;
                    }
                    loop {
                        // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
                        // `RETURNING_VALUES N` are the engine's too (measured on 2196)
                        if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                            self.i += 1;
                        }
                        let Some(Tok::Ident(v)) = self.t.get(self.i) else {
                            return None;
                        };
                        let vi = self
                            .local_vars
                            .iter()
                            .position(|n| n == v)?
                            as u16;
                        vars.push(vi);
                        self.i += 1;
                        if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                            self.i += 1;
                        } else {
                            break;
                        }
                    }
                }
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None;
                }
                self.i += 1;
                if full {
                    return Some(TrigStmt::ExecStmtFull {
                        sql,
                        ins,
                        vars,
                        data_src,
                        user,
                        pwd,
                        role,
                        run: None,
                    });
                }
                return Some(if vars.is_empty() {
                    TrigStmt::ExecSql(sql)
                } else {
                    TrigStmt::ExecInto {
                        sql,
                        vars,
                        run: None,
                    }
                });
            }
            if !self.kw("PROCEDURE") {
                return None;
            }
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let mut name = name.clone();
            self.i += 1;
            // EXECUTE PROCEDURE PKG.NAME - the packaged form
            let mut pkg: Option<String> = None;
            if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                self.i += 1;
                let Some(Tok::Ident(pn)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(pn) {
                    return None;
                }
                pkg = Some(name);
                name = pn.clone();
                self.i += 1;
            }
            let mut ins = Vec::new();
            if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                self.i += 1;
                loop {
                    ins.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
            } else if !matches!(self.t.get(self.i), Some(Tok::Semi) | None)
                && !matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "RETURNING_VALUES")
            {
                // the PAREN-LESS argument list `EXECUTE PROCEDURE p :a, :b`
                // (the employee sample's DEPT_BUDGET): the same BLR as
                // the parenthesised spelling
                loop {
                    ins.push(self.val()?);
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                    } else {
                        break;
                    }
                }
            }
            let mut outs = Vec::new();
            if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "RETURNING_VALUES")
            {
                self.i += 1;
                loop {
                    // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
                    // `RETURNING_VALUES N` are the engine's too (measured on 2196)
                    if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                        self.i += 1;
                    }
                    let Some(Tok::Ident(v)) = self.t.get(self.i) else {
                        return None;
                    };
                    let vi = self.local_vars.iter().position(|n| n == v)?;
                    outs.push(vi as u16);
                    self.i += 1;
                    if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        self.i += 1;
                    } else {
                        break;
                    }
                }
            }
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            if let Some(pkg) = pkg {
                return Some(TrigStmt::PkgCall(pkg, name, ins, outs));
            }
            // a DECLAREd sub-procedure takes the invoke_procedure
            // verb, count-checked against its declaration
            if let Some((ni, no)) = self
                .sub_procs
                .iter()
                .find(|(n, ..)| n == &name)
                .map(|(_, i, o)| (*i, *o))
            {
                if ins.len() != ni || outs.len() != no {
                    return None;
                }
                return Some(TrigStmt::SubCall(name, ins, outs));
            }
            return Some(TrigStmt::ExecProc(name, ins, outs));
        }
        if self.kw("EXCEPTION") {
            // a bare `EXCEPTION;` re-raises the caught exception
            if matches!(self.t.get(self.i), Some(Tok::Semi)) {
                self.i += 1;
                return Some(TrigStmt::ExceptionReraise);
            }
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let name = name.clone();
            self.i += 1;
            // an optional literal message override: EXCEPTION E_NEG 'text'.
            // A concatenation/expression message or a USING clause leaves a
            // non-semicolon token here and refuses (literal only).
            let message = if let Some(Tok::Str(m)) = self.t.get(self.i) {
                let m = m.clone();
                self.i += 1;
                Some(m)
            } else {
                None
            };
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::ExceptionRaise(name, message));
        }
        if self.kw("EXIT") {
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::Exit);
        }
        // bare LEAVE / CONTINUE (the innermost loop). A following
        // identifier is a LABELLED form this surface does not take, and
        // either outside a loop has no label to target - both refuse.
        if self.kw("LEAVE") {
            let l = self.loop_target()?;
            return Some(TrigStmt::LeaveLoop(l));
        }
        if self.kw("CONTINUE") {
            let l = self.loop_target()?;
            return Some(TrigStmt::ContinueLoop(l));
        }
        if self.kw("IN") {
            if !(self.kw("AUTONOMOUS") && self.kw("TRANSACTION") && self.kw("DO")) {
                return None;
            }
            return Some(TrigStmt::AutoTrans(Box::new(self.trig_stmt()?)));
        }
        if self.kw("OPEN") || matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "CLOSE")
        {
            // (the OPEN kw was consumed above; CLOSE is consumed here)
            let sub = if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "CLOSE")
            {
                self.i += 1;
                1u8
            } else {
                0u8
            };
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            let num = self.cursors.iter().position(|n| n == name)? as u16;
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::CursorOp(sub, num));
        }
        if self.kw("FETCH") {
            // optional direction + FROM: the directed forms take the
            // SCROLL fetch sub-verb (3) with a direction byte and an
            // offset value - blr_null unless ABSOLUTE/RELATIVE; only
            // NEXT is legal on an unscrolled cursor (probed)
            let dir: Option<(u8, Option<i32>)> = if self.kw("NEXT") {
                Some((0, None))
            } else if self.kw("PRIOR") {
                Some((1, None))
            } else if self.kw("FIRST") {
                Some((2, None))
            } else if self.kw("LAST") {
                Some((3, None))
            } else if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "ABSOLUTE" || w == "RELATIVE")
            {
                let Some(Tok::Ident(w)) = self.t.get(self.i) else {
                    return None;
                };
                let code = if w == "ABSOLUTE" { 4 } else { 5 };
                self.i += 1;
                let neg = matches!(self.t.get(self.i), Some(Tok::Minus));
                if neg {
                    self.i += 1;
                }
                let Some(Tok::Int(v)) = self.t.get(self.i) else {
                    return None;
                };
                let v = i32::try_from(*v).ok()?;
                self.i += 1;
                Some((code, Some(if neg { -v } else { v })))
            } else {
                None
            };
            if dir.is_some() && !self.kw("FROM") {
                return None;
            }
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            let num = self.cursors.iter().position(|n| n == name)? as u16;
            let name = name.clone();
            self.i += 1;
            if let Some((code, _)) = &dir {
                let decl =
                    self.cursor_decls.iter().find(|d| d.name == name)?;
                if *code != 0 && !decl.scroll {
                    return None;
                }
            }
            // an INTO-less FETCH (positioning a cursor for WHERE
            // CURRENT OF) carries an empty begin/end (probed)
            if matches!(self.t.get(self.i), Some(Tok::Semi)) {
                self.i += 1;
                return Some(match dir {
                    Some((code, off)) => {
                        TrigStmt::CursorFetchDir(num, code, off, Vec::new())
                    }
                    None => TrigStmt::CursorFetch(num, Vec::new()),
                });
            }
            if !self.kw("INTO") {
                return None;
            }
            let mut vars = Vec::new();
            loop {
                // the colon is OPTIONAL on a target variable: `INTO N`, `FETCH C INTO N`,
                // `RETURNING_VALUES N` are the engine's too (measured on 2196)
                if matches!(self.t.get(self.i), Some(Tok::Colon)) {
                    self.i += 1;
                }
                let Some(Tok::Ident(v)) = self.t.get(self.i) else {
                    return None;
                };
                let vi = self.local_vars.iter().position(|n| n == v)? as u16;
                vars.push(vi);
                self.i += 1;
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            // the fetch's assignments read the cursor's OUTPUT
            // columns - fields at the cursor's context, or fid slots
            // on an aggregate cursor's map
            let decl = self
                .cursor_decls
                .iter()
                .find(|d| d.name == name)?;
            if vars.len() != decl.outs.len() {
                return None;
            }
            let assigns = decl
                .outs
                .iter()
                .zip(&vars)
                .map(|(o, vi)| (o.clone(), *vi))
                .collect();
            return Some(match dir {
                Some((code, off)) => {
                    TrigStmt::CursorFetchDir(num, code, off, assigns)
                }
                None => TrigStmt::CursorFetch(num, assigns),
            });
        }
        if self.kw("POST_EVENT") {
            let v = self.val()?;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::PostEvent(v));
        }
        if self.kw("WHILE") {
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            let cond = self.bool_or()?;
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            if !self.kw("DO") {
                return None;
            }
            let label = self.next_label;
            self.next_label += 1;
            self.loop_labels.push((self.pending_loop_label.take(), label));
            let body = match self.trig_stmt() {
                Some(b) => Box::new(b),
                None => {
                    self.loop_labels.pop();
                    return None;
                }
            };
            self.loop_labels.pop();
            return Some(TrigStmt::While(label, cond, body));
        }
        // <var> = <value>; - a local-variable assignment
        if let Some(Tok::Ident(name)) = self.t.get(self.i) {
            if let Some(vi) = self.local_vars.iter().position(|n| n == name) {
                if matches!(self.t.get(self.i + 1), Some(Tok::Cmp(CmpOp::Eql))) {
                    self.i += 2;
                    let src = self.val()?;
                    if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                        return None;
                    }
                    self.i += 1;
                    return Some(TrigStmt::Assign(src, Val::LocalVar(vi as u16)));
                }
            }
        }
        if self.kw("INSERT") {
            // INSERT INTO rel (cols) VALUES (vals); - the column
            // list is REQUIRED (without it the mapping needs the
            // catalog); values may read OLD/NEW but not the target
            if !self.kw("INTO") {
                return None;
            }
            let Some(Tok::Ident(rel)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(rel) {
                return None;
            }
            let rel = rel.clone();
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            let mut cols = Vec::new();
            loop {
                let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(c) {
                    return None;
                }
                cols.push(c.clone());
                self.i += 1;
                match self.t.get(self.i)? {
                    Tok::Comma => self.i += 1,
                    Tok::RParen => {
                        self.i += 1;
                        break;
                    }
                    _ => return None,
                }
            }
            // INSERT ... SELECT: a marks-stamped FOR loop over the
            // source rse - the source stream numbers FIRST (probed)
            if self.kw("SELECT") {
                // two-phase: the source items are FULL value
                // expressions at the source stream (probed) - scan
                // to FROM, parse the stream, rewind for the items
                let list_start = self.i;
                let mut depth = 0i32;
                let list_end = loop {
                    match self.t.get(self.i)? {
                        Tok::LParen => {
                            depth += 1;
                            self.i += 1;
                        }
                        Tok::RParen => {
                            depth -= 1;
                            self.i += 1;
                        }
                        Tok::Ident(w) if w == "FROM" && depth == 0 => {
                            break self.i
                        }
                        _ => self.i += 1,
                    }
                };
                self.i = list_end + 1;
                let src = self.stream_item()?;
                if src.derived.is_some() {
                    return None;
                }
                self.streams.push(src.clone());
                let src_idx = self.streams.len() - 1;
                let src_ctx = src_idx as u8 + self.base;
                let after_from = self.i;
                self.i = list_start;
                let saved = self.sub.replace(src_idx);
                let mut vals = Vec::new();
                loop {
                    vals.push(self.val()?);
                    if self.i == list_end {
                        break;
                    }
                    if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                        return None;
                    }
                    self.i += 1;
                }
                if vals.len() != cols.len() {
                    return None;
                }
                self.i = after_from;
                let wher = if self.kw("WHERE") {
                    Some(self.bool_or()?)
                } else {
                    None
                };
                self.sub = saved;
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None;
                }
                self.i += 1;
                let tgt = Stream {
                    name: rel,
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
                    cur: None,
                    proc_args: None,
                };
                self.streams.push(tgt.clone());
                let tgt_ctx = (self.streams.len() - 1) as u8 + self.base;
                return Some(TrigStmt::InsertSel {
                    src,
                    src_ctx,
                    tgt,
                    tgt_ctx,
                    cols,
                    vals,
                    wher,
                });
            }
            if !self.kw("VALUES") || !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            self.i += 1;
            let mut vals = Vec::new();
            loop {
                vals.push(self.val()?);
                match self.t.get(self.i)? {
                    Tok::Comma => self.i += 1,
                    Tok::RParen => {
                        self.i += 1;
                        break;
                    }
                    _ => return None,
                }
            }
            if vals.len() != cols.len() {
                return None;
            }
            let ret = self.returning_into()?;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            let st = Stream {
                name: rel,
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            };
            self.streams.push(st.clone());
            let ctx = (self.streams.len() - 1) as u8 + self.base;
            return Some(TrigStmt::Insert(
                st,
                ctx,
                cols.into_iter().zip(vals).collect(),
                ret,
            ));
        }
        if self.kw("DELETE") {
            // DELETE FROM rel [WHERE ...]; - inside the WHERE a bare
            // name binds to the DML's own stream (innermost scope)
            if !self.kw("FROM") {
                return None;
            }
            let st = self.stream_item()?;
            if st.derived.is_some() {
                return None;
            }
            // WHERE CURRENT OF <cursor>: blr_erase at the cursor's
            // OWN context - no fresh stream slot (probed; an aliased
            // positioned delete is unprobed and refuses below)
            if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "WHERE")
                && matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "CURRENT")
            {
                self.i += 2;
                if !self.kw("OF") {
                    return None;
                }
                let Some(Tok::Ident(cur)) = self.t.get(self.i) else {
                    return None;
                };
                // the erased table must be the cursor's (and a plain,
                // non-aggregate cursor - the engine refuses the rest)
                let (ctx, ctbl) = self.find_pos_cursor(cur)?;
                if ctbl != st.name || st.alias.is_some() {
                    return None;
                }
                self.i += 1;
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None;
                }
                self.i += 1;
                return Some(TrigStmt::PosDelete(ctx));
            }
            self.streams.push(st.clone());
            let idx = self.streams.len() - 1;
            let ctx = idx as u8 + self.base;
            let saved = self.sub.replace(idx);
            let wher = if self.kw("WHERE") {
                Some(self.bool_or()?)
            } else {
                None
            };
            self.sub = saved;
            let ret = self.returning_into()?;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::Delete(st, ctx, wher, ret));
        }
        if self.kw("MERGE") {
            // MERGE INTO tgt [alias] USING src [alias] ON <bool>
            // WHEN [NOT] MATCHED THEN ... - one MATCHED branch
            // (UPDATE SET / DELETE) and one NOT MATCHED (INSERT) at
            // most; AND-qualified branches, sub-selects as source
            // and RETURNING are unprobed and refuse
            if !self.kw("INTO") {
                return None;
            }
            let named = |p: &mut P| -> Option<Stream> {
                let Some(Tok::Ident(n)) = p.t.get(p.i) else {
                    return None;
                };
                if is_keyword(n) {
                    return None;
                }
                let n = n.clone();
                p.i += 1;
                let alias = match p.t.get(p.i) {
                    Some(Tok::Ident(a)) if !is_keyword(a) => {
                        let a = a.clone();
                        p.i += 1;
                        Some(a)
                    }
                    _ => None,
                };
                Some(Stream {
                    name: n,
                    alias,
                    derived: None,
                    sub: p.in_sub,
                    cur: None,
                    proc_args: None,
                })
            };
            let tgt = named(self)?;
            if !self.kw("USING") {
                return None;
            }
            let src = named(self)?;
            // contexts: the SOURCE stream numbers first (probed:
            // source 0, target 1)
            self.streams.push(src.clone());
            let src_idx = self.streams.len() - 1;
            let src_ctx = src_idx as u8 + self.base;
            self.streams.push(tgt.clone());
            let tgt_idx = self.streams.len() - 1;
            let tgt_ctx = tgt_idx as u8 + self.base;
            if !self.kw("ON") {
                return None;
            }
            self.merge_scope = Some((src_idx, tgt_idx + 1));
            let on = self.bool_or()?;
            // branches in SQL order; an UNCONDITIONAL branch must be
            // its kind's LAST (later ones would be unreachable - and
            // the chain has one else slot to fill)
            let mut mat_raw: Vec<(Option<Bool>, MatRaw)> = Vec::new();
            let mut nm_raw: Vec<(Option<Bool>, Vec<String>, Vec<Val>)> =
                Vec::new();
            enum MatRaw {
                Upd(Vec<(String, Val)>),
                Del,
            }
            while self.kw("WHEN") {
                if self.kw("NOT") {
                    if !self.kw("MATCHED") {
                        return None;
                    }
                    if matches!(nm_raw.last(), Some((None, ..))) {
                        return None; // after an unconditional branch
                    }
                    let cond = if self.kw("AND") {
                        Some(self.bool_or()?)
                    } else {
                        None
                    };
                    if !(self.kw("THEN") && self.kw("INSERT"))
                        || !matches!(self.t.get(self.i), Some(Tok::LParen))
                    {
                        return None;
                    }
                    self.i += 1;
                    let mut cols = Vec::new();
                    loop {
                        let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                            return None;
                        };
                        if is_keyword(c) {
                            return None;
                        }
                        cols.push(c.clone());
                        self.i += 1;
                        match self.t.get(self.i)? {
                            Tok::Comma => self.i += 1,
                            Tok::RParen => {
                                self.i += 1;
                                break;
                            }
                            _ => return None,
                        }
                    }
                    if !self.kw("VALUES")
                        || !matches!(self.t.get(self.i), Some(Tok::LParen))
                    {
                        return None;
                    }
                    self.i += 1;
                    let mut vals = Vec::new();
                    loop {
                        vals.push(self.val()?);
                        match self.t.get(self.i)? {
                            Tok::Comma => self.i += 1,
                            Tok::RParen => {
                                self.i += 1;
                                break;
                            }
                            _ => return None,
                        }
                    }
                    if vals.len() != cols.len() {
                        return None;
                    }
                    nm_raw.push((cond, cols, vals));
                } else {
                    if !self.kw("MATCHED") {
                        return None;
                    }
                    if matches!(mat_raw.last(), Some((None, _))) {
                        return None; // after an unconditional branch
                    }
                    let cond = if self.kw("AND") {
                        Some(self.bool_or()?)
                    } else {
                        None
                    };
                    if !self.kw("THEN") {
                        return None;
                    }
                    if self.kw("UPDATE") {
                        if !self.kw("SET") {
                            return None;
                        }
                        let mut sets = Vec::new();
                        loop {
                            let Some(Tok::Ident(col)) = self.t.get(self.i)
                            else {
                                return None;
                            };
                            if is_keyword(col) {
                                return None;
                            }
                            let col = col.clone();
                            self.i += 1;
                            if !matches!(
                                self.t.get(self.i),
                                Some(Tok::Cmp(CmpOp::Eql))
                            ) {
                                return None;
                            }
                            self.i += 1;
                            sets.push((col, self.val()?));
                            if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                                self.i += 1;
                            } else {
                                break;
                            }
                        }
                        mat_raw.push((cond, MatRaw::Upd(sets)));
                    } else if self.kw("DELETE") {
                        mat_raw.push((cond, MatRaw::Del));
                    } else {
                        return None;
                    }
                }
            }
            self.merge_scope = None;
            if mat_raw.is_empty() && nm_raw.is_empty() {
                return None;
            }
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            // branch contexts allocate BY KIND, branch order within:
            // every matched UPDATE claims a new-record slot, then
            // every INSERT its store slot - independent of the SQL's
            // matched/not-matched interleaving (probed)
            let matched: Vec<(Option<Bool>, MergeAct)> = mat_raw
                .into_iter()
                .map(|(c, r)| {
                    (
                        c,
                        match r {
                            MatRaw::Upd(sets) => {
                                self.streams.push(Stream {
                                    name: String::new(),
                                    alias: None,
                                    derived: None,
                                    sub: self.in_sub,
                                    cur: None,
                                    proc_args: None,
                                });
                                MergeAct::Upd(
                                    (self.streams.len() - 1) as u8
                                        + self.base,
                                    sets,
                                )
                            }
                            MatRaw::Del => MergeAct::Del,
                        },
                    )
                })
                .collect();
            let notmatched: Vec<(Option<Bool>, u8, Vec<String>, Vec<Val>)> =
                nm_raw
                    .into_iter()
                    .map(|(c, cols, vals)| {
                        self.streams.push(Stream {
                            name: String::new(),
                            alias: None,
                            derived: None,
                            sub: self.in_sub,
                            cur: None,
                            proc_args: None,
                        });
                        (
                            c,
                            (self.streams.len() - 1) as u8 + self.base,
                            cols,
                            vals,
                        )
                    })
                    .collect();
            return Some(TrigStmt::Merge {
                src,
                src_ctx,
                tgt,
                tgt_ctx,
                on,
                matched,
                notmatched,
            });
        }
        if self.kw("UPDATE") {
            if self.kw("OR") {
                // UPDATE OR INSERT INTO rel (cols) VALUES (vals)
                // MATCHING (mcol); - contexts allocated store,
                // modify-new, rse-org IN THAT ORDER (probed); the
                // MATCHING clause is REQUIRED (default matching needs
                // the primary key - the catalog)
                if !(self.kw("INSERT") && self.kw("INTO")) {
                    return None;
                }
                let Some(Tok::Ident(rel)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(rel) {
                    return None;
                }
                let rel = rel.clone();
                self.i += 1;
                if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                    return None;
                }
                self.i += 1;
                let mut cols = Vec::new();
                loop {
                    let Some(Tok::Ident(c)) = self.t.get(self.i) else {
                        return None;
                    };
                    if is_keyword(c) {
                        return None;
                    }
                    cols.push(c.clone());
                    self.i += 1;
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
                if !self.kw("VALUES") || !matches!(self.t.get(self.i), Some(Tok::LParen))
                {
                    return None;
                }
                self.i += 1;
                let mut vals = Vec::new();
                loop {
                    vals.push(self.val()?);
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
                if vals.len() != cols.len() {
                    return None;
                }
                if !self.kw("MATCHING") || !matches!(self.t.get(self.i), Some(Tok::LParen))
                {
                    return None;
                }
                self.i += 1;
                let mut matching: Vec<(String, usize)> = Vec::new();
                loop {
                    let Some(Tok::Ident(mcol)) = self.t.get(self.i) else {
                        return None;
                    };
                    let mcol = mcol.clone();
                    self.i += 1;
                    let midx = cols.iter().position(|c| c == &mcol)?;
                    matching.push((mcol, midx));
                    match self.t.get(self.i)? {
                        Tok::Comma => self.i += 1,
                        Tok::RParen => {
                            self.i += 1;
                            break;
                        }
                        _ => return None,
                    }
                }
                if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                    return None;
                }
                self.i += 1;
                let st = Stream {
                    name: rel,
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
                    cur: None,
                    proc_args: None,
                };
                // contexts: store, modify-new, rse-org - in order
                let base = self.base;
                self.streams.push(st.clone());
                let store_ctx = (self.streams.len() - 1) as u8 + base;
                self.streams.push(Stream {
                    name: String::new(),
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
                    cur: None,
                    proc_args: None,
                });
                let new_ctx = (self.streams.len() - 1) as u8 + base;
                self.streams.push(Stream {
                    name: String::new(),
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
                    cur: None,
                    proc_args: None,
                });
                let org_ctx = (self.streams.len() - 1) as u8 + base;
                return Some(TrigStmt::UpdateOrInsert {
                    rel: st,
                    store_ctx,
                    new_ctx,
                    org_ctx,
                    cols,
                    vals,
                    matching,
                });
            }
            // UPDATE rel SET col = v [, ...] [WHERE ...]; - the NEW
            // record's context is allocated BEFORE the rse stream's
            // (probed: modify 3,2 with the rse at 3); SET sources and
            // the WHERE read the ORG stream
            let Some(Tok::Ident(rel)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(rel) {
                return None;
            }
            let rel = rel.clone();
            self.i += 1;
            // an optional stream alias (SET is a keyword, so a bare
            // following ident is the alias)
            let rel_alias = match self.t.get(self.i) {
                Some(Tok::Ident(a)) if !is_keyword(a) => {
                    let a = a.clone();
                    self.i += 1;
                    Some(a)
                }
                _ => None,
            };
            // UPDATE ... WHERE CURRENT OF: the modify goes from the
            // cursor's context to ONE fresh slot (the new record) -
            // scan ahead for the positioned tail before allocating
            let mut j = self.i;
            let mut positioned = false;
            while let Some(t) = self.t.get(j) {
                if matches!(t, Tok::Semi) {
                    break;
                }
                if matches!(t, Tok::Ident(w) if w == "WHERE")
                    && matches!(self.t.get(j + 1), Some(Tok::Ident(w)) if w == "CURRENT")
                    && matches!(self.t.get(j + 2), Some(Tok::Ident(w)) if w == "OF")
                {
                    positioned = true;
                    break;
                }
                j += 1;
            }
            if positioned {
                // an aliased positioned update: unprobed
                if rel_alias.is_some() {
                    return None;
                }
                return self.positioned_update(rel);
            }
            // the new-record placeholder is unnameable: SET targets
            // are built directly against its context
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            });
            let new_ctx = (self.streams.len() - 1) as u8 + self.base;
            let st = Stream {
                name: rel,
                alias: rel_alias,
                derived: None,
                sub: self.in_sub,
                cur: None,
                proc_args: None,
            };
            self.streams.push(st.clone());
            let org_idx = self.streams.len() - 1;
            let org_ctx = org_idx as u8 + self.base;
            if !self.kw("SET") {
                return None;
            }
            let saved = self.sub.replace(org_idx);
            let mut sets = Vec::new();
            loop {
                let Some(Tok::Ident(col)) = self.t.get(self.i) else {
                    return None;
                };
                if is_keyword(col) {
                    return None;
                }
                let target = Val::Field(new_ctx, col.clone());
                self.i += 1;
                if !matches!(self.t.get(self.i), Some(Tok::Cmp(CmpOp::Eql))) {
                    return None;
                }
                self.i += 1;
                sets.push((target, self.val()?));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
            let wher = if self.kw("WHERE") {
                Some(self.bool_or()?)
            } else {
                None
            };
            self.sub = saved;
            let ret = self.returning_into()?;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::Update(st, org_ctx, new_ctx, sets, wher, ret));
        }
        // NEW.col = <value>;
        let Some(Tok::Ident(q)) = self.t.get(self.i) else {
            return None;
        };
        if q != "NEW" {
            return None; // OLD targets are read-only in the engine
        }
        self.i += 1;
        if !matches!(self.t.get(self.i), Some(Tok::Dot)) {
            return None;
        }
        self.i += 1;
        let Some(Tok::Ident(col)) = self.t.get(self.i) else {
            return None;
        };
        let col = col.clone();
        self.i += 1;
        let target = self.field(Some("NEW"), &col)?;
        if !matches!(self.t.get(self.i), Some(Tok::Cmp(CmpOp::Eql))) {
            return None;
        }
        self.i += 1;
        let src = self.val()?;
        if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
            return None;
        }
        self.i += 1;
        Some(TrigStmt::Assign(src, target))
    }
}

/// Compile a column DEFAULT clause to the BLR the engine stores in
/// `RDB$RELATION_FIELDS.RDB$DEFAULT_VALUE` - oracle number FOUR, and
/// the smallest wrapper possible: blr_version5, the value, blr_eoc.
/// The engine's own grammar restricts defaults to literals, NULL and
/// the niladic context functions - anything else refuses here too.
pub fn compile_default(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: Vec::new(),
        base: 0,
        outer: Some(0),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !p.kw("DEFAULT") {
        return None;
    }
    let v = p.val()?;
    if p.i != p.t.len() {
        return None;
    }
    if !matches!(
        v,
        Val::Int(_)
            | Val::Int64(_)
            | Val::Dec(..)
            | Val::Str(_)
            | Val::Null
            | Val::CurrentDate
            | Val::CurrentTime
            | Val::CurrentTimestamp
    ) {
        return None; // the engine's DEFAULT grammar is this narrow
    }
    let mut out = vec![blr::VERSION5];
    emit_val(&mut out, &v);
    out.push(blr::EOC);
    Some(out)
}

/// `compile_default` as uppercase hex.
pub fn compile_default_hex(sql: &str) -> Option<String> {
    Some(
        compile_default(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// Compile a COMPUTED BY clause to the BLR the engine stores in
/// `RDB$FIELDS.RDB$COMPUTED_BLR`: blr_version5, the expression,
/// blr_eoc - with the table's columns as bare fields at CONTEXT 0
/// (probed). The whole converted expression surface rides inside
/// (arithmetic, functions, cast-wrapped CASE).
pub fn compile_computed(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        // one anonymous stream: the table itself, context 0 - bare
        // names bind to it, qualified names refuse
        streams: vec![Stream {
            name: String::new(),
            alias: None,
            derived: None,
            sub: false,
            cur: None,
            proc_args: None,
        }],
        base: 0,
        outer: Some(1),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !(p.kw("COMPUTED") && p.kw("BY")) {
        return None;
    }
    if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
        return None;
    }
    p.i += 1;
    let v = p.val()?;
    if !matches!(p.t.get(p.i), Some(Tok::RParen)) {
        return None;
    }
    p.i += 1;
    if p.i != p.t.len() {
        return None;
    }
    let mut out = vec![blr::VERSION5];
    emit_val(&mut out, &v);
    out.push(blr::EOC);
    Some(out)
}

/// Compile a PARTIAL index's condition - `WHERE <boolean>` - to the BLR
/// the engine stores in `RDB$INDICES.RDB$CONDITION_BLR`: blr_version5,
/// the boolean as written (not negated, unlike a CHECK's trigger),
/// blr_eoc, with the table's columns as bare fields at CONTEXT 0 - the
/// shape [compile_computed] gives an expression index (measured on 2196:
/// `WHERE S = 'active'` stores 05 2F 17 00 01 'S' 15 0F 00 00 06 00
/// 'active' 4C).
pub fn compile_index_condition(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        // one anonymous stream: the table itself, context 0 - bare
        // names bind to it, qualified names refuse
        streams: vec![Stream {
            name: String::new(),
            alias: None,
            derived: None,
            sub: false,
            cur: None,
            proc_args: None,
        }],
        base: 0,
        outer: Some(1),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !p.kw("WHERE") {
        return None;
    }
    let cond = p.bool_or()?;
    if p.i != p.t.len() {
        return None;
    }
    let mut out = vec![blr::VERSION5];
    emit_bool(&mut out, &cond);
    out.push(blr::EOC);
    Some(out)
}

/// Compile a CHECK constraint to the BLR the engine stores as its
/// system trigger (`RDB$TRIGGERS`, types 1 and 3 - byte-identical):
/// blr_begin, blr_if over the NEGATED condition whose then-branch is
/// blr_abort with blr_gds_code 'check_constraint', a bare blr_end in
/// the else slot, blr_end, blr_eoc. Fields sit at CONTEXT 1 (the NEW
/// record). The negation reuses the same fold as NOT (probed:
/// CHECK (A < B) stores blr_geq).
pub fn compile_check(sql: &str) -> Option<Vec<u8>> {
    compile_check_for(sql, "", &[])
}

/// [compile_check] for a table whose NAME and COLUMN TYPES are known:
/// `TABLE.COL` resolves to the NEW context (the engine's check trigger
/// reads context 1), and a text `IN` list casts to the column's type.
pub fn compile_check_for(sql: &str, table: &str, cols: &[(String, TypeSpec)]) -> Option<Vec<u8>> {
    TYPING.with(|t| {
        *t.borrow_mut() = Typing {
            value: None,
            cols: cols.iter().map(|(n, ts)| (n.clone(), ts.dsc())).collect(),
        }
    });
    let r = compile_check_inner(sql, table);
    TYPING.with(|t| *t.borrow_mut() = Typing::default());
    r
}

fn compile_check_inner(sql: &str, table: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        // two anonymous slots so bare fields bind to context 1
        streams: vec![
            Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: false,
                cur: None,
                proc_args: None,
            },
            Stream {
                name: table.to_ascii_uppercase(),
                alias: None,
                derived: None,
                sub: false,
                cur: None,
                proc_args: None,
            },
        ],
        base: 0,
        outer: Some(0),
        sub: Some(1),
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !p.kw("CHECK") {
        return None;
    }
    if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
        return None;
    }
    p.i += 1;
    let cond = p.bool_or()?;
    if !matches!(p.t.get(p.i), Some(Tok::RParen)) {
        return None;
    }
    p.i += 1;
    if p.i != p.t.len() {
        return None;
    }
    let mut out = vec![blr::VERSION5, blr::BEGIN, blr::IF];
    emit_bool(&mut out, &negate(cond));
    out.push(blr::BEGIN);
    out.push(blr::ABORT);
    out.push(0); // blr_gds_code
    let msg = b"check_constraint";
    out.push(msg.len() as u8);
    out.extend_from_slice(msg);
    out.push(blr::END);
    out.push(blr::END); // the missing else
    out.push(blr::END);
    out.push(blr::EOC);
    Some(out)
}

/// `compile_check` as uppercase hex.
pub fn compile_check_hex(sql: &str) -> Option<String> {
    Some(
        compile_check(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// Compile a DOMAIN's CHECK to the BLR the engine stores in
/// `RDB$FIELDS.RDB$VALIDATION_BLR` - the SEVENTH catalog store. The
/// shape differs from a table CHECK's system trigger: the RAW boolean
/// (NOT negated, no abort wrapper) between blr_version5 and blr_eoc,
/// with VALUE compiling to blr_fid(0, 0) (probed).
/// A column's or a domain VALUE's declared type, as the caller knows it
/// from RDB$FIELDS terms: the BLR type code (blr_text 14, blr_varying
/// 37, blr_short 7, blr_long 8, blr_int64 16, blr_double 27, the
/// date/time codes), the byte length and the scale.
#[derive(Clone, Copy, Debug)]
pub struct TypeSpec {
    pub blr_type: u8,
    pub length: u16,
    pub scale: i8,
    /// a text column's set when the caller knows it (a catalog column:
    /// the length is then its BYTES); None keeps the database default a
    /// bare declaration takes
    pub charset: Option<u16>,
}

impl TypeSpec {
    fn dsc(&self) -> Dsc {
        match (self.blr_type, self.charset) {
            (14, Some(cs)) => Dsc::TextCs(self.length / charset_bpc(cs), cs),
            (37, Some(cs)) => Dsc::VaryingCs(self.length / charset_bpc(cs), cs),
            (14, None) => Dsc::Text(self.length),
            (37, None) => Dsc::Varying(self.length),
            (26, _) => Dsc::Num(26, self.scale),
            (24, _) => Dsc::Dec64,
            (25, _) => Dsc::Dec128,
            (12, _) => Dsc::Date,
            (13, _) => Dsc::Time,
            (35, _) => Dsc::Timestamp,
            (27, _) => Dsc::Double,
            (10, _) => Dsc::Float,
            (23, _) => Dsc::Boolean,
            (t, _) => Dsc::Num(t, self.scale),
        }
    }
}

fn charset_bpc(cs: u16) -> u16 {
    CHARSET_BPC.iter().find(|(i, _)| *i == cs).map_or(1, |(_, b)| (*b).max(1))
}

/// A column type written as SQL (`NUMERIC(9,2)`, `VARCHAR(20) CHARACTER
/// SET UTF8`, `DOUBLE PRECISION`) as the [TypeSpec] a typed catalog entry
/// carries ([set_catalog_typed]); a bare text type takes the database
/// default set ([set_default_charset]). None for a spelling the cast
/// grammar does not read.
pub fn type_spec_of(sql: &str) -> Option<TypeSpec> {
    let toks = lex(sql.trim())?;
    let mut p = P::fresh(&toks);
    let d = p.cast_target()?;
    if p.i != toks.len() {
        return None;
    }
    let (def_cs, def_bpc) = DEFAULT_CS.with(|c| c.get());
    Some(match d {
        Dsc::Num(dt, sc) => TypeSpec { blr_type: dt, length: 0, scale: sc, charset: None },
        Dsc::Text(l) => TypeSpec { blr_type: 14, length: l.saturating_mul(def_bpc), scale: 0, charset: Some(def_cs) },
        Dsc::Varying(l) => TypeSpec { blr_type: 37, length: l.saturating_mul(def_bpc), scale: 0, charset: Some(def_cs) },
        Dsc::TextCs(l, cs) => TypeSpec { blr_type: 14, length: l.saturating_mul(charset_bpc(cs)), scale: 0, charset: Some(cs) },
        Dsc::VaryingCs(l, cs) => TypeSpec { blr_type: 37, length: l.saturating_mul(charset_bpc(cs)), scale: 0, charset: Some(cs) },
        Dsc::Date => TypeSpec { blr_type: 12, length: 4, scale: 0, charset: None },
        Dsc::Time => TypeSpec { blr_type: 13, length: 4, scale: 0, charset: None },
        Dsc::Timestamp => TypeSpec { blr_type: 35, length: 8, scale: 0, charset: None },
        Dsc::Double => TypeSpec { blr_type: 27, length: 8, scale: 0, charset: None },
        Dsc::Float => TypeSpec { blr_type: 10, length: 4, scale: 0, charset: None },
        Dsc::Boolean => TypeSpec { blr_type: 23, length: 1, scale: 0, charset: None },
        Dsc::Dec64 => TypeSpec { blr_type: 24, length: 8, scale: 0, charset: None },
        Dsc::Dec128 => TypeSpec { blr_type: 25, length: 16, scale: 0, charset: None },
    })
}

/// What the compiler knows about the types around it while compiling a
/// CHECK: the domain VALUE's type, and the checked table's columns. The
/// engine casts the members of a text `IN (...)` list to the tested
/// operand's type (measured: `VALUE IN ('software', ...)` on a
/// VARCHAR(12) domain stores each literal under `blr_cast blr_varying2
/// 0,0 12,0`), so the list needs the operand's declared type.
#[derive(Default, Clone)]
struct Typing {
    value: Option<Dsc>,
    cols: Vec<(String, Dsc)>,
}

thread_local! {
    /// the DATABASE's default character set for a text type written
    /// without one - (charset id, bytes per character); (0, 1) is NONE,
    /// the only database this crate was measured against before
    static DEFAULT_CS: std::cell::Cell<(u16, u16)> = const { std::cell::Cell::new((0, 1)) };
    /// the set a string LITERAL's descriptor names - the attachment's, on
    /// the engine (a routine compiled under a UTF8 attachment stores
    /// `blr_literal blr_text2 4 ..`, under NONE `.. 0 ..`, measured on 2196)
    static LIT_CS: std::cell::Cell<u16> = const { std::cell::Cell::new(0) };
    static TYPING: std::cell::RefCell<Typing> = std::cell::RefCell::new(Typing::default());
    /// (relation or procedure name, its column or output names): what a
    /// bare column name across several streams resolves through
    static CATALOG: std::cell::RefCell<Vec<(String, Vec<(String, Option<TypeSpec>)>)>> = std::cell::RefCell::new(Vec::new());
}

/// The database's default character set, for the text types a body
/// declares without one (`DECLARE W VARCHAR(60)` in a UTF8 database is
/// `blr_varying2` charset 4, 240 BYTES - measured). (0, 1) restores NONE.
/// The set string literals are stamped with ([LIT_CS]) - the attachment's;
/// 0 restores the NONE every other compile keeps.
pub fn set_literal_charset(charset: u16) {
    LIT_CS.with(|c| c.set(charset));
}

pub fn set_default_charset(charset: u16, bytes_per_char: u16) {
    DEFAULT_CS.with(|c| c.set((charset, bytes_per_char.max(1))));
}

/// Hand the compiler the columns of the tables (and the outputs of the
/// procedures) a body may read, so a bare name across two streams binds
/// the way the engine's resolves it. Cleared with an empty list.
pub fn set_catalog(entries: Vec<(String, Vec<String>)>) {
    set_catalog_typed(
        entries
            .into_iter()
            .map(|(r, cols)| (r, cols.into_iter().map(|c| (c, None)).collect()))
            .collect(),
    );
}

/// [set_catalog] with each column's type where the caller knows it, so
/// a CASE / IIF / NULLIF / FILTER over a column, and an IN list beside
/// one, carry the cast descriptor the engine unifies to
/// ([P::unify_branches]); a None type leaves those shapes refused.
pub fn set_catalog_typed(entries: Vec<(String, Vec<(String, Option<TypeSpec>)>)>) {
    CATALOG.with(|c| *c.borrow_mut() = entries);
}

/// Every column of a catalogued relation (or a selectable procedure's
/// outputs) in RDB$FIELD_POSITION order - what a `*` stands for; None
/// when the catalog does not know the name, so a star compiles nothing
/// it cannot see.
fn catalog_columns(rel: &str) -> Option<Vec<String>> {
    CATALOG.with(|c| {
        c.borrow()
            .iter()
            .find(|(r, _)| r == rel)
            .map(|(_, cols)| cols.iter().map(|(n, _)| n.clone()).collect())
    })
}

fn catalog_has(rel: &str, col: &str) -> bool {
    CATALOG.with(|c| {
        c.borrow()
            .iter()
            .any(|(r, cols)| r == rel && cols.iter().any(|(x, _)| x == col))
    })
}

fn catalog_type(rel: &str, col: &str) -> Option<Dsc> {
    CATALOG.with(|c| {
        let c = c.borrow();
        let (_, cols) = c.iter().find(|(r, _)| r == rel)?;
        let (_, t) = cols.iter().find(|(x, _)| x == col)?;
        t.map(|t| t.dsc())
    })
}

fn typing_of(v: &Val) -> Option<Dsc> {
    TYPING.with(|t| {
        let t = t.borrow();
        match v {
            Val::Fid(0, 0) => t.value,
            Val::Field(_, name) => t.cols.iter().find(|(n, _)| n == name).map(|(_, d)| *d),
            _ => None,
        }
    })
}

/// [compile_validation] with the domain VALUE's declared type known, so
/// a text `IN` list compiles the way the engine stores it.
pub fn compile_validation_typed(sql: &str, value: TypeSpec) -> Option<Vec<u8>> {
    TYPING.with(|t| *t.borrow_mut() = Typing { value: Some(value.dsc()), cols: Vec::new() });
    let r = compile_validation(sql);
    TYPING.with(|t| *t.borrow_mut() = Typing::default());
    r
}

pub fn compile_validation(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: Vec::new(),
        base: 0,
        outer: Some(0),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: true,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !p.kw("CHECK") {
        return None;
    }
    if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
        return None;
    }
    p.i += 1;
    let cond = p.bool_or()?;
    if !matches!(p.t.get(p.i), Some(Tok::RParen)) {
        return None;
    }
    p.i += 1;
    if p.i != p.t.len() {
        return None;
    }
    let mut out = vec![blr::VERSION5];
    emit_bool(&mut out, &cond);
    out.push(blr::EOC);
    Some(out)
}

/// `compile_validation` as uppercase hex.
pub fn compile_validation_hex(sql: &str) -> Option<String> {
    Some(
        compile_validation(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// `compile_computed` as uppercase hex.
pub fn compile_computed_hex(sql: &str) -> Option<String> {
    Some(
        compile_computed(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// Compile a CREATE TRIGGER to the BLR the engine stores in
/// `RDB$TRIGGER_BLR` - oracle number THREE, and the leanest wrapper
/// of all (probed): blr_begin, blr_label 0, then a DOUBLE blr_begin
/// holding the statements, three blr_ends, blr_eoc. OLD is CONTEXT 0
/// and NEW is CONTEXT 1 - modelled as two pseudo-streams, so
/// qualified fields resolve through the ordinary path and bare names
/// refuse. The trigger HEADER (table, BEFORE/AFTER, INSERT/UPDATE/
/// DELETE, POSITION) leaves NO trace in the BLR - it is catalog data,
/// like a view's select list.
///
///   CREATE TRIGGER <name> FOR <table>
///     BEFORE|AFTER INSERT|UPDATE|DELETE [POSITION <n>] AS
///   BEGIN <statements> END
pub fn compile_trigger(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: vec![
            Stream {
                name: "OLD".to_string(),
                alias: None,
                derived: None,
                sub: false,
                cur: None,
                proc_args: None,
            },
            Stream {
                name: "NEW".to_string(),
                alias: None,
                derived: None,
                sub: false,
                cur: None,
                proc_args: None,
            },
        ],
        base: 0,
        outer: Some(2),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        win_cap: None,
        win_found: Vec::new(),
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
            loop_labels: Vec::new(),
            package: None,
            pkg_members: Vec::new(),
            plain_funcs: Vec::new(),
            saw_user_fn: false,
            pending_loop_label: None,
        proc: None,
        agg_fid_ctx: 1,
        domain_value: false,
        cursors: Vec::new(),
        cursor_decls: Vec::new(),
        for_cursors: Vec::new(),
        merge_scope: None,
        in_func: false,
        in_sub: false,
        saw_suspend: false,
        host: None,
        ctes: Vec::new(),
        sub_decls: Vec::new(),
        sub_procs: Vec::new(),
        sub_funcs: Vec::new(),
    };
    if !(p.kw("CREATE") && p.kw("TRIGGER")) {
        return None;
    }
    match p.t.get(p.i)? {
        Tok::Ident(w) if !is_keyword(w) => p.i += 1,
        _ => return None,
    }
    if !p.kw("FOR") {
        return None;
    }
    match p.t.get(p.i)? {
        Tok::Ident(w) if !is_keyword(w) => p.i += 1,
        _ => return None,
    }
    if !(p.kw("BEFORE") || p.kw("AFTER")) {
        return None;
    }
    // one or more events: INSERT [OR UPDATE [OR DELETE]] - the event
    // list, like the rest of the header, leaves no BLR trace
    loop {
        match p.t.get(p.i)? {
            Tok::Ident(w)
                if matches!(w.as_str(), "INSERT" | "UPDATE" | "DELETE") =>
            {
                p.i += 1
            }
            _ => return None,
        }
        if !p.kw("OR") {
            break;
        }
    }
    if p.kw("POSITION") {
        let Some(Tok::Int(_)) = p.t.get(p.i) else {
            return None;
        };
        p.i += 1;
    }
    if !p.kw("AS") {
        return None;
    }
    // DECLARE [VARIABLE] name TYPE [= <value>]; ... - declares sit
    // between the outer begin and label 0, each null-initialised
    // UNLESS an initialiser replaces the null; cursor declarations
    // hold their SOURCE position among the declares while the inits
    // stay grouped at the end (probed - the trigger flavor of the
    // procedure's deferral law)
    let mut declares: Vec<(Dsc, Option<Val>)> = Vec::new();
    enum TDecl {
        Var(usize),
        Cur(usize),
        Sub(usize),
    }
    let mut decl_seq: Vec<TDecl> = Vec::new();
    while p.kw("DECLARE") {
        // subroutines declare in trigger bodies too - the same
        // grouped-declare slots cursors take (probed)
        if p.kw("PROCEDURE") {
            decl_seq.push(TDecl::Sub(p.sub_decl(false)?));
            continue;
        }
        if p.kw("FUNCTION") {
            decl_seq.push(TDecl::Sub(p.sub_decl(true)?));
            continue;
        }
        let _ = p.kw("VARIABLE");
        let Some(Tok::Ident(name)) = p.t.get(p.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        p.i += 1;
        let scroll = p.kw("SCROLL");
        if p.kw("CURSOR") {
            decl_seq.push(TDecl::Cur(p.cursor_decls.len()));
            p.cursor_decl(name, scroll)?;
            continue;
        }
        if scroll {
            return None;
        }
        let dsc = p.cast_target()?;
        p.local_vars.push(name);
        let init = if matches!(p.t.get(p.i), Some(Tok::Cmp(CmpOp::Eql))) {
            p.i += 1;
            Some(p.val()?)
        } else {
            None
        };
        decl_seq.push(TDecl::Var(declares.len()));
        declares.push((dsc, init));
        if !matches!(p.t.get(p.i), Some(Tok::Semi)) {
            return None;
        }
        p.i += 1;
    }
    if !p.kw("BEGIN") {
        return None;
    }
    let mut stmts = Vec::new();
    while !p.kw("END") {
        stmts.push(p.trig_stmt()?);
    }
    if p.i != p.t.len() {
        return None;
    }
    let mut out = vec![blr::VERSION5, blr::BEGIN];
    // TRIGGERS group ALL declares first (cursor declarations in
    // their source slots among them), THEN all init assignments -
    // unlike procedures, which interleave declare/init per variable
    // (both probed; read the bytes, not the symmetry)
    for d in &decl_seq {
        match d {
            TDecl::Var(vi) => {
                out.push(blr::DECLARE);
                out.extend_from_slice(&(*vi as u16).to_le_bytes());
                emit_dsc(&mut out, declares[*vi].0);
            }
            TDecl::Cur(ci) => emit_cursor_decl(&mut out, &p.cursor_decls[*ci]),
            TDecl::Sub(si) => out.extend_from_slice(&p.sub_decls[*si]),
        }
    }
    for (vi, (_, init)) in declares.iter().enumerate() {
        out.push(blr::ASSIGNMENT);
        match init {
            Some(v) => emit_val(&mut out, v),
            None => out.push(blr::NULL),
        }
        out.push(blr::VARIABLE);
        out.extend_from_slice(&(vi as u16).to_le_bytes());
    }
    out.extend_from_slice(&[blr::LABEL, 0, blr::BEGIN]);
    // an empty body is its block's wrapper alone (see the routine's)
    if !stmts.is_empty() {
        out.push(blr::BEGIN);
        for st in &stmts {
            emit_trig_stmt(&mut out, st);
        }
        out.push(blr::END);
    }
    out.push(blr::END);
    out.push(blr::END);
    out.push(blr::EOC);
    Some(out)
}

/// `compile_trigger` as uppercase hex.
pub fn compile_trigger_hex(sql: &str) -> Option<String> {
    Some(
        compile_trigger(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// One parameter of a compiled procedure, shaped for the catalog rows
/// a CREATE PROCEDURE writes: the name and the RDB$FIELDS facts its
/// invented RDB$n domain needs (RDB$FIELD_TYPE / LENGTH / SCALE /
/// SUB_TYPE - the same catalog language table columns speak).
pub struct ProcParamMeta {
    pub name: String,
    pub field_type: i16,
    pub length: u16,
    pub scale: i16,
    pub sub_type: i16,
    /// RDB$FIELD_PRECISION: the declared p of a NUMERIC/DECIMAL parameter
    pub precision: Option<i16>,
    /// a TEXT parameter's EXPLICIT `CHARACTER SET` (its id); None takes the
    /// database's default
    pub charset: Option<u16>,
    /// an input parameter DEFAULT value SOURCE (`5`, `'x'`, `NULL`); None
    /// for outputs and undefaulted inputs. The wire turns it into the
    /// stored RDB$DEFAULT_SOURCE / VALUE.
    pub default: Option<String>,
}

/// A declared NUMERIC/DECIMAL spelling overrides the descriptor's guess
/// at sub_type and supplies the precision.
fn apply_decl(m: &mut ProcParamMeta, decl: &Option<(i16, i16)>) {
    if let Some((sub, prec)) = decl {
        m.sub_type = *sub;
        m.precision = Some(*prec);
    }
}

fn dsc_to_meta(name: &str, d: &Dsc) -> ProcParamMeta {
    let (field_type, length, scale) = match d {
        Dsc::Num(7, sc) => (7, 2, *sc as i16),
        Dsc::Num(8, sc) => (8, 4, *sc as i16),
        Dsc::Num(26, sc) => (26, 16, *sc as i16),
        Dsc::Num(_, sc) => (16, 8, *sc as i16),
        Dsc::Text(l) | Dsc::TextCs(l, _) => (14, *l, 0),
        Dsc::Varying(l) | Dsc::VaryingCs(l, _) => (37, *l, 0),
        Dsc::Dec64 => (24, 8, 0),
        Dsc::Dec128 => (25, 16, 0),
        Dsc::Date => (12, 4, 0),
        Dsc::Time => (13, 4, 0),
        Dsc::Timestamp => (35, 8, 0),
        Dsc::Double => (27, 8, 0),
        Dsc::Float => (10, 4, 0),
        Dsc::Boolean => (23, 1, 0),
    };
    ProcParamMeta {
        name: name.to_string(),
        field_type,
        length,
        scale,
        // a scaled exact-numeric parameter is NUMERIC (RDB$FIELD_SUB_TYPE
        // 1); a plain integer or a non-numeric type is 0. DECIMAL (2) is
        // not distinguished from NUMERIC by the Dsc here - a boundary.
        sub_type: if scale != 0 { 1 } else { 0 },
        // a DECFLOAT's RDB$FIELD_PRECISION is its digits (16 / 34, probed)
        precision: match d {
            Dsc::Dec64 => Some(16),
            Dsc::Dec128 => Some(34),
            // a bare INT128's RDB$FIELD_PRECISION is 0 (measured); a declared
            // NUMERIC(p, s) overrides it ([apply_decl])
            Dsc::Num(26, _) => Some(0),
            _ => None,
        },
        default: None,
        charset: match d {
            Dsc::TextCs(_, cs) | Dsc::VaryingCs(_, cs) => Some(*cs),
            _ => None,
        },
    }
}

/// A compiled CREATE PROCEDURE, everything the DDL's catalog writes
/// need: the engine-byte BLR, the parameters both ways, whether a
/// SUSPEND makes it selectable (RDB$PROCEDURE_TYPE 1) or not (2), and
/// the body SOURCE (from its first non-space byte - what the engine
/// stores in RDB$PROCEDURE_SOURCE, and what the source interpreter
/// reads back).
pub struct ProcCompiled {
    pub name: String,
    pub blob: Vec<u8>,
    pub ins: Vec<ProcParamMeta>,
    pub outs: Vec<ProcParamMeta>,
    pub selectable: bool,
    pub source: String,
    /// the body binds a bare plain user-function call - it must run via
    /// exe (see [P::saw_user_fn]); the server checks exe can convert the BLR
    pub calls_user_fn: bool,
}

/// [compile_procedure] with the catalog metadata kept - None exactly
/// when compile_procedure refuses, so the DDL surface and the BLR
/// oracle can never drift.
fn compile_routine_full(
    sql: &str,
    is_function: bool,
    pkg: Option<(&str, &[(String, usize)])>,
    plain_funcs: &[(String, usize, usize)],
) -> Option<ProcCompiled> {
    let trimmed = sql.trim().trim_end_matches(';');
    let toks = lex(trimmed)?;
    let mut p = P::fresh(&toks);
    if let Some((pkn, mems)) = pkg {
        // a PACKAGE BODY member: sibling members resolve unqualified
        p.package = Some(pkn.to_ascii_uppercase());
        p.pkg_members = mems.iter().map(|(m, a)| (m.to_ascii_uppercase(), *a)).collect();
    }
    p.plain_funcs = plain_funcs
        .iter()
        .map(|(m, a, r)| (m.to_ascii_uppercase(), *a, *r))
        .collect();
    let kw2 = if is_function { "FUNCTION" } else { "PROCEDURE" };
    if !(p.kw("CREATE") && p.kw(kw2)) {
        return None;
    }
    let name = match p.t.get(p.i)? {
        Tok::Ident(w) if !is_keyword(w) => {
            p.i += 1;
            w.to_ascii_uppercase()
        }
        _ => return None,
    };
    let bo = body_compile(&mut p, is_function, false)?;
    // the stored source is the text from AS onward, first non-space:
    // exactly what the load-by-source interpreter expects
    let up = trimmed.to_ascii_uppercase();
    let bytes = up.as_bytes();
    let mut as_at = None;
    let mut k = 0usize;
    while let Some(rel) = up[k..].find("AS") {
        let at = k + rel;
        let before_ok = at == 0 || !bytes[at - 1].is_ascii_alphanumeric() && bytes[at - 1] != b'_' && bytes[at - 1] != b'$';
        let after_ok = bytes
            .get(at + 2)
            .is_none_or(|c| !c.is_ascii_alphanumeric() && *c != b'_' && *c != b'$');
        if before_ok && after_ok {
            as_at = Some(at);
            break;
        }
        k = at + 2;
    }
    let source = trimmed[as_at? + 2..].trim_start().to_string();
    Some(ProcCompiled {
        name,
        blob: bo.blob,
        ins: bo
            .ins
            .iter()
            .zip(bo.in_defaults.iter())
            .zip(bo.in_decls.iter().chain(std::iter::repeat(&None)))
            .map(|(((n, d), def), decl)| {
                let mut m = dsc_to_meta(n, d);
                m.default = def.clone();
                apply_decl(&mut m, decl);
                m
            })
            .collect(),
        outs: bo
            .outs
            .iter()
            .zip(bo.out_decls.iter().chain(std::iter::repeat(&None)))
            .map(|((n, d), decl)| {
                let mut m = dsc_to_meta(n, d);
                apply_decl(&mut m, decl);
                m
            })
            .collect(),
        selectable: bo.selectable,
        source,
        calls_user_fn: p.saw_user_fn,
    })
}

pub fn compile_procedure_full(sql: &str) -> Option<ProcCompiled> {
    compile_routine_full(sql, false, None, &[])
}

/// [compile_procedure_full] with the enclosing package's name and its
/// sibling member names, so an unqualified sibling call in the body binds
/// to the package (blr_function2 with THIS package).
pub fn compile_procedure_full_in_package(
    sql: &str,
    package: &str,
    members: &[(String, usize)],
) -> Option<ProcCompiled> {
    compile_routine_full(sql, false, Some((package, members)), &[])
}

/// `compile_procedure` as uppercase hex.
/// `CREATE FUNCTION <name> (<args>) RETURNS <type> [DETERMINISTIC] AS <body>`:
/// the procedure compiler in FUNCTION mode (the one package functions
/// use) - the body wrapped in one more blr_begin, `RETURN <e>` as the
/// assignment to variable 0 then the send of message 1 and a leave, the
/// final send without the EOS flag (probed byte for byte against the
/// engine's RDB$FUNCTION_BLR).
pub fn compile_function_full(sql: &str) -> Option<ProcCompiled> {
    compile_routine_full(sql, true, None, &[])
}

/// [compile_procedure_full] with the plain user functions the catalog
/// holds, so a bare `F(...)` in the body binds to blr_function.
pub fn compile_procedure_full_with_funcs(
    sql: &str,
    plain_funcs: &[(String, usize, usize)],
) -> Option<ProcCompiled> {
    compile_routine_full(sql, false, None, plain_funcs)
}

/// [compile_function_full] with the plain user functions the catalog holds.
pub fn compile_function_full_with_funcs(
    sql: &str,
    plain_funcs: &[(String, usize, usize)],
) -> Option<ProcCompiled> {
    compile_routine_full(sql, true, None, plain_funcs)
}

/// [compile_function_full] with the enclosing package's name and its
/// sibling member names (see [compile_procedure_full_in_package]).
pub fn compile_function_full_in_package(
    sql: &str,
    package: &str,
    members: &[(String, usize)],
) -> Option<ProcCompiled> {
    compile_routine_full(sql, true, Some((package, members)), &[])
}

pub fn compile_procedure_hex(sql: &str) -> Option<String> {
    Some(
        compile_procedure(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

/// The emitted BLR as uppercase hex - what the gate compares against
/// isql's OCTETS rendering of `RDB$VIEW_BLR`.
pub fn compile_view_select_hex(sql: &str) -> Option<String> {
    Some(
        compile_view_select(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// every expected string here was read back from the ENGINE's
    /// RDB$VIEW_BLR for the identical statement (see the module doc);
    /// the gate re-verifies them against a live engine on every run
    fn pin(sql: &str, want_hex: &str) {
        assert_eq!(
            compile_view_select_hex(sql).as_deref(),
            Some(want_hex),
            "{sql}"
        );
    }

    #[test]
    fn compiles_the_probed_view_blr_byte_for_byte() {
        // the select list leaves no trace: both compile identically
        pin("SELECT ID FROM T", "0543014A015401FF4C");
        pin("SELECT ID, A FROM T", "0543014A015401FF4C");
        // WHERE with a comparison and a literal
        pin(
            "SELECT ID FROM T WHERE A > 5",
            "0543014A01540147311701014115080005000000FF4C",
        );
        // AND of comparisons, text literal as blr_text2
        pin(
            "SELECT ID, S FROM T WHERE A = 1 AND S = 'x'",
            "0543014A015401473A2F17010141150800010000002F17010153150F0000010078FF4C",
        );
        // OR, >=, <>
        pin(
            "SELECT ID FROM T WHERE A >= 5 OR A <> 0",
            "0543014A0154014739321701014115080005000000301701014115080000000000FF4C",
        );
        // NOT folds to the inverse comparison
        pin(
            "SELECT ID FROM T WHERE NOT (A > 5)",
            "0543014A01540147341701014115080005000000FF4C",
        );
        // IS NULL is blr_missing
        pin("SELECT ID FROM T WHERE S IS NULL", "0543014A015401473D17010153FF4C");
        // a decimal literal keeps its written scale (12.50 -> -2, 1250)
        pin(
            "SELECT ID FROM T WHERE N = 12.50",
            "0543014A015401472F1701014E1508FEE2040000FF4C",
        );
        // BETWEEN stays blr_between
        pin(
            "SELECT ID FROM T WHERE A BETWEEN 1 AND 9",
            "0543014A0154014738170101411508000100000015080009000000FF4C",
        );
        // LIKE
        pin(
            "SELECT ID FROM T WHERE S LIKE 'x%'",
            "0543014A015401473F17010153150F000002007825FF4C",
        );
        // left-nested ANDs, <, <=, IS NOT NULL = not(missing)
        pin(
            "SELECT ID FROM T WHERE A < 3 AND A <= 4 AND S IS NOT NULL",
            "0543014A015401473A3A3317010141150800030000003417010141150800040000003B3D17010153FF4C",
        );
        // De Morgan pushes NOT through OR: and(neq, not(missing))
        pin(
            "SELECT ID FROM T WHERE NOT (A = 1 OR S IS NULL)",
            "0543014A015401473A3017010141150800010000003B3D17010153FF4C",
        );
        // NOT LIKE keeps blr_not
        pin(
            "SELECT ID FROM T WHERE S NOT LIKE 'x%'",
            "0543014A015401473B3F17010153150F000002007825FF4C",
        );
        // NOT BETWEEN expands to lss OR gtr
        pin(
            "SELECT ID FROM T WHERE A NOT BETWEEN 1 AND 9",
            "0543014A0154014739331701014115080001000000311701014115080009000000FF4C",
        );
        // field against field
        pin(
            "SELECT ID FROM T WHERE A = ID",
            "0543014A015401472F170101411701024944FF4C",
        );
        // IS NOT DISTINCT FROM is blr_equiv; IS DISTINCT FROM keeps a
        // blr_not over it, and NOT of that cancels (read back from the
        // engine's RDB$VIEW_BLR on 2182)
        pin(
            "SELECT ID FROM T WHERE A IS NOT DISTINCT FROM 5",
            "0543014A015401472E1701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A IS DISTINCT FROM 5",
            "0543014A015401473B2E1701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT (A IS DISTINCT FROM 5)",
            "0543014A015401472E1701014115080005000000FF4C",
        );
    }

    #[test]
    fn compiles_slice_two_shapes_byte_for_byte() {
        // value expressions: add/sub/mul/div with plain precedence
        pin(
            "SELECT ID FROM T WHERE A + 1 > 5",
            "0543014A015401473122170101411508000100000015080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A * 2 - 1 = 9",
            "0543014A015401472F232417010141150800020000001508000100000015080009000000FF4C",
        );
        // blr_negate survives only before a field...
        pin(
            "SELECT ID FROM T WHERE -A = 5",
            "0543014A015401472F261701014115080005000000FF4C",
        );
        // ...while a sign before a numeric literal FOLDS into it
        pin(
            "SELECT ID FROM T WHERE A = -1",
            "0543014A015401472F17010141150800FFFFFFFFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = -1.5",
            "0543014A015401472F170101411508FFF1FFFFFFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A / 2 = 3",
            "0543014A015401472F25170101411508000200000015080003000000FF4C",
        );
        // parens reshape the tree
        pin(
            "SELECT ID FROM T WHERE (A + 1) * 2 = 8",
            "0543014A015401472F242217010141150800010000001508000200000015080008000000FF4C",
        );
        // concatenation
        pin(
            "SELECT ID FROM T WHERE S = 'a' || 'b'",
            "0543014A015401472F1701015327150F0000010061150F0000010062FF4C",
        );
        // IN is blr_in_list with a u16 count; NOT IN keeps blr_not
        pin(
            "SELECT ID FROM T WHERE A IN (1, 2, 3)",
            "0543014A0154014740170101410300150800010000001508000200000015080003000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A NOT IN (1, 2)",
            "0543014A015401473B401701014102001508000100000015080002000000FF4C",
        );
        // comma-FROM: two streams side by side, fields by context
        pin(
            "SELECT T.ID FROM T, U2 WHERE T.ID = U2.UID",
            "0543024A0154014A02553202472F1701024944170203554944FF4C",
        );
        // an alias becomes blr_relation2, UPPERCASED IN DOUBLE QUOTES
        pin(
            "SELECT X.ID FROM T X WHERE X.A > 1",
            "054301920154032258220147311701014115080001000000FF4C",
        );
        pin(
            "SELECT AB.ID FROM T AB WHERE AB.A > 1",
            "05430192015404224142220147311701014115080001000000FF4C",
        );
        // a lowercase alias uppercases before quoting
        pin(
            "SELECT x.ID FROM T x WHERE x.A > 1",
            "054301920154032258220147311701014115080001000000FF4C",
        );
        // INNER JOIN: blr_join nests like an rse, the ON clause is its
        // boolean, and a WHERE is the rse's own boolean after it
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID WHERE U2.UA > 0",
            "05430177024A0154014A02553202472F1701024944170203554944FF4731170202554115080000000000FF4C",
        );
        pin(
            "SELECT E.ID FROM T E JOIN U2 D ON E.ID = D.UID",
            "05430177029201540322452201920255320322442202472F1701024944170203554944FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_three_shapes_byte_for_byte() {
        // outer joins: blr_join_type (absent for INNER) carries
        // 1=LEFT, 2=RIGHT, 3=FULL after the streams, before the ON
        pin(
            "SELECT T.ID FROM T LEFT JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025001472F1701024944170203554944FFFF4C",
        );
        pin(
            "SELECT T.ID FROM T RIGHT JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025002472F1701024944170203554944FFFF4C",
        );
        pin(
            "SELECT T.ID FROM T FULL JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025003472F1701024944170203554944FFFF4C",
        );
        // LEFT OUTER JOIN compiles to the same bytes as LEFT JOIN
        pin(
            "SELECT T.ID FROM T LEFT OUTER JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025001472F1701024944170203554944FFFF4C",
        );
        // a chained join NESTS LEFT: the second join's node holds the
        // first join's node as its first stream slot (probed)
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID JOIN V3T ON U2.UA = V3T.VID",
            "054301770277024A0154014A02553202472F1701024944170203554944FF4A0356335403472F1702025541170303564944FFFF4C",
        );
        // a mixed chain: the type byte sits on ITS OWN node only
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID LEFT JOIN V3T ON U2.UA = V3T.VID",
            "054301770277024A0154014A02553202472F1701024944170203554944FF4A03563354035001472F1702025541170303564944FFFF4C",
        );
        // an outer join plus WHERE: the rse's own boolean follows the
        // join node - the classic find-the-unmatched-rows shape
        pin(
            "SELECT T.ID FROM T LEFT JOIN U2 ON T.ID = U2.UID WHERE U2.UA IS NULL",
            "05430177024A0154014A025532025001472F1701024944170203554944FF473D1702025541FF4C",
        );
        // a literal past blr_long's 32 bits: blr_int64, one scale
        // byte, 8 little-endian bytes
        pin(
            "SELECT ID FROM T WHERE A = 5000000000",
            "0543014A015401472F1701014115100000F2052A01000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = -5000000000",
            "0543014A015401472F17010141151000000EFAD5FEFFFFFFFF4C",
        );
        // built-ins: blr_upcase / blr_lowcase take one operand
        pin(
            "SELECT ID FROM T WHERE UPPER(S) = 'X'",
            "0543014A015401472F6717010153150F0000010058FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE LOWER(S) = 'x'",
            "0543014A015401472FB517010153150F0000010078FF4C",
        );
        // blr_strlen's length-type byte: CHAR_LENGTH=1, OCTET_LENGTH=2
        pin(
            "SELECT ID FROM T WHERE CHAR_LENGTH(S) > 3",
            "0543014A0154014731B6011701015315080003000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE OCTET_LENGTH(S) > 3",
            "0543014A0154014731B6021701015315080003000000FF4C",
        );
        // blr_substring's start is 0-BASED and the engine emits
        // subtract(<from>, 1) UNFOLDED - FROM 1 stores subtract(1, 1)
        pin(
            "SELECT ID FROM T WHERE SUBSTRING(S FROM 1 FOR 2) = 'ab'",
            "0543014A015401472F281701015323150800010000001508000100000015080002000000150F000002006162FF4C",
        );
        // blr_trim: where byte (0=BOTH 1=LEADING 2=TRAILING), spec
        // byte (0=spaces, 1=an explicit what operand)
        pin(
            "SELECT ID FROM T WHERE TRIM(S) = 'x'",
            "0543014A015401472FB7000017010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(LEADING 'a' FROM S) = 'x'",
            "0543014A015401472FB70101150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(TRAILING 'a' FROM S) = 'x'",
            "0543014A015401472FB70201150F000001006117010153150F0000010078FF4C",
        );
        // a bare `TRIM('a' FROM s)` is BOTH - byte-identical to the
        // explicit form
        pin(
            "SELECT ID FROM T WHERE TRIM('a' FROM S) = 'x'",
            "0543014A015401472FB70001150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(BOTH 'a' FROM S) = 'x'",
            "0543014A015401472FB70001150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(LEADING FROM S) = 'x'",
            "0543014A015401472FB7010017010153150F0000010078FF4C",
        );
    }

    #[test]
    fn compiles_slice_four_shapes_byte_for_byte() {
        // blr_cast: dsc bytes per target - numerics carry dtype +
        // scale; NUMERIC(p<=4) is SHORT but DECIMAL(p<=9) is ALWAYS
        // LONG; p in 10..=18 is INT64; texts carry charset + length;
        // temporals are the dtype alone
        pin(
            "SELECT ID FROM T WHERE CAST(A AS BIGINT) = 5",
            "0543014A015401472F8310001701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS SMALLINT) = 5",
            "0543014A015401472F8307001701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS INTEGER) = 5",
            "0543014A015401472F8308001701015315080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(9,2)) = 1.50",
            "0543014A015401472F8308FE170101411508FE96000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(4,1)) = 1.5",
            "0543014A015401472F8307FF170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS DECIMAL(4,1)) = 1.5",
            "0543014A015401472F8308FF170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(18,2)) = 1.5",
            "0543014A015401472F8310FE170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(10)) = 1",
            "0543014A015401472F8310001701014115080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(ID AS VARCHAR(10)) = '5'",
            "0543014A015401472F832600000A001701024944150F0000010035FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS CHAR(5)) = 'x'",
            "0543014A015401472F830F0000050017010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS DATE) = S",
            "0543014A015401472F830C1701015317010153FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS TIME) = S",
            "0543014A015401472F830D1701015317010153FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS TIMESTAMP) = S",
            "0543014A015401472F83231701015317010153FF4C",
        );
        // the searched CASE: ONE cast wrapper over a value_if chain,
        // the unified dsc from the branches (NULL ignored)
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 ELSE 0 END = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000001508000000000015080001000000FF4C",
        );
        // IIF is byte-identical sugar for it
        pin(
            "SELECT ID FROM T WHERE IIF(A > 5, 1, 0) = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000001508000000000015080001000000FF4C",
        );
        // a missing ELSE is blr_null - and does not shape the dsc
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 END = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000002D15080001000000FF4C",
        );
        // further WHENs nest in the ELSE slot; still ONE cast on top
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 WHEN A > 2 THEN 2 ELSE 3 END = 1",
            "0543014A015401472F830800693117010141150800050000001508000100000069311701014115080002000000150800020000001508000300000015080001000000FF4C",
        );
        // text branches unify to blr_text2 at the MAXIMUM length
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 'yes' ELSE 'no' END = 'yes'",
            "0543014A015401472F830F0000030069311701014115080005000000150F00000300796573150F000002006E6F150F00000300796573FF4C",
        );
        // THE WIDENING LAW: long(0) with long(-1) needs 10 digits -
        // the unified dsc is INT64 scale -1, not long
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1.5 ELSE 0 END = 1",
            "0543014A015401472F8310FF693117010141150800050000001508FF0F0000001508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1.23 ELSE 0.5 END = 1",
            "0543014A015401472F8310FE693117010141150800050000001508FE7B0000001508FF0500000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 5000000000 ELSE 0 END = 1",
            "0543014A015401472F8310006931170101411508000500000015100000F2052A010000001508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 5000000000 ELSE 0.5 END = 1",
            "0543014A015401472F8310FF6931170101411508000500000015100000F2052A010000001508FF0500000015080001000000FF4C",
        );
        // CAST branches contribute their EXPLICIT dsc: two SMALLINT
        // casts stay short; short with long-0 is long
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS SMALLINT) ELSE CAST(ID AS SMALLINT) END = 1",
            "0543014A015401472F8307006931170101411508000500000083070017010141830700170102494415080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS SMALLINT) ELSE 0 END = 1",
            "0543014A015401472F83080069311701014115080005000000830700170101411508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS BIGINT) ELSE 0 END = 1",
            "0543014A015401472F83100069311701014115080005000000831000170101411508000000000015080001000000FF4C",
        );
        // the simple CASE is blr_decode - NO cast wrapper; the ELSE
        // is one extra result, its absence unmarked
        pin(
            "SELECT ID FROM T WHERE CASE ID WHEN 1 THEN 'a' WHEN 2 THEN 'b' ELSE 'c' END = 'a'",
            "0543014A015401472FCB170102494402150800010000001508000200000003150F0000010061150F0000010062150F0000010063150F0000010061FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE ID WHEN 1 THEN 'a' WHEN 2 THEN 'b' END = 'a'",
            "0543014A015401472FCB170102494402150800010000001508000200000002150F0000010061150F0000010062150F0000010061FF4C",
        );
        // COALESCE: a count byte and the values, NO cast wrapper -
        // field arguments are fine here (no dsc to compute)
        pin(
            "SELECT ID FROM T WHERE COALESCE(A, 0) = 5",
            "0543014A015401472FCA02170101411508000000000015080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE COALESCE(A, ID, 0) = 5",
            "0543014A015401472FCA031701014117010249441508000000000015080005000000FF4C",
        );
        // NULLIF(a, b) is cast(value_if(a = b, NULL, a)) - the dsc
        // from the BRANCHES (NULL, a), so b never shapes it
        pin(
            "SELECT ID FROM T WHERE NULLIF(1, 2.55) = 1",
            "0543014A015401472F830800692F150800010000001508FEFF0000002D1508000100000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NULLIF('ab', 'cd') = 'ab'",
            "0543014A015401472F830F00000200692F150F000002006162150F0000020063642D150F000002006162150F000002006162FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NULLIF('abc', 'z') = 'a'",
            "0543014A015401472F830F00000300692F150F00000300616263150F000001007A2D150F00000300616263150F0000010061FF4C",
        );
    }

    #[test]
    fn compiles_slice_five_shapes_byte_for_byte() {
        // EXISTS is blr_any over ONE rse; the subquery's WHERE is
        // that rse's boolean and its select list leaves no trace
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // SELECT * compiles identically
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT * FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // NOT EXISTS keeps a REAL blr_not (no inverse verb)
        pin(
            "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473B3C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // SINGULAR is blr_unique, same single-rse shape
        pin(
            "SELECT ID FROM T WHERE SINGULAR (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473E43014A02553202472F1702035549441701024944FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT SINGULAR (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473B3E43014A02553202472F1702035549441701024944FFFF4C",
        );
        // IN (SELECT ...) is blr_ansi_any: an rse whose single STREAM
        // IS THE SUBQUERY'S RSE, then the comparison as the OUTER
        // rse's boolean; = ANY compiles byte-identical
        pin(
            "SELECT ID FROM T WHERE A IN (SELECT UA FROM U2)",
            "0543014A0154014797430143014A02553202FF472F170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = ANY (SELECT UA FROM U2)",
            "0543014A0154014797430143014A02553202FF472F170101411702025541FFFF4C",
        );
        // NOT IN: the quantifier FLIPS to ansi_all, the comparison
        // INVERTS to neq
        pin(
            "SELECT ID FROM T WHERE A NOT IN (SELECT UA FROM U2)",
            "0543014A015401479E430143014A02553202FF4730170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT (A = ANY (SELECT UA FROM U2))",
            "0543014A015401479E430143014A02553202FF4730170101411702025541FFFF4C",
        );
        // ALL keeps the WRITTEN comparison; NOT (> ALL) flips back to
        // ansi_any with the INVERSE (leq)
        pin(
            "SELECT ID FROM T WHERE A > ALL (SELECT UA FROM U2)",
            "0543014A015401479E430143014A02553202FF4731170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT (A > ALL (SELECT UA FROM U2))",
            "0543014A0154014797430143014A02553202FF4734170101411702025541FFFF4C",
        );
        // SOME == ANY; a correlated WHERE sits inside the INNER rse
        pin(
            "SELECT ID FROM T WHERE A = SOME (SELECT UA FROM U2 WHERE U2.UID = T.ID)",
            "0543014A0154014797430143014A02553202472F1702035549441701024944FF472F170101411702025541FFFF4C",
        );
        // an aliased subquery stream is blr_relation2, and a bare
        // select column binds to the subquery's OWN stream
        pin(
            "SELECT ID FROM T WHERE A IN (SELECT UA FROM U2 X WHERE X.UA > 0)",
            "0543014A0154014797430143019202553203225822024731170202554115080000000000FF472F170101411702025541FFFF4C",
        );
        // context numbering CONTINUES across subqueries: T=1, U2=2,
        // then the subquery's V3T takes 3
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID WHERE EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.A)",
            "05430177024A0154014A02553202472F1701024944170203554944FF473C43014A0356335403472F17030356494417010141FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) OR EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.ID)",
            "0543014A01540147393C43014A02553202472F1702035549441701024944FF3C43014A0356335403472F1703035649441701024944FFFF4C",
        );
        // subqueries compose with plain terms
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) AND A > 0",
            "0543014A015401473A3C43014A02553202472F1702035549441701024944FF311701014115080000000000FF4C",
        );
    }

    #[test]
    fn compiles_slice_six_shapes_byte_for_byte() {
        // DISTINCT is blr_project - the ONE place the select list
        // leaves a trace: count byte, then the listed columns
        pin("SELECT DISTINCT A FROM T", "0543014A015401450117010141FF4C");
        pin(
            "SELECT DISTINCT A, S FROM T",
            "0543014A01540145021701014117010153FF4C",
        );
        // probed order: the boolean first, then the projection
        pin(
            "SELECT DISTINCT A FROM T WHERE A > 0",
            "0543014A01540147311701014115080000000000450117010141FF4C",
        );
        // a scalar subselect is blr_via(blr_singular(rse), value,
        // blr_null) - usable anywhere a value is
        pin(
            "SELECT ID FROM T WHERE A = (SELECT UA FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401472F170101412B7F43014A02553202472F1702035549441701024944FF17020255412DFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE (SELECT UA FROM U2 WHERE U2.UID = T.ID) > 5",
            "0543014A01540147312B7F43014A02553202472F1702035549441701024944FF17020255412D15080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE S = (SELECT X.UA FROM U2 X)",
            "0543014A015401472F170101532B7F4301920255320322582202FF17020255412DFF4C",
        );
        // a derived table is an rse in the stream slot; the relation2
        // alias text carries the alias AND the schema-qualified
        // table: `(SELECT ID FROM T) X` stores `\"X\" \"PUBLIC\".\"T\"`
        pin(
            "SELECT X.ID FROM (SELECT ID FROM T) X",
            "05430143019201541022582220225055424C4943222E22542201FFFF4C",
        );
        // ONE shared context: the inner WHERE and the outer WHERE both
        // address context 1
        pin(
            "SELECT X.ID FROM (SELECT ID FROM T WHERE A > 0) X WHERE X.ID > 1",
            "05430143019201541022582220225055424C4943222E2254220147311701014115080000000000FF4731170102494415080001000000FF4C",
        );
        // a derived table rides anywhere a stream can - here as the
        // left side of a join
        pin(
            "SELECT X.ID FROM (SELECT ID FROM T) X JOIN U2 ON X.ID = U2.UID",
            "054301770243019201541022582220225055424C4943222E22542201FF4A02553202472F1701024944170203554944FFFF4C",
        );
        // UNION: the statement rse's single stream is blr_union - its
        // own context (1, claimed BEFORE any branch), a branch count,
        // then per branch an rse and a blr_map; the DISTINCT form
        // appends blr_project over blr_fid, UNION ALL does not
        pin(
            "SELECT A FROM T UNION SELECT UA FROM U2",
            "0543014C010243014A015402FF4D010000001702014143014A02553203FF4D010000001703025541450118010000FF4C",
        );
        pin(
            "SELECT A FROM T UNION ALL SELECT UA FROM U2",
            "0543014C010243014A015402FF4D010000001702014143014A02553203FF4D010000001703025541FF4C",
        );
        // two columns: map field numbers are little-endian words
        pin(
            "SELECT A, ID FROM T UNION SELECT UA, UID FROM U2",
            "0543014C010243014A015402FF4D02000000170201410100170202494443014A02553203FF4D020000001703025541010017030355494445021801000018010100FF4C",
        );
        // branch WHEREs sit inside the branch rses
        pin(
            "SELECT A FROM T WHERE A > 0 UNION ALL SELECT UA FROM U2 WHERE U2.UA < 9",
            "0543014C010243014A01540247311702014115080000000000FF4D010000001702014143014A025532034733170302554115080009000000FF4D010000001703025541FF4C",
        );
        // three branches: contexts 2, 3, 4 after the union's 1
        pin(
            "SELECT A FROM T UNION ALL SELECT UA FROM U2 UNION ALL SELECT VID FROM V3T",
            "0543014C010343014A015402FF4D010000001702014143014A02553203FF4D01000000170302554143014A0356335404FF4D01000000170403564944FF4C",
        );
    }

    /// every expected string read back from RDB$PROCEDURE_BLR (the
    /// SECOND oracle - procedure bodies hold what views cannot:
    /// ORDER BY); the gate re-verifies against a live engine
    fn pin_proc(sql: &str, want_hex: &str) {
        assert_eq!(
            compile_procedure_hex(sql).as_deref(),
            Some(want_hex),
            "{sql}"
        );
    }

    #[test]
    fn a_package_member_calls_a_sibling_unqualified() {
        // inside a package body a bare `DBL(...)` names sibling member DBL,
        // compiled to blr_function2 with THIS package (C2 <pkg> <name>
        // <argcount>) - byte-identical to the engine's RDB$FUNCTION_BLR for
        // the same package body (read back with blrdump).
        let members = vec![("DBL".to_string(), 1usize), ("QUAD".to_string(), 1usize)];
        let c = compile_function_full_in_package(
            "CREATE FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(DBL(A)); END",
            "PK",
            &members,
        )
        .expect("QUAD compiles in package PK");
        let hex: String = c.blob.iter().map(|b| format!("{:02X}", b)).collect();
        assert_eq!(
            hex,
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B110002020201C202504B0344424C01C202504B0344424C012900000001001A00000E0102011A0000290100000100FF1200FFFFFFFF0E0102011A0000290100000100FFFF4C"
        );
        // WITHOUT the package context (or when the name is no sibling) the
        // same body still REFUSES - a bare unknown call is never silently
        // turned into a field
        assert!(compile_function_full(
            "CREATE FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(DBL(A)); END"
        )
        .is_none());
        assert!(compile_function_full_in_package(
            "CREATE FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN NOPE(A); END",
            "PK",
            &members,
        )
        .is_none());
        // a sibling call with the WRONG arg count refuses (the engine's
        // parameter-mismatch at compile)
        assert!(compile_function_full_in_package(
            "CREATE FUNCTION QUAD(A INTEGER) RETURNS INTEGER AS BEGIN RETURN DBL(A, A); END",
            "PK",
            &members,
        )
        .is_none());
    }

    #[test]
    fn compiles_slice_seven_procedures_byte_for_byte() {
        // the minimal wrapper: message 1 with dsc+null-flag per param
        // plus the EOF short; declare+null-init per param; stall; two
        // labels; for over the rse - STREAM CONTEXT 0 (procedures
        // number from 0, views from 1); assignments; twin sends
        pin_proc(
            "CREATE PROCEDURE QP1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ORDER BY: blr_sort after the boolean - count byte, then
        // blr_ascending/blr_descending per key
        pin_proc(
            "CREATE PROCEDURE QP2 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY ID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QP3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A > 0 ORDER BY ID DESC INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400473117000141150800000000004601491700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // two parameters: interleaved dsc/null-flag message, two
        // declares, ordered assignments, parameter2 slots 0/1 and 2/3
        // and the EOF at 4
        pin_proc(
            "CREATE PROCEDURE QP4 RETURNS (R1 INTEGER, R2 VARCHAR(10)) AS BEGIN FOR SELECT ID, S FROM T ORDER BY S, ID INTO :R1, :R2 DO SUSPEND; END",
            "050204010500080007002600000A0007000700020300000800012D1A00000301002600000A00012D1A01009B1100020211010743014A01540046024817000153481700024944FF020117000249441A000001170001531A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // the dsc encodings are the CAST ones, byte for byte - here
        // NUMERIC(9,2) in message and declare; expressions work in
        // the body's WHERE (context 0)
        pin_proc(
            "CREATE PROCEDURE QP5 RETURNS (R1 NUMERIC(9,2)) AS BEGIN FOR SELECT N FROM T WHERE UPPER(S) = 'X' INTO :R1 DO SUSPEND; END",
            "05020401030008FE070007000203000008FE012D1A00009B1100020211010743014A015400472F6717000153150F0000010058FF02011700014E1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // mixed directions: DESC then ASC, each key marked
        pin_proc(
            "CREATE PROCEDURE QP6 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, A FROM T ORDER BY A DESC, ID ASC INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014A01540046024917000141481700024944FF020117000249441A000001170001411A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_eight_aggregates_byte_for_byte() {
        // the aggregate is a STREAM: blr_aggregate with its own
        // context (1) wrapping the source rse (ctx 0), blr_group_by
        // (present even with ZERO keys), and a blr_map; the DO body
        // reads the output through blr_fid(1, slot)
        pin_proc(
            "CREATE PROCEDURE QA1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D0100000053FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the aggregate verbs: total, min, average, count-of-values
        pin_proc(
            "CREATE PROCEDURE QA2 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(A) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005617000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QA6 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(A) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005D17000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QA7 RETURNS (R1 NUMERIC(9,2)) AS BEGIN FOR SELECT AVG(A) FROM T INTO :R1 DO SUSPEND; END",
            "05020401030008FE070007000203000008FE012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005717000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the WHERE belongs to the SOURCE rse, inside the aggregate
        pin_proc(
            "CREATE PROCEDURE QA4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT MIN(A) FROM T WHERE A > 0 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A01540047311700014115080000000000FF4E004D010000005517000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // an aggregate over an EXPRESSION
        pin_proc(
            "CREATE PROCEDURE QB4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(ID + 1) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005622170002494415080001000000FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // GROUP BY: keys in CLAUSE order, the map in SELECT-LIST
        // order (probed to differ: GROUP BY S, A vs SELECT A, S)
        pin_proc(
            "CREATE PROCEDURE QA3 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A015400FF4E01170001414D0200000017000141010053FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QB1 RETURNS (R1 INTEGER, R2 VARCHAR(10), R3 INTEGER) AS BEGIN FOR SELECT A, S, COUNT(*) FROM T GROUP BY S, A INTO :R1, :R2, :R3 DO SUSPEND; END",
            "050204010700080007002600000A000700080007000700020300000800012D1A00000301002600000A00012D1A01000302000800012D1A02009B1100020211010743014F0143014A015400FF4E0217000153170001414D0300000017000141010017000153020053FF0201180100001A000001180101001A010001180102001A02000E0102011A0000290100000100011A0100290102000300011A020029010400050001150700010019010600FFFFFFFFFF0E0102011A0000290100000100011A0100290102000300011A020029010400050001150700000019010600FFFF4C",
        );
        // WHERE + GROUP BY: the boolean stays in the source rse
        pin_proc(
            "CREATE PROCEDURE QB5 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, SUM(ID) FROM T WHERE ID > 0 GROUP BY A INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A0154004731170002494415080000000000FF4E01170001414D02000000170001410100561700024944FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // HAVING is the OUTER rse's boolean over blr_fid slots: a
        // fresh aggregate APPENDS a map slot...
        pin_proc(
            "CREATE PROCEDURE QA5 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, MAX(ID) FROM T GROUP BY A HAVING COUNT(*) > 1 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A015400FF4E01170001414D0300000017000141010054170002494402005347311801020015080001000000FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ...while a structurally EQUAL one REUSES the select-list's
        // slot (probed: fid 1,1 - no third map entry)
        pin_proc(
            "CREATE PROCEDURE QB2 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A HAVING COUNT(*) > 1 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A015400FF4E01170001414D020000001700014101005347311801010015080001000000FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // a group-key column in HAVING becomes ITS slot's fid
        pin_proc(
            "CREATE PROCEDURE QB3 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A HAVING A > 0 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A015400FF4E01170001414D020000001700014101005347311801000015080000000000FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ORDER BY over an aggregate sorts fids
        pin_proc(
            "CREATE PROCEDURE QA8 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, SUM(ID) FROM T GROUP BY A ORDER BY A DESC INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A015400FF4E01170001414D0200000017000141010056170002494446014918010000FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_nine_input_params_byte_for_byte() {
        // inputs are MESSAGE 0: dsc + null-flag short per parameter,
        // NO EOF slot; the whole loop block sits under blr_receive 0
        // and `:name` compiles to blr_parameter2(0, 2i, 2i+1) used
        // straight as a value - no variable is declared for inputs
        pin_proc(
            "CREATE PROCEDURE QC1 (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A > :I1 INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A015400473117000141290000000100FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // two inputs: slots 0/1 and 2/3
        pin_proc(
            "CREATE PROCEDURE QC2 (I1 INTEGER, I2 VARCHAR(10)) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A > :I1 AND S = :I2 INTO :R1 DO SUSPEND; END",
            "050204000400080007002600000A000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A015400473A31170001412900000001002F17000153290002000300FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // inputs ride inside expressions, beside ORDER BY
        pin_proc(
            "CREATE PROCEDURE QD1 (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A + :I1 > 0 ORDER BY ID INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A01540047312217000141290000000100150800000000004601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // and inside an aggregate's source rse (BETWEEN two inputs)
        pin_proc(
            "CREATE PROCEDURE QD2 (LO INTEGER, HI INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, SUM(ID) FROM T WHERE ID BETWEEN :LO AND :HI GROUP BY A INTO :R1, :R2 DO SUSPEND; END",
            "050204000400080007000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A01540047381700024944290000000100290002000300FF4E01170001414D02000000170001410100561700024944FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_ten_shapes_byte_for_byte() {
        // the SINGULAR form: blr_for over blr_singular(rse), NO label
        // 1; the for's body holds only the assignments and a SUSPEND
        // compiles as a SIBLING send after the for
        pin_proc(
            "CREATE PROCEDURE QE1 RETURNS (R1 INTEGER) AS BEGIN SELECT COUNT(*) FROM T INTO :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202077F43014F0143014A015400FF4E004D0100000053FF0201180100001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QG6 RETURNS (R1 INTEGER) AS BEGIN SELECT ID FROM T WHERE A = 1 INTO :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202077F43014A015400472F1700014115080001000000FF020117000249441A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // without SUSPEND, only the final EOF send remains
        pin_proc(
            "CREATE PROCEDURE QF4 RETURNS (R1 INTEGER) AS BEGIN SELECT MAX(ID) FROM T INTO :R1; END",
            "050204010300080007000700020300000800012D1A00009B11000202077F43014F0143014A015400FF4E004D01000000541700024944FF0201180100001A0000FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // FIRST/SKIP: rse sub-clauses between the streams and the
        // boolean (probed order: stream, FIRST, SKIP, boolean, sort)
        pin_proc(
            "CREATE PROCEDURE QE2 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 5 ID FROM T ORDER BY ID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A01540044150800050000004601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QE3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 5 SKIP 2 ID FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004415080005000000AF15080002000000FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QE4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SKIP 3 ID FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400AF15080003000000FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QF1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 2 ID FROM T WHERE A > 0 ORDER BY ID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004415080002000000473117000141150800000000004601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the DISTINCT aggregate verbs: COUNT/SUM/AVG get their own;
        // MIN(DISTINCT) FOLDS to plain agg_min (byte-identical)
        pin_proc(
            "CREATE PROCEDURE QE5 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(DISTINCT A) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005E17000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QE6 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(DISTINCT A) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005F17000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QF2 RETURNS (R1 NUMERIC(9,2)) AS BEGIN FOR SELECT AVG(DISTINCT A) FROM T INTO :R1 DO SUSPEND; END",
            "05020401030008FE070007000203000008FE012D1A00009B1100020211010743014F0143014A015400FF4E004D010000006017000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QF3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT MIN(DISTINCT A) FROM T INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D010000005517000141FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    /// every expected string read back from RDB$TRIGGER_BLR - the
    /// THIRD oracle, and the leanest wrapper of all
    fn pin_trig(sql: &str, want_hex: &str) {
        assert_eq!(compile_trigger_hex(sql).as_deref(), Some(want_hex), "{sql}");
    }

    #[test]
    fn compiles_slice_eleven_triggers_byte_for_byte() {
        // the wrapper: begin, label 0, DOUBLE begin, statements,
        // three ends, eoc; the header (table, BEFORE/AFTER, event,
        // POSITION) leaves NO trace - catalog data
        pin_trig(
            "CREATE TRIGGER QT_A FOR T BEFORE INSERT AS BEGIN NEW.A = 5; END",
            "050211000202011508000500000017010141FFFFFF4C",
        );
        // OLD is CONTEXT 0, NEW is CONTEXT 1
        pin_trig(
            "CREATE TRIGGER QT_B FOR T BEFORE UPDATE AS BEGIN NEW.A = OLD.A + 1; END",
            "0502110002020122170001411508000100000017010141FFFFFF4C",
        );
        // IF: condition, then-statement, and a bare blr_end in the
        // MISSING else slot
        pin_trig(
            "CREATE TRIGGER QT_C FOR T BEFORE INSERT AS BEGIN IF (NEW.A IS NULL) THEN NEW.A = 0; END",
            "050211000202083D17010141011508000000000017010141FFFFFFFF4C",
        );
        // a present ELSE fills the slot instead
        pin_trig(
            "CREATE TRIGGER QT_D FOR T BEFORE UPDATE AS BEGIN IF (NEW.A > OLD.A) THEN NEW.S = 'up'; ELSE NEW.S = 'down'; END",
            "0502110002020831170101411700014101150F0000020075701701015301150F00000400646F776E17010153FFFFFF4C",
        );
        // statements concatenate inside the double begin
        pin_trig(
            "CREATE TRIGGER QT_E FOR T BEFORE INSERT AS BEGIN NEW.A = 1; NEW.S = 'x'; END",
            "05021100020201150800010000001701014101150F000001007817010153FFFFFF4C",
        );
        // a nested BEGIN..END block is a DOUBLE blr_begin (probed)
        pin_trig(
            "CREATE TRIGGER QT_F FOR T BEFORE INSERT AS BEGIN IF (NEW.A IS NULL) THEN BEGIN NEW.A = 0; NEW.S = 'def'; END END",
            "050211000202083D17010141020201150800000000001701014101150F0000030064656617010153FFFFFFFFFFFF4C",
        );
        // POSITION leaves no trace either
        pin_trig(
            "CREATE TRIGGER QT_G FOR T BEFORE UPDATE POSITION 5 AS BEGIN IF (OLD.S = NEW.S) THEN NEW.A = 9; END",
            "050211000202082F1700015317010153011508000900000017010141FFFFFFFF4C",
        );
        // the converted expression surface rides on trigger fields
        pin_trig(
            "CREATE TRIGGER QT_H FOR T BEFORE INSERT AS BEGIN NEW.S = UPPER(NEW.S); END",
            "05021100020201671701015317010153FFFFFF4C",
        );
        pin_trig(
            "CREATE TRIGGER QT_I FOR T BEFORE INSERT AS BEGIN IF (NEW.A > 0 AND NEW.S IS NOT NULL) THEN NEW.A = NEW.A * 2; ELSE NEW.A = 0; END",
            "050211000202083A3117010141150800000000003B3D170101530124170101411508000200000017010141011508000000000017010141FFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twelve_dml_byte_for_byte() {
        // INSERT is blr_store(relation, assignments) - no FOR
        // wrapper; the target claims the next context (2 after
        // OLD/NEW) and assignments follow the column list's order
        pin_trig(
            "CREATE TRIGGER QU_A FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 (UID, UA) VALUES (1, 2); END",
            "0502110002020F4A0255320202011508000100000017020355494401150800020000001702025541FFFFFFFF4C",
        );
        // VALUES read OLD/NEW freely
        pin_trig(
            "CREATE TRIGGER QU_B FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 (UID) VALUES (NEW.A); END",
            "0502110002020F4A02553202020117010141170203554944FFFFFFFF4C",
        );
        // DELETE is blr_for over a marks(1,4)-stamped rse, then
        // blr_erase(ctx)
        pin_trig(
            "CREATE TRIGGER QU_C FOR T BEFORE INSERT AS BEGIN DELETE FROM U2 WHERE U2.UID = NEW.A; END",
            "05021100020207D9010443014A02553202472F17020355494417010141FF0502FFFFFF4C",
        );
        pin_trig(
            "CREATE TRIGGER QV_C FOR T BEFORE INSERT AS BEGIN DELETE FROM U2; END",
            "05021100020207D9010443014A02553202FF0502FFFFFF4C",
        );
        // UPDATE: the NEW-record context is allocated BEFORE the rse
        // stream's (modify 3,2 with the rse at 3); SET targets write
        // the new context...
        pin_trig(
            "CREATE TRIGGER QU_D FOR T BEFORE INSERT AS BEGIN UPDATE U2 SET UA = 5 WHERE U2.UID = NEW.A; END",
            "05021100020207D9010443014A02553203472F17030355494417010141FF0A03020201150800050000001702025541FFFFFFFF4C",
        );
        // ...while SET sources and the WHERE read the ORG stream
        // (probed: SET UA = UA + 1 reads ctx 3, writes ctx 2)
        pin_trig(
            "CREATE TRIGGER QV_A FOR T BEFORE INSERT AS BEGIN UPDATE U2 SET UA = UA + 1 WHERE U2.UID = NEW.A; END",
            "05021100020207D9010443014A02553203472F17030355494417010141FF0A03020201221703025541150800010000001702025541FFFFFFFF4C",
        );
        pin_trig(
            "CREATE TRIGGER QV_B FOR T BEFORE INSERT AS BEGIN UPDATE U2 SET UA = 0; END",
            "05021100020207D9010443014A02553203FF0A03020201150800000000001702025541FFFFFFFF4C",
        );
        pin_trig(
            "CREATE TRIGGER QV_D FOR T BEFORE INSERT AS BEGIN UPDATE U2 SET UA = 1, UID = 2 WHERE U2.ID = 3; END",
            "05021100020207D9010443014A02553203472F170302494415080003000000FF0A030202011508000100000017020255410115080002000000170203554944FFFFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirteen_psql_byte_for_byte() {
        // DECLARE: the declares sit between the outer begin and
        // label 0; a bare name resolves to the variable; assignment
        // targets blr_variable
        pin_trig(
            "CREATE TRIGGER QW_A FOR T BEFORE INSERT AS DECLARE V1 INTEGER; BEGIN V1 = 5; NEW.A = V1; END",
            "05020300000800012D1A00001100020201150800050000001A0000011A000017010141FFFFFF4C",
        );
        // an initialiser REPLACES the null-init
        pin_trig(
            "CREATE TRIGGER QW_B FOR T BEFORE INSERT AS DECLARE V1 INTEGER = 0; BEGIN NEW.A = V1; END",
            "0502030000080001150800000000001A000011000202011A000017010141FFFFFF4C",
        );
        // with several: TRIGGERS group ALL declares first, THEN the
        // inits - unlike procedures, which interleave (both probed)
        pin_trig(
            "CREATE TRIGGER QX_C FOR T BEFORE INSERT AS DECLARE VARIABLE V1 INTEGER; DECLARE V2 SMALLINT = 1; BEGIN WHILE (V2 < 3) DO BEGIN V1 = V2; V2 = V2 + 1; END NEW.A = V1; END",
            "050203000008000301000700012D1A000001150800010000001A0100110002021101090208331A0100150800030000000202011A01001A000001221A0100150800010000001A0100FFFF1201FF011A000017010141FFFFFF4C",
        );
        // WHILE: blr_label N, blr_loop, begin, blr_if(cond, body,
        // blr_leave N), end - labels number in ENCOUNTER order after
        // the wrapper's 0
        pin_trig(
            "CREATE TRIGGER QW_C FOR T BEFORE INSERT AS DECLARE V1 INTEGER; BEGIN V1 = 0; WHILE (V1 < 5) DO V1 = V1 + 1; NEW.A = V1; END",
            "05020300000800012D1A00001100020201150800000000001A00001101090208331A00001508000500000001221A0000150800010000001A00001201FF011A000017010141FFFFFF4C",
        );
        // labelled CONTINUE / LEAVE naming an OUTER loop: from the inner
        // loop (label 2) they target OUTR (label 1) - blr_continue_loop 1,
        // blr_leave 1 (probed, byte-identical to the engine)
        pin_trig(
            "CREATE TRIGGER TOL FOR T BEFORE INSERT AS DECLARE I INTEGER; DECLARE J INTEGER; BEGIN I=0; OUTR: WHILE (I<3) DO BEGIN I=I+1; J=0; WHILE (J<3) DO BEGIN J=J+1; IF (J=2) THEN CONTINUE OUTR; IF (I=3) THEN LEAVE OUTR; END END NEW.A=I; END",
            "050203000008000301000800012D1A0000012D1A01001100020201150800000000001A00001101090208331A000015080003000000020201221A0000150800010000001A000001150800000000001A01001102090208331A010015080003000000020201221A0100150800010000001A0100082F1A010015080002000000C501FF082F1A0000150800030000001201FFFFFF1202FFFFFF1201FF011A000017010141FFFFFF4C",
        );
        // WHILE with CONTINUE and a bare LEAVE - blr_continue_loop 1 and
        // blr_leave 1 both target the loop label (probed)
        pin_trig(
            "CREATE TRIGGER QW_LC FOR T BEFORE INSERT AS DECLARE V1 INTEGER; BEGIN V1 = 0; WHILE (V1 < 5) DO BEGIN V1 = V1 + 1; IF (V1 = 2) THEN CONTINUE; IF (V1 = 4) THEN LEAVE; END NEW.A = V1; END",
            "05020300000800012D1A00001100020201150800000000001A00001101090208331A000015080005000000020201221A0000150800010000001A0000082F1A000015080002000000C501FF082F1A0000150800040000001201FFFFFF1201FF011A000017010141FFFFFF4C",
        );
        // nested WHILEs: outer label 1, inner label 2, leaves match
        pin_trig(
            "CREATE TRIGGER QX_D FOR T BEFORE INSERT AS DECLARE V1 INTEGER = 0; BEGIN WHILE (V1 < 3) DO WHILE (V1 < 2) DO V1 = V1 + 1; END",
            "0502030000080001150800000000001A0000110002021101090208331A0000150800030000001102090208331A00001508000200000001221A0000150800010000001A00001202FF1201FFFFFFFF4C",
        );
        // INSERTING/UPDATING/DELETING: eql(blr_internal_info(6),
        // 1/2/3); the multi-event header still leaves no trace
        pin_trig(
            "CREATE TRIGGER QW_D FOR T BEFORE INSERT OR UPDATE AS BEGIN IF (INSERTING) THEN NEW.A = 1; ELSE NEW.A = 2; END",
            "050211000202082FB11508000600000015080001000000011508000100000017010141011508000200000017010141FFFFFF4C",
        );
        pin_trig(
            "CREATE TRIGGER QX_A FOR T BEFORE INSERT OR UPDATE OR DELETE AS BEGIN IF (UPDATING) THEN NEW.A = 2; IF (DELETING) THEN NEW.A = 3; END",
            "050211000202082FB11508000600000015080002000000011508000200000017010141FF082FB11508000600000015080003000000011508000300000017010141FFFFFFFF4C",
        );
        // NOT INSERTING folds to neq - the inverse-comparison law
        // reaches the trigger predicates
        pin_trig(
            "CREATE TRIGGER QX_B FOR T BEFORE INSERT AS BEGIN IF (NOT INSERTING) THEN NEW.A = 0; END",
            "0502110002020830B11508000600000015080001000000011508000000000017010141FFFFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_fourteen_general_bodies_byte_for_byte() {
        // output parameters ARE variables: R1 = 5; assigns var 0, and
        // SUSPEND anywhere is the row send
        pin_proc(
            "CREATE PROCEDURE QH1 RETURNS (R1 INTEGER) AS BEGIN R1 = 5; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020201150800050000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // locals continue the variable numbering after the outputs,
        // INTERLEAVED declare/init (procedure style); WHILE works in
        // procedure bodies with the same label machinery
        pin_proc(
            "CREATE PROCEDURE QH2 RETURNS (R1 INTEGER) AS DECLARE V1 INTEGER = 0; BEGIN WHILE (V1 < 5) DO V1 = V1 + 1; R1 = V1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000030100080001150800000000001A01009B110002021101090208331A01001508000500000001221A0100150800010000001A01001201FF011A01001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // bare input parameters resolve outside stream scopes:
        // IF (I1 > 0) compiles the message reference
        pin_proc(
            "CREATE PROCEDURE QH3 (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN IF (I1 > 0) THEN R1 = 1; ELSE R1 = 0; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020208312900000001001508000000000001150800010000001A000001150800000000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // a procedure with NO outputs: message 1 is the one-slot EOF
        // form and the final send carries only the flag; DML works in
        // procedure bodies at context 0 with :params
        pin_proc(
            "CREATE PROCEDURE QH4 (I1 INTEGER) AS BEGIN DELETE FROM U2 WHERE U2.UID = :I1; END",
            "050204000200080007000401010007000C00029B1100020207D9010443014A02553200472F170003554944290000000100FF0500FFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_fifteen_calls_byte_for_byte() {
        // EXECUTE PROCEDURE: blr_exec_proc - counted name, u16 input
        // count + values, u16 output count (+ variable targets)
        pin_proc(
            "CREATE PROCEDURE QI1 AS BEGIN EXECUTE PROCEDURE QI0(5); END",
            "0502040101000700029B1100020278035149300100150800050000000000FFFFFF0E010201150700000019010000FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QJ2 AS BEGIN EXECUTE PROCEDURE QJ0; END",
            "0502040101000700029B110002027803514A3000000000FFFFFF0E010201150700000019010000FFFF4C",
        );
        // RETURNING_VALUES fills the output slots with variables
        pin_proc(
            "CREATE PROCEDURE QJ3 RETURNS (R1 INTEGER) AS BEGIN EXECUTE PROCEDURE QJ1 RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002027803514A31000001001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // EXCEPTION name: blr_abort, 2, counted name
        pin_proc(
            "CREATE PROCEDURE QI2 RETURNS (R1 INTEGER) AS BEGIN IF (R1 IS NULL) THEN EXCEPTION QEX1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202083D1A000080020451455831FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // EXIT is blr_leave 0 - it leaves the WRAPPER's label
        pin_proc(
            "CREATE PROCEDURE QI3 RETURNS (R1 INTEGER) AS BEGIN R1 = 1; IF (R1 > 0) THEN EXIT; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020201150800010000001A000008311A0000150800000000001200FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QJ0 AS BEGIN EXIT; END",
            "0502040101000700029B110002021200FFFFFF0E010201150700000019010000FFFF4C",
        );
        // FOR SELECT inside a TRIGGER: the stream takes the next
        // context after OLD/NEW (2), labels share the numbering, and
        // the DO body is any statement - no row-send
        pin_trig(
            "CREATE TRIGGER QI_T FOR T BEFORE INSERT AS DECLARE V1 INTEGER; BEGIN FOR SELECT UA FROM U2 INTO :V1 DO NEW.A = V1; END",
            "05020300000800012D1A00001100020211010743014A02553202FF020117020255411A0000011A000017010141FFFFFFFF4C",
        );
    }

    /// oracle number FOUR: RDB$RELATION_FIELDS.RDB$DEFAULT_VALUE and
    /// RDB$FIELDS.RDB$COMPUTED_BLR - the smallest wrappers of all
    fn pin_default(sql: &str, want_hex: &str) {
        assert_eq!(compile_default_hex(sql).as_deref(), Some(want_hex), "{sql}");
    }
    fn pin_computed(sql: &str, want_hex: &str) {
        assert_eq!(compile_computed_hex(sql).as_deref(), Some(want_hex), "{sql}");
    }

    #[test]
    fn compiles_slice_sixteen_field_blr_byte_for_byte() {
        // a DEFAULT is blr_version5, the value, blr_eoc - nothing else
        pin_default("DEFAULT 0", "05150800000000004C");
        pin_default("DEFAULT 'none'", "05150F000004006E6F6E654C");
        pin_default("DEFAULT NULL", "052D4C");
        // the sign still folds into the literal
        pin_default("DEFAULT -5", "05150800FBFFFFFF4C");
        // the niladic context functions, one verb each
        pin_default("DEFAULT CURRENT_DATE", "05A04C");
        pin_default("DEFAULT CURRENT_TIME", "05A24C");
        pin_default("DEFAULT CURRENT_TIMESTAMP", "05A14C");
        // COMPUTED BY: the expression with the table's columns as
        // bare fields at CONTEXT 0
        pin_computed("COMPUTED BY (C1 + C6)", "0522170002433117000243364C");
        pin_computed("COMPUTED BY (UPPER(C2))", "056717000243324C");
        pin_computed(
            "COMPUTED BY (C1 * 2 + 1)",
            "052224170002433115080002000000150800010000004C",
        );
        // the whole expression surface rides inside - a cast-wrapped
        // CASE, byte-identical to the probe
        pin_computed(
            "COMPUTED BY (CASE WHEN C3 > 0 THEN 1 ELSE 0 END)",
            "05830800693117000243331508000000000015080001000000150800000000004C",
        );
    }

    #[test]
    fn compiles_slice_seventeen_constraints_byte_for_byte() {
        // a CHECK constraint is the engine's own system trigger:
        // begin, if over the NEGATED condition (CHECK (A < B) stores
        // blr_geq - the NOT fold again), abort with blr_gds_code
        // 'check_constraint', bare-end else, end, eoc; fields at
        // CONTEXT 1 (the NEW record)
        assert_eq!(
            compile_check_hex("CHECK (A < B)").as_deref(),
            Some("05020832170101411701014202800010636865636B5F636F6E73747261696E74FFFFFF4C"),
        );
        // a domain default is the same minimal frame as a column's,
        // read from RDB$FIELDS instead (probed: DEFAULT 7)
        pin_default("DEFAULT 7", "05150800070000004C");
        // an expression index is the same frame as a computed column,
        // read from RDB$INDICES.RDB$EXPRESSION_BLR (probed)
        pin_computed("COMPUTED BY (UPPER(S))", "0567170001534C");
        pin_computed("COMPUTED BY (A + B)", "052217000141170001424C");
    }

    #[test]
    fn compiles_slice_eighteen_shapes_byte_for_byte() {
        // a DOMAIN's CHECK is RDB$VALIDATION_BLR - the RAW boolean
        // (NOT negated, unlike a table CHECK's system trigger), with
        // VALUE compiling to blr_fid(0, 0)
        assert_eq!(
            compile_validation_hex("CHECK (VALUE > 0)").as_deref(),
            Some("053118000000150800000000004C"),
        );
        assert_eq!(
            compile_validation_hex(
                "CHECK (VALUE IS NOT NULL AND CHAR_LENGTH(VALUE) > 2)"
            )
            .as_deref(),
            Some("053A3B3D1800000031B60118000000150800020000004C"),
        );
        // GEN_ID(seq, inc): blr_gen_id, counted name, increment value
        pin_trig(
            "CREATE TRIGGER QGT_A FOR T BEFORE INSERT AS BEGIN NEW.A = GEN_ID(QSEQ1, 1); END",
            "05021100020201650551534551311508000100000017010141FFFFFF4C",
        );
        // NEXT VALUE FOR: blr_gen_id2, the name alone
        pin_trig(
            "CREATE TRIGGER QGT_B FOR T BEFORE INSERT AS BEGIN NEW.A = NEXT VALUE FOR QSEQ1; END",
            "05021100020201D205515345513117010141FFFFFF4C",
        );
        // POST_EVENT: blr_post + the event-name value
        pin_trig(
            "CREATE TRIGGER QGT_C FOR T AFTER INSERT AS BEGIN POST_EVENT 'row_added'; END",
            "05021100020214150F00000900726F775F6164646564FFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_nineteen_handlers_byte_for_byte() {
        // a BEGIN..END with WHEN becomes blr_block: a begin with the
        // guarded statements, blr_error_handler + u16 code count +
        // the code, the handler STATEMENT, blr_end. WHEN ANY is
        // blr_default_code
        pin_proc(
            "CREATE PROCEDURE QK1 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1 / 0; WHEN ANY DO R1 = -1; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002028102012515080001000000150800000000001A0000FF8201000401150800FFFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // WHEN EXCEPTION <name>: code 9, 0, counted name
        pin_proc(
            "CREATE PROCEDURE QK2 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN EXCEPTION QEX1 DO R1 = -2; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF8201000900045145583101150800FEFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // WHEN GDSCODE <name>: code 0, counted UPPERCASED name
        pin_proc(
            "CREATE PROCEDURE QL4 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN GDSCODE arith_except DO R1 = -3; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF820100000C41524954485F45584345505401150800FDFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // handlers work in triggers too - same blr_block shape
        pin_trig(
            "CREATE TRIGGER QM3 FOR T BEFORE INSERT AS BEGIN BEGIN NEW.A = 1; WHEN ANY DO NEW.A = -1; END END",
            "0502110002028102011508000100000017010141FF8201000401150800FFFFFFFF17010141FFFFFFFF4C",
        );
        // ROW_COUNT is blr_internal_info(5) - beside trigger-action's
        // 6, one family of context codes
        pin_proc(
            "CREATE PROCEDURE QK3 RETURNS (R1 INTEGER) AS BEGIN DELETE FROM U2 WHERE U2.UID = 0; R1 = ROW_COUNT; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020207D9010443014A02553200472F17000355494415080000000000FF050001B1150800050000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // and a PLAIN nested block in a procedure stays a DOUBLE
        // begin - blr_block belongs to handler-carrying blocks only
        pin_proc(
            "CREATE PROCEDURE QM1 (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN IF (I1 > 0) THEN BEGIN R1 = 1; R1 = R1 + 1; END SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202083129000000010015080000000000020201150800010000001A000001221A0000150800010000001A0000FFFFFF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_shapes_byte_for_byte() {
        // UPDATE OR INSERT: a begin holding a modify-loop (blr_equiv
        // on the MATCHING column) and a row_count==0-guarded store;
        // contexts allocated store(0), modify-new(1), rse-org(2) IN
        // THAT ORDER
        pin_proc(
            "CREATE PROCEDURE QL1 (I1 INTEGER) AS BEGIN UPDATE OR INSERT INTO U2 (UID, UA) VALUES (:I1, 0) MATCHING (UID); END",
            "050204000200080007000401010007000C00029B110002020207D9010443014A02553202472E170203554944290000000100FF0A0201020129000000010017010355494401150800000000001701025541FF082FB115080005000000150800000000000F4A02553200020129000000010017000355494401150800000000001700025541FFFFFFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // CURRENT_CONNECTION / CURRENT_TRANSACTION: internal_info
        // codes 1 and 2 - one family with ROW_COUNT's 5 and the
        // trigger-action 6
        pin_proc(
            "CREATE PROCEDURE QN1 RETURNS (R1 BIGINT) AS BEGIN R1 = CURRENT_CONNECTION; SUSPEND; END",
            "050204010300100007000700020300001000012D1A00009B1100020201B1150800010000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QN2 RETURNS (R1 BIGINT) AS BEGIN R1 = CURRENT_TRANSACTION; SUSPEND; END",
            "050204010300100007000700020300001000012D1A00009B1100020201B1150800020000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // MULTIPLE handlers: one error-handler section per WHEN,
        // sequential (flip ten's probe)
        pin_proc(
            "CREATE PROCEDURE QN3 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN EXCEPTION QEX1 DO R1 = -1; WHEN ANY DO R1 = -2; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF8201000900045145583101150800FFFFFFFF1A00008201000401150800FEFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // a BLOCK as a handler's body nests blr_block AGAIN with no
        // handler section of its own (flip eleven's probe)
        pin_proc(
            "CREATE PROCEDURE QN4 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN ANY DO BEGIN R1 = -1; END END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF82010004810201150800FFFFFFFF1A0000FFFFFF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_one_shapes_byte_for_byte() {
        // IN AUTONOMOUS TRANSACTION DO: blr_auto_trans, sub-code 0,
        // the statement
        pin_proc(
            "CREATE PROCEDURE QO1 AS BEGIN IN AUTONOMOUS TRANSACTION DO INSERT INTO U2 (UID) VALUES (1); END",
            "0502040101000700029B11000202BB000F4A02553200020115080001000000170003554944FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // multi-column MATCHING: one blr_equiv per column, left-nested
        // under blr_and (flip of the single-column restriction)
        pin_proc(
            "CREATE PROCEDURE QO2 (I1 INTEGER, I2 INTEGER) AS BEGIN UPDATE OR INSERT INTO U2 (UID, UA) VALUES (:I1, :I2) MATCHING (UID, UA); END",
            "05020400040008000700080007000401010007000C00029B110002020207D9010443014A02553202473A2E1702035549442900000001002E1702025541290002000300FF0A02010201290000000100170103554944012900020003001701025541FF082FB115080005000000150800000000000F4A025532000201290000000100170003554944012900020003001700025541FFFFFFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // WHEN SQLCODE <n>: code 1 + i16 little-endian (flip twelve)
        pin_proc(
            "CREATE PROCEDURE QO3 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN SQLCODE -802 DO R1 = -1; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF82010001DEFC01150800FFFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // CURSORS: blr_dcl_cursor(num, rse, out-count, derived_exprs)
        // - the cursor NAME rides in the relation2 alias like a
        // derived table's; OPEN/CLOSE/FETCH are blr_cursor_stmt
        // sub-verbs 0/1/2, fetch carrying its into-assignments
        pin_proc(
            "CREATE PROCEDURE QO4 RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT ID FROM T); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A600004301920154112243312220225055424C4943222E22542200FF0100BF010017000249449B11000202A7000000A7020000020117000249441A0000FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn declaration_order_law() {
        // a variable's INIT is DEFERRED past cursor declarations that
        // follow it, flushing before the next variable's declare or
        // at the section end (probed three ways)
        pin_proc(
            "CREATE PROCEDURE QP_A RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT ID FROM T); DECLARE V1 INTEGER; BEGIN OPEN CX; FETCH CX INTO :V1; R1 = V1; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A600004301920154112243582220225055424C4943222E22542200FF0100BF010017000249440301000800012D1A01009B11000202A7000000A7020000020117000249441A0100FF011A01001A0000A70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        pin_proc(
            "CREATE PROCEDURE QP_B RETURNS (R1 INTEGER) AS DECLARE V1 INTEGER = 5; DECLARE CX CURSOR FOR (SELECT ID FROM T); BEGIN OPEN CX; FETCH CX INTO :V1; R1 = V1; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A00000301000800A600004301920154112243582220225055424C4943222E22542200FF0100BF0100170002494401150800050000001A01009B11000202A7000000A7020000020117000249441A0100FF011A01001A0000A70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_two_shapes_byte_for_byte() {
        // WHEN SQLSTATE '<s>': handler code 8 + counted string (flip
        // thirteen)
        pin_proc(
            "CREATE PROCEDURE QQ1 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN SQLSTATE '22012' DO R1 = -1; END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF8201000805323230313201150800FFFFFFFF1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // a handler's block body carrying its OWN handlers: blr_block
        // nests again WITH its error-handler section (flip fourteen)
        pin_proc(
            "CREATE PROCEDURE QQ2 RETURNS (R1 INTEGER) AS BEGIN BEGIN R1 = 1; WHEN ANY DO BEGIN R1 = 2; WHEN GDSCODE arith_except DO R1 = 3; END END SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202810201150800010000001A0000FF82010004810201150800020000001A0000FF820100000C41524954485F45584345505401150800030000001A0000FFFF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // a cursor over an ALIASED table: the relation2 alias string
        // becomes "C1" "A" - cursor name + table alias - and
        // qualified columns resolve to the one stream (flip fifteen)
        pin_proc(
            "CREATE PROCEDURE QQ3 RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT A.ID FROM T A WHERE A.ID > 0 ORDER BY A.ID DESC); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A6000043019201540822433122202241220047311700024944150800000000004601491700024944FF0100BF010017000249449B11000202A7000000A7020000020117000249441A0000FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // an AGGREGATE cursor: blr_aggregate at ctx+1 (a second
        // stream slot), group_by + map inside the dcl_cursor rse,
        // outputs and fetch-sources as BARE blr_fid slots - no
        // blr_derived_expr wrapper (flip sixteen)
        pin_proc(
            "CREATE PROCEDURE QQ4 RETURNS (R1 INTEGER, R2 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT UID, SUM(UA) AS S FROM U2 GROUP BY UID); BEGIN OPEN C1; FETCH C1 INTO :R1, :R2; CLOSE C1; SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A0100A6000043014F01430192025532122243312220225055424C4943222E2255322200FF4E011700035549444D020000001700035549440100561700025541FF020018010000180101009B11000202A7000000A70200000201180100001A000001180101001A0100FFA70100000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // DELETE ... WHERE CURRENT OF: blr_erase at the CURSOR's own
        // context, blr_marks(1, 1) TRAILING the erase where a DML
        // loop's marks lead its rse; the INTO-less FETCH that
        // positions it carries an empty begin/end
        pin_proc(
            "CREATE PROCEDURE QQ5 AS DECLARE C1 CURSOR FOR (SELECT ID FROM T); BEGIN OPEN C1; FETCH C1; DELETE FROM T WHERE CURRENT OF C1; CLOSE C1; END",
            "050204010100070002A600004301920154112243312220225055424C4943222E22542200FF0100BF010017000249449B11000202A7000000A702000002FF0500D90101A7010000FFFFFF0E010201150700000019010000FFFF4C",
        );
        // UPDATE ... WHERE CURRENT OF: blr_modify from the cursor's
        // context to ONE fresh slot, marks(1, 1), the assignments
        pin_proc(
            "CREATE PROCEDURE QQ6 (P1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT UID, UA FROM U2); BEGIN OPEN C1; FETCH C1; UPDATE U2 SET UA = :P1 WHERE CURRENT OF C1; CLOSE C1; END",
            "050204000200080007000401010007000C0002A60000430192025532122243312220225055424C4943222E2255322200FF0200BF0100170003554944BF010017000255419B11000202A7000000A702000002FF0A0001D9010102012900000001001701025541FFA7010000FFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_three_shapes_byte_for_byte() {
        // MERGE, both branches: for(marks(1,6), rse(join2(source@0,
        // target@1, LEFT, ON), or(not(missing(dbkey tgt)),
        // missing(dbkey tgt))), if(missing, store@3, modify 1->2
        // marks(1,2))) - the INSERT half branches on the LEFT join's
        // missing target dbkey (flip seventeen)
        pin_proc(
            "CREATE PROCEDURE QR1 (P1 INTEGER) AS BEGIN MERGE INTO U2 USING T ON U2.UID = T.ID WHEN MATCHED THEN UPDATE SET UA = :P1 WHEN NOT MATCHED THEN INSERT (UID, UA) VALUES (T.ID, 0); END",
            "050204000200080007000401010007000C00029B1100020207D90106430177024A0154004A025532015001472F1701035549441700024944FF47393B3D16013D1601FF083D16010F4A025532030201170002494417030355494401150800000000001703025541FF0A0102D9010202012900000001001702025541FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // matched-only MERGE: an INNER join (no join_type), NO rse
        // boolean, if(not(missing), erase(tgt) marks(1,2), bare end)
        pin_proc(
            "CREATE PROCEDURE QR2 AS BEGIN MERGE INTO U2 USING T ON U2.UID = T.ID WHEN MATCHED THEN DELETE; END",
            "0502040101000700029B1100020207D90106430177024A0154004A02553201472F1701035549441700024944FFFF083B3D16010501D90102FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // insert-only MERGE with aliases: LEFT join, rse boolean =
        // missing alone, store re-emits the ALIASED target at its
        // own context (2 - no modify branch to claim it first)
        pin_proc(
            "CREATE PROCEDURE QR3 AS BEGIN MERGE INTO U2 B USING T A ON B.UID = A.ID WHEN NOT MATCHED THEN INSERT (UID) VALUES (A.ID); END",
            "0502040101000700029B1100020207D901064301770292015403224122009202553203224222015001472F1701035549441700024944FF473D1601FF083D16010F92025532032242220202011700024944170203554944FFFFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // FOR SELECT ... AS CURSOR: the name rides the relation2
        // alias like a DECLAREd cursor's, into-assign sources wrap
        // in blr_derived_expr, positioned DML hits the FOR's context
        // (flip eighteen)
        pin_proc(
            "CREATE PROCEDURE QR4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T INTO :R1 AS CURSOR CU DO BEGIN UPDATE T SET ID = ID + 1 WHERE CURRENT OF CU; SUSPEND; END END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301920154112243552220225055424C4943222E22542200FF0201BF010017000249441A000002020A0001D901010201221700024944150800010000001701024944FF0E0102011A000029010000010001150700010019010200FFFFFFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the INTO-less AS CURSOR loop: no assignments at all in the
        // body begin, just the positioned statement
        pin_proc(
            "CREATE PROCEDURE QR5 AS BEGIN FOR SELECT ID FROM T WHERE ID < 0 AS CURSOR CU DO DELETE FROM T WHERE CURRENT OF CU; END",
            "0502040101000700029B110002021101074301920154112243552220225055424C4943222E225422004733170002494415080000000000FF020500D90101FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // cursors in TRIGGERS: the declaration keeps its SOURCE slot
        // among the grouped declares (trigger flavor of the deferral
        // law), the cursor numbering past OLD/NEW (flip nineteen)
        pin_trig(
            "CREATE TRIGGER TRQ6 FOR U2 BEFORE UPDATE AS DECLARE CX CURSOR FOR (SELECT ID FROM T ORDER BY ID DESC); DECLARE V1 INTEGER; BEGIN OPEN CX; FETCH CX INTO :V1; CLOSE CX; NEW.UA = V1; END",
            "0502A600004301920154112243582220225055424C4943222E225422024601491702024944FF0100BF010217020249440300000800012D1A000011000202A7000000A7020000020117020249441A0000FFA7010000011A00001701025541FFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_four_shapes_byte_for_byte() {
        // conditional MERGE branches: WHEN [NOT] MATCHED AND <cond>
        // joins the rse boolean's branch term - and(not(missing),
        // cond) / and(missing, cond) - and wraps the action in
        // if(cond, action, bare end) (flip twenty)
        pin_proc(
            "CREATE PROCEDURE QS1 (P1 INTEGER) AS BEGIN MERGE INTO U2 USING T ON U2.UID = T.ID WHEN MATCHED AND U2.UA > :P1 THEN DELETE WHEN NOT MATCHED AND T.ID > 0 THEN INSERT (UID) VALUES (T.ID); END",
            "050204000200080007000401010007000C00029B1100020207D90106430177024A0154004A025532015001472F1701035549441700024944FF47393A3B3D16013117010255412900000001003A3D160131170002494415080000000000FF083D160108311700024944150800000000000F4A0255320202011700024944170203554944FFFF083117010255412900000001000501D90102FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // SCROLL cursors: blr_scrollable before the dcl_cursor rse;
        // FETCH <direction> FROM = cursor_stmt sub-verb 3 + direction
        // byte (0 next / 1 prior / 2 first / 3 last / 4 absolute /
        // 5 relative) + the offset value - blr_null unless
        // ABSOLUTE/RELATIVE (flip twenty-one)
        pin_proc(
            "CREATE PROCEDURE QS2 RETURNS (R1 INTEGER) AS DECLARE CX SCROLL CURSOR FOR (SELECT UID FROM U2); BEGIN OPEN CX; FETCH LAST FROM CX INTO :R1; FETCH RELATIVE -3 FROM CX INTO :R1; FETCH NEXT FROM CX INTO :R1; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A600006D430192025532122243582220225055424C4943222E2255322200FF0100BF01001700035549449B11000202A7000000A7030000032D02011700035549441A0000FFA703000005150800FDFFFFFF02011700035549441A0000FFA7030000002D02011700035549441A0000FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // INSERT ... RETURNING INTO: blr_store2 with a second begin
        // of field-to-variable assigns at the store's context
        pin_proc(
            "CREATE PROCEDURE QS3 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN INSERT INTO U2 (UID, UA) VALUES (:P1, 5) RETURNING UID, UA INTO :R1, :R2; SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B11000202134A02553200020129000000010017000355494401150800050000001700025541FF02011700035549441A00000117000255411A0100FF0E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // UPDATE ... RETURNING INTO: blr_modify2 under a SINGULAR
        // rse, the returning assigns reading the NEW record
        pin_proc(
            "CREATE PROCEDURE QS4 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN UPDATE U2 SET UA = UA * 2 WHERE U2.UID = :P1 RETURNING UA INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020207D901047F43014A02553201472F170103554944290000000100FFAC01000201241701025541150800020000001700025541FF020117000255411A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // DELETE ... RETURNING INTO: NO erase2 - a begin holding the
        // returning assigns then the PLAIN erase, under a singular
        // rse; the values read the erased stream
        pin_proc(
            "CREATE PROCEDURE QS5 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN DELETE FROM U2 WHERE U2.UID = :P1 RETURNING UA INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020207D901047F43014A02553200472F170003554944290000000100FF02020117000255411A0000FF0500FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // EXECUTE STATEMENT: plain = blr_exec_sql + the literal;
        // FOR ... INTO ... DO = a labeled blr_exec_into with flag 0,
        // the DO statement, then the variables LAST (flip twenty-two)
        pin_proc(
            "CREATE PROCEDURE QS6 RETURNS (R1 INTEGER) AS BEGIN FOR EXECUTE STATEMENT 'select uid from u2' INTO :R1 DO SUSPEND; EXECUTE STATEMENT 'delete from u2'; END",
            "050204010300080007000700020300000800012D1A00009B110002021101A40100150F0000120073656C656374207569642066726F6D207532000E0102011A000029010000010001150700010019010200FF1A0000B0150F00000E0064656C6574652066726F6D207532FFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_five_shapes_byte_for_byte() {
        // multi-branch MERGE: branches of one kind form an if-else
        // CHAIN in SQL order, each conditional branch if(cond,
        // action, <next>), an unconditional LAST filling the else;
        // the rse boolean ORs kind-terms built from or-chains of the
        // branch conds; contexts allocate BY KIND in branch order
        // (flip twenty-three - slice 23/24's multi-branch refusal)
        pin_proc(
            "CREATE PROCEDURE QT1 (P1 INTEGER, P2 INTEGER) AS BEGIN MERGE INTO U2 USING T ON U2.UID = T.ID WHEN MATCHED AND U2.UA > :P1 THEN UPDATE SET UA = :P2 WHEN MATCHED AND U2.UA < 0 THEN DELETE WHEN NOT MATCHED AND T.ID > 0 THEN INSERT (UID) VALUES (T.ID) WHEN NOT MATCHED THEN INSERT (UID, UA) VALUES (T.ID, :P2); END",
            "05020400040008000700080007000401010007000C00029B1100020207D90106430177024A0154004A025532015001472F1701035549441700024944FF47393A3B3D160139311701025541290000000100331701025541150800000000003D1601FF083D160108311700024944150800000000000F4A0255320302011700024944170303554944FF0F4A0255320402011700024944170403554944012900020003001704025541FF083117010255412900000001000A0102D9010202012900020003001702025541FF08331701025541150800000000000501D90102FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // parameterized EXECUTE STATEMENT ('sql') (vals) INTO: the
        // full blr_exec_stmt with tag-prefixed clauses - in-count,
        // out-count, sql, input values, output variables, blr_end
        // (flip twenty-four)
        pin_proc(
            "CREATE PROCEDURE QT2 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN EXECUTE STATEMENT ('select ua from u2 where uid = ?') (:P1) INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202BD01010002010003150F00001F0073656C6563742075612066726F6D20753220776865726520756964203D203F0B2900000001000D1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the FOR form slots its DO statement under tag 4, BETWEEN
        // the sql and the input values
        pin_proc(
            "CREATE PROCEDURE QT3 (P1 INTEGER, P2 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR EXECUTE STATEMENT ('select uid from u2 where ua between ? and ?') (:P1, :P2) INTO :R1 DO SUSPEND; END",
            "0502040004000800070008000700040103000800070007000C00020300000800012D1A00009B110002021101BD01020002010003150F00002B0073656C656374207569642066726F6D207532207768657265207561206265747765656E203F20616E64203F040E0102011A000029010000010001150700010019010200FF0B2900000001002900020003000D1A0000FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // WITH LOCK: blr_writelock between the stream and the
        // boolean - here in a DECLAREd cursor feeding a positioned
        // UPDATE (flip twenty-five)
        pin_proc(
            "CREATE PROCEDURE QT4 RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2 WHERE UA > 0 WITH LOCK); BEGIN OPEN CX; FETCH CX INTO :R1; UPDATE U2 SET UA = 0 WHERE CURRENT OF CX; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A60000430192025532122243582220225055424C4943222E2255322200B34731170002554115080000000000FF0100BF01001700035549449B11000202A7000000A702000002011700035549441A0000FF0A0001D901010201150800000000001701025541FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and in an AS CURSOR loop's rse, beside its WHERE
        pin_proc(
            "CREATE PROCEDURE QT5 (P1 INTEGER) AS BEGIN FOR SELECT UID FROM U2 WHERE UA < :P1 WITH LOCK AS CURSOR CU DO DELETE FROM U2 WHERE CURRENT OF CU; END",
            "050204000200080007000401010007000C00029B11000202110107430192025532122243552220225055424C4943222E2255322200B347331700025541290000000100FF020500D90101FFFFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn slice_twenty_five_refusals() {
        for sql in [
            // WITH LOCK over an aggregate: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM U2 WITH LOCK INTO :R1 DO SUSPEND; END",
            // WITH LOCK beside ORDER BY: unprobed emission order
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT UID FROM U2 ORDER BY UID WITH LOCK INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn compiles_slice_twenty_six_shapes_byte_for_byte() {
        // DECLARE FUNCTION: blr_subfunc_decl - counted name, type 0,
        // flags, u16-counted param names (the return slot UNNAMED),
        // u32-counted inner body; the call is blr_invoke_function
        // with the sub id clause; RETURN = begin(assign slot 0, the
        // no-EOF send, leave 0) (flip twenty-six)
        pin_proc(
            "CREATE PROCEDURE QU1 RETURNS (R1 INTEGER) AS DECLARE V1 INTEGER = 3; DECLARE FUNCTION TRIPLE (I1 INTEGER) RETURNS INTEGER AS DECLARE M1 INTEGER = 3; BEGIN RETURN I1 * M1; END BEGIN R1 = TRIPLE(V1); SUSPEND; END",
            "050204010300080007000700020300000800012D1A00000301000800CF06545249504C450000010002493100010000006900000005020400020008000700040103000800070007000C00020300000800012D1A0000030200080001150800030000001A02009B110002020201242900000001001A02001A00000E0102011A0000290100000100FF1200FFFFFFFF0E0102011A0000290100000100FFFF4C01150800030000001A01009B1100020201E001040306545249504C45FF0301001A0100FF1A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // DECLARE PROCEDURE with two outputs: blr_subproc_decl with
        // the selectable flag, the invoke_procedure call carrying
        // both output variables (flip twenty-seven)
        pin_proc(
            "CREATE PROCEDURE QU2 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS DECLARE PROCEDURE BOTH2 (X1 INTEGER) RETURNS (O1 INTEGER, O2 INTEGER) AS BEGIN O1 = X1 + 1; O2 = X1 - 1; SUSPEND; END BEGIN EXECUTE PROCEDURE BOTH2(:P1) RETURNING_VALUES :R1, :R2; SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A0100CD05424F54483200010100025831000200024F3100024F3200A10000000502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B110002020122290000000100150800010000001A00000123290000000100150800010000001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C9B11000202E101040305424F544832FF0301002900000001000502001A00001A0100FF0E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // named EXECUTE STATEMENT parameters (tag 12: counted name +
        // value each) beside AS USER (tag 6) - flip twenty-eight
        pin_proc(
            "CREATE PROCEDURE QU3 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN EXECUTE STATEMENT ('select ua from u2 where uid = :id') (id := :P1) AS USER 'SYSDBA' INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202BD01010002010003150F0000210073656C6563742075612066726F6D20753220776865726520756964203D203A696406150F000006005359534442410C0249442900000001000D1A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and in the FOR loop form, the DO statement under tag 4
        pin_proc(
            "CREATE PROCEDURE QU4 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR EXECUTE STATEMENT ('select uid from u2 where ua > :x') (x := :P1) INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B110002021101BD01010002010003150F0000200073656C656374207569642066726F6D207532207768657265207561203E203A78040E0102011A000029010000010001150700010019010200FF0C01582900000001000D1A0000FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // TWO laws in one pin: a SUBROUTINE's inputs RESERVE variable
        // slots (two inputs put the first local at 3) and local
        // declares GROUP with their inits after
        pin_proc(
            "CREATE PROCEDURE QU5 RETURNS (R1 INTEGER) AS DECLARE FUNCTION FX (A1 INTEGER, A2 INTEGER) RETURNS INTEGER AS DECLARE M1 INTEGER = 1; DECLARE M2 INTEGER; BEGIN M2 = A1 + A2 + M1; RETURN M2; END BEGIN R1 = FX(1, 2); SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CF02465800000200024131000241320001000000850000000502040004000800070008000700040103000800070007000C00020300000800012D1A00000303000800030400080001150800010000001A0300012D1A04009B110002020122222900000001002900020003001A03001A040002011A04001A00000E0102011A0000290100000100FF1200FFFFFFFF0E0102011A0000290100000100FFFF4C9B1100020201E0010403024658FF0302001508000100000015080002000000FF1A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the same two laws in a sub-PROCEDURE
        pin_proc(
            "CREATE PROCEDURE QU6 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE SP (X1 INTEGER) RETURNS (O1 INTEGER) AS DECLARE M1 INTEGER = 1; DECLARE M2 INTEGER = 2; BEGIN O1 = X1 + M1 + M2; SUSPEND; END BEGIN EXECUTE PROCEDURE SP(4) RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD02535000010100025831000100024F31008D00000005020400020008000700040103000800070007000C00020300000800012D1A00000302000800030300080001150800010000001A020001150800020000001A03009B110002020122222900000001001A02001A03001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E1010403025350FF030100150800040000000501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the grouping law at TOP LEVEL - the latent divergence this
        // slice's probes exposed: two inited locals emit declare,
        // declare, init, init - NOT interleaved pairs; the outputs
        // above them DO interleave (a different slot kind's rule)
        pin_proc(
            "CREATE PROCEDURE QU7 RETURNS (R1 INTEGER, R2 INTEGER) AS DECLARE M1 INTEGER = 1; DECLARE M2 INTEGER = 2; BEGIN R1 = M1; R2 = M2; SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01000302000800030300080001150800010000001A020001150800020000001A03009B11000202011A02001A0000011A03001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_seven_shapes_byte_for_byte() {
        // streams inside SUBROUTINE bodies: blr_relation3 - counted
        // schema PUBLIC, counted EMPTY package, the name, then the
        // alias slot (a counted empty when relation-plain) - slice
        // 26's refusal flipped (twenty-nine). INSERT:
        pin_proc(
            "CREATE PROCEDURE QV1 (P1 INTEGER) AS DECLARE PROCEDURE LOGIT (X1 INTEGER) AS BEGIN INSERT INTO T (ID) VALUES (:X1); END BEGIN EXECUTE PROCEDURE LOGIT(:P1); END",
            "050204000200080007000401010007000C0002CD054C4F4749540000010002583100000046000000050204000200080007000401010007000C0002110002020F94065055424C4943000154000002012900000001001700024944FFFFFFFF0E010201150700000019010000FFFF4C9B11000202E1010403054C4F474954FF030100290000000100FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // ... a singular SELECT INTO over an aggregate
        pin_proc(
            "CREATE PROCEDURE QV2 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE CNT RETURNS (O1 INTEGER) AS BEGIN SELECT COUNT(*) FROM U2 INTO :O1; END BEGIN EXECUTE PROCEDURE CNT RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD03434E54000000000100024F310063000000050204010300080007000700020300000800012D1A00009B11000202077F43014F01430194065055424C4943000255320000FF4E004D0100000053FF0201180100001A0000FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E101040303434E54FF0501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... DELETE and UPDATE loops - only the stream form changes
        pin_proc(
            "CREATE PROCEDURE QV3 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE SWEEP AS BEGIN DELETE FROM U2 WHERE U2.UA < 0; UPDATE U2 SET UA = 0 WHERE U2.UID = 9; END BEGIN EXECUTE PROCEDURE SWEEP; R1 = 1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD0553574545500000000000007B0000000502040101000700021100020207D90104430194065055424C49430002553200004733170002554115080000000000FF050007D90104430194065055424C4943000255320002472F17020355494415080009000000FF0A02010201150800000000001701025541FFFFFFFF0E010201150700000019010000FFFF4C9B11000202E1010403055357454550FFFF01150800010000001A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... a DECLAREd cursor: relation3 carrying the SAME
        // cursor-name alias string relation2 would
        pin_proc(
            "CREATE PROCEDURE QV5 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE PICK RETURNS (O1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2); BEGIN OPEN CX; FETCH CX INTO :O1; CLOSE CX; END BEGIN EXECUTE PROCEDURE PICK RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD045049434B000000000100024F310082000000050204010300080007000700020300000800012D1A0000A60000430194065055424C494300025532122243582220225055424C4943222E2255322200FF0100BF01001700035549449B11000202A7000000A702000002011700035549441A0000FFA7010000FFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E1010403045049434BFF0501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and an AS CURSOR loop feeding positioned DML
        pin_proc(
            "CREATE PROCEDURE QV6 AS DECLARE PROCEDURE ZAP AS BEGIN FOR SELECT UID FROM U2 WHERE UA < 0 AS CURSOR CU DO DELETE FROM U2 WHERE CURRENT OF CU; END BEGIN EXECUTE PROCEDURE ZAP; END",
            "050204010100070002CD035A41500000000000005B00000005020401010007000211000202110107430194065055424C494300025532122243552220225055424C4943222E22553222004733170002554115080000000000FF020500D90101FFFFFFFF0E010201150700000019010000FFFF4C9B11000202E1010403035A4150FFFFFFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_eight_shapes_byte_for_byte() {
        // ALIASED streams in body statements (flip thirty): FOR
        // SELECT emits relation2 with the quoted alias, qualified
        // refs resolving through the one stream
        pin_proc(
            "CREATE PROCEDURE QX1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT B.UID FROM U2 B WHERE B.UA > 0 ORDER BY B.UID DESC INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743019202553203224222004731170002554115080000000000460149170003554944FF02011700035549441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... aliased UPDATE (the alias on the ORG stream) and DELETE
        pin_proc(
            "CREATE PROCEDURE QX2 (P1 INTEGER, P2 INTEGER) AS BEGIN UPDATE U2 X SET UA = :P2 WHERE X.UID = :P1; DELETE FROM U2 Y WHERE Y.UA < 0; END",
            "05020400040008000700080007000401010007000C00029B1100020207D901044301920255320322582201472F170103554944290000000100FF0A010002012900020003001700025541FF07D9010443019202553203225922024733170202554115080000000000FF0502FFFFFF0E010201150700000019010000FFFF4C",
        );
        // ... and inside a SUBROUTINE: relation3 with the quoted
        // alias in the always-present alias slot (the QV4 law)
        pin_proc(
            "CREATE PROCEDURE QX3 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE PICK RETURNS (O1 INTEGER) AS BEGIN FOR SELECT B.UID FROM U2 B WHERE B.UA > 0 INTO :O1 DO SUSPEND; END BEGIN EXECUTE PROCEDURE PICK RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD045049434B000100000100024F310082000000050204010300080007000700020300000800012D1A00009B11000202110107430194065055424C49430002553203224222004731170002554115080000000000FF02011700035549441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E1010403045049434BFF0501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... an aliased AGGREGATE source with a qualified group key
        pin_proc(
            "CREATE PROCEDURE QX4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM U2 Z GROUP BY Z.UA INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143019202553203225A2200FF4E0117000255414D0100000053FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // SUBROUTINES IN TRIGGER BODIES (flip thirty-one): the
        // declaration takes the same grouped-declare slot cursors do
        pin_trig(
            "CREATE TRIGGER TRS1 FOR T BEFORE INSERT AS DECLARE V1 INTEGER; DECLARE FUNCTION CAP (X1 INTEGER) RETURNS INTEGER AS BEGIN IF (X1 > 100) THEN RETURN 100; RETURN X1; END BEGIN V1 = CAP(NEW.ID); NEW.ID = V1; END",
            "05020300000800CF034341500000010002583100010000008200000005020400020008000700040103000800070007000C00020300000800012D1A00009B110002020831290000000100150800640000000201150800640000001A00000E0102011A0000290100000100FF1200FFFF02012900000001001A00000E0102011A0000290100000100FF1200FFFFFFFF0E0102011A0000290100000100FFFF4C012D1A00001100020201E001040303434150FF0301001701024944FF1A0000011A00001701024944FFFFFF4C",
        );
    }

    #[test]
    fn compiles_slice_twenty_nine_shapes_byte_for_byte() {
        // SUBQUERIES in body statements (flip thirty-two - named
        // unprobed in slice 7): the subquery stream takes the NEXT
        // context id in the statement's numbering, and the enclosing
        // statement's stream stays visible to QUALIFIED names -
        // EXISTS correlated on the FOR's table:
        pin_proc(
            "CREATE PROCEDURE QY1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE WHERE EXISTS (SELECT 1 FROM T WHERE T.ID = EMPLOYEE.EMP_NO) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F59454500473C43014A015401472F1701024944170006454D505F4E4FFFFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... IN (SELECT): the ansi_any double-rse at body numbering
        pin_proc(
            "CREATE PROCEDURE QY2 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE WHERE DEPT_ID IN (SELECT ID FROM T) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F594545004797430143014A015401FF472F170007444550545F49441701024944FFFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... a scalar subselect in an ASSIGNMENT: the subquery
        // claims ctx 0 (no other streams in the statement)
        pin_proc(
            "CREATE PROCEDURE QY5 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN R1 = (SELECT UA FROM U2 WHERE U2.UID = :P1); SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202012B7F43014A02553200472F170003554944290000000100FF17000255412D1A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // an ALIASED stream under AS CURSOR: the cursor name pairs
        // with the ALIAS - "CU" "E" - the DECLARE CURSOR law (flip
        // thirty-three)
        pin_proc(
            "CREATE PROCEDURE QY4 AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE E AS CURSOR CU DO UPDATE EMPLOYEE SET SALARY = 0 WHERE CURRENT OF CU; END",
            "0502040101000700029B1100020211010743019208454D504C4F59454508224355222022452200FF020A0001D9010102011508000000000017010653414C415259FFFFFFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_shapes_byte_for_byte() {
        // AGGREGATE scalar subselects (flip thirty-four): via(
        // singular, rse1(aggregate at the NEXT slot over the inner
        // rse - its WHERE inside - zero group keys, a one-slot map),
        // fid(agg, 0), null)
        pin_proc(
            "CREATE PROCEDURE QY3 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN R1 = (SELECT MAX(ID) FROM T); SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202012B7F43014F0143014A015400FF4E004D01000000541700024944FF180100002D1A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... in a FOR's WHERE comparison: subquery stream at 1 over
        // the FOR's 0, the aggregate claiming 2
        pin_proc(
            "CREATE PROCEDURE QZ2 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE WHERE SALARY > (SELECT AVG(UA) FROM U2 WHERE U2.UID > :P1) INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A08454D504C4F59454500473117000653414C4152592B7F43014F0243014A025532014731170103554944290000000100FF4E004D01000000571701025541FF180200002DFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... COUNT(*) with its WHERE inside the aggregate's rse
        pin_proc(
            "CREATE PROCEDURE QZ3 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN R1 = (SELECT COUNT(*) FROM T WHERE T.ID > :P1); SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202012B7F43014F0143014A01540047311700024944290000000100FF4E004D0100000053FF180100002D1A00000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // EXISTS inside a SUBROUTINE body: relation3 with the empty
        // alias slot on the subquery stream (composition)
        pin_proc(
            "CREATE PROCEDURE QZ5 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE ANYROW RETURNS (O1 INTEGER) AS BEGIN O1 = 0; IF (EXISTS (SELECT 1 FROM T)) THEN O1 = 1; END BEGIN EXECUTE PROCEDURE ANYROW RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD06414E59524F57000000000100024F310062000000050204010300080007000700020300000800012D1A00009B1100020201150800000000001A0000083C430194065055424C49430001540000FF01150800010000001A0000FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E101040306414E59524F57FF0501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_one_shapes_byte_for_byte() {
        // the cursor-alias INFECTION (flip thirty-five - slice 30's
        // guarded law): a subquery stream inside a cursor's rse
        // carries the cursor's concatenated alias
        pin_proc(
            "CREATE PROCEDURE QZ4 RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2 WHERE EXISTS (SELECT 1 FROM T WHERE T.ID = U2.UID)); BEGIN OPEN CX; FETCH CX INTO :R1; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A60000430192025532122243582220225055424C4943222E2255322200473C4301920154112243582220225055424C4943222E22542201472F1701024944170003554944FFFF0100BF01001700035549449B11000202A7000000A702000002011700035549441A0000FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... an ALIASED subquery stream pairs the cursor name with
        // the inner alias - "CX" "X"
        pin_proc(
            "CREATE PROCEDURE RA2 RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2 WHERE EXISTS (SELECT 1 FROM T X WHERE X.ID = U2.UID)); BEGIN OPEN CX; FETCH CX INTO :R1; CLOSE CX; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000A60000430192025532122243582220225055424C4943222E2255322200473C430192015408224358222022582201472F1701024944170003554944FFFF0100BF01001700035549449B11000202A7000000A702000002011700035549441A0000FFA70100000E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... AS CURSOR infects alike
        pin_proc(
            "CREATE PROCEDURE RA3 AS BEGIN FOR SELECT UID FROM U2 WHERE EXISTS (SELECT 1 FROM T WHERE T.ID = U2.UID) AS CURSOR CU DO DELETE FROM U2 WHERE CURRENT OF CU; END",
            "0502040101000700029B11000202110107430192025532122243552220225055424C4943222E2255322200473C4301920154112243552220225055424C4943222E22542201472F1701024944170003554944FFFF020500D90101FFFFFFFF0E010201150700000019010000FFFF4C",
        );
        // ... and in a SUBROUTINE the infected stream is relation3
        // with the cursor string in its alias slot (composition)
        pin_proc(
            "CREATE PROCEDURE RA4 RETURNS (R1 INTEGER) AS DECLARE PROCEDURE PICK RETURNS (O1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2 WHERE EXISTS (SELECT 1 FROM T WHERE T.ID = U2.UID)); BEGIN OPEN CX; FETCH CX INTO :O1; CLOSE CX; END BEGIN EXECUTE PROCEDURE PICK RETURNING_VALUES :R1; SUSPEND; END",
            "050204010300080007000700020300000800012D1A0000CD045049434B000000000100024F3100B2000000050204010300080007000700020300000800012D1A0000A60000430194065055424C494300025532122243582220225055424C4943222E2255322200473C430194065055424C4943000154112243582220225055424C4943222E22542201472F1701024944170003554944FFFF0100BF01001700035549449B11000202A7000000A702000002011700035549441A0000FFA7010000FFFFFF0E0102011A000029010000010001150700000019010200FFFF4C9B11000202E1010403045049434BFF0501001A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // DISTINCT aggregate scalars: the dedicated verbs, contexts
        // continuing across back-to-back statements (flip thirty-six)
        pin_proc(
            "CREATE PROCEDURE RA5 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN R1 = (SELECT COUNT(DISTINCT UA) FROM U2); R2 = (SELECT SUM(DISTINCT ID) FROM T); SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B11000202012B7F43014F0143014A02553200FF4E004D010000005E1700025541FF180100002D1A0000012B7F43014F0343014A015402FF4E004D010000005F1702024944FF180300002D1A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_two_shapes_byte_for_byte() {
        // JOINS in body FOR SELECTs (flip thirty-seven): the view's
        // left-nested chain at body numbering, ON at the join level
        pin_proc(
            "CREATE PROCEDURE RB1 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT E.EMP_NO, X.ID FROM EMPLOYEE E JOIN T X ON E.EMP_NO = X.ID INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B11000202110107430177029208454D504C4F59454503224522009201540322582201472F170006454D505F4E4F1701024944FFFF0201170006454D505F4E4F1A00000117010249441A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... LEFT with the WHERE at the RSE level
        pin_proc(
            "CREATE PROCEDURE RB2 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT E.EMP_NO, X.ID FROM EMPLOYEE E LEFT JOIN T X ON E.EMP_NO = X.ID WHERE E.SALARY > 0 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B11000202110107430177029208454D504C4F594545032245220092015403225822015001472F170006454D505F4E4F1701024944FF473117000653414C41525915080000000000FF0201170006454D505F4E4F1A00000117010249441A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... a three-stream chain: the second join holds the first
        // as its left slot, RIGHT = type 2
        pin_proc(
            "CREATE PROCEDURE RB4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT A.EMP_NO FROM EMPLOYEE A JOIN T B ON A.EMP_NO = B.ID RIGHT JOIN U2 C ON B.ID = C.UID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301770277029208454D504C4F59454503224122009201540322422201472F170006454D505F4E4F1701024944FF9202553203224322025002472F1701024944170203554944FFFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and the SINGULAR select-into over a FULL OUTER join
        pin_proc(
            "CREATE PROCEDURE RB5 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN SELECT X.ID FROM T X FULL OUTER JOIN U2 Y ON X.ID = Y.UID WHERE Y.UA > :P1 INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202077F4301770292015403225822009202553203225922015003472F1700024944170103554944FF47311701025541290000000100FF020117000249441A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // PACKAGED calls (flip thirty-eight): blr_exec_proc2 and
        // blr_function2 - counted package + name, exec_proc-style
        // u16 counts for the procedure, a count BYTE for the function
        pin_proc(
            "CREATE PROCEDURE RB3 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN EXECUTE PROCEDURE PKG1.PADD(:P1) RETURNING_VALUES :R1; R2 = PKG1.FDBL(:P1); SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B11000202C104504B47310450414444010029000000010001001A000001C204504B4731044644424C012900000001001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn slice_thirty_two_refusals() {
        for sql in [
            // a join under AS CURSOR: unprobed
            "CREATE PROCEDURE X AS BEGIN FOR SELECT A.ID FROM T A JOIN U2 B ON A.ID = B.UID AS CURSOR CU DO DELETE FROM T WHERE CURRENT OF CU; END",
            // bare columns across a join need the catalog
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T A JOIN U2 B ON A.ID = B.UID INTO :R1 DO SUSPEND; END",
            // subqueries inside an ON clause: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT A.ID FROM T A JOIN U2 B ON EXISTS (SELECT 1 FROM T) INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn compiles_slice_thirty_three_shapes_byte_for_byte() {
        // AGGREGATES over joins (flip thirty-nine): the join chain
        // sits inside the aggregate's inner rse, the aggregate
        // claiming the slot after ALL the join streams
        pin_proc(
            "CREATE PROCEDURE RC1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM T A JOIN U2 B ON A.ID = B.UID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F02430177029201540322412200920255320322422201472F1700024944170103554944FFFF4E004D0100000053FF0201180200001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... GROUP BY with a qualified key, the WHERE inside the
        // aggregate's inner rse after the join
        pin_proc(
            "CREATE PROCEDURE RC2 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT B.UID, SUM(A.ID) FROM T A JOIN U2 B ON A.ID = B.UID WHERE A.ID > :P1 GROUP BY B.UID INTO :R1, :R2 DO SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B1100020211010743014F02430177029201540322412200920255320322422201472F1700024944170103554944FF47311700024944290000000100FF4E011701035549444D020000001701035549440100561700024944FF0201180200001A000001180201001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // JOINS in cursor declarations (flip forty): BOTH streams
        // carry the cursor pairing, and each output derived_expr
        // wrap names its column's OWN stream
        pin_proc(
            "CREATE PROCEDURE RC3 RETURNS (R1 INTEGER, R2 INTEGER) AS DECLARE CX CURSOR FOR (SELECT A.ID, B.UA FROM T A JOIN U2 B ON A.ID = B.UID); BEGIN OPEN CX; FETCH CX INTO :R1, :R2; CLOSE CX; SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A0100A6000043017702920154082243582220224122009202553208224358222022422201472F1700024944170103554944FFFF0200BF01001700024944BF010117010255419B11000202A7000000A7020000020117000249441A00000117010255411A0100FFA70100000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_four_shapes_byte_for_byte() {
        // WINDOW functions (flip forty-one): blr_window wraps the
        // inner rse; ONE window holds passthrough columns AND an
        // empty-spec OVER () side by side
        pin_proc(
            "CREATE PROCEDURE RD1 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, COUNT(*) OVER () FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF01C4010046004D02000000170003554944010053FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... PARTITION BY: keys as source fields then REMAPPED to
        // the window's own map slots; the partitioned function gets
        // its OWN window beside the passthrough default
        pin_proc(
            "CREATE PROCEDURE RD2 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, SUM(UA) OVER (PARTITION BY UID) FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF02C4010046004D01000000170003554944C402011700035549441802010046004D020000005617000255410100170003554944FF0201180100001A000001180200001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... ROW_NUMBER() OVER (ORDER BY): blr_agg_function with a
        // counted name and zero arguments, the order under the
        // window's sort clause
        pin_proc(
            "CREATE PROCEDURE RD4 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, ROW_NUMBER() OVER (ORDER BY UA DESC) FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF02C4010046004D01000000170003554944C4020046014917000255414D01000000C70A524F575F4E554D42455200FF0201180100001A000001180200001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... the WHERE lives inside the window's inner rse
        pin_proc(
            "CREATE PROCEDURE RD5 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(UA) OVER () FROM U2 WHERE UID > :P1 INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B110002021101074301C343014A025532004731170003554944290000000100FF01C4010046004D01000000561700025541FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... windows number in ENCOUNTER order of their specs
        pin_proc(
            "CREATE PROCEDURE RD6 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT MAX(UA) OVER (PARTITION BY UID), UID FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF02C401011700035549441801010046004D020000005417000255410100170003554944C4020046004D01000000170003554944FF0201180100001A000001180200001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_five_shapes_byte_for_byte() {
        // LAG canonicalizes to THREE arguments - value, offset
        // (filled 1), default (filled NULL) - under blr_agg_function
        // (flip forty-two)
        pin_proc(
            "CREATE PROCEDURE RE1 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, LAG(UA, 1) OVER (ORDER BY UID) FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF02C4010046004D01000000170003554944C402004601481700035549444D01000000C7034C4147031700025541150800010000002DFF0201180100001A000001180200001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... the fills probed against explicit arguments, two
        // functions sharing one window
        pin_proc(
            "CREATE PROCEDURE RE4 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT LAG(UA) OVER (ORDER BY UID), LEAD(UA, 2, 0) OVER (ORDER BY UID) FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF01C401004601481700035549444D02000000C7034C4147031700025541150800010000002D0100C7044C4541440317000255411508000200000015080000000000FF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // FRAME extents take the v4 blr_window_win - subcoded
        // order/map, extent unit ROWS(1), bounds with values, its
        // OWN end (flip forty-three)
        pin_proc(
            "CREATE PROCEDURE RE3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(UA) OVER (ORDER BY UID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301C343014A02553200FF01D30102014817000355494403010000005617000255410401050100060115080001000000050202FFFF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... RANGE(0), UNBOUNDED = a bound sans value
        pin_proc(
            "CREATE PROCEDURE RE5 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(UA) OVER (ORDER BY UID RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301C343014A02553200FF01D30102014817000355494403010000005617000255410400050100050202FFFF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... a single bound implies CURRENT ROW as frame two, and
        // the v4 partition subcode carries the v3 layout
        pin_proc(
            "CREATE PROCEDURE RE7 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(UA) OVER (PARTITION BY UID ORDER BY UA ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301C343014A02553200FF01D3010101170003554944180101000201481700025541030200000056170002554101001700035549440401050100050202FFFF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_six_shapes_byte_for_byte() {
        // NTH_VALUE canonicalizes with a FROM FIRST indicator -
        // literal 0 as a third argument (flip forty-four)
        pin_proc(
            "CREATE PROCEDURE RF1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT NTH_VALUE(UA, 2) OVER (ORDER BY UID) FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B110002021101074301C343014A02553200FF01C401004601481700035549444D01000000C7094E54485F56414C55450317000255411508000200000015080000000000FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // DERIVED tables in body FOR SELECTs (flip forty-five): the
        // view convention at body numbering - the inner rse in the
        // stream slot, inner WHERE inside, outer WHERE at rse level,
        // one shared context
        pin_proc(
            "CREATE PROCEDURE RF4 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT UID FROM (SELECT UID FROM U2 WHERE UA > 0) D WHERE UID > :P1 INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014301920255321122442220225055424C4943222E22553222004731170002554115080000000000FF4731170003554944290000000100FF02011700035549441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and a derived table in a SUBQUERY - live through
        // composition since the subquery slice, pinned NOW
        pin_proc(
            "CREATE PROCEDURE RF5 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM (SELECT UID FROM U2) D WHERE D.UID = T.ID) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400473C43014301920255321122442220225055424C4943222E2255322201FF472F1701035549441700024944FFFF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_seven_shapes_byte_for_byte() {
        // DERIVED-COLUMN ALIASES (flip forty-six): outer references
        // by ALIAS translate to the INNER column name at the shared
        // context - D.X over (SELECT UID AS X ...) emits UID
        pin_proc(
            "CREATE PROCEDURE RG1 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT D.X FROM (SELECT UID AS X FROM U2 WHERE UA > 0) D WHERE D.X > :P1 INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014301920255321122442220225055424C4943222E22553222004731170002554115080000000000FF4731170003554944290000000100FF02011700035549441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... the bare-name outer form translates too
        pin_proc(
            "CREATE PROCEDURE RF3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT D.X FROM (SELECT UID AS X FROM U2) D INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014301920255321122442220225055424C4943222E2255322200FFFF02011700035549441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_eight_shapes_byte_for_byte() {
        // UNION in body FOR SELECTs (flip forty-seven): blr_union at
        // the statement's FIRST slot, branch streams following
        pin_proc(
            "CREATE PROCEDURE RG3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T UNION ALL SELECT UID FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014C000243014A015401FF4D01000000170102494443014A02553202FF4D01000000170203554944FF0201180000001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... a DISTINCT union appends blr_project over the fids
        pin_proc(
            "CREATE PROCEDURE RH1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T UNION SELECT UID FROM U2 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014C000243014A015401FF4D01000000170102494443014A02553202FF4D01000000170203554944450118000000FF0201180000001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... per-branch WHEREs inside their rses, duplicate columns
        // keeping separate slots
        pin_proc(
            "CREATE PROCEDURE RH2 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT ID, ID FROM T WHERE ID > :P1 UNION ALL SELECT UID, UA FROM U2 WHERE UA < :P1 INTO :R1, :R2 DO SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B1100020211010743014C000243014A01540147311701024944290000000100FF4D0200000017010249440100170102494443014A0255320247331702025541290000000100FF4D0200000017020355494401001702025541FF0201180000001A000001180001001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // INSERT ... SELECT (flip forty-eight - a slice-12 refusal):
        // a marks(1, 4) FOR loop over the source rse, one store per
        // row, the SOURCE stream numbering first
        pin_proc(
            "CREATE PROCEDURE RH4 (P1 INTEGER) AS BEGIN INSERT INTO T (ID) SELECT UID FROM U2 WHERE UA > :P1; END",
            "050204000200080007000401010007000C00029B1100020207D9010443014A0255320047311700025541290000000100FF0F4A01540102011700035549441701024944FFFFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_thirty_nine_shapes_byte_for_byte() {
        // WITH ctes inline as DERIVED tables - the cte name becomes
        // the alias, column aliases translate (flip forty-nine)
        pin_proc(
            "CREATE PROCEDURE RI4 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN WITH W1 AS (SELECT UID AS X FROM U2 WHERE UA > 0) SELECT X FROM W1 WHERE X > :P1 INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202077F4301430192025532122257312220225055424C4943222E22553222004731170002554115080000000000FF4731170003554944290000000100FF02011700035549441A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ... and in the FOR loop form with an ORDER BY at the
        // shared context
        pin_proc(
            "CREATE PROCEDURE RI5 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR WITH CW AS (SELECT ID FROM T WHERE ID > :P1) SELECT ID FROM CW ORDER BY ID INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014301920154112243572220225055424C4943222E2254220047311700024944290000000100FF4601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // INSERT..SELECT items are FULL expressions at the source
        // stream (flip fifty)
        pin_proc(
            "CREATE PROCEDURE RI1 (P1 INTEGER) AS BEGIN INSERT INTO T (ID) SELECT UID * 2 + :P1 FROM U2; END",
            "050204000200080007000401010007000C00029B1100020207D9010443014A02553200FF0F4A01540102012224170003554944150800020000002900000001001701024944FFFFFFFF0E010201150700000019010000FFFF4C",
        );
    }

    #[test]
    fn slice_thirty_nine_refusals() {
        for sql in [
            // a select item whose field is NOT a group-key field
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UA + 0, COUNT(*) FROM U2 GROUP BY UID + 0 INTO :R1, :R2 DO SUSPEND; END",
            // a cte referenced twice: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN WITH A1 AS (SELECT ID FROM T) FOR SELECT ID FROM A1 UNION ALL SELECT ID FROM A1 INTO :R1 DO SUSPEND; END",
            // an unreferenced cte: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN WITH A1 AS (SELECT ID FROM T) SELECT UID FROM U2 INTO :R1; SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn compiles_slice_forty_shapes_byte_for_byte() {
        // select-item EXPRESSIONS at the stream context (flip
        // fifty-one)
        pin_proc(
            "CREATE PROCEDURE RJ1 (P1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT EMP_NO, SALARY * 2 + :P1 FROM EMPLOYEE WHERE DEPT_ID = 100 INTO :R1, :R2 DO SUSPEND; END",
            "0502040002000800070004010500080007000800070007000C00020300000800012D1A00000301000800012D1A01009B1100020211010743014A08454D504C4F59454500472F170007444550545F494415080064000000FF0201170006454D505F4E4F1A000001222417000653414C415259150800020000002900000001001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // GROUP BY EXPRESSIONS (flip fifty-two): the group list
        // takes the raw expression, the map its BARE fields, the
        // select item REBUILT over the fids
        pin_proc(
            "CREATE PROCEDURE RJ2 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID + UA, COUNT(*) FROM U2 GROUP BY UID + UA INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A02553200FF4E012217000355494417000255414D0300000017000355494401001700025541020053FF02012218010000180101001A000001180102001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // ... map slots in SELECT-ITEM order - the aggregate first
        // when selected first (the slice-8 law generalized)
        pin_proc(
            "CREATE PROCEDURE RJ5 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT COUNT(*), UID + 0 FROM U2 GROUP BY UID + 0 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014F0143014A02553200FF4E0122170003554944150800000000004D02000000530100170003554944FF0201180100001A0000012218010100150800000000001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // MULTIPLE ctes (flip fifty-three), one in the main FROM and
        // one expanding inside a correlated subquery
        pin_proc(
            "CREATE PROCEDURE RJ4 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN WITH A1 AS (SELECT ID FROM T WHERE ID > :P1), A2 AS (SELECT UID AS V FROM U2) SELECT ID FROM A1 WHERE EXISTS (SELECT 1 FROM A2 WHERE A2.V = A1.ID) INTO :R1; SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B11000202077F43014301920154112241312220225055424C4943222E2254220047311700024944290000000100FF473C4301430192025532122241322220225055424C4943222E2255322201FF472F1701035549441700024944FFFF020117000249441A0000FF0E0102011A000029010000010001150700010019010200FFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_one_shapes_byte_for_byte() {
        // non-aggregate EXPRESSION sort keys - the raw expression in
        // the sort clause (flip fifty-four)
        pin_proc(
            "CREATE PROCEDURE RK1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE ORDER BY SALARY * 2 DESC INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F594545004601492417000653414C41525915080002000000FF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // window PASSTHROUGH expressions: fields into the default
        // window's map, the item rebuilt over the fids - the
        // group-expression law in window clothing (flip fifty-five)
        pin_proc(
            "CREATE PROCEDURE RK2 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID + 1, COUNT(*) OVER () FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B110002021101074301C343014A02553200FF01C4010046004D02000000170003554944010053FF02012218010000150800010000001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
        // HAVING without GROUP BY: an aggregate with zero group keys
        // - LIVE through composition, pinned now
        pin_proc(
            "CREATE PROCEDURE RK3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) FROM U2 HAVING COUNT(*) > 5 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A02553200FF4E004D010000005347311801000015080005000000FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // OFFSET/FETCH - the standard spelling of SKIP and FIRST,
        // the same rse clauses in the same order (flip fifty-six)
        pin_proc(
            "CREATE PROCEDURE RK4 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE ORDER BY EMP_NO OFFSET 1 ROW FETCH FIRST 2 ROWS ONLY INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F594545004415080002000000AF15080001000000460148170006454D505F4E4FFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // PLAN (tbl NATURAL): blr_plan/blr_retrieve/the stream
        // again/blr_sequential, LAST in the rse after the sort
        // (flip fifty-seven)
        pin_proc(
            "CREATE PROCEDURE RK6 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID > :P1 PLAN (T NATURAL) ORDER BY ID INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A0154004731170002494429000000010046014817000249448B914A0154008EFF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_two_shapes_byte_for_byte() {
        // SELECT DISTINCT in a body FOR SELECT: blr_project over the
        // select columns, AFTER the boolean - the view law lands at
        // body numbering (flip fifty-nine)
        pin_proc(
            "CREATE PROCEDURE RL1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT DEPT_ID FROM EMPLOYEE WHERE SALARY > 0 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F59454500473117000653414C415259150800000000004501170007444550545F4944FF0201170007444550545F49441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // PLAN (tbl INDEX (name)): the plan head as NATURAL, then
        // blr_indices + a count + counted index names in place of
        // blr_sequential (flip sixty)
        pin_proc(
            "CREATE PROCEDURE RL2 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID = :P1 PLAN (T INDEX (IDX_T_ID)) INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A015400472F17000249442900000001008B914A0154009001084944585F545F4944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // ROWS m TO n: the legacy limits desugar to UNFOLDED
        // arithmetic - first = add(subtract(n, m), 1) and skip =
        // subtract(m, 1), literal expression trees in the rse
        // (flip sixty-one)
        pin_proc(
            "CREATE PROCEDURE RL3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE ORDER BY EMP_NO ROWS 2 TO 4 INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A08454D504C4F59454500442223150800040000001508000200000015080001000000AF231508000200000015080001000000460148170006454D505F4E4FFF0201170006454D505F4E4F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_three_shapes_byte_for_byte() {
        // STARTING [WITH] - blr_starting; NOT keeps blr_not like
        // LIKE (flip sixty-two)
        pin_proc(
            "CREATE PROCEDURE RM1 RETURNS (R1 VARCHAR(10)) AS BEGIN FOR SELECT NAME FROM T WHERE NAME STARTING WITH 'b' INTO :R1 DO SUSPEND; END",
            "0502040103002600000A0007000700020300002600000A00012D1A00009B1100020211010743014A01540047371700044E414D45150F0000010062FF02011700044E414D451A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // FIRST (:P1) - a PARENTHESIZED parameter compiles to the
        // bare parameter2; FIRST :P1 is a syntax error in the ENGINE
        // too (flip sixty-three)
        pin_proc(
            "CREATE PROCEDURE RM2 (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST (:P1) ID FROM T ORDER BY ID INTO :R1 DO SUSPEND; END",
            "05020400020008000700040103000800070007000C00020300000800012D1A00009B1100020211010743014A015400442900000001004601481700024944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // DISTINCT over a DERIVED table: the project's field
        // translates through the derived list (flip sixty-four)
        pin_proc(
            "CREATE PROCEDURE RM3 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT X.V FROM (SELECT AMT AS V FROM T) X INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B11000202110107430143019201541022582220225055424C4943222E22542200FF4501170003414D54FF0201170003414D541A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // FOR-less SUBSTRING: the engine fills the length with INT
        // MAX (flip sixty-five)
        pin_proc(
            "CREATE PROCEDURE RM4 RETURNS (R1 VARCHAR(10)) AS BEGIN FOR SELECT SUBSTRING(NAME FROM 2) FROM T INTO :R1 DO SUSPEND; END",
            "0502040103002600000A0007000700020300002600000A00012D1A00009B1100020211010743014A015400FF0201281700044E414D45231508000200000015080001000000150800FFFFFF7F1A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // an EXPRESSION select item in a quantified subquery wraps
        // in blr_derived_expr over the subquery stream (flip
        // sixty-six)
        pin_proc(
            "CREATE PROCEDURE RM5 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IN (SELECT UA / 25 FROM U) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004797430143014A015501FF472F170003414D54BF010125170102554115080019000000FFFF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_four_shapes_byte_for_byte() {
        // UNION ALL as a quantified subquery's stream: the union
        // claims the subquery's context slot, branches the next
        // ones, the comparison reads fid(union ctx, 0) - and NOT IN
        // negates to ansi_all + neq as everywhere (flip sixty-seven)
        pin_proc(
            "CREATE PROCEDURE RM6 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID NOT IN (SELECT UID FROM U UNION ALL SELECT ID FROM T) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400479E430143014C010243014A015502FF4D0100000017020355494443014A015403FF4D010000001703024944FF4730170002494418010000FFFF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_five_shapes_byte_for_byte() {
        // WITH RECURSIVE - blr_recurse: ctx, the SECONDARY recursive
        // context byte, branch count; anchor rse+map (cte name on
        // the relation2 alias), STREAM-LESS recursive branch reading
        // fid(ctx, 0); the +1 anchor casts int64 (dialect-3 ADD
        // types the union there - the slice-44 law, catalog-free)
        // (flip sixty-eight)
        pin_proc(
            "CREATE PROCEDURE RN1 RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE NUMS AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT NUMS.ID + 1 FROM NUMS WHERE NUMS.ID < 5) SELECT NUMS.ID FROM NUMS INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014301B9010002430192015413224E554D532220225055424C4943222E22542202472F170202494415080001000000FF4D010000008310001702024944430047331801000015080005000000FF4D01000000221801000015080001000000FFFF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // the no-arithmetic recursion: same types, NO casts anywhere
        pin_proc(
            "CREATE PROCEDURE RN2 RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE NUMS AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT NUMS.ID FROM NUMS WHERE NUMS.ID < 0) SELECT NUMS.ID FROM NUMS INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014301B9010002430192015413224E554D532220225055424C4943222E22542202472F170202494415080001000000FF4D010000001702024944430047331801000015080000000000FF4D0100000018010000FFFF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_six_shapes_byte_for_byte() {
        // the union TYPE-UNIFICATION law, converted (flip sixty-nine):
        // one arithmetic branch types the union int64 (dialect-3,
        // width-independent - catalog-free) and every PLAIN branch
        // wraps in cast(int64)
        pin_proc(
            "CREATE PROCEDURE RO1 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IN (SELECT UA FROM U UNION ALL SELECT UA * 2 FROM U) INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004797430143014C010243014A015502FF4D01000000831000170202554143014A015503FF4D0100000024170302554115080002000000FF472F170003414D5418010000FFFF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
        // PLAN (tbl ORDER idx) - blr_navigational + ONE counted name,
        // no count byte (flip seventy); the engine demands the
        // matching ORDER BY
        pin_proc(
            "CREATE PROCEDURE RO2 RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID > 1 PLAN (T ORDER IDX_T_ID) ORDER BY ID INTO :R1 DO SUSPEND; END",
            "050204010300080007000700020300000800012D1A00009B1100020211010743014A015400473117000249441508000100000046014817000249448B914A0154008F084944585F545F4944FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_forty_seven_shapes_byte_for_byte() {
        // MULTI-COLUMN recursive ctes (flip seventy-one) - and the
        // unification law refined: it is PER COLUMN. Only the column
        // whose RECURSIVE item is integer arithmetic promotes (its
        // anchor field wraps in cast(int64)); the plain sibling
        // stays bare, both in one map
        pin_proc(
            "CREATE PROCEDURE RQ1 RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR WITH RECURSIVE N AS (SELECT ID, AMT FROM T WHERE ID = 1 UNION ALL SELECT N.ID + 1, N.AMT FROM N WHERE N.ID < 3) SELECT N.ID, N.AMT FROM N INTO :R1, :R2 DO SUSPEND; END",
            "05020401050008000700080007000700020300000800012D1A00000301000800012D1A01009B1100020211010743014301B9010002430192015410224E2220225055424C4943222E22542202472F170202494415080001000000FF4D0200000083100017020249440100170203414D54430047331801000015080003000000FF4D02000000221801000015080001000000010018010100FFFF0201180100001A000001180101001A01000E0102011A0000290100000100011A010029010200030001150700010019010400FFFFFFFFFF0E0102011A0000290100000100011A010029010200030001150700000019010400FFFF4C",
        );
    }

    #[test]
    fn slice_forty_seven_refusals() {
        for sql in [
            // an outer column ORDER over the recursion: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR WITH RECURSIVE N AS (SELECT ID, AMT FROM T WHERE ID = 1 UNION ALL SELECT N.ID + 1, N.AMT FROM N WHERE N.ID < 3) SELECT N.ID, N.AMT FROM N ORDER BY N.ID INTO :R1, :R2 DO SUSPEND; END",
            // a column the cte does not declare
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE N AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT N.ID + 1 FROM N WHERE N.ID < 3) SELECT N.AMT FROM N INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_forty_six_refusals() {
        for sql in [
            // DIVISION in a union branch: the scale rules ride a
            // different promotion - unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IN (SELECT UA FROM U UNION ALL SELECT UA / 2 FROM U) INTO :R1 DO SUSPEND; END",
            // field-by-field arithmetic in a branch: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE AMT IN (SELECT UA FROM U UNION ALL SELECT UA + UID FROM U) INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_forty_five_refusals() {
        for sql in [
            // non-recursive cte BESIDE a recursive one: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE NUMS AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT NUMS.ID + 1 FROM NUMS WHERE NUMS.ID < 5), OTHER AS (SELECT ID FROM T) SELECT NUMS.ID FROM NUMS INTO :R1 DO SUSPEND; END",
            // an outer WHERE over the recursion: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE NUMS AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT NUMS.ID + 1 FROM NUMS WHERE NUMS.ID < 5) SELECT NUMS.ID FROM NUMS WHERE NUMS.ID > 2 INTO :R1 DO SUSPEND; END",
            // multiplication in the recursive item: the dialect-3
            // promotion differs (int64-rank operands) - unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR WITH RECURSIVE NUMS AS (SELECT ID FROM T WHERE ID = 1 UNION ALL SELECT NUMS.ID * 2 FROM NUMS WHERE NUMS.ID < 5) SELECT NUMS.ID FROM NUMS INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_forty_four_refusals() {
        for sql in [
            // the DISTINCT union form in a subquery: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID IN (SELECT UID FROM U UNION SELECT ID FROM T) INTO :R1 DO SUSPEND; END",
            // EXISTS over a union: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE EXISTS (SELECT UID FROM U UNION ALL SELECT ID FROM T) INTO :R1 DO SUSPEND; END",
            // derived branches inside a union subquery: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID IN (SELECT V FROM (SELECT ID AS V FROM T) A UNION ALL SELECT UID FROM U) INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_forty_three_refusals() {
        for sql in [
            // general limit expressions: unprobed (params only)
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST (1 + 1) ID FROM T INTO :R1 DO SUSPEND; END",
            // an expression item in a SCALAR subselect: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN R1 = (SELECT UA / 25 FROM U WHERE U.UID = 1); SUSPEND; END",
            // NULLIF/IIF over FIELD branches: the unifying cast's
            // target needs the field's CATALOG type - a model
            // boundary for a catalog-free compiler, not a gap
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT NULLIF(AMT, 8) FROM T INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_forty_two_refusals() {
        for sql in [
            // ROWS n alone (no TO): unprobed
            // ROWS with parameter bounds: unprobed
            "CREATE PROCEDURE X (P1 INTEGER, P2 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE ORDER BY EMP_NO ROWS :P1 TO :P2 INTO :R1 DO SUSPEND; END",
            // ROWS after OFFSET/FETCH: contradictory limits
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT EMP_NO FROM EMPLOYEE ORDER BY EMP_NO OFFSET 1 ROW FETCH FIRST 2 ROWS ONLY ROWS 2 TO 4 INTO :R1 DO SUSPEND; END",
            // DISTINCT in the singular form: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN SELECT DISTINCT DEPT_ID FROM EMPLOYEE INTO :R1; SUSPEND; END",
            // DISTINCT over aggregates: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT COUNT(*) FROM EMPLOYEE INTO :R1 DO SUSPEND; END",
            // DISTINCT over a join: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT DISTINCT A.ID FROM T A JOIN U2 B ON A.ID = B.UID INTO :R1 DO SUSPEND; END",
            // PLAN INDEX with an empty index list: malformed
            "CREATE PROCEDURE X (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID = :P1 PLAN (T INDEX ()) INTO :R1 DO SUSPEND; END",
            // PLAN over a join: unprobed
            "CREATE PROCEDURE X (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT A.ID FROM T A JOIN U2 B ON A.ID = B.UID WHERE A.ID = :P1 PLAN JOIN (A INDEX (IDX_T_ID), B NATURAL) INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn window_statement_sort() {
        // the statement ORDER BY reads the window streams: an unselected
        // column joins the DEFAULT window's map after the items and the
        // sort names its fid; a position sorts on the item's own fid
        // (RDB$PROCEDURE_BLR on 2196)
        let c = compile_procedure("CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, ROW_NUMBER() OVER (ORDER BY UA) FROM U2 ORDER BY ID INTO :R1, :R2 DO SUSPEND; END").unwrap();
        let map = [blr::MAP, 2, 0, 0, 0, blr::FIELD, 0, 3, b'U', b'I', b'D', 1, 0, blr::FIELD, 0, 2, b'I', b'D'];
        assert!(c.windows(map.len()).any(|w| w == map), "{:02X?}", c);
        assert!(c.windows(7).any(|w| w == [blr::SORT, 1, blr::ASCENDING, blr::FID, 1, 1, 0]), "{:02X?}", c);
        let p = compile_procedure("CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, ROW_NUMBER() OVER (ORDER BY UA) RN FROM U2 ORDER BY RN DESC INTO :R1, :R2 DO SUSPEND; END").unwrap();
        assert!(p.windows(7).any(|w| w == [blr::SORT, 1, blr::DESCENDING, blr::FID, 2, 0, 0]), "{:02X?}", p);
    }

    #[test]
    fn window_refusals() {
        for sql in [
            // windows beside GROUP BY/aggregates: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT COUNT(*), SUM(UA) OVER () FROM U2 INTO :R1, :R2 DO SUSPEND; END",
            // windows over a JOIN: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT COUNT(*) OVER () FROM T A JOIN U2 B ON A.ID = B.UID INTO :R1 DO SUSPEND; END",
            // the singular form with a window: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN SELECT COUNT(*) OVER () FROM U2 INTO :R1; SUSPEND; END",
            // a window FUNCTION as a statement sort key: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, COUNT(*) OVER () FROM U2 ORDER BY RANK() OVER (ORDER BY UA) INTO :R1, :R2 DO SUSPEND; END",
            // two items under the sort key's name: the engine's 42702
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER, R3 INTEGER) AS BEGIN FOR SELECT UID, UID, COUNT(*) OVER () FROM U2 ORDER BY UID INTO :R1, :R2, :R3 DO SUSPEND; END",
            // a frame DEMANDS an order (unprobed without one)
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT SUM(UA) OVER (ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM U2 INTO :R1 DO SUSPEND; END",
            // named windows (the WINDOW clause): unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT UID, SUM(UA) OVER W FROM U2 WINDOW W AS (PARTITION BY UID) INTO :R1, :R2 DO SUSPEND; END",
            // mixed ALL/distinct across union branches: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T UNION ALL SELECT UID FROM U2 UNION SELECT UID FROM U2 INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn subroutine_refusals() {
        for sql in [
            // derived tables inside subroutines: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE PROCEDURE S1 RETURNS (O1 INTEGER) AS BEGIN SELECT ID FROM (SELECT ID FROM T) A INTO :O1; END BEGIN EXECUTE PROCEDURE S1 RETURNING_VALUES :R1; SUSPEND; END",
            // nested subroutines: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE PROCEDURE S1 RETURNS (O1 INTEGER) AS DECLARE PROCEDURE S2 RETURNS (O2 INTEGER) AS BEGIN O2 = 1; END BEGIN EXECUTE PROCEDURE S2 RETURNING_VALUES :O1; END BEGIN EXECUTE PROCEDURE S1 RETURNING_VALUES :R1; SUSPEND; END",
            // RETURN belongs to function bodies only
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN RETURN 1; END",
            // SUSPEND has no place in a function body
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE FUNCTION F1 RETURNS INTEGER AS BEGIN SUSPEND; END BEGIN R1 = F1(); SUSPEND; END",
            // sub-call argument counts are checked at the declaration
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE FUNCTION DBL (I1 INTEGER) RETURNS INTEGER AS BEGIN RETURN I1 + I1; END BEGIN R1 = DBL(1, 2); SUSPEND; END",
            // mixed named and unnamed EXECUTE STATEMENT parameters
            "CREATE PROCEDURE X (P1 INTEGER) AS BEGIN EXECUTE STATEMENT ('delete from u2 where uid = :a and ua = ?') (a := :P1, :P1); END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn merge_refusals() {
        for sql in [
            // a branch AFTER its kind's unconditional one is
            // unreachable - the chain has one else slot to fill
            "CREATE PROCEDURE X (P1 INTEGER) AS BEGIN MERGE INTO U2 USING T ON U2.UID = T.ID WHEN MATCHED THEN DELETE WHEN MATCHED THEN UPDATE SET UA = :P1; END",
            // bare names in the ON clause need the catalog
            "CREATE PROCEDURE X AS BEGIN MERGE INTO U2 USING T ON UID = ID WHEN MATCHED THEN DELETE; END",
            // a sub-select source: unprobed
            "CREATE PROCEDURE X AS BEGIN MERGE INTO U2 USING (SELECT ID FROM T) A ON U2.UID = A.ID WHEN MATCHED THEN DELETE; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_twenty_four_refusals() {
        for sql in [
            // backward fetch on an UNSCROLLED cursor is an engine error
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2); BEGIN OPEN CX; FETCH PRIOR FROM CX INTO :R1; CLOSE CX; SUSPEND; END",
            // RETURNING on positioned DML: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT UID FROM U2); BEGIN OPEN CX; FETCH CX; DELETE FROM U2 WHERE CURRENT OF CX RETURNING UID INTO :R1; CLOSE CX; SUSPEND; END",
            // RETURNING expressions: unprobed (columns only)
            "CREATE PROCEDURE X (P1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN INSERT INTO U2 (UID) VALUES (:P1) RETURNING UID * 2 INTO :R1; SUSPEND; END",
            // EXECUTE STATEMENT USING: unprobed
            "CREATE PROCEDURE X (P1 INTEGER) AS BEGIN EXECUTE STATEMENT 'delete from t where id = ?' USING :P1; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn for_cursor_refusals() {
        for sql in [
            // ORDER BY on an AS CURSOR loop: unprobed
            "CREATE PROCEDURE X AS BEGIN FOR SELECT ID FROM T ORDER BY ID AS CURSOR CU DO DELETE FROM T WHERE CURRENT OF CU; END",
            // OPEN/FETCH/CLOSE address DECLAREd cursors only
            "CREATE PROCEDURE X AS BEGIN FOR SELECT ID FROM T AS CURSOR CU DO OPEN CU; END",
            // an AS CURSOR name is OUT OF SCOPE after its loop
            "CREATE PROCEDURE X AS BEGIN FOR SELECT ID FROM T AS CURSOR CU DO EXIT; DELETE FROM T WHERE CURRENT OF CU; END",
            // positioned DML against the wrong table
            "CREATE PROCEDURE X AS BEGIN FOR SELECT ID FROM T AS CURSOR CU DO DELETE FROM U2 WHERE CURRENT OF CU; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn handler_refusals() {
        for sql in [
            // UPDATE OR INSERT without MATCHING needs the primary key
            "CREATE PROCEDURE X (I1 INTEGER) AS BEGIN UPDATE OR INSERT INTO U2 (UID) VALUES (:I1); END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn cursor_refusals() {
        for sql in [
            // ORDER BY over an aggregate cursor: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT COUNT(*) AS C FROM U2 ORDER BY C); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
            // DISTINCT aggregates in a cursor: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT COUNT(DISTINCT UID) AS C FROM U2); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
            // a qualifier that matches NO stream
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT B.ID FROM T A); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
            // WHERE CURRENT OF against the WRONG table
            "CREATE PROCEDURE X AS DECLARE C1 CURSOR FOR (SELECT ID FROM T); BEGIN OPEN C1; FETCH C1; DELETE FROM U2 WHERE CURRENT OF C1; CLOSE C1; END",
            // WHERE CURRENT OF an aggregate cursor is an engine error
            "CREATE PROCEDURE X AS DECLARE C1 CURSOR FOR (SELECT COUNT(*) AS C FROM T); BEGIN OPEN C1; FETCH C1; DELETE FROM T WHERE CURRENT OF C1; CLOSE C1; END",
            // an aggregate column without a name is an engine error
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE C1 CURSOR FOR (SELECT COUNT(*), UID FROM U2 GROUP BY UID); BEGIN OPEN C1; FETCH C1 INTO :R1; CLOSE C1; SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn field_blr_refusals() {
        // the engine's DEFAULT grammar allows literals, NULL and the
        // context functions - NOTHING else; qualified names in a
        // computed refuse (the stream is anonymous)
        for sql in ["DEFAULT 3 + 4", "DEFAULT A", "DEFAULT UPPER('x')"] {
            assert!(compile_default(sql).is_none(), "{sql} was compiled");
        }
        assert!(compile_computed("COMPUTED BY (T.C1)").is_none());
    }

    #[test]
    fn general_body_refusals() {
        for sql in [
            // SUSPEND without outputs: unprobed
            "CREATE PROCEDURE X (I1 INTEGER) AS BEGIN SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn psql_refusals() {
        for sql in [
            // an assignment to an undeclared name is not a variable
            "CREATE TRIGGER X FOR T BEFORE INSERT AS DECLARE V1 INTEGER; BEGIN V2 = 5; END",
        ] {
            assert!(compile_trigger(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn dml_refusals() {
        for sql in [
            // INSERT without a column list needs the catalog
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 VALUES (1); END",
            // column/value count mismatch is an engine error
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 (UID) VALUES (1, 2); END",
            // INSERT ... SELECT over aggregates: unprobed
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 (UID) SELECT COUNT(*) FROM T; END",
        ] {
            assert!(compile_trigger(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn an_empty_body_is_its_wrapper_alone() {
        // measured on 2196 (qa/serve-real-emptybody.sh holds the wire side):
        // `label 0, begin, end` - no statement list at all
        assert_eq!(
            compile_trigger("CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN END"),
            Some(vec![blr::VERSION5, blr::BEGIN, blr::LABEL, 0, blr::BEGIN, blr::END, blr::END, blr::EOC])
        );
    }

    #[test]
    fn trigger_refusals() {
        for sql in [
            // OLD targets are read-only in the engine
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN OLD.A = 5; END",
            // bare column names are ambiguous between OLD and NEW
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN A = 5; END",
            // database-level triggers: a different wrapper, unprobed
            "CREATE TRIGGER X FOR T ON CONNECT AS BEGIN NEW.A = 1; END",
        ] {
            assert!(compile_trigger(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn slice_ten_refusals() {
        for sql in [
            // FIRST :param without parens is an ENGINE syntax error
            "CREATE PROCEDURE X (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST :I1 ID FROM T INTO :R1 DO SUSPEND; END",
            // FIRST/SKIP in the singular form and over aggregates:
            // unprobed placements
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN SELECT FIRST 1 ID FROM T INTO :R1; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn standalone_function_blr_matches_the_engine() {
        // probed: RDB$FUNCTION_BLR of `CREATE FUNCTION F (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END`
        let c = compile_function_full("CREATE FUNCTION F (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END").unwrap();
        let hex: String = c.blob.iter().map(|x| format!("{:02x}", x)).collect();
        assert_eq!(hex, "05020400020008000700040103000800070007000c00020300000800012d1a00009b11000202020122290000000100150800010000001a00000e0102011a0000290100000100ff1200ffffffff0e0102011a0000290100000100ffff4c");
        assert_eq!(c.name, "F");
        assert_eq!(c.ins.len(), 1);
        assert_eq!(c.outs.len(), 1);
        assert_eq!(c.source, "BEGIN RETURN A + 1; END");
    }

    #[test]
    fn view_column_blr_matches_the_engine() {
        // probed on the live engine: RDB$COMPUTED_BLR of the auto-domains
        let hex = |v: &Option<Vec<u8>>| v.as_ref().map(|b| b.iter().map(|x| format!("{:02x}", x)).collect::<String>());
        let c = compile_view_columns("SELECT ID, V || 'x' FROM T").unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0], None);
        assert_eq!(hex(&c[1]).as_deref(), Some("052717010156150f00000100784c"));
        let c = compile_view_columns("SELECT a.ID AS AID, b.V, a.N + 1 AS NP FROM T a JOIN T b ON b.ID = a.ID WHERE a.N > 0").unwrap();
        assert_eq!(c[0], None);
        assert_eq!(c[1], None);
        assert_eq!(hex(&c[2]).as_deref(), Some("05221701014e150800010000004c"));
        let c = compile_view_columns("SELECT ID, N * 2 AS N2, UPPER(V) AS UV FROM T WHERE ID <> 2").unwrap();
        assert_eq!(hex(&c[1]).as_deref(), Some("05241701014e150800020000004c"));
        assert_eq!(hex(&c[2]).as_deref(), Some("0567170101564c"));
        // the RSE of those views compiles too
        assert!(compile_view_select("SELECT ID, V || 'x' FROM T").is_some());
        assert!(compile_view_select("SELECT ID, N * 2 AS N2, UPPER(V) AS UV FROM T WHERE ID <> 2").is_some());
    }

    #[test]
    fn input_param_refusals() {
        for sql in [
            // `:name` must name an input parameter
            "CREATE PROCEDURE X (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A > :MISSING INTO :R1 DO SUSPEND; END",
            // `:name` outside a procedure body means nothing
            "SELECT ID FROM T WHERE A > :I1",
        ] {
            assert!(
                compile_procedure(sql).is_none()
                    && compile_view_select(sql).is_none(),
                "{sql} was compiled"
            );
        }
    }

    #[test]
    fn aggregate_refusals() {
        for sql in [
            // a plain column beside an aggregate NEEDS a GROUP BY
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T INTO :R1, :R2 DO SUSPEND; END",
            // GROUP BY without aggregates: unprobed
            // a select column missing from GROUP BY
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT S, COUNT(*) FROM T GROUP BY A INTO :R1, :R2 DO SUSPEND; END",
            // a non-grouped column in HAVING
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A HAVING S > 0 INTO :R1, :R2 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn explicit_character_set_types_the_descriptor_and_the_parameter() {
        // `VARCHAR(10) CHARACTER SET UTF8` is blr_varying2, set 4, 40 bytes -
        // whatever the default - and the parameter meta carries the set
        let c = compile_procedure_full(
            "CREATE PROCEDURE P (X CHAR(2) CHARACTER SET WIN_1252) RETURNS (R VARCHAR(10) CHARACTER SET UTF8) AS BEGIN R = X; SUSPEND; END",
        )
        .expect("compiles");
        assert!(c.blob.windows(5).any(|w| w == [blr::VARYING2, 4, 0, 40, 0]));
        assert!(c.blob.windows(5).any(|w| w == [blr::TEXT2, 53, 0, 2, 0]));
        assert_eq!(c.outs[0].charset, Some(4));
        assert_eq!(c.ins[0].charset, Some(53));
        // an unknown set, and a COLLATE after a set, refuse
        assert!(compile_procedure("CREATE PROCEDURE P RETURNS (R VARCHAR(10) CHARACTER SET NOSUCH) AS BEGIN SUSPEND; END").is_none());
        assert!(compile_procedure("CREATE PROCEDURE P RETURNS (R VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE) AS BEGIN SUSPEND; END").is_none());
    }

    #[test]
    fn order_by_position_is_the_item_it_names() {
        // byte-for-byte the named key (RDB$PROCEDURE_BLR on 2196): plain
        // columns, an aggregate's map slot, an expression
        for (pos, named) in [
            ("ORDER BY 2 DESC, 1", "ORDER BY A DESC, ID"),
            ("ORDER BY 1", "ORDER BY ID * 2"),
        ] {
            let wrap = |o: &str, sel: &str| {
                format!("CREATE PROCEDURE X RETURNS (R1 BIGINT, R2 INTEGER) AS BEGIN FOR SELECT {} FROM T {} INTO :R1, :R2 DO SUSPEND; END", sel, o)
            };
            let sel = if named.contains('*') { "ID * 2, A" } else { "ID, A" };
            assert_eq!(compile_procedure(&wrap(pos, sel)), compile_procedure(&wrap(named, sel)), "{pos}");
            assert!(compile_procedure(&wrap(pos, sel)).is_some(), "{pos}");
        }
        let grp = |o: &str| {
            format!("CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 BIGINT) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A {} INTO :R1, :R2 DO SUSPEND; END", o)
        };
        // an aggregate's position compiles to its map slot (the engine's
        // PO3 bytes, checked through fcdsql); the AGGREGATE written out as
        // the key (`ORDER BY COUNT(*)`) is not taken by this compiler yet
        assert!(compile_procedure(&grp("ORDER BY 2 DESC")).is_some());
        // slice 28: an aggregate as a sort key takes its map slot - the
        // same bytes as the ordinal that names it (measured: `ORDER BY
        // SUM(N)` sorts on fid 1)
        assert_eq!(
            compile_procedure(&grp("ORDER BY COUNT(*) DESC")),
            compile_procedure(&grp("ORDER BY 2 DESC"))
        );
        assert!(compile_procedure(&grp("ORDER BY COUNT(*) DESC")).is_some());
    }

    #[test]
    fn procedure_refusals() {
        for sql in [
            // ORDER BY <position> past the select list (the engine's -104
            // *Invalid column position*), and a scaled one
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY 2 INTO :R1 DO SUSPEND; END",
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY 1.0 INTO :R1 DO SUSPEND; END",
            // INTO must name RETURNS parameters, one per column
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T INTO :NOPE DO SUSPEND; END",
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID, A FROM T INTO :R1 DO SUSPEND; END",
            // quantified comparisons over AGGREGATE output: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE ID > ALL (SELECT MAX(UA) FROM U2) INTO :R1 DO SUSPEND; END",
            // aliased positioned DML: unprobed
            "CREATE PROCEDURE X (P1 INTEGER) AS DECLARE CX CURSOR FOR (SELECT ID FROM T); BEGIN OPEN CX; FETCH CX; UPDATE T A SET ID = :P1 WHERE CURRENT OF CX; CLOSE CX; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn refuses_outside_the_surface() {
        // shapes this slice has NOT verified against the engine refuse
        // rather than guess
        for sql in [
            "SELECT ID FROM T ORDER BY ID",          // trailing clause
            "UPDATE T SET A = 1",                    // not a SELECT
            "SELECT COUNT(*) FROM T",                // aggregates
            // a BARE field in a multi-stream statement: the engine
            // resolves it through the catalog; catalog-free, we refuse
            "SELECT T.ID FROM T, U2 WHERE ID = 1",
            "SELECT T.ID FROM T, U2, T WHERE T.ID = 1 AND X.A = 2", // bad qualifier
            // an unknown name followed by '(' is a UDF or an
            // unconverted built-in - never a field
            "SELECT ID FROM T WHERE FOO(A) = 1",
            "SELECT ID FROM T WHERE DECODE(A, 1, 2) = 1",
            "SELECT ID FROM T CROSS JOIN U2",        // no ON clause
            // a FIELD branch in a cast-wrapped conditional: its dsc
            // lives in the catalog - never guess a descriptor
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN A ELSE 0 END = 1",
            "SELECT ID FROM T WHERE NULLIF(A, 0) = 5",
            // single-argument COALESCE is a syntax error IN THE ENGINE
            "SELECT ID FROM T WHERE COALESCE(A) = 5",
            // unprobed cast targets and unprobed unifications
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN NULL ELSE NULL END IS NULL",
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 'x' ELSE 0 END = 'x'",
            // a subquery inside an ON clause would interleave the
            // join chain's stream numbering: unprobed
            "SELECT T.ID FROM T JOIN U2 ON EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.ID)",
            // multi-stream subqueries and multi-column select lists
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 JOIN V3T ON U2.UID = V3T.VID)",
            "SELECT ID FROM T WHERE A IN (SELECT UA, UID FROM U2)",
            // non-integer IN-list items: the engine casts each to the
            // left side's CATALOG type (probed: S IN ('a','b') stores
            // blr_cast varying2(10) per item) - catalog-free refuses
            "SELECT ID FROM T WHERE S IN ('a', 'b')",
            // mixed UNION / UNION ALL chains bind by their own
            // precedence rules: unprobed
            "SELECT A FROM T UNION SELECT UA FROM U2 UNION ALL SELECT VID FROM V3T",
            // column-count mismatch is an engine error
            "SELECT A FROM T UNION SELECT UA, UID FROM U2",
            // DISTINCT in union branches, DISTINCT *, DISTINCT over
            // expressions: unprobed shapes
            "SELECT DISTINCT A FROM T UNION SELECT UA FROM U2",
            "SELECT DISTINCT * FROM T",
            "SELECT DISTINCT UPPER(S) FROM T",
            // derived tables need an alias; derived union branches
            // are unprobed
            "SELECT X.ID FROM (SELECT ID FROM T)",
            "SELECT A FROM T UNION SELECT X.ID FROM (SELECT ID FROM T) X",
        ] {
            assert!(compile_view_select(sql).is_none(), "{sql} was compiled");
        }
        // a CAST to the approximate kinds is the dtype byte alone -
        // blr_float 10, blr_double 27 (measured: a view over CAST(A AS
        // FLOAT) / REAL / DOUBLE PRECISION stores the engine's bytes)
        let f = compile_view_select("SELECT ID FROM T WHERE CAST(A AS FLOAT) = 1").expect("FLOAT cast");
        assert!(f.windows(2).any(|w| w == [blr::CAST, 10]), "{f:02X?}");
        let d = compile_view_select("SELECT ID FROM T WHERE CAST(A AS DOUBLE PRECISION) = 1").expect("DOUBLE cast");
        // ...and INT128 its scale byte (measured: NUMERIC(30) and INT128 are
        // `83 1A 00`, DECIMAL(25,3) `83 1A FD`)
        let n = compile_view_select("SELECT ID FROM T WHERE CAST(A AS NUMERIC(30)) = 1").expect("NUMERIC(30) cast");
        assert!(n.windows(3).any(|w| w == [blr::CAST, 26, 0]), "{n:02X?}");
        let n = compile_view_select("SELECT ID FROM T WHERE CAST(A AS DECIMAL(25,3)) = 1").expect("DECIMAL(25,3) cast");
        assert!(n.windows(3).any(|w| w == [blr::CAST, 26, 0xFD]), "{n:02X?}");
        assert!(d.windows(2).any(|w| w == [blr::CAST, 27]), "{d:02X?}");
        // double negation cancels
        assert_eq!(
            compile_view_select("SELECT ID FROM T WHERE NOT (NOT (A > 5))"),
            compile_view_select("SELECT ID FROM T WHERE A > 5"),
        );
    }
}

#[cfg(test)]
mod employee_sample_bodies {
    use super::*;
    /// The procedure shapes the employee sample's build script uses, each
    /// once refused here: a bare column across a comma-joined FROM (through
    /// the catalog), an array element with a parameter subscript, a
    /// selectable procedure with arguments as a FOR SELECT source, and the
    /// paren-less EXECUTE PROCEDURE argument list.
    #[test]
    fn compile_the_sample_shapes() {
        set_catalog(vec![
            ("SALES".into(), vec!["PO_NUMBER".into(), "CUST_NO".into(), "ORDER_STATUS".into()]),
            ("CUSTOMER".into(), vec!["CUST_NO".into(), "ON_HOLD".into()]),
            ("JOB".into(), vec!["JOB_CODE".into(), "LANGUAGE_REQ".into()]),
            ("SHOW_LANGS".into(), vec!["LANGUAGES".into()]),
        ]);
        let comma = compile_procedure_full(
            "CREATE PROCEDURE p (po CHAR(8)) AS DECLARE VARIABLE a CHAR(7); DECLARE VARIABLE h CHAR(1); BEGIN \
             SELECT s.order_status, c.on_hold FROM sales s, customer c WHERE po_number = :po AND s.cust_no = c.cust_no INTO :a, :h; END",
        );
        let elem = compile_procedure_full(
            "CREATE PROCEDURE q (i INTEGER) RETURNS (l VARCHAR(15)) AS BEGIN SELECT language_req[:i] FROM job WHERE job_code = 'x' INTO :l; END",
        );
        let source = compile_procedure_full(
            "CREATE PROCEDURE r (code VARCHAR(5)) RETURNS (lang VARCHAR(15)) AS BEGIN FOR SELECT languages FROM show_langs(:code, 1, 'USA') INTO :lang DO SUSPEND; END",
        );
        let parenless = compile_procedure_full(
            "CREATE PROCEDURE d (dno CHAR(3)) RETURNS (t INTEGER) AS DECLARE VARIABLE s INTEGER; BEGIN EXECUTE PROCEDURE d :dno RETURNING_VALUES :s; t = s; END",
        );
        let paren = compile_procedure_full(
            "CREATE PROCEDURE d (dno CHAR(3)) RETURNS (t INTEGER) AS DECLARE VARIABLE s INTEGER; BEGIN EXECUTE PROCEDURE d(:dno) RETURNING_VALUES :s; t = s; END",
        );
        set_catalog(Vec::new());
        let comma = comma.expect("comma join compiles");
        // measured: a flat rse of TWO streams, no join heads
        assert!(comma.blob.windows(2).any(|w| w == [blr::RSE, 2]));
        assert!(!comma.blob.contains(&blr::JOIN));
        let elem = elem.expect("array element compiles");
        assert!(elem.blob.contains(&blr::INDEX));
        let source = source.expect("procedure source compiles");
        assert!(source.blob.contains(&blr::PROCEDURE));
        assert_eq!(parenless.expect("paren-less").blob, paren.expect("paren").blob);
    }
}
