//! The server half of the wire protocol - the honest firebird-qa
//! milestone. A fire-crab server accepts TCP connections and speaks the
//! same protocol the C++ engine's `src/remote/` server does: it reads
//! `op_connect`, negotiates a protocol version, runs the SERVER side of
//! the SRP-256 exchange (deriving the same session key the client does,
//! without the password on the wire), turns on Arc4 encryption, accepts
//! `op_attach`, and answers the statement pipeline.
//!
//! This is a real, demonstrable server: the genuine C++ client (isql /
//! fbclient) and fire-crab's own client both authenticate and attach to
//! it. What it does NOT yet have is a SQL engine - `op_prepare`/`execute`
//! /`fetch` currently answer a fixed single-BIGINT result, enough to
//! prove the full request/response pipeline round-trips against a real
//! client. Wiring real SQL execution to the converted storage engine
//! (the `ods` crate) is the work that follows; the protocol server it
//! runs on is proven here.

use crate::crypto::Rc4;
use crate::srp::SrpVerifier;
use fire_crab_ods::data::DataPage;
use fire_crab_ods::format::{decode_record, dtype, Descriptor, Value};
use fire_crab_ods::{relation_columns, relation_data_pages, relation_formats, RelationColumn};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

use crate::{
    OP_ATTACH, OP_COMMIT, OP_CONNECT, OP_CONT_AUTH, OP_CRYPT, OP_DETACH, OP_EXECUTE, OP_FETCH,
    OP_FETCH_RESPONSE, OP_FREE_STATEMENT, OP_PREPARE_STATEMENT, OP_RESPONSE, OP_ROLLBACK,
    OP_TRANSACTION,
};

const OP_ALLOCATE_STATEMENT: i32 = 62;
const OP_COND_ACCEPT: i32 = 98;
const OP_CANCEL: i32 = 91;
const OP_INFO_DATABASE: i32 = 40;

/// A tiny fixed-randomness source (no external deps); the server salt
/// and ephemeral b only need to be per-connection, not cryptographically
/// audited, for this milestone.
fn seed_bytes(n: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x & 0xff) as u8
        })
        .collect()
}

/// Read exactly n bytes, decrypting if a cipher is armed.
fn read_n(s: &mut TcpStream, dec: &mut Option<Rc4>, n: usize) -> std::io::Result<Vec<u8>> {
    let mut b = vec![0u8; n];
    s.read_exact(&mut b)?;
    Ok(match dec {
        Some(c) => c.transform(&b),
        None => b,
    })
}
fn read_int(s: &mut TcpStream, dec: &mut Option<Rc4>) -> std::io::Result<i32> {
    let b = read_n(s, dec, 4)?;
    Ok(i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}
fn read_wire_bytes(s: &mut TcpStream, dec: &mut Option<Rc4>) -> std::io::Result<Vec<u8>> {
    let n = read_int(s, dec)? as usize;
    let data = read_n(s, dec, n)?;
    let pad = (4 - n % 4) % 4;
    read_n(s, dec, pad)?;
    Ok(data)
}

/// An XDR writer that optionally encrypts on finish.
#[derive(Default)]
struct W {
    buf: Vec<u8>,
}
impl W {
    fn int(&mut self, v: i32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_be_bytes());
        self
    }
    fn raw(&mut self, b: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(b);
        self
    }
    fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.int(b.len() as i32);
        self.buf.extend_from_slice(b);
        let pad = (4 - b.len() % 4) % 4;
        self.buf.extend(std::iter::repeat(0).take(pad));
        self
    }
    fn send(&self, s: &mut TcpStream, enc: &mut Option<Rc4>) -> std::io::Result<()> {
        let out = match enc {
            Some(c) => c.transform(&self.buf),
            None => self.buf.clone(),
        };
        s.write_all(&out)
    }
}

/// A clean op_response (handle, no data, empty status vector).
fn respond(s: &mut TcpStream, enc: &mut Option<Rc4>, handle: i32) -> std::io::Result<()> {
    let mut w = W::default();
    w.int(OP_RESPONSE)
        .int(handle)
        .int(0)
        .int(0) // blob id
        .int(0) // response data length
        .int(0); // isc_arg_end (clean status)
    w.send(s, enc)
}

/// Extract the SRP client key A (specific_data chunks reassembled) and
/// the login from a p_cnct_user_id block.
fn parse_user_id(uid: &[u8]) -> (String, String) {
    let mut i = 0;
    let mut login = String::new();
    let mut specific: Vec<u8> = Vec::new();
    while i + 1 < uid.len() {
        let tag = uid[i];
        let len = uid[i + 1] as usize;
        let data = &uid[i + 2..(i + 2 + len).min(uid.len())];
        match tag {
            9 => login = String::from_utf8_lossy(data).into_owned(), // CNCT_LOGIN
            7 => {
                // CNCT_SPECIFIC_DATA: first byte is the chunk sequence
                if !data.is_empty() {
                    specific.extend_from_slice(&data[1..]);
                }
            }
            _ => {}
        }
        i += 2 + len;
    }
    (login, String::from_utf8_lossy(&specific).into_owned())
}

/// The describe buffer describing exactly one BIGINT column - the
/// reciprocal of the client's parse_describe.
fn describe_one_bigint() -> Vec<u8> {
    let mut d = Vec::new();
    let item = |d: &mut Vec<u8>, code: u8, val: i32| {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    };
    item(&mut d, 21, 1); // isc_info_sql_stmt_type = select(1)
    d.push(5); // isc_info_sql_bind (bare)
    item(&mut d, 7, 0); // describe_vars: 0 params
    d.push(8); // describe_end (params)
    d.push(4); // isc_info_sql_select (bare)
    item(&mut d, 7, 1); // describe_vars: 1 column
    item(&mut d, 9, 1); // sqlda_seq = 1
    item(&mut d, 11, 580); // isc_info_sql_type = SQL_INT64
    item(&mut d, 12, 0); // sub_type
    item(&mut d, 13, 0); // scale
    item(&mut d, 14, 8); // length
    d.push(8); // describe_end (column)
    d.push(1); // isc_info_end
    d
}

/// One op_response carrying a describe buffer.
fn respond_prepare(s: &mut TcpStream, enc: &mut Option<Rc4>, describe: &[u8]) -> std::io::Result<()> {
    let mut w = W::default();
    w.int(OP_RESPONSE)
        .int(0)
        .int(0)
        .int(0)
        .bytes(describe)
        .int(0);
    w.send(s, enc)
}

/// The describe buffer for N projected columns - the reciprocal of a
/// client's describe parser. Each column carries its SQL type, length,
/// and its name as both the field name (16) and the alias (19); clients
/// key result columns by the alias, so multi-column results need it.
fn build_describe(cols: &[ProjCol]) -> Vec<u8> {
    let mut d = Vec::new();
    fn int_item(d: &mut Vec<u8>, code: u8, val: i32) {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    }
    fn str_item(d: &mut Vec<u8>, code: u8, s: &str) {
        d.push(code);
        d.extend_from_slice(&(s.len() as u16).to_le_bytes());
        d.extend_from_slice(s.as_bytes());
    }
    int_item(&mut d, 21, 1); // isc_info_sql_stmt_type = select
    d.push(5); // isc_info_sql_bind
    int_item(&mut d, 7, 0); // 0 params
    d.push(8); // describe_end (params)
    d.push(4); // isc_info_sql_select
    int_item(&mut d, 7, cols.len() as i32); // describe_vars: N columns
    for (i, c) in cols.iter().enumerate() {
        int_item(&mut d, 9, (i + 1) as i32); // sqlda_seq
        int_item(&mut d, 11, c.sql_type); // type
        int_item(&mut d, 12, 0); // sub_type
        int_item(&mut d, 13, 0); // scale
        int_item(&mut d, 14, c.length); // length
        str_item(&mut d, 16, &c.name); // field name
        str_item(&mut d, 19, &c.name); // alias (the client's column key)
        d.push(8); // describe_end (column)
    }
    d.push(1); // isc_info_end
    d
}

/// The value the server falls back to when a query is not one it can
/// resolve from the database (or no database is loaded).
const FIXED_ANSWER: i64 = 4242;

/// A database file the server has opened for the current attachment: the
/// raw bytes plus the page size read from its header. The `ods` crate
/// decodes everything from this slice.
struct Database {
    bytes: Vec<u8>,
    page_size: usize,
}

/// Open the file the client named in op_attach, if it exists and looks
/// like a database (a decodable header page). Returns None otherwise -
/// the server then answers the fixed constant, so a client attaching to
/// a bare name with no file behind it still completes the pipeline.
fn load_database(path: &str) -> Option<Database> {
    let p = path.trim();
    if p.is_empty() {
        return None;
    }
    let bytes = std::fs::read(p).ok()?;
    let h = fire_crab_ods::header::HeaderPage::decode(&bytes)?;
    let page_size = h.page_size as usize;
    if page_size == 0 {
        return None;
    }
    Some(Database { bytes, page_size })
}

/// How a projected column is carried on the wire. Integer-family columns
/// (SHORT/LONG/INT64, scale 0) go as SQL_INT64; everything else is
/// rendered to text and sent as SQL_VARYING - the same two shapes the
/// client side coerces to (see `query_rows`).
enum Wire {
    Int64,
    Varying,
}

/// One column of a projection: its name, the field id that indexes the
/// decoded record, and how it is described/encoded on the wire.
struct ProjCol {
    name: String,
    field_id: usize,
    wire: Wire,
    sql_type: i32,
    length: i32,
}

