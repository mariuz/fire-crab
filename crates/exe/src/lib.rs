//! BLR request execution - the conversion of `src/jrd/exe.cpp`'s
//! statement looper and the `src/jrd/recsrc/` record sources (the
//! Volcano iterator tree the paper's execution chapter describes).
//!
//! THE ORACLE IS THE ENGINE RUNNING THE SAME BYTES. A procedure's
//! compiled BLR sits verbatim in `RDB$PROCEDURE_BLR` - the blob
//! `fire-crab-dsql` already matches byte-for-byte from the SQL text.
//! This crate picks that blob up and EXECUTES it against the database
//! file through `fire-crab-ods` (the committed-visibility scan), and
//! `SELECT * FROM <proc>` on the C++ engine must produce the identical
//! rows: SQL -> (fcdsql) BLR -> (fcexe) rows, every arrow checked
//! against the original.
//!
//! Slice 1 executes the `FOR SELECT ... DO SUSPEND` wrapper the dsql
//! crate emits for parameterless procedures over ONE stream: messages,
//! declares, stall, labels, the for-loop over an rse (relation +
//! boolean), assignments, and the twin sends. The record source is the
//! sequential scan (`FullTableScan` + the `VIO_get` visibility rule,
//! already converted as `fire_crab_ods::visible_rows`) under a
//! filter (`FilteredStream` - the boolean evaluated with the engine's
//! three-valued logic). Everything else REFUSES - an unknown verb is
//! an error, never a guess, exactly the dsql crate's rule facing the
//! other direction.

use fire_crab_ods::{
    decode_record, read_blob_content, relation_columns, relation_data_pages,
    resolve_relation, system_relation_formats, visible_rows, DataPage, TipChain,
    Value,
};

/// The BLR verbs this executor understands - `blr.h` values. The
/// numbers are the same table `fire-crab-dsql` emits from; this crate
/// keeps its own copy because the two crates face opposite directions
/// (one writes the bytes, one runs them) and must not be able to
/// drift in lockstep by sharing a constant.
mod blr {
    pub const ASSIGNMENT: u8 = 1;
    pub const BEGIN: u8 = 2;
    pub const DECLARE: u8 = 3;
    pub const MESSAGE: u8 = 4;
    pub const VERSION5: u8 = 5;
    pub const FOR: u8 = 7;
    pub const RECEIVE: u8 = 12;
    pub const SEND: u8 = 14;
    pub const LABEL: u8 = 17;
    pub const LITERAL: u8 = 21;
    pub const ADD: u8 = 34;
    pub const SUBTRACT: u8 = 35;
    pub const MULTIPLY: u8 = 36;
    pub const DIVIDE: u8 = 37;
    pub const NEGATE: u8 = 38;
    pub const CONCATENATE: u8 = 39;
    pub const SUBSTRING: u8 = 40;
    pub const VIA: u8 = 43;
    pub const GEN_ID: u8 = 101;
    pub const UPCASE: u8 = 103;
    pub const LOWCASE: u8 = 181;
    pub const STRLEN: u8 = 182;
    pub const TRIM: u8 = 183;
    pub const VALUE_IF: u8 = 105;
    pub const CAST: u8 = 131;
    pub const COALESCE: u8 = 202;
    pub const DECODE: u8 = 203;
    pub const FIELD: u8 = 23;
    pub const FID: u8 = 24;
    pub const PARAMETER: u8 = 25;
    pub const VARIABLE: u8 = 26;
    pub const PARAMETER2: u8 = 41;
    pub const EQL: u8 = 47;
    pub const NEQ: u8 = 48;
    pub const GTR: u8 = 49;
    pub const GEQ: u8 = 50;
    pub const LSS: u8 = 51;
    pub const LEQ: u8 = 52;
    pub const MATCHING: u8 = 54;
    pub const STARTING: u8 = 55;
    pub const BETWEEN: u8 = 56;
    pub const OR: u8 = 57;
    pub const AND: u8 = 58;
    pub const NOT: u8 = 59;
    pub const ANY: u8 = 60;
    pub const MISSING: u8 = 61;
    pub const UNIQUE: u8 = 62;
    pub const LIKE: u8 = 63;
    pub const IN_LIST: u8 = 64;
    pub const RSE: u8 = 67;
    /// 76 doubles as blr_eoc - position disambiguates: union stands
    /// in a stream slot, eoc at the top level
    pub const UNION: u8 = 76;
    pub const FIRST: u8 = 68;
    pub const PROJECT: u8 = 69;
    pub const BOOLEAN: u8 = 71;
    pub const RELATION: u8 = 74;
    pub const MAP: u8 = 77;
    pub const GROUP_BY: u8 = 78;
    pub const AGGREGATE: u8 = 79;
    pub const AGG_COUNT: u8 = 83;
    pub const AGG_MAX: u8 = 84;
    pub const AGG_MIN: u8 = 85;
    pub const AGG_TOTAL: u8 = 86;
    pub const AGG_AVERAGE: u8 = 87;
    pub const AGG_COUNT2: u8 = 93;
    pub const JOIN_TYPE: u8 = 80;
    pub const RS_STREAM: u8 = 119;
    // blr_join_type operands (blr.h): inner 0, left 1, right 2, full 3
    pub const LEFT: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const FULL: u8 = 3;
    pub const SINGULAR: u8 = 127;
    pub const PLAN: u8 = 139;
    pub const ANSI_ANY: u8 = 151;
    pub const WINDOW: u8 = 195;
    pub const PARTITION_BY: u8 = 196;
    pub const AGG_FUNCTION: u8 = 199;
    pub const RECURSE: u8 = 185;
    pub const GEN_ID2: u8 = 210;
    pub const WINDOW_WIN: u8 = 211;
    // blr_window_win subcodes
    pub const WW_PARTITION: u8 = 1;
    pub const WW_ORDER: u8 = 2;
    pub const WW_MAP: u8 = 3;
    pub const WW_EXTENT_UNIT: u8 = 4;
    pub const WW_FRAME_BOUND: u8 = 5;
    pub const WW_FRAME_VALUE: u8 = 6;
    pub const ANSI_ALL: u8 = 158;
    pub const DERIVED_EXPR: u8 = 191;
    pub const SEQUENTIAL: u8 = 142;
    pub const INDICES: u8 = 144;
    pub const RETRIEVE: u8 = 145;
    pub const RELATION2: u8 = 146;
    pub const SKIP: u8 = 175;
    pub const END: u8 = 255;
    pub const EOC: u8 = 76;
    pub const NULL: u8 = 45;
    pub const STALL: u8 = 155;
    pub const SORT: u8 = 70;
    pub const ASCENDING: u8 = 72;
    pub const DESCENDING: u8 = 73;
    // message-descriptor dtypes (blr.h dtype language)
    pub const DT_SHORT: u8 = 7;
    pub const DT_LONG: u8 = 8;
    pub const DT_INT64: u8 = 16;
    pub const DT_TEXT: u8 = 14;
    pub const DT_TEXT2: u8 = 15;
    pub const DT_VARYING: u8 = 37;
    pub const DT_VARYING2: u8 = 38;
}

/// One slot of a message: its BLR dtype and, for text, the declared
/// byte length. The message is the request's wire contract - EXE_send
/// copies the slots out in declaration order.
#[derive(Clone, Debug)]
pub struct MsgSlot {
    pub dtype: u8,
    pub length: u16,
    #[allow(dead_code)]
    pub scale: i8,
}

/// A value expression the looper can evaluate - the slice-1 subset of
/// the engine's expression nodes.
#[derive(Clone, Debug)]
pub enum Expr {
    /// blr_field: context + field name, resolved to the record's
    /// field id when the stream binds
    Field(u8, String),
    /// blr_variable
    Variable(u16),
    /// blr_parameter2 read as a VALUE: (message, value slot) - the
    /// null companion travels with the buffer, not the expression
    Parameter(u8, u16),
    /// blr_fid: an aggregate output slot (context, position)
    Fid(u8, u16),
    /// blr_literal, already decoded to a Value
    Literal(Value),
    /// blr_add/subtract/multiply/divide/concatenate - the arithmetic
    /// verb and both operands; NULL propagates, integer division
    /// truncates toward zero, divide-by-zero is a runtime ERROR
    Arith(u8, Box<Expr>, Box<Expr>),
    /// blr_negate
    Negate(Box<Expr>),
    /// blr_gen_id / blr_gen_id2: read-and-advance a generator - the
    /// step expression for GEN_ID, the sequence's own increment for
    /// NEXT VALUE FOR. The advance lands in an IN-MEMORY overlay:
    /// consecutive reads in one execution see it, the FILE is never
    /// written (fcexe is a harness; the wire server excludes
    /// generator-writing requests from the BLR path and lets its
    /// persisting interpreter serve them)
    GenId(String, Option<Box<Expr>>),
    /// blr_upcase / blr_lowcase - ASCII case mapping (the charset
    /// layer waits with internationalization)
    CaseMap(bool, Box<Expr>),
    /// blr_strlen: the length-type byte (1 = CHAR_LENGTH, 2 =
    /// OCTET_LENGTH) and the operand
    StrLen(u8, Box<Expr>),
    /// blr_substring(value, start, length) - the start is 0-BASED,
    /// compiled as the reference compiler's unfolded subtract
    Substr(Box<Expr>, Box<Expr>, Box<Expr>),
    /// blr_trim: where (0 both, 1 leading, 2 trailing), spec 0 =
    /// spaces (spec 1, trim-by-character, is unconverted)
    Trim(u8, Box<Expr>),
    /// blr_cast: convert to the carried descriptor's type - range
    /// checks error (never wrap), text width overflows error (never
    /// silently truncate), NULL passes through
    Cast(MsgSlot, Box<Expr>),
    /// blr_coalesce: the first non-NULL of the counted operands
    Coalesce(Vec<Expr>),
    /// blr_decode: the simple CASE - an operand, the counted
    /// condition values, the counted results (one extra = ELSE);
    /// a NULL operand matches nothing and takes the else
    Decode(Box<Expr>, Vec<Expr>, Vec<Expr>),
    /// blr_value_if(cond, then, else) - the conditional value CASE
    /// compiles to (under a unifying cast)
    ValueIf(Box<Bool>, Box<Expr>, Box<Expr>),
    /// blr_via(singular-rse, value, else): the scalar subselect -
    /// one row binds and the value evaluates, none and the else
    /// does, more than one is the engine's sing_err
    Via(Box<Rse>, Box<Expr>, Box<Expr>),
    /// blr_null
    Null,
}

/// A boolean node - evaluated with the engine's three-valued logic
/// (`Option<bool>`, `None` = UNKNOWN; a filter keeps only `Some(true)`).
#[derive(Clone, Debug)]
pub enum Bool {
    Cmp(u8, Expr, Expr),
    And(Box<Bool>, Box<Bool>),
    Or(Box<Bool>, Box<Bool>),
    Not(Box<Bool>),
    Missing(Expr),
    /// blr_in_list: operand = any of the u16-counted values (3VL:
    /// no match beside a NULL comparand is UNKNOWN, not false)
    InList(Expr, Vec<Expr>),
    /// blr_between: lo <= v AND v <= hi, three-valued
    Between(Expr, Expr, Expr),
    /// blr_like: SQL LIKE - % any run, _ one character
    Like(Expr, Expr),
    /// blr_starting: STARTING WITH - a plain prefix test
    Starting(Expr, Expr),
    /// blr_any: EXISTS - the rse yields at least one row (the
    /// correlated outer frames stay on the stack during the scan)
    Any(Box<Rse>),
    /// blr_unique: SINGULAR - exactly one row
    UniqueRse(Box<Rse>),
    /// blr_ansi_any / blr_ansi_all: the quantified comparison - a
    /// wrapper rse whose single stream IS the subquery and whose
    /// boolean is the comparison; `all` flips the quantifier
    Quantified { all: bool, rse: Box<Rse> },
}

/// One sort key of an rse's blr_sort clause: the expression and its
/// direction (true = descending).
#[derive(Clone, Debug)]
pub struct SortKey {
    pub expr: Expr,
    pub desc: bool,
}

/// One aggregate-map entry: the output slot and what fills it - an
/// aggregate verb over an optional operand, or a plain value (a
/// group key passed through).
#[derive(Clone, Debug)]
pub enum MapItem {
    Agg(u8, Option<Expr>),
    Value(Expr),
}

/// A blr_aggregate stream: its own context over an inner rse, the
/// group keys, and the map - the AggregatedStream of recsrc/.
#[derive(Clone, Debug)]
pub struct Aggregate {
    pub context: u8,
    pub source: Box<Rse>,
    pub group_by: Vec<Expr>,
    pub map: Vec<(u16, MapItem)>,
}

/// One relation stream of a join: catalog name and context (the
/// alias is display-only - context is the binding).
#[derive(Clone, Debug)]
pub struct JoinStream {
    pub name: String,
    pub context: u8,
}

/// One side of a join: a relation, or a NESTED join - chains
/// left-nest (the inner rs_stream stands as the outer's first
/// stream, exactly the shape the dsql crate emits).
#[derive(Clone, Debug)]
pub enum JoinSource {
    Rel(JoinStream),
    Nested(Box<Stream>),
}

/// A join's kind - blr_join_type's operand; INNER when the
/// sub-clause is absent.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum JoinKind {
    Inner,
    Left,
    Right,
    Full,
}

/// One item of a window's map: an aggregate verb, a named window
/// function (ROW_NUMBER / RANK / DENSE_RANK ride blr_agg_function),
/// or a passthrough value.
#[derive(Clone, Debug)]
pub enum WinItem {
    Agg(u8, Option<Expr>),
    Fn(String, Vec<Expr>),
    Value(Expr),
}

/// One frame bound: 0 = PRECEDING, 1 = FOLLOWING, 2 = CURRENT ROW;
/// a PRECEDING/FOLLOWING bound without a value is UNBOUNDED.
#[derive(Clone, Debug)]
pub struct FrameBound {
    pub kind: u8,
    pub value: Option<Expr>,
}

/// A v4 frame extent: the unit (0 = RANGE, 1 = ROWS) and the two
/// bounds (a missing second bound means CURRENT ROW).
#[derive(Clone, Debug)]
pub struct Frame {
    pub unit: u8,
    pub start: FrameBound,
    pub end: FrameBound,
}

