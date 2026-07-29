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
    /// blr_fid - a stream's own column by number; how HAVING, ORDER
    /// BY and the DO body address an aggregate's output
    Fid(u8, u16),
    /// a DECLAREd sub-function call: blr_invoke_function, the id
    /// clause (sub + counted name), counted argument values (probed)
    SubFn(String, Vec<Val>),
    /// `:name` - an INPUT parameter, referenced straight out of
    /// message 0 as blr_parameter2 (value slot 2i, null slot 2i+1);
    /// no variable is declared for inputs (probed)
    InParam(u16),
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
    /// GEN_ID(sequence, increment)
    GenId(String, Box<Val>),
    /// NEXT VALUE FOR sequence - blr_gen_id2, the name alone
    GenId2(String),
    /// blr_coalesce
    Coalesce(Vec<Val>),
}

/// A cast target descriptor, exactly the dsc bytes blr_cast carries
/// (each layout probed: numerics are dtype + scale, texts carry a
/// 2-byte charset then a 2-byte length, temporals are the dtype alone)
#[derive(Clone, Copy, Debug, PartialEq)]
enum Dsc {
    /// blr_short / blr_long / blr_int64 with a scale byte
    Num(u8, i8),
    /// blr_text2, charset 0 (a NONE-charset database), length
    Text(u16),
    /// blr_varying2, charset 0, length
    Varying(u16),
    Date,
    Time,
    Timestamp,
}

fn emit_dsc(out: &mut Vec<u8>, d: Dsc) {
    match d {
        Dsc::Num(dt, sc) => {
            out.push(dt);
            out.push(sc as u8);
        }
        Dsc::Text(l) => {
            out.push(blr::TEXT2);
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&l.to_le_bytes());
        }
        Dsc::Varying(l) => {
            out.push(blr::VARYING2);
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&l.to_le_bytes());
        }
        Dsc::Date => out.push(blr::DATE),
        Dsc::Time => out.push(blr::TIME),
        Dsc::Timestamp => out.push(blr::TIMESTAMP),
    }
}

/// A branch's contribution to the unified descriptor of a value_if
/// chain. Only literals and explicit CASTs contribute - a FIELD
/// branch's descriptor lives in the catalog, so it REFUSES (same
/// principle as bare multi-stream fields: never guess a descriptor).
enum BranchDsc {
    /// exact-numeric: (integer digits, scale<=0)
    Num(i32, i8),
    Text(u16),
    /// NULL - ignored by unification (probed: the missing-ELSE null
    /// leaves the dsc to the real branches)
    Skip,
}

fn branch_dsc(v: &Val) -> Option<BranchDsc> {
    Some(match v {
        Val::Int(_) => BranchDsc::Num(9, 0),
        Val::Int64(_) => BranchDsc::Num(18, 0),
        // a decimal literal is blr_long at its written scale (the
        // stored scale is ALREADY negative: 1.5 is (15, -1)): 9
        // digits of precision, |scale| of them fractional
        Val::Dec(_, sc) => BranchDsc::Num(9 + *sc as i32, *sc),
        Val::Str(t) => BranchDsc::Text(u16::try_from(t.len()).ok()?),
        Val::Null => BranchDsc::Skip,
        Val::Cast(d, _) => match d {
            Dsc::Num(dt, sc) => {
                let prec = match *dt {
                    blr::SHORT => 4,
                    blr::LONG => 9,
                    blr::INT64 => 18,
                    _ => return None,
                };
                BranchDsc::Num(prec + *sc as i32, *sc)
            }
            Dsc::Text(l) => BranchDsc::Text(*l),
            // varying / temporal branches: unification not yet probed
            _ => return None,
        },
        _ => return None,
    })
}