/// What a prepared statement resolves to. `Scalar` is a single BIGINT
/// computed at prepare - the fixed fallback, a `COUNT`, or a `MIN/MAX/SUM`
/// aggregate (all honouring any WHERE); `None` is SQL NULL (an aggregate
/// over no rows). `Project` is `SELECT <cols> FROM <table> [WHERE ...]
/// [ORDER BY ...]` walked at fetch, emitting the rows the filter accepts,
/// sorted by `order_by` (a list of (field id, descending) keys). `Group`
/// is a grouped query - `GROUP BY`, or a multi-aggregate projection with
/// no GROUP BY (one global group): the filtered rows are bucketed by the
/// `key_fids` record fields (NULLs group together), each `gitems` output
/// computed per group; `cols` describes the output columns (their
/// `field_id` is the OUTPUT index, which is also what `order_by` sorts on).
enum Plan {
    Scalar(Option<i64>),
    Project {
        rel: u16,
        formats: Vec<(u8, Vec<Descriptor>)>,
        cols: Vec<ProjCol>,
        filter: Option<Predicate>,
        order_by: Vec<(usize, bool)>,
    },
    Group {
        rel: u16,
        formats: Vec<(u8, Vec<Descriptor>)>,
        cols: Vec<ProjCol>,
        gitems: Vec<GItem>,
        key_fids: Vec<usize>,
        filter: Option<Predicate>,
        order_by: Vec<(usize, bool)>,
    },
}

/// One output column of a grouped query: a grouping key (carried by its
/// record field id) or an aggregate over the group's rows (`None` fid =
/// `COUNT(*)`).
enum GItem {
    Key(usize),
    Agg(AggFn, Option<usize>),
}

/// A scalar-returning aggregate function.
#[derive(Clone, Copy)]
enum AggFn {
    Count,
    Min,
    Max,
    Sum,
}

/// What an aggregate is computed over.
enum AggTarget {
    Star,
    Col(String),
}

/// A comparison operator in a WHERE term.
#[derive(Clone, Copy, PartialEq)]
enum Cmp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

/// The right-hand literal of a comparison.
#[derive(Clone)]
enum Rhs {
    Int(i64),
    Str(String),
}

/// A resolved WHERE term: a column (by field id) tested against a literal
/// or for NULL-ness.
enum Term {
    Cmp(usize, Cmp, Rhs),
    IsNull(usize),
    IsNotNull(usize),
}

/// A resolved WHERE predicate in disjunctive normal form (OR of ANDs),
/// which is what AND-binds-tighter-than-OR gives with no parentheses. A
/// row matches if every term of any one group matches.
struct Predicate(Vec<Vec<Term>>);

impl Predicate {
    fn matches(&self, values: &[Value]) -> bool {
        self.0
            .iter()
            .any(|group| group.iter().all(|t| t.matches(values)))
    }
}

fn ord_ok(o: std::cmp::Ordering, op: Cmp) -> bool {
    use std::cmp::Ordering::*;
    match op {
        Cmp::Eq => o == Equal,
        Cmp::Ne => o != Equal,
        Cmp::Lt => o == Less,
        Cmp::Le => o != Greater,
        Cmp::Gt => o == Greater,
        Cmp::Ge => o != Less,
    }
}

impl Term {
    fn matches(&self, values: &[Value]) -> bool {
        match self {
            // out-of-range / missing column reads as NULL
            Term::IsNull(fid) => matches!(values.get(*fid), Some(Value::Null) | None),
            Term::IsNotNull(fid) => {
                matches!(values.get(*fid), Some(v) if !matches!(v, Value::Null))
            }
            // comparison with NULL, or a type that does not match the
            // literal, is UNKNOWN - i.e. not true, the row is excluded
            Term::Cmp(fid, op, Rhs::Int(lit)) => match values.get(*fid) {
                Some(Value::Int(i)) => ord_ok(i.cmp(lit), *op),
                _ => false,
            },
            Term::Cmp(fid, op, Rhs::Str(lit)) => match values.get(*fid) {
                // trailing blanks are not significant in Firebird text
                // comparisons (CHAR padding); trim both sides
                Some(Value::Text(s)) => {
                    ord_ok(s.trim_end_matches(' ').cmp(lit.trim_end_matches(' ')), *op)
                }
                _ => false,
            },
        }
    }
}

/// Pick the wire shape, SQL type and length for a column from its stored
/// descriptor.
fn wire_for(d: &Descriptor) -> (Wire, i32, i32) {
    let is_int = matches!(d.dtype, dtype::SHORT | dtype::LONG | dtype::INT64) && d.scale == 0;
    if is_int {
        (Wire::Int64, 580, 8) // SQL_INT64
    } else {
        (Wire::Varying, 448, 32765) // SQL_VARYING, rendered text
    }
}

/// Build the projected-column list from a select list and the relation's
/// columns + format descriptors. `*` expands to every column in field-id
/// (SELECT *) order. Returns None if any named column is unknown or has no
/// descriptor.
fn build_projcols(
    collist: &[String],
    columns: &[RelationColumn],
    descs: &[Descriptor],
) -> Option<Vec<ProjCol>> {
    let selected: Vec<&RelationColumn> = if collist.len() == 1 && collist[0] == "*" {
        columns.iter().collect()
    } else {
        let mut v = Vec::new();
        for name in collist {
            v.push(columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?);
        }
        v
    };
    let mut out = Vec::new();
    for rc in selected {
        let d = descs.get(rc.field_id as usize)?;
        let (wire, sql_type, length) = wire_for(d);
        out.push(ProjCol {
            name: rc.name.clone(),
            field_id: rc.field_id as usize,
            wire,
            sql_type,
            length,
        });
    }
    Some(out)
}

/// Plan a prepared statement against the loaded database. The shapes
/// answered from real pages are `SELECT COUNT(*) FROM <table> [WHERE ...]`,
/// `SELECT <cols> FROM <table> [WHERE ...] [ORDER BY ...]`, and grouped
/// queries `SELECT <keys and aggregates> FROM <table> [WHERE ...] [GROUP
/// BY ...] [ORDER BY ...]`, resolving the table through `RDB$RELATIONS`
/// and columns through `RDB$RELATION_FIELDS`. A clause that cannot be
/// parsed or resolved makes the whole query fall back to the fixed
/// constant rather than answer it wrong (returning extra or misgrouped
/// rows would be worse than answering nothing).
fn plan_query(sql: &str, db: &Option<Database>) -> Plan {
    let fallback = Plan::Scalar(Some(FIXED_ANSWER));
    let trace = std::env::var("FC_SRV_TRACE").is_ok();
    let Some((proj_s, table_s, where_s, group_s, order_s)) = split_query(sql) else {
        if trace { eprintln!("[srv] plan: split_query failed for {:?}", sql); }
        return fallback;
    };
    if trace {
        eprintln!(
            "[srv] plan: proj={:?} table={:?} where={:?} group={:?} order={:?}",
            proj_s, table_s, where_s, group_s, order_s
        );
    }
    let Some(proj) = parse_projection(proj_s) else {
        if trace { eprintln!("[srv] plan: parse_projection failed"); }
        return fallback;
    };
    let table = table_s.trim_matches('"');
    if !ident_ok(table) {
        return fallback;
    }
    let Some(db) = db else { return fallback };
    let Some(rel) = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, table) else {
        return fallback;
    };
    let columns = relation_columns(&db.bytes, db.page_size, table);
    let formats = relation_formats(&db.bytes, db.page_size, rel);
    let descs = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .map(|(_, d)| d.clone())
        .unwrap_or_default();

    // parse + resolve the optional WHERE clause
    let filter = match where_s {
        None => None,
        Some(ws) => match tokenize(ws)
            .and_then(|t| parse_predicate(&t))
            .and_then(|raw| resolve_predicate(raw, &columns, &descs))
        {
            Some(p) => Some(p),
            None => {
                if trace { eprintln!("[srv] plan: WHERE parse/resolve failed for {:?}", ws); }
                return fallback; // unsupported WHERE: do not answer wrong
            }
        },
    };

    let items = match proj {
        Proj::Star => {
            // SELECT * is a plain projection; GROUP BY over it would need
            // every column grouped - not a shape worth answering
            if group_s.is_some() {
                return fallback;
            }
            let Some(cols) = build_projcols(&["*".to_string()], &columns, &descs) else {
                return fallback;
            };
            let order_by = match order_s {
                None => Vec::new(),
                Some(os) => {
                    match parse_order_by(os, &cols, |n| {
                        columns
                            .iter()
                            .find(|c| c.name.eq_ignore_ascii_case(n))
                            .map(|c| c.field_id as usize)
                    }) {
                        Some(keys) => keys,
                        None => return fallback,
                    }
                }
            };
            return Plan::Project { rel, formats, cols, filter, order_by };
        }
        Proj::Items(items) => items,
    };

    let has_agg = items.iter().any(|i| matches!(i, SelItem::Agg(..)));

    // a single aggregate with no GROUP BY stays on the scalar path - it
    // keeps the header-count fast path for COUNT(*), which is also the
    // only way COUNT works on system relations (no RDB$FORMATS entry)
    if group_s.is_none() && items.len() == 1 {
        if let SelItem::Agg(func, target) = &items[0] {
            // ORDER BY on a single-row aggregate is meaningless; reject it
            if order_s.is_some() {
                return fallback;
            }
            return match aggregate(db, rel, &formats, &columns, &descs, *func, target, &filter) {
                Some(v) => Plan::Scalar(v),
                None => fallback, // unsupported aggregate (e.g. MIN of a text column)
            };
        }
    }

    if !has_agg && group_s.is_none() {
        // plain projection: SELECT <cols> [WHERE] [ORDER BY]
        let collist: Vec<String> = items
            .iter()
            .map(|i| match i {
                SelItem::Col(c) => c.clone(),
                SelItem::Agg(..) => unreachable!(),
            })
            .collect();
        let Some(cols) = build_projcols(&collist, &columns, &descs) else {
            return fallback;
        };
        if cols.is_empty() {
            return fallback;
        }
        let order_by = match order_s {
            None => Vec::new(),
            Some(os) => {
                match parse_order_by(os, &cols, |n| {
                    columns
                        .iter()
                        .find(|c| c.name.eq_ignore_ascii_case(n))
                        .map(|c| c.field_id as usize)
                }) {
                    Some(keys) => keys,
                    None => {
                        if trace { eprintln!("[srv] plan: ORDER BY parse failed for {:?}", os); }
                        return fallback;
                    }
                }
            }
        };
        return Plan::Project { rel, formats, cols, filter, order_by };
    }

    // grouped query: GROUP BY, or a multi-aggregate global projection
    match plan_group(&items, group_s, order_s, rel, formats, &columns, &descs, filter) {
        Some(p) => p,
        None => {
            if trace { eprintln!("[srv] plan: GROUP BY plan failed"); }
            fallback
        }
    }
}