/// One window of a blr_window stream: its context, partition keys,
/// ORDER keys, map and optional v4 frame. The remap fids after the
/// partition keys are bookkeeping (they name the keys' own map
/// slots) and parse away.
#[derive(Clone, Debug)]
pub struct Win {
    pub context: u8,
    pub partition: Vec<Expr>,
    pub order: Vec<SortKey>,
    pub map: Vec<(u16, WinItem)>,
    pub frame: Option<Frame>,
}

/// The stream slot of an rse: a plain relation scan, an aggregate
/// over an inner rse, a join (blr_rs_stream) - the NestedLoopJoin /
/// FullOuterJoin of recsrc/ - or a DERIVED TABLE: a nested rse
/// standing where a stream would, its bindings passing through
/// (the inner stream's context IS what outer references name).
#[derive(Clone, Debug)]
pub enum Stream {
    Relation { name: String, context: u8 },
    Aggregate(Aggregate),
    Join { streams: Vec<JoinSource>, kind: JoinKind, on: Option<Bool> },
    Derived(Box<Rse>),
    /// blr_union: its own context, per-branch (rse, positional map) -
    /// branches concatenate in order (ALL; the distinct form rides
    /// the outer rse's blr_project over the union's fids)
    Union { context: u8, branches: Vec<(Rse, Vec<(u16, Expr)>)> },
    /// blr_recurse: the recursion tower - its own context, a
    /// SECONDARY recursive-context byte, an ANCHOR branch (a real
    /// rse + map) and a STREAM-LESS recursive branch whose boolean
    /// and map read the recursion's own output by fid
    Recurse {
        context: u8,
        anchor: Box<Rse>,
        anchor_map: Vec<(u16, Expr)>,
        rec_boolean: Option<Bool>,
        rec_map: Vec<(u16, Expr)>,
    },
    /// blr_window: the inner rse and the windows over it - every
    /// source row survives (a window is an aggregate that KEEPS its
    /// rows), each window's context binding a slot-row of computed
    /// values the body reads by fid
    Window { source: Box<Rse>, windows: Vec<Win> },
}

/// The record-selection expression of a blr_for: one stream, the
/// optional clauses - FullTableScan (or AggregatedStream) under
/// FilteredStream under SortedStream under SkipRowsStream under
/// FirstRowsStream, the Volcano tower in the engine's own order
/// (sort, then skip, then first).
#[derive(Clone, Debug)]
pub struct Rse {
    pub stream: Stream,
    pub boolean: Option<Bool>,
    pub sort: Vec<SortKey>,
    pub first: Option<Expr>,
    pub skip: Option<Expr>,
    /// blr_project: DISTINCT - the projected expressions; rows
    /// dedupe on them with NULL equal to NULL (set semantics)
    pub project: Vec<Expr>,
    /// blr_plan (T INDEX (names)): retrieve through the named
    /// indexes - the BitmapTableScan; empty = none/NATURAL
    pub plan_indices: Vec<String>,
    /// blr_singular: at most one row - a second is a genuine error
    pub singular: bool,
}

/// A statement node of the looper's subset.
#[derive(Clone, Debug)]
pub enum Stmt {
    Begin(Vec<Stmt>),
    /// blr_label: the number only matters to blr_leave, which slice 1
    /// does not execute - kept for the day it does
    Label(u8, Box<Stmt>),
    For(Rse, Box<Stmt>),
    /// blr_send: message number + the statement filling it
    Send(u8, Box<Stmt>),
    /// blr_assignment: source expression into a target
    Assign(Expr, Target),
    /// blr_stall - the scheduling point between EXE_start and the
    /// first EXE_receive; a no-op for this synchronous executor
    Stall,
}

/// An assignment target.
#[derive(Clone, Debug)]
pub enum Target {
    Variable(u16),
    /// blr_parameter: (message, slot)
    Parameter(u8, u16),
    /// blr_parameter2: (message, value slot, null-flag slot)
    Parameter2(u8, u16, u16),
}

/// A parsed request: the message formats and the body.
pub struct Request {
    pub messages: Vec<(u8, Vec<MsgSlot>)>,
    pub declares: usize,
    pub body: Stmt,
    /// GEN_ID / NEXT VALUE FOR appears in the body: executing this
    /// request ADVANCES generator state (in-memory here; a caller
    /// that must persist should route around this executor)
    pub uses_generators: bool,
}

// ---------------------------------------------------------------- parse

struct P<'a> {
    b: &'a [u8],
    i: usize,
    /// the request reads-and-advances a generator somewhere
    uses_generators: bool,
}

impl<'a> P<'a> {
    fn u8(&mut self) -> Result<u8, String> {
        let v = *self.b.get(self.i).ok_or("BLR ends early")?;
        self.i += 1;
        Ok(v)
    }
    fn u16(&mut self) -> Result<u16, String> {
        let lo = self.u8()? as u16;
        let hi = self.u8()? as u16;
        Ok(lo | (hi << 8))
    }
    fn counted_name(&mut self) -> Result<String, String> {
        let n = self.u8()? as usize;
        let s = self
            .b
            .get(self.i..self.i + n)
            .ok_or("name ends early")?
            .to_vec();
        self.i += n;
        String::from_utf8(s).map_err(|_| "name not utf8".into())
    }

    /// One message-descriptor dtype - the subset the dsql crate emits
    /// for INTEGER/SMALLINT/BIGINT/VARCHAR outputs.
    fn msg_slot(&mut self) -> Result<MsgSlot, String> {
        let dtype = self.u8()?;
        Ok(match dtype {
            blr::DT_SHORT | blr::DT_LONG | blr::DT_INT64 => MsgSlot {
                dtype,
                length: 0,
                scale: self.u8()? as i8,
            },
            blr::DT_TEXT | blr::DT_VARYING => MsgSlot {
                dtype,
                length: self.u16()?,
                scale: 0,
            },
            // the charset-carrying twins: u16 charset, then length
            blr::DT_TEXT2 | blr::DT_VARYING2 => {
                let _charset = self.u16()?;
                MsgSlot { dtype, length: self.u16()?, scale: 0 }
            }
            // the charset-carrying twins: u16 charset, then the length
            blr::DT_TEXT2 | blr::DT_VARYING2 => {
                let _charset = self.u16()?;
                MsgSlot { dtype, length: self.u16()?, scale: 0 }
            }
            other => return Err(format!("message dtype {} unconverted", other)),
        })
    }

    /// A positional map: u16 count, then (u16 slot, value) pairs.
    fn map_pairs(&mut self) -> Result<Vec<(u16, Expr)>, String> {
        let n = self.u16()? as usize;
        let mut map = Vec::new();
        for _ in 0..n {
            let slot = self.u16()?;
            map.push((slot, self.expr()?));
        }
        Ok(map)
    }

    /// A window map: u16 count, then (u16 slot, item) - items are
    /// aggregate verbs, blr_agg_function names, or passthroughs.
    fn win_map(&mut self) -> Result<Vec<(u16, WinItem)>, String> {
        let mn = self.u16()? as usize;
        let mut map = Vec::new();
        for _ in 0..mn {
            let slot = self.u16()?;
            let item = match self.b.get(self.i) {
                Some(&blr::AGG_COUNT) => {
                    self.i += 1;
                    WinItem::Agg(blr::AGG_COUNT, None)
                }
                Some(&v @ (blr::AGG_MAX | blr::AGG_MIN | blr::AGG_TOTAL
                    | blr::AGG_AVERAGE | blr::AGG_COUNT2)) => {
                    self.i += 1;
                    WinItem::Agg(v, Some(self.expr()?))
                }
                Some(&blr::AGG_FUNCTION) => {
                    self.i += 1;
                    let name = self.counted_name()?;
                    let argc = self.u8()? as usize;
                    let mut args = Vec::new();
                    for _ in 0..argc {
                        args.push(self.expr()?);
                    }
                    WinItem::Fn(name, args)
                }
                _ => WinItem::Value(self.expr()?),
            };
            map.push((slot, item));
        }
        Ok(map)
    }

    /// A sort-key list: count byte + direction-tagged expressions.
    fn sort_keys(&mut self) -> Result<Vec<SortKey>, String> {
        let sn = self.u8()? as usize;
        let mut order = Vec::new();
        for _ in 0..sn {
            let desc = match self.u8()? {
                blr::ASCENDING => false,
                blr::DESCENDING => true,
                other => return Err(format!("sort direction {} unconverted", other)),
            };
            order.push(SortKey { expr: self.expr()?, desc });
        }
        Ok(order)
    }

    /// One blr_rs_stream node: stream count, the sources (relations
    /// or NESTED rs_streams - chains left-nest), the optional
    /// join_type and ON boolean, its end.
    fn rs_stream(&mut self) -> Result<Stream, String> {
        let n = self.u8()? as usize;
        let mut streams = Vec::new();
        for _ in 0..n {
            match self.u8()? {
                blr::RELATION => {
                    let name = self.counted_name()?;
                    let context = self.u8()?;
                    streams.push(JoinSource::Rel(JoinStream { name, context }));
                }
                blr::RELATION2 => {
                    let name = self.counted_name()?;
                    let _alias = self.counted_name()?;
                    let context = self.u8()?;
                    streams.push(JoinSource::Rel(JoinStream { name, context }));
                }
                blr::RS_STREAM => {
                    streams.push(JoinSource::Nested(Box::new(self.rs_stream()?)));
                }
                other => {
                    return Err(format!("join stream verb {} unconverted", other))
                }
            }
        }
        let mut on = None;
        let mut kind = JoinKind::Inner;
        loop {
            match self.u8()? {
                blr::BOOLEAN => on = Some(self.boolean()?),
                blr::JOIN_TYPE => {
                    kind = match self.u8()? {
                        blr::LEFT => JoinKind::Left,
                        blr::RIGHT => JoinKind::Right,
                        blr::FULL => JoinKind::Full,
                        other => {
                            return Err(format!("join type {} unconverted", other))
                        }
                    };
                }
                blr::END => break,
                other => return Err(format!("join clause {} unconverted", other)),
            }
        }
        if kind != JoinKind::Inner && streams.len() != 2 {
            return Err("outer join over more than two streams unconverted".into());
        }
        Ok(Stream::Join { streams, kind, on })
    }

    fn expr(&mut self) -> Result<Expr, String> {
        match self.u8()? {
            blr::FIELD => {
                let ctx = self.u8()?;
                Ok(Expr::Field(ctx, self.counted_name()?))
            }
            blr::VARIABLE => Ok(Expr::Variable(self.u16()?)),
            blr::PARAMETER2 => {
                let msg = self.u8()?;
                let val = self.u16()?;
                let _null = self.u16()?;
                Ok(Expr::Parameter(msg, val))
            }
            blr::FID => {
                let ctx = self.u8()?;
                Ok(Expr::Fid(ctx, self.u16()?))
            }
            blr::NULL => Ok(Expr::Null),
            blr::CAST => {
                let slot = self.msg_slot()?;
                Ok(Expr::Cast(slot, Box::new(self.expr()?)))
            }
            blr::COALESCE => {
                let n = self.u8()? as usize;
                let mut ops = Vec::new();
                for _ in 0..n {
                    ops.push(self.expr()?);
                }
                Ok(Expr::Coalesce(ops))
            }
            blr::GEN_ID => {
                self.uses_generators = true;
                let name = self.counted_name()?;
                Ok(Expr::GenId(name, Some(Box::new(self.expr()?))))
            }
            blr::GEN_ID2 => {
                self.uses_generators = true;
                Ok(Expr::GenId(self.counted_name()?, None))
            }
            blr::UPCASE => Ok(Expr::CaseMap(true, Box::new(self.expr()?))),
            blr::LOWCASE => Ok(Expr::CaseMap(false, Box::new(self.expr()?))),
            blr::STRLEN => {
                let kind = self.u8()?;
                Ok(Expr::StrLen(kind, Box::new(self.expr()?)))
            }
            blr::SUBSTRING => Ok(Expr::Substr(
                Box::new(self.expr()?),
                Box::new(self.expr()?),
                Box::new(self.expr()?),
            )),
            blr::TRIM => {
                let wher = self.u8()?;
                let spec = self.u8()?;
                if spec != 0 {
                    return Err("TRIM by character unconverted".into());
                }
                Ok(Expr::Trim(wher, Box::new(self.expr()?)))
            }
            blr::DECODE => {
                let operand = Box::new(self.expr()?);
                let n = self.u8()? as usize;
                let mut conds = Vec::new();
                for _ in 0..n {
                    conds.push(self.expr()?);
                }
                let m = self.u8()? as usize;
                let mut results = Vec::new();
                for _ in 0..m {
                    results.push(self.expr()?);
                }
                Ok(Expr::Decode(operand, conds, results))
            }
            blr::VALUE_IF => Ok(Expr::ValueIf(
                Box::new(self.boolean()?),
                Box::new(self.expr()?),
                Box::new(self.expr()?),
            )),
            blr::VIA => {
                let rse = self.rse_entry()?;
                let value = Box::new(self.expr()?);
                let els = Box::new(self.expr()?);
                Ok(Expr::Via(Box::new(rse), value, els))
            }
            blr::DERIVED_EXPR => {
                // bookkeeping wrapper: stream count + stream ids,
                // then the expression itself
                let n = self.u8()? as usize;
                for _ in 0..n {
                    let _stream = self.u8()?;
                }
                self.expr()
            }
            v @ (blr::ADD | blr::SUBTRACT | blr::MULTIPLY | blr::DIVIDE
            | blr::CONCATENATE) => Ok(Expr::Arith(
                v,
                Box::new(self.expr()?),
                Box::new(self.expr()?),
            )),
            blr::NEGATE => Ok(Expr::Negate(Box::new(self.expr()?))),
            blr::LITERAL => {
                let s = self.msg_slot()?;
                Ok(Expr::Literal(match s.dtype {
                    blr::DT_SHORT => {
                        let v = self.u16()? as i16;
                        scaled(v as i64, s.scale)
                    }
                    blr::DT_LONG => {
                        let mut raw = [0u8; 4];
                        for byte in raw.iter_mut() {
                            *byte = self.u8()?;
                        }
                        scaled(i32::from_le_bytes(raw) as i64, s.scale)
                    }
                    blr::DT_INT64 => {
                        let mut raw = [0u8; 8];
                        for byte in raw.iter_mut() {
                            *byte = self.u8()?;
                        }
                        scaled(i64::from_le_bytes(raw), s.scale)
                    }
                    blr::DT_TEXT | blr::DT_VARYING | blr::DT_TEXT2
                    | blr::DT_VARYING2 => {
                        let n = s.length as usize;
                        let bytes = self
                            .b
                            .get(self.i..self.i + n)
                            .ok_or("literal ends early")?
                            .to_vec();
                        self.i += n;
                        Value::Text(
                            String::from_utf8(bytes)
                                .map_err(|_| "literal not utf8")?,
                        )
                    }
                    other => return Err(format!("literal dtype {} unconverted", other)),
                }))
            }
            other => Err(format!("value verb {} unconverted", other)),
        }
    }