/// The UNIFIED descriptor the engine's DSQL computes for a value_if
/// chain, probed law by law: NULL branches are ignored; all-text
/// branches unify to blr_text2 at the MAXIMUM length ('yes'/'no' ->
/// CHAR(3)); exact numerics take the MAXIMUM integer-digit count and
/// the MINIMUM scale, then the dtype that FITS the total digit count
/// (<=4 short, <=9 long, else int64) - which is why long(scale 0)
/// united with long(scale -1) WIDENS to int64: 9 + 1 = 10 digits
fn unify_branches(branches: &[&Val]) -> Option<Dsc> {
    let mut num: Option<(i32, i8)> = None;
    let mut text: Option<u16> = None;
    let mut seen = false;
    for b in branches {
        match branch_dsc(b)? {
            BranchDsc::Skip => continue,
            BranchDsc::Num(ints, sc) => {
                if text.is_some() {
                    return None; // text/numeric mixtures: unprobed
                }
                let (i0, s0) = num.unwrap_or((ints, sc));
                num = Some((i0.max(ints), s0.min(sc)));
                seen = true;
            }
            BranchDsc::Text(l) => {
                if num.is_some() {
                    return None;
                }
                text = Some(text.unwrap_or(0).max(l));
                seen = true;
            }
        }
    }
    if !seen {
        return None; // all-NULL: the engine's choice is unprobed
    }
    if let Some(l) = text {
        return Some(Dsc::Text(l));
    }
    let (ints, sc) = num?;
    let needed = ints - sc as i32;
    let dt = if needed <= 4 {
        blr::SHORT
    } else if needed <= 9 {
        blr::LONG
    } else {
        blr::INT64
    };
    Some(Dsc::Num(dt, sc))
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
    AnsiAny(CmpOp, Val, SubQ),
    /// `<left> <cmp> ALL (SELECT ...)` and NOT IN - blr_ansi_all
    AnsiAll(CmpOp, Val, SubQ),
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
        keep @ (Bool::Missing(_) | Bool::Like(..) | Bool::InList(..)) => {
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
    /// a derived table `(SELECT cols FROM name [WHERE ...]) alias`:
    /// emitted as an rse-within-a-stream-slot whose relation2 alias
    /// text is `"ALIAS" "PUBLIC"."NAME"` - the schema-qualified
    /// underlying table rides along (probed); the WHOLE derived table
    /// has ONE context, shared by inner and outer references
    derived: Option<Box<Derived>>,
    /// inside a SUBROUTINE body every stream emits blr_relation3
    /// with an explicit schema and empty package (probed)
    sub: bool,
}

#[derive(Clone, Debug, PartialEq)]
struct Derived {
    wher: Option<Bool>,
}

/// One slot of an aggregate's blr_map: a group-key value or an
/// aggregate function (verb + optional operand).
#[derive(Clone, Debug, PartialEq)]
enum MapEntry {
    Key(Val),
    Agg(u8, Option<Val>),
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
    /// the procedure's INPUT parameter names, in message-0 order;
    /// `:name` in an expression resolves against this
    in_params: Vec<String>,
    /// local variable names declared in a trigger body, in
    /// declaration order; a bare name resolves here FIRST
    local_vars: Vec<String>,
    /// the next free label number (0 is the body wrapper's)
    next_label: u8,
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
    /// while parsing a MERGE's ON/SET/VALUES: the (source, target)
    /// stream indexes - the ONLY two streams qualified names may
    /// bind to there, and bare column names refuse
    merge_scope: Option<(usize, usize)>,
    /// a FUNCTION body: RETURN allowed, SUSPEND refused
    in_func: bool,
    /// a SUBROUTINE body: nested subroutine declarations refuse
    in_sub: bool,
    /// a SUSPEND was parsed - the subproc_decl's selectable flag
    saw_suspend: bool,
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
            in_params: Vec::new(),
            local_vars: Vec::new(),
            next_label: 1,
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
            sub_decls: Vec::new(),
            sub_procs: Vec::new(),
            sub_funcs: Vec::new(),
        }
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
        // inside a MERGE's ON/SET/VALUES only the source and target
        // streams are visible, and bare names refuse (catalog-free -
        // the engine resolves them through column lists)
        if let Some((si, ti)) = self.merge_scope {
            let q = qualifier?;
            let hit = |st: &Stream| {
                st.alias.as_deref().map_or(st.name == q, |a| a == q)
            };
            let idx = [si, ti]
                .into_iter()
                .find(|&i| hit(&self.streams[i]))?;
            return Some(Val::Field(idx as u8 + self.base, name.to_string()));
        }
        let n_outer = self.outer.unwrap_or(self.streams.len());
        let ctx = match qualifier {
            Some(q) => {
                let hit = |st: &Stream| {
                    st.alias.as_deref().map_or(st.name == q, |a| a == q)
                };
                let idx = self
                    .streams
                    .iter()
                    .take(n_outer)
                    .position(hit)
                    .or_else(|| {
                        self.sub
                            .filter(|&si| hit(&self.streams[si]))
                    })?;
                idx as u8 + self.base
            }
            None => match self.sub {
                Some(si) => si as u8 + self.base,
                None => {
                    if n_outer != 1 {
                        return None;
                    }
                    self.base
                }
            },
        };
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
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        self.i += 1;
        let alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        Some(Stream { name, alias, derived: None, sub: self.in_sub })
    }

    /// A derived table: pass-through column list, ONE underlying
    /// table, an optional inner WHERE (whose bare names bind to the
    /// derived stream - it has the only visible context), a REQUIRED
    /// alias. The stream is pushed while the inner WHERE parses (its
    /// fields need the context id) and popped for the caller to
    /// re-push at the same index.
    fn derived_item(&mut self) -> Option<Stream> {
        if self.in_sub {
            return None; // derived tables in subroutines: unprobed
        }
        self.i += 1; // (
        if !self.kw("SELECT") {
            return None;
        }
        // the pass-through list: bare columns only (they leave no
        // trace; outer references go by NAME through the shared
        // context, which is exactly the pass-through case)
        loop {
            match self.t.get(self.i)? {
                Tok::Ident(w) if w == "FROM" => {
                    self.i += 1;
                    break;
                }
                Tok::Ident(w) if !is_keyword(w) => self.i += 1,
                Tok::Comma => self.i += 1,
                _ => return None, // *, expressions, quals: unprobed
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
        self.streams.push(Stream {
            name: name.clone(),
            alias: None,
            derived: None,
            sub: self.in_sub,
        });
        let si = self.streams.len() - 1;
        let saved = self.sub.replace(si);
        let wher = if self.kw("WHERE") {
            Some(self.bool_or()?)
        } else {
            None
        };
        self.sub = saved;
        self.streams.pop();
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        let Some(Tok::Ident(alias)) = self.t.get(self.i) else {
            return None; // an alias-less derived table: unprobed
        };
        if is_keyword(alias) {
            return None;
        }
        let alias = alias.clone();
        self.i += 1;
        Some(Stream {
            name,
            alias: Some(alias),
            derived: Some(Box::new(Derived { wher })),
            sub: self.in_sub,
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
                _ => return None,
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
    fn subselect(&mut self, need_col: bool) -> Option<SubQ> {
        if self.outer.is_none() {
            // a subquery inside an ON clause would interleave the
            // join chain's stream numbering: unprobed, refuse
            return None;
        }
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        if !self.kw("SELECT") {
            return None;
        }
        // capture the select list positionally; resolve after the
        // stream exists
        let mut col: Option<(Option<String>, String)> = None;
        if need_col {
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
        if self.base != 1 {
            return None; // subqueries in procedure bodies: unprobed
        }
        let stream = self.stream_item()?;
        self.streams.push(stream.clone());
        let si = self.streams.len() - 1;
        let ctx = (si + 1) as u8;
        // the subquery scope: bare names bind to ITS stream
        let saved = self.sub.replace(si);
        let col = match col {
            None => None,
            Some((q, n)) => Some(self.field(q.as_deref(), &n)?),
        };
        let wher = if self.kw("WHERE") {
            Some(Box::new(self.bool_or()?))
        } else {
            None
        };
        self.sub = saved;
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None; // joins, comma-FROM etc. in a subquery: unconverted
        }
        self.i += 1;
        Some(SubQ { stream, ctx, wher, col })
    }

    /// expression grammar mirroring the engine's precedence:
    /// `+`/`-` over `*`/`/` over unary `-` over `||` over atoms
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

    fn val_atom(&mut self) -> Option<Val> {
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
                // a qualified field: IDENT . IDENT
                if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                    self.i += 1;
                    let Some(Tok::Ident(f)) = self.t.get(self.i) else {
                        return None;
                    };
                    let f = f.clone();
                    self.i += 1;
                    return self.field(Some(&first), &f);
                }
                return self.field(None, &first);
            }
            Tok::Int(n) => match i32::try_from(*n) {
                Ok(v) => Val::Int(v),
                Err(_) => Val::Int64(*n),
            },
            Tok::Dec(r, s) => Val::Dec(i32::try_from(*r).ok()?, *s),
            Tok::Str(s) => Val::Str(s.clone()),
            Tok::LParen => {
                // a scalar subselect as a value: blr_via(singular)
                if matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SELECT")
                {
                    return Some(Val::ScalarSub(Box::new(self.subselect(true)?)));
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
        self.i += 1; // (
        let v = match name {
            "UPPER" => Val::Upper(Box::new(self.val()?)),
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
                if !self.kw("FOR") {
                    return None; // FOR-less substring: not yet probed
                }
                let len = self.val()?;
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
                let dsc = unify_branches(&[&Val::Null, &a])?;
                Val::Cast(
                    dsc,
                    Box::new(Val::ValueIf(
                        Box::new(Bool::Cmp(CmpOp::Eql, a.clone(), b)),
                        Box::new(Val::Null),
                        Box::new(a),
                    )),
                )
            }
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
                let dsc = unify_branches(&[&a, &b])?;
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
            let dsc = unify_branches(&branches)?;
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
                    } else {
                        return None; // INT128 territory: unprobed
                    };
                    Dsc::Num(dt, -sc)
                }
            },
            "VARCHAR" => {
                let (l, sc) = paren_num(self)?;
                if sc != 0 {
                    return None;
                }
                Dsc::Varying(u16::try_from(l).ok()?)
            }
            "CHAR" | "CHARACTER" => {
                let (l, sc) = paren_num(self)?;
                if sc != 0 {
                    return None;
                }
                Dsc::Text(u16::try_from(l).ok()?)
            }
            "DATE" => Dsc::Date,
            "TIME" => Dsc::Time,
            "TIMESTAMP" => Dsc::Timestamp,
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
            let body = Bool::Like(left, pat);
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
            // the engine CASTS non-integer IN-list items to the
            // LEFT SIDE's catalog type (probed: S IN ('a','b') stores
            // each item under blr_cast varying2(10) - the column's
            // declared type, in views and CHECKs alike). Integer
            // literals and input parameters are the probed UNCAST
            // cases; anything else needs the catalog and refuses.
            if items.iter().any(|it| {
                !matches!(it, Val::Int(_) | Val::Int64(_) | Val::InParam(_))
            }) {
                return None;
            }
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
            emit_stream(out, &sub.stream, sub.ctx);
            if let Some(w) = &sub.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
            emit_val(out, sub.col.as_ref().expect("scalar subselect has a column"));
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
            out.extend_from_slice(&0u16.to_le_bytes()); // charset (NONE)
            out.extend_from_slice(&(s.len() as u16).to_le_bytes());
            out.extend_from_slice(s.as_bytes());
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
                sub.col.as_ref().expect("quantified subquery has a column"),
            );
            out.push(blr::END);
        }
    }
}