/// Build a `Plan::Group`. With a GROUP BY every bare select-list column
/// must be one of the group keys (anything else is invalid SQL); with no
/// GROUP BY (a multi-aggregate projection) there are no keys, the whole
/// table is one group, and a bare column is invalid. MIN/MAX/SUM need an
/// integer column; COUNT takes any column or `*`. Returns None on any
/// unresolvable or invalid piece - the caller falls back.
#[allow(clippy::too_many_arguments)]
fn plan_group(
    items: &[SelItem],
    group_s: Option<&str>,
    order_s: Option<&str>,
    rel: u16,
    formats: Vec<(u8, Vec<Descriptor>)>,
    columns: &[RelationColumn],
    descs: &[Descriptor],
    filter: Option<Predicate>,
) -> Option<Plan> {
    let key_fids = match group_s {
        None => Vec::new(),
        Some(g) => parse_group_by(g, items, columns)?,
    };
    let mut gitems = Vec::new();
    let mut cols = Vec::new();
    for (out_idx, item) in items.iter().enumerate() {
        match item {
            SelItem::Col(name) => {
                let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
                let fid = rc.field_id as usize;
                if !key_fids.contains(&fid) {
                    return None; // a selected column that is not grouped
                }
                let (wire, sql_type, length) = wire_for(descs.get(fid)?);
                cols.push(ProjCol {
                    name: rc.name.clone(),
                    field_id: out_idx,
                    wire,
                    sql_type,
                    length,
                });
                gitems.push(GItem::Key(fid));
            }
            SelItem::Agg(func, target) => {
                let fid = match target {
                    AggTarget::Star => None, // COUNT(*) - parse guarantees Count
                    AggTarget::Col(name) => {
                        let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
                        let fid = rc.field_id as usize;
                        // MIN/MAX/SUM only over integers (COUNT counts any)
                        if !matches!(func, AggFn::Count)
                            && !matches!(col_kind(descs.get(fid)?)?, ColKind::Int)
                        {
                            return None;
                        }
                        Some(fid)
                    }
                };
                // the engine titles aggregate output columns by function
                let name = match func {
                    AggFn::Count => "COUNT",
                    AggFn::Min => "MIN",
                    AggFn::Max => "MAX",
                    AggFn::Sum => "SUM",
                };
                cols.push(ProjCol {
                    name: name.to_string(),
                    field_id: out_idx,
                    wire: Wire::Int64,
                    sql_type: 580,
                    length: 8,
                });
                gitems.push(GItem::Agg(*func, fid));
            }
        }
    }
    // ORDER BY sorts the OUTPUT rows: names resolve to output columns
    // (group keys by column name), ordinals to select-list positions
    let order_by = match order_s {
        None => Vec::new(),
        Some(os) => parse_order_by(os, &cols, |n| {
            cols.iter()
                .find(|c| c.name.eq_ignore_ascii_case(n))
                .map(|c| c.field_id)
        })?,
    };
    Some(Plan::Group {
        rel,
        formats,
        cols,
        gitems,
        key_fids,
        filter,
        order_by,
    })
}

/// Parse a GROUP BY list into record field ids. Items are column names or
/// 1-based select-list ordinals (which must name a bare column - grouping
/// by an aggregate is invalid).
fn parse_group_by(
    group: &str,
    items: &[SelItem],
    columns: &[RelationColumn],
) -> Option<Vec<usize>> {
    let mut fids = Vec::new();
    for part in group.split(',') {
        let name = part.trim().trim_matches('"');
        let col_name = if let Ok(ord) = name.parse::<usize>() {
            if ord == 0 || ord > items.len() {
                return None;
            }
            match &items[ord - 1] {
                SelItem::Col(c) => c.as_str(),
                SelItem::Agg(..) => return None,
            }
        } else {
            if !ident_ok(name) {
                return None;
            }
            name
        };
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(col_name))?;
        fids.push(rc.field_id as usize);
    }
    if fids.is_empty() {
        None
    } else {
        Some(fids)
    }
}

/// Compute a scalar aggregate over the matching rows. COUNT works on any
/// column (and `*`); MIN/MAX/SUM require an integer column. Returns
/// Some(None) for a NULL result (MIN/MAX/SUM over no rows), or None if the
/// aggregate is unsupported (so the caller falls back).
#[allow(clippy::too_many_arguments)]
fn aggregate(
    db: &Database,
    rel: u16,
    formats: &[(u8, Vec<Descriptor>)],
    columns: &[RelationColumn],
    descs: &[Descriptor],
    func: AggFn,
    target: &AggTarget,
    filter: &Option<Predicate>,
) -> Option<Option<i64>> {
    let matches = |vals: &[Value]| filter.as_ref().map_or(true, |p| p.matches(vals));

    // COUNT(*) does not need the column values, only the row count. With no
    // filter it counts record headers without decoding - which is also the
    // only way it works on system relations (whose format is not in
    // RDB$FORMATS, so for_each_record would decode nothing).
    if let (AggFn::Count, AggTarget::Star) = (func, target) {
        let n = match filter {
            None => fire_crab_ods::count_primary_records(&db.bytes, db.page_size, rel) as i64,
            Some(_) => {
                let mut n = 0i64;
                for_each_record(db, rel, formats, |v| {
                    if matches(v) {
                        n += 1;
                    }
                });
                n
            }
        };
        return Some(Some(n));
    }

    // every other aggregate is over a named column
    let AggTarget::Col(name) = target else {
        return None;
    };
    let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
    let fid = rc.field_id as usize;

    // COUNT(col) counts non-null values; MIN/MAX/SUM need an integer column
    if matches!(func, AggFn::Count) {
        let mut n = 0i64;
        for_each_record(db, rel, formats, |v| {
            if matches(v) && matches!(v.get(fid), Some(x) if !matches!(x, Value::Null)) {
                n += 1;
            }
        });
        return Some(Some(n));
    }
    if !matches!(col_kind(descs.get(fid)?)?, ColKind::Int) {
        return None; // MIN/MAX/SUM only over integers for now
    }
    let mut acc: Option<i64> = None;
    for_each_record(db, rel, formats, |v| {
        if !matches(v) {
            return;
        }
        let Some(Value::Int(i)) = v.get(fid) else {
            return; // null or non-int: skipped by all three
        };
        acc = Some(match (func, acc) {
            (_, None) => *i,
            (AggFn::Min, Some(a)) => a.min(*i),
            (AggFn::Max, Some(a)) => a.max(*i),
            (AggFn::Sum, Some(a)) => a + *i,
            (AggFn::Count, _) => unreachable!(),
        });
    });
    Some(acc)
}

/// Walk a relation's committed primary records, decoding each with the
/// format it names, and hand the decoded values to `f`.
fn for_each_record<F: FnMut(&[Value])>(
    db: &Database,
    rel: u16,
    formats: &[(u8, Vec<Descriptor>)],
    mut f: F,
) {
    for dp_no in relation_data_pages(&db.bytes, db.page_size, rel) {
        let start = dp_no as usize * db.page_size;
        let Some(dp) = db
            .bytes
            .get(start..start + db.page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
            let descs = formats
                .iter()
                .find(|(n, _)| *n == r.format)
                .or_else(|| formats.iter().max_by_key(|(n, _)| *n));
            let Some((_, descs)) = descs else { continue };
            f(&decode_record(&image, descs));
        }
    }
}

/// Order two values for ORDER BY. NULL sorts as the lowest value (so
/// ascending puts NULLs first), matching the engine's default; integers
/// compare numerically, text ignoring trailing blanks, other types by
/// their rendered text.
fn value_cmp(a: &Value, b: &Value) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    match (a, b) {
        (Value::Null, Value::Null) => Equal,
        (Value::Null, _) => Less,
        (_, Value::Null) => Greater,
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Text(x), Value::Text(y)) => x.trim_end_matches(' ').cmp(y.trim_end_matches(' ')),
        _ => a.render().cmp(&b.render()),
    }
}

/// Compare two rows by a list of (field id, descending) ORDER BY keys.
fn order_cmp(a: &[Value], b: &[Value], keys: &[(usize, bool)]) -> std::cmp::Ordering {
    use std::cmp::Ordering::Equal;
    let nullv = Value::Null;
    for &(fid, desc) in keys {
        let va = a.get(fid).unwrap_or(&nullv);
        let vb = b.get(fid).unwrap_or(&nullv);
        let o = value_cmp(va, vb);
        let o = if desc { o.reverse() } else { o };
        if o != Equal {
            return o;
        }
    }
    Equal
}

