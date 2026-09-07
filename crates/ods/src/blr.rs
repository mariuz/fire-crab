//! BLR (Binary Language Representation) decoding, converted from the
//! parser structure in `par.cpp` and the operand-shape table the
//! engine's own pretty-printer uses (`blr_print_table` in
//! `src/jrd/blp.h`, driven by the op-atom loop in
//! `src/yvalve/gds.cpp:3549`). BLR is the compiled form of computed
//! fields, defaults, view/trigger/procedure bodies and query
//! expressions - a tagged byte stream: a version byte, then a tree of
//! verbs each followed by operands whose layout the verb determines,
//! terminated by `blr_eoc`.
//!
//! This converts the *structural* walk: each known verb's operand
//! sequence (from the format table) so the whole tree can be traversed
//! byte-exactly, references extracted, and the stream verified to
//! consume to its end. Unknown verbs are reported, not guessed - the
//! honest incompleteness a partial grammar demands.

/// Op-atoms, converted from gds.cpp:300 - the alphabet the verb format
/// table is written in. Each atom says how many bytes to consume and
/// whether to recurse.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Op {
    Line,        // formatting only, no bytes
    Verb,        // recurse: one sub-verb
    Byte,        // consume 1 byte, set n
    Word,        // consume 2 bytes LE, set n
    Pad,         // formatting only
    Dtype,       // a datatype descriptor; sets n to the literal width
    Literal,     // consume n bytes (n from the previous Byte/Word/Dtype)
    Begin,       // loop sub-verbs until blr_end
    Message,     // n dtype descriptors (n from previous Word)
    Args,        // one byte count, then that many sub-verbs
    ByteOptVerb, // one byte n, then a sub-verb iff n != 0
    Indent,      // formatting only
    Parameters,  // one byte count, then that many sub-verbs
    // the printer's SPECIAL atoms (gds.cpp blr_print_verb), each a
    // hand-written consumer in [walk_verb]
    SetError,        // one condition (blr_print_cond)
    ErrorHandler,    // n conditions
    Join,            // one join-type byte
    Union,           // n x (rse verb, map verb)
    Map,             // n x (word, verb)
    Literals,        // n x (byte len, chars)
    ExecInto,        // verb, byte, (verb if byte == 0), n verbs
    ExecStmt,        // tag-driven, to blr_end
    DerivedExpr,     // byte n, n bytes, verb
    CursorStmt,      // byte op, word, [scroll byte + verb]
    PartitionArgs,   // byte n, 2n verbs, verb
    SubRoutineDecl,  // sub-procedure / sub-function declaration
    WindowWin,       // tag-driven, to blr_end
    Erase,           // byte ctx, optional blr_marks
    DclLocalTable,   // tag-driven, to blr_end
    OuterMap,        // tag-driven, to blr_end
    InvokeFunction,  // tag-driven, to blr_end
    InvselProcedure, // tag-driven, to blr_end
    TableValueFun,   // one sub-code and its operands
    ForRange,        // tag-driven, to blr_end
    CustomAggFunction, // tag-driven, to blr_end
    WithinGroupOrder, // optional blr_within_group_order, byte n, n verbs
}