/// One relation stream: plain (blr_relation) or aliased
/// (blr_relation2, the alias UPPERCASED IN DOUBLE QUOTES - probed).
fn emit_stream(out: &mut Vec<u8>, st: &Stream, ctx: u8) {
    if let Some(d) = &st.derived {
        // a derived table is an rse in the stream slot; its relation2
        // alias text carries the alias AND the schema-qualified
        // underlying table (probed: `(SELECT ID FROM T) X` stores
        // `"X" "PUBLIC"."T"`); inner and outer references share the
        // ONE context
        out.push(blr::RSE);
        out.push(1);
        out.push(blr::RELATION2);
        out.push(st.name.len() as u8);
        out.extend_from_slice(st.name.as_bytes());
        let alias = st.alias.as_deref().unwrap_or("");
        let text = format!("\"{}\" \"PUBLIC\".\"{}\"", alias, st.name);
        out.push(text.len() as u8);
        out.extend_from_slice(text.as_bytes());
        out.push(ctx);
        if let Some(w) = &d.wher {
            out.push(blr::BOOLEAN);
            emit_bool(out, w);
        }
        out.push(blr::END);
        return;
    }
    if st.sub {
        // a subroutine body qualifies every relation: blr_relation3
        // with schema PUBLIC, an empty package, and the alias slot
        // ALWAYS present - the quoted alias or a counted empty
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

/// The blr_relation3 head: schema PUBLIC, empty package, the name -
/// the caller appends the alias slot and context.
fn emit_relation3(out: &mut Vec<u8>, name: &str) {
    out.push(blr::RELATION3);
    out.push(6);
    out.extend_from_slice(b"PUBLIC");
    out.push(0);
    out.push(name.len() as u8);
    out.extend_from_slice(name.as_bytes());
}

/// Compile a view-shaped SELECT to the BLR the engine's DSQL stores in
/// `RDB$VIEW_BLR` - byte for byte. `None` for anything outside the
/// converted surface (the caller refuses; this crate never guesses).
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
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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
fn map_val_to_fid(map: &[MapEntry], v: &Val, fid_ctx: u8) -> Option<Val> {
    match v {
        Val::Field(..) => {
            let idx = map
                .iter()
                .position(|e| matches!(e, MapEntry::Key(k) if k == v))?;
            Some(Val::Fid(fid_ctx, idx as u16))
        }
        Val::Fid(..) | Val::Int(_) | Val::Int64(_) | Val::Dec(..) | Val::Str(_) | Val::Null => {
            Some(v.clone())
        }
        Val::Add(a, b) | Val::Sub(a, b) | Val::Mul(a, b) | Val::Div(a, b)
        | Val::Concat(a, b) => {
            let (a, b) = (
                map_val_to_fid(map, a, fid_ctx)?,
                map_val_to_fid(map, b, fid_ctx)?,
            );
            Some(match v {
                Val::Add(..) => Val::Add(Box::new(a), Box::new(b)),
                Val::Sub(..) => Val::Sub(Box::new(a), Box::new(b)),
                Val::Mul(..) => Val::Mul(Box::new(a), Box::new(b)),
                Val::Div(..) => Val::Div(Box::new(a), Box::new(b)),
                _ => Val::Concat(Box::new(a), Box::new(b)),
            })
        }
        Val::Neg(a) => Some(Val::Neg(Box::new(map_val_to_fid(map, a, fid_ctx)?))),
        // anything richer over an aggregate's output: unprobed
        _ => None,
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
    if d.sub {
        emit_relation3(out, &d.table);
    } else {
        out.push(blr::RELATION2);
        out.push(d.table.len() as u8);
        out.extend_from_slice(d.table.as_bytes());
    }
    let alias = match &d.alias {
        Some(a) => format!("\"{}\" \"{}\"", d.name, a),
        None => format!("\"{}\" \"PUBLIC\".\"{}\"", d.name, d.table),
    };
    out.push(alias.len() as u8);
    out.extend_from_slice(alias.as_bytes());
    out.push(d.ctx);
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
        for (fi, e) in d.map.iter().enumerate() {
            out.extend_from_slice(&(fi as u16).to_le_bytes());
            match e {
                MapEntry::Key(v) => emit_val(out, v),
                MapEntry::Agg(verb, arg) => {
                    out.push(*verb);
                    if let Some(a) = arg {
                        emit_val(out, a);
                    }
                }
            }
        }
    }
    if !d.sort.is_empty() {
        out.push(blr::SORT);
        out.push(d.sort.len() as u8);
        for (desc, key) in &d.sort {
            out.push(if *desc {
                blr::DESCENDING
            } else {
                blr::ASCENDING
            });
            emit_val(out, key);
        }
    }
    out.push(blr::END);
    out.extend_from_slice(&(d.outs.len() as u16).to_le_bytes());
    for o in &d.outs {
        if d.agg.is_none() {
            out.push(blr::DERIVED_EXPR);
            out.push(1);
            out.push(d.ctx);
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
    ins: Vec<String>,
    outs: Vec<String>,
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
fn body_compile(p: &mut P, func: bool, sub: bool) -> Option<BodyOut> {
    // optional INPUT parameters: message 0, one dsc + null-flag short
    // per parameter, NO EOF slot
    let mut inputs: Vec<(String, Dsc)> = Vec::new();
    if matches!(p.t.get(p.i), Some(Tok::LParen)) {
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
            let dsc = p.cast_target()?;
            inputs.push((name, dsc));
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
    p.outer = Some(0);
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
    if stmts.is_empty() {
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
    out.push(blr::BEGIN);
    for st in &stmts {
        emit_trig_stmt(&mut out, st);
    }
    out.push(blr::END);
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
        ins: inputs.into_iter().map(|(n, _)| n).collect(),
        outs: params.into_iter().map(|(n, _)| n).collect(),
        selectable: p.saw_suspend,
        deterministic,
    })
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
    ExceptionRaise(String),
    /// EXIT; - blr_leave 0: leaves the wrapper label
    Exit,
    /// POST_EVENT <value>; - blr_post
    PostEvent(Val),
    /// BEGIN ... WHEN <code> DO <stmt> ... END - blr_block with one
    /// error-handler section PER WHEN (probed sequential)
    HandledBlock(Vec<TrigStmt>, Vec<(HandlerCode, TrigStmt)>),
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
    ExecSql(String),
    /// RETURN <expr>; in a function body: begin(assign to the
    /// unnamed slot 0, the no-EOF send, blr_leave 0) end (probed)
    Return(Val),
    /// EXECUTE PROCEDURE on a DECLAREd subroutine:
    /// blr_invoke_procedure, id clause (sub + counted name), input
    /// values, output variables (probed)
    SubCall(String, Vec<Val>, Vec<u16>),
    /// [FOR] EXECUTE STATEMENT '<sql>' INTO :v, ...: blr_exec_into,
    /// u16 out-count, the sql, then flag 1 (singleton) or flag 0 +
    /// the labeled loop's DO statement; the variables LAST (probed)
    ExecInto {
        sql: String,
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
        sql: String,
        ins: Vec<(Option<String>, Val)>,
        vars: Vec<u16>,
        data_src: Option<Val>,
        user: Option<Val>,
        pwd: Option<Val>,
        role: Option<Val>,
        run: Option<(u8, Box<TrigStmt>)>,
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
    aggregate: bool,
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
        TrigStmt::ExceptionRaise(name) => {
            out.push(blr::ABORT);
            out.push(2);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        TrigStmt::Exit => {
            out.push(blr::LEAVE);
            out.push(0);
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
            for (code, handler) in handlers {
                out.push(blr::ERROR_HANDLER);
                out.extend_from_slice(&1u16.to_le_bytes());
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
                // a BLOCK as the handler's body nests blr_block AGAIN
                // with no handler section of its own (probed)
                match handler {
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
            emit_val(out, &Val::Str(sql.clone()));
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
            emit_val(out, &Val::Str(sql.clone()));
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
            emit_val(out, &Val::Str(sql.clone()));
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
            out.push(1);
            if f.aggregate {
                out.push(blr::AGGREGATE);
                out.push(f.ctx + 1);
                out.push(blr::RSE);
                out.push(1);
                emit_stream(out, &f.stream, f.ctx);
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
                for (fi, e) in f.map.iter().enumerate() {
                    out.extend_from_slice(&(fi as u16).to_le_bytes());
                    match e {
                        MapEntry::Key(v) => emit_val(out, v),
                        MapEntry::Agg(verb, arg) => {
                            out.push(*verb);
                            if let Some(a) = arg {
                                emit_val(out, a);
                            }
                        }
                    }
                }
                if let Some(h) = &f.having {
                    out.push(blr::BOOLEAN);
                    emit_bool(out, h);
                }
            } else if let Some(cn) = &f.cursor {
                // AS CURSOR: the name rides the relation2 alias
                // exactly like a DECLAREd cursor's - relation3 with
                // the same alias string inside a subroutine (probed)
                if f.stream.sub {
                    emit_relation3(out, &f.stream.name);
                } else {
                    out.push(blr::RELATION2);
                    out.push(f.stream.name.len() as u8);
                    out.extend_from_slice(f.stream.name.as_bytes());
                }
                let alias =
                    format!("\"{}\" \"PUBLIC\".\"{}\"", cn, f.stream.name);
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
                    out.push(if *desc {
                        blr::DESCENDING
                    } else {
                        blr::ASCENDING
                    });
                    emit_val(out, key);
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
        if self.kw("FIRST") {
            let Some(Tok::Int(v)) = self.t.get(self.i) else {
                return None;
            };
            first = Some(Val::Int(i32::try_from(*v).ok()?));
            self.i += 1;
        }
        if self.kw("SKIP") {
            let Some(Tok::Int(v)) = self.t.get(self.i) else {
                return None;
            };
            skip = Some(Val::Int(i32::try_from(*v).ok()?));
            self.i += 1;
        }
        if !is_for && (first.is_some() || skip.is_some()) {
            return None; // FIRST/SKIP in the singular form: unprobed
        }
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
        let stream = self.stream_item()?;
        if stream.derived.is_some() {
            return None; // derived FOR streams: unprobed
        }
        self.streams.push(stream.clone());
        let sidx = self.streams.len() - 1;
        let ctx = sidx as u8 + self.base;
        let after_from = self.i;
        self.i = list_start;
        enum Item {
            Col(Val),
            Agg(u8, Option<Val>),
        }
        let saved_sub = self.sub.replace(sidx);
        let mut items: Vec<Item> = Vec::new();
        loop {
            match self.t.get(self.i)? {
                Tok::Ident(w)
                    if matches!(
                        w.as_str(),
                        "COUNT" | "SUM" | "AVG" | "MIN" | "MAX"
                    ) && matches!(self.t.get(self.i + 1), Some(Tok::LParen)) =>
                {
                    let w = w.clone();
                    self.i += 1;
                    let (verb, arg) = self.parse_agg(&w)?;
                    items.push(Item::Agg(verb, arg));
                }
                Tok::Ident(w) if !is_keyword(w) => {
                    let a = w.clone();
                    self.i += 1;
                    let v = if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                        self.i += 1;
                        let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                            return None;
                        };
                        let b = b.clone();
                        self.i += 1;
                        self.field(Some(&a), &b)?
                    } else {
                        // a select column, NOT a variable: resolve as
                        // a field of the select's own stream
                        Val::Field(ctx, a)
                    };
                    items.push(Item::Col(v));
                }
                _ => return None,
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
        let cols_n = items.len();
        if cols_n == 0 {
            return None;
        }
        let has_aggs = items.iter().any(|it| matches!(it, Item::Agg(..)));
        let boolean = if self.kw("WHERE") {
            Some(self.bool_or()?)
        } else {
            None
        };
        let mut group_keys: Vec<Val> = Vec::new();
        let grouped = self.kw("GROUP");
        if grouped {
            if !self.kw("BY") {
                return None;
            }
            loop {
                let key = match self.t.get(self.i)? {
                    Tok::Ident(w) if !is_keyword(w) => {
                        let a = w.clone();
                        self.i += 1;
                        if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                            self.i += 1;
                            let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                                return None;
                            };
                            let b = b.clone();
                            self.i += 1;
                            self.field(Some(&a), &b)?
                        } else {
                            Val::Field(ctx, a)
                        }
                    }
                    _ => return None,
                };
                group_keys.push(key);
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        let aggregate = has_aggs || grouped;
        if aggregate {
            if !has_aggs {
                return None; // grouped-without-aggs: unprobed
            }
            if first.is_some() || skip.is_some() {
                return None;
            }
            // the aggregate node takes the NEXT context (stream + 1,
            // probed at 1-over-0 and 3-over-2); claim its slot so
            // later statements keep counting correctly
            self.agg_fid_ctx = ctx + 1;
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
            });
            for it in &items {
                if let Item::Col(v) = it {
                    if !group_keys.contains(v) {
                        return None;
                    }
                }
            }
            self.agg_map = items
                .iter()
                .map(|it| match it {
                    Item::Col(v) => MapEntry::Key(v.clone()),
                    Item::Agg(verb, arg) => MapEntry::Agg(*verb, arg.clone()),
                })
                .collect();
        }
        let having = if self.kw("HAVING") {
            if !aggregate {
                return None;
            }
            self.agg_mode = true;
            let b = self.bool_or()?;
            self.agg_mode = false;
            Some(map_bool_to_fids(&self.agg_map, b, ctx + 1)?)
        } else {
            None
        };
        let mut sort: Vec<(bool, Val)> = Vec::new();
        if self.kw("ORDER") {
            if !self.kw("BY") {
                return None;
            }
            loop {
                let key = match self.t.get(self.i)? {
                    Tok::Ident(w) if !is_keyword(w) => {
                        let a = w.clone();
                        self.i += 1;
                        if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                            self.i += 1;
                            let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                                return None;
                            };
                            let b = b.clone();
                            self.i += 1;
                            self.field(Some(&a), &b)?
                        } else {
                            Val::Field(ctx, a)
                        }
                    }
                    _ => return None,
                };
                let key = if aggregate {
                    map_val_to_fid(&self.agg_map, &key, ctx + 1)?
                } else {
                    key
                };
                let descending = if self.kw("DESC") {
                    true
                } else {
                    let _ = self.kw("ASC");
                    false
                };
                sort.push((descending, key));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        self.sub = saved_sub;
        let col_vals: Vec<Val> = if aggregate {
            (0..cols_n).map(|i| Val::Fid(ctx + 1, i as u16)).collect()
        } else {
            items
                .iter()
                .map(|it| match it {
                    Item::Col(v) => Some(v.clone()),
                    Item::Agg(..) => None,
                })
                .collect::<Option<Vec<_>>>()?
        };
        // WITH LOCK - probed beside a WHERE and alone; the shapes
        // beyond the probes (aggregates, FIRST/SKIP, ORDER BY) refuse
        let lock = if self.kw("WITH") {
            if !self.kw("LOCK")
                || aggregate
                || first.is_some()
                || skip.is_some()
                || !sort.is_empty()
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
                if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                    return None;
                }
                self.i += 1;
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
            // an ALIASED stream under AS CURSOR: the alias string's
            // shape is unprobed - refuse
            if aggregate
                || first.is_some()
                || skip.is_some()
                || !sort.is_empty()
                || stream.alias.is_some()
            {
                return None;
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
            let body = self.trig_stmt()?;
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
        Some(TrigStmt::ForSel(Box::new(ForSel {
            label,
            stream,
            ctx,
            cursor,
            lock,
            aggregate,
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
        })))
    }


    /// The parameterized EXECUTE STATEMENT head: ('<literal sql>')
    /// (val [, ...] | name := val [, ...]) - self.i at the opening
    /// paren of the sql. All parameters named or all unnamed (the
    /// two live under different tags - mixing refuses).
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
            if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                return None;
            }
            self.i += 1;
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
            if d.agg.is_some() {
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
            for n in list.iter() {
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
                items.push(RawItem::Col(q, n));
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
        });
        let sidx = self.streams.len() - 1;
        let ctx = sidx as u8 + self.base;
        let aggregate = items
            .iter()
            .any(|it| matches!(it, RawItem::Agg(..)));
        // the aggregate claims the NEXT context slot (probed:
        // a second cursor's aggregate sat at ctx 2 over its
        // stream's 1)
        let agg = if aggregate {
            self.streams.push(Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: self.in_sub,
            });
            Some((self.streams.len() - 1) as u8 + self.base)
        } else {
            None
        };
        let resolve = |q: &Option<String>, n: &str| -> Option<Val> {
            if let Some(q) = q {
                let hit = alias.as_deref().map_or(tbl == *q, |a| a == q);
                if !hit {
                    return None;
                }
            }
            Some(Val::Field(ctx, n.to_string()))
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
                }
                outs.push(Val::Fid(agg_ctx, (outs.len()) as u16));
            }
        } else {
            for it in &items {
                let RawItem::Col(q, n) = it else {
                    return None;
                };
                outs.push(resolve(q, n)?);
            }
        }
        let saved = self.sub.replace(sidx);
        let boolean = if self.kw("WHERE") {
            Some(self.bool_or()?)
        } else {
            None
        };
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
                sort.push((descending, key));
                if matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                } else {
                    break;
                }
            }
        }
        self.sub = saved;
        // WITH LOCK - refused over aggregates and sorts (unprobed)
        let lock = if self.kw("WITH") {
            if !self.kw("LOCK") || aggregate || !sort.is_empty() {
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

    /// one trigger-body statement; self.i past any leading keyword
    fn trig_stmt(&mut self) -> Option<TrigStmt> {
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
            let mut handlers: Vec<(HandlerCode, TrigStmt)> = Vec::new();
            while self.kw("WHEN") {
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
                if !self.kw("DO") {
                    return None;
                }
                // a handler's body may itself carry handlers - the
                // nested block emits blr_block again, WITH its own
                // error-handler section (probed)
                let h = self.trig_stmt()?;
                handlers.push((code, h));
            }
            if !self.kw("END") {
                return None;
            }
            // an optional ; after END
            if matches!(self.t.get(self.i), Some(Tok::Semi)) {
                self.i += 1;
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
                let (sql, ins) =
                    if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                        self.exec_stmt_head()?
                    } else {
                        let Some(Tok::Str(sql)) = self.t.get(self.i) else {
                            return None;
                        };
                        let sql = sql.clone();
                        self.i += 1;
                        (sql, Vec::new())
                    };
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
                    if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                        return None;
                    }
                    self.i += 1;
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
                let body = Box::new(self.trig_stmt()?);
                return Some(if full {
                    TrigStmt::ExecStmtFull {
                        sql,
                        ins,
                        vars,
                        data_src,
                        user,
                        pwd,
                        role,
                        run: Some((label, body)),
                    }
                } else {
                    TrigStmt::ExecInto {
                        sql,
                        vars,
                        run: Some((label, body)),
                    }
                });
            }
            if !self.kw("SELECT") {
                return None;
            }
            return self.select_stmt(true);
        }
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "SELECT") {
            self.i += 1;
            return self.select_stmt(false);
        }
        if self.kw("EXECUTE") {
            // EXECUTE STATEMENT '<literal sql>' [INTO :v, ...]; -
            // expression sql, USING, external data sources: unprobed
            if self.kw("STATEMENT") {
                // sql: a bare literal or the parenthesized head with
                // parameters; then the optional modifiers - either
                // of which forces the FULL blr_exec_stmt form
                let (sql, ins) =
                    if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                        self.exec_stmt_head()?
                    } else {
                        let Some(Tok::Str(sql)) = self.t.get(self.i) else {
                            return None;
                        };
                        let sql = sql.clone();
                        self.i += 1;
                        (sql, Vec::new())
                    };
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
                        if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                            return None;
                        }
                        self.i += 1;
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
                return Some(if full {
                    TrigStmt::ExecStmtFull {
                        sql,
                        ins,
                        vars,
                        data_src,
                        user,
                        pwd,
                        role,
                        run: None,
                    }
                } else if vars.is_empty() {
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
            let name = name.clone();
            self.i += 1;
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
            }
            let mut outs = Vec::new();
            if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "RETURNING_VALUES")
            {
                self.i += 1;
                loop {
                    if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                        return None;
                    }
                    self.i += 1;
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
            let Some(Tok::Ident(name)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(name) {
                return None;
            }
            let name = name.clone();
            self.i += 1;
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::ExceptionRaise(name));
        }
        if self.kw("EXIT") {
            if !matches!(self.t.get(self.i), Some(Tok::Semi)) {
                return None;
            }
            self.i += 1;
            return Some(TrigStmt::Exit);
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
                if !matches!(self.t.get(self.i), Some(Tok::Colon)) {
                    return None;
                }
                self.i += 1;
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
            let body = Box::new(self.trig_stmt()?);
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
            self.merge_scope = Some((src_idx, tgt_idx));
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
                });
                let new_ctx = (self.streams.len() - 1) as u8 + base;
                self.streams.push(Stream {
                    name: String::new(),
                    alias: None,
                    derived: None,
                    sub: self.in_sub,
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
            });
            let new_ctx = (self.streams.len() - 1) as u8 + self.base;
            let st = Stream {
                name: rel,
                alias: rel_alias,
                derived: None,
                sub: self.in_sub,
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
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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
        }],
        base: 0,
        outer: Some(1),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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