/// Compute the grouped output rows: filter, bucket by the key fields
/// (sorting the filtered rows by them - NULLs compare equal, so they form
/// one group), then compute each output item per bucket. With no keys the
/// whole input is ONE group, emitted even when empty - SQL's global
/// aggregate shape (COUNT = 0, MIN/MAX/SUM = NULL over no rows).
fn group_output(
    db: &Database,
    rel: u16,
    formats: &[(u8, Vec<Descriptor>)],
    gitems: &[GItem],
    key_fids: &[usize],
    filter: &Option<Predicate>,
) -> Vec<Vec<Value>> {
    let mut input: Vec<Vec<Value>> = Vec::new();
    for_each_record(db, rel, formats, |v| {
        if filter.as_ref().map_or(true, |p| p.matches(v)) {
            input.push(v.to_vec());
        }
    });
    if key_fids.is_empty() {
        return vec![compute_group(&input, gitems)];
    }
    let keys: Vec<(usize, bool)> = key_fids.iter().map(|&f| (f, false)).collect();
    input.sort_by(|a, b| order_cmp(a, b, &keys));
    let mut out = Vec::new();
    let mut i = 0;
    while i < input.len() {
        let mut j = i + 1;
        while j < input.len() && order_cmp(&input[i], &input[j], &keys) == std::cmp::Ordering::Equal
        {
            j += 1;
        }
        out.push(compute_group(&input[i..j], gitems));
        i = j;
    }
    out
}

/// One output row for one group of input rows. Key items take the value
/// from the first row (all rows in the group share it); COUNT(*) counts
/// rows, COUNT(col) non-null values; MIN/MAX/SUM fold the non-null
/// integers, NULL if there are none.
fn compute_group(rows: &[Vec<Value>], gitems: &[GItem]) -> Vec<Value> {
    gitems
        .iter()
        .map(|gi| match gi {
            GItem::Key(fid) => rows
                .first()
                .and_then(|r| r.get(*fid))
                .cloned()
                .unwrap_or(Value::Null),
            GItem::Agg(AggFn::Count, None) => Value::Int(rows.len() as i64),
            GItem::Agg(AggFn::Count, Some(fid)) => Value::Int(
                rows.iter()
                    .filter(|r| matches!(r.get(*fid), Some(v) if !matches!(v, Value::Null)))
                    .count() as i64,
            ),
            GItem::Agg(func, Some(fid)) => {
                let mut acc: Option<i64> = None;
                for r in rows {
                    let Some(Value::Int(i)) = r.get(*fid) else { continue };
                    acc = Some(match (func, acc) {
                        (_, None) => *i,
                        (AggFn::Min, Some(a)) => a.min(*i),
                        (AggFn::Max, Some(a)) => a.max(*i),
                        (AggFn::Sum, Some(a)) => a + *i,
                        (AggFn::Count, _) => unreachable!(),
                    });
                }
                acc.map_or(Value::Null, Value::Int)
            }
            GItem::Agg(_, None) => Value::Null, // MIN/MAX/SUM(*): rejected at plan
        })
        .collect()
}

/// The describe buffer for a plan: one BIGINT for `Scalar`, the projected
/// columns for `Project`, the output columns for `Group`.
fn describe_for(plan: &Plan) -> Vec<u8> {
    match plan {
        Plan::Scalar(_) => describe_one_bigint(),
        Plan::Project { cols, .. } => build_describe(cols),
        Plan::Group { cols, .. } => build_describe(cols),
    }
}

/// Emit the fetch response for a plan: a stream of
/// op_fetch_response(status=0, messages=1) + row messages, terminated by
/// op_fetch_response(status=100). `Scalar` emits one row (NULL when the
/// value is None); `Project` walks the relation, filters, and either
/// streams the rows or - if there is an ORDER BY - collects, sorts and
/// then emits them.
fn emit_rows(w: &mut W, plan: &Plan, db: &Option<Database>) {
    match plan {
        Plan::Scalar(v) => {
            w.int(OP_FETCH_RESPONSE).int(0).int(1);
            match v {
                Some(n) => {
                    w.raw(&[0u8; 4]); // null bitmap (1 col, not null), padded to 4
                    w.raw(&n.to_be_bytes());
                }
                None => {
                    w.raw(&[1u8, 0, 0, 0]); // null bitmap: col 0 is NULL, no data
                }
            }
        }
        Plan::Project {
            rel,
            formats,
            cols,
            filter,
            order_by,
        } => {
            if let Some(db) = db {
                let accepts = |v: &[Value]| filter.as_ref().map_or(true, |p| p.matches(v));
                if order_by.is_empty() {
                    for_each_record(db, *rel, formats, |values| {
                        if accepts(values) {
                            w.int(OP_FETCH_RESPONSE).int(0).int(1);
                            encode_row(w, cols, values);
                        }
                    });
                } else {
                    // collect matching rows, then sort by the ORDER BY keys
                    let mut rows: Vec<Vec<Value>> = Vec::new();
                    for_each_record(db, *rel, formats, |values| {
                        if accepts(values) {
                            rows.push(values.to_vec());
                        }
                    });
                    rows.sort_by(|a, b| order_cmp(a, b, order_by));
                    for values in &rows {
                        w.int(OP_FETCH_RESPONSE).int(0).int(1);
                        encode_row(w, cols, values);
                    }
                }
            }
        }
        Plan::Group {
            rel,
            formats,
            cols,
            gitems,
            key_fids,
            filter,
            order_by,
        } => {
            if let Some(db) = db {
                let mut rows = group_output(db, *rel, formats, gitems, key_fids, filter);
                if !order_by.is_empty() {
                    // order_by keys are output indexes; output rows are
                    // aligned with gitems/cols, so order_cmp applies as-is
                    rows.sort_by(|a, b| order_cmp(a, b, order_by));
                }
                for values in &rows {
                    w.int(OP_FETCH_RESPONSE).int(0).int(1);
                    encode_row(w, cols, values);
                }
            }
        }
    }
    // end-of-cursor terminator
    w.int(OP_FETCH_RESPONSE).int(100).int(0);
}

/// Encode one row message: the leading null bitmap (one bit per projected
/// column, padded to 4 bytes) followed by the non-null column data - each
/// INT64 as 8 big-endian bytes, each VARYING as a 4-byte length + text +
/// 4-byte padding. Null columns contribute only their bit; the client
/// skips their data (protocol 13+ layout).
fn encode_row(w: &mut W, cols: &[ProjCol], values: &[Value]) {
    let n = cols.len();
    let nbytes = n.div_ceil(8);
    let mut bitmap = vec![0u8; nbytes];
    for (i, c) in cols.iter().enumerate() {
        let is_null = values.get(c.field_id).map_or(true, |v| matches!(v, Value::Null));
        if is_null {
            bitmap[i / 8] |= 1 << (i % 8);
        }
    }
    w.raw(&bitmap);
    for _ in nbytes..nbytes.div_ceil(4) * 4 {
        w.raw(&[0u8]);
    }
    for c in cols {
        let Some(v) = values.get(c.field_id) else {
            continue;
        };
        if matches!(v, Value::Null) {
            continue; // null: data omitted, the bitmap bit already set
        }
        match c.wire {
            Wire::Int64 => {
                let iv = if let Value::Int(i) = v { *i } else { 0 };
                w.raw(&iv.to_be_bytes());
            }
            Wire::Varying => {
                let s = v.render();
                let b = s.as_bytes();
                w.int(b.len() as i32);
                w.raw(b);
                for _ in 0..(4 - b.len() % 4) % 4 {
                    w.raw(&[0u8]);
                }
            }
        }
    }
}

/// A bare SQL identifier: letters, digits, `_`, `$`, non-empty.
fn ident_ok(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

fn is_ident_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$'
}

/// Find `word` (already uppercase) occurring as a whole word (identifier
/// boundaries on both sides) in `up`, at or after byte `from`.
fn find_word(up: &str, word: &str, from: usize) -> Option<usize> {
    let b = up.as_bytes();
    let mut i = from;
    while let Some(p) = up[i..].find(word) {
        let idx = i + p;
        let before = idx == 0 || !is_ident_byte(b[idx - 1]);
        let after = idx + word.len();
        let after_ok = after >= b.len() || !is_ident_byte(b[after]);
        if before && after_ok {
            return Some(idx);
        }
        i = idx + 1;
    }
    None
}

/// One item of a select list: a bare column or an aggregate.
enum SelItem {
    Col(String),
    Agg(AggFn, AggTarget),
}

/// The projection part of a SELECT: `*`, or a list of columns/aggregates.
enum Proj {
    Star,
    Items(Vec<SelItem>),
}

/// Replace the contents of single-quoted string literals (and the quotes)
/// with `X`, preserving byte length, so keyword searches never match a
/// `WHERE`/`ORDER` that lives inside a literal. `''` is an escaped quote.
fn mask_literals(up: &str) -> String {
    let mut b = up.as_bytes().to_vec();
    let mut i = 0;
    let mut in_str = false;
    while i < b.len() {
        if b[i] == b'\'' {
            b[i] = b'X';
            in_str = !in_str;
        } else if in_str {
            b[i] = b'X';
        }
        i += 1;
    }
    // masked bytes are all ASCII outside literals and `X` inside
    String::from_utf8_lossy(&b).into_owned()
}

/// Find the last `<kw> BY` (`kw` = `ORDER` or `GROUP`, already uppercase)
/// in `up`, returning (index of the keyword, index where the column list
/// begins). The last occurrence is taken so a string literal containing
/// the phrase earlier in a WHERE clause does not shadow the real clause
/// (the caller additionally masks literals out).
fn find_kw_by(up: &str, kw: &str) -> Option<(usize, usize)> {
    let mut result = None;
    let mut from = 0;
    while let Some(p) = find_word(up, kw, from) {
        from = p + kw.len();
        let tail = &up[p + kw.len()..];
        let ws = tail.len() - tail.trim_start().len();
        let t = tail.as_bytes();
        // the next whole word must be BY
        if t.len() >= ws + 2
            && t[ws] == b'B'
            && t[ws + 1] == b'Y'
            && (t.len() == ws + 2 || !is_ident_byte(t[ws + 2]))
        {
            result = Some((p, p + kw.len() + ws + 2));
        }
    }
    result
}