/// The verb format table, converted from blp.h `blr_print_table`.
/// Indexed by verb byte; `None` = verb we have not converted yet.
fn verb_format(verb: u8) -> Option<(&'static str, &'static [Op])> {
    use Op::*;
    // shared shapes (blp.h names)
    const ZERO: &[Op] = &[Line];
    const ONE: &[Op] = &[Line, Verb];
    const TWO: &[Op] = &[Line, Verb, Verb];
    const THREE: &[Op] = &[Line, Verb, Verb, Verb];
    const FIELD: &[Op] = &[Byte, Byte, Literal, Pad, Line];
    const PARM: &[Op] = &[Byte, Word, Line];
    const PARM2: &[Op] = &[Byte, Word, Word, Line];
    const PARM3: &[Op] = &[Byte, Word, Word, Word, Line];
    const ONE_WORD: &[Op] = &[Word, Line];
    const LITERAL: &[Op] = &[Dtype, Literal, Line];
    const BEGIN: &[Op] = &[Line, Begin, Verb];
    const MESSAGE: &[Op] = &[Byte, Word, Line, Message];
    const BYTE_VERB: &[Op] = &[Byte, Line, Verb];
    const BYTE_LINE: &[Op] = &[Byte, Line];
    const BYTE_ARGS: &[Op] = &[Byte, Line, Args];
    const BYTE_BYTE_VERB: &[Op] = &[Byte, Byte, Line, Verb];
    const RELATION: &[Op] = &[Byte, Literal, Pad, Byte, Line];
    const RID: &[Op] = &[Word, Byte, Line];
    const RSE: &[Op] = &[Byte, Line, Begin, Verb];
    const CAST: &[Op] = &[Dtype, Line, Verb];
    const EXTRACT: &[Op] = &[Line, Byte, Verb];

    Some(match verb {
        1 => ("assignment", &[Line, Verb, Verb]),
        2 => ("begin", &[Line, Begin, Verb]),
        3 => ("declare", &[Word, Dtype, Line]),
        4 => ("message", &[Byte, Word, Line, Message]),
        5 => ("erase", &[Erase]),
        6 => ("fetch", &[Line, Verb, Verb]),
        7 => ("for", &[Line, Verb, Verb]),
        8 => ("if", &[Line, Verb, Verb, Verb]),
        9 => ("loop", &[Line, Verb]),
        10 => ("modify", &[Byte, Byte, Line, Verb]),
        11 => ("handler", &[Line, Verb]),
        12 => ("receive", &[Byte, Line, Verb]),
        13 => ("select", &[Line, Begin, Verb]),
        14 => ("send", &[Byte, Line, Verb]),
        15 => ("store", &[Line, Verb, Verb]),
        17 => ("label", &[Byte, Line, Verb]),
        18 => ("leave", &[Byte, Line]),
        19 => ("store2", &[Line, Verb, Verb, Verb]),
        20 => ("post", &[Line, Verb]),
        21 => ("literal", &[Dtype, Literal, Line]),
        22 => ("dbkey", &[Byte, Line]),
        23 => ("field", &[Byte, Byte, Literal, Pad, Line]),
        24 => ("fid", &[Byte, Word, Line]),
        25 => ("parameter", &[Byte, Word, Line]),
        26 => ("variable", &[Word, Line]),
        27 => ("average", &[Line, Verb, Verb]),
        28 => ("count", &[Line, Verb]),
        29 => ("maximum", &[Line, Verb, Verb]),
        30 => ("minimum", &[Line, Verb, Verb]),
        31 => ("total", &[Line, Verb, Verb]),
        32 => ("receive_batch", &[Byte, Line, Verb]),
        33 => ("bulk_insert", &[Line, Verb, Verb, Verb]),
        34 => ("add", &[Line, Verb, Verb]),
        35 => ("subtract", &[Line, Verb, Verb]),
        36 => ("multiply", &[Line, Verb, Verb]),
        37 => ("divide", &[Line, Verb, Verb]),
        38 => ("negate", &[Line, Verb]),
        39 => ("concatenate", &[Line, Verb, Verb]),
        40 => ("substring", &[Line, Verb, Verb, Verb]),
        41 => ("parameter2", &[Byte, Word, Word, Line]),
        42 => ("from", &[Line, Verb, Verb]),
        43 => ("via", &[Line, Verb, Verb, Verb]),
        44 => ("user_name", &[Line]),
        45 => ("null", &[Line]),
        46 => ("equiv", &[Line, Verb, Verb]),
        47 => ("eql", &[Line, Verb, Verb]),
        48 => ("neq", &[Line, Verb, Verb]),
        49 => ("gtr", &[Line, Verb, Verb]),
        50 => ("geq", &[Line, Verb, Verb]),
        51 => ("lss", &[Line, Verb, Verb]),
        52 => ("leq", &[Line, Verb, Verb]),
        53 => ("containing", &[Line, Verb, Verb]),
        54 => ("matching", &[Line, Verb, Verb]),
        55 => ("starting", &[Line, Verb, Verb]),
        56 => ("between", &[Line, Verb, Verb, Verb]),
        57 => ("or", &[Line, Verb, Verb]),
        58 => ("and", &[Line, Verb, Verb]),
        59 => ("not", &[Line, Verb]),
        60 => ("any", &[Line, Verb]),
        61 => ("missing", &[Line, Verb]),
        62 => ("unique", &[Line, Verb]),
        63 => ("like", &[Line, Verb, Verb]),
        64 => ("in_list", &[Line, Verb, Indent, Word, Line, Args]),
        67 => ("rse", &[Byte, Line, Begin, Verb]),
        68 => ("first", &[Line, Verb]),
        69 => ("project", &[Byte, Line, Args]),
        70 => ("sort", &[Byte, Line, Args]),
        71 => ("boolean", &[Line, Verb]),
        72 => ("ascending", &[Line, Verb]),
        73 => ("descending", &[Line, Verb]),
        74 => ("relation", &[Byte, Literal, Pad, Byte, Line]),
        75 => ("rid", &[Word, Byte, Line]),
        76 => ("union", &[Byte, Byte, Line, Union]),
        77 => ("map", &[Word, Line, Map]),
        78 => ("group_by", &[Byte, Line, Args]),
        79 => ("aggregate", &[Byte, Line, Verb, Verb, Verb]),
        80 => ("join_type", &[Join, Line]),
        83 => ("agg_count", &[Line]),
        84 => ("agg_max", &[Line, Verb]),
        85 => ("agg_min", &[Line, Verb]),
        86 => ("agg_total", &[Line, Verb]),
        87 => ("agg_average", &[Line, Verb]),
        88 => ("parameter3", &[Byte, Word, Word, Word, Line]),
        93 => ("agg_count2", &[Line, Verb]),
        94 => ("agg_count_distinct", &[Line, Verb]),
        95 => ("agg_total_distinct", &[Line, Verb]),
        96 => ("agg_average_distinct", &[Line, Verb]),
        100 => ("function", &[Byte, Literal, Byte, Line, Args]),
        101 => ("gen_id", &[Byte, Literal, Line, Verb]),
        103 => ("upcase", &[Line, Verb]),
        105 => ("value_if", &[Line, Verb, Verb, Verb]),
        106 => ("matching2", &[Line, Verb, Verb, Verb]),
        107 => ("index", &[Line, Verb, Indent, Byte, Line, Args]),
        108 => ("ansi_like", &[Line, Verb, Verb, Verb]),
        112 => ("seek", &[Line, Verb, Verb]),
        119 => ("rs_stream", &[Byte, Line, Begin, Verb]),
        120 => (
            "exec_proc",
            &[
                Byte, Literal, Line, Indent, Word, Line, Parameters, Indent, Word, Line, Parameters,
            ],
        ),
        124 => (
            "procedure",
            &[
                Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        125 => (
            "pid",
            &[Word, Pad, Byte, Line, Indent, Word, Line, Parameters],
        ),
        127 => ("singular", &[Line, Verb]),
        128 => ("abort", &[SetError, Line]),
        129 => ("block", &[Line, Begin, Verb]),
        130 => ("error_handler", &[Word, Line, ErrorHandler]),
        131 => ("cast", &[Dtype, Line, Verb]),
        132 => (
            "pid2",
            &[
                Word, Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        133 => (
            "procedure2",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        134 => ("start_savepoint", &[Line]),
        135 => ("end_savepoint", &[Line]),
        139 => ("plan", &[Line, Verb]),
        140 => ("merge", &[Byte, Line, Args]),
        141 => ("join", &[Byte, Line, Args]),
        142 => ("sequential", &[Line]),
        143 => ("navigational", &[Byte, Literal, Line]),
        144 => ("indices", &[Byte, Line, Literals]),
        145 => ("retrieve", &[Line, Verb, Verb]),
        146 => (
            "relation2",
            &[Byte, Literal, Line, Indent, Byte, Literal, Pad, Byte, Line],
        ),
        147 => ("rid2", &[Word, Byte, Literal, Pad, Byte, Line]),
        148 => (
            "relation3",
            &[
                Line, Indent, Byte, Literal, Line, Indent, Byte, Literal, Line, Indent, Byte,
                Literal, Line, Indent, Byte, Literal, Line, Indent, Byte, Line,
            ],
        ),
        150 => ("set_generator", &[Byte, Literal, Line, Verb]),
        151 => ("ansi_any", &[Line, Verb]),
        152 => ("exists", &[Line, Verb]),
        154 => ("record_version", &[Byte, Line]),
        155 => ("stall", &[Line]),
        158 => ("ansi_all", &[Line, Verb]),
        159 => ("extract", &[Line, Byte, Verb]),
        160 => ("current_date", &[Line]),
        161 => ("current_timestamp", &[Line]),
        162 => ("current_time", &[Line]),
        163 => ("post_arg", &[Line, Verb, Verb]),
        164 => ("exec_into", &[Word, Line, Indent, ExecInto]),
        165 => ("user_savepoint", &[Byte, Byte, Literal, Line]),
        166 => ("dcl_cursor", &[Word, Line, Verb, Indent, Word, Line, Args]),
        167 => ("cursor_stmt", &[CursorStmt]),
        168 => ("current_timestamp2", &[Byte, Line]),
        169 => ("current_time2", &[Byte, Line]),
        170 => ("agg_list", &[Line, Verb, Verb, WithinGroupOrder]),
        171 => ("agg_list_distinct", &[Line, Verb, Verb, WithinGroupOrder]),
        172 => ("modify2", &[Byte, Byte, Line, Verb, Verb]),
        173 => ("erase2", &[Erase, Verb]),
        174 => ("current_role", &[Line]),
        175 => ("skip", &[Line, Verb]),
        176 => ("exec_sql", &[Line, Verb]),
        177 => ("internal_info", &[Line, Verb]),
        178 => ("nullsfirst", &[Line, Verb]),
        179 => ("writelock", &[Line]),
        180 => ("nullslast", &[Line, Verb]),
        181 => ("lowcase", &[Line, Verb]),
        182 => ("strlen", &[Byte, Line, Verb]),
        183 => ("trim", &[Byte, ByteOptVerb, Verb]),
        184 => ("init_variable", &[Word, Line]),
        185 => ("recurse", &[Byte, Byte, Line, Union]),
        186 => ("sys_function", &[Byte, Literal, Byte, Line, Args]),
        187 => ("auto_trans", &[Byte, Line, Verb]),
        188 => ("similar", &[Line, Verb, Verb, Indent, ByteOptVerb]),
        189 => ("exec_stmt", &[ExecStmt]),
        190 => ("stmt_expr", &[Line, Verb, Verb]),
        191 => ("derived_expr", &[DerivedExpr]),
        192 => (
            "procedure3",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        193 => (
            "exec_proc2",
            &[
                Byte, Literal, Pad, Byte, Literal, Line, Indent, Word, Line, Parameters, Indent,
                Word, Line, Parameters,
            ],
        ),
        194 => (
            "function2",
            &[Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Args],
        ),
        195 => ("window", &[Line, Verb, Indent, Byte, Line, Args]),
        196 => ("partition_by", &[Byte, Line, PartitionArgs, Verb]),
        197 => ("continue_loop", &[Byte, Line]),
        198 => (
            "procedure4",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent,
                Word, Line, Parameters,
            ],
        ),
        199 => ("agg_function", &[Byte, Literal, Byte, Line, Args, WithinGroupOrder]),
        200 => ("substring_similar", &[Line, Verb, Verb, Verb]),
        201 => ("bool_as_value", &[Line, Verb]),
        202 => ("coalesce", &[Byte, Line, Args]),
        203 => (
            "decode",
            &[
                Line, Verb, Indent, Byte, Line, Args, Indent, Byte, Line, Args,
            ],
        ),
        204 => (
            "exec_subproc",
            &[
                Byte, Literal, Line, Indent, Word, Line, Parameters, Indent, Word, Line, Parameters,
            ],
        ),
        205 => ("subproc_decl", &[SubRoutineDecl]),
        206 => (
            "subproc",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        207 => ("subfunc_decl", &[SubRoutineDecl]),
        208 => ("subfunc", &[Byte, Literal, Byte, Line, Args]),
        209 => ("record_version2", &[Byte, Line]),
        210 => ("gen_id2", &[Byte, Literal, Line]),
        211 => ("window_win", &[Byte, WindowWin]),
        212 => (
            "default",
            &[
                Line, Indent, Byte, Literal, Line, Indent, Byte, Literal, Pad, Line,
            ],
        ),
        213 => ("store3", &[Line, Byte, Line, Verb, Verb, Verb]),
        214 => ("local_timestamp", &[Byte, Line]),
        215 => ("local_time", &[Byte, Line]),
        216 => ("at", &[Verb, Byte, Line, Verb]),
        217 => ("marks", &[Byte, Literal, Line, Verb]),
        218 => ("dcl_local_table", &[DclLocalTable]),
        219 => ("local_table_truncate", &[Word, Line]),
        220 => ("local_table_id", &[Word, Byte, Literal, Byte, Line]),
        221 => ("outer_map", &[OuterMap]),
        223 => ("skip_locked", &[Line]),
        224 => ("invoke_function", &[InvokeFunction]),
        225 => ("invoke_procedure", &[InvselProcedure]),
        226 => ("select_procedure", &[InvselProcedure]),
        227 => ("default_arg", &[Line]),
        228 => (
            "cast_format",
            &[Line, Indent, Byte, Literal, Line, Indent, Dtype, Line, Verb],
        ),
        229 => ("table_value_fun", &[TableValueFun]),
        230 => ("for_range", &[ForRange]),
        231 => (
            "gen_id3",
            &[
                Line,
                Indent,
                Byte,
                Literal,
                Line,
                Indent,
                Byte,
                Literal,
                Line,
                Indent,
                ByteOptVerb,
            ],
        ),
        232 => (
            "default2",
            &[
                Line, Indent, Byte, Literal, Line, Indent, Byte, Literal, Line, Indent, Byte,
                Literal, Pad, Line,
            ],
        ),
        233 => ("current_schema", &[Line]),
        236 => ("invoke_agg_function", &[CustomAggFunction]),
        255 => ("end", &[Line]),
        _ => return None,
    })
}

#[derive(Debug)]
pub enum BlrError {
    Empty,
    BadVersion(u8),
    UnknownVerb { verb: u8, offset: usize },
    Truncated { offset: usize },
    Trailing { consumed: usize, total: usize },
}

impl std::fmt::Display for BlrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BlrError::Empty => write!(f, "empty BLR"),
            BlrError::BadVersion(v) => write!(f, "bad BLR version byte {}", v),
            BlrError::UnknownVerb { verb, offset } => {
                write!(
                    f,
                    "unknown verb {} (0x{:02x}) at offset {}",
                    verb, verb, offset
                )
            }
            BlrError::Truncated { offset } => write!(f, "truncated at offset {}", offset),
            BlrError::Trailing { consumed, total } => {
                write!(f, "trailing bytes: consumed {} of {}", consumed, total)
            }
        }
    }
}

/// The result of a decode: the rendered verb lines (isql `SET BLOB
/// ALL` style, one verb per line, indented) and the extracted field
/// and relation references.
#[derive(Default, Debug)]
pub struct BlrDecode {
    pub lines: Vec<String>,
    /// (context, field name) from every `blr_field`
    pub fields: Vec<(u8, String)>,
    /// relation names from every `blr_relation`
    pub relations: Vec<String>,
    pub version: u8,
    /// EVERY REFERENCE THE ENGINE RECORDS AS A DEPENDENCY, in the order
    /// the parse meets them - the events `PAR_dependency` and the other
    /// `csb->addDependency` sites fire while compiling this BLR
    /// (par.cpp:966, ExprNodes.cpp:6125, RecordSourceNodes.cpp:855/1433,
    /// StmtNodes.cpp:3277/3791/5704, ExprNodes.cpp:7183/13359, par.cpp
    /// PAR_desc 520/594/610). Contexts are resolved by the caller, which
    /// knows what a trigger's 0/1 stand for.
    pub deps: Vec<DepEvent>,
}

/// One dependency-recording event met in a BLR walk.
#[derive(Debug, Clone, PartialEq)]
pub enum DepEvent {
    /// a relation opened as a stream (`blr_relation*`): the context it
    /// is bound to, and its name - the relation-level (NULL field) row
    RelCtx { ctx: u8, name: String },
    /// blr_modify / blr_modify2: the NEW record's context is the same
    /// relation as the stream it modifies (an assignment target under
    /// it is a field dependency: the engine records LOG.Y for
    /// `UPDATE LOG SET Y = :v`)
    ModifyCtx { org: u8, new: u8 },
    /// `blr_rid*`: the same, by relation id
    RelId { ctx: u8, id: u16 },
    /// a procedure opened as a stream (`blr_procedure*`, `blr_select_procedure`)
    ProcCtx { ctx: u8, name: String },
    /// `blr_field`: a field of a context, by name
    Field { ctx: u8, name: String },
    /// `blr_fid`: a field of a context, by id
    Fid { ctx: u8, id: u16 },
    /// `blr_exec_proc*` / `blr_invoke_procedure`: a procedure called
    ExecProc { name: String },
    /// a named argument of a called / selected procedure
    ProcArg { proc: String, arg: String },
    /// `blr_gen_id*` / `blr_set_generator`
    GenId { name: String },
    /// an exception named in `blr_abort` or an error handler
    Exception { name: String },
    /// a user function (`blr_function*`, `blr_invoke_function`) - never a
    /// system function or a sub-routine
    Function { name: String },
    /// a domain named in a descriptor (`blr_domain_name*`)
    Domain { name: String },
    /// a relation column named in a descriptor (`blr_column_name*`)
    RelField { relation: String, field: String },
    /// an explicit collation in a descriptor: the text type (charset |
    /// collation << 8)
    Collation { ttype: u16 },
}

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn byte(&mut self) -> Option<u8> {
        let v = *self.b.get(self.pos)?;
        self.pos += 1;
        Some(v)
    }
    fn word(&mut self) -> Option<u16> {
        let lo = self.byte()? as u16;
        let hi = self.byte()? as u16;
        Some(lo | (hi << 8))
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.b.get(self.pos..self.pos + n)?;
        self.pos += n;
        Some(s)
    }
}

/// The literal width of a descriptor whose data is a word-length numeric
/// string rather than a fixed number of bytes.
const LEN_PREFIXED: usize = usize::MAX;

/// A counted name: one length byte, then the bytes.
fn read_name(r: &mut Reader) -> Option<String> {
    let n = r.byte()? as usize;
    Some(String::from_utf8_lossy(r.take(n)?).into_owned())
}

/// Consume a datatype descriptor (gds.cpp blr_print_dtype), returning
/// the literal-data width that follows a `blr_literal` of this type.
/// The NAME forms (par.cpp PAR_desc) record what they depend on: a
/// domain, a relation column, an explicit collation.
fn consume_dtype(r: &mut Reader, out: &mut BlrDecode) -> Option<(usize, &'static str)> {
    let dtype = r.byte()?;
    let name = dtype_name(dtype);
    // a text type with a charset that is neither NONE (0) nor dynamic
    // (127) is a collation dependency (par.cpp:606-611)
    let collation = |ttype: u16, out: &mut BlrDecode| {
        let cs = ttype & 0xff;
        if cs != 0 && cs != 127 {
            out.deps.push(DepEvent::Collation { ttype });
        }
    };
    // codes from blr.h; scale/charset/length trailers per gds.cpp
    let width = match dtype {
        // blr_not_nullable: a wrapper around the real descriptor
        20 => return consume_dtype(r, out),
        // blr_domain_name (18) / _name2 (19) / _name3 (32): full-or-type
        // byte, [schema], name, then a collation word (name2 always,
        // name3 behind a flag byte)
        18 | 19 | 32 => {
            r.byte()?;
            if dtype == 32 {
                read_name(r)?;
            }
            let dn = read_name(r)?;
            out.deps.push(DepEvent::Domain { name: dn });
            if dtype == 19 || (dtype == 32 && r.byte()? != 0) {
                let tt = r.word()?;
                collation(tt, out);
            }
            0
        }
        // blr_column_name (21) / _name2 (22) / _name3 (33): full-or-type
        // byte, [schema], relation, field, then the same collation tail
        21 | 22 | 33 => {
            r.byte()?;
            if dtype == 33 {
                read_name(r)?;
            }
            let rel = read_name(r)?;
            let fld = read_name(r)?;
            out.deps.push(DepEvent::RelField { relation: rel, field: fld });
            if dtype == 22 || (dtype == 33 && r.byte()? != 0) {
                let tt = r.word()?;
                collation(tt, out);
            }
            0
        }
        7 => {
            r.byte()?;
            2
        } // blr_short  (+scale)
        8 => {
            r.byte()?;
            4
        } // blr_long   (+scale)
        16 => {
            r.byte()?;
            8
        } // blr_int64  (+scale)
        9 => 8,                       // blr_quad
        10 => 4,                      // blr_float
        // A DOUBLE / DEC128 / INT128 LITERAL IS NUMERIC TEXT: a word
        // length then the digits (LiteralNode::parse, ExprNodes.cpp:7729-
        // 7768, "the value is passed as if it were a text string") - not
        // the binary width the descriptor names. The width is decided
        // when the literal's data is read ([LEN_PREFIXED]).
        11 | 27 | 25 => LEN_PREFIXED, // blr_d_float / blr_double / blr_dec128
        26 => {
            r.byte()?; // scale
            LEN_PREFIXED
        } // blr_int128
        12 => 4,                      // blr_sql_date
        13 => 4,                      // blr_sql_time
        28 => 6,                      // blr_sql_time_tz
        35 => 8,                      // blr_timestamp
        29 => 10,                     // blr_timestamp_tz
        23 => 1,                      // blr_bool
        24 => 8,                      // blr_dec64
        14 => r.word()? as usize,     // blr_text   (+len)
        37 => r.word()? as usize + 2, // blr_varying (+len, +2)
        40 => r.word()? as usize,     // blr_cstring (+len)
        15 => {
            let tt = r.word()?;
            collation(tt, out);
            r.word()? as usize
        } // blr_text2   (+charset,+len)
        38 => {
            let tt = r.word()?;
            collation(tt, out);
            r.word()? as usize + 2
        } // blr_varying2 (+charset,+len,+2)
        41 => {
            let tt = r.word()?;
            collation(tt, out);
            r.word()? as usize
        } // blr_cstring2 (+charset,+len)
        // blr_blob2: sub_type word, charset word
        17 => {
            r.word()?;
            let tt = r.word()?;
            collation(tt, out);
            0
        }
        _ => 0,                       // unknown dtype: no trailing width
    };
    Some((width, name))
}

/// dtype byte -> the blr_ token name isql prints (gds.cpp).
fn dtype_name(dtype: u8) -> &'static str {
    match dtype {
        7 => "blr_short",
        8 => "blr_long",
        9 => "blr_quad",
        10 => "blr_float",
        11 => "blr_d_float",
        12 => "blr_sql_date",
        13 => "blr_sql_time",
        14 => "blr_text",
        15 => "blr_text2",
        16 => "blr_int64",
        23 => "blr_bool",
        24 => "blr_dec64",
        25 => "blr_dec128",
        26 => "blr_int128",
        27 => "blr_double",
        28 => "blr_sql_time_tz",
        29 => "blr_timestamp_tz",
        35 => "blr_timestamp",
        37 => "blr_varying",
        38 => "blr_varying2",
        40 => "blr_cstring",
        41 => "blr_cstring2",
        _ => "blr_dtype?",
    }
}

/// Decode a BLR blob. Verifies the version, walks the verb tree
/// byte-exactly, and requires the stream to end cleanly at
/// blr_eoc/blr_end with everything consumed.
pub fn decode(blr: &[u8]) -> Result<BlrDecode, BlrError> {
    if blr.is_empty() {
        return Err(BlrError::Empty);
    }
    let mut r = Reader { b: blr, pos: 0 };
    let version = r.byte().ok_or(BlrError::Empty)?;
    if version != 4 && version != 5 {
        return Err(BlrError::BadVersion(version));
    }
    let mut out = BlrDecode {
        version,
        ..Default::default()
    };
    out.lines.push(format!("blr_version{}", version));
    // blr_flags (234): a header FB6 may put right after the version -
    // a list of `tag, word length, bytes` ending in blr_end
    // (BlrReader::parseHeader, BlrReader.h:131-172; tag 1 =
    // blr_flags_search_system_schema)
    if r.b.get(r.pos) == Some(&234) {
        r.byte();
        loop {
            let tag = r.byte().ok_or(BlrError::Truncated { offset: r.pos })?;
            if tag == 255 {
                break;
            }
            let len = r.word().ok_or(BlrError::Truncated { offset: r.pos })? as usize;
            r.take(len).ok_or(BlrError::Truncated { offset: r.pos })?;
        }
    }

    walk_verb(&mut r, &mut out, 1)?;

    // after the top expression/statement, a trailing blr_eoc (76)
    if r.pos < blr.len() {
        if blr[r.pos] == 76 {
            r.pos += 1;
            out.lines.push("blr_eoc".into());
        }
    }
    if r.pos != blr.len() {
        return Err(BlrError::Trailing {
            consumed: r.pos,
            total: blr.len(),
        });
    }
    Ok(out)
}

fn trunc(r: &Reader) -> BlrError {
    BlrError::Truncated { offset: r.pos }
}

/// One condition of `blr_abort` / an error handler (gds.cpp
/// blr_print_cond, StmtNodes.cpp ExceptionNode / ErrorHandlerNode
/// parse): the exception forms record a dependency.
fn walk_cond(r: &mut Reader, out: &mut BlrDecode, level: usize) -> Result<(), BlrError> {
    let ctype = r.byte().ok_or_else(|| trunc(r))?;
    match ctype {
        0 => {
            // blr_gds_code: a counted symbol
            read_name(r).ok_or_else(|| trunc(r))?;
        }
        1 => {
            // blr_sql_code: a word
            r.word().ok_or_else(|| trunc(r))?;
        }
        8 => {
            // blr_sql_state: a counted string
            read_name(r).ok_or_else(|| trunc(r))?;
        }
        4 | 5 => {} // blr_default_code / blr_raise: nothing follows
        2 | 6 | 7 | 9 | 10 => {
            // blr_exception (2), _msg (6), _params (7), _2 (9), _3 (10):
            // [schema for 9/10], name; then _msg: one verb; _3: a flag
            // byte then a verb if nonzero, then a word count of verbs;
            // _params: a word count of verbs
            if ctype == 9 || ctype == 10 {
                read_name(r).ok_or_else(|| trunc(r))?;
            }
            let name = read_name(r).ok_or_else(|| trunc(r))?;
            out.deps.push(DepEvent::Exception { name });
            if ctype == 6 || (ctype == 10 && r.byte().ok_or_else(|| trunc(r))? != 0) {
                walk_verb(r, out, level + 1)?;
            }
            if ctype == 7 || ctype == 10 {
                let n = r.word().ok_or_else(|| trunc(r))?;
                for _ in 0..n {
                    walk_verb(r, out, level + 1)?;
                }
            }
        }
        other => {
            return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 });
        }
    }
    Ok(())
}

