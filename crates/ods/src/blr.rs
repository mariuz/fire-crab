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
        // 5 erase: unsupported (erase)
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
        // 76 union: unsupported (union_ops)
        // 77 map: unsupported (map)
        78 => ("group_by", &[Byte, Line, Args]),
        79 => ("aggregate", &[Byte, Line, Verb, Verb, Verb]),
        // 80 join_type: unsupported (join)
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
        // 128 abort: unsupported (set_error)
        129 => ("block", &[Line, Begin, Verb]),
        // 130 error_handler: unsupported (error_handler)
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
        // 144 indices: unsupported (indices)
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
        // 164 exec_into: unsupported (exec_into)
        165 => ("user_savepoint", &[Byte, Byte, Literal, Line]),
        166 => ("dcl_cursor", &[Word, Line, Verb, Indent, Word, Line, Args]),
        // 167 cursor_stmt: unsupported (cursor_stmt)
        168 => ("current_timestamp2", &[Byte, Line]),
        169 => ("current_time2", &[Byte, Line]),
        // 170 agg_list: unsupported (list_function)
        // 171 agg_list_distinct: unsupported (list_function)
        172 => ("modify2", &[Byte, Byte, Line, Verb, Verb]),
        // 173 erase2: unsupported (erase2)
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
        // 185 recurse: unsupported (union_ops)
        186 => ("sys_function", &[Byte, Literal, Byte, Line, Args]),
        187 => ("auto_trans", &[Byte, Line, Verb]),
        188 => ("similar", &[Line, Verb, Verb, Indent, ByteOptVerb]),
        // 189 exec_stmt: unsupported (exec_stmt)
        190 => ("stmt_expr", &[Line, Verb, Verb]),
        // 191 derived_expr: unsupported (derived_expr)
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
        // 196 partition_by: unsupported (partition_by)
        197 => ("continue_loop", &[Byte, Line]),
        198 => (
            "procedure4",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent,
                Word, Line, Parameters,
            ],
        ),
        // 199 agg_function: unsupported (agg_function)
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
        // 205 subproc_decl: unsupported (subproc_decl)
        206 => (
            "subproc",
            &[
                Byte, Literal, Pad, Byte, Literal, Pad, Byte, Line, Indent, Word, Line, Parameters,
            ],
        ),
        // 207 subfunc_decl: unsupported (subfunc_decl)
        208 => ("subfunc", &[Byte, Literal, Byte, Line, Args]),
        209 => ("record_version2", &[Byte, Line]),
        210 => ("gen_id2", &[Byte, Literal, Line]),
        // 211 window_win: unsupported (window_win)
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
        // 218 dcl_local_table: unsupported (dcl_local_table)
        219 => ("local_table_truncate", &[Word, Line]),
        220 => ("local_table_id", &[Word, Byte, Literal, Byte, Line]),
        // 221 outer_map: unsupported (outer_map)
        223 => ("skip_locked", &[Line]),
        // 224 invoke_function: unsupported (invoke_function)
        // 225 invoke_procedure: unsupported (invsel_procedure)
        // 226 select_procedure: unsupported (invsel_procedure)
        227 => ("default_arg", &[Line]),
        228 => (
            "cast_format",
            &[Line, Indent, Byte, Literal, Line, Indent, Dtype, Line, Verb],
        ),
        // 229 table_value_fun: unsupported (table_value_fun)
        // 230 for_range: unsupported (for_range)
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
        // 236 invoke_agg_function: unsupported (custom_agg_function)
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