    fn boolean(&mut self) -> Result<Bool, String> {
        let verb = self.u8()?;
        Ok(match verb {
            blr::EQL | blr::NEQ | blr::GTR | blr::GEQ | blr::LSS | blr::LEQ => {
                Bool::Cmp(verb, self.expr()?, self.expr()?)
            }
            blr::AND => Bool::And(Box::new(self.boolean()?), Box::new(self.boolean()?)),
            blr::OR => Bool::Or(Box::new(self.boolean()?), Box::new(self.boolean()?)),
            blr::NOT => Bool::Not(Box::new(self.boolean()?)),
            blr::MISSING => Bool::Missing(self.expr()?),
            blr::IN_LIST => {
                let v = self.expr()?;
                let n = self.u16()? as usize;
                let mut list = Vec::new();
                for _ in 0..n {
                    list.push(self.expr()?);
                }
                Bool::InList(v, list)
            }
            blr::BETWEEN => Bool::Between(self.expr()?, self.expr()?, self.expr()?),
            blr::LIKE => Bool::Like(self.expr()?, self.expr()?),
            blr::STARTING => Bool::Starting(self.expr()?, self.expr()?),
            blr::ANY => Bool::Any(Box::new(self.rse_entry()?)),
            blr::UNIQUE => Bool::UniqueRse(Box::new(self.rse_entry()?)),
            v @ (blr::ANSI_ANY | blr::ANSI_ALL) => {
                if self.u8()? != blr::RSE {
                    return Err("quantified predicate without an rse".into());
                }
                Bool::Quantified {
                    all: v == blr::ANSI_ALL,
                    rse: Box::new(self.rse_body()?),
                }
            }
            other => return Err(format!("boolean verb {} unconverted", other)),
        })
    }

    /// A blr_for's source: `[blr_singular] blr_rse <body>`.
    fn rse_entry(&mut self) -> Result<Rse, String> {
        let singular = if self.b.get(self.i) == Some(&blr::SINGULAR) {
            self.i += 1;
            true
        } else {
            false
        };
        if self.u8()? != blr::RSE {
            return Err("for source is not blr_rse - unconverted".into());
        }
        let mut rse = self.rse_body()?;
        rse.singular = singular;
        Ok(rse)
    }

    /// The rse proper: stream count onward (the tag already consumed).
    fn rse_body(&mut self) -> Result<Rse, String> {
        let streams = self.u8()?;
        if streams != 1 {
            return Err(format!("{}-stream rse unconverted", streams));
        }
        let stream = match self.u8()? {
            blr::RELATION => {
                let name = self.counted_name()?;
                let context = self.u8()?;
                Stream::Relation { name, context }
            }
            blr::RELATION2 => {
                let name = self.counted_name()?;
                let _alias = self.counted_name()?;
                let context = self.u8()?;
                Stream::Relation { name, context }
            }
            blr::RS_STREAM => self.rs_stream()?,
            blr::RSE => {
                // a derived table: an rse standing in the stream slot
                Stream::Derived(Box::new(self.rse_body()?))
            }
            blr::WINDOW => {
                if self.u8()? != blr::RSE {
                    return Err("window source is not an rse".into());
                }
                let source = Box::new(self.rse_body()?);
                let n = self.u8()? as usize;
                let mut windows = Vec::new();
                for _ in 0..n {
                    match self.u8()? {
                        // the v3 window: ctx, partition keys + remap
                        // fids, sort, map - no frame
                        blr::PARTITION_BY => {
                            let context = self.u8()?;
                            let pn = self.u8()? as usize;
                            let mut partition = Vec::new();
                            for _ in 0..pn {
                                partition.push(self.expr()?);
                            }
                            for _ in 0..pn {
                                let _ = self.expr()?; // remap fids
                            }
                            if self.u8()? != blr::SORT {
                                return Err("window without a sort clause unconverted".into());
                            }
                            let order = self.sort_keys()?;
                            if self.u8()? != blr::MAP {
                                return Err("window without blr_map unconverted".into());
                            }
                            let map = self.win_map()?;
                            windows.push(Win {
                                context,
                                partition,
                                order,
                                map,
                                frame: None,
                            });
                        }
                        // the v4 framed window: subcoded clauses with
                        // its OWN blr_end
                        blr::WINDOW_WIN => {
                            let context = self.u8()?;
                            let mut partition = Vec::new();
                            let mut order = Vec::new();
                            let mut map = Vec::new();
                            let mut unit = 0u8;
                            let mut start: Option<FrameBound> = None;
                            let mut end: Option<FrameBound> = None;
                            loop {
                                match self.u8()? {
                                    blr::WW_PARTITION => {
                                        let pn = self.u8()? as usize;
                                        for _ in 0..pn {
                                            partition.push(self.expr()?);
                                        }
                                        for _ in 0..pn {
                                            let _ = self.expr()?;
                                        }
                                    }
                                    blr::WW_ORDER => order = self.sort_keys()?,
                                    blr::WW_MAP => map = self.win_map()?,
                                    blr::WW_EXTENT_UNIT => unit = self.u8()?,
                                    blr::WW_FRAME_BOUND => {
                                        let which = self.u8()?;
                                        let kind = self.u8()?;
                                        let b = FrameBound { kind, value: None };
                                        if which == 1 {
                                            start = Some(b);
                                        } else {
                                            end = Some(b);
                                        }
                                    }
                                    blr::WW_FRAME_VALUE => {
                                        let which = self.u8()?;
                                        let v = self.expr()?;
                                        let slot = if which == 1 { &mut start } else { &mut end };
                                        match slot {
                                            Some(b) => b.value = Some(v),
                                            None => {
                                                return Err(
                                                    "frame value before its bound".into()
                                                )
                                            }
                                        }
                                    }
                                    blr::END => break,
                                    other => {
                                        return Err(format!(
                                            "window subcode {} unconverted",
                                            other
                                        ))
                                    }
                                }
                            }
                            let start = start.ok_or("framed window without a start bound")?;
                            // a single bound implies CURRENT ROW as
                            // the second (the dsql-probed law)
                            let end = end.unwrap_or(FrameBound { kind: 2, value: None });
                            windows.push(Win {
                                context,
                                partition,
                                order,
                                map,
                                frame: Some(Frame { unit, start, end }),
                            });
                        }
                        other => {
                            return Err(format!("window verb {} unconverted", other))
                        }
                    }
                }
                if self.u8()? != blr::END {
                    return Err("window does not close with blr_end".into());
                }
                // the window consumed the rse-clause END itself: the
                // stream returns directly (no outer clauses follow a
                // window in this wrapper)
                return Ok(Rse {
                    stream: Stream::Window { source, windows },
                    boolean: None,
                    sort: Vec::new(),
                    first: None,
                    skip: None,
                    project: Vec::new(),
                    plan_indices: Vec::new(),
                    singular: false,
                });
            }
            blr::RECURSE => {
                let context = self.u8()?;
                let _secondary = self.u8()?;
                let branches = self.u8()?;
                if branches != 2 {
                    return Err("recursion with other than two branches unconverted".into());
                }
                if self.u8()? != blr::RSE {
                    return Err("recursion anchor is not an rse".into());
                }
                let anchor = Box::new(self.rse_body()?);
                if self.u8()? != blr::MAP {
                    return Err("recursion anchor without a map".into());
                }
                let anchor_map = self.map_pairs()?;
                if self.u8()? != blr::RSE {
                    return Err("recursive branch is not an rse".into());
                }
                let streams = self.u8()?;
                if streams != 0 {
                    return Err("recursive branch with streams unconverted".into());
                }
                let mut rec_boolean = None;
                loop {
                    match self.u8()? {
                        blr::BOOLEAN => rec_boolean = Some(self.boolean()?),
                        blr::END => break,
                        other => {
                            return Err(format!(
                                "recursive-branch clause {} unconverted",
                                other
                            ))
                        }
                    }
                }
                if self.u8()? != blr::MAP {
                    return Err("recursive branch without a map".into());
                }
                let rec_map = self.map_pairs()?;
                // the WRAPPER rse's end closes the recursion (the
                // outer rse's own end follows, for its caller) - the
                // recursion tower is TWO rses deep, unlike the union
                if self.u8()? != blr::END {
                    return Err("recursion does not close with blr_end".into());
                }
                return Ok(Rse {
                    stream: Stream::Recurse {
                        context,
                        anchor,
                        anchor_map,
                        rec_boolean,
                        rec_map,
                    },
                    boolean: None,
                    sort: Vec::new(),
                    first: None,
                    skip: None,
                    project: Vec::new(),
                    plan_indices: Vec::new(),
                    singular: false,
                });
            }
            blr::UNION => {
                let context = self.u8()?;
                let n = self.u8()? as usize;
                let mut branches = Vec::new();
                for _ in 0..n {
                    if self.u8()? != blr::RSE {
                        return Err("union branch is not an rse".into());
                    }
                    let rse = self.rse_body()?;
                    if self.u8()? != blr::MAP {
                        return Err("union branch without blr_map".into());
                    }
                    let cnt = self.u16()? as usize;
                    let mut map = Vec::new();
                    for _ in 0..cnt {
                        let slot = self.u16()?;
                        map.push((slot, self.expr()?));
                    }
                    branches.push((rse, map));
                }
                // no terminator of its own - the branch count bounds
                // the union; the next end belongs to the OUTER rse
                Stream::Union { context, branches }
            }
            blr::AGGREGATE => {
                let context = self.u8()?;
                if self.u8()? != blr::RSE {
                    return Err("aggregate source is not an rse".into());
                }
                let source = Box::new(self.rse_body()?);
                if self.u8()? != blr::GROUP_BY {
                    return Err("aggregate without blr_group_by".into());
                }
                let n = self.u8()? as usize;
                let mut group_by = Vec::new();
                for _ in 0..n {
                    group_by.push(self.expr()?);
                }
                if self.u8()? != blr::MAP {
                    return Err("aggregate without blr_map".into());
                }
                let n = self.u16()? as usize;
                let mut map = Vec::new();
                for _ in 0..n {
                    let slot = self.u16()?;
                    let item = match self.b.get(self.i) {
                        Some(&blr::AGG_COUNT) => {
                            self.i += 1;
                            MapItem::Agg(blr::AGG_COUNT, None)
                        }
                        Some(&v @ (blr::AGG_MAX | blr::AGG_MIN | blr::AGG_TOTAL
                            | blr::AGG_AVERAGE | blr::AGG_COUNT2)) => {
                            self.i += 1;
                            MapItem::Agg(v, Some(self.expr()?))
                        }
                        _ => MapItem::Value(self.expr()?),
                    };
                    map.push((slot, item));
                }
                Stream::Aggregate(Aggregate { context, source, group_by, map })
            }
            other => return Err(format!("stream verb {} unconverted", other)),
        };
        let mut boolean = None;
        let mut sort = Vec::new();
        let mut first = None;
        let mut skip = None;
        let mut project = Vec::new();
        let mut plan_indices = Vec::new();
        loop {
            match self.u8()? {
                blr::BOOLEAN => boolean = Some(self.boolean()?),
                blr::FIRST => first = Some(self.expr()?),
                blr::SKIP => skip = Some(self.expr()?),
                blr::PROJECT => {
                    let n = self.u8()? as usize;
                    for _ in 0..n {
                        project.push(self.expr()?);
                    }
                }
                blr::PLAN => {
                    // blr_retrieve { the stream re-emitted, then
                    // blr_sequential or blr_indices + counted names }
                    if self.u8()? != blr::RETRIEVE {
                        return Err("plan clause without blr_retrieve unconverted".into());
                    }
                    match self.u8()? {
                        blr::RELATION => {
                            let _name = self.counted_name()?;
                            let _ctx = self.u8()?;
                        }
                        blr::RELATION2 => {
                            let _name = self.counted_name()?;
                            let _alias = self.counted_name()?;
                            let _ctx = self.u8()?;
                        }
                        other => {
                            return Err(format!("plan stream verb {} unconverted", other))
                        }
                    }
                    match self.u8()? {
                        blr::SEQUENTIAL => {}
                        blr::INDICES => {
                            let n = self.u8()? as usize;
                            for _ in 0..n {
                                plan_indices.push(self.counted_name()?);
                            }
                        }
                        other => {
                            return Err(format!("plan access {} unconverted", other))
                        }
                    }
                }
                blr::SORT => {
                    let n = self.u8()? as usize;
                    for _ in 0..n {
                        let desc = match self.u8()? {
                            blr::ASCENDING => false,
                            blr::DESCENDING => true,
                            other => {
                                return Err(format!("sort direction {} unconverted", other))
                            }
                        };
                        sort.push(SortKey { expr: self.expr()?, desc });
                    }
                }
                blr::END => break,
                other => return Err(format!("rse clause {} unconverted", other)),
            }
        }
        Ok(Rse {
            stream,
            boolean,
            sort,
            first,
            skip,
            project,
            plan_indices,
            singular: false,
        })
    }

    fn stmt(&mut self) -> Result<Stmt, String> {
        match self.u8()? {
            blr::BEGIN => {
                let mut list = Vec::new();
                loop {
                    if self.b.get(self.i) == Some(&blr::END) {
                        self.i += 1;
                        break;
                    }
                    list.push(self.stmt()?);
                }
                Ok(Stmt::Begin(list))
            }
            blr::LABEL => {
                let n = self.u8()?;
                Ok(Stmt::Label(n, Box::new(self.stmt()?)))
            }
            blr::FOR => {
                let rse = self.rse_entry()?;
                Ok(Stmt::For(rse, Box::new(self.stmt()?)))
            }
            blr::SEND => {
                let msg = self.u8()?;
                Ok(Stmt::Send(msg, Box::new(self.stmt()?)))
            }
            blr::ASSIGNMENT => {
                let from = self.expr()?;
                let to = match self.u8()? {
                    blr::VARIABLE => Target::Variable(self.u16()?),
                    blr::PARAMETER => {
                        let m = self.u8()?;
                        Target::Parameter(m, self.u16()?)
                    }
                    blr::PARAMETER2 => {
                        let m = self.u8()?;
                        let v = self.u16()?;
                        let f = self.u16()?;
                        Target::Parameter2(m, v, f)
                    }
                    other => return Err(format!("assign target {} unconverted", other)),
                };
                Ok(Stmt::Assign(from, to))
            }
            blr::STALL => Ok(Stmt::Stall),
            other => Err(format!("statement verb {} unconverted", other)),
        }
    }
}

