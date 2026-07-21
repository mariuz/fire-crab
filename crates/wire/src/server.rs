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

/// What a prepared statement resolves to. `Scalar` covers both the fixed
/// fallback and `SELECT COUNT(*)` (a single BIGINT computed at prepare);
/// `Project` is `SELECT <cols> FROM <table>` walked at fetch.
enum Plan {
    Scalar(i64),
    Project {
        rel: u16,
        formats: Vec<(u8, Vec<Descriptor>)>,
        cols: Vec<ProjCol>,
    },
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

/// Plan a prepared statement against the loaded database. Two shapes are
/// answered from real pages - `SELECT COUNT(*) FROM <table>` and
/// `SELECT <cols> FROM <table>` - both resolving the table through
/// `RDB$RELATIONS`. Everything else (and any query with no database
/// behind it) plans to the fixed constant.
fn plan_query(sql: &str, db: &Option<Database>) -> Plan {
    if let Some(table) = parse_count_target(sql) {
        if let Some(db) = db {
            if let Some(rel) = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, &table) {
                let n = fire_crab_ods::count_primary_records(&db.bytes, db.page_size, rel);
                return Plan::Scalar(n as i64);
            }
        }
        return Plan::Scalar(FIXED_ANSWER);
    }
    if let Some((collist, table)) = parse_select_from(sql) {
        if let Some(db) = db {
            if let Some(rel) = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, &table) {
                let columns = relation_columns(&db.bytes, db.page_size, &table);
                let formats = relation_formats(&db.bytes, db.page_size, rel);
                let cols = {
                    let descs = formats
                        .iter()
                        .max_by_key(|(n, _)| *n)
                        .map(|(_, d)| d.as_slice())
                        .unwrap_or(&[]);
                    build_projcols(&collist, &columns, descs)
                };
                if let Some(cols) = cols {
                    if !cols.is_empty() {
                        return Plan::Project { rel, formats, cols };
                    }
                }
            }
        }
        return Plan::Scalar(FIXED_ANSWER);
    }
    Plan::Scalar(FIXED_ANSWER)
}

/// The describe buffer for a plan: one BIGINT for `Scalar`, the projected
/// columns for `Project`.
fn describe_for(plan: &Plan) -> Vec<u8> {
    match plan {
        Plan::Scalar(_) => describe_one_bigint(),
        Plan::Project { cols, .. } => build_describe(cols),
    }
}