/// Consume a datatype descriptor (gds.cpp blr_print_dtype), returning
/// the literal-data width that follows a `blr_literal` of this type.
fn consume_dtype(r: &mut Reader) -> Option<(usize, &'static str)> {
    let dtype = r.byte()?;
    let name = dtype_name(dtype);
    // codes from blr.h; scale/charset/length trailers per gds.cpp
    let width = match dtype {
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
        26 => {
            r.byte()?;
            16
        } // blr_int128 (+scale)
        9 => 8,                       // blr_quad
        10 => 4,                      // blr_float
        11 => 8,                      // blr_d_float
        27 => 8,                      // blr_double
        12 => 4,                      // blr_sql_date
        13 => 4,                      // blr_sql_time
        28 => 6,                      // blr_sql_time_tz
        35 => 8,                      // blr_timestamp
        29 => 10,                     // blr_timestamp_tz
        23 => 1,                      // blr_bool
        24 => 8,                      // blr_dec64
        25 => 16,                     // blr_dec128
        14 => r.word()? as usize,     // blr_text   (+len)
        37 => r.word()? as usize + 2, // blr_varying (+len, +2)
        40 => r.word()? as usize,     // blr_cstring (+len)
        15 => {
            r.word()?;
            r.word()? as usize
        } // blr_text2   (+charset,+len)
        38 => {
            r.word()?;
            r.word()? as usize + 2
        } // blr_varying2 (+charset,+len,+2)
        41 => {
            r.word()?;
            r.word()? as usize
        } // blr_cstring2 (+charset,+len)
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

fn walk_verb(r: &mut Reader, out: &mut BlrDecode, level: usize) -> Result<(), BlrError> {
    let offset = r.pos;
    let verb = r.byte().ok_or(BlrError::Truncated { offset })?;
    let (name, ops) = verb_format(verb).ok_or(BlrError::UnknownVerb { verb, offset })?;
    out.lines
        .push(format!("{}blr_{}", "   ".repeat(level), name));

    // capture field/relation names as their literal operand is read
    let mut pending_context: Option<u8> = None;
    let mut byte_stack: Vec<u8> = Vec::new();
    let mut n: usize = 0;

    for op in ops {
        match op {
            Op::Line | Op::Pad | Op::Indent => {}
            Op::Byte => {
                let v = r.byte().ok_or(BlrError::Truncated { offset: r.pos })?;
                n = v as usize;
                byte_stack.push(v);
                if verb == 23 && pending_context.is_none() {
                    pending_context = Some(v); // field context
                }
            }
            Op::Word => {
                n = r.word().ok_or(BlrError::Truncated { offset: r.pos })? as usize;
            }
            Op::Dtype => {
                let (w, dname) = consume_dtype(r).ok_or(BlrError::Truncated { offset: r.pos })?;
                n = w;
                // isql prints the dtype as its own token; emit it so the
                // blr_* token streams line up verb-for-verb
                out.lines
                    .push(format!("{}{}", "   ".repeat(level + 1), dname));
            }
            Op::Literal => {
                let data = r.take(n).ok_or(BlrError::Truncated { offset: r.pos })?;
                if verb == 23 {
                    // blr_field: the literal is the field name
                    let name = String::from_utf8_lossy(data).into_owned();
                    out.fields
                        .push((pending_context.unwrap_or(0), name.clone()));
                    *out.lines.last_mut().unwrap() += &format!(" '{}'", name);
                } else if verb == 74 {
                    // blr_relation: the literal is the relation name
                    let name = String::from_utf8_lossy(data).into_owned();
                    out.relations.push(name.clone());
                    *out.lines.last_mut().unwrap() += &format!(" '{}'", name);
                }
            }
            Op::Verb => walk_verb(r, out, level + 1)?,
            Op::Begin => {
                // peek for blr_end without consuming it (gds op_begin);
                // the trailing Verb in the format reads it as blr_end
                while r.b.get(r.pos) != Some(&255) {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::Message => {
                for _ in 0..n {
                    let (_, dname) =
                        consume_dtype(r).ok_or(BlrError::Truncated { offset: r.pos })?;
                    out.lines
                        .push(format!("{}{}", "   ".repeat(level + 1), dname));
                }
            }
            Op::Args | Op::Parameters => {
                // uses the count set by the preceding Byte/Word (n), like
                // gds.cpp op_args `while (--n >= 0) blr_print_verb`
                for _ in 0..n {
                    walk_verb(r, out, level + 1)?;
                }
            }
            Op::ByteOptVerb => {
                let v = r.byte().ok_or(BlrError::Truncated { offset: r.pos })?;
                if v != 0 {
                    walk_verb(r, out, level + 1)?;
                }
            }
        }
    }
    Ok(())
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