fn scaled(raw: i64, scale: i8) -> Value {
    if scale == 0 {
        Value::Int(raw)
    } else {
        Value::Scaled(raw, scale)
    }
}

/// Parse a stored procedure-BLR blob into a runnable [Request] -
/// the CMP pass of `cmp.cpp`, reduced to the slice-1 wrapper: version,
/// begin, messages, an inner begin holding declares + NULL-inits +
/// stall + the labeled body, the trailing EOF send.
pub fn parse(blr_bytes: &[u8]) -> Result<Request, String> {
    let mut p = P { b: blr_bytes, i: 0, uses_generators: false };
    if p.u8()? != blr::VERSION5 {
        return Err("not blr_version5 - unconverted".into());
    }
    if p.u8()? != blr::BEGIN {
        return Err("wrapper does not open with blr_begin".into());
    }
    let mut messages = Vec::new();
    while p.b.get(p.i) == Some(&blr::MESSAGE) {
        p.i += 1;
        let num = p.u8()?;
        let count = p.u16()?;
        let mut slots = Vec::new();
        for _ in 0..count {
            slots.push(p.msg_slot()?);
        }
        messages.push((num, slots));
    }
    // with input parameters the wrapper waits under blr_receive 0
    // before the inner begin - the EXE_start/EXE_receive handshake;
    // this synchronous executor binds message 0 up front, so the
    // receive is transparent
    if p.b.get(p.i) == Some(&blr::RECEIVE) {
        p.i += 1;
        let _msg = p.u8()?;
    }
    // the inner begin: declares + their NULL-inits (procedures
    // INTERLEAVE the two - declare, init, declare, init - the law the
    // dsql crate probed), stall, the labeled body
    if p.u8()? != blr::BEGIN {
        return Err("no inner blr_begin".into());
    }
    let mut declares = 0usize;
    let mut body = Vec::new();
    loop {
        match p.b.get(p.i) {
            Some(&blr::END) => {
                p.i += 1;
                break;
            }
            Some(&blr::DECLARE) => {
                p.i += 1;
                let var = p.u16()?;
                let _slot = p.msg_slot()?;
                declares = declares.max(var as usize + 1);
            }
            None => return Err("BLR ends inside the body".into()),
            _ => body.push(p.stmt()?),
        }
    }
    // the trailing EOF send, the outer begin's close, blr_eoc
    let mut tail = Vec::new();
    loop {
        match p.b.get(p.i) {
            Some(&blr::END) => {
                p.i += 1;
                break;
            }
            None => return Err("BLR ends without the wrapper's end".into()),
            _ => tail.push(p.stmt()?),
        }
    }
    if p.u8()? != blr::EOC {
        return Err("wrapper does not close with blr_eoc".into());
    }
    if p.i != p.b.len() {
        return Err("bytes after blr_eoc".into());
    }
    let mut all = vec![Stmt::Begin(body)];
    all.extend(tail);
    Ok(Request {
        messages,
        declares,
        body: Stmt::Begin(all),
        uses_generators: p.uses_generators,
    })
}

// -------------------------------------------------------------- execute

/// A stream binding: the rows of the opened record source and the
/// current position's decoded record, addressed by context number.
#[derive(Clone)]
struct StreamFrame {
    context: u8,
    /// the bound relation's name - blr_field resolves through it;
    /// None for an aggregate frame, whose row is SLOT-indexed and
    /// read by blr_fid
    relation: Option<String>,
    /// field-id (or map-slot) -> values of the CURRENT row
    row: Vec<Value>,
}

struct Exec<'a> {
    file: &'a [u8],
    page_size: usize,
    /// generator advances live HERE, never in the file - reads in
    /// one execution see each other's steps
    gen_overlay: std::collections::BTreeMap<i64, i64>,
    variables: Vec<Value>,
    /// per message number: the slot buffer
    msg_bufs: Vec<Vec<Value>>,
    msg_slots: Vec<Vec<MsgSlot>>,
    frames: Vec<StreamFrame>,
    /// every executed blr_send: (message number, buffer snapshot)
    sends: Vec<(u8, Vec<Value>)>,
}

/// The looper (`EXE_looper`): execute the statement tree synchronously,
/// collecting every send's message image. The EXE_start / EXE_receive
/// staging collapses - blr_stall is a no-op because nothing here yields
/// to a scheduler; the sends carry the same images they would carry
/// across the API boundary.
pub fn execute(
    file: &[u8],
    page_size: usize,
    request: &Request,
    args: &[String],
) -> Result<Vec<(u8, Vec<Value>)>, String> {
    // parse each CLI argument by its message slot's dtype, then run
    // the value-typed core (the wire server binds Values directly)
    let mut vals = Vec::with_capacity(args.len());
    if let Some((_, slots)) = request.messages.iter().find(|(n, _)| *n == 0) {
        let inputs = slots.len() / 2;
        if args.len() != inputs {
            return Err(format!(
                "procedure takes {} argument(s), got {}",
                inputs,
                args.len()
            ));
        }
        for (i, a) in args.iter().enumerate() {
            let slot = &slots[2 * i];
            vals.push(match slot.dtype {
                blr::DT_SHORT | blr::DT_LONG | blr::DT_INT64 => Value::Int(
                    a.parse::<i64>()
                        .map_err(|_| format!("argument {} is not an integer", i + 1))?,
                ),
                _ => Value::Text(a.clone()),
            });
        }
    } else if !args.is_empty() {
        return Err(format!("procedure takes no arguments, got {}", args.len()));
    }
    bind_and_execute(file, page_size, request, &vals)
}

/// [execute] with the arguments already typed - what the wire server
/// binds (its parameters arrive as [Value]s, not text).
pub fn bind_and_execute(
    file: &[u8],
    page_size: usize,
    request: &Request,
    args: &[Value],
) -> Result<Vec<(u8, Vec<Value>)>, String> {
    let mut max_msg = 0u8;
    for (n, _) in &request.messages {
        max_msg = max_msg.max(*n);
    }
    let mut msg_bufs = vec![Vec::new(); max_msg as usize + 1];
    let mut msg_slots = vec![Vec::new(); max_msg as usize + 1];
    for (n, slots) in &request.messages {
        msg_bufs[*n as usize] = vec![Value::Null; slots.len()];
        msg_slots[*n as usize] = slots.clone();
    }
    // bind message 0 - the input parameters, (value, null) pairs
    // with no EOF slot
    if let Some((_, slots)) = request.messages.iter().find(|(n, _)| *n == 0) {
        let inputs = slots.len() / 2;
        if args.len() != inputs {
            return Err(format!(
                "procedure takes {} argument(s), got {}",
                inputs,
                args.len()
            ));
        }
        for (i, v) in args.iter().enumerate() {
            let is_null = matches!(v, Value::Null);
            msg_bufs[0][2 * i] = v.clone();
            msg_bufs[0][2 * i + 1] = Value::Int(if is_null { -1 } else { 0 });
        }
    } else if !args.is_empty() {
        return Err(format!("procedure takes no arguments, got {}", args.len()));
    }
    let mut ex = Exec {
        file,
        page_size,
        gen_overlay: std::collections::BTreeMap::new(),
        variables: vec![Value::Null; request.declares],
        msg_bufs,
        msg_slots,
        frames: Vec::new(),
        sends: Vec::new(),
    };
    ex.stmt(&request.body)?;
    Ok(ex.sends)
}

impl<'a> Exec<'a> {
    fn stmt(&mut self, s: &Stmt) -> Result<(), String> {
        match s {
            Stmt::Begin(list) => {
                for s in list {
                    self.stmt(s)?;
                }
            }
            Stmt::Label(_, inner) => self.stmt(inner)?,
            Stmt::Stall => {}
            Stmt::Send(msg, filler) => {
                self.stmt(filler)?;
                let buf = self
                    .msg_bufs
                    .get(*msg as usize)
                    .ok_or("send names an undeclared message")?
                    .clone();
                self.sends.push((*msg, buf));
            }
            Stmt::Assign(from, to) => {
                let v = self.eval(from)?;
                match to {
                    Target::Variable(n) => {
                        let slot = self
                            .variables
                            .get_mut(*n as usize)
                            .ok_or("assignment to an undeclared variable")?;
                        *slot = v;
                    }
                    Target::Parameter(m, i) => {
                        let buf = self
                            .msg_bufs
                            .get_mut(*m as usize)
                            .ok_or("parameter names an undeclared message")?;
                        let slot = buf
                            .get_mut(*i as usize)
                            .ok_or("parameter slot out of range")?;
                        *slot = v;
                    }
                    Target::Parameter2(m, i, flag) => {
                        let is_null = matches!(v, Value::Null);
                        let buf = self
                            .msg_bufs
                            .get_mut(*m as usize)
                            .ok_or("parameter names an undeclared message")?;
                        *buf
                            .get_mut(*i as usize)
                            .ok_or("parameter slot out of range")? = v;
                        // the null companion: 0 = present, -1 = null
                        // (the SQLDA convention the wire carries)
                        *buf
                            .get_mut(*flag as usize)
                            .ok_or("null slot out of range")? =
                            Value::Int(if is_null { -1 } else { 0 });
                    }
                }
            }
            Stmt::For(rse, body) => {
                let bindings = self.open_rse(rse)?;
                if rse.singular && bindings.len() > 1 {
                    // the engine's sing_err: a singleton select with
                    // a second row is a runtime ERROR, not a truncation
                    return Err("multiple rows in singleton select".into());
                }
                for binding in bindings {
                    let depth = self.frames.len();
                    self.frames.extend(binding);
                    let r = self.stmt(body);
                    self.frames.truncate(depth);
                    r?;
                }
            }
        }
        Ok(())
    }