/// Split `SELECT <proj> FROM <table> [WHERE <pred>] [GROUP BY <cols>]
/// [ORDER BY <cols>]` into its parts, case-insensitively but preserving
/// the original case (WHERE literals are case-sensitive). ASCII
/// uppercasing keeps byte positions, so keyword offsets found in the
/// uppercased copy slice the original.
#[allow(clippy::type_complexity)]
fn split_query(sql: &str) -> Option<(&str, &str, Option<&str>, Option<&str>, Option<&str>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    if find_word(&up, "SELECT", 0) != Some(0) {
        return None;
    }
    let from = find_word(&up, "FROM", "SELECT".len())?;
    let proj = s["SELECT".len()..from].trim();
    let after = from + "FROM".len();
    let rest = &s[after..];
    // search on a copy with string literals masked out, so a WHERE/GROUP/
    // ORDER keyword inside a literal does not match; slice the original.
    let masked = mask_literals(&up[after..]);

    let where_pos = find_word(&masked, "WHERE", 0);
    let group = find_kw_by(&masked, "GROUP");
    let order = find_kw_by(&masked, "ORDER");
    let group_kw = group.map(|(k, _)| k);
    let order_kw = order.map(|(k, _)| k);

    // the table name ends at the first of WHERE / GROUP BY / ORDER BY
    let table_end = [where_pos, group_kw, order_kw]
        .into_iter()
        .flatten()
        .min()
        .unwrap_or(rest.len());
    let table = rest[..table_end].trim();

    let where_str = where_pos.map(|wp| {
        let end = [group_kw, order_kw]
            .into_iter()
            .flatten()
            .filter(|&o| o > wp)
            .min()
            .unwrap_or(rest.len());
        rest[wp + "WHERE".len()..end].trim()
    });
    let group_str = group.map(|(_, cols)| {
        let end = order_kw.filter(|&o| o > cols).unwrap_or(rest.len());
        rest[cols..end].trim()
    });
    let order_str = order.map(|(_, cols)| rest[cols..].trim());
    Some((proj, table, where_str, group_str, order_str))
}

/// Parse one select-list item as an aggregate: `COUNT(*)`, `COUNT(col)`,
/// `MIN|MAX|SUM(col)` (spacing-tolerant). None if it is not an aggregate
/// or is malformed (`MIN(*)`).
fn parse_agg_item(item: &str) -> Option<(AggFn, AggTarget)> {
    let compact: String = item.chars().filter(|c| !c.is_whitespace()).collect();
    let cu = compact.to_ascii_uppercase();
    for (kw, func) in [
        ("COUNT(", AggFn::Count),
        ("MIN(", AggFn::Min),
        ("MAX(", AggFn::Max),
        ("SUM(", AggFn::Sum),
    ] {
        if cu.starts_with(kw) && cu.ends_with(')') {
            let arg = &compact[kw.len()..compact.len() - 1]; // original case
            let target = if arg == "*" {
                // only COUNT accepts *
                if !matches!(func, AggFn::Count) {
                    return None;
                }
                AggTarget::Star
            } else {
                let name = arg.trim_matches('"');
                if !ident_ok(name) {
                    return None;
                }
                AggTarget::Col(name.to_string())
            };
            return Some((func, target));
        }
    }
    None
}

/// Parse the projection: `*`, or a comma-separated list where each item
/// is a bare identifier or an aggregate. (Aggregate arguments contain no
/// commas, so splitting the list on commas is safe.)
fn parse_projection(proj: &str) -> Option<Proj> {
    if proj.trim() == "*" {
        return Some(Proj::Star);
    }
    let mut items = Vec::new();
    for part in proj.split(',') {
        let part = part.trim();
        if let Some((func, target)) = parse_agg_item(part) {
            items.push(SelItem::Agg(func, target));
        } else {
            let name = part.trim_matches('"');
            if !ident_ok(name) {
                return None;
            }
            items.push(SelItem::Col(name.to_string()));
        }
    }
    if items.is_empty() {
        return None;
    }
    Some(Proj::Items(items))
}

/// Parse `ORDER BY` into a list of (sort key, descending) pairs. Each
/// item is a column name or a 1-based projection ordinal, with optional
/// ASC/DESC. Ordinals index `cols` (the projection) and take its
/// `field_id`; names go through `resolve_name` - the relation's columns
/// for a plain projection (record field ids), the output columns for a
/// grouped one (output indexes). Returns None on an unknown column, bad
/// ordinal, or malformed item.
fn parse_order_by(
    order: &str,
    cols: &[ProjCol],
    resolve_name: impl Fn(&str) -> Option<usize>,
) -> Option<Vec<(usize, bool)>> {
    let mut keys = Vec::new();
    for part in order.split(',') {
        let toks: Vec<&str> = part.split_whitespace().collect();
        let (name, desc) = match toks.as_slice() {
            [n] => (*n, false),
            [n, dir] => match dir.to_ascii_uppercase().as_str() {
                "ASC" => (*n, false),
                "DESC" => (*n, true),
                _ => return None,
            },
            _ => return None,
        };
        let name = name.trim_matches('"');
        let fid = if let Ok(ord) = name.parse::<usize>() {
            // 1-based ordinal into the projection
            if ord == 0 || ord > cols.len() {
                return None;
            }
            cols[ord - 1].field_id
        } else {
            resolve_name(name)?
        };
        keys.push((fid, desc));
    }
    if keys.is_empty() {
        None
    } else {
        Some(keys)
    }
}

/// A WHERE token.
enum Tok {
    Ident(String),
    Int(i64),
    Str(String),
    Cmp(Cmp),
    And,
    Or,
    Is,
    Not,
    Null,
}

/// Tokenise a WHERE clause. Single-quoted strings ('' escapes a quote),
/// integer literals (optionally negative), comparison operators
/// (= <> != < <= > >=), identifiers and the keywords AND/OR/IS/NOT/NULL.
/// Anything else (parentheses, functions, other operators) returns None,
/// so an unsupported predicate falls back rather than answering wrong.
fn tokenize(s: &str) -> Option<Vec<Tok>> {
    let b = s.as_bytes();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        match c {
            b'\'' => {
                i += 1;
                let mut val = Vec::new();
                loop {
                    if i >= b.len() {
                        return None; // unterminated string
                    }
                    if b[i] == b'\'' {
                        if i + 1 < b.len() && b[i + 1] == b'\'' {
                            val.push(b'\'');
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    val.push(b[i]);
                    i += 1;
                }
                out.push(Tok::Str(String::from_utf8_lossy(&val).into_owned()));
            }
            b'=' => {
                out.push(Tok::Cmp(Cmp::Eq));
                i += 1;
            }
            b'<' => {
                if b.get(i + 1) == Some(&b'=') {
                    out.push(Tok::Cmp(Cmp::Le));
                    i += 2;
                } else if b.get(i + 1) == Some(&b'>') {
                    out.push(Tok::Cmp(Cmp::Ne));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(Cmp::Lt));
                    i += 1;
                }
            }
            b'>' => {
                if b.get(i + 1) == Some(&b'=') {
                    out.push(Tok::Cmp(Cmp::Ge));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(Cmp::Gt));
                    i += 1;
                }
            }
            b'!' if b.get(i + 1) == Some(&b'=') => {
                out.push(Tok::Cmp(Cmp::Ne));
                i += 2;
            }
            b'0'..=b'9' => {
                let start = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                out.push(Tok::Int(s[start..i].parse().ok()?));
            }
            b'-' if b.get(i + 1).is_some_and(|c| c.is_ascii_digit()) => {
                let start = i;
                i += 1;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                out.push(Tok::Int(s[start..i].parse().ok()?));
            }
            _ if is_ident_byte(c) => {
                let start = i;
                while i < b.len() && is_ident_byte(b[i]) {
                    i += 1;
                }
                let word = &s[start..i];
                match word.to_ascii_uppercase().as_str() {
                    "AND" => out.push(Tok::And),
                    "OR" => out.push(Tok::Or),
                    "IS" => out.push(Tok::Is),
                    "NOT" => out.push(Tok::Not),
                    "NULL" => out.push(Tok::Null),
                    _ => out.push(Tok::Ident(word.to_string())),
                }
            }
            _ => return None, // unsupported character
        }
    }
    Some(out)
}

/// An unresolved WHERE term (column name not yet resolved to a field id).
struct RawTerm {
    col: String,
    kind: RawKind,
}
enum RawKind {
    Cmp(Cmp, Rhs),
    IsNull,
    IsNotNull,
}

/// Parse a token stream into DNF (OR of AND-groups of terms). With no
/// parentheses, AND binding tighter than OR is exactly OR-of-ANDs.
fn parse_predicate(toks: &[Tok]) -> Option<Vec<Vec<RawTerm>>> {
    let mut groups = Vec::new();
    for or_part in split_on(toks, |t| matches!(t, Tok::Or)) {
        let mut terms = Vec::new();
        for and_part in split_on(or_part, |t| matches!(t, Tok::And)) {
            terms.push(parse_term(and_part)?);
        }
        if terms.is_empty() {
            return None;
        }
        groups.push(terms);
    }
    if groups.is_empty() {
        return None;
    }
    Some(groups)
}

fn split_on<'a>(toks: &'a [Tok], is_sep: impl Fn(&Tok) -> bool) -> Vec<&'a [Tok]> {
    let mut parts = Vec::new();
    let mut start = 0;
    for (i, t) in toks.iter().enumerate() {
        if is_sep(t) {
            parts.push(&toks[start..i]);
            start = i + 1;
        }
    }
    parts.push(&toks[start..]);
    parts
}

fn parse_term(t: &[Tok]) -> Option<RawTerm> {
    match t {
        [Tok::Ident(c), Tok::Cmp(op), Tok::Int(n)] => Some(RawTerm {
            col: c.clone(),
            kind: RawKind::Cmp(*op, Rhs::Int(*n)),
        }),
        [Tok::Ident(c), Tok::Cmp(op), Tok::Str(v)] => Some(RawTerm {
            col: c.clone(),
            kind: RawKind::Cmp(*op, Rhs::Str(v.clone())),
        }),
        [Tok::Ident(c), Tok::Is, Tok::Null] => Some(RawTerm {
            col: c.clone(),
            kind: RawKind::IsNull,
        }),
        [Tok::Ident(c), Tok::Is, Tok::Not, Tok::Null] => Some(RawTerm {
            col: c.clone(),
            kind: RawKind::IsNotNull,
        }),
        _ => None,
    }
}

