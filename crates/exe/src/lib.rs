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
    pub const OR: u8 = 57;
    pub const AND: u8 = 58;
    pub const NOT: u8 = 59;
    pub const MISSING: u8 = 61;
    pub const RSE: u8 = 67;
    pub const FIRST: u8 = 68;
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
    pub const SINGULAR: u8 = 127;
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

/// The stream slot of an rse: a plain relation scan, or an
/// aggregate over an inner rse.
#[derive(Clone, Debug)]
pub enum Stream {
    Relation { name: String, context: u8 },
    Aggregate(Aggregate),
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
            // the charset-carrying twins: u16 charset, then the length
            blr::DT_TEXT2 | blr::DT_VARYING2 => {
                let _charset = self.u16()?;
                MsgSlot { dtype, length: self.u16()?, scale: 0 }
            }
            other => return Err(format!("message dtype {} unconverted", other)),
        })
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
        loop {
            match self.u8()? {
                blr::BOOLEAN => boolean = Some(self.boolean()?),
                blr::FIRST => first = Some(self.expr()?),
                blr::SKIP => skip = Some(self.expr()?),
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
        Ok(Rse { stream, boolean, sort, first, skip, singular: false })
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
                let rows = self.open_rse(rse)?;
                if rse.singular && rows.len() > 1 {
                    // the engine's sing_err: a singleton select with
                    // a second row is a runtime ERROR, not a truncation
                    return Err("multiple rows in singleton select".into());
                }
                let (context, relation) = match &rse.stream {
                    Stream::Relation { name, context } => (*context, Some(name.clone())),
                    Stream::Aggregate(a) => (a.context, None),
                };
                for row in rows {
                    self.frames.push(StreamFrame {
                        context,
                        relation: relation.clone(),
                        row,
                    });
                    let r = self.stmt(body);
                    self.frames.pop();
                    r?;
                }
            }
        }
        Ok(())
    }

    /// Open the record source tower for an rse - the engine's own
    /// stacking order: FullTableScan or AggregatedStream at the
    /// bottom, FilteredStream (the boolean), SortedStream (blr_sort),
    /// SkipRowsStream, FirstRowsStream on top.
    fn open_rse(&mut self, rse: &Rse) -> Result<Vec<Vec<Value>>, String> {
        let (context, relation) = match &rse.stream {
            Stream::Relation { name, context } => (*context, Some(name.clone())),
            Stream::Aggregate(a) => (a.context, None),
        };
        let mut rows: Vec<Vec<Value>> = match &rse.stream {
            Stream::Relation { name, .. } => {
                let rel = resolve_relation(self.file, self.page_size, name)
                    .ok_or_else(|| format!("relation {} not found", name))?;
                let formats =
                    fire_crab_ods::relation_formats(self.file, self.page_size, rel);
                let (_, descs) = formats
                    .iter()
                    .max_by_key(|(n, _)| *n)
                    .ok_or("relation has no format")?;
                let tips = TipChain::read(self.file, self.page_size)
                    .ok_or("cannot read transaction inventory")?;
                visible_rows(self.file, self.page_size, rel, descs, &tips)
                    .into_iter()
                    .map(|vr| vr.values)
                    .collect()
            }
            Stream::Aggregate(agg) => self.open_aggregate(agg)?,
        };
        // FilteredStream: the boolean, three-valued, TRUE survives -
        // over an aggregate this is HAVING, reading fids
        if let Some(b) = &rse.boolean {
            let mut kept = Vec::new();
            for row in rows {
                self.frames.push(StreamFrame {
                    context,
                    relation: relation.clone(),
                    row,
                });
                let keep = self.bool_eval(b)?;
                let frame = self.frames.pop().expect("frame just pushed");
                if keep == Some(true) {
                    kept.push(frame.row);
                }
            }
            rows = kept;
        }
        // SortedStream
        if !rse.sort.is_empty() {
            let mut keyed: Vec<(Vec<Value>, Vec<Value>)> = Vec::new();
            for row in rows {
                self.frames.push(StreamFrame {
                    context,
                    relation: relation.clone(),
                    row,
                });
                let mut keys = Vec::new();
                for k in &rse.sort {
                    keys.push(self.eval(&k.expr)?);
                }
                let frame = self.frames.pop().expect("frame just pushed");
                keyed.push((keys, frame.row));
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
            rows = keyed.into_iter().map(|(_, r)| r).collect();
        }
        // SkipRowsStream, then FirstRowsStream - blr_first/blr_skip
        // are rse clauses, but the tower applies sort, skip, first
        if let Some(e) = &rse.skip {
            let n = self.eval_count(e)?;
            rows = rows.into_iter().skip(n).collect();
        }
        if let Some(e) = &rse.first {
            let n = self.eval_count(e)?;
            rows.truncate(n);
        }
        Ok(rows)
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
        let (in_ctx, in_rel) = match &agg.source.stream {
            Stream::Relation { name, context } => (*context, Some(name.clone())),
            Stream::Aggregate(_) => {
                return Err("aggregate over an aggregate unconverted".into())
            }
        };
        let source_rows = self.open_rse(&agg.source)?;
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
        for row in source_rows {
            self.frames.push(StreamFrame {
                context: in_ctx,
                relation: in_rel.clone(),
                row,
            });
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
            self.frames.pop();
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
        })
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