    /// Open the record source tower for an rse - the engine's own
    /// stacking: FullTableScan / NestedLoopJoin / AggregatedStream at
    /// the bottom, FilteredStream (the boolean), the DISTINCT project
    /// (sort-based unique, NULL equal to NULL), SortedStream,
    /// SkipRowsStream, FirstRowsStream. A BINDING is the set of
    /// stream frames one "row" of the source stands for - one frame
    /// for a scan, one per joined stream for a join.
    fn open_rse(&mut self, rse: &Rse) -> Result<Vec<Vec<StreamFrame>>, String> {
        let mut bindings: Vec<Vec<StreamFrame>> = match &rse.stream {
            Stream::Relation { name, context } => {
                let rows = if rse.plan_indices.is_empty() {
                    self.scan_relation(name)?
                } else {
                    // PLAN (T INDEX (...)): the BitmapTableScan -
                    // the B-tree walk yields record numbers, the
                    // records fetch by number, visibility decided on
                    // the record itself (the index only says where
                    // records MIGHT be)
                    self.scan_relation_bitmap(name, &rse.plan_indices)?
                };
                rows.into_iter()
                    .map(|row| {
                        vec![StreamFrame {
                            context: *context,
                            relation: Some(name.clone()),
                            row,
                        }]
                    })
                    .collect()
            }
            Stream::Aggregate(agg) => self
                .open_aggregate(agg)?
                .into_iter()
                .map(|row| {
                    vec![StreamFrame { context: agg.context, relation: None, row }]
                })
                .collect(),
            Stream::Join { streams, kind, on } => {
                match kind {
                    JoinKind::Inner => {
                        // NestedLoopJoin over SOURCES - each a
                        // relation or a nested join whose bindings
                        // splice in whole (chains left-nest)
                        let mut acc: Vec<Vec<StreamFrame>> = vec![Vec::new()];
                        for src in streams {
                            let side = self.open_source(src)?;
                            let mut next = Vec::new();
                            for b in &acc {
                                for sb in &side {
                                    let mut nb = b.clone();
                                    nb.extend(sb.iter().cloned());
                                    next.push(nb);
                                }
                            }
                            acc = next;
                        }
                        match on {
                            None => acc,
                            Some(b) => {
                                let mut kept = Vec::new();
                                for binding in acc {
                                    if self
                                        .with_binding(&binding, |ex| ex.bool_eval(b))?
                                        == Some(true)
                                    {
                                        kept.push(binding);
                                    }
                                }
                                kept
                            }
                        }
                    }
                    // outer joins: preserved-side bindings with no ON
                    // match emit once, the other side's frames EMPTY
                    // rows - every field of them reads NULL
                    JoinKind::Left | JoinKind::Right | JoinKind::Full => {
                        let side_a = self.open_source(&streams[0])?;
                        let side_b = self.open_source(&streams[1])?;
                        let pad_a = padding_frames(&streams[0]);
                        let pad_b = padding_frames(&streams[1]);
                        let mut out = Vec::new();
                        let mut b_matched = vec![false; side_b.len()];
                        for ba in &side_a {
                            let mut hit = false;
                            for (bi, bb) in side_b.iter().enumerate() {
                                let mut binding = ba.clone();
                                binding.extend(bb.iter().cloned());
                                let keep = match on {
                                    None => Some(true),
                                    Some(cond) => self
                                        .with_binding(&binding, |ex| ex.bool_eval(cond))?,
                                };
                                if keep == Some(true) {
                                    hit = true;
                                    b_matched[bi] = true;
                                    out.push(binding);
                                }
                            }
                            if !hit && matches!(kind, JoinKind::Left | JoinKind::Full) {
                                let mut binding = ba.clone();
                                binding.extend(pad_b.iter().cloned());
                                out.push(binding);
                            }
                        }
                        if matches!(kind, JoinKind::Right | JoinKind::Full) {
                            for (bi, bb) in side_b.iter().enumerate() {
                                if !b_matched[bi] {
                                    let mut binding = pad_a.clone();
                                    binding.extend(bb.iter().cloned());
                                    out.push(binding);
                                }
                            }
                        }
                        out
                    }
                }
            }
            Stream::Derived(inner) => self.open_rse(inner)?,
            Stream::Window { source, windows } => {
                return self.open_window(source, windows);
            }
            Stream::Recurse {
                context,
                anchor,
                anchor_map,
                rec_boolean,
                rec_map,
            } => {
                // the recursion's fixpoint: the anchor branch seeds
                // the output, then the recursive branch runs over
                // EACH produced row (bound at the recursion's own
                // context - the branch has no stream of its own) and
                // its results feed the next wave, breadth-first,
                // until a wave yields nothing
                let width = anchor_map
                    .iter()
                    .chain(rec_map.iter())
                    .map(|(sl, _)| *sl as usize + 1)
                    .max()
                    .unwrap_or(0);
                let mut out: Vec<Vec<StreamFrame>> = Vec::new();
                let mut wave: Vec<Vec<Value>> = Vec::new();
                for binding in self.open_rse(anchor)? {
                    let row = self.with_binding(&binding, |ex| {
                        let mut row = vec![Value::Null; width];
                        for (slot, e) in anchor_map {
                            row[*slot as usize] = ex.eval(e)?;
                        }
                        Ok(row)
                    })?;
                    wave.push(row);
                }
                // the engine caps recursion depth (1024 - RecursiveStream
                // in recsrc/); a runaway is an ERROR, never a hang
                let mut depth = 0usize;
                while !wave.is_empty() {
                    for row in &wave {
                        out.push(vec![StreamFrame {
                            context: *context,
                            relation: None,
                            row: row.clone(),
                        }]);
                    }
                    depth += 1;
                    if depth > 1024 {
                        return Err("too many recursion levels".into());
                    }
                    let mut next = Vec::new();
                    for row in wave {
                        let frame = vec![StreamFrame {
                            context: *context,
                            relation: None,
                            row,
                        }];
                        let keep = match rec_boolean {
                            None => Some(true),
                            Some(b) => self.with_binding(&frame, |ex| ex.bool_eval(b))?,
                        };
                        if keep != Some(true) {
                            continue;
                        }
                        let produced = self.with_binding(&frame, |ex| {
                            let mut r = vec![Value::Null; width];
                            for (slot, e) in rec_map {
                                r[*slot as usize] = ex.eval(e)?;
                            }
                            Ok(r)
                        })?;
                        next.push(produced);
                    }
                    wave = next;
                }
                out
            }
            Stream::Union { context, branches } => {
                // branches concatenate in order; each row is the
                // branch map's slot values on the union's context
                let mut out = Vec::new();
                for (rse, map) in branches {
                    let width =
                        map.iter().map(|(sl, _)| *sl as usize + 1).max().unwrap_or(0);
                    for binding in self.open_rse(rse)? {
                        let row = self.with_binding(&binding, |ex| {
                            let mut row = vec![Value::Null; width];
                            for (slot, e) in map {
                                row[*slot as usize] = ex.eval(e)?;
                            }
                            Ok(row)
                        })?;
                        out.push(vec![StreamFrame {
                            context: *context,
                            relation: None,
                            row,
                        }]);
                    }
                }
                out
            }
        };
        // FilteredStream - over an aggregate this is HAVING
        if let Some(b) = &rse.boolean {
            let mut kept = Vec::new();
            for binding in bindings {
                if self.with_binding(&binding, |ex| ex.bool_eval(b))? == Some(true) {
                    kept.push(binding);
                }
            }
            bindings = kept;
        }
        // the DISTINCT project: sort-based unique on the projected
        // values, NULL grouping with NULL (set semantics)
        if !rse.project.is_empty() {
            let mut keyed: Vec<(Vec<Value>, Vec<StreamFrame>)> = Vec::new();
            for binding in bindings {
                let keys = self.with_binding(&binding, |ex| {
                    rse.project.iter().map(|e| ex.eval(e)).collect::<Result<Vec<_>, _>>()
                })?;
                keyed.push((keys, binding));
            }
            keyed.sort_by(|(a, _), (b, _)| {
                for (x, y) in a.iter().zip(b) {
                    let o = null_aware_cmp(x, y, false);
                    if o != std::cmp::Ordering::Equal {
                        return o;
                    }
                }
                std::cmp::Ordering::Equal
            });
            keyed.dedup_by(|(a, _), (b, _)| {
                a.iter().zip(b.iter()).all(|(x, y)| group_eq(x, y))
            });
            bindings = keyed.into_iter().map(|(_, b)| b).collect();
        }
        // SortedStream
        if !rse.sort.is_empty() {
            let mut keyed: Vec<(Vec<Value>, Vec<StreamFrame>)> = Vec::new();
            for binding in bindings {
                let keys = self.with_binding(&binding, |ex| {
                    rse.sort.iter().map(|k| ex.eval(&k.expr)).collect::<Result<Vec<_>, _>>()
                })?;
                keyed.push((keys, binding));
            }
            let dirs: Vec<bool> = rse.sort.iter().map(|k| k.desc).collect();
            keyed.sort_by(|(a, _), (b, _)| {
                for (i, desc) in dirs.iter().enumerate() {
                    let o = null_aware_cmp(&a[i], &b[i], *desc);
                    if o != std::cmp::Ordering::Equal {
                        return o;
                    }
                }
                std::cmp::Ordering::Equal
            });
            bindings = keyed.into_iter().map(|(_, b)| b).collect();
        }
        // SkipRowsStream, then FirstRowsStream
        if let Some(e) = &rse.skip {
            let n = self.eval_count(e)?;
            bindings = bindings.into_iter().skip(n).collect();
        }
        if let Some(e) = &rse.first {
            let n = self.eval_count(e)?;
            bindings.truncate(n);
        }
        Ok(bindings)
    }

    /// The WindowedStream: every source row survives; each window
    /// computes its map per row - whole-partition aggregates when the
    /// window has no ORDER, running aggregates over the RANGE frame
    /// (peers included - rows with equal sort keys share the value)
    /// when it does, and ROW_NUMBER / RANK / DENSE_RANK by position.
    /// Windows process in declaration order, each sorting the row set
    /// by (partition, order) keys - the LAST window's order is the
    /// order the rows emerge in, matching the engine's
    /// sort-per-window pipeline.
    fn open_window(
        &mut self,
        source: &Rse,
        windows: &[Win],
    ) -> Result<Vec<Vec<StreamFrame>>, String> {
        struct WRow {
            binding: Vec<StreamFrame>,
            extra: Vec<StreamFrame>,
        }
        let mut rows: Vec<WRow> = self
            .open_rse(source)?
            .into_iter()
            .map(|binding| WRow { binding, extra: Vec::new() })
            .collect();
        for w in windows {
            let width = w.map.iter().map(|(sl, _)| *sl as usize + 1).max().unwrap_or(0);
            // keys per row
            let mut keyed: Vec<(Vec<Value>, Vec<Value>, usize)> = Vec::new();
            for (i, r) in rows.iter().enumerate() {
                let (pk, sk) = self.with_binding(&r.binding, |ex| {
                    let pk = w
                        .partition
                        .iter()
                        .map(|e| ex.eval(e))
                        .collect::<Result<Vec<_>, _>>()?;
                    let sk = w
                        .order
                        .iter()
                        .map(|k| ex.eval(&k.expr))
                        .collect::<Result<Vec<_>, _>>()?;
                    Ok((pk, sk))
                })?;
                keyed.push((pk, sk, i));
            }
            let dirs: Vec<bool> = w.order.iter().map(|k| k.desc).collect();
            keyed.sort_by(|(pa, sa, _), (pb, sb, _)| {
                for (x, y) in pa.iter().zip(pb) {
                    let o = null_aware_cmp(x, y, false);
                    if o != std::cmp::Ordering::Equal {
                        return o;
                    }
                }
                for (i, desc) in dirs.iter().enumerate() {
                    let o = null_aware_cmp(&sa[i], &sb[i], *desc);
                    if o != std::cmp::Ordering::Equal {
                        return o;
                    }
                }
                std::cmp::Ordering::Equal
            });
            // per-row slot values, indexed by ORIGINAL row position
            let mut slot_rows: Vec<Vec<Value>> = vec![vec![Value::Null; width]; rows.len()];
            let mut p_start = 0usize;
            while p_start < keyed.len() {
                let p_end = (p_start..keyed.len())
                    .take_while(|&j| {
                        keyed[j].0.iter().zip(&keyed[p_start].0).all(|(a, b)| group_eq(a, b))
                    })
                    .last()
                    .unwrap()
                    + 1;
                let part = &keyed[p_start..p_end];
                // the first sort key per row and its direction - what
                // RANGE value bounds do arithmetic over
                let key0: Vec<Value> = part
                    .iter()
                    .map(|(_, sk, _)| sk.first().cloned().unwrap_or(Value::Null))
                    .collect();
                let dir0_desc = w.order.first().map(|k| k.desc).unwrap_or(false);
                // peer-group bounds per row (whole partition when the
                // window has no ORDER)
                let mut peer_start = vec![0usize; part.len()];
                let mut peer_end_arr = vec![part.len(); part.len()];
                if !w.order.is_empty() {
                    let mut j = 0usize;
                    while j < part.len() {
                        let pe = (j..part.len())
                            .take_while(|&k| {
                                part[k].1.iter().zip(&part[j].1).all(|(a, b)| group_eq(a, b))
                            })
                            .last()
                            .unwrap()
                            + 1;
                        for k in j..pe {
                            peer_start[k] = j;
                            peer_end_arr[k] = pe;
                        }
                        j = pe;
                    }
                }
                for (slot, item) in &w.map {
                    match item {
                        WinItem::Value(e) => {
                            for (_, _, ri) in part {
                                let v = self
                                    .with_binding(&rows[*ri].binding.clone(), |ex| ex.eval(e))?;
                                slot_rows[*ri][*slot as usize] = v;
                            }
                        }
                        WinItem::Fn(name, args) => {
                            // arg 0 per row (the valued functions)
                            let mut vals: Vec<Value> = Vec::new();
                            if !args.is_empty() {
                                for (_, _, ri) in part {
                                    vals.push(self.with_binding(
                                        &rows[*ri].binding.clone(),
                                        |ex| ex.eval(&args[0]),
                                    )?);
                                }
                            }
                            match name.as_str() {
                                "ROW_NUMBER" | "RANK" | "DENSE_RANK" => {
                                    let mut rank = 0usize;
                                    let mut dense = 0usize;
                                    let mut j = 0usize;
                                    while j < part.len() {
                                        let peer_end = peer_end_arr[j].max(j + 1);
                                        dense += 1;
                                        for (pos, (_, _, ri)) in
                                            part[j..peer_end].iter().enumerate()
                                        {
                                            let v = match name.as_str() {
                                                "ROW_NUMBER" => (j + pos + 1) as i64,
                                                "RANK" => (rank + 1) as i64,
                                                _ => dense as i64,
                                            };
                                            slot_rows[*ri][*slot as usize] =
                                                Value::Int(v);
                                        }
                                        rank += peer_end - j;
                                        j = peer_end;
                                    }
                                }
                                // LAG/LEAD: the row offset positions
                                // ago/ahead in partition order, the
                                // third argument when it runs out
                                "LAG" | "LEAD" => {
                                    for (j, (_, _, ri)) in part.iter().enumerate() {
                                        let off = match self.with_binding(
                                            &rows[*ri].binding.clone(),
                                            |ex| ex.eval(&args[1]),
                                        )? {
                                            Value::Int(n) if n >= 0 => n as usize,
                                            _ => return Err("bad LAG/LEAD offset".into()),
                                        };
                                        let src = if name == "LAG" {
                                            j.checked_sub(off)
                                        } else {
                                            let k = j + off;
                                            (k < part.len()).then_some(k)
                                        };
                                        slot_rows[*ri][*slot as usize] = match src {
                                            Some(k) => vals[k].clone(),
                                            None => self.with_binding(
                                                &rows[*ri].binding.clone(),
                                                |ex| ex.eval(&args[2]),
                                            )?,
                                        };
                                    }
                                }
                                // FIRST/LAST/NTH_VALUE read the frame:
                                // first row, LAST OF THE CURRENT PEER
                                // GROUP (the default frame's famous
                                // trap), or the nth if the frame
                                // reaches it
                                "FIRST_VALUE" | "LAST_VALUE" | "NTH_VALUE" => {
                                    for (j, (_, _, ri)) in part.iter().enumerate() {
                                        let (fs, fe) = self.frame_span(
                                            &w.frame,
                                            !w.order.is_empty(),
                                            j,
                                            part.len(),
                                            &peer_start,
                                            &peer_end_arr,
                                            &key0,
                                            dir0_desc,
                                            &rows[*ri].binding.clone(),
                                        )?;
                                        let v = if fs >= fe {
                                            Value::Null
                                        } else {
                                            match name.as_str() {
                                                "FIRST_VALUE" => vals[fs].clone(),
                                                "LAST_VALUE" => vals[fe - 1].clone(),
                                                _ => {
                                                    let n = match self.with_binding(
                                                        &rows[*ri].binding.clone(),
                                                        |ex| ex.eval(&args[1]),
                                                    )? {
                                                        Value::Int(n) if n >= 1 => n as usize,
                                                        _ => {
                                                            return Err(
                                                                "bad NTH_VALUE index".into()
                                                            )
                                                        }
                                                    };
                                                    if fs + n <= fe {
                                                        vals[fs + n - 1].clone()
                                                    } else {
                                                        Value::Null
                                                    }
                                                }
                                            }
                                        };
                                        slot_rows[*ri][*slot as usize] = v;
                                    }
                                }
                                other => {
                                    return Err(format!(
                                        "window function {} unconverted",
                                        other
                                    ))
                                }
                            }
                        }
                        WinItem::Agg(verb, operand) => {
                            // operand values in partition order
                            let mut ops: Vec<Option<Value>> = Vec::new();
                            for (_, _, ri) in part {
                                ops.push(match operand {
                                    None => None,
                                    Some(e) => Some(self.with_binding(
                                        &rows[*ri].binding.clone(),
                                        |ex| ex.eval(e),
                                    )?),
                                });
                            }
                            for (j, (_, _, ri)) in part.iter().enumerate() {
                                let (fs, fe) = self.frame_span(
                                    &w.frame,
                                    !w.order.is_empty(),
                                    j,
                                    part.len(),
                                    &peer_start,
                                    &peer_end_arr,
                                    &key0,
                                    dir0_desc,
                                    &rows[*ri].binding.clone(),
                                )?;
                                let v = window_fold(*verb, &ops[fs..fe])?;
                                slot_rows[*ri][*slot as usize] = v;
                            }
                        }
                    }
                }
                p_start = p_end;
            }
            // attach this window's frame per row, and REORDER the row
            // set to this window's sort - the engine's pipeline order
            let order: Vec<usize> = keyed.iter().map(|(_, _, ri)| *ri).collect();
            for (ri, slots) in slot_rows.into_iter().enumerate() {
                rows[ri].extra.push(StreamFrame {
                    context: w.context,
                    relation: None,
                    row: slots,
                });
            }
            let mut reordered = Vec::with_capacity(rows.len());
            let mut taken: Vec<Option<WRow>> = rows.into_iter().map(Some).collect();
            for ri in order {
                reordered.push(taken[ri].take().expect("each row once"));
            }
            rows = reordered;
        }
        Ok(rows
            .into_iter()
            .map(|r| {
                let mut b = r.binding;
                b.extend(r.extra);
                b
            })
            .collect())
    }