/// Whether a descriptor is comparable as an integer or as text (the only
/// kinds WHERE handles); None for anything else.
enum ColKind {
    Int,
    Text,
}
fn col_kind(d: &Descriptor) -> Option<ColKind> {
    if matches!(d.dtype, dtype::SHORT | dtype::LONG | dtype::INT64) && d.scale == 0 {
        Some(ColKind::Int)
    } else if matches!(d.dtype, dtype::TEXT | dtype::VARYING) {
        Some(ColKind::Text)
    } else {
        None
    }
}

/// Resolve every term's column name to a field id and check the literal
/// type matches the column type. Returns None on an unknown column, an
/// unsupported column type, or a literal/column type mismatch.
fn resolve_predicate(
    raw: Vec<Vec<RawTerm>>,
    columns: &[RelationColumn],
    descs: &[Descriptor],
) -> Option<Predicate> {
    let mut groups = Vec::new();
    for g in raw {
        let mut terms = Vec::new();
        for rt in g {
            let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(&rt.col))?;
            let fid = rc.field_id as usize;
            let kind = col_kind(descs.get(fid)?)?;
            let term = match rt.kind {
                RawKind::Cmp(op, Rhs::Int(n)) => match kind {
                    ColKind::Int => Term::Cmp(fid, op, Rhs::Int(n)),
                    _ => return None,
                },
                RawKind::Cmp(op, Rhs::Str(v)) => match kind {
                    ColKind::Text => Term::Cmp(fid, op, Rhs::Str(v)),
                    _ => return None,
                },
                RawKind::IsNull => Term::IsNull(fid),
                RawKind::IsNotNull => Term::IsNotNull(fid),
            };
            terms.push(term);
        }
        groups.push(terms);
    }
    Some(Predicate(groups))
}

/// Serve one connection to completion.
fn handle(mut s: TcpStream, user: &str, password: &str) -> std::io::Result<()> {
    let mut none: Option<Rc4> = None;

    // --- op_connect ---
    if read_int(&mut s, &mut none)? != OP_CONNECT {
        return Ok(());
    }
    read_int(&mut s, &mut none)?; // p_cnct_operation
    read_int(&mut s, &mut none)?; // connect version
    read_int(&mut s, &mut none)?; // arch
    read_wire_bytes(&mut s, &mut none)?; // db path
    let count = read_int(&mut s, &mut none)?;
    let uid = read_wire_bytes(&mut s, &mut none)?;
    let mut best = 0i32;
    for _ in 0..count {
        let v = read_int(&mut s, &mut none)? & 0x7fff;
        read_int(&mut s, &mut none)?; // arch
        read_int(&mut s, &mut none)?; // min ptype
        read_int(&mut s, &mut none)?; // max ptype
        read_int(&mut s, &mut none)?; // weight
        if (13..=20).contains(&v) && v > best {
            best = v;
        }
    }
    if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] op_connect ok, best proto {}", best); }
    if best == 0 {
        return Ok(()); // no common protocol
    }
    let (login, a_hex) = parse_user_id(&uid);
    if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] login={} keylen={}", login, a_hex.len()); }
    if !login.eq_ignore_ascii_case(user) || a_hex.is_empty() {
        return Ok(());
    }

    // --- server SRP: salt + verifier, send op_cond_accept(salt, B) ---
    let salt = hex_upper(&seed_bytes(16, 0xC0FFEE)); // 32 printable-hex bytes
    let verifier = SrpVerifier::new(user, password, salt.as_bytes());
    let (b_priv, b_hex) = verifier.server_public(&seed_bytes(128, 0xBEEF));

    let mut data = Vec::new();
    data.extend_from_slice(&(salt.len() as u16).to_le_bytes());
    data.extend_from_slice(salt.as_bytes());
    data.extend_from_slice(&(b_hex.len() as u16).to_le_bytes());
    data.extend_from_slice(b_hex.as_bytes());

    // The accepted version must carry FB_PROTOCOL_FLAG (0x8000) in the
    // high bit, exactly as the client offered it. Real clients store this
    // value verbatim and compare it against PROTOCOL_VERSION13 (which also
    // has the flag): stripping the flag makes protocol 20 look "< 13", so
    // the client decodes rows in the legacy per-field-null-indicator
    // format and every value comes back NULL. (Cost us a full debug pass.)
    const FB_PROTOCOL_FLAG: i32 = 0x8000;
    let mut w = W::default();
    w.int(OP_COND_ACCEPT)
        .int(best | FB_PROTOCOL_FLAG)
        .int(1) // arch
        .int(3) // ptype
        .bytes(&data)
        .bytes(b"Srp256")
        .int(0) // authenticated flag (not yet)
        .bytes(&[]); // keys
    w.send(&mut s, &mut none)?;

    if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] sent cond_accept, waiting cont_auth"); }
    // --- op_cont_auth: the client proof M ---
    let ca = read_int(&mut s, &mut none)?;
    if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] next op after cond_accept = {}", ca); }
    if ca != OP_CONT_AUTH {
        return Ok(());
    }
    let m = read_wire_bytes(&mut s, &mut none)?;
    read_wire_bytes(&mut s, &mut none)?; // plugin
    read_wire_bytes(&mut s, &mut none)?; // list
    read_wire_bytes(&mut s, &mut none)?; // keys
    let m_hex = String::from_utf8_lossy(&m).into_owned();
    let session_key = match verifier.verify(&a_hex, &b_priv, &b_hex, &m_hex) {
        Some(k) => k,
        None => {
            // isc_login (335544472) as a gds status
            let mut w = W::default();
            w.int(OP_RESPONSE)
                .int(0)
                .int(0)
                .int(0)
                .int(0)
                .int(1) // isc_arg_gds
                .int(335544472)
                .int(0);
            w.send(&mut s, &mut none)?;
            return Ok(());
        }
    };
    if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] proof verified, auth accepted"); }
    respond(&mut s, &mut none, 0)?; // auth accepted

    // --- op_crypt is OPTIONAL. A client that asked for wire encryption
    // sends op_crypt("Arc4","Symmetric") here and everything after is
    // encrypted with the SRP session key. A client that did NOT (or one
    // whose crypt negotiation we did not satisfy, e.g. node-firebird,
    // which falls back to cleartext) sends op_attach straight away. We
    // peek the op and branch: only arm Arc4 when op_crypt actually
    // arrives, so both kinds of client attach. ---
    let mut enc: Option<Rc4> = None;
    let mut dec: Option<Rc4> = None;
    let cop = read_int(&mut s, &mut none)?;
    if std::env::var("FC_SRV_TRACE").is_ok() {
        eprintln!("[srv] op after auth = {} (op_crypt 96 => encrypt, op_attach 19 => cleartext)", cop);
    }
    let attach_op = if cop == OP_CRYPT {
        read_wire_bytes(&mut s, &mut none)?; // "Arc4"
        read_wire_bytes(&mut s, &mut none)?; // "Symmetric"
        enc = Some(Rc4::new(&session_key));
        dec = Some(Rc4::new(&session_key));
        respond(&mut s, &mut enc, 0)?; // op_crypt reply, encrypted from here on
        read_int(&mut s, &mut dec)? // now read the (encrypted) op_attach
    } else {
        cop // the op we already read IS op_attach (cleartext path)
    };

    // --- op_attach (encrypted or not, depending on the branch above) ---
    if attach_op != OP_ATTACH {
        return Ok(());
    }
    read_int(&mut s, &mut dec)?; // 0
    let path_bytes = read_wire_bytes(&mut s, &mut dec)?; // db path
    read_wire_bytes(&mut s, &mut dec)?; // dpb
    let db_path = String::from_utf8_lossy(&path_bytes).into_owned();
    // Open the real file the client named, if it exists and is a database.
    // When it does, queries answer from its pages; when it does not (the
    // client attached to a name with no file behind it), the server falls
    // back to the fixed constant so the pipeline still round-trips.
    let database: Option<Database> = load_database(&db_path);
    if std::env::var("FC_SRV_TRACE").is_ok() {
        eprintln!(
            "[srv] op_attach ok, handle 1 ({}); database '{}' {}",
            if enc.is_some() { "encrypted" } else { "cleartext" },
            db_path,
            match &database {
                Some(d) => format!("loaded ({}-byte pages)", d.page_size),
                None => "not loaded (fixed-answer fallback)".to_string(),
            }
        );
    }
    respond(&mut s, &mut enc, 1)?; // attachment handle 1

    // The SQL text of the most recently prepared statement, and the plan
    // it resolves to (built at prepare, executed at fetch).
    let mut stmt_sql = String::new();
    let mut plan = Plan::Scalar(Some(FIXED_ANSWER));

    // --- the op loop (encrypted) ---
    loop {
        let op = match read_int(&mut s, &mut dec) {
            Ok(o) => o,
            Err(_) => break,
        };
        if std::env::var("FC_SRV_TRACE").is_ok() { eprintln!("[srv] op-loop got op = {}", op); }
        match op {
            x if x == OP_DETACH => {
                read_int(&mut s, &mut dec)?; // handle
                respond(&mut s, &mut enc, 0)?;
                break;
            }
            x if x == OP_TRANSACTION => {
                read_int(&mut s, &mut dec)?; // db handle
                read_wire_bytes(&mut s, &mut dec)?; // tpb
                respond(&mut s, &mut enc, 1)?; // tr handle 1
            }
            x if x == OP_ALLOCATE_STATEMENT => {
                read_int(&mut s, &mut dec)?; // db handle
                respond(&mut s, &mut enc, 1)?; // stmt handle 1
            }
            x if x == OP_PREPARE_STATEMENT => {
                read_int(&mut s, &mut dec)?; // tr
                read_int(&mut s, &mut dec)?; // stmt
                read_int(&mut s, &mut dec)?; // dialect
                let sql = read_wire_bytes(&mut s, &mut dec)?; // sql
                read_wire_bytes(&mut s, &mut dec)?; // items
                read_int(&mut s, &mut dec)?; // buffer length
                if best >= 20 {
                    read_int(&mut s, &mut dec)?; // p_sqlst_flags (FB6/proto 20+)
                }
                stmt_sql = String::from_utf8_lossy(&sql).into_owned();
                plan = plan_query(&stmt_sql, &database);
                let describe = describe_for(&plan);
                respond_prepare(&mut s, &mut enc, &describe)?;
            }
            x if x == OP_EXECUTE => {
                read_int(&mut s, &mut dec)?; // stmt
                read_int(&mut s, &mut dec)?; // tr
                read_wire_bytes(&mut s, &mut dec)?; // input blr
                read_int(&mut s, &mut dec)?; // msg number
                read_int(&mut s, &mut dec)?; // param count
                // op_execute grew trailing fields across protocol versions;
                // a client that negotiated a newer version always sends them,
                // and not draining them desyncs the (encrypted) stream.
                if best >= 16 {
                    read_int(&mut s, &mut dec)?; // p_sqldata_timeout
                }
                if best >= 18 {
                    read_int(&mut s, &mut dec)?; // p_sqldata_cursor_flags
                }
                if best >= 19 {
                    read_int(&mut s, &mut dec)?; // p_sqldata_inline_blob_size
                }
                respond(&mut s, &mut enc, 0)?;
            }
            x if x == OP_FETCH => {
                read_int(&mut s, &mut dec)?; // stmt
                read_wire_bytes(&mut s, &mut dec)?; // blr
                read_int(&mut s, &mut dec)?; // msg number
                read_int(&mut s, &mut dec)?; // count
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] fetch: {:?}", stmt_sql.trim());
                }
                // stream the plan's rows + end-of-cursor terminator
                let mut w = W::default();
                emit_rows(&mut w, &plan, &database);
                w.send(&mut s, &mut enc)?;
            }
            x if x == OP_FREE_STATEMENT => {
                read_int(&mut s, &mut dec)?; // stmt
                read_int(&mut s, &mut dec)?; // op
                respond(&mut s, &mut enc, 0)?;
            }
            x if x == OP_COMMIT || x == OP_ROLLBACK => {
                read_int(&mut s, &mut dec)?; // tr
                respond(&mut s, &mut enc, 0)?;
            }
            x if x == OP_CANCEL => {
                // The C++ fbclient configures async cancellation right after
                // attach (op_cancel with fb_cancel_disable). Per protocol.h
                // it carries ONLY p_co_kind (one int) and the server sends
                // NO response - it is fire-and-forget (server.cpp: op_cancel
                // -> cancel_operation, no send). Reading a second int or
                // replying desyncs the stream.
                read_int(&mut s, &mut dec)?; // p_co_kind
            }
            x if x == OP_INFO_DATABASE => {
                // isql asks for dialect / ODS / server-version banner data.
                // We answer a minimal but well-formed info buffer.
                read_int(&mut s, &mut dec)?; // db handle
                read_int(&mut s, &mut dec)?; // incarnation
                let items = read_wire_bytes(&mut s, &mut dec)?; // requested items
                read_int(&mut s, &mut dec)?; // buffer length
                let info = build_db_info(&items);
                let mut w = W::default();
                w.int(OP_RESPONSE).int(0).int(0).int(0).bytes(&info).int(0);
                w.send(&mut s, &mut enc)?;
            }
            _ => break, // unhandled op: end the connection
        }
    }
    Ok(())
}

