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
    relation_columns, resolve_relation, visible_rows, TipChain, Value,
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
    pub const VIA: u8 = 43;
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
}

// ---------------------------------------------------------------- parse

struct P<'a> {
    b: &'a [u8],
    i: usize,
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
    let mut p = P { b: blr_bytes, i: 0 };
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
    Ok(Request { messages, declares, body: Stmt::Begin(all) })
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
    // with no EOF slot; each CLI argument parses by its slot's dtype
    if let Some((_, slots)) = request.messages.iter().find(|(n, _)| *n == 0) {
        let inputs = slots.len() / 2;
        if args.len() != inputs {
            return Err(format!("procedure takes {} argument(s), got {}", inputs, args.len()));
        }
        for (i, a) in args.iter().enumerate() {
            let slot = &slots[2 * i];
            let v = match slot.dtype {
                blr::DT_SHORT | blr::DT_LONG | blr::DT_INT64 => Value::Int(
                    a.parse::<i64>().map_err(|_| format!("argument {} is not an integer", i + 1))?,
                ),
                _ => Value::Text(a.clone()),
            };
            msg_bufs[0][2 * i] = v;
            msg_bufs[0][2 * i + 1] = Value::Int(0);
        }
    }
    let mut ex = Exec {
        file,
        page_size,
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
                let Some(image) = r.image() else { continue };
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