    /// One row's frame as a half-open span over its partition. The
    /// default (no frame) is the whole partition without ORDER and
    /// RANGE UNBOUNDED PRECEDING..CURRENT ROW (through the peers)
    /// with it. ROWS frames offset by row position; RANGE bounds
    /// with VALUES are unconverted (the key-arithmetic form).
    #[allow(clippy::too_many_arguments)]
    fn frame_span(
        &mut self,
        frame: &Option<Frame>,
        has_order: bool,
        j: usize,
        len: usize,
        peer_start: &[usize],
        peer_end: &[usize],
        key0: &[Value],
        dir0_desc: bool,
        binding: &[StreamFrame],
    ) -> Result<(usize, usize), String> {
        let Some(f) = frame else {
            return Ok(if has_order { (0, peer_end[j]) } else { (0, len) });
        };
        let bound_value = |ex: &mut Self, b: &FrameBound| -> Result<Option<usize>, String> {
            match &b.value {
                None => Ok(None),
                Some(e) => match ex.with_binding(binding, |ex| ex.eval(e))? {
                    Value::Int(n) if n >= 0 => Ok(Some(n as usize)),
                    _ => Err("bad frame bound value".into()),
                },
            }
        };
        if f.unit == 1 {
            // ROWS: position arithmetic
            let sv = bound_value(self, &f.start)?;
            let fs = match (f.start.kind, sv) {
                (0, Some(v)) => j.saturating_sub(v),
                (0, None) => 0,
                (2, _) => j,
                (1, Some(v)) => (j + v).min(len),
                _ => return Err("frame start bound unconverted".into()),
            };
            let ev = bound_value(self, &f.end)?;
            let fe = match (f.end.kind, ev) {
                (0, Some(v)) => (j + 1).saturating_sub(v),
                (2, _) => j + 1,
                (1, Some(v)) => (j + 1 + v).min(len),
                (1, None) => len,
                _ => return Err("frame end bound unconverted".into()),
            };
            Ok((fs.min(fe), fe))
        } else {
            // RANGE: value bounds are KEY arithmetic over the single
            // sort key - the frame is the contiguous run of rows
            // whose key lies within [cur - v, cur + v] on the
            // traversal's own axis (PRECEDING subtracts along it,
            // FOLLOWING adds; DESC flips the sign). A NULL current
            // key frames its peer group alone.
            let sv = bound_value(self, &f.start)?;
            let ev = bound_value(self, &f.end)?;
            if sv.is_some() || ev.is_some() {
                let cur = &key0[j];
                if matches!(cur, Value::Null) {
                    return Ok((peer_start[j], peer_end[j]));
                }
                let cur_n =
                    int_of(cur).ok_or("RANGE value bound over a non-integer key unconverted")?;
                let sign = if dir0_desc { -1i64 } else { 1i64 };
                // key-space edge for a bound: how far along the axis
                let edge = |kind: u8, v: Option<usize>| -> Result<Option<i64>, String> {
                    Ok(match (kind, v) {
                        (0, Some(n)) => Some(cur_n - sign * n as i64),
                        (1, Some(n)) => Some(cur_n + sign * n as i64),
                        (2, _) => None, // peers
                        (0, None) => None, // unbounded start
                        (1, None) => None, // unbounded end
                        _ => return Err("frame bound unconverted".into()),
                    })
                };
                let lo = edge(f.start.kind, sv)?;
                let hi = edge(f.end.kind, ev)?;
                // frame edges on the traversal axis - NULL keys
                // never qualify (their comparisons are UNKNOWN)
                let ok_low = |k: &Value, e: i64| match int_of(k) {
                    None => false,
                    Some(n) => {
                        if dir0_desc {
                            n <= e
                        } else {
                            n >= e
                        }
                    }
                };
                let ok_high = |k: &Value, e: i64| match int_of(k) {
                    None => false,
                    Some(n) => {
                        if dir0_desc {
                            n >= e
                        } else {
                            n <= e
                        }
                    }
                };
                let fs = match (f.start.kind, lo) {
                    (2, _) => peer_start[j],
                    (0, None) => 0,
                    (_, Some(e)) => {
                        (0..len).find(|&k| ok_low(&key0[k], e)).unwrap_or(len)
                    }
                    _ => return Err("frame start bound unconverted".into()),
                };
                let fe = match (f.end.kind, hi) {
                    (2, _) => peer_end[j],
                    (1, None) => len,
                    (_, Some(e)) => (0..len)
                        .rev()
                        .find(|&k| ok_high(&key0[k], e))
                        .map(|k| k + 1)
                        .unwrap_or(0),
                    _ => return Err("frame end bound unconverted".into()),
                };
                return Ok((fs.min(fe), fe));
            }
            // value-less bounds: peer semantics
            let fs = match f.start.kind {
                0 => 0,
                2 => peer_start[j],
                _ => return Err("frame start bound unconverted".into()),
            };
            let fe = match f.end.kind {
                2 => peer_end[j],
                1 => len,
                _ => return Err("frame end bound unconverted".into()),
            };
            Ok((fs.min(fe), fe))
        }
    }

    /// One join source's bindings: a relation scans, a nested join
    /// recurses (the chain's left-nested inner node).
    fn open_source(&mut self, src: &JoinSource) -> Result<Vec<Vec<StreamFrame>>, String> {
        match src {
            JoinSource::Rel(js) => Ok(self
                .scan_relation(&js.name)?
                .into_iter()
                .map(|row| {
                    vec![StreamFrame {
                        context: js.context,
                        relation: Some(js.name.clone()),
                        row,
                    }]
                })
                .collect()),
            JoinSource::Nested(inner) => {
                let rse = Rse {
                    stream: (**inner).clone(),
                    boolean: None,
                    sort: Vec::new(),
                    first: None,
                    skip: None,
                    project: Vec::new(),
                    plan_indices: Vec::new(),
                    singular: false,
                };
                self.open_rse(&rse)
            }
        }
    }

    /// The BitmapTableScan: walk the named indexes' leaves for record
    /// numbers, then fetch the visible rows those numbers name -
    /// index pages say where records MIGHT be; visibility is decided
    /// on the record itself (VIO_get through visible_rows).
    fn scan_relation_bitmap(
        &mut self,
        name: &str,
        indices: &[String],
    ) -> Result<Vec<Vec<Value>>, String> {
        let rel = resolve_relation(self.file, self.page_size, name)
            .ok_or_else(|| format!("relation {} not found", name))?;
        let mut bitmap = std::collections::BTreeSet::new();
        for iname in indices {
            let id = self.index_id_by_name(name, iname)?;
            let leaves =
                fire_crab_ods::walk_index_leaves(self.file, self.page_size, rel, id)
                    .ok_or_else(|| format!("index {} has no tree", iname))?;
            for (_, recno) in leaves {
                bitmap.insert(recno);
            }
        }
        let formats = fire_crab_ods::relation_formats(self.file, self.page_size, rel);
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("relation has no format")?;
        let tips = TipChain::read(self.file, self.page_size)
            .ok_or("cannot read transaction inventory")?;
        Ok(visible_rows(self.file, self.page_size, rel, descs, &tips)
            .into_iter()
            .filter(|vr| bitmap.contains(&vr.recno))
            .map(|vr| vr.values)
            .collect())
    }

    /// RDB$INDICES: the named index's 0-based slot in the relation's
    /// index root (RDB$INDEX_ID is 1-based in the catalog).
    fn index_id_by_name(&self, table: &str, index: &str) -> Result<u8, String> {
        let rel = resolve_relation(self.file, self.page_size, "RDB$INDICES")
            .ok_or("no RDB$INDICES")?;
        let formats =
            fire_crab_ods::system_relation_formats(self.file, self.page_size, "RDB$INDICES")
                .ok_or("no RDB$INDICES format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("empty format")?;
        let cols = relation_columns(self.file, self.page_size, "RDB$INDICES");
        let fid = |n: &str| {
            cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize)
        };
        let name_f = fid("RDB$INDEX_NAME").ok_or("no RDB$INDEX_NAME")?;
        let relname_f = fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
        let id_f = fid("RDB$INDEX_ID").ok_or("no RDB$INDEX_ID")?;
        for dp_no in
            fire_crab_ods::relation_data_pages(self.file, self.page_size, rel)
        {
            let start = dp_no as usize * self.page_size;
            let Some(dp) = self
                .file
                .get(start..start + self.page_size)
                .and_then(fire_crab_ods::DataPage::decode)
            else {
                continue;
            };
            for r in dp.records() {
                if !r.is_primary_record() {
                    continue;
                }
                let Some(image) = fire_crab_ods::data::assembled_image(self.file, self.page_size, &r) else { continue };
                let values = fire_crab_ods::decode_record(&image, descs);
                let (Some(Value::Text(iname)), Some(Value::Text(rname))) =
                    (values.get(name_f), values.get(relname_f))
                else {
                    continue;
                };
                if iname.trim_end() == index && rname.trim_end() == table {
                    if let Some(Value::Int(id)) = values.get(id_f) {
                        return Ok((*id - 1) as u8);
                    }
                }
            }
        }
        Err(format!("index {} not found on {}", index, table))
    }

    /// RDB$GENERATORS: the named generator's id and increment.
    fn generator_by_name(&self, name: &str) -> Result<(i64, i64), String> {
        let rel = resolve_relation(self.file, self.page_size, "RDB$GENERATORS")
            .ok_or("no RDB$GENERATORS")?;
        let formats = system_relation_formats(
            self.file,
            self.page_size,
            "RDB$GENERATORS",
        )
        .ok_or("no RDB$GENERATORS format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("empty format")?;
        let cols = relation_columns(self.file, self.page_size, "RDB$GENERATORS");
        let fid = |n: &str| {
            cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize)
        };
        let name_f = fid("RDB$GENERATOR_NAME").ok_or("no name column")?;
        let id_f = fid("RDB$GENERATOR_ID").ok_or("no id column")?;
        let inc_f = fid("RDB$GENERATOR_INCREMENT");
        for dp_no in
            fire_crab_ods::relation_data_pages(self.file, self.page_size, rel)
        {
            let start = dp_no as usize * self.page_size;
            let Some(dp) = self
                .file
                .get(start..start + self.page_size)
                .and_then(DataPage::decode)
            else {
                continue;
            };
            for r in dp.records() {
                if !r.is_primary_record() {
                    continue;
                }
                let Some(image) = fire_crab_ods::data::assembled_image(self.file, self.page_size, &r) else { continue };
                let values = decode_record(&image, descs);
                let Some(Value::Text(t)) = values.get(name_f) else {
                    continue;
                };
                if t.trim_end() != name {
                    continue;
                }
                let Some(Value::Int(id)) = values.get(id_f) else {
                    continue;
                };
                let inc = match inc_f.and_then(|f| values.get(f)) {
                    Some(Value::Int(n)) => *n,
                    _ => 1,
                };
                return Ok((*id, inc));
            }
        }
        Err(format!("generator {} not found", name))
    }

    /// The committed-visibility scan of one relation.
    fn scan_relation(&mut self, name: &str) -> Result<Vec<Vec<Value>>, String> {
        let rel = resolve_relation(self.file, self.page_size, name)
            .ok_or_else(|| format!("relation {} not found", name))?;
        let formats = fire_crab_ods::relation_formats(self.file, self.page_size, rel);
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("relation has no format")?;
        let tips = TipChain::read(self.file, self.page_size)
            .ok_or("cannot read transaction inventory")?;
        Ok(visible_rows(self.file, self.page_size, rel, descs, &tips)
            .into_iter()
            .map(|vr| vr.values)
            .collect())
    }

    /// Run an evaluation with a binding's frames pushed.
    fn with_binding<T>(
        &mut self,
        binding: &[StreamFrame],
        f: impl FnOnce(&mut Self) -> Result<T, String>,
    ) -> Result<T, String> {
        let depth = self.frames.len();
        self.frames.extend(binding.iter().cloned());
        let r = f(self);
        self.frames.truncate(depth);
        r
    }

    /// A FIRST/SKIP operand: a non-negative count.
    fn eval_count(&mut self, e: &Expr) -> Result<usize, String> {
        match self.eval(e)? {
            Value::Int(n) if n >= 0 => Ok(n as usize),
            Value::Int(_) => Err("negative row limit".into()),
            _ => Err("row limit is not an integer".into()),
        }
    }