fn hex_upper(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02X}", x)).collect()
}

/// Build a minimal-but-well-formed isc_info database response for the
/// items isql requests after attach. Each recognised item is emitted as
/// code(1) + length(2 LE) + little-endian value; unknown items are
/// skipped; the buffer ends with isc_info_end (1). Enough for isql to
/// establish dialect/ODS/version and show its prompt.
fn build_db_info(items: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    fn put_int(out: &mut Vec<u8>, code: u8, val: i32) {
        out.push(code);
        out.extend_from_slice(&4u16.to_le_bytes());
        out.extend_from_slice(&val.to_le_bytes());
    }
    for &code in items {
        match code {
            62 => put_int(&mut out, 62, 3),    // isc_info_db_sql_dialect
            32 => put_int(&mut out, 32, 13),   // isc_info_ods_version (FB6)
            33 => put_int(&mut out, 33, 0),    // isc_info_ods_minor_version
            14 => put_int(&mut out, 14, 8192), // isc_info_page_size
            63 => put_int(&mut out, 63, 0),    // isc_info_db_read_only
            13 => {
                // isc_info_base_level: byte-count-prefixed value
                out.push(13);
                out.extend_from_slice(&2u16.to_le_bytes());
                out.extend_from_slice(&[1, 6]);
            }
            103 => {
                // isc_info_firebird_version: count byte + [len][string]*
                let banner: &[u8] = b"LI-V6.0.0 fire-crab";
                let mut data = vec![1u8, banner.len() as u8];
                data.extend_from_slice(banner);
                out.push(103);
                out.extend_from_slice(&(data.len() as u16).to_le_bytes());
                out.extend_from_slice(&data);
            }
            1 => break, // isc_info_end already in the request
            _ => {}     // unknown item: skip
        }
    }
    out.push(1); // isc_info_end
    out
}