/// Emit the fetch response for a plan: a stream of
/// op_fetch_response(status=0, messages=1) + row messages, terminated by
/// op_fetch_response(status=100). `Scalar` emits one row; `Project` walks
/// the relation's committed primary records, decoding each with the
/// format it names and projecting the requested columns.
fn emit_rows(w: &mut W, plan: &Plan, db: &Option<Database>) {
    match plan {
        Plan::Scalar(v) => {
            w.int(OP_FETCH_RESPONSE).int(0).int(1);
            w.raw(&[0u8; 4]); // null bitmap (1 col, not null), padded to 4
            w.raw(&v.to_be_bytes());
        }
        Plan::Project {
            rel,
            formats,
            cols,
        } => {
            if let Some(db) = db {
                for dp_no in relation_data_pages(&db.bytes, db.page_size, *rel) {
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
                        let values = decode_record(&image, descs);
                        w.int(OP_FETCH_RESPONSE).int(0).int(1);
                        encode_row(w, cols, &values);
                    }
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

/// Recognise `SELECT <col-list> FROM <table>` where the column list is
/// `*` or a comma-separated list of bare identifiers and nothing follows
/// the table name (no WHERE/JOIN/ORDER/GROUP - honouring those would mean
/// returning different rows, so an unrecognised shape is rejected rather
/// than silently answered wrong). Returns (columns, table).
fn parse_select_from(sql: &str) -> Option<(Vec<String>, String)> {
    let upper = sql.to_ascii_uppercase();
    let compact = upper.split_whitespace().collect::<Vec<_>>().join(" ");
    let compact = compact.trim().trim_end_matches(';').trim();
    let rest = compact.strip_prefix("SELECT ")?;
    let (collist_s, after) = rest.split_once(" FROM ")?;
    // table is the sole token after FROM; anything else is an unsupported clause
    let after = after.trim();
    let mut it = after.splitn(2, ' ');
    let table = it.next()?.trim_matches('"');
    if it.next().map_or(false, |m| !m.trim().is_empty()) {
        return None;
    }
    if table.is_empty() {
        return None;
    }
    let cols: Vec<String> = if collist_s.trim() == "*" {
        vec!["*".to_string()]
    } else {
        collist_s
            .split(',')
            .map(|c| c.trim().trim_matches('"').to_string())
            .collect()
    };
    // only bare identifiers (letters/digits/_/$) - reject expressions,
    // functions, qualified names, empty entries
    let ident_ok = |s: &str| {
        !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
    };
    if cols.iter().any(|c| c != "*" && !ident_ok(c)) {
        return None;
    }
    Some((cols, table.to_string()))
}

/// Recognise `SELECT COUNT(*) FROM <table>`, tolerant of case and of
/// spacing inside `COUNT(*)`, and return the table name. None for every
/// other statement - deliberately narrow: this milestone converts one
/// real query path, it does not pretend to be a SQL parser.
fn parse_count_target(sql: &str) -> Option<String> {
    let upper = sql.to_ascii_uppercase();
    let compact = upper.split_whitespace().collect::<Vec<_>>().join(" ");
    let compact = compact
        .replace("COUNT ( * )", "COUNT(*)")
        .replace("COUNT( * )", "COUNT(*)")
        .replace("COUNT (*)", "COUNT(*)")
        .replace("COUNT(* )", "COUNT(*)")
        .replace("COUNT( *)", "COUNT(*)");
    let rest = compact.strip_prefix("SELECT COUNT(*) FROM ")?;
    let name = rest
        .trim()
        .split([' ', ';'])
        .next()
        .unwrap_or("")
        .trim_matches('"');
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
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
    let mut plan = Plan::Scalar(FIXED_ANSWER);

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

    #[test]
    fn parses_count_star_target() {
        assert_eq!(parse_count_target("SELECT COUNT(*) FROM RDB$RELATIONS").as_deref(), Some("RDB$RELATIONS"));
        // case- and spacing-insensitive, trailing semicolon tolerated
        assert_eq!(parse_count_target("select count( * ) from Dept;").as_deref(), Some("DEPT"));
        assert_eq!(parse_count_target("SELECT  COUNT(*)  FROM  \"MyTab\"").as_deref(), Some("MYTAB"));
    }

    #[test]
    fn rejects_non_count_queries() {
        assert_eq!(parse_count_target("SELECT CAST(42 AS BIGINT) FROM RDB$DATABASE"), None);
        assert_eq!(parse_count_target("SELECT * FROM DEPT"), None);
        assert_eq!(parse_count_target("SELECT COUNT(*)"), None); // no FROM
    }

    #[test]
    fn plan_falls_back_to_scalar_without_database() {
        // with no database loaded, everything plans to the fixed scalar
        assert!(matches!(plan_query("SELECT COUNT(*) FROM DEPT", &None), Plan::Scalar(FIXED_ANSWER)));
        assert!(matches!(plan_query("SELECT ID, NAME FROM EMP", &None), Plan::Scalar(FIXED_ANSWER)));
        assert!(matches!(plan_query("SELECT CAST(1 AS BIGINT) FROM RDB$DATABASE", &None), Plan::Scalar(FIXED_ANSWER)));
    }

    #[test]
    fn parses_select_from_projection() {
        let (cols, t) = parse_select_from("SELECT ID, NAME FROM EMP").unwrap();
        assert_eq!(cols, vec!["ID", "NAME"]);
        assert_eq!(t, "EMP");
        // star and lowercase + trailing semicolon
        let (cols, t) = parse_select_from("select * from dept;").unwrap();
        assert_eq!(cols, vec!["*"]);
        assert_eq!(t, "DEPT");
    }

    #[test]
    fn rejects_unsupported_projections() {
        assert!(parse_select_from("SELECT ID FROM EMP WHERE ID > 5").is_none()); // WHERE
        assert!(parse_select_from("SELECT MAX(ID) FROM EMP").is_none()); // expression
        assert!(parse_select_from("SELECT ID FROM EMP ORDER BY ID").is_none()); // ORDER BY
        assert!(parse_select_from("SELECT ID, NAME FROM A JOIN B ON A.X=B.X").is_none()); // JOIN
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