    /// The AggregatedStream: fold the inner rse's rows into groups by
    /// the group-by keys, one output row per group, slot-indexed by
    /// the map. Aggregate semantics are the engine's: COUNT of no
    /// rows is 0 but SUM/AVG/MIN/MAX of no rows are NULL; NULL
    /// operands do not contribute; integer AVG truncates (sum/count
    /// in integer division). A zero-row source with NO group keys
    /// still yields ONE row - the aggregate of the empty set.
    fn open_aggregate(&mut self, agg: &Aggregate) -> Result<Vec<Vec<Value>>, String> {
        if matches!(agg.source.stream, Stream::Aggregate(_)) {
            return Err("aggregate over an aggregate unconverted".into());
        }
        let source_bindings = self.open_rse(&agg.source)?;
        // fold state per group, keyed by the group-by values; groups
        // keep FIRST-ENCOUNTER order and sort by key below
        struct Acc {
            keys: Vec<Value>,
            slots: Vec<(u16, Fold)>,
        }
        enum Fold {
            Count(i64),
            Sum(Option<i64>),
            Avg(Option<(i64, i64)>),
            Min(Option<Value>),
            Max(Option<Value>),
            Pass(Value),
        }
        let new_acc = |keys: Vec<Value>, map: &[(u16, MapItem)]| Acc {
            keys,
            slots: map
                .iter()
                .map(|(slot, item)| {
                    let f = match item {
                        MapItem::Agg(v, _) => match *v {
                            blr::AGG_COUNT | blr::AGG_COUNT2 => Fold::Count(0),
                            blr::AGG_TOTAL => Fold::Sum(None),
                            blr::AGG_AVERAGE => Fold::Avg(None),
                            blr::AGG_MIN => Fold::Min(None),
                            blr::AGG_MAX => Fold::Max(None),
                            _ => unreachable!("parse admitted the verb"),
                        },
                        MapItem::Value(_) => Fold::Pass(Value::Null),
                    };
                    (*slot, f)
                })
                .collect(),
        };
        let mut groups: Vec<Acc> = Vec::new();
        for binding in source_bindings {
            let depth = self.frames.len();
            self.frames.extend(binding);
            let mut keys = Vec::new();
            for k in &agg.group_by {
                keys.push(self.eval(k)?);
            }
            let gi = match groups.iter().position(|g| {
                g.keys.len() == keys.len()
                    && g.keys.iter().zip(&keys).all(|(a, b)| group_eq(a, b))
            }) {
                Some(i) => i,
                None => {
                    groups.push(new_acc(keys.clone(), &agg.map));
                    groups.len() - 1
                }
            };
            for (slot_i, (_, item)) in agg.map.iter().enumerate() {
                let operand = match item {
                    MapItem::Agg(_, Some(e)) | MapItem::Value(e) => Some(self.eval(e)?),
                    MapItem::Agg(_, None) => None,
                };
                let fold = &mut groups[gi].slots[slot_i].1;
                match (fold, item, operand) {
                    (Fold::Count(n), MapItem::Agg(v, _), op) => {
                        // COUNT(*) counts rows; COUNT(x) counts
                        // non-NULL operands
                        if *v == blr::AGG_COUNT || !matches!(op, Some(Value::Null)) {
                            *n += 1;
                        }
                    }
                    (Fold::Sum(acc), _, Some(v)) => {
                        if let Some(n) = int_of(&v) {
                            *acc = Some(acc.unwrap_or(0) + n);
                        }
                    }
                    (Fold::Avg(acc), _, Some(v)) => {
                        if let Some(n) = int_of(&v) {
                            let (s, c) = acc.unwrap_or((0, 0));
                            *acc = Some((s + n, c + 1));
                        }
                    }
                    (Fold::Min(acc), _, Some(v)) => {
                        if !matches!(v, Value::Null) {
                            let take = match acc {
                                None => true,
                                Some(cur) => {
                                    value_cmp(&v, cur) == Some(std::cmp::Ordering::Less)
                                }
                            };
                            if take {
                                *acc = Some(v);
                            }
                        }
                    }
                    (Fold::Max(acc), _, Some(v)) => {
                        if !matches!(v, Value::Null) {
                            let take = match acc {
                                None => true,
                                Some(cur) => {
                                    value_cmp(&v, cur)
                                        == Some(std::cmp::Ordering::Greater)
                                }
                            };
                            if take {
                                *acc = Some(v);
                            }
                        }
                    }
                    (Fold::Pass(p), _, Some(v)) => *p = v,
                    _ => {}
                }
            }
            self.frames.truncate(depth);
        }
        // the aggregate of the EMPTY set: no group keys -> one row
        if groups.is_empty() && agg.group_by.is_empty() {
            groups.push(new_acc(Vec::new(), &agg.map));
        }
        // groups emerge in key order (the engine aggregates over
        // key-sorted input)
        groups.sort_by(|a, b| {
            for (x, y) in a.keys.iter().zip(&b.keys) {
                let o = null_aware_cmp(x, y, false);
                if o != std::cmp::Ordering::Equal {
                    return o;
                }
            }
            std::cmp::Ordering::Equal
        });
        let width = agg.map.iter().map(|(s, _)| *s as usize + 1).max().unwrap_or(0);
        let mut out = Vec::with_capacity(groups.len());
        for g in groups {
            let mut row = vec![Value::Null; width];
            for (slot, fold) in g.slots {
                row[slot as usize] = match fold {
                    Fold::Count(n) => Value::Int(n),
                    Fold::Sum(v) => v.map(Value::Int).unwrap_or(Value::Null),
                    // integer average truncates toward zero, like the
                    // engine's integer division
                    Fold::Avg(v) => v.map(|(s, c)| Value::Int(s / c)).unwrap_or(Value::Null),
                    Fold::Min(v) | Fold::Max(v) => v.unwrap_or(Value::Null),
                    Fold::Pass(v) => v,
                };
            }
            out.push(row);
        }
        Ok(out)
    }

    fn eval(&mut self, e: &Expr) -> Result<Value, String> {
        Ok(match e {
            Expr::Null => Value::Null,
            Expr::Literal(v) => v.clone(),
            Expr::Coalesce(ops) => {
                let mut out = Value::Null;
                for e in ops {
                    let v = self.eval(e)?;
                    if !matches!(v, Value::Null) {
                        out = v;
                        break;
                    }
                }
                out
            }
            Expr::GenId(name, step) => {
                let (id, increment) = self.generator_by_name(name)?;
                let step = match step {
                    Some(e) => match self.eval(e)? {
                        Value::Int(n) => n,
                        _ => return Err("GEN_ID step is not an integer".into()),
                    },
                    None => increment,
                };
                let cur = *self
                    .gen_overlay
                    .get(&id)
                    .unwrap_or(&fire_crab_ods::gen::read(self.file, self.page_size, id));
                let new = cur + step;
                self.gen_overlay.insert(id, new);
                Value::Int(new)
            }
            Expr::CaseMap(up, inner) => match self.eval(inner)? {
                Value::Null => Value::Null,
                Value::Text(t) => Value::Text(if *up {
                    t.to_uppercase()
                } else {
                    t.to_lowercase()
                }),
                _ => return Err("case mapping over a non-text value".into()),
            },
            Expr::StrLen(kind, inner) => match self.eval(inner)? {
                Value::Null => Value::Null,
                Value::Text(t) => Value::Int(match kind {
                    1 => t.chars().count() as i64,
                    2 => t.len() as i64,
                    other => {
                        return Err(format!("strlen type {} unconverted", other))
                    }
                }),
                _ => return Err("length of a non-text value".into()),
            },
            Expr::Substr(v, start, len) => {
                let (vv, sv, lv) = (self.eval(v)?, self.eval(start)?, self.eval(len)?);
                match (vv, sv, lv) {
                    (Value::Null, _, _) | (_, Value::Null, _) | (_, _, Value::Null) => {
                        Value::Null
                    }
                    (Value::Text(t), Value::Int(st), Value::Int(ln)) => {
                        // the engine's runtime rules: a negative
                        // length errors, a start past the end is empty
                        if ln < 0 {
                            return Err("negative substring length".into());
                        }
                        if st < 0 {
                            return Err("negative substring start".into());
                        }
                        let chars: Vec<char> = t.chars().collect();
                        let st = (st as usize).min(chars.len());
                        let end = (st + ln as usize).min(chars.len());
                        Value::Text(chars[st..end].iter().collect())
                    }
                    _ => return Err("substring over non-text operands".into()),
                }
            }
            Expr::Trim(wher, inner) => match self.eval(inner)? {
                Value::Null => Value::Null,
                Value::Text(t) => Value::Text(match wher {
                    1 => t.trim_start_matches(' ').to_string(),
                    2 => t.trim_end_matches(' ').to_string(),
                    _ => t.trim_matches(' ').to_string(),
                }),
                _ => return Err("trim over a non-text value".into()),
            },
            Expr::Decode(operand, conds, results) => {
                let ov = self.eval(operand)?;
                let mut hit = None;
                if !matches!(ov, Value::Null) {
                    for (i, c) in conds.iter().enumerate() {
                        if value_cmp(&ov, &self.eval(c)?)
                            == Some(std::cmp::Ordering::Equal)
                        {
                            hit = Some(i);
                            break;
                        }
                    }
                }
                match hit {
                    Some(i) => self.eval(&results[i])?,
                    None if results.len() > conds.len() => {
                        self.eval(&results[conds.len()])?
                    }
                    None => Value::Null,
                }
            }
            Expr::ValueIf(cond, then, els) => {
                // UNKNOWN takes the else branch, like the engine
                if self.bool_eval(cond)? == Some(true) {
                    self.eval(then)?
                } else {
                    self.eval(els)?
                }
            }
            Expr::Cast(slot, inner) => {
                let v = self.eval(inner)?;
                if matches!(v, Value::Null) {
                    return Ok(Value::Null);
                }
                match slot.dtype {
                    blr::DT_SHORT | blr::DT_LONG | blr::DT_INT64 => {
                        // text parses (the engine's string-to-number
                        // conversion; a bad string is its 22018)
                        let n = match &v {
                            Value::Text(t) => t
                                .trim()
                                .parse::<i64>()
                                .map_err(|_| format!("conversion error from string \"{}\"", t.trim()))?,
                            other => int_of(other)
                                .ok_or("cast to integer unconverted for this value")?,
                        };
                        let fits = match slot.dtype {
                            blr::DT_SHORT => i16::try_from(n).is_ok(),
                            blr::DT_LONG => i32::try_from(n).is_ok(),
                            _ => true,
                        };
                        if !fits {
                            return Err("integer overflow".into());
                        }
                        Value::Int(n)
                    }
                    blr::DT_TEXT | blr::DT_TEXT2 | blr::DT_VARYING
                    | blr::DT_VARYING2 => {
                        // integers render in plain decimal
                        let t = match v {
                            Value::Text(t) => t,
                            Value::Int(n) => n.to_string(),
                            _ => {
                                return Err(
                                    "cast to text unconverted for this value".into()
                                )
                            }
                        };
                        if t.trim_end_matches(' ').len() > slot.length as usize {
                            // the engine's 22001, never a silent cut
                            return Err("string right truncation".into());
                        }
                        Value::Text(t)
                    }
                    other => {
                        return Err(format!("cast target dtype {} unconverted", other))
                    }
                }
            }
            Expr::Via(rse, value, els) => {
                let bindings = self.open_rse(rse)?;
                match bindings.len() {
                    0 => self.eval(els)?,
                    1 => {
                        let b = bindings.into_iter().next().expect("len checked");
                        self.with_binding(&b, |ex| ex.eval(value))?
                    }
                    // the engine's sing_err, as everywhere singular
                    _ => return Err("multiple rows in singleton select".into()),
                }
            }
            Expr::Negate(inner) => match self.eval(inner)? {
                Value::Null => Value::Null,
                Value::Int(n) => Value::Int(-n),
                Value::Scaled(raw, sc) => Value::Scaled(-raw, sc),
                _ => return Err("negate over a non-numeric value".into()),
            },
            Expr::Arith(verb, l, r) => {
                let lv = self.eval(l)?;
                let rv = self.eval(r)?;
                if matches!(lv, Value::Null) || matches!(rv, Value::Null) {
                    return Ok(Value::Null);
                }
                if *verb == blr::CONCATENATE {
                    let text = |v: &Value| match v {
                        Value::Text(t) => Ok(t.clone()),
                        _ => Err("concatenation over a non-text value".to_string()),
                    };
                    return Ok(Value::Text(format!("{}{}", text(&lv)?, text(&rv)?)));
                }
                let (a, b) = match (int_of(&lv), int_of(&rv)) {
                    (Some(a), Some(b)) => (a, b),
                    _ => return Err("arithmetic over a non-integer value".into()),
                };
                Value::Int(match *verb {
                    blr::ADD => a.checked_add(b).ok_or("integer overflow")?,
                    blr::SUBTRACT => a.checked_sub(b).ok_or("integer overflow")?,
                    blr::MULTIPLY => a.checked_mul(b).ok_or("integer overflow")?,
                    // integer division truncates toward zero; zero
                    // divisor is the engine's runtime error
                    blr::DIVIDE => {
                        if b == 0 {
                            return Err("integer divide by zero".into());
                        }
                        a / b
                    }
                    _ => unreachable!("parse admitted the verb"),
                })
            }
            Expr::Variable(n) => self
                .variables
                .get(*n as usize)
                .ok_or("read of an undeclared variable")?
                .clone(),
            Expr::Parameter(msg, slot) => self
                .msg_bufs
                .get(*msg as usize)
                .and_then(|b| b.get(*slot as usize))
                .cloned()
                .ok_or("parameter slot out of range")?,
            Expr::Fid(ctx, slot) => {
                let frame = self
                    .frames
                    .iter()
                    .rev()
                    .find(|f| f.context == *ctx)
                    .ok_or_else(|| format!("context {} not bound", ctx))?;
                frame.row.get(*slot as usize).cloned().unwrap_or(Value::Null)
            }
            Expr::Field(ctx, name) => {
                let frame = self
                    .frames
                    .iter()
                    .rev()
                    .find(|f| f.context == *ctx)
                    .ok_or_else(|| format!("context {} not bound", ctx))?;
                // resolve the NAME through the catalog to the field id
                // - decoded rows index by field id
                let rel_name = frame
                    .relation
                    .clone()
                    .ok_or("bare field over an aggregate frame")?;
                let cols =
                    relation_columns(self.file, self.page_size, &rel_name);
                let col = cols
                    .iter()
                    .find(|c| c.name.eq_ignore_ascii_case(name))
                    .ok_or_else(|| format!("field {} unknown", name))?;
                frame
                    .row
                    .get(col.field_id as usize)
                    .cloned()
                    .unwrap_or(Value::Null)
            }
        })
    }