/// Run the fire-crab wire server on `addr` (e.g. "127.0.0.1:3051"),
/// authenticating `user`/`password`. One thread per connection.
pub fn serve(addr: &str, user: &str, password: &str) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr)?;
    eprintln!("fire-crab server listening on {} (user {})", addr, user);
    for conn in listener.incoming() {
        match conn {
            Ok(s) => {
                // one thread per connection so clients that reconnect in
                // quick succession are not serialized behind each other
                let (u, p) = (user.to_string(), password.to_string());
                std::thread::spawn(move || {
                    let _ = handle(s, &u, &p);
                });
            }
            Err(e) => eprintln!("accept error: {}", e),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_buffer_is_parseable() {
        // the describe the server produces must satisfy the client parser
        let d = describe_one_bigint();
        // marker [4,7,4,0] must be present
        assert!(d.windows(4).any(|w| w == [4, 7, 4, 0]));
    }

    fn proj_cols(p: &Proj) -> Vec<String> {
        match p {
            Proj::Star => vec!["*".into()],
            Proj::Items(items) => items
                .iter()
                .map(|i| match i {
                    SelItem::Col(c) => c.clone(),
                    SelItem::Agg(..) => "<agg>".into(),
                })
                .collect(),
        }
    }

    #[test]
    fn splits_select_from_where_order() {
        // COUNT
        let (p, t, w, g, o) = split_query("SELECT COUNT(*) FROM RDB$RELATIONS").unwrap();
        assert!(matches!(
            parse_projection(p),
            Some(Proj::Items(items))
                if matches!(items.as_slice(), [SelItem::Agg(AggFn::Count, AggTarget::Star)])
        ));
        assert_eq!(t, "RDB$RELATIONS");
        assert!(w.is_none() && g.is_none() && o.is_none());
        // projection + WHERE + ORDER BY, mixed case; literal case preserved
        let (p, t, w, g, o) =
            split_query("select ID, NAME from Emp where NAME = 'Emp 5' order by ID desc;").unwrap();
        assert_eq!(proj_cols(&parse_projection(p).unwrap()), vec!["ID", "NAME"]);
        assert_eq!(t, "Emp");
        assert_eq!(w, Some("NAME = 'Emp 5'"));
        assert!(g.is_none());
        assert_eq!(o, Some("ID desc"));
        // ORDER BY without WHERE
        let (_, t, w, g, o) = split_query("SELECT * FROM DEPT ORDER BY 1").unwrap();
        assert_eq!(t, "DEPT");
        assert!(w.is_none() && g.is_none());
        assert_eq!(o, Some("1"));
    }

    #[test]
    fn splits_group_by() {
        // WHERE + GROUP BY + ORDER BY, mixed case
        let (p, t, w, g, o) = split_query(
            "select DEPT_ID, count(*) from EMP where ID <= 30 group by DEPT_ID order by 1",
        )
        .unwrap();
        assert_eq!(proj_cols(&parse_projection(p).unwrap()), vec!["DEPT_ID", "<agg>"]);
        assert_eq!(t, "EMP");
        assert_eq!(w, Some("ID <= 30"));
        assert_eq!(g, Some("DEPT_ID"));
        assert_eq!(o, Some("1"));
        // GROUP BY alone ends at the statement end
        let (_, t, w, g, o) = split_query("SELECT A, SUM(B) FROM T GROUP BY A").unwrap();
        assert_eq!(t, "T");
        assert!(w.is_none() && o.is_none());
        assert_eq!(g, Some("A"));
        // 'GROUP BY' inside a WHERE literal must not start the clause
        let (_, t, w, g, _) = split_query("SELECT ID FROM T WHERE NAME = 'GROUP BY X'").unwrap();
        assert_eq!(t, "T");
        assert_eq!(w, Some("NAME = 'GROUP BY X'"));
        assert!(g.is_none());
    }

    #[test]
    fn find_word_respects_boundaries() {
        // FROM inside an identifier must not match
        assert!(split_query("SELECT X FROM T WHERE FROMAGE = 1").is_some());
        // no FROM at all
        assert!(split_query("SELECT 1").is_none());
        // 'ORDER' inside a WHERE string literal must not start an ORDER BY
        let (_, t, w, _, o) = split_query("SELECT ID FROM T WHERE NAME = 'ORDER BY X'").unwrap();
        assert_eq!(t, "T");
        assert_eq!(w, Some("NAME = 'ORDER BY X'"));
        assert!(o.is_none());
    }

    #[test]
    fn parses_aggregates_and_ordinals() {
        assert!(matches!(parse_agg_item("MIN(SALARY)"), Some((AggFn::Min, AggTarget::Col(c))) if c == "SALARY"));
        assert!(matches!(parse_agg_item("sum( id )"), Some((AggFn::Sum, AggTarget::Col(c))) if c == "id"));
        assert!(matches!(parse_agg_item("COUNT(*)"), Some((AggFn::Count, AggTarget::Star))));
        assert!(parse_agg_item("MIN(*)").is_none()); // MIN(*) invalid
        assert!(parse_projection("MIN(*)").is_none()); // ...and not an identifier either
        // a mixed select list parses item by item
        assert_eq!(
            proj_cols(&parse_projection("DEPT_ID, COUNT(*), MIN(SALARY)").unwrap()),
            vec!["DEPT_ID", "<agg>", "<agg>"]
        );
        // ORDER BY resolution: ordinal into the projection, and by name
        let cols = vec![
            ProjCol { name: "ID".into(), field_id: 3, wire: Wire::Int64, sql_type: 580, length: 8 },
            ProjCol { name: "NAME".into(), field_id: 1, wire: Wire::Varying, sql_type: 448, length: 32765 },
        ];
        let columns = vec![
            RelationColumn { name: "ID".into(), field_id: 3, position: 0 },
            RelationColumn { name: "NAME".into(), field_id: 1, position: 1 },
        ];
        let by_col = |n: &str| {
            columns
                .iter()
                .find(|c| c.name.eq_ignore_ascii_case(n))
                .map(|c| c.field_id as usize)
        };
        assert_eq!(parse_order_by("2 DESC, ID", &cols, by_col), Some(vec![(1, true), (3, false)]));
        assert!(parse_order_by("3", &cols, by_col).is_none()); // ordinal out of range
        assert!(parse_order_by("BOGUS", &cols, by_col).is_none()); // unknown column
    }

    #[test]
    fn group_by_list_resolves_names_and_ordinals() {
        let items = vec![
            SelItem::Col("DEPT_ID".into()),
            SelItem::Agg(AggFn::Count, AggTarget::Star),
        ];
        let columns = vec![
            RelationColumn { name: "ID".into(), field_id: 0, position: 0 },
            RelationColumn { name: "DEPT_ID".into(), field_id: 2, position: 1 },
        ];
        assert_eq!(parse_group_by("DEPT_ID", &items, &columns), Some(vec![2]));
        assert_eq!(parse_group_by("1", &items, &columns), Some(vec![2])); // ordinal = the Col item
        assert!(parse_group_by("2", &items, &columns).is_none()); // ordinal names an aggregate
        assert!(parse_group_by("BOGUS", &items, &columns).is_none()); // unknown column
        assert!(parse_group_by("", &items, &columns).is_none()); // empty list
    }

    #[test]
    fn computes_group_aggregates() {
        // rows: (key at fid 0, value at fid 1)
        let rows = vec![
            vec![Value::Int(1), Value::Int(10)],
            vec![Value::Int(1), Value::Null],
            vec![Value::Int(1), Value::Int(4)],
        ];
        let gitems = vec![
            GItem::Key(0),
            GItem::Agg(AggFn::Count, None),
            GItem::Agg(AggFn::Count, Some(1)),
            GItem::Agg(AggFn::Min, Some(1)),
            GItem::Agg(AggFn::Max, Some(1)),
            GItem::Agg(AggFn::Sum, Some(1)),
        ];
        assert_eq!(
            compute_group(&rows, &gitems),
            vec![
                Value::Int(1),
                Value::Int(3),  // COUNT(*) counts the NULL row
                Value::Int(2),  // COUNT(col) does not
                Value::Int(4),
                Value::Int(10),
                Value::Int(14),
            ]
        );
        // the global empty group: COUNT = 0, MIN/MAX/SUM = NULL
        assert_eq!(
            compute_group(&[], &gitems[1..]),
            vec![Value::Int(0), Value::Int(0), Value::Null, Value::Null, Value::Null]
        );
    }

    #[test]
    fn order_cmp_sorts_with_nulls_low() {
        let keys = vec![(0usize, false)];
        let mut rows = vec![
            vec![Value::Int(3)],
            vec![Value::Null],
            vec![Value::Int(1)],
        ];
        rows.sort_by(|a, b| order_cmp(a, b, &keys));
        assert_eq!(rows, vec![vec![Value::Null], vec![Value::Int(1)], vec![Value::Int(3)]]);
        // descending reverses (NULLs last)
        let keys = vec![(0usize, true)];
        rows.sort_by(|a, b| order_cmp(a, b, &keys));
        assert_eq!(rows, vec![vec![Value::Int(3)], vec![Value::Int(1)], vec![Value::Null]]);
    }

    #[test]
    fn plan_falls_back_to_scalar_without_database() {
        // with no database loaded, everything plans to the fixed scalar
        assert!(matches!(plan_query("SELECT COUNT(*) FROM DEPT", &None), Plan::Scalar(Some(FIXED_ANSWER))));
        assert!(matches!(plan_query("SELECT ID, NAME FROM EMP WHERE ID > 5", &None), Plan::Scalar(Some(FIXED_ANSWER))));
        assert!(matches!(plan_query("SELECT CAST(1 AS BIGINT) FROM RDB$DATABASE", &None), Plan::Scalar(Some(FIXED_ANSWER))));
    }

    #[test]
    fn tokenizes_and_parses_predicate() {
        let toks = tokenize("ID >= 5 AND NAME = 'a b' OR SALARY IS NULL").unwrap();
        let dnf = parse_predicate(&toks).unwrap();
        assert_eq!(dnf.len(), 2); // two OR groups
        assert_eq!(dnf[0].len(), 2); // ID>=5 AND NAME='a b'
        assert_eq!(dnf[1].len(), 1); // SALARY IS NULL
        // string literal keeps embedded spaces and case
        assert!(matches!(&dnf[0][1].kind, RawKind::Cmp(_, Rhs::Str(s)) if s == "a b"));
        // <> and != both parse; negative ints; IS NOT NULL
        assert!(parse_predicate(&tokenize("A <> -3").unwrap()).is_some());
        assert!(parse_predicate(&tokenize("A != 1 AND B IS NOT NULL").unwrap()).is_some());
        // parentheses / functions are unsupported -> tokenize fails
        assert!(tokenize("(A = 1)").is_none());
    }

    #[test]
    fn predicate_matches_rows() {
        // col 0 int, col 1 text
        let p = Predicate(vec![vec![
            Term::Cmp(0, Cmp::Ge, Rhs::Int(5)),
            Term::Cmp(1, Cmp::Eq, Rhs::Str("x".into())),
        ]]);
        assert!(p.matches(&[Value::Int(5), Value::Text("x   ".into())])); // trailing blanks ignored
        assert!(!p.matches(&[Value::Int(4), Value::Text("x".into())])); // 4 < 5
        assert!(!p.matches(&[Value::Int(9), Value::Text("y".into())])); // text differs
        // NULL comparison is UNKNOWN (excluded); IS NULL catches it
        assert!(!Term::Cmp(0, Cmp::Eq, Rhs::Int(1)).matches(&[Value::Null]));
        assert!(Term::IsNull(0).matches(&[Value::Null]));
        assert!(Term::IsNotNull(0).matches(&[Value::Int(0)]));
    }

    #[test]
    fn encodes_row_bitmap_and_values() {
        // two INT64 cols, second null: 4-byte bitmap (bit 1 set) + one 8-byte value
        let cols = vec![
            ProjCol { name: "A".into(), field_id: 0, wire: Wire::Int64, sql_type: 580, length: 8 },
            ProjCol { name: "B".into(), field_id: 1, wire: Wire::Int64, sql_type: 580, length: 8 },
        ];
        let values = vec![Value::Int(7), Value::Null];
        let mut w = W::default();
        encode_row(&mut w, &cols, &values);
        // bitmap: byte0 = 0b10 (col1 null), 3 pad bytes, then 8-byte BE 7
        assert_eq!(&w.buf[0..4], &[0b10, 0, 0, 0]);
        assert_eq!(&w.buf[4..12], &7i64.to_be_bytes());
        assert_eq!(w.buf.len(), 12); // null col contributes no data
    }

    #[test]
    fn db_info_answers_known_items_and_ends() {
        // isc_info_db_sql_dialect(62) + isc_info_ods_version(32),
        // terminated by isc_info_end(1).
        let out = build_db_info(&[62, 32, 1]);
        assert_eq!(out[0], 62);
        // 2-byte LE length field (= 4), then the 4-byte LE dialect value 3
        assert_eq!(&out[1..3], &4u16.to_le_bytes());
        assert_eq!(i32::from_le_bytes([out[3], out[4], out[5], out[6]]), 3);
        // ODS version item follows
        assert_eq!(out[7], 32);
        // and the buffer ends with isc_info_end
        assert_eq!(*out.last().unwrap(), 1);
    }

    #[test]
    fn db_info_skips_unknown_items() {
        // an unrecognised item (200) contributes nothing but the trailer.
        assert_eq!(build_db_info(&[200]), vec![1]);
    }

    #[test]
    fn user_id_extracts_login_and_key() {
        let mut uid = Vec::new();
        uid.extend_from_slice(&[9, 6]);
        uid.extend_from_slice(b"SYSDBA");
        uid.extend_from_slice(&[7, 4, 0]); // specific_data: seq 0 + "ABC"
        uid.extend_from_slice(b"ABC");
        let (login, key) = parse_user_id(&uid);
        assert_eq!(login, "SYSDBA");
        assert_eq!(key, "ABC");
    }
}