/// A tag-driven list ending in blr_end, each tag consumed by `f`.
fn walk_tags(
    r: &mut Reader,
    out: &mut BlrDecode,
    level: usize,
    mut f: impl FnMut(u8, &mut Reader, &mut BlrDecode, usize) -> Result<(), BlrError>,
) -> Result<(), BlrError> {
    loop {
        let tag = r.byte().ok_or_else(|| trunc(r))?;
        if tag == 255 {
            return Ok(());
        }
        f(tag, r, out, level)?;
    }
}

/// The `id` sub-list of blr_invoke_function / blr_invsel_procedure /
/// blr_invoke_agg_function: schema (1) / package (2) / name (3) as
/// counted names, sub (4) bare, to blr_end. Returns (name, is
/// sub-routine, has package).
fn walk_routine_id(r: &mut Reader) -> Result<(String, bool, bool), BlrError> {
    let mut name = String::new();
    let mut sub = false;
    let mut pkg = false;
    loop {
        let t = r.byte().ok_or_else(|| trunc(r))?;
        match t {
            255 => return Ok((name, sub, pkg)),
            1 => {
                read_name(r).ok_or_else(|| trunc(r))?;
            }
            2 => {
                read_name(r).ok_or_else(|| trunc(r))?;
                pkg = true;
            }
            3 => name = read_name(r).ok_or_else(|| trunc(r))?,
            4 => sub = true,
            other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
        }
    }
}