    fn bool_eval(&mut self, b: &Bool) -> Result<Option<bool>, String> {
        Ok(match b {
            Bool::Cmp(verb, l, r) => {
                let lv = self.eval(l)?;
                let rv = self.eval(r)?;
                match value_cmp(&lv, &rv) {
                    None => None,
                    Some(o) => Some(match *verb {
                        blr::EQL => o == std::cmp::Ordering::Equal,
                        blr::NEQ => o != std::cmp::Ordering::Equal,
                        blr::GTR => o == std::cmp::Ordering::Greater,
                        blr::GEQ => o != std::cmp::Ordering::Less,
                        blr::LSS => o == std::cmp::Ordering::Less,
                        blr::LEQ => o != std::cmp::Ordering::Greater,
                        _ => unreachable!(),
                    }),
                }
            }
            Bool::And(l, r) => {
                // Kleene AND: false dominates, unknown otherwise
                match (self.bool_eval(l)?, self.bool_eval(r)?) {
                    (Some(false), _) | (_, Some(false)) => Some(false),
                    (Some(true), Some(true)) => Some(true),
                    _ => None,
                }
            }
            Bool::Or(l, r) => match (self.bool_eval(l)?, self.bool_eval(r)?) {
                (Some(true), _) | (_, Some(true)) => Some(true),
                (Some(false), Some(false)) => Some(false),
                _ => None,
            },
            Bool::Not(inner) => self.bool_eval(inner)?.map(|v| !v),
            Bool::Missing(e) => {
                Some(matches!(self.eval(e)?, Value::Null))
            }
            Bool::InList(v, list) => {
                let lv = self.eval(v)?;
                if matches!(lv, Value::Null) {
                    return Ok(None);
                }
                let mut unknown = false;
                for item in list {
                    match value_cmp(&lv, &self.eval(item)?) {
                        Some(std::cmp::Ordering::Equal) => return Ok(Some(true)),
                        None => unknown = true,
                        _ => {}
                    }
                }
                if unknown { None } else { Some(false) }
            }
            Bool::Between(v, lo, hi) => {
                let vv = self.eval(v)?;
                let lov = self.eval(lo)?;
                let hiv = self.eval(hi)?;
                let ge = value_cmp(&vv, &lov).map(|o| o != std::cmp::Ordering::Less);
                let le = value_cmp(&vv, &hiv).map(|o| o != std::cmp::Ordering::Greater);
                match (ge, le) {
                    (Some(false), _) | (_, Some(false)) => Some(false),
                    (Some(true), Some(true)) => Some(true),
                    _ => None,
                }
            }
            Bool::Like(v, p) => {
                let (vv, pv) = (self.eval(v)?, self.eval(p)?);
                match (vv, pv) {
                    (Value::Null, _) | (_, Value::Null) => None,
                    (Value::Text(t), Value::Text(pat)) => {
                        Some(like_match(&t.chars().collect::<Vec<_>>(),
                                        &pat.chars().collect::<Vec<_>>()))
                    }
                    _ => return Err("LIKE over non-text values".into()),
                }
            }
            Bool::Starting(v, p) => {
                let (vv, pv) = (self.eval(v)?, self.eval(p)?);
                match (vv, pv) {
                    (Value::Null, _) | (_, Value::Null) => None,
                    (Value::Text(t), Value::Text(pre)) => Some(t.starts_with(&pre)),
                    _ => return Err("STARTING over non-text values".into()),
                }
            }
            Bool::Any(rse) => Some(!self.open_rse(rse)?.is_empty()),
            Bool::UniqueRse(rse) => Some(self.open_rse(rse)?.len() == 1),
            Bool::Quantified { all, rse } => {
                // the wrapper's stream is the subquery; its boolean
                // is the comparison, evaluated per subquery row -
                // ANY: true beats unknown beats false; ALL: false
                // beats unknown beats true; the empty set answers
                // false for ANY and true for ALL
                let comparison = rse.boolean.clone();
                let inner = Rse {
                    stream: rse.stream.clone(),
                    boolean: None,
                    sort: Vec::new(),
                    first: None,
                    skip: None,
                    project: Vec::new(),
                    plan_indices: Vec::new(),
                    singular: false,
                };
                let mut unknown = false;
                for binding in self.open_rse(&inner)? {
                    let v = match &comparison {
                        None => Some(true),
                        Some(c) => self.with_binding(&binding, |ex| ex.bool_eval(c))?,
                    };
                    match (all, v) {
                        (false, Some(true)) => return Ok(Some(true)),
                        (true, Some(false)) => return Ok(Some(false)),
                        (_, None) => unknown = true,
                        _ => {}
                    }
                }
                if unknown {
                    None
                } else {
                    Some(*all)
                }
            }
        })
    }
}

/// Fold a window aggregate over operand values (None = COUNT(*)'s
/// rowcount) - the same empty-set and NULL rules the grouped
/// aggregate uses.
fn window_fold(verb: u8, ops: &[Option<Value>]) -> Result<Value, String> {
    match verb {
        blr::AGG_COUNT => Ok(Value::Int(ops.len() as i64)),
        blr::AGG_COUNT2 => Ok(Value::Int(
            ops.iter()
                .filter(|o| !matches!(o, Some(Value::Null) | None))
                .count() as i64,
        )),
        blr::AGG_TOTAL | blr::AGG_AVERAGE => {
            let mut sum = 0i64;
            let mut n = 0i64;
            for o in ops {
                if let Some(v) = o {
                    if let Some(x) = int_of(v) {
                        sum += x;
                        n += 1;
                    }
                }
            }
            if n == 0 {
                Ok(Value::Null)
            } else if verb == blr::AGG_TOTAL {
                Ok(Value::Int(sum))
            } else {
                Ok(Value::Int(sum / n))
            }
        }
        blr::AGG_MIN | blr::AGG_MAX => {
            let mut acc: Option<Value> = None;
            for o in ops.iter().flatten() {
                if matches!(o, Value::Null) {
                    continue;
                }
                let take = match &acc {
                    None => true,
                    Some(cur) => {
                        let want = if verb == blr::AGG_MIN {
                            std::cmp::Ordering::Less
                        } else {
                            std::cmp::Ordering::Greater
                        };
                        value_cmp(o, cur) == Some(want)
                    }
                };
                if take {
                    acc = Some(o.clone());
                }
            }
            Ok(acc.unwrap_or(Value::Null))
        }
        other => Err(format!("window aggregate verb {} unconverted", other)),
    }
}

/// SQL LIKE, character-based with backtracking (the porting
/// playbook's own pseudocode): `%` matches any run including empty -
/// try every split point - and `_` exactly one character.
fn like_match(v: &[char], p: &[char]) -> bool {
    match p.split_first() {
        None => v.is_empty(),
        Some(('%', rest)) => {
            (0..=v.len()).any(|i| like_match(&v[i..], rest))
        }
        Some(('_', rest)) => match v.split_first() {
            Some((_, vr)) => like_match(vr, rest),
            None => false,
        },
        Some((c, rest)) => match v.split_first() {
            Some((vc, vr)) => vc == c && like_match(vr, rest),
            None => false,
        },
    }
}

/// The empty frames an outer join's unmatched side stands on - one
/// per context the side binds; every field read off them is NULL.
fn padding_frames(src: &JoinSource) -> Vec<StreamFrame> {
    match src {
        JoinSource::Rel(js) => vec![StreamFrame {
            context: js.context,
            relation: Some(js.name.clone()),
            row: Vec::new(),
        }],
        JoinSource::Nested(inner) => match &**inner {
            Stream::Join { streams, .. } => {
                streams.iter().flat_map(padding_frames).collect()
            }
            Stream::Relation { name, context } => vec![StreamFrame {
                context: *context,
                relation: Some(name.clone()),
                row: Vec::new(),
            }],
            _ => Vec::new(),
        },
    }
}

/// Group-key equality: NULL groups WITH NULL (set semantics, the
/// same rule DISTINCT and UNION use - the opposite of `= NULL`).
fn group_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        _ => value_cmp(a, b) == Some(std::cmp::Ordering::Equal),
    }
}

/// An exact-integer view of a value for SUM/AVG folding.
fn int_of(v: &Value) -> Option<i64> {
    match v {
        Value::Int(n) => Some(*n),
        _ => None,
    }
}

/// Compare two values the engine's way: exact numerics align in a wide
/// integer (never text-compare mixed shapes), text compares with
/// trailing spaces insignificant (PAD SPACE). NULL beside anything is
/// UNKNOWN (`None`).
pub fn value_cmp(a: &Value, b: &Value) -> Option<std::cmp::Ordering> {
    use Value::*;
    let num = |v: &Value| -> Option<(i128, i8)> {
        match v {
            Int(n) => Some((*n as i128, 0)),
            Scaled(raw, s) => Some((*raw as i128, *s)),
            Int128(raw, s) => Some((*raw, *s)),
            Bool(b) => Some((*b as i128, 0)),
            _ => None,
        }
    };
    match (a, b) {
        (Null, _) | (_, Null) => None,
        (Text(x), Text(y)) => {
            Some(x.trim_end_matches(' ').cmp(y.trim_end_matches(' ')))
        }
        _ => {
            let (ar, asc) = num(a)?;
            let (br, bsc) = num(b)?;
            // align to the smaller (more negative) scale
            let scale = asc.min(bsc);
            let lift = |raw: i128, s: i8| -> i128 {
                let mut v = raw;
                for _ in 0..(s - scale) {
                    v *= 10;
                }
                v
            };
            Some(lift(ar, asc).cmp(&lift(br, bsc)))
        }
    }
}

/// Sort comparison: like [value_cmp] but total - NULLs collate FIRST
/// on an ascending key and LAST on a descending one (the engine's
/// default: NULLs sort LOW), and the direction flips the order.
fn null_aware_cmp(a: &Value, b: &Value, desc: bool) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let o = match (matches!(a, Value::Null), matches!(b, Value::Null)) {
        (true, true) => Ordering::Equal,
        // NULLs sort LOW: first ascending, and the flip below puts
        // them last descending (probed - the engine's default)
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        (false, false) => value_cmp(a, b).unwrap_or(Ordering::Equal),
    };
    if desc {
        o.reverse()
    } else {
        o
    }
}

/// The catalog read: RDB$PROCEDURES' committed primary row named
/// `name`, its RDB$PROCEDURE_BLR blob.
pub fn procedure_blr(file: &[u8], page_size: usize, name: &str) -> Result<Vec<u8>, String> {
    let rel = resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES format")?;
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("empty format list")?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| {
        cols.iter()
            .find(|c| c.name == n)
            .map(|c| c.field_id as usize)
    };
    let name_f = fid("RDB$PROCEDURE_NAME").ok_or("no RDB$PROCEDURE_NAME column")?;
    let blr_f = fid("RDB$PROCEDURE_BLR").ok_or("no RDB$PROCEDURE_BLR column")?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = fire_crab_ods::data::assembled_image(file, page_size, &r) else { continue };
            let values = decode_record(&image, descs);
            let Some(Value::Text(t)) = values.get(name_f) else {
                continue;
            };
            if t.trim_end() != name {
                continue;
            }
            return match values.get(blr_f) {
                Some(Value::Blob(brel, brec)) => {
                    read_blob_content(file, page_size, *brel, *brec)
                        .ok_or_else(|| "cannot read the BLR blob".into())
                }
                _ => Err(format!("procedure {} has no BLR", name)),
            };
        }
    }
    Err(format!("procedure {} not found", name))
}


#[cfg(test)]
mod tests {
    use super::*;

    /// The P1 wrapper - the exact bytes fire-crab-dsql emits (and the
    /// engine stores) for:
    ///   CREATE PROCEDURE P1 RETURNS (R1 INTEGER) AS
    ///   BEGIN FOR SELECT ID FROM T WHERE AMT > 5 INTO :R1 DO SUSPEND; END
    const P1: &str = "050204010300080007000700020300000800012D1A00009B1100020211010743014A0154004731170003414D5415080005000000FF020117000249441A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C";

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn parses_the_dsql_wrapper() {
        let req = parse(&unhex(P1)).expect("P1 parses");
        assert_eq!(req.declares, 1);
        // message 1: R1 long + null short + EOF short
        let (num, slots) = &req.messages[0];
        assert_eq!(*num, 1);
        assert_eq!(slots.len(), 3);
        assert_eq!(slots[0].dtype, blr::DT_LONG);
        assert_eq!(slots[1].dtype, blr::DT_SHORT);
        assert_eq!(slots[2].dtype, blr::DT_SHORT);
    }

    #[test]
    fn refuses_unknown_verbs() {
        // a version byte this executor does not speak
        assert!(parse(&[4]).is_err());
        // truncated stream
        assert!(parse(&unhex(&P1[..P1.len() - 8])).is_err());
    }

    /// The aggregate wrapper - fcdsql's bytes for:
    ///   CREATE PROCEDURE Q2 RETURNS (R1 INTEGER) AS
    ///   BEGIN FOR SELECT COUNT(*) FROM T INTO :R1 DO SUSPEND; END
    const Q2: &str = "050204010300080007000700020300000800012D1A00009B1100020211010743014F0143014A015400FF4E004D0100000053FF0201180100001A00000E0102011A000029010000010001150700010019010200FFFFFFFFFF0E0102011A000029010000010001150700000019010200FFFF4C";

    #[test]
    fn parses_the_aggregate_stream() {
        let req = parse(&unhex(Q2)).expect("Q2 parses");
        fn find_agg(s: &Stmt) -> Option<&Aggregate> {
            match s {
                Stmt::Begin(list) => list.iter().find_map(find_agg),
                Stmt::Label(_, i) | Stmt::Send(_, i) => find_agg(i),
                Stmt::For(rse, body) => match &rse.stream {
                    Stream::Aggregate(a) => Some(a),
                    _ => find_agg(body),
                },
                _ => None,
            }
        }
        let agg = find_agg(&req.body).expect("an aggregate stream");
        assert_eq!(agg.context, 1);
        assert!(agg.group_by.is_empty());
        assert_eq!(agg.map.len(), 1);
        assert!(matches!(agg.map[0], (0, MapItem::Agg(v, None)) if v == blr::AGG_COUNT));
    }

    #[test]
    fn three_valued_comparison() {
        use std::cmp::Ordering::*;
        assert_eq!(value_cmp(&Value::Int(2), &Value::Int(3)), Some(Less));
        // exact numerics align in a wide integer, never as text
        assert_eq!(
            value_cmp(&Value::Scaled(250, -2), &Value::Int(3)),
            Some(Less)
        );
        assert_eq!(
            value_cmp(&Value::Scaled(300, -2), &Value::Int(3)),
            Some(Equal)
        );
        // NULL beside anything is UNKNOWN
        assert_eq!(value_cmp(&Value::Null, &Value::Int(1)), None);
        // PAD SPACE: trailing spaces are insignificant
        assert_eq!(
            value_cmp(
                &Value::Text("aa ".into()),
                &Value::Text("aa".into())
            ),
            Some(Equal)
        );
    }
}