/// Compile a CHECK constraint to the BLR the engine stores as its
/// system trigger (`RDB$TRIGGERS`, types 1 and 3 - byte-identical):
/// blr_begin, blr_if over the NEGATED condition whose then-branch is
/// blr_abort with blr_gds_code 'check_constraint', a bare blr_end in
/// the else slot, blr_end, blr_eoc. Fields sit at CONTEXT 1 (the NEW
/// record). The negation reuses the same fold as NOT (probed:
/// CHECK (A < B) stores blr_geq).
pub fn compile_check(sql: &str) -> Option<Vec<u8>> {
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
            },
            Stream {
                name: String::new(),
                alias: None,
                derived: None,
                sub: false,
            },
        ],
        base: 0,
        outer: Some(0),
        sub: Some(1),
        agg_map: Vec::new(),
        agg_mode: false,
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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
            },
            Stream {
                name: "NEW".to_string(),
                alias: None,
                derived: None,
                sub: false,
            },
        ],
        base: 0,
        outer: Some(2),
        sub: None,
        agg_map: Vec::new(),
        agg_mode: false,
        in_params: Vec::new(),
        local_vars: Vec::new(),
        next_label: 1,
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
    if p.i != p.t.len() || stmts.is_empty() {
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
    out.extend_from_slice(&[blr::LABEL, 0, blr::BEGIN, blr::BEGIN]);
    for st in &stmts {
        emit_trig_stmt(&mut out, st);
    }
    out.push(blr::END);
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

/// `compile_procedure` as uppercase hex.
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
            // EXECUTE STATEMENT with an expression sql: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS DECLARE V1 VARCHAR(50); BEGIN EXECUTE STATEMENT V1 INTO :R1; SUSPEND; END",
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
            // bare LEAVE/loop control: unconverted
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN WHILE (1 = 1) DO LEAVE; END",
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
            // INSERT ... SELECT: unprobed
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN INSERT INTO U2 (UID) SELECT ID FROM T; END",
        ] {
            assert!(compile_trigger(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn trigger_refusals() {
        for sql in [
            // OLD targets are read-only in the engine
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN OLD.A = 5; END",
            // bare column names are ambiguous between OLD and NEW
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN A = 5; END",
            // an empty body stores nothing worth comparing
            "CREATE TRIGGER X FOR T BEFORE INSERT AS BEGIN END",
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
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT FIRST 2 COUNT(*) FROM T INTO :R1 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn input_param_refusals() {
        for sql in [
            // `:name` must name an input parameter
            "CREATE PROCEDURE X (I1 INTEGER) RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE A > :MISSING INTO :R1 DO SUSPEND; END",
            // an input inside HAVING crosses the aggregate boundary:
            // unprobed
            "CREATE PROCEDURE X (I1 INTEGER) RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A HAVING COUNT(*) > :I1 INTO :R1, :R2 DO SUSPEND; END",
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
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT A FROM T GROUP BY A INTO :R1 DO SUSPEND; END",
            // a select column missing from GROUP BY
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT S, COUNT(*) FROM T GROUP BY A INTO :R1, :R2 DO SUSPEND; END",
            // a non-grouped column in HAVING
            "CREATE PROCEDURE X RETURNS (R1 INTEGER, R2 INTEGER) AS BEGIN FOR SELECT A, COUNT(*) FROM T GROUP BY A HAVING S > 0 INTO :R1, :R2 DO SUSPEND; END",
        ] {
            assert!(compile_procedure(sql).is_none(), "{sql} was compiled");
        }
    }

    #[test]
    fn procedure_refusals() {
        for sql in [
            // ORDER BY <position> and expressions: unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY 1 INTO :R1 DO SUSPEND; END",
            // INTO must name RETURNS parameters, one per column
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T INTO :NOPE DO SUSPEND; END",
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID, A FROM T INTO :R1 DO SUSPEND; END",
            // subqueries inside procedure bodies: contexts unprobed
            "CREATE PROCEDURE X RETURNS (R1 INTEGER) AS BEGIN FOR SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) INTO :R1 DO SUSPEND; END",
            // an ALIASED stream under AS CURSOR: unprobed alias string
            "CREATE PROCEDURE X AS BEGIN FOR SELECT ID FROM T E AS CURSOR CU DO DELETE FROM T WHERE CURRENT OF CU; END",
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
            // SUBSTRING without FOR: layout not yet probed
            "SELECT ID FROM T WHERE SUBSTRING(S FROM 1) = 'a'",
            "SELECT ID FROM T CROSS JOIN U2",        // no ON clause
            // a FIELD branch in a cast-wrapped conditional: its dsc
            // lives in the catalog - never guess a descriptor
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN A ELSE 0 END = 1",
            "SELECT ID FROM T WHERE NULLIF(A, 0) = 5",
            // single-argument COALESCE is a syntax error IN THE ENGINE
            "SELECT ID FROM T WHERE COALESCE(A) = 5",
            // unprobed cast targets and unprobed unifications
            "SELECT ID FROM T WHERE CAST(A AS FLOAT) = 1",
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(30)) = 1",
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
            "SELECT ID FROM T WHERE N IN (1.5, 2.5)",
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
        // double negation cancels
        assert_eq!(
            compile_view_select("SELECT ID FROM T WHERE NOT (NOT (A > 5))"),
            compile_view_select("SELECT ID FROM T WHERE A > 5"),
        );
    }
}