fn walk_verb(r: &mut Reader, out: &mut BlrDecode, level: usize) -> Result<(), BlrError> {
    let offset = r.pos;
    let verb = r.byte().ok_or(BlrError::Truncated { offset })?;
    let (name, ops) = verb_format(verb).ok_or(BlrError::UnknownVerb { verb, offset })?;
    out.lines
        .push(format!("{}blr_{}", "   ".repeat(level), name));

    // the operands read so far of THIS verb, for the dependency events
    // emitted once its own operands are in
    let mut strings: Vec<String> = Vec::new();
    let mut bytes: Vec<u8> = Vec::new();
    let mut words: Vec<u16> = Vec::new();
    let mut n: usize = 0;
    let mut fired = false;
    macro_rules! emit {
        () => {
            if !fired {
                if let Some(ev) = stream_event(verb, &strings, &bytes, &words) {
                    out.deps.push(ev);
                    fired = true;
                }
            }
        };
    }

    for op in ops.iter() {
        match op {
            Op::Line | Op::Pad | Op::Indent => {}
            Op::Byte => {
                let v = r.byte().ok_or_else(|| trunc(r))?;
                n = v as usize;
                bytes.push(v);
            }
            Op::Word => {
                let w = r.word().ok_or_else(|| trunc(r))?;
                n = w as usize;
                words.push(w);
            }
            Op::Dtype => {
                let (w, dname) = consume_dtype(r, out).ok_or_else(|| trunc(r))?;
                n = w;
                out.lines
                    .push(format!("{}{}", "   ".repeat(level + 1), dname));
            }
            Op::Literal => {
                if n == LEN_PREFIXED {
                    n = r.word().ok_or_else(|| trunc(r))? as usize;
                }
                let data = r.take(n).ok_or_else(|| trunc(r))?;
                if verb != 21 {
                    // every literal but blr_literal's data is a NAME
                    let text = String::from_utf8_lossy(data).into_owned();
                    *out.lines.last_mut().unwrap() += &format!(" '{}'", text);
                    if verb == 23 {
                        out.fields.push((bytes.first().copied().unwrap_or(0), text.clone()));
                    } else if verb == 74 {
                        out.relations.push(text.clone());
                    }
                    strings.push(text);
                }
            }
            Op::Verb => {
                // a stream verb's context is bound BEFORE its arguments
                // are walked (a procedure's inputs follow its context)
                emit!();
                walk_verb(r, out, level + 1)?
            }
            Op::Begin => {
                while r.b.get(r.pos) != Some(&255) {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::Message => {
                for _ in 0..n {
                    let (_, dname) = consume_dtype(r, out).ok_or_else(|| trunc(r))?;
                    out.lines
                        .push(format!("{}{}", "   ".repeat(level + 1), dname));
                }
            }
            Op::Args | Op::Parameters => {
                emit!();
                for _ in 0..n {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::ByteOptVerb => {
                let v = r.byte().ok_or_else(|| trunc(r))?;
                bytes.push(v);
                emit!();
                if v != 0 {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::SetError => walk_cond(r, out, level)?,
            Op::ErrorHandler => {
                for _ in 0..n {
                    walk_cond(r, out, level)?;
                }
            }
            Op::Join => {
                r.byte().ok_or_else(|| trunc(r))?;
            }
            Op::Union => {
                // n from the SECOND byte (the member count; the first is the context)
                for _ in 0..n {
                    walk_verb(r, out, level + 1)?;
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::Map => {
                for _ in 0..n {
                    r.word().ok_or_else(|| trunc(r))?;
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::Literals => {
                for _ in 0..n {
                    read_name(r).ok_or_else(|| trunc(r))?;
                }
            }
            Op::ExecInto => {
                walk_verb(r, out, level + 1)?;
                if r.byte().ok_or_else(|| trunc(r))? == 0 {
                    walk_verb(r, out, level + 1)?;
                }
                for _ in 0..n {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::ExecStmt => {
                let mut inputs = 0usize;
                let mut outputs = 0usize;
                walk_tags(r, out, level, |tag, r, out, level| {
                    match tag {
                        1 => inputs = r.word().ok_or_else(|| trunc(r))? as usize,
                        2 => outputs = r.word().ok_or_else(|| trunc(r))? as usize,
                        3 | 4 | 5 | 6 | 7 | 14 => walk_verb(r, out, level + 1)?,
                        9 => {
                            r.byte().ok_or_else(|| trunc(r))?;
                        }
                        8 | 10 => {}
                        11 | 12 => {
                            for _ in 0..inputs {
                                if tag == 12 {
                                    read_name(r).ok_or_else(|| trunc(r))?;
                                }
                                walk_verb(r, out, level + 1)?;
                            }
                        }
                        13 => {
                            for _ in 0..outputs {
                                walk_verb(r, out, level + 1)?;
                            }
                        }
                        15 => {
                            // blr_exec_stmt_in_excess: excess input params numbers
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                r.word().ok_or_else(|| trunc(r))?;
                            }
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::DerivedExpr => {
                let k = r.byte().ok_or_else(|| trunc(r))? as usize;
                r.take(k).ok_or_else(|| trunc(r))?;
                walk_verb(r, out, level + 1)?;
            }
            Op::CursorStmt => {
                let op = r.byte().ok_or_else(|| trunc(r))?;
                r.word().ok_or_else(|| trunc(r))?;
                if op == 3 {
                    r.byte().ok_or_else(|| trunc(r))?; // scroll code
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::PartitionArgs => {
                let k = r.byte().ok_or_else(|| trunc(r))? as usize;
                for _ in 0..2 * k {
                    walk_verb(r, out, level + 1)?;
                }
                walk_verb(r, out, level + 1)?;
            }
            Op::SubRoutineDecl => {
                // name, type byte, kind byte, two (word count of (name,
                // default flag [+verb])) lists, four bytes, then a
                // whole nested BLR program (version .. eoc). Nothing in
                // a sub-routine is a dependency of the outer object
                // (isSubRoutine() is excluded everywhere), so its body
                // is walked into a THROWAWAY decode.
                read_name(r).ok_or_else(|| trunc(r))?;
                r.byte().ok_or_else(|| trunc(r))?;
                r.byte().ok_or_else(|| trunc(r))?;
                for _ in 0..2 {
                    let args = r.word().ok_or_else(|| trunc(r))?;
                    for _ in 0..args {
                        read_name(r).ok_or_else(|| trunc(r))?;
                        if r.byte().ok_or_else(|| trunc(r))? == 1 {
                            walk_verb(r, out, level + 1)?;
                        }
                    }
                }
                r.take(4).ok_or_else(|| trunc(r))?;
                let v = r.byte().ok_or_else(|| trunc(r))?;
                if !matches!(v, 4 | 5) {
                    return Err(BlrError::BadVersion(v));
                }
                let mut inner = BlrDecode::default();
                walk_verb(r, &mut inner, level + 1)?;
                if r.byte().ok_or_else(|| trunc(r))? != 76 {
                    return Err(BlrError::UnknownVerb { verb: r.b[r.pos - 1], offset: r.pos - 1 });
                }
            }
            Op::WindowWin => {
                walk_tags(r, out, level, |tag, r, out, level| {
                    match tag {
                        1 | 2 => {
                            let k = r.byte().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                walk_verb(r, out, level + 1)?;
                                if tag == 1 {
                                    walk_verb(r, out, level + 1)?;
                                }
                            }
                        }
                        3 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                r.word().ok_or_else(|| trunc(r))?;
                                walk_verb(r, out, level + 1)?;
                            }
                        }
                        4 | 7 => {
                            r.byte().ok_or_else(|| trunc(r))?;
                        }
                        5 => {
                            r.take(2).ok_or_else(|| trunc(r))?;
                        }
                        6 => {
                            r.byte().ok_or_else(|| trunc(r))?;
                            walk_verb(r, out, level + 1)?;
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::Erase => {
                r.byte().ok_or_else(|| trunc(r))?; // context
                if r.b.get(r.pos) == Some(&217) {
                    r.byte();
                    read_name(r).ok_or_else(|| trunc(r))?; // blr_marks: length + bytes
                }
            }
            Op::DclLocalTable => {
                r.word().ok_or_else(|| trunc(r))?;
                walk_tags(r, out, level, |tag, r, out, _| {
                    match tag {
                        1 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                consume_dtype(r, out).ok_or_else(|| trunc(r))?;
                            }
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::OuterMap => {
                walk_tags(r, out, level, |tag, r, _, _| {
                    match tag {
                        1 | 2 => {
                            r.word().ok_or_else(|| trunc(r))?;
                            r.word().ok_or_else(|| trunc(r))?;
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::InvokeFunction | Op::CustomAggFunction => {
                let custom = matches!(op, Op::CustomAggFunction);
                walk_tags(r, out, level, |tag, r, out, level| {
                    match tag {
                        1 => {
                            let (fname, sub, pkg) = walk_routine_id(r)?;
                            if !sub && !pkg && !fname.is_empty() {
                                out.deps.push(DepEvent::Function { name: fname });
                            }
                        }
                        2 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                read_name(r).ok_or_else(|| trunc(r))?;
                            }
                        }
                        3 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                walk_verb(r, out, level + 1)?;
                            }
                        }
                        4 if custom => walk_verb(r, out, level + 1)?,
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::InvselProcedure => {
                // blr_invoke_procedure (225) calls, blr_select_procedure
                // (226) opens a stream on a context (tag 8)
                let mut pname = String::new();
                let mut sub = false;
                let mut pkg = false;
                let mut ctx: Option<u16> = None;
                let mut arg_names: Vec<String> = Vec::new();
                walk_tags(r, out, level, |tag, r, out, level| {
                    match tag {
                        1 => {
                            let (nm, s, p) = walk_routine_id(r)?;
                            pname = nm;
                            sub = s;
                            pkg = p;
                        }
                        2 | 4 | 6 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                arg_names.push(read_name(r).ok_or_else(|| trunc(r))?);
                            }
                        }
                        3 | 5 | 7 => {
                            let k = r.word().ok_or_else(|| trunc(r))? as usize;
                            for _ in 0..k {
                                walk_verb(r, out, level + 1)?;
                            }
                        }
                        8 => ctx = Some(r.word().ok_or_else(|| trunc(r))?),
                        9 => {
                            read_name(r).ok_or_else(|| trunc(r))?;
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
                if !sub && !pkg && !pname.is_empty() {
                    match (verb, ctx) {
                        (226, Some(c)) => out.deps.push(DepEvent::ProcCtx { ctx: c as u8, name: pname.clone() }),
                        _ => out.deps.push(DepEvent::ExecProc { name: pname.clone() }),
                    }
                    for a in arg_names {
                        out.deps.push(DepEvent::ProcArg { proc: pname.clone(), arg: a });
                    }
                }
            }
            Op::TableValueFun => {
                let sub = r.byte().ok_or_else(|| trunc(r))?;
                match sub {
                    1 | 2 => {
                        r.byte().ok_or_else(|| trunc(r))?;
                        read_name(r).ok_or_else(|| trunc(r))?;
                        let k = r.word().ok_or_else(|| trunc(r))? as usize;
                        for _ in 0..k {
                            walk_verb(r, out, level + 1)?;
                        }
                        let k = r.word().ok_or_else(|| trunc(r))? as usize;
                        for _ in 0..k {
                            consume_dtype(r, out).ok_or_else(|| trunc(r))?;
                            read_name(r).ok_or_else(|| trunc(r))?;
                        }
                    }
                    other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                }
            }
            Op::ForRange => {
                walk_tags(r, out, level, |tag, r, out, level| {
                    match tag {
                        1..=5 => walk_verb(r, out, level + 1)?,
                        6 => {
                            r.byte().ok_or_else(|| trunc(r))?;
                        }
                        other => return Err(BlrError::UnknownVerb { verb: other, offset: r.pos - 1 }),
                    }
                    Ok(())
                })?;
            }
            Op::WithinGroupOrder => {
                if r.b.get(r.pos) == Some(&235) {
                    r.byte();
                    let k = r.byte().ok_or_else(|| trunc(r))? as usize;
                    for _ in 0..k {
                        walk_verb(r, out, level + 1)?;
                    }
                }
            }
        }
    }
    emit!();
    Ok(())
}

/// The dependency event a verb's OWN operands amount to, once they are
/// all in - `None` while they are not (the caller asks at every
/// recursion point and at the verb's end, and emits once).
fn stream_event(verb: u8, strings: &[String], bytes: &[u8], words: &[u16]) -> Option<DepEvent> {
    match verb {
        // blr_relation (74): name, ctx | blr_relation2 (146): name, alias, ctx
        74 | 146 => {
            let need = if verb == 74 { 2 } else { 3 };
            if bytes.len() < need {
                return None;
            }
            Some(DepEvent::RelCtx { ctx: *bytes.last()?, name: strings.first()?.clone() })
        }
        // blr_relation3 (148): schema, package, name, alias, ctx
        148 => {
            if bytes.len() < 5 {
                return None;
            }
            Some(DepEvent::RelCtx { ctx: bytes[4], name: strings.get(2)?.clone() })
        }
        // blr_rid (75): id word, ctx | blr_rid2 (147): id, alias, ctx
        75 | 147 => {
            let need = if verb == 75 { 1 } else { 2 };
            if bytes.len() < need {
                return None;
            }
            Some(DepEvent::RelId { ctx: *bytes.last()?, id: *words.first()? })
        }
        // blr_modify (10) / blr_modify2 (172): org ctx, new ctx
        10 | 172 => {
            if bytes.len() < 2 {
                return None;
            }
            Some(DepEvent::ModifyCtx { org: bytes[0], new: bytes[1] })
        }
        // blr_field (23): ctx, name
        23 => Some(DepEvent::Field { ctx: *bytes.first()?, name: strings.first()?.clone() }),
        // blr_fid (24): ctx, id
        24 => Some(DepEvent::Fid { ctx: *bytes.first()?, id: *words.first()? }),
        // blr_procedure (124): name, ctx | procedure2 (133): name, alias, ctx |
        // procedure3 (192): package, name, ctx | procedure4 (198): package,
        // name, alias, ctx - a PACKAGED procedure is no plain row here
        124 | 133 => {
            let need = if verb == 124 { 2 } else { 3 };
            if bytes.len() < need {
                return None;
            }
            Some(DepEvent::ProcCtx { ctx: *bytes.last()?, name: strings.first()?.clone() })
        }
        192 | 198 => None,
        // blr_exec_proc (120): name | exec_proc2 (193): package, name
        120 => Some(DepEvent::ExecProc { name: strings.first()?.clone() }),
        193 => None,
        // blr_gen_id (101) / blr_set_generator (150) / blr_gen_id2 (210): name
        101 | 150 | 210 => Some(DepEvent::GenId { name: strings.first()?.clone() }),
        // blr_gen_id3 (231): schema, name
        231 => {
            if strings.len() < 2 {
                return None;
            }
            Some(DepEvent::GenId { name: strings[1].clone() })
        }
        // blr_function (100): name - blr_sys_function (186) and blr_subfunc
        // (208) share the shape and are NOT user functions; function2
        // (194) is packaged
        100 => Some(DepEvent::Function { name: strings.first()?.clone() }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The paper's FULL_NAME fixture (LAST_NAME || ', ' || FIRST_NAME),
    /// byte-identical across all five language samples.
    const FULL_NAME: &[u8] = &[
        0x05, 0x27, 0x27, 0x17, 0x00, 0x09, b'L', b'A', b'S', b'T', b'_', b'N', b'A', b'M', b'E',
        0x15, 0x0F, 0x00, 0x00, 0x02, 0x00, 0x2C, 0x20, 0x17, 0x00, 0x0A, b'F', b'I', b'R', b'S',
        b'T', b'_', b'N', b'A', b'M', b'E', 0x4C,
    ];

    #[test]
    fn decodes_the_full_name_fixture() {
        let d = decode(FULL_NAME).unwrap();
        assert_eq!(d.version, 5);
        // exactly the two field references the engine records in
        // RDB$DEPENDENCIES for this computed column
        let names: Vec<&str> = d.fields.iter().map(|(_, n)| n.as_str()).collect();
        assert_eq!(names, vec!["LAST_NAME", "FIRST_NAME"]);
        // full clean consume to blr_eoc
        assert!(d.lines.iter().any(|l| l.contains("blr_concatenate")));
        assert_eq!(d.lines.last().unwrap(), "blr_eoc");
    }

    /// FB6 may follow the version with a blr_flags header: tag, word
    /// length, bytes, ..., blr_end (BlrReader::parseHeader). Skipped
    /// whole; the program after it decodes as before.
    #[test]
    fn skips_a_flags_header() {
        let d = decode(&[5, 234, 1, 0, 0, 255, 45, 76]).unwrap();
        assert!(d.lines.iter().any(|l| l.contains("blr_null")));
        assert_eq!(d.lines.last().unwrap(), "blr_eoc");
    }

    /// A blr_double literal is numeric TEXT with a word length
    /// (LiteralNode::parse): `1.5` travels as 3 characters, not 8 bytes.
    #[test]
    fn a_double_literal_is_a_counted_numeric_string() {
        let d = decode(&[5, 21, 27, 3, 0, b'1', b'.', b'5', 76]).unwrap();
        assert_eq!(d.lines.last().unwrap(), "blr_eoc");
        let d = decode(&[5, 21, 26, 0, 2, 0, b'4', b'2', 76]).unwrap();
        assert_eq!(d.lines.last().unwrap(), "blr_eoc");
    }

    /// gbak's generator-value program records the generator it draws; a
    /// blr_abort records the exception it raises.
    #[test]
    fn records_a_generator_draw_and_an_exception() {
        let blr: [u8; 46] = [
            5, 2, 3, 0, 0, 16, 0, 2, 1, 231, 6, 80, 85, 66, 76, 73, 67, 10, 69, 77, 80, 95, 78,
            79, 95, 71, 69, 78, 1, 21, 16, 0, 145, 0, 0, 0, 0, 0, 0, 0, 26, 0, 0, 255, 255, 76,
        ];
        let d = decode(&blr).unwrap();
        assert_eq!(d.deps, vec![DepEvent::GenId { name: "EMP_NO_GEN".into() }]);
        let d = decode(&[5, 128, 2, 3, b'E', b'X', b'C', 76]).unwrap();
        assert_eq!(d.deps, vec![DepEvent::Exception { name: "EXC".into() }]);
    }

    #[test]
    fn rejects_bad_version() {
        assert!(matches!(
            decode(&[0x09, 0x4C]),
            Err(BlrError::BadVersion(9))
        ));
    }

    #[test]
    fn reports_unknown_verb() {
        // version 5, then an unconverted verb byte
        assert!(matches!(
            decode(&[0x05, 0xFE]),
            Err(BlrError::UnknownVerb { verb: 0xFE, .. })
        ));
    }

    #[test]
    fn detects_truncation() {
        // field verb promising a 9-byte name but cut short
        assert!(decode(&[0x05, 0x17, 0x00, 0x09, b'L', b'A']).is_err());
    }
}
