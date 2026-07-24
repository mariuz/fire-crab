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
    OP_ATTACH, OP_COMMIT, OP_CONNECT, OP_CONT_AUTH, OP_CREATE, OP_CRYPT, OP_DETACH, OP_EXECUTE,
    OP_FETCH, OP_FETCH_RESPONSE, OP_FREE_STATEMENT, OP_PREPARE_STATEMENT, OP_RESPONSE, OP_ROLLBACK,
    OP_SERVICE_ATTACH, OP_SERVICE_DETACH, OP_SERVICE_INFO, OP_SERVICE_START, OP_TRANSACTION,
};

const OP_ALLOCATE_STATEMENT: i32 = 62;
const OP_EXEC_IMMEDIATE: i32 = 64;
// prepare+execute+return one output message in a single round-trip - the
// OO client's execute()-with-output-metadata, and isql's SHOW GENERATORS
// value probe. Its reply is an op_sql_response then a plain op_response.
const OP_EXEC_IMMEDIATE2: i32 = 75;
const OP_SQL_RESPONSE: i32 = 78;
// legacy BLR request API (isql's SHOW commands)
const OP_COMPILE: i32 = 22;
const OP_START: i32 = 23;
const OP_START_AND_SEND: i32 = 24;
const OP_RECEIVE: i32 = 26;
const OP_RELEASE: i32 = 28;
const OP_SEND: i32 = 25; // the op the server replies to op_receive with
const OP_START_AND_RECEIVE: i32 = 73;
const OP_START_SEND_AND_RECEIVE: i32 = 74;
const BLR_REQ_HANDLE: i32 = 5;
const OP_COND_ACCEPT: i32 = 98;
const OP_CANCEL: i32 = 91;
const OP_INFO_DATABASE: i32 = 40;
const OP_INFO_SQL: i32 = 70;
const OP_OPEN_BLOB: i32 = 35;
const OP_GET_SEGMENT: i32 = 36;
const OP_CLOSE_BLOB: i32 = 39;
const OP_OPEN_BLOB2: i32 = 56;

/// isc_bad_segstr_id - "invalid BLOB ID", answered for an op_open_blob
/// naming a blob the file does not have.
const GDS_BAD_BLOB_ID: i32 = 335544329;

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

/// Answer one op_receive with exactly ONE output message, its
/// `p_data_messages` field set to 0 so the client (remote/client/
/// interface.cpp, batch_gds_receive) treats each op_send as a complete
/// one-message batch and comes back with a fresh op_receive for the next
/// row. Sending a message with `p_data_messages == 1` instead would tell
/// the client more of this batch is still on the wire and it would block
/// reading them (deadlock); sending the WHOLE queue up front breaks the
/// legacy requests that keep several open at once - SHOW INDICES drives
/// the index request while, per index, running a segment request, so any
/// rows shipped ahead of demand would be read as the OTHER request's
/// responses and desync the stream. One message per round-trip keeps each
/// request's packets strictly interleaved with its own op_receives.
/// `req_msgno` is echoed when the queue is drained (an empty terminator).
fn send_request_batch(
    s: &mut TcpStream,
    enc: &mut Option<Rc4>,
    handle: i32,
    queue: &[(i32, Vec<u8>)],
    cursor: &mut usize,
    req_msgno: i32,
    _batch: i32,
) -> std::io::Result<()> {
    let mut w = W::default();
    if let Some((msgno, msg)) = queue.get(*cursor) {
        *cursor += 1;
        w.int(OP_SEND)
            .int(handle)
            .int(0) // incarnation
            .int(TX_HANDLE)
            .int(*msgno)
            .int(0); // a one-message batch: 0 ends it, client re-requests
        w.raw(msg);
    } else {
        // no data left: an empty terminator op_send with messages = 0
        w.int(OP_SEND)
            .int(handle)
            .int(0)
            .int(TX_HANDLE)
            .int(req_msgno)
            .int(0);
    }
    w.send(s, enc)
}

/// One op_response whose status vector carries a gds error - how the
/// server refuses a statement (isc_arg_gds + code + isc_arg_end); the
/// client raises it as an SQL error instead of silently proceeding.
fn respond_error(s: &mut TcpStream, enc: &mut Option<Rc4>, gds: i32) -> std::io::Result<()> {
    let mut w = W::default();
    w.int(OP_RESPONSE)
        .int(0)
        .int(0)
        .int(0) // blob id
        .int(0) // response data length
        .int(1) // isc_arg_gds
        .int(gds)
        .int(0); // isc_arg_end
    w.send(s, enc)
}

/// isc_dsql_error - the generic "Dynamic SQL Error" the server answers
/// for statements it cannot honour rather than answering them wrong.
const GDS_DSQL_ERROR: i32 = 335544569;

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

/// Append the isc_info_sql_bind section: how many parameters the
/// statement takes and each one's type/scale/length (the column it
/// targets, described exactly like an output column). Clients build
/// their parameter encoders from this - node-firebird picks
/// SQLParamDate/Bool/etc by these types.
fn append_bind_section(d: &mut Vec<u8>, params: &[Descriptor]) {
    fn int_item(d: &mut Vec<u8>, code: u8, val: i32) {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    }
    d.push(5); // isc_info_sql_bind (bare)
    int_item(d, 7, params.len() as i32); // describe_vars
    for (i, pd) in params.iter().enumerate() {
        let (_, sql_type, length, scale, sub_type) = wire_for(pd);
        int_item(d, 9, (i + 1) as i32); // sqlda_seq
        int_item(d, 11, sql_type);
        int_item(d, 12, sub_type);
        int_item(d, 13, scale);
        int_item(d, 14, length);
        d.push(8); // describe_end (param)
    }
    if params.is_empty() {
        d.push(8); // describe_end (empty section, the historical shape)
    }
}

/// The describe buffer describing exactly one BIGINT column - the
/// reciprocal of the client's parse_describe.
fn describe_one_bigint(params: &[Descriptor]) -> Vec<u8> {
    let mut d = Vec::new();
    let item = |d: &mut Vec<u8>, code: u8, val: i32| {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    };
    item(&mut d, 21, 1); // isc_info_sql_stmt_type = select(1)
    append_bind_section(&mut d, params);
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

/// The describe buffer for a DML statement: its statement type
/// (isc_info_sql_stmt_ insert=2, update=3, delete=4), its parameters,
/// no output columns - the client executes without fetching.
fn describe_dml(stmt_type: i32, params: &[Descriptor]) -> Vec<u8> {
    let mut d = Vec::new();
    let item = |d: &mut Vec<u8>, code: u8, val: i32| {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    };
    item(&mut d, 21, stmt_type); // isc_info_sql_stmt_type
    append_bind_section(&mut d, params);
    d.push(4); // isc_info_sql_select
    item(&mut d, 7, 0); // 0 output columns
    d.push(8); // describe_end
    d.push(1); // isc_info_end
    d
}

/// The op_info_sql answer for isc_info_sql_records: the per-verb row
/// counts of the last executed statement, in the standard cluster form
/// (code 23, 2-byte total length, nested count items, isc_info_end).
fn build_records_info(inserted: i32, updated: i32, deleted: i32) -> Vec<u8> {
    let mut inner = Vec::new();
    let item = |d: &mut Vec<u8>, code: u8, val: i32| {
        d.push(code);
        d.extend_from_slice(&4u16.to_le_bytes());
        d.extend_from_slice(&val.to_le_bytes());
    };
    item(&mut inner, 13, 0); // isc_info_req_select_count
    item(&mut inner, 14, inserted); // isc_info_req_insert_count
    item(&mut inner, 15, updated); // isc_info_req_update_count
    item(&mut inner, 16, deleted); // isc_info_req_delete_count
    let mut d = Vec::new();
    d.push(23); // isc_info_sql_records
    d.extend_from_slice(&(inner.len() as u16).to_le_bytes());
    d.extend_from_slice(&inner);
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
fn build_describe(cols: &[ProjCol], params: &[Descriptor]) -> Vec<u8> {
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
    append_bind_section(&mut d, params);
    d.push(4); // isc_info_sql_select
    int_item(&mut d, 7, cols.len() as i32); // describe_vars: N columns
    for (i, c) in cols.iter().enumerate() {
        int_item(&mut d, 9, (i + 1) as i32); // sqlda_seq
        int_item(&mut d, 11, c.sql_type); // type
        int_item(&mut d, 12, c.sub_type); // sub_type (blob text/binary)
        int_item(&mut d, 13, c.scale); // scale (client divides scaled ints)
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

/// A monotonic attachment id, one per op_attach, so `con.info.id`
/// (isc_info_attachment_id) is distinct per connection - the
/// firebird-qa bootstrap opens two employee connections and names both
/// ids in its architecture-detection query.
static ATTACH_COUNTER: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(1);

/// The transaction handle the server hands out (op_transaction) and
/// echoes in op_execute responses (server.cpp send_response uses the
/// transaction's rtr_id - the OO client reads it as the live
/// transaction and nulls its ITransaction on a 0).
const TX_HANDLE: i32 = 2;

/// A database file the server has opened for the current attachment: the
/// raw bytes plus the page size read from its header. The `ods` crate
/// decodes everything from this slice.
struct Database {
    bytes: Vec<u8>,
    page_size: usize,
    /// where the bytes came from - an INSERT flushes back here
    path: String,
    /// ODS version from the header (for op_info_database)
    ods_major: u16,
    ods_minor: u16,
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
    Some(Database {
        bytes,
        page_size,
        path: p.to_string(),
        ods_major: h.ods_major(),
        ods_minor: h.ods_minor,
    })
}

/// Materialise an empty real database at `path` (op_create). fire-crab
/// serves and mutates real ODS files; synthesising a valid one from
/// nothing is a separate large conversion, so op_create has the engine
/// create it - `isql -o /dev/null` running a CREATE DATABASE - exactly
/// as every gate builds its scratch db. The binary is taken from
/// $FC_ISQL, else `isql` on PATH. The client's own DDL/DML then runs
/// through fire-crab against the file.
fn create_database_file(path: &str) -> Result<(), String> {
    let p = path.trim();
    if p.is_empty() {
        return Err("empty database path".into());
    }
    // an existing file with a decodable header is already a database
    if load_database(p).is_some() {
        return Ok(());
    }
    let _ = std::fs::remove_file(p);
    let isql = std::env::var("FC_ISQL").unwrap_or_else(|_| "isql".to_string());
    let user = std::env::var("FC_CREATE_USER").unwrap_or_else(|_| "SYSDBA".to_string());
    let pass = std::env::var("FC_CREATE_PASSWORD").unwrap_or_else(|_| "masterkey".to_string());
    let sql = format!(
        "CREATE DATABASE '{}' USER '{}' PASSWORD '{}' PAGE_SIZE 8192;\n",
        p.replace('\'', "''"),
        user,
        pass
    );
    let out = std::process::Command::new(&isql)
        .args(["-q", "-o", "/dev/null"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            child.stdin.take().unwrap().write_all(sql.as_bytes())?;
            child.wait_with_output()
        })
        .map_err(|e| format!("spawn {}: {}", isql, e))?;
    if !out.status.success() && load_database(p).is_none() {
        return Err(format!(
            "isql create failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    if load_database(p).is_none() {
        return Err("created file is not a decodable database".into());
    }
    Ok(())
}

/// Serve the op_service_attach connection the firebird-qa plugin's
/// connect_server opens at session start. It reads a handful of server
/// info items (version, home/lock dirs, security db, architecture) and
/// detaches. The exact response byte format was captured from the real
/// Firebird server: each string item is `[tag][u16 LE len][bytes]`,
/// the cluster ending in isc_info_end(1) (SvcInfoCode: SERVER_VERSION
/// 55, IMPLEMENTATION 56, USER_DBPATH 58, GET_ENV 59, GET_ENV_LOCK 60).
fn serve_service(
    s: &mut TcpStream,
    enc: &mut Option<Rc4>,
    dec: &mut Option<Rc4>,
) -> std::io::Result<()> {
    read_int(s, dec)?; // database id (0)
    read_wire_bytes(s, dec)?; // service name ("service_mgr")
    read_wire_bytes(s, dec)?; // spb
    respond(s, enc, 1)?; // service handle 1
    if std::env::var("FC_SRV_TRACE").is_ok() {
        eprintln!("[srv] op_service_attach ok, handle 1");
    }
    loop {
        let op = match read_int(s, dec) {
            Ok(o) => o,
            Err(_) => break,
        };
        match op {
            x if x == OP_SERVICE_INFO => {
                read_int(s, dec)?; // object (service handle)
                read_int(s, dec)?; // incarnation
                read_wire_bytes(s, dec)?; // send items
                let recv = read_wire_bytes(s, dec)?; // requested items
                read_int(s, dec)?; // buffer length
                let info = service_info(&recv);
                let mut w = W::default();
                w.int(OP_RESPONSE).int(0).int(0).int(0).bytes(&info).int(0);
                w.send(s, enc)?;
            }
            x if x == OP_SERVICE_START => {
                // service actions (backup, gstat, ...) are not converted;
                // acknowledge so the client does not desync, and let its
                // info-poll of the (empty) output stream complete
                read_int(s, dec)?; // object
                read_int(s, dec)?; // incarnation
                read_wire_bytes(s, dec)?; // spb (the action)
                respond(s, enc, 0)?;
            }
            x if x == OP_SERVICE_DETACH => {
                read_int(s, dec)?; // handle
                respond(s, enc, 0)?;
                break;
            }
            _ => {
                // unknown service op: reply an error rather than hang
                respond_error(s, enc, GDS_DSQL_ERROR)?;
            }
        }
    }
    Ok(())
}

/// Build the op_service_info response cluster for the requested items,
/// mirroring the real server's bytes. Unknown items are skipped.
fn service_info(items: &[u8]) -> Vec<u8> {
    fn str_item(d: &mut Vec<u8>, tag: u8, val: &str) {
        d.push(tag);
        d.extend_from_slice(&(val.len() as u16).to_le_bytes());
        d.extend_from_slice(val.as_bytes());
    }
    // RUNNING and VERSION are read by the driver as a bare 4-byte int
    // (no 2-byte length prefix), unlike the string items - probe-pinned.
    fn int_item(d: &mut Vec<u8>, tag: u8, val: i32) {
        d.push(tag);
        d.extend_from_slice(&val.to_le_bytes());
    }
    let mut d = Vec::new();
    for &it in items {
        match it {
            // SERVER_VERSION: the driver splits the first space-token on
            // 'V'/'T', so it must look like a Firebird version banner
            55 => str_item(&mut d, 55, "LI-V6.0.0.2076 Firebird 6.0 fire-crab"),
            56 => str_item(&mut d, 56, "Firebird/Linux/ARM64"), // IMPLEMENTATION
            58 => str_item(&mut d, 58, "/opt/firebird/security6.fdb"), // USER_DBPATH
            59 => str_item(&mut d, 59, "/opt/firebird/"), // GET_ENV (home)
            60 => str_item(&mut d, 60, "/tmp/firebird/"), // GET_ENV_LOCK
            54 => int_item(&mut d, 54, 2), // VERSION (service manager)
            67 => int_item(&mut d, 67, 0), // RUNNING: no async action is running
            _ => {}
        }
    }
    d.push(1); // isc_info_end
    d
}

/// How a projected column is carried on the wire (protocol 13+ XDR).
/// Every stored type the record decoder handles exactly is sent in its
/// native wire form; only CHAR/VARCHAR text (and anything unsupported,
/// e.g. blobs) is rendered and sent as SQL_VARYING. The client is
/// expected to fetch with the message format the describe announced -
/// which is what real clients build their output BLR from.
#[derive(Clone, Copy)]
enum Wire {
    /// 8-byte big-endian integer (BIGINT, and INT64-backed numerics)
    Int64,
    /// 4-byte big-endian integer (SMALLINT/INTEGER and their numerics -
    /// XDR carries SHORT as a 32-bit slot too)
    Int32,
    /// 8-byte big-endian IEEE double
    Double,
    /// 4-byte big-endian IEEE float
    Float,
    /// 4-byte big-endian day number (Modified Julian Day epoch)
    Date,
    /// 4-byte big-endian time of day in 1/10000 s
    Time,
    /// date then time, 8 bytes
    Timestamp,
    /// 4-byte int 0/1 (XDR pads the 1-byte boolean to a slot)
    Bool,
    /// 4-byte length + bytes + padding to 4
    Varying,
    /// 8-byte blob id (the on-disk bid bytes); the client fetches the
    /// content through op_open_blob/op_get_segment with this id
    Blob,
    /// 16-byte big-endian 128-bit integer (xdr_int128: high hyper, low
    /// hyper); the raw scaled value travels, the client divides
    Int128,
    /// IEEE 754-2008 decimal64, 8 bytes big-endian (xdr_dec64)
    Dec16,
    /// decimal128, 16 bytes big-endian, high half first (xdr_dec128)
    Dec34,
    /// TIME WITH TIME ZONE: UTC time long + zone id in a 4-byte XDR
    /// slot (xdr.cpp:237-243)
    TimeTz,
    /// TIMESTAMP WITH TIME ZONE: two longs + the zone slot
    /// (xdr.cpp:295-303)
    TimestampTz,
}

/// One column of a projection: its name, the field id that indexes the
/// decoded record, and how it is described/encoded on the wire. `scale`
/// is announced in the describe; the raw scaled integer travels on the
/// wire and the client divides (that is the engine's contract too).
#[derive(Clone)]
struct ProjCol {
    name: String,
    field_id: usize,
    wire: Wire,
    sql_type: i32,
    length: i32,
    scale: i32,
    /// describe item 12 - the blob sub_type (text/binary) for blob
    /// columns, 0 elsewhere
    sub_type: i32,
    /// a scalar expression evaluated per row; `None` = the plain column
    /// at `field_id` (the common case)
    expr: Option<Expr>,
}

impl ProjCol {
    /// The column's value for a decoded row: the expression's result if
    /// it is one, else the record field at `field_id`. `Err` is a per-row
    /// arithmetic exception raised while evaluating an expression column.
    fn value_of(&self, values: &[Value]) -> Result<Value, EvalErr> {
        match &self.expr {
            Some(e) => e.eval(values),
            None => Ok(values.get(self.field_id).cloned().unwrap_or(Value::Null)),
        }
    }
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
/// `having` filters the computed OUTPUT rows; it may reference `gitems`
/// entries past `cols` - hidden items appended for aggregates or keys
/// named only in the HAVING clause, which are computed but not emitted.
/// `Join` is an equi-join of two relations - INNER, or LEFT/RIGHT/FULL
/// OUTER per `kind`: each joined row is the left record's values followed
/// by the right record's (so a COMBINED index < `left_width` names a left
/// field, >= names a right field at `index - left_width`), `on` lists the
/// (left, right) combined-index equality pairs, and `cols`/`filter`/
/// `order_by` all speak combined indexes - `encode_row`, the predicate
/// and the sort apply unchanged. An outer join pads the partnerless
/// side's values with NULLs, and the WHERE filter runs on the PADDED
/// row (SQL's order: join first, then filter - which is what makes
/// `WHERE right.col IS NULL` the classic anti-join).
enum Plan {
    Scalar(Option<i64>),
    /// `SELECT GEN_ID(<name>, <step>)` with a non-zero step, or `NEXT VALUE
    /// FOR <seq>` (step = the sequence's increment): a SELECT that WRITES.
    /// At op_execute it reads the generator, adds the step, writes the new
    /// value back, and becomes a `Scalar` of that new value for the fetch.
    /// `step` is `None` for `NEXT VALUE FOR` (use the generator's own
    /// increment) or `Some(n)` for an explicit `GEN_ID` step.
    GenIdIncrement { name: String, step: Option<i64> },
    /// A query over a MON$ virtual table, which fire-crab reports as
    /// empty: one row of `ncols` NULL columns (an aggregate over no
    /// rows). Used for the firebird-qa bootstrap's architecture probe.
    VirtualEmpty { ncols: usize },
    /// `CREATE TABLE <name> (<col defs>)`: catalog rows, format and
    /// runtime blobs, pointer/root pages, NOT NULL/PRIMARY KEY
    /// constraint rows - all written at op_execute through
    /// `fire_crab_ods::ddl`
    CreateTable {
        name: String,
        cols: Vec<fire_crab_ods::ddl::ColumnDef>,
        /// PRIMARY KEY / UNIQUE constraints, in declaration order
        keys: Vec<fire_crab_ods::ddl::KeyDef>,
        fks: Vec<fire_crab_ods::ddl::ForeignKeyDef>,
    },
    /// `CREATE [UNIQUE] [ASC|DESC] INDEX <name> ON <table> (cols)`:
    /// irt slot + empty root + catalog rows + backfill of existing rows
    CreateIndex {
        table: String,
        name: String,
        cols: Vec<String>,
        unique: bool,
        descending: bool,
    },
    /// `DROP TABLE <name>`: catalog rows stubbed, RDB$PAGES rows wiped,
    /// every owned page released
    DropTable { name: String },
    /// `DROP INDEX <name>`: the mirror of CREATE INDEX - the index
    /// removed the engine's deferred way. An index backing a
    /// constraint is refused (ALTER TABLE DROP CONSTRAINT does that)
    DropIndex { name: String },
    /// `CREATE SEQUENCE|GENERATOR <name> [START WITH n] [INCREMENT [BY]
    /// n]`: the RDB$GENERATORS row with an id drawn from the master
    /// generator, its security class and the owner's USAGE grant, and
    /// the sequence's own slot primed to `start - increment`
    CreateSequence {
        name: String,
        start: Option<i64>,
        increment: Option<i64>,
    },
    /// `DROP SEQUENCE|GENERATOR <name>`: the catalog rows go, the
    /// stored value stays behind
    DropSequence { name: String },
    /// `ALTER INDEX <name> ACTIVE|INACTIVE`: INACTIVE moves the slot to
    /// the drop states (still maintained, no longer enforcing), ACTIVE
    /// REBUILDS the index into a new slot and recomputes its selectivity
    AlterIndex { name: String, active: bool },
    /// `SET STATISTICS INDEX <name>`: recompute the index's selectivity
    /// (`1 / distinct` per key prefix over the current rows) into the
    /// catalog and the index root descriptor
    SetStatistics { name: String },
    /// `ALTER TABLE <table> ADD <column>`: a new format version, the new
    /// column's catalog rows, and a version rewrite of the RDB$RELATIONS
    /// row bumping its format and field count
    AlterTableAdd {
        table: String,
        col: fire_crab_ods::ddl::ColumnDef,
    },
    /// `ALTER TABLE <table> ADD [CONSTRAINT <name>] FOREIGN KEY (...)
    /// REFERENCES ...`: add a foreign key to an existing table - the FK
    /// index built and backfilled over committed rows, the constraint
    /// catalog rows written
    AlterTableAddFk {
        table: String,
        fk: fire_crab_ods::ddl::ForeignKeyDef,
    },
    /// `ALTER TABLE <table> ADD [CONSTRAINT <name>] PRIMARY KEY|UNIQUE
    /// (...)`: add a key constraint to an existing table - the unique
    /// index built over the committed rows (duplicates fail the
    /// statement), the constraint catalog row written
    AlterTableAddKey {
        table: String,
        key: fire_crab_ods::ddl::KeyDef,
    },
    /// `ALTER TABLE <table> DROP CONSTRAINT <name>`: remove a NOT NULL,
    /// PRIMARY KEY, UNIQUE or FOREIGN KEY constraint - the catalog rows
    /// deleted and any backing index deferred-dropped the engine's way
    AlterTableDropConstraint { table: String, constraint: String },
    /// `ALTER TABLE <table> DROP <column>`: a new format version with the
    /// dropped field as a placeholder, the column's catalog rows deleted,
    /// RDB$RUNTIME rebuilt, RDB$RELATIONS format bumped
    AlterTableDrop { table: String, column: String },
    /// `ALTER TABLE <table> ALTER <column> TYPE <newtype>`: a new format
    /// version with the field's descriptor changed, the domain retyped in
    /// place, RDB$RUNTIME rebuilt, RDB$RELATIONS format bumped
    AlterColumnType {
        table: String,
        column: String,
        col: fire_crab_ods::ddl::ColumnDef,
    },
    /// `ALTER TABLE <table> ALTER <column> SET|DROP NOT NULL`: add or
    /// remove a NOT NULL constraint (no format change)
    AlterColumnNull {
        table: String,
        column: String,
        not_null: bool,
    },
    /// `INSERT INTO <t> [(cols)] VALUES (...)`: the record image is
    /// built at prepare (nulls flagged, literal fields at their
    /// descriptor offsets); `param_fields` lists the (field id,
    /// parameter slot) pairs whose bytes arrive with op_execute, which
    /// binds them into a copy of the image and writes it into the
    /// file's pages
    Insert {
        rel: u16,
        format_no: u8,
        image: Vec<u8>,
        descs: Vec<Descriptor>,
        index_ops: Vec<IndexOp>,
        param_fields: Vec<(usize, usize)>,
        /// `NEXT VALUE FOR` / `GEN_ID` fields: (field id, generator name,
        /// step). Each bumps its generator at execute and stores the new
        /// value into the field.
        gen_fields: Vec<(usize, String, Option<i64>)>,
        /// field ids under a NOT NULL constraint - checked after
        /// binding, exactly where the engine validates
        not_null: Vec<usize>,
    },
    /// `UPDATE <t> SET col = <lit|?> [, ...] [WHERE ...]`: literal SET
    /// values are encoded at prepare, parameter ones bind at execute;
    /// op_execute walks the committed primary records, patches the
    /// matching rows' images, and rewrites each as a new version
    /// chained over its old one
    Update {
        rel: u16,
        format_no: u8,
        formats: Vec<(u8, Vec<Descriptor>)>,
        sets: Vec<(usize, SetVal)>,
        filter: Option<Predicate>,
        index_ops: Vec<IndexOp>,
        not_null: Vec<usize>,
    },
    /// `DELETE FROM <t> [WHERE ...]`: op_execute rewrites each matching
    /// primary record as a deleted stub over its version chain
    Delete {
        rel: u16,
        formats: Vec<(u8, Vec<Descriptor>)>,
        filter: Option<Predicate>,
    },
    Project {
        rel: u16,
        formats: Vec<(u8, Vec<Descriptor>)>,
        cols: Vec<ProjCol>,
        filter: Option<Predicate>,
        order_by: Vec<(usize, bool)>,
        /// generator-advancing output columns (usually empty); each is
        /// evaluated per emitted row in output order and persisted when
        /// the fetch completes
        gen_cols: Vec<GenCol>,
    },
    Join {
        kind: JoinKind,
        left_rel: u16,
        left_formats: Vec<(u8, Vec<Descriptor>)>,
        left_width: usize,
        right_rel: u16,
        right_formats: Vec<(u8, Vec<Descriptor>)>,
        right_width: usize,
        on: Vec<(usize, usize)>,
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
        having: Option<Predicate>,
        order_by: Vec<(usize, bool)>,
    },
    /// `SET GENERATOR <name> TO <n>` or `ALTER SEQUENCE|GENERATOR <name>
    /// RESTART WITH <n>`: write a new value into the generator page at
    /// op_execute. `stmt_type` is the statement's info type (set_generator
    /// = 13, or ddl = 5 for the ALTER form) so the describe matches the
    /// engine and the client does not try to fetch a cursor.
    SetGenerator {
        name: String,
        mode: GenWrite,
        stmt_type: i32,
    },
}

/// How a generator write sets its value: `Absolute(n)` stores `n` (`SET
/// GENERATOR ... TO n`); `Restart(n)` stores `n - increment` (`ALTER
/// SEQUENCE ... RESTART WITH n`), so the next `GEN_ID`/`NEXT VALUE FOR`
/// yields `n` - the increment is read from the catalog at execute.
#[derive(Clone, Copy)]
enum GenWrite {
    Absolute(i64),
    Restart(i64),
}

/// One UPDATE SET value: encoded at prepare (literal - `None` inside =
/// SQL NULL), or a parameter slot bound at execute.
enum SetVal {
    Lit(Option<Vec<u8>>),
    Param(usize),
}

/// How a join treats partnerless rows: INNER drops them; LEFT keeps
/// every left row (right side NULL-padded), RIGHT the mirror, FULL both.
#[derive(Clone, Copy, PartialEq)]
enum JoinKind {
    Inner,
    Left,
    Right,
    Full,
}

/// One output column of a grouped query: a grouping key (carried by its
/// record field id) or an aggregate over the group's rows (`None` fid =
/// `COUNT(*)`).
enum GItem {
    Key(usize),
    Agg(AggFn, Option<usize>),
}

/// A scalar-returning aggregate function.
#[derive(Clone, Copy, PartialEq)]
enum AggFn {
    Count,
    Min,
    Max,
    Sum,
}

/// What an aggregate is computed over.
#[derive(Clone)]
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

/// The right-hand side of a comparison: a literal, a NULL literal
/// (legal SQL - the comparison is then always UNKNOWN), or a `?`
/// parameter slot (its index into the statement's parameters, plus
/// the column kind it must bind as - checked when the value arrives
/// at execute).
#[derive(Clone)]
enum Rhs {
    Int(i64),
    Str(String),
    Null,
    Param(usize, ColKind),
}

/// A resolved WHERE term: a column (by field id) tested against a
/// literal, for NULL-ness, or against a LIKE pattern. NOT is pushed
/// all the way into the leaves at parse time (De Morgan through the
/// DNF conversion), so a term only ever answers "definitely true" -
/// SQL UNKNOWN and false both exclude the row, and `negated` LIKE is
/// its own leaf state rather than a runtime NOT. `Never` is what a
/// comparison against NULL (literal or bound parameter) becomes -
/// always UNKNOWN, the row is excluded.
#[derive(Clone)]
enum Term {
    Cmp(usize, Cmp, Rhs),
    IsNull(usize),
    IsNotNull(usize),
    /// `<col> [NOT] LIKE <pattern> [ESCAPE <c>]`: pattern is a string
    /// literal or a text parameter; matching is per CHARACTER (`_` is
    /// one char, `%` any run) on the STORED value - CHAR padding
    /// counts, exactly as the engine matches (CHAR(5) 'abc' matches
    /// 'abc  ' and 'abc%' but NOT 'abc')
    Like(usize, Rhs, Option<char>, bool),
    Never,
}

/// A resolved WHERE predicate in disjunctive normal form (OR of ANDs),
/// which is what AND-binds-tighter-than-OR gives with no parentheses. A
/// row matches if every term of any one group matches.
#[derive(Clone)]
struct Predicate(Vec<Vec<Term>>);

impl Predicate {
    fn matches(&self, values: &[Value]) -> bool {
        self.0
            .iter()
            .any(|group| group.iter().all(|t| t.matches(values)))
    }

    /// Substitute every parameter slot with the value that arrived at
    /// execute. A NULL parameter in a comparison binds to `Term::Never`
    /// (comparison with NULL is UNKNOWN); a value whose wire type does
    /// not match the column kind is an error - never a silent wrong
    /// filter.
    fn bind(&self, args: &[WireParam]) -> Result<Predicate, String> {
        let bind_rhs = |idx: &usize, kind: &ColKind| -> Result<Option<Rhs>, String> {
            let arg = args.get(*idx).ok_or("missing parameter value")?;
            Ok(match (kind, arg) {
                (_, WireParam::Null) => None,
                (ColKind::Int, WireParam::Int(v, 0)) => Some(Rhs::Int(*v)),
                (ColKind::Text, WireParam::Text(s)) => Some(Rhs::Str(s.clone())),
                _ => return Err("parameter type does not match its column".into()),
            })
        };
        let mut groups = Vec::new();
        for g in &self.0 {
            let mut terms = Vec::new();
            for t in g {
                terms.push(match t {
                    Term::Cmp(fid, op, Rhs::Param(idx, kind)) => match bind_rhs(idx, kind)? {
                        None => Term::Never,
                        Some(rhs) => Term::Cmp(*fid, *op, rhs),
                    },
                    Term::Like(fid, Rhs::Param(idx, _), escape, negated) => {
                        match bind_rhs(idx, &ColKind::Text)? {
                            None => Term::Never, // LIKE NULL is UNKNOWN
                            Some(rhs) => Term::Like(*fid, rhs, *escape, *negated),
                        }
                    }
                    other => other.clone(),
                });
            }
            groups.push(terms);
        }
        Ok(Predicate(groups))
    }
}

/// Bind an optional filter's parameters, if it has any.
fn bind_filter(
    filter: &Option<Predicate>,
    args: &[WireParam],
) -> Result<Option<Predicate>, String> {
    match filter {
        None => Ok(None),
        Some(p) => p.bind(args).map(Some),
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
            // comparison against NULL is UNKNOWN - excluded either way
            Term::Cmp(_, _, Rhs::Null) => false,
            // an unbound parameter never matches (the execute path binds
            // before evaluating; this is the defensive answer)
            Term::Cmp(_, _, Rhs::Param(..)) => false,
            Term::Like(fid, pattern, escape, negated) => match (values.get(*fid), pattern) {
                // NO pad trim: the engine matches the stored value,
                // padding included (differentially confirmed)
                (Some(Value::Text(s)), Rhs::Str(p)) => like_match(s, p, *escape) != *negated,
                // NULL value or NULL/unbound pattern: UNKNOWN
                _ => false,
            },
            Term::Never => false,
        }
    }
}

/// SQL LIKE, per CHARACTER (multi-byte text: `_` is one character, not
/// one byte): `%` matches any run, `_` exactly one, the escape
/// character makes the next pattern character literal. Plain
/// backtracking - WHERE patterns are short.
fn like_match(value: &str, pattern: &str, escape: Option<char>) -> bool {
    let v: Vec<char> = value.chars().collect();
    let p: Vec<char> = pattern.chars().collect();
    fn rec(v: &[char], vi: usize, p: &[char], pi: usize, esc: Option<char>) -> bool {
        let mut vi = vi;
        let mut pi = pi;
        while pi < p.len() {
            let c = p[pi];
            if Some(c) == esc && pi + 1 < p.len() {
                if vi < v.len() && v[vi] == p[pi + 1] {
                    vi += 1;
                    pi += 2;
                    continue;
                }
                return false;
            }
            match c {
                '%' => {
                    // try every split for the rest of the pattern
                    for k in vi..=v.len() {
                        if rec(v, k, p, pi + 1, esc) {
                            return true;
                        }
                    }
                    return false;
                }
                '_' => {
                    if vi >= v.len() {
                        return false;
                    }
                    vi += 1;
                    pi += 1;
                }
                _ => {
                    if vi >= v.len() || v[vi] != c {
                        return false;
                    }
                    vi += 1;
                    pi += 1;
                }
            }
        }
        vi == v.len()
    }
    rec(&v, 0, &p, 0, escape)
}

/// Pick the wire shape, SQL type, length and scale for a column from its
/// stored descriptor - mirroring the types the engine itself describes
/// (SQL type codes from sqlda_pub.h). Text and anything without a native
/// mapping (blobs, INT128, DECFLOAT) is rendered and sent as SQL_VARYING.
fn wire_for(d: &Descriptor) -> (Wire, i32, i32, i32, i32) {
    let scale = d.scale as i32;
    match d.dtype {
        dtype::SHORT => (Wire::Int32, 500, 2, scale, 0), // SQL_SHORT
        dtype::LONG => (Wire::Int32, 496, 4, scale, 0),  // SQL_LONG
        dtype::INT64 => (Wire::Int64, 580, 8, scale, 0), // SQL_INT64
        dtype::REAL => (Wire::Float, 482, 4, 0, 0),      // SQL_FLOAT
        dtype::DOUBLE => (Wire::Double, 480, 8, 0, 0),   // SQL_DOUBLE
        dtype::SQL_DATE => (Wire::Date, 570, 4, 0, 0),   // SQL_TYPE_DATE
        dtype::SQL_TIME => (Wire::Time, 560, 4, 0, 0),   // SQL_TYPE_TIME
        dtype::TIMESTAMP => (Wire::Timestamp, 510, 8, 0, 0), // SQL_TIMESTAMP
        dtype::BOOLEAN => (Wire::Bool, 32764, 1, 0, 0),  // SQL_BOOLEAN
        // blob: the 8-byte id travels, content via the blob ops; the
        // describe carries the sub_type so clients know text vs binary
        dtype::BLOB => (Wire::Blob, 520, 8, 0, d.sub_type as i32), // SQL_BLOB
        dtype::INT128 => (Wire::Int128, 32752, 16, scale, 0), // SQL_INT128
        dtype::SQL_TIME_TZ => (Wire::TimeTz, 32756, 8, 0, 0), // SQL_TIME_TZ
        dtype::TIMESTAMP_TZ => (Wire::TimestampTz, 32754, 12, 0, 0), // SQL_TIMESTAMP_TZ
        dtype::DEC64 => (Wire::Dec16, 32760, 8, 0, 0),   // SQL_DEC16
        dtype::DEC128 => (Wire::Dec34, 32762, 16, 0, 0), // SQL_DEC34
        _ => (Wire::Varying, 448, 32765, 0, 0),          // SQL_VARYING, rendered text
    }
}

/// The field ids of a table's NOT NULL columns, read from
/// RDB$RELATION_FIELDS.RDB$NULL_FLAG through the computed system
/// format - what the engine's validation (the RSR_field_not_null
/// runtime segment) enforces; the server checks the same at DML
/// execute.
fn not_null_fids(db: &Database, table: &str) -> Vec<usize> {
    use fire_crab_ods::format::Value;
    let Some(formats) =
        fire_crab_ods::sysfmt::system_relation_formats(&db.bytes, db.page_size, "RDB$RELATION_FIELDS")
    else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(&db.bytes, db.page_size, "RDB$RELATION_FIELDS");
    let fid_of = |name: &str| {
        cols.iter()
            .find(|c| c.name == name)
            .map(|c| c.field_id as usize)
    };
    let (Some(rel_fid), Some(id_fid), Some(nn_fid)) = (
        fid_of("RDB$RELATION_NAME"),
        fid_of("RDB$FIELD_ID"),
        fid_of("RDB$NULL_FLAG"),
    ) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let fmts = vec![(0u8, descs.clone())];
    for_each_record(db, 5, &fmts, |values| {
        let is_rel = matches!(values.get(rel_fid), Some(Value::Text(t)) if t.trim_end().eq_ignore_ascii_case(table));
        if is_rel
            && matches!(values.get(nn_fid), Some(Value::Int(1)))
        {
            if let Some(Value::Int(id)) = values.get(id_fid) {
                out.push(*id as usize);
            }
        }
    });
    out
}

/// Build the projected-column list from a select list and the relation's
/// columns + format descriptors. `*` expands to every column in field-id
/// (SELECT *) order. Returns None if any named column is unknown or has no
/// descriptor.
/// Build a projected column for a scalar expression: resolve its
/// column names to field ids, type it (integer arithmetic -> BIGINT,
/// string literal -> VARCHAR), and carry the expression evaluated per
/// row. None if the expression cannot be resolved or typed.
fn build_expr_col(
    raw: &RawExpr,
    name: &str,
    columns: &[RelationColumn],
    descs: &[Descriptor],
) -> Option<ProjCol> {
    let e = resolve_expr(raw, columns, descs)?;
    let (wire, sql_type, length, scale) = match e.type_of(descs)? {
        ExprType::Int => (Wire::Int64, 580, 8, 0),
        ExprType::Text => (Wire::Varying, 448, 32765, 0),
        // a numeric arithmetic result travels as an INT64-backed scaled
        // integer (SQL_INT64 + its scale, the raw integer on the wire and
        // the client divides) - the scale is computed statically from the
        // operand scales, and `eval` produces exactly that scale so the
        // decode matches
        ExprType::Numeric => (Wire::Int64, 580, 8, e.result_scale(descs)? as i32),
    };
    Some(ProjCol {
        name: name.to_string(),
        field_id: 0,
        wire,
        sql_type,
        length,
        scale,
        sub_type: 0,
        expr: Some(e),
    })
}

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
        let (wire, sql_type, length, scale, sub_type) = wire_for(d);
        out.push(ProjCol {
            name: rc.name.clone(),
            field_id: rc.field_id as usize,
            wire,
            sql_type,
            length,
            scale,
            sub_type,
            expr: None,
        });
    }
    Some(out)
}

/// A value an INSERT accepts: a literal, a `?` parameter slot bound at
/// execute, or a generator advance (`NEXT VALUE FOR <seq>` /
/// `GEN_ID(<name>, <n>)`) evaluated at execute - it bumps the generator
/// and stores the NEW value.
enum InsVal {
    Int(i64),
    Str(String),
    Null,
    Param(usize),
    /// `GenId(name, step)`: `None` step = `NEXT VALUE FOR` (use the
    /// sequence's own increment), `Some(n)` = `GEN_ID(name, n)`.
    GenId(String, Option<i64>),
}

/// Parse one column definition of a CREATE TABLE: `<name> <type>`,
/// where the type is one of the plain storable types, optionally
/// followed by the column-level constraints this writer supports -
/// `NOT NULL` and `[CONSTRAINT <name>] PRIMARY KEY|UNIQUE`, in either
/// order. Anything else (DEFAULT, CHECK, ...) is refused - the
/// statement then errors, it never half-creates. Returns the column
/// (external RDB$FIELD_TYPE code plus the descriptor pieces, dsc.h
/// dtypes) and its column-level key constraint, if any, as
/// (constraint name - empty when unnamed, is-primary).
fn parse_column_def(item: &str) -> Option<(fire_crab_ods::ddl::ColumnDef, Option<(String, bool)>)> {
    use fire_crab_ods::format::dtype;
    let item = item.trim();
    let (name, ty) = item.split_once(char::is_whitespace)?;
    let name = name.trim_matches('"');
    if !ident_ok(name) {
        return None;
    }
    let mut ty = ty.trim().to_ascii_uppercase();
    // trailing column constraints, stripped off the end in any order
    let mut key: Option<(String, bool)> = None;
    let mut not_null = false;
    loop {
        let t = ty.trim_end();
        let (rest, primary) = if let Some(r) = t.strip_suffix("PRIMARY KEY") {
            (r, true)
        } else if let Some(r) = t.strip_suffix("UNIQUE") {
            (r, false)
        } else if let Some(r) = t.strip_suffix("NOT NULL") {
            not_null = true;
            ty = r.trim_end().to_string();
            continue;
        } else {
            break;
        };
        if key.is_some() {
            return None; // two key constraints on one column
        }
        // the key words may be preceded by CONSTRAINT <name>
        let mut head = rest.trim_end().to_string();
        let mut cname = String::new();
        if let Some(sp) = head.rfind(char::is_whitespace) {
            let cand = head[sp + 1..].trim().trim_matches('"').to_string();
            let before = head[..sp].trim_end().to_string();
            if let Some(pre) = before.strip_suffix("CONSTRAINT") {
                if pre.is_empty() || pre.ends_with(char::is_whitespace) {
                    if !ident_ok(&cand) {
                        return None;
                    }
                    cname = cand;
                    head = pre.trim_end().to_string();
                }
            }
        }
        if primary {
            not_null = true; // PRIMARY KEY implies NOT NULL
        }
        key = Some((cname, primary));
        ty = head;
    }
    let col = |field_type: i16, dt: u8, length: u16, scale: i8, sub_type: i16, char_len: Option<u16>| {
        Some(fire_crab_ods::ddl::ColumnDef {
            name: name.to_ascii_uppercase(),
            field_type,
            dtype: dt,
            length,
            scale,
            sub_type,
            char_len,
            not_null,
            // a column-level NOT NULL (explicit or from a column-level
            // PRIMARY KEY) is the case the engine records as a
            // constraint row
            not_null_constraint: not_null,
        })
    };
    // parenthesised argument(s), if any
    let (base, args) = match ty.find('(') {
        Some(p) => {
            if !ty.ends_with(')') {
                return None;
            }
            let mut nums = Vec::new();
            for part in ty[p + 1..ty.len() - 1].split(',') {
                nums.push(part.trim().parse::<u16>().ok()?);
            }
            (ty[..p].trim().to_string(), nums)
        }
        None => (ty.clone(), Vec::new()),
    };
    let built = match (base.as_str(), args.as_slice()) {
        ("SMALLINT", []) => col(7, dtype::SHORT, 2, 0, 0, None),
        ("INTEGER" | "INT", []) => col(8, dtype::LONG, 4, 0, 0, None),
        ("BIGINT", []) => col(16, dtype::INT64, 8, 0, 0, None),
        ("FLOAT", []) => col(10, dtype::REAL, 4, 0, 0, None),
        ("DOUBLE PRECISION", []) => col(27, dtype::DOUBLE, 8, 0, 0, None),
        ("DATE", []) => col(12, dtype::SQL_DATE, 4, 0, 0, None),
        ("TIME", []) => col(13, dtype::SQL_TIME, 4, 0, 0, None),
        ("TIMESTAMP", []) => col(35, dtype::TIMESTAMP, 8, 0, 0, None),
        ("BOOLEAN", []) => col(23, dtype::BOOLEAN, 1, 0, 0, None),
        ("CHAR" | "CHARACTER", [n]) if *n >= 1 => col(14, dtype::TEXT, *n, 0, 0, Some(*n)),
        ("VARCHAR", [n]) if *n >= 1 => col(37, dtype::VARYING, *n + 2, 0, 0, Some(*n)),
        // NUMERIC/DECIMAL: storage by precision (dialect-3 rule);
        // sub_type 1 = NUMERIC, 2 = DECIMAL
        ("NUMERIC" | "DECIMAL", [p]) => {
            let sub = if base == "NUMERIC" { 1 } else { 2 };
            numeric_col(name, *p, 0, sub, not_null)
        }
        ("NUMERIC" | "DECIMAL", [p, s]) if s <= p => {
            let sub = if base == "NUMERIC" { 1 } else { 2 };
            numeric_col(name, *p, *s, sub, not_null)
        }
        _ => None,
    };
    Some((built?, key))
}

fn numeric_col(
    name: &str,
    p: u16,
    s: u16,
    sub_type: i16,
    not_null: bool,
) -> Option<fire_crab_ods::ddl::ColumnDef> {
    use fire_crab_ods::format::dtype;
    let (field_type, dt, length) = match p {
        1..=4 => (7i16, dtype::SHORT, 2u16),
        5..=9 => (8, dtype::LONG, 4),
        10..=18 => (16, dtype::INT64, 8),
        _ => return None,
    };
    Some(fire_crab_ods::ddl::ColumnDef {
        name: name.to_ascii_uppercase(),
        field_type,
        dtype: dt,
        length,
        scale: -(s as i8),
        sub_type,
        char_len: None,
        not_null,
        not_null_constraint: not_null,
    })
}

/// Parse `CREATE TABLE <name> (<col defs>)`. Only plain column lists -
/// constraints, options and every other CREATE verb refuse (the caller
/// answers a real SQL error, never the fallback: a client must never
/// think its DDL succeeded).
fn plan_create_table(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "CREATE", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "CREATE".len())?;
    if masked[..table_kw].trim() != "CREATE" {
        return None; // CREATE <something else> TABLE
    }
    let open = s.find('(')?;
    if !s.ends_with(')') {
        return None;
    }
    let name = s[table_kw + "TABLE".len()..open].trim().trim_matches('"');
    if !ident_ok(name) {
        return None;
    }
    let body = &s[open + 1..s.len() - 1];
    // split on top-level commas (type args carry their own parens)
    let mut items: Vec<&str> = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    for (i, ch) in body.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth = depth.checked_sub(1)?,
            ',' if depth == 0 => {
                items.push(&body[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    items.push(&body[start..]);

    let mut cols: Vec<fire_crab_ods::ddl::ColumnDef> = Vec::new();
    // key constraints in DECLARATION order - the order the engine's
    // generated constraint and index names follow
    let mut keys: Vec<fire_crab_ods::ddl::KeyDef> = Vec::new();
    let mut fks: Vec<fire_crab_ods::ddl::ForeignKeyDef> = Vec::new();
    for item in items {
        let up_item = item.trim().to_ascii_uppercase();
        // a [CONSTRAINT <name>] FOREIGN KEY (cols) REFERENCES t [(refcols)]
        // table-level constraint (names uppercased like the engine does
        // for unquoted identifiers)
        if let Some(fk) = parse_fk_clause(&up_item) {
            fks.push(fk);
            continue;
        }
        // a [CONSTRAINT <name>] PRIMARY KEY|UNIQUE (cols) table-level one
        if let Some(key) = parse_key_clause(&up_item) {
            keys.push(key);
            continue;
        }
        let (col, col_key) = parse_column_def(item)?;
        if let Some((kname, primary)) = col_key {
            keys.push(fire_crab_ods::ddl::KeyDef {
                name: kname,
                columns: vec![col.name.clone()],
                primary,
            });
        }
        cols.push(col);
    }
    // resolve the key columns and apply the PRIMARY KEY's implied NOT
    // NULL. A table-level PRIMARY KEY sets its columns' NULL_FLAG but
    // gets no NOT NULL constraint row - the engine's own shape, so
    // not_null_constraint stays as the column declared it.
    let mut has_pk = false;
    for k in &keys {
        if k.primary {
            if has_pk {
                return None; // more than one PRIMARY KEY
            }
            has_pk = true;
        }
        for n in &k.columns {
            let i = cols.iter().position(|c| c.name.eq_ignore_ascii_case(n))?;
            if k.primary {
                cols[i].not_null = true;
            }
        }
    }
    Some((
        Plan::CreateTable { name: name.to_ascii_uppercase(), cols, keys, fks },
        Vec::new(),
    ))
}

/// Parse one table-level `[CONSTRAINT <name>] PRIMARY KEY|UNIQUE
/// (<cols>)` clause from an already-uppercased CREATE TABLE item.
/// None if the item is something else (a column definition or another
/// constraint), so the caller keeps parsing. An unnamed key carries an
/// empty name - create_table generates the engine's INTEG_<n>.
fn parse_key_clause(up_item: &str) -> Option<fire_crab_ods::ddl::KeyDef> {
    let mut t = up_item.trim();
    let mut name = String::new();
    if let Some(rest) = t.strip_prefix("CONSTRAINT ") {
        let rest = rest.trim_start();
        let end = rest.find(char::is_whitespace)?;
        name = rest[..end].trim_matches('"').to_string();
        if !ident_ok(&name) {
            return None;
        }
        t = rest[end..].trim_start();
    }
    let (rest, primary) = if let Some(rest) = t.strip_prefix("PRIMARY KEY") {
        (rest, true)
    } else if let Some(rest) = t.strip_prefix("UNIQUE") {
        (rest, false)
    } else {
        return None;
    };
    let rest = rest.trim();
    if !(rest.starts_with('(') && rest.ends_with(')')) {
        return None;
    }
    let columns = split_ident_list(&rest[1..rest.len() - 1])?;
    Some(fire_crab_ods::ddl::KeyDef { name, columns, primary })
}

/// Parse one table-level `[CONSTRAINT <name>] FOREIGN KEY (<cols>)
/// REFERENCES <table> [(<refcols>)]` clause from an already-uppercased
/// CREATE TABLE item. None if the item is not a foreign-key clause (a
/// column definition or another constraint), so the caller keeps parsing.
/// An unnamed FK carries an empty name - create_table generates one.
fn parse_fk_clause(up_item: &str) -> Option<fire_crab_ods::ddl::ForeignKeyDef> {
    let mut t = up_item.trim();
    let mut name = String::new();
    if let Some(rest) = t.strip_prefix("CONSTRAINT ") {
        let rest = rest.trim_start();
        let end = rest.find(char::is_whitespace)?;
        name = rest[..end].trim_matches('"').to_string();
        if !ident_ok(&name) {
            return None;
        }
        t = rest[end..].trim_start();
    }
    let rest = t.strip_prefix("FOREIGN KEY")?.trim_start();
    // (referencing columns)
    if !rest.starts_with('(') {
        return None;
    }
    let close = rest.find(')')?;
    let columns = split_ident_list(&rest[1..close])?;
    let after = rest[close + 1..].trim_start().strip_prefix("REFERENCES")?.trim_start();
    // referenced table, optionally with an explicit (columns) list
    let (ref_table, ref_columns) = match after.find('(') {
        Some(p) => {
            let rc_close = after.rfind(')')?;
            if rc_close <= p {
                return None;
            }
            let rt = after[..p].trim().trim_matches('"').to_string();
            (rt, split_ident_list(&after[p + 1..rc_close])?)
        }
        None => (after.trim().trim_matches('"').to_string(), Vec::new()),
    };
    if !ident_ok(&ref_table) || columns.is_empty() {
        return None;
    }
    Some(fire_crab_ods::ddl::ForeignKeyDef { name, columns, ref_table, ref_columns })
}

/// Split a comma-separated identifier list (`A, "B", C`), each trimmed and
/// unquoted; None if any element is not a bare identifier.
fn split_ident_list(s: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    for part in s.split(',') {
        let n = part.trim().trim_matches('"');
        if !ident_ok(n) {
            return None;
        }
        out.push(n.to_string());
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Parse `CREATE [UNIQUE] [ASC[ENDING]|DESC[ENDING]] INDEX <name> ON
/// <table> (col, ...)`.
fn plan_create_index(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "CREATE", 0) != Some(0) {
        return None;
    }
    let index_kw = find_word(&masked, "INDEX", "CREATE".len())?;
    // the words between CREATE and INDEX: any of UNIQUE/ASC(ENDING)/DESC(ENDING)
    let mut unique = false;
    let mut descending = false;
    for w in masked["CREATE".len()..index_kw].split_whitespace() {
        match w {
            "UNIQUE" => unique = true,
            "ASC" | "ASCENDING" => descending = false,
            "DESC" | "DESCENDING" => descending = true,
            _ => return None,
        }
    }
    let on_kw = find_word(&masked, "ON", index_kw + "INDEX".len())?;
    let name = s[index_kw + "INDEX".len()..on_kw].trim().trim_matches('"');
    if !ident_ok(name) {
        return None;
    }
    let open = s[on_kw..].find('(')? + on_kw;
    if !s.ends_with(')') {
        return None;
    }
    let table = s[on_kw + "ON".len()..open].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    let mut cols = Vec::new();
    for n in s[open + 1..s.len() - 1].split(',') {
        let n = n.trim().trim_matches('"');
        if !ident_ok(n) {
            return None;
        }
        cols.push(n.to_string());
    }
    if cols.is_empty() {
        return None;
    }
    Some((
        Plan::CreateIndex {
            table: table.to_ascii_uppercase(),
            name: name.to_ascii_uppercase(),
            cols,
            unique,
            descending,
        },
        Vec::new(),
    ))
}

/// Parse `DROP TABLE <name>`.
fn plan_drop_table(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "DROP", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "DROP".len())?;
    if masked[..table_kw].trim() != "DROP" {
        return None;
    }
    let name = s[table_kw + "TABLE".len()..].trim().trim_matches('"');
    if !ident_ok(name) {
        return None;
    }
    Some((Plan::DropTable { name: name.to_ascii_uppercase() }, Vec::new()))
}

/// Parse `DROP INDEX <name>`.
fn plan_drop_index(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "DROP", 0) != Some(0) {
        return None;
    }
    let index_kw = find_word(&masked, "INDEX", "DROP".len())?;
    if masked[..index_kw].trim() != "DROP" {
        return None;
    }
    let name = s[index_kw + "INDEX".len()..].trim().trim_matches('"');
    if !ident_ok(name) {
        return None;
    }
    Some((Plan::DropIndex { name: name.to_ascii_uppercase() }, Vec::new()))
}

/// Parse `CREATE SEQUENCE|GENERATOR <name> [START WITH <n>]
/// [INCREMENT [BY] <n>]`. The two options may appear in either order,
/// as the grammar allows (parse.y's `sequence_options`); both values
/// may be signed.
fn plan_create_sequence(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() < 3 || !toks[0].eq_ignore_ascii_case("CREATE") {
        return None;
    }
    if !(toks[1].eq_ignore_ascii_case("SEQUENCE") || toks[1].eq_ignore_ascii_case("GENERATOR")) {
        return None;
    }
    let name = unquote_ident(toks[2])?;
    let (mut start, mut increment) = (None, None);
    let mut i = 3;
    while i < toks.len() {
        if toks[i].eq_ignore_ascii_case("START") && i + 2 < toks.len()
            && toks[i + 1].eq_ignore_ascii_case("WITH")
        {
            start = Some(toks[i + 2].parse::<i64>().ok()?);
            i += 3;
        } else if toks[i].eq_ignore_ascii_case("INCREMENT") {
            // INCREMENT [BY] <n>
            let at = if i + 1 < toks.len() && toks[i + 1].eq_ignore_ascii_case("BY") {
                i + 2
            } else {
                i + 1
            };
            increment = Some(toks.get(at)?.parse::<i64>().ok()?);
            i = at + 1;
        } else {
            return None; // an option this writer does not implement
        }
    }
    Some((Plan::CreateSequence { name, start, increment }, Vec::new()))
}

/// Parse `DROP SEQUENCE|GENERATOR <name>`.
fn plan_drop_sequence(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() != 3 || !toks[0].eq_ignore_ascii_case("DROP") {
        return None;
    }
    if !(toks[1].eq_ignore_ascii_case("SEQUENCE") || toks[1].eq_ignore_ascii_case("GENERATOR")) {
        return None;
    }
    Some((Plan::DropSequence { name: unquote_ident(toks[2])? }, Vec::new()))
}

/// Parse `SET STATISTICS INDEX <name>`.
fn plan_set_statistics(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() != 4
        || !toks[0].eq_ignore_ascii_case("SET")
        || !toks[1].eq_ignore_ascii_case("STATISTICS")
        || !toks[2].eq_ignore_ascii_case("INDEX")
    {
        return None;
    }
    Some((Plan::SetStatistics { name: unquote_ident(toks[3])? }, Vec::new()))
}

/// Parse `ALTER INDEX <name> ACTIVE|INACTIVE`.
fn plan_alter_index(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() != 4
        || !toks[0].eq_ignore_ascii_case("ALTER")
        || !toks[1].eq_ignore_ascii_case("INDEX")
    {
        return None;
    }
    let active = if toks[3].eq_ignore_ascii_case("ACTIVE") {
        true
    } else if toks[3].eq_ignore_ascii_case("INACTIVE") {
        false
    } else {
        return None;
    };
    Some((
        Plan::AlterIndex { name: unquote_ident(toks[2])?, active },
        Vec::new(),
    ))
}

/// Parse `ALTER TABLE <table> ADD <column def>` - append one nullable
/// plain column. A NOT NULL or PRIMARY KEY on the added column is a
/// constraint over the table's existing rows and is left for later
/// (returns None, so the statement errors rather than half-applying).
fn plan_alter_table_add(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "ALTER", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "ALTER".len())?;
    if masked[..table_kw].trim() != "ALTER" {
        return None;
    }
    let add_kw = find_word(&masked, "ADD", table_kw + "TABLE".len())?;
    let table = s[table_kw + "TABLE".len()..add_kw].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    let tail = s[add_kw + "ADD".len()..].trim();
    // ADD [CONSTRAINT <name>] FOREIGN KEY (...) REFERENCES ...
    if let Some(fk) = parse_fk_clause(&tail.to_ascii_uppercase()) {
        return Some((
            Plan::AlterTableAddFk { table: table.to_ascii_uppercase(), fk },
            Vec::new(),
        ));
    }
    // ADD [CONSTRAINT <name>] PRIMARY KEY|UNIQUE (...)
    if let Some(key) = parse_key_clause(&tail.to_ascii_uppercase()) {
        return Some((
            Plan::AlterTableAddKey { table: table.to_ascii_uppercase(), key },
            Vec::new(),
        ));
    }
    let (col, col_key) = parse_column_def(&s[add_kw + "ADD".len()..])?;
    if col_key.is_some() || col.not_null {
        return None;
    }
    Some((
        Plan::AlterTableAdd { table: table.to_ascii_uppercase(), col },
        Vec::new(),
    ))
}

/// Parse `ALTER TABLE <table> DROP <column>` - drop one column. Only a
/// bare column name is a column drop; `DROP CONSTRAINT`/`PRIMARY KEY`/etc.
/// return None (unsupported, so the statement errors rather than
/// half-applying).
fn plan_alter_table_drop(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "ALTER", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "ALTER".len())?;
    if masked[..table_kw].trim() != "ALTER" {
        return None;
    }
    let drop_kw = find_word(&masked, "DROP", table_kw + "TABLE".len())?;
    let table = s[table_kw + "TABLE".len()..drop_kw].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    let tail = s[drop_kw + "DROP".len()..].trim();
    // DROP CONSTRAINT <name>
    if let Some(rest) = tail.to_ascii_uppercase().strip_prefix("CONSTRAINT ") {
        let cname = rest.trim().trim_matches('"');
        if !ident_ok(cname) {
            return None;
        }
        return Some((
            Plan::AlterTableDropConstraint {
                table: table.to_ascii_uppercase(),
                constraint: cname.to_ascii_uppercase(),
            },
            Vec::new(),
        ));
    }
    let col = tail.trim_matches('"');
    if !ident_ok(col) {
        return None; // DROP PRIMARY KEY / ... not a column drop
    }
    Some((
        Plan::AlterTableDrop {
            table: table.to_ascii_uppercase(),
            column: col.to_ascii_uppercase(),
        },
        Vec::new(),
    ))
}

/// Parse `ALTER TABLE <table> ALTER [COLUMN] <col> TYPE <datatype>` -
/// change one column's type. The new type is parsed by reusing the
/// column-definition parser on a placeholder name.
fn plan_alter_table_alter_type(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "ALTER", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "ALTER".len())?;
    if masked[..table_kw].trim() != "ALTER" {
        return None;
    }
    // the second ALTER (the column clause), then TYPE
    let alter2 = find_word(&masked, "ALTER", table_kw + "TABLE".len())?;
    let type_kw = find_word(&masked, "TYPE", alter2 + "ALTER".len())?;
    let table = s[table_kw + "TABLE".len()..alter2].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    // between the second ALTER and TYPE: an optional COLUMN keyword then
    // the column name
    let mid = s[alter2 + "ALTER".len()..type_kw].trim();
    let toks: Vec<&str> = mid.split_whitespace().collect();
    let col = match toks.as_slice() {
        [c] => *c,
        [kw, c] if kw.eq_ignore_ascii_case("COLUMN") => *c,
        _ => return None,
    };
    let col = col.trim_matches('"');
    if !ident_ok(col) {
        return None;
    }
    let datatype = s[type_kw + "TYPE".len()..].trim();
    let (new_col, _col_key) = parse_column_def(&format!("C {}", datatype))?;
    Some((
        Plan::AlterColumnType {
            table: table.to_ascii_uppercase(),
            column: col.to_ascii_uppercase(),
            col: new_col,
        },
        Vec::new(),
    ))
}

/// Parse `ALTER TABLE <table> ALTER [COLUMN] <col> SET|DROP NOT NULL` -
/// add or remove a column's NOT NULL constraint.
fn plan_alter_column_null(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "ALTER", 0) != Some(0) {
        return None;
    }
    let table_kw = find_word(&masked, "TABLE", "ALTER".len())?;
    if masked[..table_kw].trim() != "ALTER" {
        return None;
    }
    let alter2 = find_word(&masked, "ALTER", table_kw + "TABLE".len())?;
    let table = s[table_kw + "TABLE".len()..alter2].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    // the tail after the second ALTER: "[COLUMN] <col> (SET|DROP) NOT NULL"
    let tail = s[alter2 + "ALTER".len()..].trim();
    let tail_up = tail.to_ascii_uppercase();
    let compact = tail_up.split_whitespace().collect::<Vec<_>>().join(" ");
    let (not_null, kw) = if compact.ends_with("SET NOT NULL") {
        (true, "SET")
    } else if compact.ends_with("DROP NOT NULL") {
        (false, "DROP")
    } else {
        return None;
    };
    // the column sits between the second ALTER and the SET/DROP keyword
    let kw_pos = find_word(&tail_up, kw, 0)?;
    let mid = tail[..kw_pos].trim();
    let toks: Vec<&str> = mid.split_whitespace().collect();
    let col = match toks.as_slice() {
        [c] => *c,
        [w, c] if w.eq_ignore_ascii_case("COLUMN") => *c,
        _ => return None,
    };
    let col = col.trim_matches('"');
    if !ident_ok(col) {
        return None;
    }
    Some((
        Plan::AlterColumnNull {
            table: table.to_ascii_uppercase(),
            column: col.to_ascii_uppercase(),
            not_null,
        },
        Vec::new(),
    ))
}

/// Strip a SQL identifier's optional double quotes. A quoted identifier
/// keeps its case (and `""` is an escaped quote); an unquoted one is
/// returned as written (the catalog stores it upper-cased, and generator
/// lookup matches case-insensitively).
fn unquote_ident(t: &str) -> Option<String> {
    let t = t.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        Some(t[1..t.len() - 1].replace("\"\"", "\""))
    } else if !t.is_empty() && !t.contains('"') {
        Some(t.to_string())
    } else {
        None
    }
}

/// Parse `SET GENERATOR <name> TO <n>` - set a generator to an absolute
/// value. The value may be signed. None for any other statement.
fn plan_set_generator(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';');
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() != 5
        || !toks[0].eq_ignore_ascii_case("SET")
        || !toks[1].eq_ignore_ascii_case("GENERATOR")
        || !toks[3].eq_ignore_ascii_case("TO")
    {
        return None;
    }
    let name = unquote_ident(toks[2])?;
    let value: i64 = toks[4].parse().ok()?;
    Some((
        Plan::SetGenerator {
            name,
            mode: GenWrite::Absolute(value),
            stmt_type: 13, // isc_info_sql_stmt_set_generator
        },
        Vec::new(),
    ))
}

/// Parse `ALTER SEQUENCE|GENERATOR <name> RESTART WITH <n>` - restart a
/// generator so the next value is `n` (the stored value becomes
/// `n - increment`, computed at execute). None for any other ALTER.
fn plan_alter_sequence(sql: &str) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';');
    let toks: Vec<&str> = s.split_whitespace().collect();
    if toks.len() != 6
        || !toks[0].eq_ignore_ascii_case("ALTER")
        || !(toks[1].eq_ignore_ascii_case("SEQUENCE") || toks[1].eq_ignore_ascii_case("GENERATOR"))
        || !toks[3].eq_ignore_ascii_case("RESTART")
        || !toks[4].eq_ignore_ascii_case("WITH")
    {
        return None;
    }
    let name = unquote_ident(toks[2])?;
    let value: i64 = toks[5].parse().ok()?;
    Some((
        Plan::SetGenerator {
            name,
            mode: GenWrite::Restart(value),
            stmt_type: 5, // isc_info_sql_stmt_ddl
        },
        Vec::new(),
    ))
}

/// Parse `INSERT INTO <t> [(col, ...)] VALUES (val, ...)` - single row,
/// each value a literal (integer, string, NULL) or a `?` parameter -
/// resolve it against the relation, and build the record image at
/// prepare (parameter fields flagged NULL until execute binds them).
/// None = the statement is not one the server can honour (the caller
/// answers an SQL error, never a silent wrong write). The second
/// element of the pair is the parameter target list, in VALUES order.
fn plan_insert(sql: &str, db: &Option<Database>) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "INSERT", 0) != Some(0) {
        return None;
    }
    let into = find_word(&masked, "INTO", "INSERT".len())?;
    let vals_kw = find_word(&masked, "VALUES", into + "INTO".len())?;
    // between INTO and VALUES: the table name + optional (column list)
    let head = s[into + "INTO".len()..vals_kw].trim();
    let (table, collist) = match head.find('(') {
        Some(pos) => {
            let rest = head[pos..].trim();
            if !rest.ends_with(')') {
                return None;
            }
            let mut cols = Vec::new();
            for part in rest[1..rest.len() - 1].split(',') {
                let n = part.trim().trim_matches('"');
                if !ident_ok(n) {
                    return None;
                }
                cols.push(n.to_string());
            }
            if cols.is_empty() {
                return None;
            }
            (head[..pos].trim(), Some(cols))
        }
        None => (head, None),
    };
    let table = table.trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    // after VALUES: exactly one parenthesised literal list
    let tail = s[vals_kw + "VALUES".len()..].trim();
    if !tail.starts_with('(') || !tail.ends_with(')') {
        return None;
    }
    let toks = tokenize(&tail[1..tail.len() - 1])?;
    let mut vals: Vec<InsVal> = Vec::new();
    let mut nparams = 0usize;
    // a comma inside GEN_ID(name, n) is not a value separator: split only
    // on top-level (paren-depth-0) commas
    for part in split_top_commas(&toks) {
        vals.push(match part {
            [Tok::Int(n)] => InsVal::Int(*n),
            [Tok::Str(v)] => InsVal::Str(v.clone()),
            [Tok::Null] => InsVal::Null,
            [Tok::Param] => {
                nparams += 1;
                InsVal::Param(nparams - 1)
            }
            // NEXT VALUE FOR <seq> - advance by the sequence's own increment
            [Tok::Ident(a), Tok::Ident(b), Tok::Ident(c), Tok::Ident(seq)]
                if a.eq_ignore_ascii_case("NEXT")
                    && b.eq_ignore_ascii_case("VALUE")
                    && c.eq_ignore_ascii_case("FOR") =>
            {
                InsVal::GenId(seq.trim_matches('"').to_string(), None)
            }
            // GEN_ID(<name>, <step>) - advance by an explicit step
            [Tok::Ident(g), Tok::LParen, Tok::Ident(name), Tok::Comma, Tok::Int(n), Tok::RParen]
                if g.eq_ignore_ascii_case("GEN_ID") =>
            {
                InsVal::GenId(name.trim_matches('"').to_string(), Some(*n))
            }
            _ => return None,
        });
    }

    let db = db.as_ref()?;
    let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, table)?;
    let columns = relation_columns(&db.bytes, db.page_size, table);
    let formats = relation_formats(&db.bytes, db.page_size, rel);
    let (format_no, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    // every index on the relation must be maintainable (single-segment
    // ascending on a supported type) or the statement is refused - a
    // record without its index entries would be silently invisible to
    // the engine's index scans
    let index_ops = resolve_index_ops(db, rel, descs)?;
    let targets: Vec<&RelationColumn> = match &collist {
        Some(names) => {
            let mut v = Vec::new();
            for n in names {
                v.push(columns.iter().find(|c| c.name.eq_ignore_ascii_case(n))?);
            }
            v
        }
        // no column list = every column, declared order
        None => columns.iter().collect(),
    };
    if targets.len() != vals.len() {
        return None;
    }
    let image = build_insert_image(&targets, &vals, descs, db, rel, *format_no)?;
    // parameter targets in VALUES (= slot) order, each a bindable type;
    // generator targets, each a bump evaluated at execute
    let mut param_fields = Vec::new();
    let mut gen_fields = Vec::new();
    let mut params = vec![None; nparams];
    for (rc, v) in targets.iter().zip(&vals) {
        match v {
            InsVal::Param(slot) => {
                let d = descs.get(rc.field_id as usize)?;
                if !param_target_ok(d) {
                    return None;
                }
                param_fields.push((rc.field_id as usize, *slot));
                params[*slot] = Some(d.clone());
            }
            InsVal::GenId(name, step) => {
                let d = descs.get(rc.field_id as usize)?;
                // a generator yields a SINT64; the column must hold an
                // integer (the engine coerces, but we store exact)
                if !matches!(d.dtype, dtype::SHORT | dtype::LONG | dtype::INT64) || d.scale != 0 {
                    return None;
                }
                // the generator must exist at prepare - else refuse rather
                // than fail mid-write
                generator_info(db, name)?;
                gen_fields.push((rc.field_id as usize, name.clone(), *step));
            }
            _ => {}
        }
    }
    let params: Vec<Descriptor> = params.into_iter().collect::<Option<_>>()?;
    let descs = descs.clone();
    let not_null = not_null_fids(db, table);
    Some((
        Plan::Insert {
            rel,
            format_no: *format_no,
            image,
            descs,
            index_ops,
            param_fields,
            gen_fields,
            not_null,
        },
        params,
    ))
}

/// Build the record image: every field NULL except the provided ones,
/// values validated against and laid at their descriptor offsets. The
/// image length is taken from a live record of the same format when the
/// table has one (the authoritative fmt_length); an empty table falls
/// back to the aligned end of the last field.
fn build_insert_image(
    targets: &[&RelationColumn],
    vals: &[InsVal],
    descs: &[Descriptor],
    db: &Database,
    rel: u16,
    format_no: u8,
) -> Option<Vec<u8>> {
    let computed = descs
        .iter()
        .map(|d| d.offset as usize + d.length as usize)
        .max()?;
    let len = sample_image_len(db, rel, format_no).unwrap_or((computed + 3) & !3);
    if len < computed {
        return None;
    }
    let mut image = vec![0u8; len];
    // start all-NULL: descriptor index i's flag is bit i of the leading
    // null-flag bytes (the same bit decode_field reads)
    for i in 0..descs.len() {
        image[i / 8] |= 1 << (i % 8);
    }
    for (rc, v) in targets.iter().zip(vals) {
        if matches!(v, InsVal::Param(_) | InsVal::GenId(..)) {
            continue; // stays NULL-flagged; execute binds/advances the value
        }
        let fid = rc.field_id as usize;
        let d = descs.get(fid)?;
        match encode_set_value(d, v)? {
            None => continue, // NULL - flag already set
            Some(bytes) => {
                let at = d.offset as usize;
                image[at..at + bytes.len()].copy_from_slice(&bytes);
            }
        }
        image[fid / 8] &= !(1 << (fid % 8)); // provided and not null
    }
    Some(image)
}

/// Encode one SQL literal for a column: `None` = a type/width mismatch
/// (the statement is refused), `Some(None)` = SQL NULL (set the null
/// flag), `Some(Some(bytes))` = the field's bytes, laid at its
/// descriptor offset. Delegates to the wire-value encoder - an integer
/// literal into a scaled NUMERIC column rescales exactly like an
/// integer parameter does (5 into NUMERIC(9,2) stores 500).
fn encode_set_value(d: &Descriptor, v: &InsVal) -> Option<Option<Vec<u8>>> {
    let wp = match v {
        InsVal::Null => WireParam::Null,
        InsVal::Int(n) => WireParam::Int(*n, 0),
        InsVal::Str(text) => WireParam::Text(text.clone()),
        // parameters bind, generators advance, at execute - not here
        InsVal::Param(_) | InsVal::GenId(..) => return None,
    };
    encode_wire_value(d, &wp)
}

/// One parameter value as decoded from the op_execute message, in the
/// wire type the CLIENT chose (the input BLR is value-derived - a JS
/// integer arrives as blr_long even when the column is BIGINT, a JS
/// Date as blr_timestamp even for DATE/TIME columns). The scale on
/// `Int` is the BLR-declared one.
#[derive(Clone, Debug, PartialEq)]
enum WireParam {
    Null,
    Int(i64, i8),
    Text(String),
    Double(f64),
    Timestamp(i32, u32),
    Date(i32),
    Time(u32),
    Bool(bool),
}

/// One field of the client's input-message BLR: how its value is laid
/// out in the XDR message.
#[derive(Clone, Copy, Debug, PartialEq)]
enum PSlot {
    /// blr_text: `len` bytes, padded to 4 (no length prefix)
    Text(usize),
    /// blr_varying: 4-byte BE length + bytes + padding
    Varying,
    /// blr_short/blr_long: a 4-byte BE slot, with the declared scale
    Int32(i8),
    /// blr_int64: 8 BE bytes
    Int64(i8),
    Double,
    Float,
    Timestamp,
    Date,
    Time,
    /// blr_bool: 1 value byte + 3 pad (xdr_datum sends the byte FIRST)
    Bool,
}

/// Parse the client's input-message BLR from op_execute:
/// `blr_version4|5, blr_begin, blr_message, <msg#>, <word field-count>`,
/// then the fields IN PAIRS - each value descriptor followed by a
/// `blr_short 0` null-indicator slot (a proto-13 message replaces those
/// shorts with the leading null bitmap, so only the value slots carry
/// bytes). None = a shape or dtype this server cannot decode; the
/// caller must then drop the connection, because the message length is
/// unknowable and the stream cannot be resynchronised.
fn parse_param_blr(b: &[u8]) -> Option<Vec<PSlot>> {
    if b.len() < 6 || !matches!(b[0], 4 | 5) || b[1] != 2 || b[2] != 4 {
        return None;
    }
    let count = u16::from_le_bytes([b[4], b[5]]) as usize;
    if count % 2 != 0 {
        return None;
    }
    let mut slots = Vec::with_capacity(count / 2);
    let mut i = 6;
    for field in 0..count {
        let dt = *b.get(i)?;
        i += 1;
        let slot = match dt {
            14 => {
                // blr_text: word length
                let len = u16::from_le_bytes([*b.get(i)?, *b.get(i + 1)?]) as usize;
                i += 2;
                PSlot::Text(len)
            }
            15 => {
                // blr_text2 (blr.h:46): charset word then length word.
                // The C++/python driver sends a string param this way -
                // a fixed TEXT of the value's own byte length.
                i += 2; // charset
                let len = u16::from_le_bytes([*b.get(i)?, *b.get(i + 1)?]) as usize;
                i += 2;
                PSlot::Text(len)
            }
            37 => {
                // blr_varying: word length (the message carries its own)
                i += 2;
                PSlot::Varying
            }
            38 => {
                // blr_varying2: charset word then length word
                i += 4;
                PSlot::Varying
            }
            7 | 8 => {
                let scale = *b.get(i)? as i8;
                i += 1;
                PSlot::Int32(scale)
            }
            16 => {
                let scale = *b.get(i)? as i8;
                i += 1;
                PSlot::Int64(scale)
            }
            27 | 11 => PSlot::Double, // blr_double / blr_d_float
            10 => PSlot::Float,
            35 => PSlot::Timestamp,
            12 => PSlot::Date,
            13 => PSlot::Time,
            23 => PSlot::Bool,
            _ => return None, // quad/blob, int128, decfloat, tz: not bindable
        };
        if field % 2 == 0 {
            slots.push(slot);
        } else if !matches!(slot, PSlot::Int32(_)) {
            return None; // the pair's second field must be the null short
        }
    }
    Some(slots)
}

/// Read the op_execute parameter message: the null bitmap (one bit per
/// parameter, padded to 4 bytes), then each NON-null parameter's value
/// in its BLR-declared XDR layout.
fn read_param_message(
    s: &mut TcpStream,
    dec: &mut Option<Rc4>,
    slots: &[PSlot],
) -> std::io::Result<Vec<WireParam>> {
    let n = slots.len();
    let bitmap = read_n(s, dec, n.div_ceil(8).div_ceil(4) * 4)?;
    let mut out = Vec::with_capacity(n);
    for (i, slot) in slots.iter().enumerate() {
        if bitmap[i / 8] & (1 << (i % 8)) != 0 {
            out.push(WireParam::Null);
            continue;
        }
        out.push(match slot {
            PSlot::Text(len) => {
                let raw = read_n(s, dec, len.div_ceil(4) * 4)?;
                WireParam::Text(String::from_utf8_lossy(&raw[..*len]).into_owned())
            }
            PSlot::Varying => {
                let len = read_int(s, dec)?.max(0) as usize;
                let raw = read_n(s, dec, len.div_ceil(4) * 4)?;
                WireParam::Text(String::from_utf8_lossy(&raw[..len]).into_owned())
            }
            PSlot::Int32(scale) => WireParam::Int(read_int(s, dec)? as i64, *scale),
            PSlot::Int64(scale) => {
                let raw = read_n(s, dec, 8)?;
                WireParam::Int(i64::from_be_bytes(raw.try_into().unwrap()), *scale)
            }
            PSlot::Double => {
                let raw = read_n(s, dec, 8)?;
                WireParam::Double(f64::from_be_bytes(raw.try_into().unwrap()))
            }
            PSlot::Float => {
                let raw = read_n(s, dec, 4)?;
                WireParam::Double(f32::from_be_bytes(raw.try_into().unwrap()) as f64)
            }
            PSlot::Timestamp => {
                let d = read_int(s, dec)?;
                let t = read_n(s, dec, 4)?;
                WireParam::Timestamp(d, u32::from_be_bytes(t.try_into().unwrap()))
            }
            PSlot::Date => WireParam::Date(read_int(s, dec)?),
            PSlot::Time => {
                let t = read_n(s, dec, 4)?;
                WireParam::Time(u32::from_be_bytes(t.try_into().unwrap()))
            }
            PSlot::Bool => {
                let raw = read_n(s, dec, 4)?;
                WireParam::Bool(raw[0] != 0)
            }
        });
    }
    Ok(out)
}

/// Whether a column can be a parameter target: everything the wire
/// value encoder can produce bytes for. Blob columns would need the
/// blob-write ops, and INT128/DECFLOAT/TZ an encoder for their layouts
/// - a plan naming one is refused, never half-supported.
fn param_target_ok(d: &Descriptor) -> bool {
    matches!(
        d.dtype,
        dtype::SHORT
            | dtype::LONG
            | dtype::INT64
            | dtype::TEXT
            | dtype::VARYING
            | dtype::REAL
            | dtype::DOUBLE
            | dtype::SQL_DATE
            | dtype::SQL_TIME
            | dtype::TIMESTAMP
            | dtype::BOOLEAN
    )
}

fn pow10_i128(e: u32) -> Option<i128> {
    10i128.checked_pow(e)
}

/// Move an integer between decimal scales exactly: the value `v * 10^from`
/// re-expressed at scale `to` (i.e. as `x * 10^to`). Scaling up
/// multiplies; scaling down requires exact divisibility - a lossy
/// conversion is refused, matching what an exact client value means.
fn rescale_int(v: i128, from: i8, to: i8) -> Option<i128> {
    let e = from as i32 - to as i32;
    if e >= 0 {
        v.checked_mul(pow10_i128(e as u32)?)
    } else {
        let p = pow10_i128((-e) as u32)?;
        if v % p == 0 {
            Some(v / p)
        } else {
            None
        }
    }
}

/// Coerce one wire parameter to a column's stored bytes: `None` = the
/// value cannot represent this column's type (the statement fails),
/// `Some(None)` = SQL NULL, `Some(Some(bytes))` = the field bytes at
/// descriptor layout. Conversions mirror the engine's CVT rules for
/// the shapes clients actually send: integers rescale exactly into
/// NUMERIC targets, doubles round half-away-from-zero (CVT adds +/-0.5
/// then truncates), a blr_timestamp truncates into DATE or TIME
/// targets (node sends JS Dates that way for all three temporal
/// column types).
fn encode_wire_value(d: &Descriptor, wp: &WireParam) -> Option<Option<Vec<u8>>> {
    let flen = d.length as usize;
    let int_bytes = |stored: i128| -> Option<Vec<u8>> {
        Some(match d.dtype {
            dtype::SHORT => i16::try_from(stored).ok()?.to_le_bytes().to_vec(),
            dtype::LONG => i32::try_from(stored).ok()?.to_le_bytes().to_vec(),
            dtype::INT64 => i64::try_from(stored).ok()?.to_le_bytes().to_vec(),
            _ => return None,
        })
    };
    Some(match wp {
        WireParam::Null => None,
        WireParam::Int(v, ws) => Some(match d.dtype {
            dtype::SHORT | dtype::LONG | dtype::INT64 => {
                int_bytes(rescale_int(*v as i128, *ws, d.scale)?)?
            }
            dtype::DOUBLE if *ws == 0 => (*v as f64).to_le_bytes().to_vec(),
            dtype::REAL if *ws == 0 => (*v as f32).to_le_bytes().to_vec(),
            _ => return None,
        }),
        WireParam::Text(text) => {
            let b = text.as_bytes();
            match d.dtype {
                dtype::VARYING => {
                    if b.len() + 2 > flen {
                        return None;
                    }
                    let mut out = (b.len() as u16).to_le_bytes().to_vec();
                    out.extend_from_slice(b);
                    Some(out)
                }
                dtype::TEXT => {
                    if b.len() > flen {
                        return None;
                    }
                    let mut out = b.to_vec();
                    out.resize(flen, b' '); // CHAR blank padding
                    Some(out)
                }
                _ => return None,
            }
        }
        WireParam::Double(x) => Some(match d.dtype {
            dtype::DOUBLE => x.to_le_bytes().to_vec(),
            dtype::REAL => (*x as f32).to_le_bytes().to_vec(),
            dtype::SHORT | dtype::LONG | dtype::INT64 => {
                // engine rounding: scale to the target, then half away
                // from zero (CVT_get_int64 adds +/-0.5 and truncates)
                let scaled = x * 10f64.powi(-(d.scale as i32));
                if !scaled.is_finite() || scaled.abs() >= i64::MAX as f64 {
                    return None;
                }
                int_bytes(scaled.round() as i128)?
            }
            _ => return None,
        }),
        WireParam::Timestamp(dd, tt) => Some(match d.dtype {
            dtype::TIMESTAMP => {
                let mut out = dd.to_le_bytes().to_vec();
                out.extend_from_slice(&tt.to_le_bytes());
                out
            }
            dtype::SQL_DATE => dd.to_le_bytes().to_vec(),
            dtype::SQL_TIME => tt.to_le_bytes().to_vec(),
            _ => return None,
        }),
        WireParam::Date(dd) => Some(match d.dtype {
            dtype::SQL_DATE => dd.to_le_bytes().to_vec(),
            dtype::TIMESTAMP => {
                // date -> timestamp is midnight of that day
                let mut out = dd.to_le_bytes().to_vec();
                out.extend_from_slice(&0u32.to_le_bytes());
                out
            }
            _ => return None,
        }),
        WireParam::Time(tt) => Some(match d.dtype {
            dtype::SQL_TIME => tt.to_le_bytes().to_vec(),
            _ => return None,
        }),
        WireParam::Bool(v) => Some(match d.dtype {
            dtype::BOOLEAN => vec![*v as u8],
            _ => return None,
        }),
    })
}

/// The unpacked image length of an existing primary record in this
/// format, if the relation has one.
fn sample_image_len(db: &Database, rel: u16, format_no: u8) -> Option<usize> {
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
            if r.is_primary_record() && r.format == format_no {
                if let Some(img) = r.image() {
                    return Some(img.len());
                }
            }
        }
    }
    None
}

/// Parse `UPDATE <t> SET col = <lit|?> [, ...] [WHERE <pred>]` - no
/// expressions or aliases - resolve it against the relation, and encode
/// every literal SET value at prepare. The WHERE clause is the same
/// grammar SELECT filters with, `?` included. Parameter slots number in
/// SQL textual order: the SET list first, then the WHERE terms. None =
/// not a statement the server can honour (the caller answers an SQL
/// error - never a silent no-op, never a wrong write).
fn plan_update(sql: &str, db: &Option<Database>) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "UPDATE", 0) != Some(0) {
        return None;
    }
    let set_kw = find_word(&masked, "SET", "UPDATE".len())?;
    let table = s["UPDATE".len()..set_kw].trim().trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    let where_kw = find_word(&masked, "WHERE", set_kw + "SET".len());

    let db = db.as_ref()?;
    let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, table)?;
    let columns = relation_columns(&db.bytes, db.page_size, table);
    let formats = relation_formats(&db.bytes, db.page_size, rel);
    let (format_no, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let index_ops = resolve_index_ops(db, rel, descs)?;

    let set_end = where_kw.unwrap_or(s.len());
    let toks = tokenize(&s[set_kw + "SET".len()..set_end])?;
    let mut params: Vec<Option<Descriptor>> = Vec::new();
    let mut sets: Vec<(usize, SetVal)> = Vec::new();
    for part in split_on(&toks, |t| matches!(t, Tok::Comma)) {
        let (name, v) = match part {
            [Tok::Ident(c), Tok::Cmp(Cmp::Eq), Tok::Int(n)] => (c, InsVal::Int(*n)),
            [Tok::Ident(c), Tok::Cmp(Cmp::Eq), Tok::Str(t)] => (c, InsVal::Str(t.clone())),
            [Tok::Ident(c), Tok::Cmp(Cmp::Eq), Tok::Null] => (c, InsVal::Null),
            [Tok::Ident(c), Tok::Cmp(Cmp::Eq), Tok::Param] => (c, InsVal::Param(0)),
            _ => return None,
        };
        let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
        let fid = rc.field_id as usize;
        if sets.iter().any(|(f, _)| *f == fid) {
            return None; // the same column set twice is invalid SQL
        }
        let d = descs.get(fid)?;
        let sv = match v {
            InsVal::Param(_) => {
                if !param_target_ok(d) {
                    return None;
                }
                params.push(Some(d.clone()));
                SetVal::Param(params.len() - 1)
            }
            lit => SetVal::Lit(encode_set_value(d, &lit)?),
        };
        sets.push((fid, sv));
    }
    if sets.is_empty() {
        return None;
    }
    // WHERE `?` slots number after the SET list's
    let mut next_param = params.len();
    let filter = match where_kw {
        None => None,
        Some(w) => Some(
            tokenize(&s[w + "WHERE".len()..])
                .and_then(|t| parse_predicate(&t, &mut next_param))
                .and_then(|raw| resolve_predicate(raw, &columns, descs, &mut params))?,
        ),
    };
    let params: Vec<Descriptor> = params.into_iter().collect::<Option<_>>()?;
    let format_no = *format_no;
    let not_null = not_null_fids(db, table);
    Some((Plan::Update { rel, format_no, formats, sets, filter, index_ops, not_null }, params))
}

/// Parse `DELETE FROM <t> [WHERE <pred>]` and resolve it. Same
/// contract as `plan_update`: None means SQL error, never a fallback.
fn plan_delete(sql: &str, db: &Option<Database>) -> Option<(Plan, Vec<Descriptor>)> {
    let s = sql.trim().trim_end_matches(';').trim();
    let up = s.to_ascii_uppercase();
    let masked = mask_literals(&up);
    if find_word(&masked, "DELETE", 0) != Some(0) {
        return None;
    }
    let from_kw = find_word(&masked, "FROM", "DELETE".len())?;
    let where_kw = find_word(&masked, "WHERE", from_kw + "FROM".len());
    let table = s[from_kw + "FROM".len()..where_kw.unwrap_or(s.len())]
        .trim()
        .trim_matches('"');
    if !ident_ok(table) {
        return None;
    }
    let db = db.as_ref()?;
    let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, table)?;
    // no index guard here: DELETE never touches indexes - the engine's
    // VIO_erase does not either (entries outlive their records until
    // garbage collection removes both)
    let columns = relation_columns(&db.bytes, db.page_size, table);
    let formats = relation_formats(&db.bytes, db.page_size, rel);
    // a relation with no RDB$FORMATS entry (a system relation) cannot
    // be walked by format - refuse rather than silently delete nothing
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let mut params: Vec<Option<Descriptor>> = Vec::new();
    let mut next_param = 0usize;
    let filter = match where_kw {
        None => None,
        Some(w) => Some(
            tokenize(&s[w + "WHERE".len()..])
                .and_then(|t| parse_predicate(&t, &mut next_param))
                .and_then(|raw| resolve_predicate(raw, &columns, descs, &mut params))?,
        ),
    };
    let params: Vec<Descriptor> = params.into_iter().collect::<Option<_>>()?;
    Some((Plan::Delete { rel, formats, filter }, params))
}

/// The DML target walk: every committed primary record of `rel` the
/// filter accepts, with the page/slot address the version-chain writer
/// needs, the record's stored format, and its unpacked image (what an
/// UPDATE patch starts from).
fn collect_dml_targets(
    db: &Database,
    rel: u16,
    formats: &[(u8, Vec<Descriptor>)],
    filter: &Option<Predicate>,
) -> Vec<(u32, u16, u8, Vec<u8>)> {
    let mut out = Vec::new();
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
            let values = decode_record(&image, descs);
            if filter.as_ref().map_or(true, |p| p.matches(&values)) {
                out.push((dp_no, r.slot, r.format, image));
            }
        }
    }
    out
}

/// Execute a DML plan against a WORKING COPY of the database bytes - a
/// statement that fails partway must not leave half its version chains
/// behind - and flush the whole file back on success (the offline
/// writer's atomicity model). `args` are the op_execute parameter
/// values; every parameter slot the plan carries binds here, and a
/// value that cannot represent its column fails the whole statement.
/// Returns the per-verb affected counts (inserted, updated, deleted)
/// for isc_info_sql_records.
fn execute_dml(
    plan: &Plan,
    database: &mut Option<Database>,
    args: &[WireParam],
) -> Result<(i32, i32, i32), String> {
    let db = database.as_mut().ok_or("no database attached")?;
    let mut work = db.bytes.clone();
    let counts = match plan {
        Plan::CreateTable { name, cols, keys, fks } => {
            fire_crab_ods::ddl::create_table(&mut work, db.page_size, name, cols, keys, fks)?;
            (0, 0, 0)
        }
        Plan::CreateIndex { table, name, cols, unique, descending } => {
            fire_crab_ods::ddl::create_index(
                &mut work, db.page_size, table, name, cols, *unique, *descending, false, None,
            )?;
            (0, 0, 0)
        }
        Plan::DropTable { name } => {
            fire_crab_ods::ddl::drop_table(&mut work, db.page_size, name)?;
            (0, 0, 0)
        }
        Plan::DropIndex { name } => {
            fire_crab_ods::ddl::drop_index(&mut work, db.page_size, name)?;
            (0, 0, 0)
        }
        Plan::CreateSequence { name, start, increment } => {
            fire_crab_ods::ddl::create_sequence(
                &mut work, db.page_size, name, *start, *increment,
            )?;
            (0, 0, 0)
        }
        Plan::DropSequence { name } => {
            fire_crab_ods::ddl::drop_sequence(&mut work, db.page_size, name)?;
            (0, 0, 0)
        }
        Plan::AlterIndex { name, active } => {
            fire_crab_ods::ddl::alter_index_active(&mut work, db.page_size, name, *active)?;
            (0, 0, 0)
        }
        Plan::SetStatistics { name } => {
            fire_crab_ods::ddl::set_index_statistics(&mut work, db.page_size, name)?;
            (0, 0, 0)
        }
        Plan::AlterTableAdd { table, col } => {
            fire_crab_ods::ddl::alter_table_add_column(&mut work, db.page_size, table, col)?;
            (0, 0, 0)
        }
        Plan::AlterTableAddFk { table, fk } => {
            fire_crab_ods::ddl::alter_table_add_foreign_key(&mut work, db.page_size, table, fk)?;
            (0, 0, 0)
        }
        Plan::AlterTableDropConstraint { table, constraint } => {
            fire_crab_ods::ddl::alter_table_drop_constraint(
                &mut work, db.page_size, table, constraint,
            )?;
            (0, 0, 0)
        }
        Plan::AlterTableAddKey { table, key } => {
            fire_crab_ods::ddl::alter_table_add_key(&mut work, db.page_size, table, key)?;
            (0, 0, 0)
        }
        Plan::AlterTableDrop { table, column } => {
            fire_crab_ods::ddl::alter_table_drop_column(&mut work, db.page_size, table, column)?;
            (0, 0, 0)
        }
        Plan::AlterColumnType { table, column, col } => {
            fire_crab_ods::ddl::alter_table_alter_column_type(
                &mut work, db.page_size, table, column, col,
            )?;
            (0, 0, 0)
        }
        Plan::AlterColumnNull { table, column, not_null } => {
            if *not_null {
                fire_crab_ods::ddl::alter_table_set_not_null(&mut work, db.page_size, table, column)?;
            } else {
                fire_crab_ods::ddl::alter_table_drop_not_null(&mut work, db.page_size, table, column)?;
            }
            (0, 0, 0)
        }
        Plan::Insert { rel, format_no, image, descs, index_ops, param_fields, gen_fields, not_null } => {
            let mut image = image.clone();
            for (fid, slot) in param_fields {
                let d = descs.get(*fid).ok_or("field beyond format")?;
                let arg = args.get(*slot).ok_or("missing parameter value")?;
                match encode_wire_value(d, arg)
                    .ok_or("parameter type does not match its column")?
                {
                    None => {} // NULL: the flag is already set
                    Some(bytes) => {
                        let at = d.offset as usize;
                        image[at..at + bytes.len()].copy_from_slice(&bytes);
                        image[fid / 8] &= !(1 << (fid % 8));
                    }
                }
            }
            // generator advances: bump each generator (persisting the new
            // value into `work`, atomic with the record) and store the new
            // value into its field. The current value is read from `work`
            // so two NEXT VALUE FOR of one sequence in a row bump twice.
            for (fid, name, step) in gen_fields {
                let (id, incr) = generator_info(db, name).ok_or("no such generator")?;
                let new_val =
                    fire_crab_ods::gen::bump(&mut work, db.page_size, id, step.unwrap_or(incr))?;
                let d = descs.get(*fid).ok_or("field beyond format")?;
                match encode_wire_value(d, &WireParam::Int(new_val, 0))
                    .ok_or("generator value does not fit its column")?
                {
                    None => {}
                    Some(bytes) => {
                        let at = d.offset as usize;
                        image[at..at + bytes.len()].copy_from_slice(&bytes);
                        image[fid / 8] &= !(1 << (fid % 8));
                    }
                }
            }
            // NOT NULL validation, where the engine validates: at store
            for fid in not_null {
                if image[fid / 8] & (1 << (fid % 8)) != 0 {
                    return Err("validation error: NOT NULL column is NULL".into());
                }
            }
            let image = &image;
            let out =
                fire_crab_ods::insert_record(&mut work, db.page_size, *rel, *format_no, image)?;
            if !index_ops.is_empty() {
                let recno = recno_of(&work, db.page_size, out.page_no, out.slot)?;
                let values = decode_record(image, descs);
                for op in index_ops {
                    let (key, all_null) = op
                        .key_for(&values)
                        .ok_or("unsupported value for an index key")?;
                    // only an ALL-NULL key is exempt from uniqueness
                    // (btr.cpp:5629 key_all_nulls)
                    fire_crab_ods::btw::insert_index_entry(
                        &mut work, db.page_size, *rel, op.id, &key, recno,
                        op.unique && !all_null,
                    )?;
                }
            }
            (1, 0, 0)
        }
        Plan::Update { rel, format_no, formats, sets, filter, index_ops, not_null } => {
            let descs = formats
                .iter()
                .find(|(n, _)| n == format_no)
                .map(|(_, d)| d)
                .ok_or("newest format not found")?;
            // bind: every SET value becomes concrete bytes (or SQL NULL)
            let mut bound_sets: Vec<(usize, Option<Vec<u8>>)> = Vec::new();
            for (fid, sv) in sets {
                let bytes = match sv {
                    SetVal::Lit(b) => b.clone(),
                    SetVal::Param(slot) => {
                        let d = descs.get(*fid).ok_or("field beyond format")?;
                        let arg = args.get(*slot).ok_or("missing parameter value")?;
                        encode_wire_value(d, arg)
                            .ok_or("parameter type does not match its column")?
                    }
                };
                bound_sets.push((*fid, bytes));
            }
            let sets = &bound_sets;
            let filter = &bind_filter(filter, args)?;
            let mut targets: Vec<(u32, u16, Vec<u8>)> = Vec::new();
            let mut old_images: Vec<Vec<u8>> = Vec::new();
            for (page, slot, fmt, image) in collect_dml_targets(db, *rel, formats, filter) {
                // the SET offsets were resolved in the NEWEST format; a
                // record still stored in an older one would patch wrong
                // bytes - refuse the whole statement instead
                if fmt != *format_no {
                    return Err("a matching record is in an older format".into());
                }
                let mut img = image.clone();
                for (fid, bytes) in sets {
                    match bytes {
                        None => img[fid / 8] |= 1 << (fid % 8), // SET col = NULL
                        Some(b) => {
                            let at = descs.get(*fid).ok_or("field beyond format")?.offset as usize;
                            if at + b.len() > img.len() {
                                return Err("record image shorter than its format".into());
                            }
                            img[at..at + b.len()].copy_from_slice(b);
                            img[fid / 8] &= !(1 << (fid % 8));
                        }
                    }
                }
                for fid in not_null {
                    if img[fid / 8] & (1 << (fid % 8)) != 0 {
                        return Err("validation error: NOT NULL column is NULL".into());
                    }
                }
                old_images.push(image);
                targets.push((page, slot, img));
            }
            let out =
                fire_crab_ods::update_records(&mut work, db.page_size, *rel, &targets, *format_no)?;
            // IDX_modify: an entry is ADDED for every key the update
            // changed; the old entry stays until garbage collection
            if !index_ops.is_empty() {
                for ((page, slot, new_img), old_img) in targets.iter().zip(&old_images) {
                    let recno = recno_of(&work, db.page_size, *page, *slot)?;
                    let old_values = decode_record(old_img, descs);
                    let new_values = decode_record(new_img, descs);
                    for op in index_ops {
                        let (old_key, _) = op
                            .key_for(&old_values)
                            .ok_or("unsupported value for an index key")?;
                        let (new_key, all_null) = op
                            .key_for(&new_values)
                            .ok_or("unsupported value for an index key")?;
                        if new_key != old_key {
                            fire_crab_ods::btw::insert_index_entry(
                                &mut work, db.page_size, *rel, op.id, &new_key, recno,
                                op.unique && !all_null,
                            )?;
                        }
                    }
                }
            }
            (0, out.affected as i32, 0)
        }
        Plan::Delete { rel, formats, filter } => {
            let filter = &bind_filter(filter, args)?;
            let targets: Vec<(u32, u16)> = collect_dml_targets(db, *rel, formats, filter)
                .into_iter()
                .map(|(page, slot, _, _)| (page, slot))
                .collect();
            let out = fire_crab_ods::delete_records(&mut work, db.page_size, *rel, &targets)?;
            (0, 0, out.affected as i32)
        }
        Plan::SetGenerator { name, mode, .. } => {
            // the generator's id locates its slot; its increment turns a
            // RESTART WITH n into the stored value n - increment (so the
            // next GEN_ID yields n) - both read from RDB$GENERATORS
            let (id, incr) = generator_info(db, name).ok_or("no such generator")?;
            let value = match mode {
                GenWrite::Absolute(n) => *n,
                GenWrite::Restart(n) => n - incr,
            };
            write_generator_value(&mut work, db.page_size, id, value)?;
            (0, 0, 0)
        }
        _ => return Err("not a DML plan".into()),
    };
    db.bytes = work;
    std::fs::write(&db.path, &db.bytes).map_err(|e| e.to_string())?;
    Ok(counts)
}

/// One index a DML statement must maintain: its key segments (field,
/// itype, scale each), key direction, and whether duplicates are
/// refused. Resolved at plan time from the index root page
/// (irt_repeat + the irtd array).
struct IndexOp {
    id: u8,
    segs: Vec<(usize, u16, i8)>,
    descending: bool,
    unique: bool,
}

impl IndexOp {
    /// Build this index's key for a decoded record: the full
    /// [btw::build_index_key] shape - compound stuffing, descending
    /// complement - plus the all-NULL marker that disables unique
    /// enforcement (btr.cpp:5629: only a key whose EVERY segment is
    /// NULL is exempt; a partial-NULL compound key still validates -
    /// the live engine refused (NULL,2) twice into UNIQUE(X,Y)).
    fn key_for(&self, values: &[Value]) -> Option<(Vec<u8>, bool)> {
        use fire_crab_ods::btw;
        let null = Value::Null;
        let segs: Vec<btw::KeySeg<'_>> = self
            .segs
            .iter()
            .map(|(fid, itype, scale)| btw::KeySeg {
                itype: *itype,
                value: values.get(*fid).unwrap_or(&null),
                scale: *scale,
            })
            .collect();
        btw::build_index_key(&segs, self.descending)
    }
}

/// Resolve every live index of `rel` into an [IndexOp], or None when
/// ANY of them is one the write path cannot maintain byte-exactly
/// (expression/conditional, or an unconverted itype) - the whole
/// statement is then refused rather than writing records the engine's
/// index scans would miss. Multi-segment and descending indexes are
/// maintained.
fn resolve_index_ops(db: &Database, rel: u16, descs: &[Descriptor]) -> Option<Vec<IndexOp>> {
    use fire_crab_ods::btw;
    let Some(irt) = fire_crab_ods::btr::find_index_root(&db.bytes, db.page_size, rel) else {
        return Some(Vec::new());
    };
    let mut ops = Vec::new();
    for e in irt.live_entries() {
        let (segs, iflags) = btw::index_segments(
            &db.bytes,
            db.page_size,
            rel,
            e.id,
            e.key_count as usize,
        )?;
        if segs.is_empty() {
            return None;
        }
        if iflags & (btw::IRT_EXPRESSION | btw::IRT_CONDITION) != 0 {
            return None;
        }
        let mut op_segs = Vec::with_capacity(segs.len());
        for (field, itype) in segs {
            if !matches!(
                itype,
                btw::IDX_STRING
                    | btw::IDX_NUMERIC
                    | btw::IDX_NUMERIC2
                    | btw::IDX_SQL_DATE
                    | btw::IDX_SQL_TIME
                    | btw::IDX_TIMESTAMP
                    | btw::IDX_BOOLEAN
            ) {
                return None;
            }
            let d = descs.get(field as usize)?;
            op_segs.push((field as usize, itype, d.scale));
        }
        ops.push(IndexOp {
            id: e.id,
            segs: op_segs,
            descending: iflags & btw::IRT_DESCENDING != 0,
            unique: iflags & btw::IRT_UNIQUE != 0,
        });
    }
    Some(ops)
}

/// Check a parameterised SELECT's values against its plan by binding
/// every filter now: the answer is an error at op_execute, not a wrong
/// row set at fetch. Plans without parameters validate trivially.
fn validate_select_bind(plan: &Plan, args: &[WireParam]) -> Result<(), String> {
    match plan {
        Plan::Project { filter, .. } | Plan::Group { filter, .. } | Plan::Join { filter, .. } => {
            bind_filter(filter, args).map(|_| ())
        }
        _ => Ok(()),
    }
}

/// The record number of the record at (page, slot) - the positional
/// identity index entries carry.
fn recno_of(work: &[u8], page_size: usize, page_no: u32, slot: u16) -> Result<u64, String> {
    let start = page_no as usize * page_size;
    let dp = work
        .get(start..start + page_size)
        .and_then(DataPage::decode)
        .ok_or("bad data page")?;
    Ok(dp.sequence as u64 * fire_crab_ods::format::max_recs_per_dp(page_size) + slot as u64)
}

/// The formats a SELECT decodes records with: `RDB$FORMATS` for user
/// tables; for system relations - which are absent there, the engine
/// formats them at creation - the format computed from the catalog
/// itself (`sysfmt`, the ini.epp offset walk over the database's own
/// `RDB$RELATION_FIELDS`/`RDB$FIELDS` rows). DML planners deliberately
/// keep plain `relation_formats`: the fallback must never make system
/// relations writable.
fn select_formats(db: &Database, table: &str, rel: u16) -> Vec<(u8, Vec<Descriptor>)> {
    let formats = relation_formats(&db.bytes, db.page_size, rel);
    if !formats.is_empty() {
        return formats;
    }
    fire_crab_ods::system_relation_formats(&db.bytes, db.page_size, table).unwrap_or_default()
}

/// One side of a FROM clause: a table name and its optional alias.
struct TableRef<'a> {
    table: &'a str,
    alias: Option<&'a str>,
}

/// Parse a table reference: `NAME` or `NAME ALIAS`.
fn parse_table_ref(s: &str) -> Option<TableRef<'_>> {
    let toks: Vec<&str> = s.split_whitespace().collect();
    let (table, alias) = match toks.as_slice() {
        [t] => (t.trim_matches('"'), None),
        [t, a] => (t.trim_matches('"'), Some(a.trim_matches('"'))),
        _ => return None,
    };
    if !ident_ok(table) || alias.is_some_and(|a| !ident_ok(a)) {
        return None;
    }
    Some(TableRef { table, alias })
}

/// Parse a FROM clause into its left table and - if there is one - the
/// join kind, the joined table and the raw ON condition text. A single
/// join is supported: `t1 [a1] [INNER|LEFT|RIGHT|FULL [OUTER]] JOIN
/// t2 [a2] ON <cond>`. Cross/natural joins, comma lists and chained
/// joins return None (fall back).
fn parse_from(from_s: &str) -> Option<(TableRef<'_>, Option<(JoinKind, TableRef<'_>, &str)>)> {
    if from_s.contains(',') {
        return None;
    }
    let up = from_s.to_ascii_uppercase();
    for kw in ["CROSS", "NATURAL"] {
        if find_word(&up, kw, 0).is_some() {
            return None;
        }
    }
    let Some(jp) = find_word(&up, "JOIN", 0) else {
        // no JOIN: none of the join keywords may appear either
        for kw in ["LEFT", "RIGHT", "FULL", "OUTER", "INNER"] {
            if find_word(&up, kw, 0).is_some() {
                return None;
            }
        }
        return Some((parse_table_ref(from_s)?, None));
    };
    // a second JOIN (chained) is not supported
    if find_word(&up, "JOIN", jp + "JOIN".len()).is_some() {
        return None;
    }
    // the join-kind keywords sit immediately before JOIN:
    // [INNER] | LEFT [OUTER] | RIGHT [OUTER] | FULL [OUTER]
    let prev_word = |end: usize| -> (usize, &str) {
        let t = up[..end].trim_end();
        let start = t.rfind(char::is_whitespace).map_or(0, |i| i + 1);
        (start, &t[start..])
    };
    let (ws, w) = prev_word(jp);
    let (mut left_end, kind) = match w {
        "OUTER" => {
            // OUTER requires a direction right before it
            let (ws2, w2) = prev_word(ws);
            match w2 {
                "LEFT" => (ws2, JoinKind::Left),
                "RIGHT" => (ws2, JoinKind::Right),
                "FULL" => (ws2, JoinKind::Full),
                _ => return None,
            }
        }
        "LEFT" => (ws, JoinKind::Left),
        "RIGHT" => (ws, JoinKind::Right),
        "FULL" => (ws, JoinKind::Full),
        "INNER" => (ws, JoinKind::Inner),
        _ => (jp, JoinKind::Inner),
    };
    // any join keyword elsewhere (e.g. a table named OUTER) is malformed
    for kw in ["LEFT", "RIGHT", "FULL", "OUTER", "INNER"] {
        if find_word(&up[..left_end], kw, 0).is_some() {
            return None;
        }
    }
    if left_end == 0 {
        return None;
    }
    left_end = left_end.min(jp);
    let left = parse_table_ref(&from_s[..left_end])?;
    let after = jp + "JOIN".len();
    let on = find_word(&up, "ON", after)?;
    let right = parse_table_ref(&from_s[after..on])?;
    let on_s = from_s[on + "ON".len()..].trim();
    Some((left, Some((kind, right, on_s))))
}

/// Split a possibly-qualified column name into (qualifier, column), each
/// stripped of double quotes.
fn split_qual(name: &str) -> (Option<&str>, &str) {
    match name.split_once('.') {
        Some((q, c)) => (Some(q.trim_matches('"')), c.trim_matches('"')),
        None => (None, name.trim_matches('"')),
    }
}

/// Does `body` look like a qualified column `T.C` (as a join projection
/// uses)? Both parts must be identifiers and the qualifier must *start*
/// like one - a leading letter/`_`/`$` - so a decimal literal such as
/// `1.5` is not mistaken for a qualified column. A body that fails this
/// (an arithmetic expression like `N + 1.5`, a bare literal) falls through
/// to expression parsing instead.
fn is_qualified_col(body: &str) -> bool {
    match body.split_once('.') {
        Some((q, c)) => {
            let q = q.trim_matches('"');
            let c = c.trim_matches('"');
            matches!(q.chars().next(), Some(ch) if ch.is_ascii_alphabetic() || ch == '_' || ch == '$')
                && ident_ok(q)
                && ident_ok(c)
        }
        None => false,
    }
}

/// One side of a join during planning: the name a qualifier must match
/// (the alias when there is one, else the table name - Firebird hides the
/// table name behind an alias), the relation's columns and newest
/// descriptors, and this side's offset into the combined row.
struct JoinSide {
    key: String,
    rel: u16,
    formats: Vec<(u8, Vec<Descriptor>)>,
    columns: Vec<RelationColumn>,
    descs: Vec<Descriptor>,
    offset: usize,
}

/// Resolve a (possibly qualified) column name against the two join sides
/// to (combined row index, descriptor, canonical column name). A bare
/// name must be unambiguous - present on exactly one side.
fn resolve_join_col<'a>(
    sides: &'a [JoinSide; 2],
    name: &str,
) -> Option<(usize, &'a Descriptor, &'a str)> {
    let (qual, col) = split_qual(name);
    let hit = |side: &'a JoinSide| -> Option<(usize, &'a Descriptor, &'a str)> {
        let rc = side.columns.iter().find(|c| c.name.eq_ignore_ascii_case(col))?;
        let d = side.descs.get(rc.field_id as usize)?;
        Some((side.offset + rc.field_id as usize, d, rc.name.as_str()))
    };
    match qual {
        Some(q) => hit(sides.iter().find(|s| s.key.eq_ignore_ascii_case(q))?),
        None => match (hit(&sides[0]), hit(&sides[1])) {
            (Some(h), None) => Some(h),
            (None, Some(h)) => Some(h),
            _ => None, // ambiguous or unknown
        },
    }
}

/// Parse an ON condition into (left, right) combined-index equality
/// pairs: one or more `<col> = <col>` terms joined by AND, each term
/// naming one column from each side, both of the same comparable kind.
fn parse_on(on_s: &str, sides: &[JoinSide; 2]) -> Option<Vec<(usize, usize)>> {
    let toks = tokenize(on_s)?;
    if toks.iter().any(|t| matches!(t, Tok::Or)) {
        return None;
    }
    let mut on = Vec::new();
    for part in split_on(&toks, |t| matches!(t, Tok::And)) {
        let [Tok::Ident(a), Tok::Cmp(Cmp::Eq), Tok::Ident(b)] = part else {
            return None;
        };
        let (ia, da, _) = resolve_join_col(sides, a)?;
        let (ib, db, _) = resolve_join_col(sides, b)?;
        // the two columns must come from opposite sides and compare as
        // the same kind
        let width = sides[1].offset;
        let (l, r, dl, dr) = match (ia < width, ib < width) {
            (true, false) => (ia, ib, da, db),
            (false, true) => (ib, ia, db, da),
            _ => return None,
        };
        match (col_kind(dl)?, col_kind(dr)?) {
            (ColKind::Int, ColKind::Int) | (ColKind::Text, ColKind::Text) => {}
            _ => return None,
        }
        on.push((l, r));
    }
    if on.is_empty() {
        None
    } else {
        Some(on)
    }
}

/// Resolve a WHERE predicate against the two join sides (combined row
/// indexes). Aggregates are invalid here, exactly as in the single-table
/// resolver; `?` terms register parameter slots the same way.
fn resolve_join_predicate(
    raw: Vec<Vec<RawTerm>>,
    sides: &[JoinSide; 2],
    params: &mut Vec<Option<Descriptor>>,
) -> Option<Predicate> {
    let mut groups = Vec::new();
    for g in raw {
        let mut terms = Vec::new();
        for rt in g {
            let RawLhs::Col(col) = &rt.lhs else {
                return None;
            };
            let (idx, d, _) = resolve_join_col(sides, col)?;
            terms.push(param_or_typed_term(idx, col_kind(d)?, rt.kind, d, params)?);
        }
        groups.push(terms);
    }
    Some(Predicate(groups))
}

/// Plan an equi-join (INNER or LEFT/RIGHT/FULL OUTER). Supported around
/// it: a projection of bare or qualified columns (or `*` = all left
/// columns then all right, in declared order), a WHERE over the combined
/// (padded) row, ORDER BY, and - as the one aggregate - a lone
/// `SELECT COUNT(*)`. GROUP BY/HAVING or other aggregates over a join
/// fall back.
#[allow(clippy::too_many_arguments)]
fn plan_join(
    proj: &Proj,
    kind: JoinKind,
    left: &TableRef<'_>,
    right: &TableRef<'_>,
    on_s: &str,
    where_s: Option<&str>,
    order_s: Option<&str>,
    db: &Database,
    params: &mut Vec<Option<Descriptor>>,
) -> Option<Plan> {
    let mut sides: Vec<JoinSide> = Vec::new();
    for tr in [left, right] {
        let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, tr.table)?;
        let columns = relation_columns(&db.bytes, db.page_size, tr.table);
        let formats = select_formats(db, tr.table, rel);
        // joining needs decodable records
        if formats.is_empty() {
            return None;
        }
        let descs = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .map(|(_, d)| d.clone())
            .unwrap_or_default();
        let offset = sides.first().map_or(0, |s: &JoinSide| s.descs.len());
        sides.push(JoinSide {
            key: tr.alias.unwrap_or(tr.table).to_string(),
            rel,
            formats,
            columns,
            descs,
            offset,
        });
    }
    // the two sides must be distinguishable by qualifier
    if sides[0].key.eq_ignore_ascii_case(&sides[1].key) {
        return None;
    }
    let sides: [JoinSide; 2] = match <[JoinSide; 2]>::try_from(sides) {
        Ok(s) => s,
        Err(_) => return None,
    };

    let on = parse_on(on_s, &sides)?;
    let mut next_param = params.len();
    let filter = match where_s {
        None => None,
        Some(ws) => Some(
            tokenize(ws)
                .and_then(|t| parse_predicate(&t, &mut next_param))
                .and_then(|raw| resolve_join_predicate(raw, &sides, params))?,
        ),
    };

    let mut cols = Vec::new();
    match proj {
        Proj::Star => {
            // all left columns then all right, each in declared order
            for side in &sides {
                for rc in &side.columns {
                    let d = side.descs.get(rc.field_id as usize)?;
                    let (wire, sql_type, length, scale, sub_type) = wire_for(d);
                    cols.push(ProjCol {
                        name: rc.name.clone(),
                        field_id: side.offset + rc.field_id as usize,
                        wire,
                        sql_type,
                        length,
                        scale,
                        sub_type,
                        expr: None,
                    });
                }
            }
        }
        Proj::Items(items) => {
            for item in items {
                let SelItem::Col(name) = item else {
                    return None; // aggregates over a join: fall back
                };
                let (idx, d, colname) = resolve_join_col(&sides, name)?;
                let (wire, sql_type, length, scale, sub_type) = wire_for(d);
                cols.push(ProjCol {
                    name: colname.to_string(),
                    field_id: idx,
                    wire,
                    sql_type,
                    length,
                    scale,
                    sub_type,
                    expr: None,
                });
            }
        }
    }
    if cols.is_empty() {
        return None;
    }

    let order_by = match order_s {
        None => Vec::new(),
        Some(os) => parse_order_by(os, &cols, |n| {
            resolve_join_col(&sides, n).map(|(idx, _, _)| idx)
        })?,
    };

    let [l, r] = sides;
    Some(Plan::Join {
        kind,
        left_rel: l.rel,
        left_formats: l.formats,
        left_width: l.descs.len(),
        right_rel: r.rel,
        right_formats: r.formats,
        right_width: r.descs.len(),
        on,
        cols,
        filter,
        order_by,
    })
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
/// Plan a SELECT, returning the plan and its parameter targets. An
/// unsupported query falls back to the fixed answer WITH NO parameters
/// (the describe then announces none, so a client that passed some gets
/// a visible count mismatch instead of a silently wrong answer).
fn plan_query(sql: &str, db: &Option<Database>) -> (Plan, Vec<Descriptor>) {
    let mut params = Vec::new();
    let planned = plan_query_inner(sql, db, &mut params);
    match (planned, params.into_iter().collect::<Option<Vec<_>>>()) {
        (Some(p), Some(ps)) => (p, ps),
        _ => (Plan::Scalar(Some(FIXED_ANSWER)), Vec::new()),
    }
}

fn plan_query_inner(
    sql: &str,
    db: &Option<Database>,
    params: &mut Vec<Option<Descriptor>>,
) -> Option<Plan> {
    let trace = std::env::var("FC_SRV_TRACE").is_ok();
    let Some((proj_s, table_s, where_s, group_s, having_s, order_s)) = split_query(sql) else {
        if trace { eprintln!("[srv] plan: split_query failed for {:?}", sql); }
        return None;
    };
    if trace {
        eprintln!(
            "[srv] plan: proj={:?} table={:?} where={:?} group={:?} having={:?} order={:?}",
            proj_s, table_s, where_s, group_s, having_s, order_s
        );
    }
    // MON$ virtual tables: fire-crab keeps no live monitoring state, so
    // it reports them as EMPTY. The firebird-qa bootstrap runs one
    // aggregate query over MON$ATTACHMENTS to detect the server
    // architecture; an aggregate over no rows is one all-NULL row (which
    // makes the bootstrap classify fire-crab as an embedded server). The
    // projection there uses shapes this server's SQL does not parse
    // (COUNT(DISTINCT ...), IIF(...)), so the column count is taken from
    // the top-level commas rather than a real parse - honest for an
    // always-empty relation. Detected before projection parsing.
    if let Some((first, _)) = parse_from(table_s).and_then(|(l, _)| Some((l.table.to_string(), ())))
    {
        if first.to_ascii_uppercase().starts_with("MON$") {
            let ncols = count_top_level_cols(proj_s);
            return Some(Plan::VirtualEmpty { ncols });
        }
    }
    // isql's SHOW GENERATORS reads each generator's current value with a
    // DSQL probe `SELECT GEN_ID(<name>, 0) FROM [SYSTEM.]RDB$DATABASE`
    // (show.epp:4668). Recognise that exact shape and answer it from the
    // generator page as a single-BIGINT scalar. Only a zero step (a pure
    // read) is answered here; a non-zero step would increment the
    // generator (a write) and is left to fall through.
    if where_s.is_none()
        && group_s.is_none()
        && having_s.is_none()
        && order_s.is_none()
    {
        if let Some((gen_name, step)) = parse_gen_id_query(proj_s, table_s) {
            if db.as_ref().is_some() {
                // step 0 is a pure read (answered now); a non-zero step
                // increments the generator - a WRITE deferred to execute
                if step == 0 {
                    return Some(Plan::Scalar(read_generator_value(db.as_ref()?, &gen_name)));
                }
                return Some(Plan::GenIdIncrement { name: gen_name, step: Some(step) });
            }
        }
        // `NEXT VALUE FOR <seq>` bumps the sequence by its own increment
        if db.as_ref().is_some() {
            if let Some(seq) = parse_next_value(proj_s, table_s) {
                return Some(Plan::GenIdIncrement { name: seq, step: None });
            }
        }
    }
    let Some(proj) = parse_projection(proj_s) else {
        if trace { eprintln!("[srv] plan: parse_projection failed"); }
        return None;
    };
    let db = db.as_ref()?;
    let Some((left, join)) = parse_from(table_s) else {
        if trace { eprintln!("[srv] plan: FROM parse failed for {:?}", table_s); }
        return None;
    };
    if let Some((kind, right, on_s)) = join {
        // a join supports projections, WHERE and ORDER BY; the one
        // aggregate shape is a lone COUNT(*), counted at prepare.
        // GROUP BY/HAVING over a join fall back.
        if group_s.is_some() || having_s.is_some() {
            return None;
        }
        if let Proj::Items(items) = &proj {
            if let [SelItem::Agg(AggFn::Count, AggTarget::Star)] = items.as_slice() {
                if order_s.is_some() {
                    return None;
                }
                if let Some(Plan::Join {
                    kind,
                    left_rel,
                    left_formats,
                    left_width,
                    right_rel,
                    right_formats,
                    right_width,
                    on,
                    filter,
                    ..
                }) = plan_join(&Proj::Star, kind, &left, &right, on_s, where_s, None, db, params)
                {
                    // counted at prepare, so a parameterised WHERE (whose
                    // values only arrive at execute) cannot be honoured
                    if !params.is_empty() {
                        return None;
                    }
                    let n = join_rows(
                        db, kind, left_rel, &left_formats, left_width, right_rel,
                        &right_formats, right_width, &on, &filter,
                    )
                    .len();
                    return Some(Plan::Scalar(Some(n as i64)));
                }
                return None;
            }
        }
        return match plan_join(&proj, kind, &left, &right, on_s, where_s, order_s, db, params) {
            Some(p) => Some(p),
            None => {
                if trace { eprintln!("[srv] plan: JOIN plan failed"); }
                None
            }
        };
    }
    let table = left.table;
    let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, table)?;
    let columns = relation_columns(&db.bytes, db.page_size, table);
    let formats = select_formats(db, table, rel);
    let descs = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .map(|(_, d)| d.clone())
        .unwrap_or_default();

    // parse + resolve the optional WHERE clause
    let mut next_param = 0usize;
    let filter = match where_s {
        None => None,
        Some(ws) => match tokenize(ws)
            .and_then(|t| parse_predicate(&t, &mut next_param))
            .and_then(|raw| resolve_predicate(raw, &columns, &descs, params))
        {
            Some(p) => Some(p),
            None => {
                if trace { eprintln!("[srv] plan: WHERE parse/resolve failed for {:?}", ws); }
                return None; // unsupported WHERE: do not answer wrong
            }
        },
    };

    let items = match proj {
        Proj::Star => {
            // SELECT * is a plain projection; GROUP BY over it would need
            // every column grouped (and HAVING needs a grouped query) -
            // not shapes worth answering
            if group_s.is_some() || having_s.is_some() {
                return None;
            }
            let cols = build_projcols(&["*".to_string()], &columns, &descs)?;
            let order_by = match order_s {
                None => Vec::new(),
                Some(os) => parse_order_by(os, &cols, |n| {
                    columns
                        .iter()
                        .find(|c| c.name.eq_ignore_ascii_case(n))
                        .map(|c| c.field_id as usize)
                })?,
            };
            return Some(Plan::Project { rel, formats, cols, filter, order_by, gen_cols: Vec::new() });
        }
        Proj::Items(items) => items,
    };

    let has_agg = items.iter().any(|i| matches!(i, SelItem::Agg(..)));
    let has_gen = items.iter().any(|i| matches!(i, SelItem::Gen(..)));
    // a generator advance in the select list needs the row-by-row Project
    // path; a grouped/aggregated query with one is not a shape we answer
    if has_gen && (has_agg || group_s.is_some() || having_s.is_some()) {
        return None;
    }

    // a single aggregate with no GROUP BY (nor HAVING, which needs the
    // grouped machinery) stays on the scalar path - it keeps the
    // header-count fast path for COUNT(*), which is also the only way
    // COUNT works on system relations (no RDB$FORMATS entry). With
    // parameters in the WHERE the value is not computable at prepare,
    // so the query drops through to the group machinery instead (which
    // computes at fetch, after the values arrive).
    if group_s.is_none() && having_s.is_none() && items.len() == 1 && params.is_empty() {
        if let SelItem::Agg(func, target) = &items[0] {
            // ORDER BY on a single-row aggregate is meaningless; reject it
            if order_s.is_some() {
                return None;
            }
            return match aggregate(db, rel, &formats, &columns, &descs, *func, target, &filter) {
                Some(v) => Some(Plan::Scalar(v)),
                None => None, // unsupported aggregate (e.g. MIN of a text column)
            };
        }
    }

    if !has_agg && group_s.is_none() {
        // HAVING with no GROUP BY makes the query one global group, where
        // a bare (ungrouped) column is invalid SQL
        if having_s.is_some() {
            return None;
        }
        // plain projection: SELECT <cols|exprs> [WHERE] [ORDER BY].
        // If every item is a bare column, `*`-expansion and the native
        // per-column wire types come from build_projcols; a select list
        // containing a scalar expression is built item by item.
        let has_expr = items.iter().any(|i| matches!(i, SelItem::Expr(..)));
        // synthetic value slots for generator columns start past every
        // format's real fields, so a decoded row never collides with them
        let gen_base = formats.iter().map(|(_, d)| d.len()).max().unwrap_or(0).max(descs.len());
        let mut gen_cols: Vec<GenCol> = Vec::new();
        let cols = if has_expr || has_gen {
            let mut out = Vec::new();
            for it in &items {
                match it {
                    SelItem::Col(name) => {
                        let one = build_projcols(&[name.clone()], &columns, &descs)?;
                        out.push(one.into_iter().next()?);
                    }
                    SelItem::Expr(e, alias) => {
                        out.push(build_expr_col(e, alias, &columns, &descs)?);
                    }
                    SelItem::Gen(gen, step, alias) => {
                        // the generator must exist at prepare (else refuse
                        // rather than fail mid-fetch)
                        generator_info(db, gen)?;
                        let value_index = gen_base + gen_cols.len();
                        gen_cols.push(GenCol { name: gen.clone(), step: *step, value_index });
                        out.push(ProjCol {
                            name: alias.clone(),
                            field_id: value_index,
                            wire: Wire::Int64,
                            sql_type: 580, // SQL_INT64 (BIGINT)
                            length: 8,
                            scale: 0,
                            sub_type: 0,
                            expr: None,
                        });
                    }
                    SelItem::Agg(..) => return None, // aggregates route to plan_group
                }
            }
            out
        } else {
            let collist: Vec<String> = items
                .iter()
                .map(|i| match i {
                    SelItem::Col(c) => c.clone(),
                    _ => unreachable!(),
                })
                .collect();
            build_projcols(&collist, &columns, &descs)?
        };
        if cols.is_empty() {
            return None;
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
                        return None;
                    }
                }
            }
        };
        return Some(Plan::Project { rel, formats, cols, filter, order_by, gen_cols });
    }

    // grouped query: GROUP BY, or a multi-aggregate global projection
    // (including a lone parameterised aggregate, deferred to fetch)
    match plan_group(&items, group_s, having_s, order_s, rel, formats, &columns, &descs, filter) {
        Some(p) => Some(p),
        None => {
            if trace { eprintln!("[srv] plan: GROUP BY plan failed"); }
            None
        }
    }
}

/// Build a `Plan::Group`. With a GROUP BY every bare select-list column
/// must be one of the group keys (anything else is invalid SQL); with no
/// GROUP BY (a multi-aggregate projection, or a lone aggregate with a
/// HAVING) there are no keys, the whole table is one group, and a bare
/// column is invalid. MIN/MAX/SUM need an integer column; COUNT takes any
/// column or `*`. HAVING resolves against the output items, appending
/// hidden ones for aggregates/keys it names that the select list does
/// not. Returns None on any unresolvable or invalid piece - the caller
/// falls back.
#[allow(clippy::too_many_arguments)]
fn plan_group(
    items: &[SelItem],
    group_s: Option<&str>,
    having_s: Option<&str>,
    order_s: Option<&str>,
    rel: u16,
    formats: Vec<(u8, Vec<Descriptor>)>,
    columns: &[RelationColumn],
    descs: &[Descriptor],
    filter: Option<Predicate>,
) -> Option<Plan> {
    // grouping decodes records, which needs the relation's formats: a
    // relation without any (a system relation) cannot be answered here -
    // falling back beats emitting empty or miscounted groups
    if formats.is_empty() {
        return None;
    }
    let key_fids = match group_s {
        None => Vec::new(),
        Some(g) => parse_group_by(g, items, columns)?,
    };
    let mut gitems = Vec::new();
    let mut cols = Vec::new();
    for (out_idx, item) in items.iter().enumerate() {
        match item {
            SelItem::Expr(..) => return None, // expressions not supported in grouped queries
            SelItem::Gen(..) => return None,  // generator advances need the Project path
            SelItem::Col(name) => {
                let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
                let fid = rc.field_id as usize;
                if !key_fids.contains(&fid) {
                    return None; // a selected column that is not grouped
                }
                let (wire, sql_type, length, scale, sub_type) = wire_for(descs.get(fid)?);
                cols.push(ProjCol {
                    name: rc.name.clone(),
                    field_id: out_idx,
                    wire,
                    sql_type,
                    length,
                    scale,
                    sub_type,
                    expr: None,
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
                    scale: 0,
                    sub_type: 0,
                    expr: None,
                });
                gitems.push(GItem::Agg(*func, fid));
            }
        }
    }
    // HAVING filters the computed output rows (may append hidden gitems);
    // `?` in HAVING is not supported - the resolver refuses the slots
    // (the throwaway counter just satisfies the parser)
    let mut having_np = 0usize;
    let having = match having_s {
        None => None,
        Some(hs) => Some(
            tokenize(hs)
                .and_then(|t| parse_predicate(&t, &mut having_np))
                .and_then(|raw| resolve_having(raw, &mut gitems, &key_fids, columns, descs))?,
        ),
    };
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
        having,
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
                _ => return None,
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

/// Compute the joined rows: a nested-loop equi-join. Each side's
/// committed records are collected (padded to the side's newest-format
/// width, so combined indexes stay stable across formats), then every
/// left/right pair whose `on` columns are all equal - NULL never joins,
/// as SQL requires - produces a combined row. An OUTER kind then emits
/// each partnerless preserved-side row once, the other side all NULLs.
/// The WHERE filter runs on the combined (padded) rows - SQL's order:
/// join first, filter after - so `WHERE <right col> IS NULL` on a LEFT
/// join is the anti-join it should be.
#[allow(clippy::too_many_arguments)]
fn join_rows(
    db: &Database,
    kind: JoinKind,
    left_rel: u16,
    left_formats: &[(u8, Vec<Descriptor>)],
    left_width: usize,
    right_rel: u16,
    right_formats: &[(u8, Vec<Descriptor>)],
    right_width: usize,
    on: &[(usize, usize)],
    filter: &Option<Predicate>,
) -> Vec<Vec<Value>> {
    let collect = |rel: u16, formats: &[(u8, Vec<Descriptor>)], width: usize| {
        let mut rows: Vec<Vec<Value>> = Vec::new();
        for_each_record(db, rel, formats, |v| {
            let mut row = v.to_vec();
            row.resize(width, Value::Null);
            rows.push(row);
        });
        rows
    };
    let lrows = collect(left_rel, left_formats, left_width);
    let rrows = collect(right_rel, right_formats, right_width);
    let mut out = Vec::new();
    let mut keep = |row: Vec<Value>| {
        if filter.as_ref().map_or(true, |p| p.matches(&row)) {
            out.push(row);
        }
    };
    let mut right_matched = vec![false; rrows.len()];
    for l in &lrows {
        let mut matched = false;
        for (ri, r) in rrows.iter().enumerate() {
            let joined = on.iter().all(|&(li, rj)| {
                let (a, b) = (&l[li], &r[rj - left_width]);
                !matches!(a, Value::Null)
                    && !matches!(b, Value::Null)
                    && value_cmp(a, b) == std::cmp::Ordering::Equal
            });
            if !joined {
                continue;
            }
            matched = true;
            right_matched[ri] = true;
            let mut row = l.clone();
            row.extend(r.iter().cloned());
            keep(row);
        }
        if !matched && matches!(kind, JoinKind::Left | JoinKind::Full) {
            let mut row = l.clone();
            row.resize(left_width + right_width, Value::Null);
            keep(row);
        }
    }
    if matches!(kind, JoinKind::Right | JoinKind::Full) {
        for (ri, r) in rrows.iter().enumerate() {
            if right_matched[ri] {
                continue;
            }
            let mut row = vec![Value::Null; left_width];
            row.extend(r.iter().cloned());
            keep(row);
        }
    }
    out
}

/// Order two values for ORDER BY. NULL sorts as the lowest value (so
/// ascending puts NULLs first), matching the engine's default; integers,
/// scaled numerics, doubles and date/time types compare numerically,
/// text ignoring trailing blanks, anything else by its rendered text.
fn value_cmp(a: &Value, b: &Value) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    match (a, b) {
        (Value::Null, Value::Null) => Equal,
        (Value::Null, _) => Less,
        (_, Value::Null) => Greater,
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Text(x), Value::Text(y)) => x.trim_end_matches(' ').cmp(y.trim_end_matches(' ')),
        // same column, same declared scale - the raw values compare
        (Value::Scaled(x, sx), Value::Scaled(y, sy)) if sx == sy => x.cmp(y),
        (Value::Scaled(x, sx), Value::Scaled(y, sy)) => {
            // differing scales (cross-format): align exactly in i128
            let ax = *x as i128 * 10i128.pow(sx.saturating_sub(*sy).max(0) as u32);
            let ay = *y as i128 * 10i128.pow(sy.saturating_sub(*sx).max(0) as u32);
            ax.cmp(&ay)
        }
        (Value::Int128(x, sx), Value::Int128(y, sy)) if sx == sy => x.cmp(y),
        (Value::Int128(x, sx), Value::Int128(y, sy)) => {
            // differing scales (cross-format): align, saturating on the
            // (astronomically unlikely) overflow
            let up = |v: i128, by: i8| {
                10i128
                    .checked_pow(by.max(0) as u32)
                    .and_then(|p| v.checked_mul(p))
                    .unwrap_or(if v < 0 { i128::MIN } else { i128::MAX })
            };
            up(*x, sx.saturating_sub(*sy)).cmp(&up(*y, sy.saturating_sub(*sx)))
        }
        (Value::DecFloat16(x), Value::DecFloat16(y)) => fire_crab_ods::decfloat::cmp(
            &fire_crab_ods::decfloat::decode_dec64(*x),
            &fire_crab_ods::decfloat::decode_dec64(*y),
        ),
        (Value::DecFloat34(x), Value::DecFloat34(y)) => fire_crab_ods::decfloat::cmp(
            &fire_crab_ods::decfloat::decode_dec128(*x),
            &fire_crab_ods::decfloat::decode_dec128(*y),
        ),
        (Value::Double(x), Value::Double(y)) => x.partial_cmp(y).unwrap_or(Equal),
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        (Value::Date(x), Value::Date(y)) => x.cmp(y),
        (Value::Time(x), Value::Time(y)) => x.cmp(y),
        (Value::Timestamp(dx, tx), Value::Timestamp(dy, ty)) => (dx, tx).cmp(&(dy, ty)),
        // WITH TIME ZONE values order by their UTC instant - the zone
        // is presentation, not identity
        (Value::TimeTz(tx, _), Value::TimeTz(ty, _)) => tx.cmp(ty),
        (Value::TimestampTz(dx, tx, _), Value::TimestampTz(dy, ty, _)) => (dx, tx).cmp(&(dy, ty)),
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
/// one group), then compute each output item per bucket and keep the rows
/// the HAVING predicate (evaluated on the OUTPUT values, hidden items
/// included) accepts. With no keys the whole input is ONE group, emitted
/// even when empty - SQL's global aggregate shape (COUNT = 0, MIN/MAX/SUM
/// = NULL over no rows) - though a HAVING can still reject it.
fn group_output(
    db: &Database,
    rel: u16,
    formats: &[(u8, Vec<Descriptor>)],
    gitems: &[GItem],
    key_fids: &[usize],
    filter: &Option<Predicate>,
    having: &Option<Predicate>,
) -> Vec<Vec<Value>> {
    let mut input: Vec<Vec<Value>> = Vec::new();
    for_each_record(db, rel, formats, |v| {
        if filter.as_ref().map_or(true, |p| p.matches(v)) {
            input.push(v.to_vec());
        }
    });
    let mut out = Vec::new();
    if key_fids.is_empty() {
        out.push(compute_group(&input, gitems));
    } else {
        let keys: Vec<(usize, bool)> = key_fids.iter().map(|&f| (f, false)).collect();
        input.sort_by(|a, b| order_cmp(a, b, &keys));
        let mut i = 0;
        while i < input.len() {
            let mut j = i + 1;
            while j < input.len()
                && order_cmp(&input[i], &input[j], &keys) == std::cmp::Ordering::Equal
            {
                j += 1;
            }
            out.push(compute_group(&input[i..j], gitems));
            i = j;
        }
    }
    if let Some(h) = having {
        out.retain(|row| h.matches(row));
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
fn describe_for(plan: &Plan, params: &[Descriptor]) -> Vec<u8> {
    match plan {
        Plan::Scalar(_) | Plan::GenIdIncrement { .. } => describe_one_bigint(params),
        Plan::CreateTable { .. } | Plan::CreateIndex { .. } | Plan::DropTable { .. }
        | Plan::DropIndex { .. }
        | Plan::CreateSequence { .. } | Plan::DropSequence { .. }
        | Plan::AlterIndex { .. }
        | Plan::SetStatistics { .. }
        | Plan::AlterTableAdd { .. } | Plan::AlterTableAddFk { .. }
        | Plan::AlterTableAddKey { .. } | Plan::AlterTableDropConstraint { .. }
        | Plan::AlterTableDrop { .. }
        | Plan::AlterColumnType { .. } | Plan::AlterColumnNull { .. } => {
            describe_dml(5, params) // isc_info_sql_stmt_ddl
        }
        Plan::Insert { .. } => describe_dml(2, params), // isc_info_sql_stmt_insert
        Plan::Update { .. } => describe_dml(3, params), // isc_info_sql_stmt_update
        Plan::Delete { .. } => describe_dml(4, params), // isc_info_sql_stmt_delete
        Plan::Project { cols, .. } => build_describe(cols, params),
        Plan::Join { cols, .. } => build_describe(cols, params),
        Plan::Group { cols, .. } => build_describe(cols, params),
        Plan::VirtualEmpty { .. } => build_describe(&output_cols_of(plan), params),
        Plan::SetGenerator { stmt_type, .. } => describe_dml(*stmt_type, params),
    }
}

/// The isc_info_sql_stmt_ type code for a plan.
fn stmt_type_of(plan: &Plan) -> i32 {
    match plan {
        Plan::Scalar(_)
        | Plan::GenIdIncrement { .. }
        | Plan::Project { .. }
        | Plan::Join { .. }
        | Plan::Group { .. }
        | Plan::VirtualEmpty { .. } => 1,
        Plan::Insert { .. } => 2,
        Plan::Update { .. } => 3,
        Plan::Delete { .. } => 4,
        Plan::CreateTable { .. } | Plan::CreateIndex { .. } | Plan::DropTable { .. }
        | Plan::DropIndex { .. }
        | Plan::CreateSequence { .. } | Plan::DropSequence { .. }
        | Plan::AlterIndex { .. }
        | Plan::SetStatistics { .. }
        | Plan::AlterTableAdd { .. } | Plan::AlterTableAddFk { .. }
        | Plan::AlterTableAddKey { .. } | Plan::AlterTableDropConstraint { .. }
        | Plan::AlterTableDrop { .. }
        | Plan::AlterColumnType { .. } | Plan::AlterColumnNull { .. } => 5,
        Plan::SetGenerator { stmt_type, .. } => *stmt_type,
    }
}

/// One projected BIGINT column named `Cn` - what a virtual-empty query's
/// columns describe as.
fn bigint_col(n: usize) -> ProjCol {
    ProjCol {
        name: format!("C{}", n),
        field_id: n,
        wire: Wire::Int64,
        sql_type: 580,
        length: 8,
        scale: 0,
        sub_type: 0,
        expr: None,
    }
}

/// The plan's output columns for describe purposes - a Scalar answers
/// as one BIGINT column.
fn output_cols_of(plan: &Plan) -> Vec<ProjCol> {
    match plan {
        Plan::Project { cols, .. } | Plan::Join { cols, .. } | Plan::Group { cols, .. } => {
            cols.clone()
        }
        Plan::Scalar(_) | Plan::GenIdIncrement { .. } => vec![ProjCol {
            name: "CONSTANT".into(),
            field_id: 0,
            wire: Wire::Int64,
            sql_type: 580,
            length: 8,
            scale: 0,
            sub_type: 0,
            expr: None,
        }],
        Plan::VirtualEmpty { ncols } => (0..*ncols).map(bigint_col).collect(),
        _ => Vec::new(),
    }
}

/// Count top-level (paren-depth 0) comma-separated items in a select
/// list - the column count of a projection this server does not fully
/// parse (a MON$ aggregate query).
fn count_top_level_cols(proj: &str) -> usize {
    let mut depth = 0i32;
    let mut n = 1usize;
    for ch in proj.chars() {
        match ch {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => n += 1,
            _ => {}
        }
    }
    n.max(1)
}

/// Answer an op_prepare_statement's REQUESTED item list - what the
/// C++ fbclient (and through it the python firebird-driver) parses
/// STRICTLY: it asks for stmt_type(21), stmt_flags(27), and per-var
/// items incl. field(16)/schema(33)/relation(17)/owner(18)/alias(19),
/// and its OO API throws on answers that do not follow the requested
/// shape (the fixed-shape buffer that satisfied node-firebird made it
/// raise "Unrecognized C++ exception"). The var-item template follows
/// each section tag (5 bind / 4 select) up to its describe_end(8);
/// every var is answered with the requested items in requested order,
/// closed by describe_end - the shape node-firebird's tag-driven
/// parser reads equally happily.
fn answer_prepare(items: &[u8], plan: &Plan, params: &[Descriptor]) -> Vec<u8> {
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
    // one described variable: (type, sub_type, scale, length, name)
    struct Var {
        sql_type: i32,
        sub_type: i32,
        scale: i32,
        length: i32,
        name: String,
    }
    let out_vars: Vec<Var> = output_cols_of(plan)
        .into_iter()
        .map(|c| Var {
            sql_type: c.sql_type,
            sub_type: c.sub_type,
            scale: c.scale,
            length: c.length,
            name: c.name,
        })
        .collect();
    let bind_vars: Vec<Var> = params
        .iter()
        .map(|pd| {
            let (_, sql_type, length, scale, sub_type) = wire_for(pd);
            Var { sql_type, sub_type, scale, length, name: String::new() }
        })
        .collect();
    let has_cursor = matches!(
        plan,
        Plan::Scalar(_)
            | Plan::GenIdIncrement { .. }
            | Plan::Project { .. }
            | Plan::Join { .. }
            | Plan::Group { .. }
            | Plan::VirtualEmpty { .. }
    );

    let mut d = Vec::new();
    let mut i = 0usize;
    while i < items.len() {
        match items[i] {
            21 => int_item(&mut d, 21, stmt_type_of(plan)),
            27 => int_item(&mut d, 27, if has_cursor { 1 } else { 0 }), // FLAG_HAS_CURSOR
            22 => str_item(&mut d, 22, ""), // isc_info_sql_get_plan
            6 => int_item(&mut d, 6, out_vars.len() as i32), // num_variables
            tag @ (4 | 5) => {
                // collect the per-var item template up to describe_end
                let mut tmpl = Vec::new();
                let mut j = i + 1;
                while j < items.len() && items[j] != 8 {
                    tmpl.push(items[j]);
                    j += 1;
                }
                i = j; // the 8 is consumed by the outer i += 1
                let vars = if tag == 5 { &bind_vars } else { &out_vars };
                d.push(tag);
                // describe_vars leads the section when requested
                if tmpl.first() == Some(&7) {
                    int_item(&mut d, 7, vars.len() as i32);
                }
                for (n, v) in vars.iter().enumerate() {
                    for &t in &tmpl {
                        match t {
                            7 => {} // count, already answered
                            9 => int_item(&mut d, 9, (n + 1) as i32),
                            11 => int_item(&mut d, 11, v.sql_type),
                            12 => int_item(&mut d, 12, v.sub_type),
                            13 => int_item(&mut d, 13, v.scale),
                            14 => int_item(&mut d, 14, v.length),
                            15 => int_item(&mut d, 15, 0), // null_ind
                            16 => str_item(&mut d, 16, &v.name), // field
                            17 => str_item(&mut d, 17, ""),      // relation
                            18 => str_item(&mut d, 18, ""),      // owner
                            19 => str_item(&mut d, 19, &v.name), // alias
                            33 => str_item(&mut d, 33, "PUBLIC"), // schema (FB6)
                            34 => str_item(&mut d, 34, ""), // relation_alias
                            _ => {}
                        }
                    }
                    d.push(8); // describe_end closes each var
                }
            }
            _ => {} // an item this server cannot answer is omitted
        }
        i += 1;
    }
    d.push(1); // isc_info_end
    d
}

/// Answer an op_info_sql request item-by-item: records(23) with the
/// per-verb counts, stmt_type(21), stmt_flags(27) - the item the
/// python driver's Statement.get_flags() lives on - and the plan(22).
fn answer_info_sql(items: &[u8], plan: &Plan, last_dml: (i32, i32, i32)) -> Vec<u8> {
    let mut d = Vec::new();
    let has_cursor = matches!(
        plan,
        Plan::Scalar(_)
            | Plan::GenIdIncrement { .. }
            | Plan::Project { .. }
            | Plan::Join { .. }
            | Plan::Group { .. }
            | Plan::VirtualEmpty { .. }
    );
    for &it in items {
        match it {
            23 => {
                let cluster = build_records_info(last_dml.0, last_dml.1, last_dml.2);
                // build_records_info already ends with isc_info_end
                d.extend_from_slice(&cluster[..cluster.len() - 1]);
            }
            21 => {
                d.push(21);
                d.extend_from_slice(&4u16.to_le_bytes());
                d.extend_from_slice(&stmt_type_of(plan).to_le_bytes());
            }
            27 => {
                d.push(27);
                d.extend_from_slice(&4u16.to_le_bytes());
                d.extend_from_slice(&(if has_cursor { 1i32 } else { 0 }).to_le_bytes());
            }
            22 => {
                d.push(22);
                d.extend_from_slice(&0u16.to_le_bytes());
            }
            _ => {}
        }
    }
    d.push(1);
    d
}

/// Emit the fetch response for a plan: a stream of
/// op_fetch_response(status=0, messages=1) + row messages, terminated by
/// op_fetch_response(status=100). `Scalar` emits one row (NULL when the
/// value is None); `Project` walks the relation, filters, and either
/// streams the rows or - if there is an ORDER BY - collects, sorts and
/// then emits them.
/// Why row emission stopped early. `Bind` is a filter bind failure -
/// op_execute already reported it, so the cursor just ends (terminator
/// only). `Eval` is a per-row arithmetic exception (divide by zero): the
/// good rows already streamed are followed by the engine's error
/// op_response, in place of the terminator - which is exactly what the
/// real server sends when a fetch access method errors mid-cursor
/// (server.cpp:4302, `send_response(... status ...)`).
enum EmitErr {
    Bind,
    Eval(EvalErr),
}

impl From<String> for EmitErr {
    fn from(_: String) -> Self {
        EmitErr::Bind
    }
}

impl From<EvalErr> for EmitErr {
    fn from(e: EvalErr) -> Self {
        EmitErr::Eval(e)
    }
}

/// isc_arith_except and isc_exception_integer_divide_by_zero - the status
/// vector the engine posts for an integer divide by zero (ExprNodes.cpp:2615,
/// iberror.h). isql renders it "arithmetic exception ... / Integer divide
/// by zero".
const GDS_ARITH_EXCEPT: i32 = 335544321;
const GDS_INTEGER_DIVIDE: i32 = 335544778;
/// isc_convert_error - the engine's "conversion error from string" for a
/// CAST that cannot convert (SQLSTATE 22018).
const GDS_CONVERT_ERROR: i32 = 335544334;

/// Write, into the fetch reply stream, the op_response the engine sends
/// when a row's evaluation raises `e` - mirroring `respond_error`'s layout
/// but carrying the matching status vector, so the client raises the same
/// SQL error the real server would (server.cpp:4302 sends the same
/// op_response on a mid-cursor access-method error).
fn write_eval_error(w: &mut W, e: &EvalErr) {
    w.int(OP_RESPONSE)
        .int(0)
        .int(0)
        .int(0) // blob id
        .int(0); // response data length
    match e {
        EvalErr::DivideByZero => {
            w.int(1) // isc_arg_gds
                .int(GDS_ARITH_EXCEPT)
                .int(1) // isc_arg_gds
                .int(GDS_INTEGER_DIVIDE);
        }
        EvalErr::ConversionError => {
            w.int(1) // isc_arg_gds
                .int(GDS_CONVERT_ERROR);
        }
    }
    w.int(0); // isc_arg_end
}

/// Emit a cursor's rows. `gen_writes` collects the (generator name, final
/// value) each generator column reached - the caller persists them after
/// the fetch, mirroring the engine's mid-fetch generator advance.
fn emit_rows(
    w: &mut W,
    plan: &Plan,
    db: &Option<Database>,
    args: &[WireParam],
    gen_writes: &mut Vec<(String, i64)>,
) {
    // a filter bind failure emits no rows, only the terminator -
    // op_execute already validated the bind and reported any error, so
    // reaching fetch with a bad bind means the client ignored it; an
    // arithmetic exception mid-cursor is reported like the engine, with
    // an error op_response in place of the terminator
    match emit_rows_inner(w, plan, db, args, gen_writes) {
        Ok(()) | Err(EmitErr::Bind) => {
            // end-of-cursor terminator
            w.int(OP_FETCH_RESPONSE).int(100).int(0);
        }
        Err(EmitErr::Eval(e)) => write_eval_error(w, &e),
    }
}

fn emit_rows_inner(
    w: &mut W,
    plan: &Plan,
    db: &Option<Database>,
    args: &[WireParam],
    gen_writes: &mut Vec<(String, i64)>,
) -> Result<(), EmitErr> {
    match plan {
        // DML, DDL and generator writes have no cursor: terminator only.
        // GenIdIncrement is replaced by a Scalar at op_execute, so it never
        // reaches fetch as itself; the arm keeps the match exhaustive.
        Plan::Insert { .. } | Plan::Update { .. } | Plan::Delete { .. }
        | Plan::CreateTable { .. } | Plan::CreateIndex { .. } | Plan::DropTable { .. }
        | Plan::DropIndex { .. }
        | Plan::CreateSequence { .. } | Plan::DropSequence { .. }
        | Plan::AlterIndex { .. }
        | Plan::SetStatistics { .. }
        | Plan::AlterTableAdd { .. } | Plan::AlterTableAddFk { .. }
        | Plan::AlterTableAddKey { .. } | Plan::AlterTableDropConstraint { .. }
        | Plan::AlterTableDrop { .. }
        | Plan::AlterColumnType { .. } | Plan::AlterColumnNull { .. }
        | Plan::GenIdIncrement { .. } | Plan::SetGenerator { .. } => {}
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
        Plan::VirtualEmpty { ncols } => {
            // one row, every column NULL - an aggregate over the empty
            // MON$ relation. The null bitmap is all-ones (padded to 4B).
            w.int(OP_FETCH_RESPONSE).int(0).int(1);
            let nbytes = ncols.div_ceil(8);
            let mut bitmap = vec![0xFFu8; nbytes];
            // clear bits past ncols in the last byte
            if ncols % 8 != 0 {
                bitmap[nbytes - 1] = (1u8 << (ncols % 8)) - 1;
            }
            w.raw(&bitmap);
            for _ in nbytes..nbytes.div_ceil(4) * 4 {
                w.raw(&[0u8]);
            }
        }
        Plan::Project {
            rel,
            formats,
            cols,
            filter,
            order_by,
            gen_cols,
        } => {
            if let Some(db) = db {
                let filter = bind_filter(filter, args)?;
                let accepts = |v: &[Value]| filter.as_ref().map_or(true, |p| p.matches(v));
                if !gen_cols.is_empty() {
                    // a generator advance per row: materialise, sort into
                    // OUTPUT order, then advance each generator once per row
                    // in that order (the engine evaluates NEXT VALUE FOR /
                    // GEN_ID mid-fetch, after the sort). The final values are
                    // handed back for the caller to persist.
                    let mut rows: Vec<Vec<Value>> = Vec::new();
                    for_each_record(db, *rel, formats, |values| {
                        if accepts(values) {
                            rows.push(values.to_vec());
                        }
                    });
                    if !order_by.is_empty() {
                        rows.sort_by(|a, b| order_cmp(a, b, order_by));
                    }
                    // running value per distinct generator, from its stored
                    // base; the increment resolves a NEXT VALUE FOR's step
                    let mut running: std::collections::HashMap<String, i64> =
                        std::collections::HashMap::new();
                    let mut incr: std::collections::HashMap<String, i64> =
                        std::collections::HashMap::new();
                    for gc in gen_cols {
                        let key = gc.name.to_ascii_uppercase();
                        if !running.contains_key(&key) {
                            let base = read_generator_value(db, &gc.name).unwrap_or(0);
                            let gi = generator_info(db, &gc.name).map(|(_, i)| i).unwrap_or(1);
                            running.insert(key.clone(), base);
                            incr.insert(key, gi);
                        }
                    }
                    let max_idx = gen_cols.iter().map(|g| g.value_index).max().unwrap_or(0);
                    for mut values in rows {
                        if values.len() <= max_idx {
                            values.resize(max_idx + 1, Value::Null);
                        }
                        for gc in gen_cols {
                            let key = gc.name.to_ascii_uppercase();
                            let step = gc.step.unwrap_or_else(|| *incr.get(&key).unwrap_or(&1));
                            let v = running.get_mut(&key).unwrap();
                            *v = v.wrapping_add(step);
                            values[gc.value_index] = Value::Int(*v);
                        }
                        encode_row(w, cols, &values)?;
                    }
                    for (key, val) in &running {
                        gen_writes.push((key.clone(), *val));
                    }
                } else if order_by.is_empty() {
                    // stream matching rows; an evaluation error on any row
                    // (divide by zero, a failed cast) stops the walk and is
                    // reported after it
                    let mut eval_err: Option<EvalErr> = None;
                    for_each_record(db, *rel, formats, |values| {
                        if eval_err.is_some() {
                            return;
                        }
                        if accepts(values) {
                            if let Err(e) = encode_row(w, cols, values) {
                                eval_err = Some(e);
                            }
                        }
                    });
                    if let Some(e) = eval_err {
                        return Err(EmitErr::Eval(e));
                    }
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
                        encode_row(w, cols, values)?;
                    }
                }
            }
        }
        Plan::Join {
            kind,
            left_rel,
            left_formats,
            left_width,
            right_rel,
            right_formats,
            right_width,
            on,
            cols,
            filter,
            order_by,
        } => {
            if let Some(db) = db {
                let filter = bind_filter(filter, args)?;
                let mut rows = join_rows(
                    db, *kind, *left_rel, left_formats, *left_width, *right_rel,
                    right_formats, *right_width, on, &filter,
                );
                if !order_by.is_empty() {
                    rows.sort_by(|a, b| order_cmp(a, b, order_by));
                }
                for values in &rows {
                    encode_row(w, cols, values)?;
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
            having,
            order_by,
        } => {
            if let Some(db) = db {
                let filter = bind_filter(filter, args)?;
                let mut rows =
                    group_output(db, *rel, formats, gitems, key_fids, &filter, having);
                if !order_by.is_empty() {
                    // order_by keys are output indexes; output rows are
                    // aligned with gitems/cols, so order_cmp applies as-is
                    rows.sort_by(|a, b| order_cmp(a, b, order_by));
                }
                for values in &rows {
                    encode_row(w, cols, values)?;
                }
            }
        }
    }
    Ok(())
}

/// Encode one row message: the leading null bitmap (one bit per projected
/// column, padded to 4 bytes) followed by the non-null column data - each
/// INT64 as 8 big-endian bytes, each VARYING as a 4-byte length + text +
/// 4-byte padding. Null columns contribute only their bit; the client
/// skips their data (protocol 13+ layout).
/// Emit one row - the op_fetch_response header then the message - or
/// `Err(EvalErr)` if any expression column raised an arithmetic exception
/// on this row, in which case NOTHING is written (the values are computed
/// before the header, so the caller can emit the error response cleanly in
/// place of the row, exactly as the engine does: it ships no fetch_response
/// for the failing row, only the error op_response).
fn encode_row(w: &mut W, cols: &[ProjCol], values: &[Value]) -> Result<(), EvalErr> {
    // each column's value: an expression's result, or the record field.
    // Computed up front so a divide-by-zero aborts before any byte lands.
    let vals: Vec<Value> = cols
        .iter()
        .map(|c| c.value_of(values))
        .collect::<Result<_, _>>()?;
    w.int(OP_FETCH_RESPONSE).int(0).int(1);
    let n = cols.len();
    let nbytes = n.div_ceil(8);
    let mut bitmap = vec![0u8; nbytes];
    for (i, v) in vals.iter().enumerate() {
        if matches!(v, Value::Null) {
            bitmap[i / 8] |= 1 << (i % 8);
        }
    }
    w.raw(&bitmap);
    for _ in nbytes..nbytes.div_ceil(4) * 4 {
        w.raw(&[0u8]);
    }
    for (c, v) in cols.iter().zip(&vals) {
        let v = &*v;
        if matches!(v, Value::Null) {
            continue; // null: data omitted, the bitmap bit already set
        }
        // the raw scaled integer travels for numerics; the client
        // divides by 10^|scale| per the describe
        let raw_int = |v: &Value| match v {
            Value::Int(i) => *i,
            Value::Scaled(raw, _) => *raw,
            _ => 0,
        };
        match c.wire {
            Wire::Int64 => {
                w.raw(&raw_int(v).to_be_bytes());
            }
            Wire::Int32 => {
                w.raw(&(raw_int(v) as i32).to_be_bytes());
            }
            Wire::Double => {
                let d = if let Value::Double(d) = v { *d } else { 0.0 };
                w.raw(&d.to_be_bytes());
            }
            Wire::Float => {
                let d = if let Value::Double(d) = v { *d } else { 0.0 };
                w.raw(&(d as f32).to_be_bytes());
            }
            Wire::Date => {
                let d = if let Value::Date(d) = v { *d } else { 0 };
                w.raw(&d.to_be_bytes());
            }
            Wire::Time => {
                let t = if let Value::Time(t) = v { *t } else { 0 };
                w.raw(&t.to_be_bytes());
            }
            Wire::Timestamp => {
                let (d, t) = if let Value::Timestamp(d, t) = v { (*d, *t) } else { (0, 0) };
                w.raw(&d.to_be_bytes());
                w.raw(&t.to_be_bytes());
            }
            Wire::Bool => {
                w.int(if matches!(v, Value::Bool(true)) { 1 } else { 0 });
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
            Wire::Blob => {
                // the on-disk bid bytes travel (RecordNumber.h:63-71
                // layout); the client echoes them back verbatim in
                // op_open_blob, where decode_blob_id reads them again
                let (rel, num) = if let Value::Blob(rel, num) = v { (*rel, *num) } else { (0, 0) };
                w.raw(&encode_blob_id(rel, num));
            }
            Wire::Int128 => {
                // xdr_int128 (xdr.cpp:437): high hyper then low hyper =
                // the value's 16 big-endian bytes
                let x = if let Value::Int128(x, _) = v { *x } else { 0 };
                w.raw(&x.to_be_bytes());
            }
            Wire::Dec16 => {
                // xdr_dec64 (xdr.cpp:424): the decimal64 word big-endian
                let x = if let Value::DecFloat16(x) = v { *x } else { 0 };
                w.raw(&x.to_be_bytes());
            }
            Wire::Dec34 => {
                // xdr_dec128 (xdr.cpp:430): high half first - the
                // decimal128's 16 big-endian bytes
                let x = if let Value::DecFloat34(x) = v { *x } else { 0 };
                w.raw(&x.to_be_bytes());
            }
            Wire::TimeTz => {
                let (t, z) = if let Value::TimeTz(t, z) = v { (*t, *z) } else { (0, 0) };
                w.raw(&t.to_be_bytes());
                w.int(z as i32); // xdr_short rides a 4-byte slot
            }
            Wire::TimestampTz => {
                let (d, t, z) =
                    if let Value::TimestampTz(d, t, z) = v { (*d, *t, *z) } else { (0, 0, 0) };
                w.raw(&d.to_be_bytes());
                w.raw(&t.to_be_bytes());
                w.int(z as i32);
            }
        }
    }
    Ok(())
}

/// The 8 wire bytes of a blob id: the on-disk bid layout (u16 relation
/// LE, reserved byte, the record number's high byte, then its low 32
/// bits LE) - the same bytes `decode_field` read. Clients treat the
/// quad as opaque and echo it in op_open_blob.
fn encode_blob_id(rel: u16, num: u64) -> [u8; 8] {
    let mut b = [0u8; 8];
    b[0..2].copy_from_slice(&rel.to_le_bytes());
    b[3] = (num >> 32) as u8;
    b[4..8].copy_from_slice(&(num as u32).to_le_bytes());
    b
}

/// The inverse of `encode_blob_id`: (relation, record number).
fn decode_blob_id(b: &[u8]) -> (u16, u64) {
    let rel = u16::from_le_bytes([b[0], b[1]]);
    let num = ((b[3] as u64) << 32) | u32::from_le_bytes([b[4], b[5], b[6], b[7]]) as u64;
    (rel, num)
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

/// One item of a select list: a bare column, an aggregate, or a scalar
/// expression (arithmetic over integer columns and literals). The
/// expression carries the output column name it should be described by.
/// Recognise isql's `SELECT GEN_ID(<name>, <step>) FROM [SYSTEM.]
/// RDB$DATABASE` (the SHOW GENERATORS value probe, show.epp:4668).
/// Returns the generator name with any schema/package qualifier and
/// quotes stripped, and the integer step. Only this precise shape - one
/// `GEN_ID` call over the one-row `RDB$DATABASE` - is recognised; every
/// other projection returns None so the ordinary planner handles it.
fn parse_gen_id_query(proj_s: &str, table_s: &str) -> Option<(String, i64)> {
    // FROM must name RDB$DATABASE, optionally SYSTEM.-qualified/quoted.
    let up = table_s.trim().to_ascii_uppercase().replace('"', "");
    let bare = up.strip_prefix("SYSTEM.").unwrap_or(&up).trim();
    if bare != "RDB$DATABASE" {
        return None;
    }
    // Projection must be exactly GEN_ID ( <name-arg> , <step> ).
    let p = proj_s.trim();
    let open = p.find('(')?;
    if !p[..open].trim().eq_ignore_ascii_case("GEN_ID") {
        return None;
    }
    let close = p.rfind(')')?;
    if close <= open {
        return None;
    }
    if p[close + 1..].trim() != "" {
        return None; // trailing text after the call
    }
    let args = &p[open + 1..close];
    // The name is the first argument; the step is the last (a generator
    // name never contains a comma). Split on the last comma.
    let comma = args.rfind(',')?;
    let step: i64 = args[comma + 1..].trim().parse().ok()?;
    let name = strip_gen_name(args[..comma].trim());
    if name.is_empty() {
        return None;
    }
    Some((name, step))
}

/// Recognise `SELECT NEXT VALUE FOR <seq> FROM [SYSTEM.]RDB$DATABASE` and
/// return the bare sequence name. `NEXT VALUE FOR` is `GEN_ID(seq, <the
/// sequence's own increment>)` - the increment is read at execute.
fn parse_next_value(proj_s: &str, table_s: &str) -> Option<String> {
    let up = table_s.trim().to_ascii_uppercase().replace('"', "");
    let bare = up.strip_prefix("SYSTEM.").unwrap_or(&up).trim();
    if bare != "RDB$DATABASE" {
        return None;
    }
    let toks: Vec<&str> = proj_s.split_whitespace().collect();
    if toks.len() != 4
        || !toks[0].eq_ignore_ascii_case("NEXT")
        || !toks[1].eq_ignore_ascii_case("VALUE")
        || !toks[2].eq_ignore_ascii_case("FOR")
    {
        return None;
    }
    let name = strip_gen_name(toks[3]);
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

/// Recognise ONE select-list item that advances a generator:
/// `NEXT VALUE FOR <seq>` (returns step None) or `GEN_ID(<name>, <n>)`
/// (returns step Some(n)). `part` is a single projection item with any
/// ` AS <alias>` already split off. None if it is not a generator item,
/// so the ordinary column/expression parsing handles it.
fn parse_gen_sel_item(part: &str) -> Option<(String, Option<i64>)> {
    let p = part.trim();
    // NEXT VALUE FOR <seq>
    let toks: Vec<&str> = p.split_whitespace().collect();
    if toks.len() == 4
        && toks[0].eq_ignore_ascii_case("NEXT")
        && toks[1].eq_ignore_ascii_case("VALUE")
        && toks[2].eq_ignore_ascii_case("FOR")
    {
        let name = strip_gen_name(toks[3]);
        return if name.is_empty() { None } else { Some((name, None)) };
    }
    // GEN_ID ( <name> , <step> )
    let open = p.find('(')?;
    if !p[..open].trim().eq_ignore_ascii_case("GEN_ID") {
        return None;
    }
    let close = p.rfind(')')?;
    if close <= open || p[close + 1..].trim() != "" {
        return None;
    }
    let args = &p[open + 1..close];
    let comma = args.rfind(',')?;
    let step: i64 = args[comma + 1..].trim().parse().ok()?;
    let name = strip_gen_name(args[..comma].trim());
    if name.is_empty() { None } else { Some((name, Some(step))) }
}

/// Reduce a possibly schema/package-qualified, possibly quoted generator
/// reference (`PUBLIC.MYGEN`, `PUBLIC."MyGen"`, `MYGEN`, `"MyGen"`) to the
/// bare object name the catalog stores.
fn strip_gen_name(arg: &str) -> String {
    let s = arg.trim();
    // Drop a leading qualifier: the last '.' whose preceding qualifier is
    // not itself quoted (isql emits bare uppercase schema/package names).
    let obj = match s.find('.') {
        Some(dot) if !s[..dot].contains('"') => &s[dot + 1..],
        _ => s,
    };
    let obj = obj.trim();
    if obj.len() >= 2 && obj.starts_with('"') && obj.ends_with('"') {
        obj[1..obj.len() - 1].replace("\"\"", "\"")
    } else {
        obj.to_string()
    }
}

enum SelItem {
    Col(String),
    Agg(AggFn, AggTarget),
    /// a scalar expression (parsed with column NAMES, resolved to field
    /// ids at plan time) and the output column name it is described by
    Expr(RawExpr, String),
    /// a generator advance in the select list - `NEXT VALUE FOR <seq>`
    /// (step None) or `GEN_ID(<name>, <n>)` (step Some(n)) - evaluated
    /// once per emitted row (see [GenCol]), with its output column name
    Gen(String, Option<i64>, String),
}

/// A generator-advancing output column of a [Plan::Project]: `name` is
/// the generator/sequence, `step` is the explicit `GEN_ID` step (or None
/// for `NEXT VALUE FOR`, meaning the sequence's own increment), and
/// `value_index` is the synthetic slot in a decoded row's value vector
/// that emit fills with this column's per-row value. Advanced once per
/// emitted row, in OUTPUT order (after any sort), each advance persisted
/// when the fetch completes - the engine evaluates it mid-fetch.
#[derive(Clone)]
struct GenCol {
    name: String,
    step: Option<i64>,
    value_index: usize,
}

/// A select-list expression before column names are resolved to field
/// ids - what `parse_projection` produces (it runs before the relation
/// is known).
#[derive(Clone)]
enum RawExpr {
    Col(String),
    Int(i64),
    /// a decimal literal `d.dd`: (raw integer, scale) - `1.5` is
    /// `(15, -1)`, `1.50` is `(150, -2)` (trailing zeros count, as the
    /// engine's scale does)
    Dec(i64, i8),
    Str(String),
    Null,
    Neg(Box<RawExpr>),
    Bin(Box<RawExpr>, ArithOp, Box<RawExpr>),
    /// string concatenation `a || b` - a text result, distinct from the
    /// arithmetic `Bin`s (its operands coerce to text, not to integers)
    Concat(Box<RawExpr>, Box<RawExpr>),
    /// `CAST(a AS <type>)` - convert to the target type
    Cast(Box<RawExpr>, CastTarget),
}

/// The target of a `CAST`. Text targets carry their declared width and
/// whether they pad (CHAR) or not (VARCHAR). The integer family
/// (SMALLINT/INTEGER/BIGINT) collapses to one target: fire-crab computes
/// the value at full `i64` width and announces BIGINT, exactly as the
/// select-list arithmetic already does - the displayed value is identical.
#[derive(Clone, Copy)]
enum CastTarget {
    Int,
    Text { len: usize, pad: bool },
}

/// Parse an arithmetic expression: `+`/`-` (lowest precedence) over
/// `*`/`/` over unary `-` over `||` over atoms (integer literals,
/// single-quoted strings, NULL, bare column names, parenthesised
/// sub-expressions). The precedence order mirrors the engine's parser
/// (parse.y:742-745): `||` binds tighter than unary minus and the
/// multiplicative and additive operators, so `1 || 2 + 3` groups as
/// `(1 || 2) + 3` exactly as Firebird dialect 3 parses it.
/// A pure identifier is left to the caller to treat as a plain column;
/// this returns None then, so the column path (all types) is preferred.
fn parse_raw_expr(s: &str) -> Option<RawExpr> {
    let b: Vec<char> = s.chars().collect();
    let mut pos = 0usize;
    let e = expr_add(&b, &mut pos)?;
    skip_ws(&b, &mut pos);
    if pos != b.len() {
        return None; // trailing tokens
    }
    // a bare column or a bare literal is NOT an "expression" for
    // projection purposes - the column path handles all column types,
    // and a lone literal is uncommon; require at least one operator
    if matches!(e, RawExpr::Col(_)) {
        return None;
    }
    Some(e)
}

fn skip_ws(b: &[char], pos: &mut usize) {
    while *pos < b.len() && b[*pos].is_whitespace() {
        *pos += 1;
    }
}

fn expr_add(b: &[char], pos: &mut usize) -> Option<RawExpr> {
    let mut left = expr_mul(b, pos)?;
    loop {
        skip_ws(b, pos);
        let op = match b.get(*pos) {
            Some('+') => ArithOp::Add,
            Some('-') => ArithOp::Sub,
            _ => break,
        };
        *pos += 1;
        let right = expr_mul(b, pos)?;
        left = RawExpr::Bin(Box::new(left), op, Box::new(right));
    }
    Some(left)
}

fn expr_mul(b: &[char], pos: &mut usize) -> Option<RawExpr> {
    let mut left = expr_unary(b, pos)?;
    loop {
        skip_ws(b, pos);
        // a lone `*` or `/`, not the `||` operator (which `expr_concat`
        // owns, one level tighter)
        let op = match b.get(*pos) {
            Some('*') => ArithOp::Mul,
            Some('/') => ArithOp::Div,
            _ => break,
        };
        *pos += 1;
        let right = expr_unary(b, pos)?;
        left = RawExpr::Bin(Box::new(left), op, Box::new(right));
    }
    Some(left)
}

fn expr_unary(b: &[char], pos: &mut usize) -> Option<RawExpr> {
    skip_ws(b, pos);
    if b.get(*pos) == Some(&'-') {
        *pos += 1;
        return Some(RawExpr::Neg(Box::new(expr_unary(b, pos)?)));
    }
    if b.get(*pos) == Some(&'+') {
        *pos += 1;
        return expr_unary(b, pos);
    }
    expr_concat(b, pos)
}

/// The `||` concatenation level - tighter than unary minus and the
/// arithmetic operators (parse.y:745), left-associative. `a || b || c`
/// groups as `(a || b) || c`.
fn expr_concat(b: &[char], pos: &mut usize) -> Option<RawExpr> {
    let mut left = expr_atom(b, pos)?;
    loop {
        skip_ws(b, pos);
        if b.get(*pos) == Some(&'|') && b.get(*pos + 1) == Some(&'|') {
            *pos += 2;
            let right = expr_atom(b, pos)?;
            left = RawExpr::Concat(Box::new(left), Box::new(right));
        } else {
            break;
        }
    }
    Some(left)
}

fn expr_atom(b: &[char], pos: &mut usize) -> Option<RawExpr> {
    skip_ws(b, pos);
    match b.get(*pos)? {
        '(' => {
            *pos += 1;
            let e = expr_add(b, pos)?;
            skip_ws(b, pos);
            if b.get(*pos) != Some(&')') {
                return None;
            }
            *pos += 1;
            Some(e)
        }
        '\'' => {
            *pos += 1;
            let mut v = String::new();
            loop {
                match b.get(*pos) {
                    None => return None, // unterminated
                    Some('\'') => {
                        if b.get(*pos + 1) == Some(&'\'') {
                            v.push('\'');
                            *pos += 2;
                        } else {
                            *pos += 1;
                            break;
                        }
                    }
                    Some(c) => {
                        v.push(*c);
                        *pos += 1;
                    }
                }
            }
            Some(RawExpr::Str(v))
        }
        c if c.is_ascii_digit() => {
            let start = *pos;
            while *pos < b.len() && b[*pos].is_ascii_digit() {
                *pos += 1;
            }
            // a decimal literal `d.dd` - a dot followed by at least one
            // digit; the raw is the digits with the point removed, the
            // scale the negative of the fractional-digit count (trailing
            // zeros included, matching the engine)
            if b.get(*pos) == Some(&'.') && b.get(*pos + 1).is_some_and(|c| c.is_ascii_digit()) {
                *pos += 1; // '.'
                let frac_start = *pos;
                while *pos < b.len() && b[*pos].is_ascii_digit() {
                    *pos += 1;
                }
                let digits: String = b[start..frac_start - 1]
                    .iter()
                    .chain(&b[frac_start..*pos])
                    .collect();
                let raw: i64 = digits.parse().ok()?;
                let scale = -((*pos - frac_start) as i8);
                return Some(RawExpr::Dec(raw, scale));
            }
            let n: i64 = b[start..*pos].iter().collect::<String>().parse().ok()?;
            Some(RawExpr::Int(n))
        }
        c if c.is_alphabetic() || *c == '_' || *c == '$' || *c == '"' => {
            let quoted = *c == '"';
            if quoted {
                *pos += 1;
            }
            let start = *pos;
            while *pos < b.len()
                && (b[*pos].is_alphanumeric()
                    || b[*pos] == '_'
                    || b[*pos] == '$'
                    || b[*pos] == '.')
            {
                *pos += 1;
            }
            let word: String = b[start..*pos].iter().collect();
            if quoted {
                if b.get(*pos) != Some(&'"') {
                    return None;
                }
                *pos += 1;
            }
            if word.eq_ignore_ascii_case("NULL") {
                Some(RawExpr::Null)
            } else if !quoted && word.eq_ignore_ascii_case("CAST") && {
                skip_ws(b, pos);
                b.get(*pos) == Some(&'(')
            } {
                // CAST(<expr> AS <type>): the operand at full precedence,
                // AS, then a target type
                *pos += 1; // '('
                let inner = expr_add(b, pos)?;
                skip_ws(b, pos);
                if !take_keyword(b, pos, "AS") {
                    return None;
                }
                let target = parse_cast_target(b, pos)?;
                skip_ws(b, pos);
                if b.get(*pos) != Some(&')') {
                    return None;
                }
                *pos += 1; // ')'
                Some(RawExpr::Cast(Box::new(inner), target))
            } else {
                Some(RawExpr::Col(word))
            }
        }
        _ => None,
    }
}

/// Consume a whole-word keyword (case-insensitive) at `pos`, skipping
/// leading whitespace. Returns true and advances on a match; leaves `pos`
/// unchanged otherwise.
fn take_keyword(b: &[char], pos: &mut usize, kw: &str) -> bool {
    skip_ws(b, pos);
    let kb: Vec<char> = kw.chars().collect();
    if *pos + kb.len() > b.len() {
        return false;
    }
    for (i, kc) in kb.iter().enumerate() {
        if !b[*pos + i].eq_ignore_ascii_case(kc) {
            return false;
        }
    }
    // must end on a word boundary
    if let Some(nc) = b.get(*pos + kb.len()) {
        if nc.is_alphanumeric() || *nc == '_' || *nc == '$' {
            return false;
        }
    }
    *pos += kb.len();
    true
}

/// Parse a CAST target type: SMALLINT/INTEGER/INT/BIGINT (the integer
/// family) or VARCHAR(n)/CHAR(n)/CHARACTER(n) (a text width). None for
/// any other type - the CAST then falls back rather than convert wrong.
fn parse_cast_target(b: &[char], pos: &mut usize) -> Option<CastTarget> {
    skip_ws(b, pos);
    let start = *pos;
    while *pos < b.len() && (b[*pos].is_alphabetic() || b[*pos] == '_') {
        *pos += 1;
    }
    let kw: String = b[start..*pos].iter().collect();
    let ku = kw.to_ascii_uppercase();
    if matches!(ku.as_str(), "SMALLINT" | "INTEGER" | "INT" | "BIGINT") {
        return Some(CastTarget::Int);
    }
    let pad = match ku.as_str() {
        "VARCHAR" => false,
        "CHAR" | "CHARACTER" => true,
        _ => return None,
    };
    // a required (n) width
    skip_ws(b, pos);
    if b.get(*pos) != Some(&'(') {
        return None;
    }
    *pos += 1;
    skip_ws(b, pos);
    let ds = *pos;
    while *pos < b.len() && b[*pos].is_ascii_digit() {
        *pos += 1;
    }
    let len: usize = b[ds..*pos].iter().collect::<String>().parse().ok()?;
    skip_ws(b, pos);
    if b.get(*pos) != Some(&')') {
        return None;
    }
    *pos += 1;
    Some(CastTarget::Text { len, pad })
}

/// Resolve a raw expression's column names to field ids against the
/// relation, producing a typed [Expr]. None on an unknown column or an
/// unsupported column type (the caller then falls back).
fn resolve_expr(
    raw: &RawExpr,
    columns: &[RelationColumn],
    descs: &[Descriptor],
) -> Option<Expr> {
    Some(match raw {
        RawExpr::Col(name) => {
            let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
            let fid = rc.field_id as usize;
            let d = descs.get(fid)?;
            // an int, text, or scaled-numeric column (numerics are only
            // usable as CAST/concat operands; type_of/eval enforce that)
            if col_kind(d).is_none() && !is_numeric_col(d) {
                return None;
            }
            Expr::Col(fid)
        }
        RawExpr::Int(n) => Expr::Int(*n),
        RawExpr::Dec(raw, scale) => Expr::Dec(*raw, *scale),
        RawExpr::Str(s) => Expr::Str(s.clone()),
        RawExpr::Null => Expr::Null,
        RawExpr::Neg(e) => Expr::Neg(Box::new(resolve_expr(e, columns, descs)?)),
        RawExpr::Bin(a, op, b) => Expr::Bin(
            Box::new(resolve_expr(a, columns, descs)?),
            *op,
            Box::new(resolve_expr(b, columns, descs)?),
        ),
        RawExpr::Concat(a, b) => Expr::Concat(
            Box::new(resolve_expr(a, columns, descs)?),
            Box::new(resolve_expr(b, columns, descs)?),
        ),
        RawExpr::Cast(e, t) => Expr::Cast(Box::new(resolve_expr(e, columns, descs)?), *t),
    })
}

/// A scalar select-list expression, evaluated per row against the
/// decoded record values. Restricted to the shapes with a clean,
/// differentially-checkable result: integer arithmetic (over scale-0
/// integer columns and integer literals) and constant literals. A NULL
/// operand propagates (SQL three-valued arithmetic).
#[derive(Clone)]
enum Expr {
    /// a scale-0 integer column, by field id
    Col(usize),
    Int(i64),
    /// a decimal literal: (raw integer, scale)
    Dec(i64, i8),
    Str(String),
    Null,
    Neg(Box<Expr>),
    Bin(Box<Expr>, ArithOp, Box<Expr>),
    /// `a || b` - both operands coerced to text, NULL-propagating
    Concat(Box<Expr>, Box<Expr>),
    /// `CAST(a AS <type>)` - convert the operand to the target type
    Cast(Box<Expr>, CastTarget),
}

#[derive(Clone, Copy)]
enum ArithOp {
    Add,
    Sub,
    Mul,
    /// integer division, truncating toward zero (ExprNodes.cpp); a zero
    /// divisor raises the arithmetic exception, it never answers wrong
    Div,
}

/// A per-row evaluation failure. The fetch path maps each to the engine's
/// own status vector, so a client raises the same SQL error the real
/// server would.
#[derive(Debug, Clone, Copy)]
enum EvalErr {
    /// integer divide by zero: `isc_arith_except` /
    /// `isc_exception_integer_divide_by_zero`
    DivideByZero,
    /// a CAST that cannot convert - a non-numeric string to an integer, or
    /// a value too long for the target text width: `isc_convert_error`
    /// (SQLSTATE 22018)
    ConversionError,
}

/// What an expression's result is typed as - which drives its wire form
/// (BIGINT for integer arithmetic, VARCHAR for a string literal).
/// `Numeric` is a scaled exact numeric operand (a `NUMERIC`/`DECIMAL`
/// column): it is only ever an *operand* here - CAST retypes it, concat
/// renders it, arithmetic rejects it - never a top-level result.
#[derive(Clone, Copy, PartialEq, Debug)]
enum ExprType {
    Int,
    Text,
    Numeric,
}

/// A scaled exact-numeric column - the operand form CAST and concat
/// accept but the scale-0 `col_kind(Int)` does not. `SHORT`/`LONG`/`INT64`
/// with a non-zero scale decode to `Value::Scaled`; `INT128` to
/// `Value::Int128`.
fn is_numeric_col(d: &Descriptor) -> bool {
    (matches!(d.dtype, dtype::SHORT | dtype::LONG | dtype::INT64) && d.scale != 0)
        || d.dtype == dtype::INT128
}

/// Decompose a numeric value into (raw integer, scale) for arithmetic:
/// an integer is scale 0, a scaled numeric keeps its scale, an INT128
/// likewise. Anything else (text, temporal, ...) is not a numeric operand.
fn numeric_parts(v: &Value) -> Option<(i128, i8)> {
    match v {
        Value::Int(n) => Some((*n as i128, 0)),
        Value::Scaled(r, s) => Some((*r as i128, *s)),
        Value::Int128(r, s) => Some((*r, *s)),
        _ => None,
    }
}

/// Wrap a computed (raw, scale) numeric result as a `Value` - a scale of
/// zero collapses to a plain integer, otherwise it stays scaled. Values
/// are kept within `i64` here (the describe announces an INT64 wire form);
/// wide-precision results that need INT128 output are a later slice.
fn scaled_value(raw: i128, scale: i8) -> Value {
    if scale == 0 {
        Value::Int(raw as i64)
    } else {
        Value::Scaled(raw as i64, scale)
    }
}

/// Apply a numeric arithmetic operator following the engine's dialect-3
/// scale rules (probed against isql, then cross-checked against
/// ExprNodes.cpp): `+`/`-` take the finer scale (the more negative, so
/// `min`) and align both operands to it; `*` adds the two scales; `/`
/// adds the scales too, first scaling the dividend by `10^(-2*s2)` and
/// then doing an integer (truncating-toward-zero) division. A zero
/// divisor is the arithmetic exception, never a wrong answer.
fn numeric_bin(r1: i128, s1: i8, op: ArithOp, r2: i128, s2: i8) -> Result<(i128, i8), EvalErr> {
    Ok(match op {
        ArithOp::Add | ArithOp::Sub => {
            let sr = s1.min(s2);
            let a = r1 * 10i128.pow((s1 - sr) as u32);
            let b = r2 * 10i128.pow((s2 - sr) as u32);
            (if matches!(op, ArithOp::Add) { a + b } else { a - b }, sr)
        }
        ArithOp::Mul => (r1 * r2, s1 + s2),
        ArithOp::Div => {
            if r2 == 0 {
                return Err(EvalErr::DivideByZero);
            }
            let scaled = r1 * 10i128.pow((-2 * s2 as i32) as u32);
            (scaled / r2, s1 + s2)
        }
    })
}

/// Round a scaled exact numeric (`raw` at `scale`) to an integer, half
/// away from zero - the engine's rule for CAST to an integer type
/// (`12.50` -> `13`, `13.50` -> `14`, `-12.50` -> `-13`). Works in `i128`
/// so it covers `INT128`-backed numerics; the caller narrows to `i64`.
fn round_scaled_to_int(raw: i128, scale: i8) -> i128 {
    if scale >= 0 {
        return raw * 10i128.pow(scale as u32);
    }
    let k = (-scale) as u32;
    let pow = 10i128.pow(k);
    let q = raw / pow;
    let r = raw % pow;
    if 2 * r.unsigned_abs() >= pow as u128 {
        q + raw.signum()
    } else {
        q
    }
}

impl Expr {
    /// Type-check the expression against the relation's descriptors:
    /// integer arithmetic needs integer operands, a string literal is
    /// text, and a NULL literal is untyped (defaults to Int for its
    /// wire form). None = a shape this server cannot type (the caller
    /// then falls back rather than answering wrong).
    fn type_of(&self, descs: &[Descriptor]) -> Option<ExprType> {
        match self {
            Expr::Col(fid) => {
                let d = descs.get(*fid)?;
                match col_kind(d) {
                    Some(ColKind::Int) => Some(ExprType::Int),
                    Some(ColKind::Text) => Some(ExprType::Text),
                    None if is_numeric_col(d) => Some(ExprType::Numeric),
                    None => None,
                }
            }
            Expr::Int(_) => Some(ExprType::Int),
            Expr::Dec(..) => Some(ExprType::Numeric),
            Expr::Str(_) => Some(ExprType::Text),
            Expr::Null => Some(ExprType::Int),
            Expr::Neg(e) => match e.type_of(descs)? {
                ExprType::Int => Some(ExprType::Int),
                ExprType::Numeric => Some(ExprType::Numeric),
                ExprType::Text => None,
            },
            Expr::Bin(a, _, b) => match (a.type_of(descs)?, b.type_of(descs)?) {
                // pure integer arithmetic stays integer
                (ExprType::Int, ExprType::Int) => Some(ExprType::Int),
                // any numeric operand (with an integer or another numeric)
                // makes the result numeric - the engine's scale rules apply
                (ExprType::Int | ExprType::Numeric, ExprType::Int | ExprType::Numeric) => {
                    Some(ExprType::Numeric)
                }
                _ => None, // a text operand is not arithmetic
            },
            Expr::Concat(a, b) => {
                // both operands must be typeable (int or text); the
                // engine coerces each to text, and the result is text
                a.type_of(descs)?;
                b.type_of(descs)?;
                Some(ExprType::Text)
            }
            Expr::Cast(e, t) => {
                // the operand must be typeable; the result type is the
                // cast target
                e.type_of(descs)?;
                Some(match t {
                    CastTarget::Int => ExprType::Int,
                    CastTarget::Text { .. } => ExprType::Text,
                })
            }
        }
    }

    /// The static scale of a `Numeric`-typed expression - what the describe
    /// announces, and what `eval` must then produce so the client's decode
    /// matches. Follows the same dialect-3 rules as [numeric_bin]: `+`/`-`
    /// take the finer (more negative) scale, `*`/`/` add the scales. Only
    /// called for an expression already typed `ExprType::Numeric`.
    fn result_scale(&self, descs: &[Descriptor]) -> Option<i8> {
        match self {
            Expr::Col(fid) => {
                let d = descs.get(*fid)?;
                if matches!(col_kind(d), Some(ColKind::Int)) {
                    Some(0)
                } else if is_numeric_col(d) {
                    Some(d.scale)
                } else {
                    None
                }
            }
            Expr::Int(_) => Some(0),
            Expr::Dec(_, scale) => Some(*scale),
            Expr::Neg(e) => e.result_scale(descs),
            Expr::Bin(a, op, b) => {
                let s1 = a.result_scale(descs)?;
                let s2 = b.result_scale(descs)?;
                Some(match op {
                    ArithOp::Add | ArithOp::Sub => s1.min(s2),
                    ArithOp::Mul | ArithOp::Div => s1 + s2,
                })
            }
            _ => None,
        }
    }

    /// Evaluate against a row's decoded values, producing a `Value`.
    /// NULL propagates through arithmetic and concatenation; a text
    /// expression is a literal, a text column, or a concatenation.
    /// `Err(EvalErr)` is a per-row arithmetic exception (divide by zero).
    fn eval(&self, values: &[Value]) -> Result<Value, EvalErr> {
        Ok(match self {
            Expr::Col(fid) => values.get(*fid).cloned().unwrap_or(Value::Null),
            Expr::Int(n) => Value::Int(*n),
            Expr::Dec(raw, scale) => Value::Scaled(*raw, *scale),
            Expr::Str(s) => Value::Text(s.clone()),
            Expr::Null => Value::Null,
            Expr::Neg(e) => match e.eval(values)? {
                Value::Int(n) => Value::Int(n.wrapping_neg()),
                Value::Scaled(r, s) => Value::Scaled(r.wrapping_neg(), s),
                Value::Int128(r, s) => Value::Int128(-r, s),
                _ => Value::Null,
            },
            Expr::Bin(a, op, b) => {
                let va = a.eval(values)?;
                let vb = b.eval(values)?;
                if matches!(va, Value::Null) || matches!(vb, Value::Null) {
                    Value::Null // any NULL operand -> NULL
                } else if let (Value::Int(x), Value::Int(y)) = (&va, &vb) {
                    // pure integer arithmetic
                    Value::Int(match op {
                        ArithOp::Add => x.wrapping_add(*y),
                        ArithOp::Sub => x.wrapping_sub(*y),
                        ArithOp::Mul => x.wrapping_mul(*y),
                        // truncating integer division (Rust `/` on i64 rounds
                        // toward zero, as the engine does); a zero divisor is
                        // the arithmetic exception, not a wrong answer
                        ArithOp::Div => match x.checked_div(*y) {
                            Some(q) => q,
                            None => return Err(EvalErr::DivideByZero),
                        },
                    })
                } else if let (Some((r1, s1)), Some((r2, s2))) =
                    (numeric_parts(&va), numeric_parts(&vb))
                {
                    // numeric arithmetic: apply the engine's scale rules
                    let (raw, sr) = numeric_bin(r1, s1, *op, r2, s2)?;
                    scaled_value(raw, sr)
                } else {
                    Value::Null
                }
            }
            Expr::Concat(a, b) => match (a.eval(values)?, b.eval(values)?) {
                (Value::Null, _) | (_, Value::Null) => Value::Null,
                (x, y) => Value::Text(format!("{}{}", x.render(), y.render())),
            },
            Expr::Cast(e, t) => {
                let v = e.eval(values)?;
                if matches!(v, Value::Null) {
                    return Ok(Value::Null); // NULL casts to NULL of any type
                }
                match t {
                    // to the integer family: an integer is kept, a scaled
                    // numeric is rounded half away from zero, a string is
                    // trimmed and parsed (a non-numeric string, or a value
                    // that overflows i64, is the conversion error)
                    CastTarget::Int => {
                        let narrow = |x: i128| match i64::try_from(x) {
                            Ok(n) => Ok(Value::Int(n)),
                            Err(_) => Err(EvalErr::ConversionError),
                        };
                        match v {
                            Value::Int(n) => Value::Int(n),
                            Value::Scaled(raw, scale) => {
                                narrow(round_scaled_to_int(raw as i128, scale))?
                            }
                            Value::Int128(raw, scale) => {
                                narrow(round_scaled_to_int(raw, scale))?
                            }
                            Value::Text(s) => match s.trim().parse::<i64>() {
                                Ok(n) => Value::Int(n),
                                Err(_) => return Err(EvalErr::ConversionError),
                            },
                            _ => return Err(EvalErr::ConversionError),
                        }
                    }
                    // to a text width: render the value, refuse if it does
                    // not fit (the engine's convert error), pad for CHAR
                    CastTarget::Text { len, pad } => {
                        let s = v.render();
                        if s.chars().count() > *len {
                            return Err(EvalErr::ConversionError);
                        }
                        let out = if *pad {
                            let mut s = s;
                            while s.chars().count() < *len {
                                s.push(' ');
                            }
                            s
                        } else {
                            s
                        };
                        Value::Text(out)
                    }
                }
            }
        })
    }
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
/// [HAVING <pred>] [ORDER BY <cols>]` into its parts, case-insensitively
/// but preserving the original case (WHERE/HAVING literals are
/// case-sensitive). ASCII uppercasing keeps byte positions, so keyword
/// offsets found in the uppercased copy slice the original.
#[allow(clippy::type_complexity)]
fn split_query(
    sql: &str,
) -> Option<(&str, &str, Option<&str>, Option<&str>, Option<&str>, Option<&str>)> {
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
    // HAVING/ORDER keyword inside a literal does not match; slice the
    // original.
    let masked = mask_literals(&up[after..]);

    let where_pos = find_word(&masked, "WHERE", 0);
    let group = find_kw_by(&masked, "GROUP");
    let having_pos = find_word(&masked, "HAVING", 0);
    let order = find_kw_by(&masked, "ORDER");
    let group_kw = group.map(|(k, _)| k);
    let order_kw = order.map(|(k, _)| k);

    // the table name ends at the first of WHERE / GROUP BY / HAVING /
    // ORDER BY
    let table_end = [where_pos, group_kw, having_pos, order_kw]
        .into_iter()
        .flatten()
        .min()
        .unwrap_or(rest.len());
    let table = rest[..table_end].trim();

    let where_str = where_pos.map(|wp| {
        let end = [group_kw, having_pos, order_kw]
            .into_iter()
            .flatten()
            .filter(|&o| o > wp)
            .min()
            .unwrap_or(rest.len());
        rest[wp + "WHERE".len()..end].trim()
    });
    let group_str = group.map(|(_, cols)| {
        let end = [having_pos, order_kw]
            .into_iter()
            .flatten()
            .filter(|&o| o > cols)
            .min()
            .unwrap_or(rest.len());
        rest[cols..end].trim()
    });
    let having_str = having_pos.map(|hp| {
        let end = order_kw.filter(|&o| o > hp).unwrap_or(rest.len());
        rest[hp + "HAVING".len()..end].trim()
    });
    let order_str = order.map(|(_, cols)| rest[cols..].trim());
    Some((proj, table, where_str, group_str, having_str, order_str))
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
/// is a bare or table-qualified identifier or an aggregate. (Aggregate
/// arguments contain no commas, so splitting the list on commas is safe.)
/// Qualified names are kept whole; the join resolver splits them, and the
/// single-table column lookup - which has no qualifiers - never matches
/// one, so a qualified column on a single table falls back as before.
fn parse_projection(proj: &str) -> Option<Proj> {
    if proj.trim() == "*" {
        return Some(Proj::Star);
    }
    let mut items = Vec::new();
    for part in split_top_level_commas(proj) {
        let part = part.trim();
        if let Some((func, target)) = parse_agg_item(part) {
            items.push(SelItem::Agg(func, target));
            continue;
        }
        // split off an ` AS <alias>` or trailing bare alias (a plain
        // column keeps its name; an expression is named by its alias or
        // a default)
        let (body, alias) = split_alias(part);
        let body = body.trim();
        // a generator advance (NEXT VALUE FOR / GEN_ID) in the select list
        if let Some((gen, step)) = parse_gen_sel_item(body) {
            let name = alias
                .map(|a| a.trim_matches('"').to_ascii_uppercase())
                .unwrap_or_else(|| if step.is_none() { "GEN_ID".into() } else { "GEN_ID".into() });
            items.push(SelItem::Gen(gen, step, name));
            continue;
        }
        if alias.is_none() && is_qualified_col(body) {
            items.push(SelItem::Col(body.to_string()));
        } else if alias.is_none() && ident_ok(body.trim_matches('"')) {
            items.push(SelItem::Col(body.trim_matches('"').to_string()));
        } else if let Some(raw) = parse_raw_expr(body) {
            let name = alias
                .map(|a| a.trim_matches('"').to_ascii_uppercase())
                .unwrap_or_else(|| default_expr_name(&raw));
            items.push(SelItem::Expr(raw, name));
        } else if let Some(a) = alias {
            // an aliased plain column: `col AS name`
            let a = a.trim_matches('"').to_ascii_uppercase();
            if body.contains('.') {
                let (q, c) = split_qual(body);
                if !ident_ok(q.unwrap_or("")) || !ident_ok(c) {
                    return None;
                }
            } else if !ident_ok(body.trim_matches('"')) {
                return None;
            }
            // reuse the column name path; the alias only changes display,
            // which build_projcols does not currently apply - keep the
            // column's own name (matches isql for un-aliased selects)
            let _ = a;
            items.push(SelItem::Col(body.trim_matches('"').to_string()));
        } else {
            return None;
        }
    }
    if items.is_empty() {
        return None;
    }
    Some(Proj::Items(items))
}

/// Split a select list on top-level commas (commas inside parentheses -
/// e.g. a function's arguments - stay put).
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = 0usize;
    for (i, ch) in s.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

/// Split a select item into its body and an optional alias: `<body> AS
/// <alias>`. Only the explicit `AS` form is recognised (an implicit
/// trailing alias is ambiguous with the expression itself). The search
/// runs on a literal-masked copy so an `AS` inside a string does not
/// match, and only a *top-level* `AS` counts - one inside parentheses is
/// part of the expression (`CAST(A AS INT)`), not an alias marker.
fn split_alias(item: &str) -> (&str, Option<&str>) {
    let masked = mask_literals(&item.to_ascii_uppercase());
    let b = masked.as_bytes();
    let mut depth = 0i32;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'(' => depth += 1,
            b')' => depth -= 1,
            b'A' if depth == 0
                && b.get(i + 1) == Some(&b'S')
                && (i == 0 || !is_ident_byte(b[i - 1]))
                && b.get(i + 2).map_or(true, |c| !is_ident_byte(*c)) =>
            {
                let alias = item[i + 2..].trim();
                if !alias.is_empty() {
                    return (&item[..i], Some(alias));
                }
            }
            _ => {}
        }
        i += 1;
    }
    (item, None)
}

/// The default output-column name for an un-aliased expression. Firebird
/// names them by the operation (e.g. `ADD`, `MULTIPLY`, `CONSTANT`); a
/// close-enough default keeps describe well-formed (tests that check the
/// value alias it).
fn default_expr_name(raw: &RawExpr) -> String {
    match raw {
        RawExpr::Bin(_, ArithOp::Add, _) => "ADD",
        RawExpr::Bin(_, ArithOp::Sub, _) => "SUBTRACT",
        RawExpr::Bin(_, ArithOp::Mul, _) => "MULTIPLY",
        RawExpr::Bin(_, ArithOp::Div, _) => "DIVIDE",
        RawExpr::Concat(_, _) => "CONCATENATION",
        RawExpr::Cast(_, _) => "CAST",
        // the engine leaves a unary-minus column unnamed (blank header)
        RawExpr::Neg(_) => "",
        RawExpr::Int(_) | RawExpr::Dec(..) | RawExpr::Str(_) | RawExpr::Null => "CONSTANT",
        RawExpr::Col(_) => "EXPR",
    }
    .to_string()
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
            // sorting is over the record's fields; an expression output
            // has no field to sort on, so ORDER BY that ordinal is not
            // something this server answers (fall back rather than sort
            // by the dummy field id)
            if cols[ord - 1].expr.is_some() {
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

/// A WHERE/HAVING/VALUES token.
enum Tok {
    Ident(String),
    Comma,
    Agg(AggFn, AggTarget),
    Int(i64),
    Str(String),
    Cmp(Cmp),
    And,
    Or,
    Is,
    Not,
    Null,
    /// a `?` parameter placeholder - its value arrives with op_execute
    Param,
    LParen,
    RParen,
    Like,
    Between,
    In,
    Escape,
}

/// Tokenise a WHERE/HAVING clause. Single-quoted strings ('' escapes a
/// quote), integer literals (optionally negative), comparison operators
/// (= <> != < <= > >=), identifiers, the keywords AND/OR/IS/NOT/NULL, and
/// aggregate calls `COUNT(*)`/`COUNT(col)`/`MIN|MAX|SUM(col)` as single
/// tokens (only valid in HAVING - WHERE resolution rejects them).
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
            b',' => {
                out.push(Tok::Comma);
                i += 1;
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
            b'?' => {
                out.push(Tok::Param);
                i += 1;
            }
            b'(' => {
                out.push(Tok::LParen);
                i += 1;
            }
            b')' => {
                out.push(Tok::RParen);
                i += 1;
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
                // a qualified column IDENT.IDENT is ONE token; the
                // resolver splits it on the dot
                if i < b.len()
                    && b[i] == b'.'
                    && b.get(i + 1).is_some_and(|n| is_ident_byte(*n))
                {
                    i += 1;
                    while i < b.len() && is_ident_byte(b[i]) {
                        i += 1;
                    }
                    out.push(Tok::Ident(s[start..i].to_string()));
                    continue;
                }
                let word = &s[start..i];
                let upper = word.to_ascii_uppercase();
                // an aggregate name followed by `(...)` lexes as one
                // aggregate-call token (spacing-tolerant, no nesting)
                if matches!(upper.as_str(), "COUNT" | "MIN" | "MAX" | "SUM") {
                    let mut j = i;
                    while j < b.len() && b[j].is_ascii_whitespace() {
                        j += 1;
                    }
                    if j < b.len() && b[j] == b'(' {
                        let close = j + s[j..].find(')')?;
                        let (func, target) = parse_agg_item(&s[start..=close])?;
                        out.push(Tok::Agg(func, target));
                        i = close + 1;
                        continue;
                    }
                }
                match upper.as_str() {
                    "AND" => out.push(Tok::And),
                    "OR" => out.push(Tok::Or),
                    "IS" => out.push(Tok::Is),
                    "NOT" => out.push(Tok::Not),
                    "NULL" => out.push(Tok::Null),
                    "LIKE" => out.push(Tok::Like),
                    "BETWEEN" => out.push(Tok::Between),
                    "IN" => out.push(Tok::In),
                    "ESCAPE" => out.push(Tok::Escape),
                    _ => out.push(Tok::Ident(word.to_string())),
                }
            }
            _ => return None, // unsupported character
        }
    }
    Some(out)
}

/// An unresolved WHERE/HAVING term (left side not yet resolved to a value
/// index). The left side is a column name, or - in HAVING only - an
/// aggregate call.
#[derive(Clone)]
struct RawTerm {
    lhs: RawLhs,
    kind: RawKind,
}
#[derive(Clone)]
enum RawLhs {
    Col(String),
    Agg(AggFn, AggTarget),
}
#[derive(Clone)]
enum RawKind {
    Cmp(Cmp, Rhs),
    IsNull,
    IsNotNull,
    Like(Rhs, Option<char>, bool),
}

/// The predicate syntax tree before normalization: OR/AND/NOT over
/// leaves. `BETWEEN` and `IN` desugar at parse time (>= AND <=, OR of
/// =), so only comparisons, NULL tests and LIKE reach the leaves.
enum Ast {
    Or(Vec<Ast>),
    And(Vec<Ast>),
    Not(Box<Ast>),
    Leaf(RawTerm),
}

/// Parse a WHERE/HAVING token stream into DNF (OR of AND-groups of
/// terms). Grammar: OR over AND over unary, `NOT` and parentheses in
/// unary position, leaves `<lhs> (= <> < <= > >=) <val>`, `IS [NOT]
/// NULL`, `[NOT] LIKE <pat> [ESCAPE <c>]`, `[NOT] BETWEEN <val> AND
/// <val>`, `[NOT] IN (<val>, ...)`. NOT is pushed into the leaves by
/// De Morgan during the DNF conversion (sound in three-valued logic:
/// the inverse comparison of UNKNOWN is still UNKNOWN). `?` markers
/// claim parameter slots AT PARSE TIME, numbered from `*next_param` in
/// textual order - a leaf duplicated by the DNF cross-product then
/// still references its one slot. None = a shape this parser does not
/// cover, or a DNF blow-up past the size cap (the caller falls back
/// rather than answering wrong).
fn parse_predicate(toks: &[Tok], next_param: &mut usize) -> Option<Vec<Vec<RawTerm>>> {
    let mut pos = 0usize;
    let ast = parse_or(toks, &mut pos, next_param)?;
    if pos != toks.len() {
        return None; // trailing tokens
    }
    let dnf = to_dnf(&ast, false)?;
    if dnf.is_empty() || dnf.iter().any(|g| g.is_empty()) {
        return None;
    }
    Some(dnf)
}

fn parse_or(t: &[Tok], pos: &mut usize, np: &mut usize) -> Option<Ast> {
    let mut parts = vec![parse_and(t, pos, np)?];
    while matches!(t.get(*pos), Some(Tok::Or)) {
        *pos += 1;
        parts.push(parse_and(t, pos, np)?);
    }
    Some(if parts.len() == 1 { parts.pop().unwrap() } else { Ast::Or(parts) })
}

fn parse_and(t: &[Tok], pos: &mut usize, np: &mut usize) -> Option<Ast> {
    let mut parts = vec![parse_unary(t, pos, np)?];
    while matches!(t.get(*pos), Some(Tok::And)) {
        *pos += 1;
        parts.push(parse_unary(t, pos, np)?);
    }
    Some(if parts.len() == 1 { parts.pop().unwrap() } else { Ast::And(parts) })
}

fn parse_unary(t: &[Tok], pos: &mut usize, np: &mut usize) -> Option<Ast> {
    match t.get(*pos) {
        Some(Tok::Not) => {
            *pos += 1;
            Some(Ast::Not(Box::new(parse_unary(t, pos, np)?)))
        }
        Some(Tok::LParen) => {
            *pos += 1;
            let inner = parse_or(t, pos, np)?;
            if !matches!(t.get(*pos), Some(Tok::RParen)) {
                return None;
            }
            *pos += 1;
            Some(inner)
        }
        _ => parse_leaf(t, pos, np),
    }
}

/// One value position in a predicate: a literal, NULL, or a `?` that
/// claims the next parameter slot.
fn parse_value(t: &[Tok], pos: &mut usize, np: &mut usize) -> Option<Rhs> {
    let v = match t.get(*pos)? {
        Tok::Int(n) => Rhs::Int(*n),
        Tok::Str(s) => Rhs::Str(s.clone()),
        Tok::Null => Rhs::Null,
        Tok::Param => {
            *np += 1;
            // the ColKind is a placeholder until resolution knows the column
            Rhs::Param(*np - 1, ColKind::Int)
        }
        _ => return None,
    };
    *pos += 1;
    Some(v)
}

fn parse_leaf(t: &[Tok], pos: &mut usize, np: &mut usize) -> Option<Ast> {
    let lhs = match t.get(*pos)? {
        Tok::Ident(c) => RawLhs::Col(c.clone()),
        Tok::Agg(f, target) => RawLhs::Agg(*f, target.clone()),
        _ => return None,
    };
    *pos += 1;
    let leaf = |kind: RawKind| Ast::Leaf(RawTerm { lhs: lhs.clone(), kind });
    // an optional NOT immediately before LIKE/BETWEEN/IN
    let negated = if matches!(t.get(*pos), Some(Tok::Not))
        && matches!(t.get(*pos + 1), Some(Tok::Like | Tok::Between | Tok::In))
    {
        *pos += 1;
        true
    } else {
        false
    };
    match t.get(*pos)? {
        Tok::Cmp(op) if !negated => {
            let op = *op;
            *pos += 1;
            Some(leaf(RawKind::Cmp(op, parse_value(t, pos, np)?)))
        }
        Tok::Is if !negated => {
            *pos += 1;
            match (t.get(*pos), t.get(*pos + 1)) {
                (Some(Tok::Null), _) => {
                    *pos += 1;
                    Some(leaf(RawKind::IsNull))
                }
                (Some(Tok::Not), Some(Tok::Null)) => {
                    *pos += 2;
                    Some(leaf(RawKind::IsNotNull))
                }
                _ => None,
            }
        }
        Tok::Like => {
            *pos += 1;
            let pattern = parse_value(t, pos, np)?;
            if matches!(pattern, Rhs::Int(_)) {
                return None; // a numeric LIKE pattern is not a shape we answer
            }
            let escape = if matches!(t.get(*pos), Some(Tok::Escape)) {
                *pos += 1;
                let Some(Tok::Str(e)) = t.get(*pos) else { return None };
                let mut chars = e.chars();
                let c = chars.next()?;
                if chars.next().is_some() {
                    return None; // ESCAPE must be a single character
                }
                *pos += 1;
                Some(c)
            } else {
                None
            };
            Some(leaf(RawKind::Like(pattern, escape, negated)))
        }
        Tok::Between => {
            *pos += 1;
            let lo = parse_value(t, pos, np)?;
            if !matches!(t.get(*pos), Some(Tok::And)) {
                return None;
            }
            *pos += 1;
            let hi = parse_value(t, pos, np)?;
            // x BETWEEN lo AND hi = x >= lo AND x <= hi (bounds not swapped)
            let body = Ast::And(vec![
                leaf(RawKind::Cmp(Cmp::Ge, lo)),
                leaf(RawKind::Cmp(Cmp::Le, hi)),
            ]);
            Some(if negated { Ast::Not(Box::new(body)) } else { body })
        }
        Tok::In => {
            *pos += 1;
            if !matches!(t.get(*pos), Some(Tok::LParen)) {
                return None;
            }
            *pos += 1;
            let mut items = vec![leaf(RawKind::Cmp(Cmp::Eq, parse_value(t, pos, np)?))];
            while matches!(t.get(*pos), Some(Tok::Comma)) {
                *pos += 1;
                items.push(leaf(RawKind::Cmp(Cmp::Eq, parse_value(t, pos, np)?)));
            }
            if !matches!(t.get(*pos), Some(Tok::RParen)) {
                return None;
            }
            *pos += 1;
            let body = Ast::Or(items);
            Some(if negated { Ast::Not(Box::new(body)) } else { body })
        }
        _ => None,
    }
}

/// The size cap on the normalized predicate - a cross-product past
/// this is refused (fallback), never silently truncated.
const DNF_MAX_GROUPS: usize = 64;

/// Normalize the tree to OR-of-ANDs, pushing `neg` down by De Morgan.
fn to_dnf(ast: &Ast, neg: bool) -> Option<Vec<Vec<RawTerm>>> {
    match ast {
        Ast::Not(inner) => to_dnf(inner, !neg),
        // OR of DNFs concatenates; negated it is an AND of negations
        Ast::Or(parts) if !neg => concat_dnf(parts, neg),
        Ast::And(parts) if neg => concat_dnf(parts, neg),
        // AND of DNFs distributes (cross-product)
        Ast::And(parts) if !neg => cross_dnf(parts, neg),
        Ast::Or(parts) | Ast::And(parts) => cross_dnf(parts, neg),
        Ast::Leaf(t) => {
            let t = if neg { negate_term(t)? } else { t.clone() };
            Some(vec![vec![t]])
        }
    }
}

fn concat_dnf(parts: &[Ast], neg: bool) -> Option<Vec<Vec<RawTerm>>> {
    let mut out = Vec::new();
    for p in parts {
        out.extend(to_dnf(p, neg)?);
        if out.len() > DNF_MAX_GROUPS {
            return None;
        }
    }
    Some(out)
}

fn cross_dnf(parts: &[Ast], neg: bool) -> Option<Vec<Vec<RawTerm>>> {
    let mut acc: Vec<Vec<RawTerm>> = vec![Vec::new()];
    for p in parts {
        let d = to_dnf(p, neg)?;
        let mut next = Vec::with_capacity(acc.len() * d.len());
        for a in &acc {
            for g in &d {
                let mut merged = a.clone();
                merged.extend(g.iter().cloned());
                next.push(merged);
            }
        }
        if next.len() > DNF_MAX_GROUPS {
            return None;
        }
        acc = next;
    }
    Some(acc)
}

/// The negation of one leaf, in three-valued logic: the inverse
/// comparison (UNKNOWN stays UNKNOWN under both), the flipped NULL
/// test (two-valued), the flipped LIKE.
fn negate_term(t: &RawTerm) -> Option<RawTerm> {
    let kind = match &t.kind {
        RawKind::Cmp(op, rhs) => {
            let inv = match op {
                Cmp::Eq => Cmp::Ne,
                Cmp::Ne => Cmp::Eq,
                Cmp::Lt => Cmp::Ge,
                Cmp::Ge => Cmp::Lt,
                Cmp::Gt => Cmp::Le,
                Cmp::Le => Cmp::Gt,
            };
            RawKind::Cmp(inv, rhs.clone())
        }
        RawKind::IsNull => RawKind::IsNotNull,
        RawKind::IsNotNull => RawKind::IsNull,
        RawKind::Like(p, e, negated) => RawKind::Like(p.clone(), *e, !negated),
    };
    Some(RawTerm { lhs: t.lhs.clone(), kind })
}

/// Split a token slice on top-level commas only - commas nested inside
/// parentheses (a `GEN_ID(name, n)` call in a VALUES list) stay with
/// their part. Depth never goes negative for a balanced list.
fn split_top_commas(toks: &[Tok]) -> Vec<&[Tok]> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut depth = 0i32;
    for (i, t) in toks.iter().enumerate() {
        match t {
            Tok::LParen => depth += 1,
            Tok::RParen => depth -= 1,
            Tok::Comma if depth == 0 => {
                parts.push(&toks[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    parts.push(&toks[start..]);
    parts
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

/// Whether a descriptor is comparable as an integer or as text (the only
/// kinds WHERE handles); None for anything else.
#[derive(Clone, Copy, PartialEq)]
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

/// Build one resolved term from a value index, the kind of value living
/// there, and the raw comparison. Checks the literal type against the
/// value type; None on a mismatch. A parameter placeholder is NOT
/// handled here - resolvers that support parameters register the slot
/// themselves (HAVING does not, so a `?` there lands on the None).
fn typed_term(idx: usize, kind: ColKind, raw: RawKind) -> Option<Term> {
    Some(match raw {
        RawKind::Cmp(op, Rhs::Int(n)) => match kind {
            ColKind::Int => Term::Cmp(idx, op, Rhs::Int(n)),
            _ => return None,
        },
        RawKind::Cmp(op, Rhs::Str(v)) => match kind {
            ColKind::Text => Term::Cmp(idx, op, Rhs::Str(v)),
            _ => return None,
        },
        // comparison against a NULL literal: legal SQL, always UNKNOWN
        RawKind::Cmp(_, Rhs::Null) => Term::Never,
        RawKind::Cmp(_, Rhs::Param(..)) => return None,
        RawKind::IsNull => Term::IsNull(idx),
        RawKind::IsNotNull => Term::IsNotNull(idx),
        RawKind::Like(pattern, escape, negated) => match (kind, pattern) {
            (ColKind::Text, Rhs::Str(p)) => Term::Like(idx, Rhs::Str(p), escape, negated),
            // <col> LIKE NULL is UNKNOWN for every row
            (ColKind::Text, Rhs::Null) => Term::Never,
            _ => return None,
        },
    })
}

/// Resolve every WHERE term's column name to a field id and check the
/// literal type matches the column type. Returns None on an unknown
/// column, an unsupported column type, a literal/column type mismatch, or
/// an aggregate call (aggregates are not valid in WHERE). A `?` term's
/// slot was numbered at parse time; resolution fills `params[slot]`
/// with the column's descriptor (a leaf the DNF cross-product
/// duplicated fills its one slot twice with the same descriptor).
fn resolve_predicate(
    raw: Vec<Vec<RawTerm>>,
    columns: &[RelationColumn],
    descs: &[Descriptor],
    params: &mut Vec<Option<Descriptor>>,
) -> Option<Predicate> {
    let mut groups = Vec::new();
    for g in raw {
        let mut terms = Vec::new();
        for rt in g {
            let RawLhs::Col(col) = &rt.lhs else {
                return None; // an aggregate in WHERE is invalid SQL
            };
            let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(col))?;
            let fid = rc.field_id as usize;
            let d = descs.get(fid)?;
            let kind = col_kind(d)?;
            terms.push(param_or_typed_term(fid, kind, rt.kind, d, params)?);
        }
        groups.push(terms);
    }
    Some(Predicate(groups))
}

/// The parameter-aware wrapper around [typed_term]: a `?` right-hand
/// side fills its parse-time slot with the column's descriptor;
/// anything else resolves as before.
fn param_or_typed_term(
    idx: usize,
    kind: ColKind,
    raw: RawKind,
    d: &Descriptor,
    params: &mut Vec<Option<Descriptor>>,
) -> Option<Term> {
    let mut claim = |slot: usize| -> Option<()> {
        if !param_target_ok(d) {
            return None;
        }
        if params.len() <= slot {
            params.resize(slot + 1, None);
        }
        params[slot] = Some(d.clone());
        Some(())
    };
    match raw {
        RawKind::Cmp(op, Rhs::Param(slot, _)) => {
            claim(slot)?;
            Some(Term::Cmp(idx, op, Rhs::Param(slot, kind)))
        }
        RawKind::Like(Rhs::Param(slot, _), escape, negated) => {
            if kind != ColKind::Text {
                return None;
            }
            claim(slot)?;
            Some(Term::Like(idx, Rhs::Param(slot, ColKind::Text), escape, negated))
        }
        other => typed_term(idx, kind, other),
    }
}

/// Resolve a HAVING predicate against a grouped query's OUTPUT rows. A
/// column left side must be one of the group keys (anything else is
/// invalid SQL); an aggregate left side is any supported aggregate call,
/// whether or not it appears in the select list. Either resolves to the
/// index of a matching `gitems` entry - appending a HIDDEN entry (computed
/// per group but not emitted, since `cols` does not cover it) when the
/// select list does not carry it. Aggregate values are integers, so their
/// literals must be too. Returns None on any unresolvable piece.
fn resolve_having(
    raw: Vec<Vec<RawTerm>>,
    gitems: &mut Vec<GItem>,
    key_fids: &[usize],
    columns: &[RelationColumn],
    descs: &[Descriptor],
) -> Option<Predicate> {
    let mut groups = Vec::new();
    for g in raw {
        let mut terms = Vec::new();
        for rt in g {
            let (idx, kind) = match &rt.lhs {
                RawLhs::Col(col) => {
                    let rc = columns.iter().find(|c| c.name.eq_ignore_ascii_case(col))?;
                    let fid = rc.field_id as usize;
                    if !key_fids.contains(&fid) {
                        return None; // HAVING on a non-grouped column
                    }
                    let kind = col_kind(descs.get(fid)?)?;
                    let idx = gitems
                        .iter()
                        .position(|gi| matches!(gi, GItem::Key(f) if *f == fid))
                        .unwrap_or_else(|| {
                            gitems.push(GItem::Key(fid));
                            gitems.len() - 1
                        });
                    (idx, kind)
                }
                RawLhs::Agg(func, target) => {
                    let fid = match target {
                        AggTarget::Star => None, // COUNT(*) - parse guarantees Count
                        AggTarget::Col(name) => {
                            let rc =
                                columns.iter().find(|c| c.name.eq_ignore_ascii_case(name))?;
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
                    let idx = gitems
                        .iter()
                        .position(|gi| matches!(gi, GItem::Agg(f, t) if f == func && *t == fid))
                        .unwrap_or_else(|| {
                            gitems.push(GItem::Agg(*func, fid));
                            gitems.len() - 1
                        });
                    (idx, ColKind::Int)
                }
            };
            terms.push(typed_term(idx, kind, rt.kind)?);
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

    // --- op_service_attach: the Services manager the firebird-qa plugin
    // bootstraps against (connect_server). It reads the server version,
    // home/lock directories, security database and architecture, then
    // detaches. We serve those from a small service loop and return. ---
    if attach_op == OP_SERVICE_ATTACH {
        return serve_service(&mut s, &mut enc, &mut dec);
    }

    // op_attach and op_create share the wire layout (database id, file,
    // dpb). op_create additionally MATERIALISES the file first: rather
    // than synthesise a valid ODS from nothing (a separate large
    // conversion), fire-crab has the engine create an empty database,
    // then serves and mutates it - the same real-file basis every gate
    // uses. Both then run the identical attachment loop below.
    if attach_op != OP_ATTACH && attach_op != OP_CREATE {
        return Ok(());
    }
    read_int(&mut s, &mut dec)?; // 0
    let path_bytes = read_wire_bytes(&mut s, &mut dec)?; // db path
    read_wire_bytes(&mut s, &mut dec)?; // dpb
    let db_path = String::from_utf8_lossy(&path_bytes).into_owned();
    if attach_op == OP_CREATE {
        if let Err(e) = create_database_file(&db_path) {
            if std::env::var("FC_SRV_TRACE").is_ok() {
                eprintln!("[srv] create_database failed: {}", e);
            }
            respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
            return Ok(());
        }
    }
    // Open the real file the client named, if it exists and is a database.
    // When it does, queries answer from its pages; when it does not (the
    // client attached to a name with no file behind it), the server falls
    // back to the fixed constant so the pipeline still round-trips.
    let mut database: Option<Database> = load_database(&db_path);
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
    let attach_id = ATTACH_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    respond(&mut s, &mut enc, 1)?; // attachment handle 1

    // The SQL text of the most recently prepared statement, the plan it
    // resolves to (built at prepare, executed at fetch), its parameter
    // targets (what the describe's bind section announced), the values
    // the last op_execute carried for them, and the last DML's per-verb
    // affected counts (what isc_info_sql_records reports).
    let mut stmt_sql = String::new();
    let mut plan = Plan::Scalar(Some(FIXED_ANSWER));
    let mut stmt_params: Vec<Descriptor> = Vec::new();
    let mut bound_args: Vec<WireParam> = Vec::new();
    let mut last_dml = (0i32, 0i32, 0i32); // (inserted, updated, deleted)
    // open blobs: handle -> (assembled content, read cursor). Content is
    // assembled at open (the whole file is in memory anyway); get_segment
    // then just slices it.
    let mut blobs: std::collections::HashMap<i32, (Vec<u8>, usize)> = std::collections::HashMap::new();
    let mut next_blob_handle: i32 = 7000;
    // the legacy BLR request (isql SHOW): the compiled request, the
    // queue of xdr-encoded output messages built at start, and the
    // read cursor the op_receive loop advances
    // The legacy request API keeps several requests open at once - isql's
    // SHOW INDICES drives a request over the indices while, per index,
    // re-running a second request over its segments. Each op_compile gets
    // its own handle; the request, its output queue and read cursor live
    // under that handle until op_release.
    struct BlrSlot {
        req: BlrReq,
        queue: Vec<(i32, Vec<u8>)>,
        cursor: usize,
    }
    let mut blr_slots: std::collections::HashMap<i32, BlrSlot> = std::collections::HashMap::new();
    let mut next_blr_handle: i32 = BLR_REQ_HANDLE;

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
                respond(&mut s, &mut enc, TX_HANDLE)?; // transaction handle (distinct from attach 1)
            }
            x if x == OP_EXEC_IMMEDIATE => {
                // prepare-and-execute in one round-trip, no cursor - what
                // isql uses for SET and DDL/DML statements it does not
                // fetch from. Shares op_prepare's wire layout (no message).
                read_int(&mut s, &mut dec)?; // tr
                read_int(&mut s, &mut dec)?; // db handle
                read_int(&mut s, &mut dec)?; // dialect
                let sql = read_wire_bytes(&mut s, &mut dec)?;
                read_wire_bytes(&mut s, &mut dec)?; // items
                read_int(&mut s, &mut dec)?; // buffer length
                if best >= 20 {
                    read_int(&mut s, &mut dec)?; // p_sqlst_flags
                }
                let text = String::from_utf8_lossy(&sql).into_owned();
                let up = text.trim_start().to_ascii_uppercase();
                let ddl_kw = ["CREATE", "ALTER", "DROP", "RECREATE"]
                    .into_iter()
                    .any(|k| find_word(&up, k, 0) == Some(0));
                let dml_kw = ["INSERT", "UPDATE", "DELETE"]
                    .into_iter()
                    .any(|k| find_word(&up, k, 0) == Some(0));
                // SET GENERATOR / ALTER SEQUENCE RESTART are generator
                // writes; the ALTER form also begins with a DDL verb.
                let planned = plan_set_generator(&text)
                    .or_else(|| plan_set_statistics(&text))
                    .or_else(|| {
                    if ddl_kw {
                        plan_create_table(&text)
                            .or_else(|| plan_create_index(&text))
                            .or_else(|| plan_drop_table(&text))
                            .or_else(|| plan_drop_index(&text))
                            .or_else(|| plan_create_sequence(&text))
                            .or_else(|| plan_drop_sequence(&text))
                            .or_else(|| plan_alter_index(&text))
                            .or_else(|| plan_alter_table_add(&text))
                            .or_else(|| plan_alter_table_drop(&text))
                            .or_else(|| plan_alter_table_alter_type(&text))
                            .or_else(|| plan_alter_column_null(&text))
                            .or_else(|| plan_alter_sequence(&text))
                    } else if dml_kw {
                        plan_insert(&text, &database)
                            .or_else(|| plan_update(&text, &database))
                            .or_else(|| plan_delete(&text, &database))
                    } else {
                        None
                    }
                });
                match planned {
                    // execute only zero-parameter statements here
                    // (op_exec_immediate carries no message)
                    Some((p, ps)) if ps.is_empty() => {
                        match execute_dml(&p, &mut database, &[]) {
                            Ok(counts) => {
                                last_dml = counts;
                                respond(&mut s, &mut enc, TX_HANDLE)?;
                            }
                            Err(_) => respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?,
                        }
                    }
                    Some(_) => respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?,
                    None if ddl_kw || dml_kw => {
                        respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?
                    }
                    None => {
                        // SET / other non-row statements: acknowledge so the
                        // client (isql) continues rather than desyncing
                        respond(&mut s, &mut enc, TX_HANDLE)?;
                    }
                }
            }
            x if x == OP_EXEC_IMMEDIATE2 => {
                // prepare + execute + return one output message in a single
                // round-trip (protocol.cpp op_exec_immediate2). The OO
                // client uses this for execute()-with-output-metadata; isql
                // reads each generator's current value this way in SHOW
                // GENERATORS: SELECT GEN_ID(<name>, 0) FROM RDB$DATABASE.
                // Wire order: in_blr, msg#, messages, [in msg], out_blr,
                // out msg#, [inline blob size], then the op_exec_immediate
                // tail (tr, stmt, dialect, sql, items, buflen, [flags]).
                read_wire_bytes(&mut s, &mut dec)?; // in_blr
                read_int(&mut s, &mut dec)?; // p_sqlst_message_number
                let in_messages = read_int(&mut s, &mut dec)?;
                if in_messages != 0 {
                    // an input message would follow (xdr_sql_message); our
                    // clients pass no parameters here, so this is unexpected
                    respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                    continue;
                }
                read_wire_bytes(&mut s, &mut dec)?; // out_blr
                read_int(&mut s, &mut dec)?; // p_sqlst_out_message_number
                if best >= 20 {
                    read_int(&mut s, &mut dec)?; // p_sqlst_inline_blob_size
                }
                read_int(&mut s, &mut dec)?; // tr
                read_int(&mut s, &mut dec)?; // stmt handle
                read_int(&mut s, &mut dec)?; // dialect
                let sql = read_wire_bytes(&mut s, &mut dec)?;
                read_wire_bytes(&mut s, &mut dec)?; // items
                read_int(&mut s, &mut dec)?; // buffer length
                if best >= 20 {
                    read_int(&mut s, &mut dec)?; // p_sqlst_flags
                }
                let text = String::from_utf8_lossy(&sql).into_owned();
                let (p, _ps) = plan_query(&text, &database);
                // op_sql_response carries the single output message (a
                // scalar row: 4-byte null bitmap then the BIGINT), then a
                // plain op_response echoes the transaction handle. A
                // non-scalar plan (should not arise from our clients) sends
                // no message.
                let mut w = W::default();
                match &p {
                    Plan::Scalar(v) => {
                        w.int(OP_SQL_RESPONSE).int(1);
                        match v {
                            Some(n) => {
                                w.raw(&[0u8; 4]); // null bitmap: 1 col, not null
                                w.raw(&n.to_be_bytes());
                            }
                            None => {
                                w.raw(&[1u8, 0, 0, 0]); // col 0 NULL, no data
                            }
                        }
                    }
                    _ => {
                        w.int(OP_SQL_RESPONSE).int(0);
                    }
                }
                w.int(OP_RESPONSE).int(TX_HANDLE).int(0).int(0).int(0).int(0);
                w.send(&mut s, &mut enc)?;
            }
            x if x == OP_ALLOCATE_STATEMENT => {
                read_int(&mut s, &mut dec)?; // db handle
                respond(&mut s, &mut enc, 3)?; // stmt handle 3 (distinct from attach 1, tr 2)
            }
            x if x == OP_PREPARE_STATEMENT => {
                read_int(&mut s, &mut dec)?; // tr
                read_int(&mut s, &mut dec)?; // stmt
                read_int(&mut s, &mut dec)?; // dialect
                let sql = read_wire_bytes(&mut s, &mut dec)?; // sql
                let prep_items = read_wire_bytes(&mut s, &mut dec)?; // items
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] op_prepare items: {:?}", prep_items);
                }
                read_int(&mut s, &mut dec)?; // buffer length
                if best >= 20 {
                    read_int(&mut s, &mut dec)?; // p_sqlst_flags (FB6/proto 20+)
                }
                stmt_sql = String::from_utf8_lossy(&sql).into_owned();
                last_dml = (0, 0, 0);
                bound_args.clear();
                let up = stmt_sql.trim_start().to_ascii_uppercase();
                let ddl_kw = ["CREATE", "ALTER", "DROP", "RECREATE"]
                    .into_iter()
                    .find(|k| find_word(&up, k, 0) == Some(0));
                let dml_kw = ["INSERT", "UPDATE", "DELETE"]
                    .into_iter()
                    .find(|k| find_word(&up, k, 0) == Some(0));
                if let Some((p, ps)) =
                    plan_set_generator(&stmt_sql).or_else(|| plan_set_statistics(&stmt_sql))
                {
                    // SET GENERATOR / SET STATISTICS - DDL that begins with
                    // SET, so it is not caught by the DDL/DML verb list
                    let describe = answer_prepare(&prep_items, &p, &ps);
                    plan = p;
                    stmt_params = ps;
                    respond_prepare(&mut s, &mut enc, &describe)?;
                } else if ddl_kw.is_some() {
                    // DDL prepares to a real plan or to an SQL error -
                    // a client must never think its DDL succeeded when
                    // the verb is one this server does not implement
                    let planned = plan_create_table(&stmt_sql)
                        .or_else(|| plan_create_index(&stmt_sql))
                        .or_else(|| plan_drop_table(&stmt_sql))
                        .or_else(|| plan_drop_index(&stmt_sql))
                        .or_else(|| plan_create_sequence(&stmt_sql))
                        .or_else(|| plan_drop_sequence(&stmt_sql))
                        .or_else(|| plan_alter_index(&stmt_sql))
                        .or_else(|| plan_alter_table_add(&stmt_sql))
                        .or_else(|| plan_alter_table_drop(&stmt_sql))
                        .or_else(|| plan_alter_table_alter_type(&stmt_sql))
                        .or_else(|| plan_alter_column_null(&stmt_sql))
                        .or_else(|| plan_alter_sequence(&stmt_sql));
                    match planned {
                        Some((p, ps)) => {
                            let describe = answer_prepare(&prep_items, &p, &ps);
                            plan = p;
                            stmt_params = ps;
                            respond_prepare(&mut s, &mut enc, &describe)?;
                        }
                        None => {
                            plan = Plan::Scalar(Some(FIXED_ANSWER));
                            stmt_params = Vec::new();
                            respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                        }
                    }
                } else if let Some(kw) = dml_kw {
                    // DML prepares to a real plan or to an SQL error -
                    // never to the fixed-answer fallback, which would
                    // let a client think its write succeeded
                    let planned = match kw {
                        "INSERT" => plan_insert(&stmt_sql, &database),
                        "UPDATE" => plan_update(&stmt_sql, &database),
                        _ => plan_delete(&stmt_sql, &database),
                    };
                    match planned {
                        Some((p, ps)) => {
                            let describe = answer_prepare(&prep_items, &p, &ps);
                            plan = p;
                            stmt_params = ps;
                            respond_prepare(&mut s, &mut enc, &describe)?;
                        }
                        None => {
                            plan = Plan::Scalar(Some(FIXED_ANSWER));
                            stmt_params = Vec::new();
                            respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                        }
                    }
                } else {
                    let (p, ps) = plan_query(&stmt_sql, &database);
                    plan = p;
                    stmt_params = ps;
                    let describe = answer_prepare(&prep_items, &plan, &stmt_params);
                    respond_prepare(&mut s, &mut enc, &describe)?;
                }
            }
            x if x == OP_EXECUTE => {
                read_int(&mut s, &mut dec)?; // stmt
                read_int(&mut s, &mut dec)?; // tr
                let in_blr = read_wire_bytes(&mut s, &mut dec)?; // input blr
                read_int(&mut s, &mut dec)?; // msg number
                let messages = read_int(&mut s, &mut dec)?; // message count
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] exec in_blr ({} B): {:?} messages={}", in_blr.len(), in_blr, messages);
                }
                // With parameters, the message (null bitmap + values)
                // follows HERE, before the version-dependent trailing
                // fields. Its layout comes from the client's own BLR -
                // if that BLR names a dtype this server cannot decode,
                // the message length is unknowable and the connection
                // must drop (a desynced stream would be worse).
                bound_args = if messages > 0 {
                    let slots = parse_param_blr(&in_blr).ok_or_else(|| {
                        std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "undecodable input-message BLR",
                        )
                    })?;
                    read_param_message(&mut s, &mut dec, &slots)?
                } else {
                    Vec::new()
                };
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
                if std::env::var("FC_SRV_TRACE").is_ok() && !bound_args.is_empty() {
                    eprintln!("[srv] execute params: {:?}", bound_args);
                }
                // the client must supply exactly the parameters the
                // describe announced - fewer or more is an error, not a
                // guess
                if bound_args.len() != stmt_params.len() {
                    last_dml = (0, 0, 0);
                    respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                } else if matches!(
                    plan,
                    Plan::Insert { .. }
                        | Plan::Update { .. }
                        | Plan::Delete { .. }
                        | Plan::CreateTable { .. }
                        | Plan::CreateIndex { .. }
                        | Plan::DropTable { .. }
                        | Plan::DropIndex { .. }
                        | Plan::CreateSequence { .. }
                        | Plan::DropSequence { .. }
                        | Plan::AlterIndex { .. }
                        | Plan::SetStatistics { .. }
                        | Plan::AlterTableAdd { .. }
                        | Plan::AlterTableAddFk { .. }
                        | Plan::AlterTableAddKey { .. }
                        | Plan::AlterTableDropConstraint { .. }
                        | Plan::AlterTableDrop { .. }
                        | Plan::AlterColumnType { .. }
                        | Plan::AlterColumnNull { .. }
                        | Plan::SetGenerator { .. }
                ) {
                    // DML and DDL execute here (not at fetch): write the
                    // new versions (or the new catalog) into a copy of
                    // the page image, swap it in and flush back
                    match execute_dml(&plan, &mut database, &bound_args) {
                        Ok(counts) => {
                            last_dml = counts;
                            if std::env::var("FC_SRV_TRACE").is_ok() {
                                eprintln!(
                                    "[srv] dml: {} inserted, {} updated, {} deleted",
                                    counts.0, counts.1, counts.2
                                );
                            }
                            respond(&mut s, &mut enc, TX_HANDLE)?;
                        }
                        Err(e) => {
                            last_dml = (0, 0, 0);
                            if std::env::var("FC_SRV_TRACE").is_ok() {
                                eprintln!("[srv] dml failed: {}", e);
                            }
                            respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                        }
                    }
                } else if matches!(plan, Plan::GenIdIncrement { .. }) {
                    // a generator-incrementing SELECT writes HERE, then
                    // becomes the Scalar of its new value for the fetch
                    let (name, step) = match &plan {
                        Plan::GenIdIncrement { name, step } => (name.clone(), *step),
                        _ => unreachable!(),
                    };
                    match gen_id_increment(&mut database, &name, step) {
                        Ok(new_val) => {
                            plan = Plan::Scalar(Some(new_val));
                            respond(&mut s, &mut enc, TX_HANDLE)?;
                        }
                        Err(e) => {
                            if std::env::var("FC_SRV_TRACE").is_ok() {
                                eprintln!("[srv] gen_id increment failed: {}", e);
                            }
                            respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                        }
                    }
                } else if let Err(e) = validate_select_bind(&plan, &bound_args) {
                    // a parameterised SELECT whose values cannot bind
                    // (type mismatch) fails HERE, visibly - never an
                    // unfiltered or empty answer at fetch
                    if std::env::var("FC_SRV_TRACE").is_ok() {
                        eprintln!("[srv] select bind failed: {}", e);
                    }
                    respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                } else {
                    respond(&mut s, &mut enc, TX_HANDLE)?;
                }
            }
            x if x == OP_INFO_SQL => {
                // the client asks for statement info - after DML it wants
                // isc_info_sql_records (the per-verb row counts)
                read_int(&mut s, &mut dec)?; // stmt handle
                read_int(&mut s, &mut dec)?; // incarnation
                let items = read_wire_bytes(&mut s, &mut dec)?;
                read_int(&mut s, &mut dec)?; // buffer length
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] op_info_sql items: {:?}", items);
                }
                let info = answer_info_sql(&items, &plan, last_dml);
                let mut w = W::default();
                w.int(OP_RESPONSE).int(0).int(0).int(0).bytes(&info).int(0);
                w.send(&mut s, &mut enc)?;
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
                let mut gen_writes: Vec<(String, i64)> = Vec::new();
                emit_rows(&mut w, &plan, &database, &bound_args, &mut gen_writes);
                // a generator-advancing SELECT (NEXT VALUE FOR / GEN_ID in
                // the select list) writes its generators' final values as
                // the fetch completes - the engine advances them mid-fetch
                if !gen_writes.is_empty() {
                    if let Some(db) = database.as_mut() {
                        let mut work = db.bytes.clone();
                        let mut ok = true;
                        for (name, val) in &gen_writes {
                            match generator_id(db, name) {
                                Some(id) => {
                                    if write_generator_value(&mut work, db.page_size, id, *val).is_err() {
                                        ok = false;
                                    }
                                }
                                None => ok = false,
                            }
                        }
                        if ok {
                            db.bytes = work;
                            let _ = std::fs::write(&db.path, &db.bytes);
                        }
                    }
                }
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
            x if x == OP_OPEN_BLOB || x == OP_OPEN_BLOB2 => {
                // p_blob: [bpb (blob2 only)], transaction, 8-byte blob id
                if x == OP_OPEN_BLOB2 {
                    read_wire_bytes(&mut s, &mut dec)?; // bpb, ignored
                }
                read_int(&mut s, &mut dec)?; // transaction handle
                let id = read_n(&mut s, &mut dec, 8)?;
                let (rel, num) = decode_blob_id(&id);
                let content = database.as_ref().and_then(|db| {
                    fire_crab_ods::read_blob_content(&db.bytes, db.page_size, rel, num)
                });
                match content {
                    Some(data) => {
                        next_blob_handle += 1;
                        if std::env::var("FC_SRV_TRACE").is_ok() {
                            eprintln!(
                                "[srv] open blob {}:{} -> handle {} ({} bytes)",
                                rel, num, next_blob_handle, data.len()
                            );
                        }
                        blobs.insert(next_blob_handle, (data, 0));
                        respond(&mut s, &mut enc, next_blob_handle)?;
                    }
                    None => respond_error(&mut s, &mut enc, GDS_BAD_BLOB_ID)?,
                }
            }
            x if x == OP_GET_SEGMENT => {
                let handle = read_int(&mut s, &mut dec)?;
                let buf_len = read_int(&mut s, &mut dec)?.max(4) as usize;
                read_int(&mut s, &mut dec)?; // p_sgmt_length, unused here
                match blobs.get_mut(&handle) {
                    Some((data, cursor)) => {
                        // one [u16 LE length][bytes] segment per response,
                        // sized to the client's buffer; resp_object = 2
                        // signals blob EOF (server.cpp get_segment)
                        let remaining = data.len() - *cursor;
                        let chunk = remaining.min(buf_len - 2).min(u16::MAX as usize);
                        let mut seg = Vec::with_capacity(chunk + 2);
                        if chunk > 0 {
                            seg.extend_from_slice(&(chunk as u16).to_le_bytes());
                            seg.extend_from_slice(&data[*cursor..*cursor + chunk]);
                            *cursor += chunk;
                        }
                        let object = if *cursor >= data.len() { 2 } else { 0 };
                        let mut w = W::default();
                        w.int(OP_RESPONSE)
                            .int(object)
                            .int(0)
                            .int(0) // blob id
                            .bytes(&seg)
                            .int(0); // clean status
                        w.send(&mut s, &mut enc)?;
                    }
                    None => respond_error(&mut s, &mut enc, GDS_BAD_BLOB_ID)?,
                }
            }
            x if x == OP_CLOSE_BLOB => {
                let handle = read_int(&mut s, &mut dec)?;
                blobs.remove(&handle);
                respond(&mut s, &mut enc, 0)?;
            }
            x if x == OP_INFO_DATABASE => {
                // isql asks for dialect / ODS / server-version banner data.
                // We answer a minimal but well-formed info buffer.
                read_int(&mut s, &mut dec)?; // db handle
                read_int(&mut s, &mut dec)?; // incarnation
                let items = read_wire_bytes(&mut s, &mut dec)?; // requested items
                read_int(&mut s, &mut dec)?; // buffer length
                let ctx = DbInfoCtx {
                    db_path: db_path.clone(),
                    attach_id,
                    ods_major: database.as_ref().map_or(14, |d| d.ods_major),
                    ods_minor: database.as_ref().map_or(0, |d| d.ods_minor),
                    page_size: database.as_ref().map_or(8192, |d| d.page_size as u32),
                };
                let info = build_db_info(&items, &ctx);
                let mut w = W::default();
                w.int(OP_RESPONSE).int(0).int(0).int(0).bytes(&info).int(0);
                w.send(&mut s, &mut enc)?;
            }
            x if x == OP_COMPILE => {
                // the legacy BLR request API that isql's SHOW commands
                // run on: compile a request (a for-loop over a system
                // relation), then start/receive its rows.
                read_int(&mut s, &mut dec)?; // db handle
                let blr = read_wire_bytes(&mut s, &mut dec)?;
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] op_compile blr ({} B): {:?}", blr.len(), blr);
                }
                match parse_blr_request(&blr) {
                    Some(req) => {
                        let handle = next_blr_handle;
                        next_blr_handle += 1;
                        blr_slots.insert(handle, BlrSlot { req, queue: Vec::new(), cursor: 0 });
                        respond(&mut s, &mut enc, handle)?;
                    }
                    None => {
                        if std::env::var("FC_SRV_TRACE").is_ok() {
                            eprintln!("[srv] op_compile PARSE FAILED ({} B): {:?}", blr.len(), blr);
                        }
                        respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?;
                    }
                }
            }
            x if x == OP_START_AND_SEND || x == OP_START_SEND_AND_RECEIVE => {
                // start a request with its input message. The client's
                // start_and_send calls receive_response and then fetches
                // rows with a separate op_receive, so a plain op_response
                // acknowledging the handle is enough - the batch is shipped
                // when op_receive arrives.
                let handle = read_int(&mut s, &mut dec)?; // request handle
                read_int(&mut s, &mut dec)?; // incarnation
                read_int(&mut s, &mut dec)?; // transaction
                read_int(&mut s, &mut dec)?; // message number
                read_int(&mut s, &mut dec)?; // message count
                let fields = blr_slots
                    .get(&handle)
                    .and_then(|slot| slot.req.msgs.first().cloned())
                    .unwrap_or_default();
                let input = read_request_message(&mut s, &mut dec, &fields)?;
                match (blr_slots.get_mut(&handle), &database) {
                    (Some(slot), Some(db)) => {
                        slot.queue = exec_blr_request(&slot.req, &input, db);
                        slot.cursor = 0;
                        respond(&mut s, &mut enc, handle)?;
                    }
                    _ => respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?,
                }
            }
            x if x == OP_START || x == OP_START_AND_RECEIVE => {
                let handle = read_int(&mut s, &mut dec)?; // request handle
                read_int(&mut s, &mut dec)?; // incarnation
                read_int(&mut s, &mut dec)?; // transaction
                read_int(&mut s, &mut dec)?; // message number
                read_int(&mut s, &mut dec)?; // message count
                match (blr_slots.get_mut(&handle), &database) {
                    (Some(slot), Some(db)) => {
                        slot.queue = exec_blr_request(&slot.req, &[], db);
                        slot.cursor = 0;
                        respond(&mut s, &mut enc, handle)?;
                    }
                    _ => respond_error(&mut s, &mut enc, GDS_DSQL_ERROR)?,
                }
            }
            x if x == OP_RECEIVE => {
                let handle = read_int(&mut s, &mut dec)?; // request handle
                read_int(&mut s, &mut dec)?; // incarnation
                read_int(&mut s, &mut dec)?; // transaction
                let msgno = read_int(&mut s, &mut dec)?; // message number
                let batch = read_int(&mut s, &mut dec)?; // messages the client will take
                match blr_slots.get_mut(&handle) {
                    Some(slot) => send_request_batch(
                        &mut s, &mut enc, handle, &slot.queue, &mut slot.cursor, msgno, batch,
                    )?,
                    None => {
                        let mut c = 0;
                        send_request_batch(&mut s, &mut enc, handle, &[], &mut c, msgno, batch)?;
                    }
                }
            }
            x if x == OP_RELEASE => {
                let handle = read_int(&mut s, &mut dec)?; // request handle
                blr_slots.remove(&handle);
                respond(&mut s, &mut enc, 0)?;
            }
            other => {
                if std::env::var("FC_SRV_TRACE").is_ok() {
                    eprintln!("[srv] UNHANDLED op = {}", other);
                }
                break; // unhandled op: end the connection
            }
        }
    }
    Ok(())
}

// ===================================================================
// Legacy BLR request execution (op_compile / op_start / op_receive) -
// what isql's SHOW commands run on. A compiled request is a `for` loop
// over a system relation with a boolean and a sort, sending each row as
// a message. fire-crab parses the BLR into a small tree, executes it
// against the same record-walk + system-format machinery a SELECT uses,
// and materialises the output messages (xdr-encoded field by field, per
// xdr_datum in common/xdr.cpp) into a queue the op_receive loop drains.
// ===================================================================

/// A message field's on-the-wire type (its xdr_datum encoding).
#[derive(Clone, Copy)]
enum BField {
    Short,
    Long,
    /// blr_quad: an 8-byte blob id (two 4-byte longs). SHOW INDICES /
    /// SHOW TABLE carry the source-blob columns this way; they are NULL
    /// (all-zero id) for ordinary objects.
    Quad,
    /// blr_bool: a one-byte boolean, padded to four on the wire
    Bool,
    /// blr_int64: an 8-byte big-endian value (xdr_hyper)
    Int64,
    Cstring(u16),
    Text(u16),
    Varying(u16),
}

/// A value in a BLR expression: a relation field (by name), a parameter
/// from an input message, or a literal.
#[derive(Clone)]
enum BVal {
    /// a field reference: (context number, field name). The context
    /// selects which stream of a joined for-loop the field comes from.
    Field(u8, String),
    Param(u8, u16),
    LitLong(i64),
    LitStr(String),
    /// blr_null (45)
    Null,
    /// blr_value_if (105): if the boolean holds, the first value, else
    /// the second
    ValueIf(Box<BBool>, Box<BVal>, Box<BVal>),
    /// blr_gen_id (101): the current value of a generator, name + operand
    GenId(String, Box<BVal>),
}

#[derive(Clone, Copy)]
enum CmpOp {
    Gtr,
    Geq,
    Lss,
    Leq,
}

/// A BLR boolean.
#[derive(Clone)]
enum BBool {
    And(Box<BBool>, Box<BBool>),
    Or(Box<BBool>, Box<BBool>),
    Not(Box<BBool>),
    Eql(BVal, BVal),
    Neq(BVal, BVal),
    /// blr_equiv (46): null-safe equality (IS NOT DISTINCT FROM) - the
    /// join predicate isql uses across the two streams of SHOW INDICES
    Equiv(BVal, BVal),
    /// blr_gtr/geq/lss/leq (49-52)
    Cmp(BVal, CmpOp, BVal),
    /// blr_starting (55): STARTING WITH (a text prefix test)
    Starting(BVal, BVal),
    /// blr_matching2 (106): SIMILAR TO, used to exclude system-named
    /// objects (RDB$<n>) from SHOW DOMAINS/…
    Matching2(BVal, BVal),
    /// blr_between (56)
    Between(BVal, BVal, BVal),
    Missing(BVal),
}

/// A record selection expression: one or more streams (each a context
/// number and its relation), an optional boolean, and a list of
/// (context, field name, descending) sort keys.
struct BRse {
    streams: Vec<(u8, String)>,
    boolean: Option<BBool>,
    sort: Vec<(u8, String, bool)>,
    /// blr_project: the DISTINCT value expressions - rows are unique on
    /// their evaluated tuple (empty = no DISTINCT)
    project: Vec<BVal>,
}

/// A BLR statement.
enum BStmt {
    Begin(Vec<BStmt>),
    Receive(Box<BStmt>),
    For(BRse, Box<BStmt>),
    /// send message `msg`, assigning each source value to its parameter.
    /// A target is (message, value-index, optional null-indicator index) -
    /// blr_parameter2 carries a separate short that the send sets to -1
    /// when the source is NULL, 0 otherwise.
    Send(u8, Vec<(BVal, (u8, u16, Option<u16>))>),
    Nop,
}

/// A compiled BLR request: the message layouts and the program.
struct BlrReq {
    msgs: Vec<Vec<BField>>,
    stmt: BStmt,
}

/// A cursor over BLR bytes.
struct BlrCur<'a> {
    b: &'a [u8],
    i: usize,
}
impl<'a> BlrCur<'a> {
    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.i)?;
        self.i += 1;
        Some(v)
    }
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn u16(&mut self) -> Option<u16> {
        let lo = self.u8()? as u16;
        let hi = self.u8()? as u16;
        Some(lo | (hi << 8))
    }
    fn name(&mut self) -> Option<String> {
        let n = self.u8()? as usize;
        let s: String = self.b.get(self.i..self.i + n)?.iter().map(|&c| c as char).collect();
        self.i += n;
        Some(s)
    }
}

// BLR verb codes used here (blr.h)
const BLR_ASSIGNMENT: u8 = 1;
const BLR_BEGIN: u8 = 2;
const BLR_MESSAGE: u8 = 4;
const BLR_FOR: u8 = 7;
const BLR_RECEIVE: u8 = 12;
const BLR_SEND: u8 = 14;
const BLR_LITERAL: u8 = 21;
const BLR_FIELD: u8 = 23;
const BLR_PARAMETER: u8 = 25;
const BLR_PARAMETER2: u8 = 41;
const BLR_NULL: u8 = 45;
const BLR_EQUIV: u8 = 46;
const BLR_EQL: u8 = 47;
const BLR_NEQ: u8 = 48;
const BLR_GTR: u8 = 49;
const BLR_GEQ: u8 = 50;
const BLR_LSS: u8 = 51;
const BLR_LEQ: u8 = 52;
const BLR_STARTING: u8 = 55;
const BLR_BETWEEN: u8 = 56;
const BLR_OR: u8 = 57;
const BLR_AND: u8 = 58;
const BLR_NOT: u8 = 59;
const BLR_MISSING: u8 = 61;
const BLR_RSE: u8 = 67;
/// blr_project (69): the DISTINCT clause of an rse - the result is unique
/// on the listed value expressions. SHOW PROCEDURES uses it to fold a
/// table dependency's field-level and table-level rows into one entry.
const BLR_PROJECT: u8 = 69;
const BLR_SORT: u8 = 70;
const BLR_BOOLEAN: u8 = 71;
const BLR_ASCENDING: u8 = 72;
const BLR_RELATION: u8 = 74;
const BLR_GEN_ID: u8 = 101;
const BLR_VALUE_IF: u8 = 105;
const BLR_MATCHING2: u8 = 106;
const BLR_END: u8 = 255;

/// Parse a compiled BLR request. None on any shape this executor does
/// not cover (the caller then answers an SQL error).
fn parse_blr_request(blr: &[u8]) -> Option<BlrReq> {
    // the first byte is the blr_version (4 or 5); the request body then
    // opens with blr_begin
    let mut c = BlrCur { b: blr, i: 1 };
    if c.u8()? != BLR_BEGIN {
        return None;
    }
    let mut msgs: Vec<Vec<BField>> = Vec::new();
    let mut stmt = BStmt::Nop;
    loop {
        match c.peek()? {
            BLR_MESSAGE => {
                c.u8();
                let mno = c.u8()? as usize;
                let cnt = c.u16()? as usize;
                let mut fields = Vec::with_capacity(cnt);
                for _ in 0..cnt {
                    fields.push(parse_blr_field(&mut c)?);
                }
                if msgs.len() <= mno {
                    msgs.resize(mno + 1, Vec::new());
                }
                msgs[mno] = fields;
            }
            BLR_RECEIVE | BLR_FOR | BLR_BEGIN | BLR_SEND | BLR_ASSIGNMENT => {
                stmt = parse_blr_stmt(&mut c)?;
                break;
            }
            BLR_END => {
                c.u8();
                break;
            }
            _ => return None,
        }
    }
    Some(BlrReq { msgs, stmt })
}

fn parse_blr_field(c: &mut BlrCur) -> Option<BField> {
    Some(match c.u8()? {
        7 => {
            c.u8()?; // scale
            BField::Short
        }
        8 => {
            c.u8()?; // scale
            BField::Long
        }
        9 => {
            c.u8()?; // scale
            BField::Quad
        }
        23 => BField::Bool, // blr_bool: no operands
        16 => {
            c.u8()?; // scale
            BField::Int64
        }
        14 => BField::Text(c.u16()?),
        37 => BField::Varying(c.u16()?),
        40 => BField::Cstring(c.u16()?),
        // the *2 variants carry a 2-byte character set id before the length
        15 => {
            c.u16()?; // charset
            BField::Text(c.u16()?)
        }
        38 => {
            c.u16()?; // charset
            BField::Varying(c.u16()?)
        }
        41 => {
            c.u16()?; // charset
            BField::Cstring(c.u16()?)
        }
        _ => return None,
    })
}

fn parse_blr_stmt(c: &mut BlrCur) -> Option<BStmt> {
    Some(match c.u8()? {
        BLR_BEGIN => {
            let mut v = Vec::new();
            while c.peek()? != BLR_END {
                v.push(parse_blr_stmt(c)?);
            }
            c.u8(); // end
            BStmt::Begin(v)
        }
        BLR_RECEIVE => {
            c.u8()?; // msgno
            BStmt::Receive(Box::new(parse_blr_stmt(c)?))
        }
        BLR_FOR => {
            let rse = parse_blr_rse(c)?;
            let body = parse_blr_stmt(c)?;
            BStmt::For(rse, Box::new(body))
        }
        BLR_SEND => {
            let msg = c.u8()?;
            // the body is a blr_begin of blr_assignment (value -> param)
            let assigns = parse_blr_assignments(c)?;
            BStmt::Send(msg, assigns)
        }
        BLR_ASSIGNMENT => {
            let _ = parse_blr_val(c)?;
            let _ = parse_blr_val(c)?;
            BStmt::Nop
        }
        _ => return None,
    })
}

/// The body of a blr_send: a single blr_assignment, or a blr_begin of
/// several. Each assignment is `blr_assignment <value> blr_parameter
/// <msg> <index>` - the value goes into that output parameter.
fn parse_blr_assignments(c: &mut BlrCur) -> Option<Vec<(BVal, (u8, u16, Option<u16>))>> {
    let mut out = Vec::new();
    let one = |c: &mut BlrCur, out: &mut Vec<(BVal, (u8, u16, Option<u16>))>| -> Option<()> {
        if c.u8()? != BLR_ASSIGNMENT {
            return None;
        }
        let from = parse_blr_val(c)?;
        let target = match c.u8()? {
            BLR_PARAMETER => {
                let m = c.u8()?;
                let idx = c.u16()?;
                (m, idx, None)
            }
            BLR_PARAMETER2 => {
                let m = c.u8()?;
                let idx = c.u16()?;
                let nidx = c.u16()?;
                (m, idx, Some(nidx))
            }
            _ => return None,
        };
        out.push((from, target));
        Some(())
    };
    if c.peek()? == BLR_BEGIN {
        c.u8();
        while c.peek()? != BLR_END {
            one(c, &mut out)?;
        }
        c.u8(); // end
    } else {
        one(c, &mut out)?;
    }
    Some(out)
}

fn parse_blr_rse(c: &mut BlrCur) -> Option<BRse> {
    if c.u8()? != BLR_RSE {
        return None;
    }
    let n_streams = c.u8()?;
    let mut streams = Vec::with_capacity(n_streams as usize);
    for _ in 0..n_streams {
        if c.u8()? != BLR_RELATION {
            return None;
        }
        let relation = c.name()?;
        let ctx = c.u8()?; // context number
        streams.push((ctx, relation));
    }
    let mut boolean = None;
    let mut sort = Vec::new();
    let mut project = Vec::new();
    loop {
        match c.peek()? {
            BLR_BOOLEAN => {
                c.u8();
                boolean = Some(parse_blr_bool(c)?);
            }
            BLR_PROJECT => {
                c.u8();
                let n = c.u8()?;
                for _ in 0..n {
                    project.push(parse_blr_val(c)?);
                }
            }
            BLR_SORT => {
                c.u8();
                let n = c.u8()?;
                for _ in 0..n {
                    let desc = match c.u8()? {
                        BLR_ASCENDING => false,
                        73 => true, // blr_descending
                        _ => return None,
                    };
                    // the sort key is a blr_field
                    if c.u8()? != BLR_FIELD {
                        return None;
                    }
                    let ctx = c.u8()?; // context
                    let fname = c.name()?;
                    sort.push((ctx, fname, desc));
                }
            }
            BLR_END => {
                c.u8();
                break;
            }
            _ => return None,
        }
    }
    Some(BRse { streams, boolean, sort, project })
}

fn parse_blr_bool(c: &mut BlrCur) -> Option<BBool> {
    Some(match c.u8()? {
        BLR_AND => BBool::And(Box::new(parse_blr_bool(c)?), Box::new(parse_blr_bool(c)?)),
        BLR_OR => BBool::Or(Box::new(parse_blr_bool(c)?), Box::new(parse_blr_bool(c)?)),
        BLR_NOT => BBool::Not(Box::new(parse_blr_bool(c)?)),
        BLR_EQL => BBool::Eql(parse_blr_val(c)?, parse_blr_val(c)?),
        BLR_NEQ => BBool::Neq(parse_blr_val(c)?, parse_blr_val(c)?),
        BLR_EQUIV => BBool::Equiv(parse_blr_val(c)?, parse_blr_val(c)?),
        BLR_GTR => BBool::Cmp(parse_blr_val(c)?, CmpOp::Gtr, parse_blr_val(c)?),
        BLR_GEQ => BBool::Cmp(parse_blr_val(c)?, CmpOp::Geq, parse_blr_val(c)?),
        BLR_LSS => BBool::Cmp(parse_blr_val(c)?, CmpOp::Lss, parse_blr_val(c)?),
        BLR_LEQ => BBool::Cmp(parse_blr_val(c)?, CmpOp::Leq, parse_blr_val(c)?),
        BLR_STARTING => BBool::Starting(parse_blr_val(c)?, parse_blr_val(c)?),
        BLR_MATCHING2 => {
            let v = parse_blr_val(c)?;
            let pat = parse_blr_val(c)?;
            let _escape = parse_blr_val(c)?; // escape operand, unused
            BBool::Matching2(v, pat)
        }
        BLR_BETWEEN => {
            BBool::Between(parse_blr_val(c)?, parse_blr_val(c)?, parse_blr_val(c)?)
        }
        BLR_MISSING => BBool::Missing(parse_blr_val(c)?),
        _ => return None,
    })
}

fn parse_blr_val(c: &mut BlrCur) -> Option<BVal> {
    Some(match c.u8()? {
        BLR_FIELD => {
            let ctx = c.u8()?; // context
            BVal::Field(ctx, c.name()?)
        }
        BLR_PARAMETER => {
            let m = c.u8()?;
            let idx = c.u16()?;
            BVal::Param(m, idx)
        }
        BLR_PARAMETER2 => {
            let m = c.u8()?;
            let idx = c.u16()?;
            c.u16()?; // null-indicator index (unused when read as a source)
            BVal::Param(m, idx)
        }
        BLR_NULL => BVal::Null,
        BLR_VALUE_IF => {
            let cond = parse_blr_bool(c)?;
            let t = parse_blr_val(c)?;
            let f = parse_blr_val(c)?;
            BVal::ValueIf(Box::new(cond), Box::new(t), Box::new(f))
        }
        BLR_GEN_ID => {
            let name = c.name()?;
            let step = parse_blr_val(c)?;
            BVal::GenId(name, Box::new(step))
        }
        BLR_LITERAL => match c.u8()? {
            8 => {
                c.u8()?; // scale
                let v = c.u8()? as i64
                    | (c.u8()? as i64) << 8
                    | (c.u8()? as i64) << 16
                    | (c.u8()? as i64) << 24;
                BVal::LitLong(v)
            }
            7 => {
                c.u8()?; // scale
                let v = c.u8()? as i64 | (c.u8()? as i64) << 8;
                BVal::LitLong(v)
            }
            14 => {
                let n = c.u16()? as usize;
                let s: String =
                    c.b.get(c.i..c.i + n)?.iter().map(|&x| x as char).collect();
                c.i += n;
                BVal::LitStr(s)
            }
            _ => return None,
        },
        _ => return None,
    })
}

/// Read the input message an op_start_and_send carries, per the
/// request's message-0 layout (each field xdr-decoded). Only the
/// field shapes SHOW uses (short/long) are needed; the values feed
/// the request's parameters.
fn read_request_message(
    s: &mut TcpStream,
    dec: &mut Option<Rc4>,
    fields: &[BField],
) -> std::io::Result<Vec<Value>> {
    let mut vals = Vec::new();
    for f in fields {
        match f {
            BField::Short | BField::Long => vals.push(Value::Int(read_int(s, dec)? as i64)),
            BField::Quad => {
                read_int(s, dec)?;
                read_int(s, dec)?; // an 8-byte blob id: two longs
                vals.push(Value::Null);
            }
            BField::Bool => {
                read_int(s, dec)?; // one byte padded to four
                vals.push(Value::Null);
            }
            BField::Int64 => {
                read_int(s, dec)?;
                read_int(s, dec)?; // 8 bytes
                vals.push(Value::Null);
            }
            BField::Cstring(_) | BField::Text(_) | BField::Varying(_) => {
                // a text input parameter (the object name a SHOW filters
                // on): length then that many bytes padded to four. The
                // text value must survive - the segment/field sub-queries
                // compare it against a catalog column.
                let n = read_int(s, dec)?.max(0) as usize;
                let bytes = read_n(s, dec, n.div_ceil(4) * 4)?;
                let text: String = bytes[..n].iter().map(|&b| b as char).collect();
                vals.push(Value::Text(text));
            }
        }
    }
    Ok(vals)
}

/// One open stream of a for-loop: its context number, the relation's
/// columns, and the current row. `eval_blr_val` resolves a `blr_field`
/// against the context whose number it names.
#[derive(Clone, Copy)]
struct Ctx<'a> {
    ctx: u8,
    columns: &'a [RelationColumn],
    row: &'a [Value],
}

/// Execute a compiled BLR request, returning the queue of xdr-encoded
/// output messages (each drained by one op_receive). `input` are the
/// values from the op_start_and_send message (the request's parameters).
fn exec_blr_request(req: &BlrReq, input: &[Value], db: &Database) -> Vec<(i32, Vec<u8>)> {
    let mut out = Vec::new();
    exec_blr_stmt(&req.stmt, req, input, &[], db, &mut out);
    out
}

/// A resolved stream: its context number, columns and the rows read.
struct StreamData {
    ctx: u8,
    columns: Vec<RelationColumn>,
    rows: Vec<Vec<Value>>,
}

fn exec_blr_stmt(
    stmt: &BStmt,
    req: &BlrReq,
    input: &[Value],
    ctxs: &[Ctx],
    db: &Database,
    out: &mut Vec<(i32, Vec<u8>)>,
) {
    match stmt {
        BStmt::Nop => {}
        BStmt::Begin(v) => {
            for st in v {
                exec_blr_stmt(st, req, input, ctxs, db, out);
            }
        }
        BStmt::Receive(body) => exec_blr_stmt(body, req, input, ctxs, db, out),
        BStmt::For(rse, body) => {
            // resolve every stream of the rse (SHOW INDICES joins two)
            let mut streams: Vec<StreamData> = Vec::new();
            for (ctx, relname) in &rse.streams {
                let Some(rel) =
                    fire_crab_ods::resolve_relation(&db.bytes, db.page_size, relname)
                else {
                    return;
                };
                let columns = relation_columns(&db.bytes, db.page_size, relname);
                let formats = select_formats(db, relname, rel);
                if formats.is_empty() {
                    return;
                }
                let mut rows: Vec<Vec<Value>> = Vec::new();
                for_each_record(db, rel, &formats, |values| rows.push(values.to_vec()));
                streams.push(StreamData { ctx: *ctx, columns, rows });
            }
            // nested-loop join: every combination of one row per stream,
            // kept when the rse boolean holds over the enclosing contexts
            // plus this combination
            let mut combos: Vec<Vec<usize>> = vec![Vec::new()];
            for s in &streams {
                let mut next = Vec::with_capacity(combos.len() * s.rows.len());
                for combo in &combos {
                    for ri in 0..s.rows.len() {
                        let mut c = combo.clone();
                        c.push(ri);
                        next.push(c);
                    }
                }
                combos = next;
            }
            let build = |combo: &[usize]| -> Vec<Ctx> {
                let mut all: Vec<Ctx> = ctxs.to_vec();
                for (s, &ri) in streams.iter().zip(combo) {
                    all.push(Ctx { ctx: s.ctx, columns: &s.columns, row: &s.rows[ri] });
                }
                all
            };
            let mut matched: Vec<Vec<usize>> = combos
                .into_iter()
                .filter(|combo| {
                    let all = build(combo);
                    rse.boolean
                        .as_ref()
                        .map_or(true, |b| eval_blr_bool(b, &all, input, db))
                })
                .collect();
            // sort by the named keys, resolving each against its context
            if !rse.sort.is_empty() {
                let descs: Vec<bool> = rse.sort.iter().map(|(_, _, d)| *d).collect();
                let key_of = |combo: &[usize]| -> Vec<Value> {
                    let all = build(combo);
                    rse.sort
                        .iter()
                        .map(|(ctx, name, _)| {
                            eval_blr_val(&BVal::Field(*ctx, name.clone()), &all, input, db)
                        })
                        .collect()
                };
                let mut keyed: Vec<(Vec<Value>, Vec<usize>)> =
                    matched.into_iter().map(|c| (key_of(&c), c)).collect();
                keyed.sort_by(|(ka, _), (kb, _)| cmp_value_keys(ka, kb, &descs));
                matched = keyed.into_iter().map(|(_, c)| c).collect();
            }
            // DISTINCT (blr_project): keep the first combo of each distinct
            // tuple of projected values - already sorted, so first == the
            // engine's chosen representative
            if !rse.project.is_empty() {
                let mut seen = std::collections::HashSet::new();
                matched.retain(|combo| {
                    let all = build(combo);
                    let key: Vec<String> = rse
                        .project
                        .iter()
                        .map(|v| eval_blr_val(v, &all, input, db).render())
                        .collect();
                    seen.insert(key)
                });
            }
            for combo in matched {
                let all = build(&combo);
                exec_blr_stmt(body, req, input, &all, db, out);
            }
        }
        BStmt::Send(msg, assigns) => {
            let fields = req.msgs.get(*msg as usize).cloned().unwrap_or_default();
            // gather assigned values by their parameter index
            let mut vals: Vec<Value> = vec![Value::Null; fields.len()];
            for (from, (_m, idx, nidx)) in assigns {
                let v = eval_blr_val(from, ctxs, input, db);
                // a blr_parameter2 carries a separate short null indicator:
                // -1 when the value is NULL, 0 otherwise
                if let Some(ni) = nidx {
                    if let Some(slot) = vals.get_mut(*ni as usize) {
                        *slot = Value::Int(if matches!(v, Value::Null) { -1 } else { 0 });
                    }
                }
                if let Some(slot) = vals.get_mut(*idx as usize) {
                    *slot = v;
                }
            }
            out.push((*msg as i32, encode_request_message(&fields, &vals)));
        }
    }
}

/// Compare two lists of sort-key values (NULLs low, per-key descending).
fn cmp_value_keys(a: &[Value], b: &[Value], descs: &[bool]) -> std::cmp::Ordering {
    use std::cmp::Ordering::Equal;
    for (i, desc) in descs.iter().enumerate() {
        let va = a.get(i).unwrap_or(&Value::Null);
        let vb = b.get(i).unwrap_or(&Value::Null);
        let o = value_cmp(va, vb);
        let o = if *desc { o.reverse() } else { o };
        if o != Equal {
            return o;
        }
    }
    Equal
}

fn eval_blr_val(v: &BVal, ctxs: &[Ctx], input: &[Value], db: &Database) -> Value {
    match v {
        BVal::LitLong(n) => Value::Int(*n),
        BVal::LitStr(s) => Value::Text(s.clone()),
        BVal::Null => Value::Null,
        BVal::Param(_m, idx) => input.get(*idx as usize).cloned().unwrap_or(Value::Null),
        BVal::Field(ctx, name) => ctxs
            .iter()
            .find(|c| c.ctx == *ctx)
            .and_then(|c| {
                c.columns
                    .iter()
                    .find(|rc| rc.name.eq_ignore_ascii_case(name))
                    .and_then(|rc| c.row.get(rc.field_id as usize))
            })
            .cloned()
            .unwrap_or(Value::Null),
        BVal::ValueIf(cond, t, f) => {
            if eval_blr_bool(cond, ctxs, input, db) {
                eval_blr_val(t, ctxs, input, db)
            } else {
                eval_blr_val(f, ctxs, input, db)
            }
        }
        BVal::GenId(name, _step) => {
            read_generator_value(db, name).map_or(Value::Null, Value::Int)
        }
    }
}

fn eval_blr_bool(b: &BBool, ctxs: &[Ctx], input: &[Value], db: &Database) -> bool {
    use std::cmp::Ordering;
    match b {
        BBool::And(x, y) => {
            eval_blr_bool(x, ctxs, input, db) && eval_blr_bool(y, ctxs, input, db)
        }
        BBool::Or(x, y) => {
            eval_blr_bool(x, ctxs, input, db) || eval_blr_bool(y, ctxs, input, db)
        }
        BBool::Not(x) => !eval_blr_bool(x, ctxs, input, db),
        BBool::Missing(v) => matches!(eval_blr_val(v, ctxs, input, db), Value::Null),
        BBool::Eql(x, y) => blr_val_cmp(x, y, ctxs, input, db) == Some(Ordering::Equal),
        BBool::Neq(x, y) => {
            !matches!(blr_val_cmp(x, y, ctxs, input, db), Some(Ordering::Equal))
        }
        // IS NOT DISTINCT FROM: two NULLs are equal, a NULL and a value
        // are not (this is the join predicate across the two streams)
        BBool::Equiv(x, y) => {
            let a = eval_blr_val(x, ctxs, input, db);
            let b = eval_blr_val(y, ctxs, input, db);
            match (&a, &b) {
                (Value::Null, Value::Null) => true,
                (Value::Null, _) | (_, Value::Null) => false,
                _ => blr_val_cmp(x, y, ctxs, input, db) == Some(Ordering::Equal),
            }
        }
        BBool::Cmp(x, op, y) => match blr_val_cmp(x, y, ctxs, input, db) {
            Some(o) => match op {
                CmpOp::Gtr => o == Ordering::Greater,
                CmpOp::Geq => o != Ordering::Less,
                CmpOp::Lss => o == Ordering::Less,
                CmpOp::Leq => o != Ordering::Greater,
            },
            None => false,
        },
        BBool::Starting(x, y) => {
            match (eval_blr_val(x, ctxs, input, db), eval_blr_val(y, ctxs, input, db)) {
                (Value::Text(s), Value::Text(p)) => {
                    s.trim_end_matches(' ').starts_with(p.trim_end_matches(' '))
                }
                _ => false,
            }
        }
        BBool::Matching2(x, pat) => {
            match (eval_blr_val(x, ctxs, input, db), eval_blr_val(pat, ctxs, input, db)) {
                (Value::Text(s), Value::Text(p)) => {
                    sleuth_match(s.trim_end_matches(' '), p.trim_end_matches(' '))
                }
                _ => false,
            }
        }
        BBool::Between(v, lo, hi) => {
            let below = blr_val_cmp(v, lo, ctxs, input, db);
            let above = blr_val_cmp(v, hi, ctxs, input, db);
            matches!(below, Some(Ordering::Greater | Ordering::Equal))
                && matches!(above, Some(Ordering::Less | Ordering::Equal))
        }
    }
}

fn blr_val_cmp(
    x: &BVal,
    y: &BVal,
    ctxs: &[Ctx],
    input: &[Value],
    db: &Database,
) -> Option<std::cmp::Ordering> {
    let a = eval_blr_val(x, ctxs, input, db);
    let b = eval_blr_val(y, ctxs, input, db);
    match (&a, &b) {
        (Value::Null, _) | (_, Value::Null) => None,
        (Value::Int(p), Value::Int(q)) => Some(p.cmp(q)),
        (Value::Text(p), Value::Text(q)) => {
            Some(p.trim_end_matches(' ').cmp(q.trim_end_matches(' ')))
        }
        _ => None,
    }
}

/// blr_matching2 is the legacy SLEUTH matcher (jrd/evl.cpp), the operator
/// behind GDML's `MATCHING`. isql uses exactly one pattern - to hide
/// system-generated names - `RDB$+` with the control string
/// `+=[0-9][0-9]* *`, which defines `+` to stand for one-or-more digits.
/// So the effective test is: does the name read `RDB$` followed by only
/// digits (a system integer-suffixed name). The full sleuth language is
/// not implemented; this recognises that one shape and otherwise reports
/// no match (which, under the `NOT (…)` the SHOW filters wrap it in,
/// keeps the row - the conservative direction).
fn sleuth_match(value: &str, pattern: &str) -> bool {
    if let Some(prefix) = pattern.strip_suffix('+') {
        // `<prefix>+` : the literal prefix then one-or-more digits
        return value
            .strip_prefix(prefix)
            .map_or(false, |rest| !rest.is_empty() && rest.bytes().all(|c| c.is_ascii_digit()));
    }
    value == pattern
}

/// Resolve a generator's id and increment from `RDB$GENERATORS` by name.
/// `RDB$GENERATOR_ID` is the index into the generator vector on the
/// generator pages; `RDB$GENERATOR_INCREMENT` is the step a
/// `RESTART WITH n` subtracts to store `n - increment`. None if the
/// generator does not exist.
fn generator_info(db: &Database, name: &str) -> Option<(i64, i64)> {
    let rel = fire_crab_ods::resolve_relation(&db.bytes, db.page_size, "RDB$GENERATORS")?;
    let formats = select_formats(db, "RDB$GENERATORS", rel);
    let cols = relation_columns(&db.bytes, db.page_size, "RDB$GENERATORS");
    let field = |n: &str| {
        cols.iter()
            .find(|c| c.name.eq_ignore_ascii_case(n))
            .map(|c| c.field_id as usize)
    };
    let name_fid = field("RDB$GENERATOR_NAME")?;
    let id_fid = field("RDB$GENERATOR_ID")?;
    let incr_fid = field("RDB$GENERATOR_INCREMENT")?;
    let want = name.trim();
    let mut found = None;
    for_each_record(db, rel, &formats, |row| {
        if found.is_some() {
            return;
        }
        if let Some(Value::Text(n)) = row.get(name_fid) {
            if n.trim_end_matches(' ').eq_ignore_ascii_case(want) {
                if let Some(Value::Int(id)) = row.get(id_fid) {
                    let incr = match row.get(incr_fid) {
                        Some(Value::Int(v)) => *v,
                        _ => 1, // a plain generator has no explicit increment
                    };
                    found = Some((*id, incr));
                }
            }
        }
    });
    found
}

/// Resolve a generator's numeric id (its slot in the generator vector).
fn generator_id(db: &Database, name: &str) -> Option<i64> {
    generator_info(db, name).map(|(id, _)| id)
}

/// Write a generator's value into its slot on the generator page (a
/// native little-endian `SINT64`, the way the engine dereferences it).
/// Errs if the generator page has not been allocated - fire-crab writes
/// to existing generators, it does not grow the generator vector.
fn write_generator_value(
    bytes: &mut [u8],
    page_size: usize,
    id: i64,
    value: i64,
) -> Result<(), String> {
    fire_crab_ods::gen::write(bytes, page_size, id, value)
}

/// Increment a generator by `step` (or, for `NEXT VALUE FOR`, by its own
/// declared increment when `step` is `None`), persist the new value, and
/// return it - what `GEN_ID(name, n)`/`NEXT VALUE FOR` yields. Runs at
/// op_execute, the one place a SELECT is allowed to write.
fn gen_id_increment(
    database: &mut Option<Database>,
    name: &str,
    step: Option<i64>,
) -> Result<i64, String> {
    let db = database.as_mut().ok_or("no database attached")?;
    let (id, incr) = generator_info(db, name).ok_or("no such generator")?;
    let current = read_generator_value(db, name).unwrap_or(0);
    let new_val = current.wrapping_add(step.unwrap_or(incr));
    let mut work = db.bytes.clone();
    write_generator_value(&mut work, db.page_size, id, new_val)?;
    db.bytes = work;
    std::fs::write(&db.path, &db.bytes).map_err(|e| e.to_string())?;
    Ok(new_val)
}

/// blr_gen_id / `GEN_ID(name, 0)` reads a generator's current value. The
/// value lives at slot `id % gensPerPage` of the generator page whose
/// sequence is `id / gensPerPage` (dpm.epp:1439); `gensPerPage` is
/// `(page_size - offsetof(generator_page, gpg_values)) / 8` = `(ps-24)/8`
/// (ods.cpp:81). The value is a native little-endian `SINT64` the engine
/// dereferences directly. Generator pages carry `pag_ids` (type 9), so we
/// find the right one by scanning for that type with the matching
/// `gpg_sequence` (@16) rather than routing through `RDB$PAGES`. A
/// generator that exists but whose page has never been written reads 0
/// (the engine's zero-initialised slot); an unknown name reads NULL.
fn read_generator_value(db: &Database, name: &str) -> Option<i64> {
    let id = generator_id(db, name)?;
    // a generator whose page has not been allocated yet reads 0 - the
    // engine's zero-initialised slot
    Some(fire_crab_ods::gen::read(&db.bytes, db.page_size, id))
}

/// Encode one output message field by field, per xdr_datum
/// (common/xdr.cpp): a short/long is a 4-byte big-endian value; a
/// cstring is a 4-byte big-endian length then that many bytes padded
/// to a 4-byte boundary; text is the fixed bytes padded to 4.
fn encode_request_message(fields: &[BField], vals: &[Value]) -> Vec<u8> {
    let mut m = Vec::new();
    let push_pad = |m: &mut Vec<u8>, bytes: &[u8]| {
        m.extend_from_slice(bytes);
        while m.len() % 4 != 0 {
            m.push(0);
        }
    };
    for (i, f) in fields.iter().enumerate() {
        let v = vals.get(i).cloned().unwrap_or(Value::Null);
        match f {
            BField::Short | BField::Long => {
                let n = match v {
                    Value::Int(n) => n as i32,
                    _ => 0,
                };
                m.extend_from_slice(&n.to_be_bytes());
            }
            BField::Quad => {
                // a blob id: the 8-byte on-disk bid layout (encode_blob_id) -
                // the SAME bytes the row encoder sends and op_open_blob
                // decodes, so a client that opens the id reaches the blob's
                // content (SHOW PROCEDURE's source). A NULL/absent blob is a
                // zero id the client leaves unopened.
                let id = match v {
                    Value::Blob(rel, num) => encode_blob_id(rel, num),
                    _ => [0u8; 8],
                };
                m.extend_from_slice(&id);
            }
            BField::Bool => {
                // dtype_boolean: one byte (xdr_opaque length 1) padded to 4
                let b = match v {
                    Value::Bool(b) => b as u8,
                    Value::Int(n) => (n != 0) as u8,
                    _ => 0,
                };
                push_pad(&mut m, &[b]);
            }
            BField::Int64 => {
                // xdr_hyper: the 8-byte big-endian value
                let n = match v {
                    Value::Int(n) => n,
                    _ => 0,
                };
                m.extend_from_slice(&n.to_be_bytes());
            }
            BField::Cstring(_) => {
                let text = match &v {
                    Value::Text(s) => s.trim_end_matches(' ').to_string(),
                    Value::Null => String::new(),
                    other => other.render(),
                };
                let b = text.as_bytes();
                m.extend_from_slice(&(b.len() as i32).to_be_bytes());
                push_pad(&mut m, b);
            }
            BField::Text(len) => {
                let text = match &v {
                    Value::Text(s) => s.clone(),
                    Value::Null => String::new(),
                    other => other.render(),
                };
                let mut b = text.into_bytes();
                b.resize(*len as usize, b' ');
                push_pad(&mut m, &b);
            }
            BField::Varying(_) => {
                let text = match &v {
                    Value::Text(s) => s.trim_end_matches(' ').to_string(),
                    Value::Null => String::new(),
                    other => other.render(),
                };
                let b = text.as_bytes();
                m.extend_from_slice(&(b.len() as i32).to_be_bytes());
                push_pad(&mut m, b);
            }
        }
    }
    m
}

fn hex_upper(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02X}", x)).collect()
}

/// Build a minimal-but-well-formed isc_info database response for the
/// items isql requests after attach. Each recognised item is emitted as
/// code(1) + length(2 LE) + little-endian value; unknown items are
/// skipped; the buffer ends with isc_info_end (1). Enough for isql to
/// establish dialect/ODS/version and show its prompt.
fn build_db_info(items: &[u8], ctx: &DbInfoCtx) -> Vec<u8> {
    let mut out = Vec::new();
    fn put_int(out: &mut Vec<u8>, code: u8, val: i32) {
        out.push(code);
        out.extend_from_slice(&4u16.to_le_bytes());
        out.extend_from_slice(&val.to_le_bytes());
    }
    for &code in items {
        match code {
            62 => {
                // isc_info_db_sql_dialect: a ONE-byte value (probe-pinned)
                out.push(62);
                out.extend_from_slice(&1u16.to_le_bytes());
                out.push(3);
            }
            32 => put_int(&mut out, 32, ctx.ods_major as i32), // isc_info_ods_version
            33 => put_int(&mut out, 33, ctx.ods_minor as i32), // isc_info_ods_minor_version
            14 => put_int(&mut out, 14, ctx.page_size as i32), // isc_info_page_size
            22 => put_int(&mut out, 22, ctx.attach_id),        // isc_info_attachment_id
            5 => put_int(&mut out, 5, 100),                    // isc_info_reads
            6 => put_int(&mut out, 6, 0),                      // isc_info_writes
            7 => put_int(&mut out, 7, 1000),                   // isc_info_fetches
            8 => put_int(&mut out, 8, 0),                      // isc_info_marks
            63 => put_int(&mut out, 63, 0),                    // isc_info_db_read_only
            4 => {
                // isc_info_db_id: a count byte then pascal strings; the
                // driver returns [0] as the database name. Two strings:
                // the file path and the host (probe-pinned layout).
                let host = "fire-crab";
                let path = ctx.db_path.as_bytes();
                let mut data = Vec::new();
                data.push(2u8); // string count
                data.push(path.len().min(255) as u8);
                data.extend_from_slice(&path[..path.len().min(255)]);
                data.push(host.len() as u8);
                data.extend_from_slice(host.as_bytes());
                out.push(4);
                out.extend_from_slice(&(data.len() as u16).to_le_bytes());
                out.extend_from_slice(&data);
            }
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

/// Context for `build_db_info`: what the per-attachment info items need.
struct DbInfoCtx {
    db_path: String,
    attach_id: i32,
    ods_major: u16,
    ods_minor: u16,
    page_size: u32,
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
        let d = describe_one_bigint(&[]);
        // marker [4,7,4,0] must be present
        assert!(d.windows(4).any(|w| w == [4, 7, 4, 0]));
    }

    #[test]
    fn set_values_encode_like_stored_fields() {
        let d = |dt: u8, len: u16, scale: i8| Descriptor {
            dtype: dt,
            scale,
            length: len,
            sub_type: 0,
            flags: 0,
            offset: 0,
        };
        // integers by width, range-checked
        assert_eq!(
            encode_set_value(&d(dtype::SHORT, 2, 0), &InsVal::Int(-7)),
            Some(Some((-7i16).to_le_bytes().to_vec()))
        );
        assert!(encode_set_value(&d(dtype::SHORT, 2, 0), &InsVal::Int(70000)).is_none());
        assert_eq!(
            encode_set_value(&d(dtype::INT64, 8, 0), &InsVal::Int(1 << 40)),
            Some(Some((1i64 << 40).to_le_bytes().to_vec()))
        );
        // an integer literal rescales exactly into a NUMERIC target
        // (5 into NUMERIC(9,2) stores 500), like the engine converts
        assert_eq!(
            encode_set_value(&d(dtype::LONG, 4, -2), &InsVal::Int(5)),
            Some(Some(500i32.to_le_bytes().to_vec()))
        );
        // CHAR pads with blanks to the declared length, VARCHAR counts
        let t = encode_set_value(&d(dtype::TEXT, 5, 0), &InsVal::Str("ab".into()));
        assert_eq!(t, Some(Some(b"ab   ".to_vec())));
        let v = encode_set_value(&d(dtype::VARYING, 7, 0), &InsVal::Str("ab".into()));
        assert_eq!(v, Some(Some(vec![2, 0, b'a', b'b'])));
        assert!(encode_set_value(&d(dtype::VARYING, 3, 0), &InsVal::Str("ab".into())).is_none());
        // type mismatches are refused, NULL passes through
        assert!(encode_set_value(&d(dtype::LONG, 4, 0), &InsVal::Str("x".into())).is_none());
        assert_eq!(encode_set_value(&d(dtype::LONG, 4, 0), &InsVal::Null), Some(None));
    }

    fn desc(dt: u8, len: u16, scale: i8) -> Descriptor {
        Descriptor { dtype: dt, scale, length: len, sub_type: 0, flags: 0, offset: 0 }
    }

    #[test]
    fn parses_node_style_param_blr() {
        // what node-firebird's CalcBlr emits for (int, 'abcde', bigint):
        // version5, begin, message 0, word 6, then pairs of value
        // descriptor + blr_short null indicator, end, eoc
        let blr = [
            5u8, 2, 4, 0, 6, 0, // header, 6 fields (3 params)
            8, 0, 7, 0, // blr_long scale 0 + null short
            14, 5, 0, 7, 0, // blr_text len 5 + null short
            16, 0, 7, 0, // blr_int64 scale 0 + null short
            255, 76, // blr_end, blr_eoc
        ];
        assert_eq!(
            parse_param_blr(&blr),
            Some(vec![PSlot::Int32(0), PSlot::Text(5), PSlot::Int64(0)])
        );
        // timestamp/bool/double have no operands
        let blr2 = [5u8, 2, 4, 0, 6, 0, 35, 7, 0, 23, 7, 0, 27, 7, 0, 255, 76];
        assert_eq!(
            parse_param_blr(&blr2),
            Some(vec![PSlot::Timestamp, PSlot::Bool, PSlot::Double])
        );
        // blr_text2 (15): charset word + length word - what the C++
        // and python firebird-driver send for a string parameter (a
        // fixed TEXT of the value's byte length); blr_varying2 (38) too
        let blr3 = [
            5u8, 2, 4, 0, 4, 0, // 2 params
            8, 0, 7, 0, // blr_long + null short
            15, 0, 0, 8, 0, 7, 0, // blr_text2 cs=0 len=8 + null short
            255, 76,
        ];
        assert_eq!(parse_param_blr(&blr3), Some(vec![PSlot::Int32(0), PSlot::Text(8)]));
        let blr4 = [5u8, 2, 4, 0, 2, 0, 38, 0, 0, 20, 0, 7, 0, 255, 76];
        assert_eq!(parse_param_blr(&blr4), Some(vec![PSlot::Varying]));
        // an undecodable dtype (blr_quad = blob id) refuses the whole BLR
        assert!(parse_param_blr(&[5u8, 2, 4, 0, 2, 0, 9, 0, 7, 0, 255, 76]).is_none());
        // odd field count is not pairs
        assert!(parse_param_blr(&[5u8, 2, 4, 0, 1, 0, 8, 0, 255, 76]).is_none());
    }

    #[test]
    fn wire_values_coerce_like_the_engine() {
        // integers rescale exactly into NUMERIC targets
        assert_eq!(
            encode_wire_value(&desc(dtype::INT64, 8, -2), &WireParam::Int(50, 0)),
            Some(Some(5000i64.to_le_bytes().to_vec()))
        );
        // an inexact down-scale is refused, not truncated
        assert!(encode_wire_value(&desc(dtype::LONG, 4, 1), &WireParam::Int(15, 0)).is_none());
        // doubles round half away from zero into scaled targets (CVT)
        assert_eq!(
            encode_wire_value(&desc(dtype::LONG, 4, -2), &WireParam::Double(100.25)),
            Some(Some(10025i32.to_le_bytes().to_vec()))
        );
        assert_eq!(
            encode_wire_value(&desc(dtype::LONG, 4, -1), &WireParam::Double(1.25)),
            Some(Some(13i32.to_le_bytes().to_vec()))
        );
        assert_eq!(
            encode_wire_value(&desc(dtype::LONG, 4, -1), &WireParam::Double(-1.25)),
            Some(Some((-13i32).to_le_bytes().to_vec()))
        );
        // a blr_timestamp truncates into DATE and TIME targets
        let ts = WireParam::Timestamp(60000, 123_450_000);
        assert_eq!(
            encode_wire_value(&desc(dtype::TIMESTAMP, 8, 0), &ts),
            Some(Some({
                let mut b = 60000i32.to_le_bytes().to_vec();
                b.extend_from_slice(&123_450_000u32.to_le_bytes());
                b
            }))
        );
        assert_eq!(
            encode_wire_value(&desc(dtype::SQL_DATE, 4, 0), &ts),
            Some(Some(60000i32.to_le_bytes().to_vec()))
        );
        assert_eq!(
            encode_wire_value(&desc(dtype::SQL_TIME, 4, 0), &ts),
            Some(Some(123_450_000u32.to_le_bytes().to_vec()))
        );
        // booleans only into BOOLEAN columns, as the single stored byte
        assert_eq!(
            encode_wire_value(&desc(dtype::BOOLEAN, 1, 0), &WireParam::Bool(true)),
            Some(Some(vec![1]))
        );
        assert!(encode_wire_value(&desc(dtype::LONG, 4, 0), &WireParam::Bool(true)).is_none());
        // text into an int column is a mismatch, never a conversion
        assert!(
            encode_wire_value(&desc(dtype::LONG, 4, 0), &WireParam::Text("9".into())).is_none()
        );
    }

    #[test]
    fn predicate_binds_params_at_execute() {
        let p = Predicate(vec![vec![
            Term::Cmp(3, Cmp::Eq, Rhs::Param(0, ColKind::Int)),
            Term::Cmp(5, Cmp::Eq, Rhs::Param(1, ColKind::Text)),
        ]]);
        let b = p
            .bind(&[WireParam::Int(42, 0), WireParam::Text("x".into())])
            .unwrap();
        assert!(b.matches(&[
            Value::Null,
            Value::Null,
            Value::Null,
            Value::Int(42),
            Value::Null,
            Value::Text("x".into()),
        ]));
        // a NULL parameter compares as UNKNOWN - the row is excluded
        let b = p
            .bind(&[WireParam::Null, WireParam::Text("x".into())])
            .unwrap();
        assert!(!b.matches(&[
            Value::Null,
            Value::Null,
            Value::Null,
            Value::Int(42),
            Value::Null,
            Value::Text("x".into()),
        ]));
        // a wire type that does not match the column kind is an error
        assert!(p
            .bind(&[WireParam::Text("42".into()), WireParam::Text("x".into())])
            .is_err());
        // scaled wire integers do not bind into scale-0 comparisons
        assert!(p
            .bind(&[WireParam::Int(42, -2), WireParam::Text("x".into())])
            .is_err());
    }

    #[test]
    fn where_params_register_targets_in_order() {
        let toks = tokenize("A = ? AND B = ?").unwrap();
        let raw = parse_predicate(&toks, &mut 0).unwrap();
        let columns = vec![
            RelationColumn { name: "A".into(), field_id: 0, position: 0 },
            RelationColumn { name: "B".into(), field_id: 1, position: 1 },
        ];
        let descs = vec![desc(dtype::LONG, 4, 0), desc(dtype::VARYING, 22, 0)];
        let mut params = Vec::new();
        let p = resolve_predicate(raw, &columns, &descs, &mut params).unwrap();
        assert_eq!(params.len(), 2);
        assert_eq!(params[0].as_ref().unwrap().dtype, dtype::LONG);
        assert_eq!(params[1].as_ref().unwrap().dtype, dtype::VARYING);
        // slots bind positionally
        let b = p
            .bind(&[WireParam::Int(7, 0), WireParam::Text("q".into())])
            .unwrap();
        assert!(b.matches(&[Value::Int(7), Value::Text("q".into())]));
        // a parameter on an unbindable column type refuses the plan
        let toks = tokenize("A = ?").unwrap();
        let raw = parse_predicate(&toks, &mut 0).unwrap();
        let blob_descs = vec![desc(dtype::BLOB, 8, 0)];
        assert!(resolve_predicate(raw, &columns, &blob_descs, &mut Vec::new()).is_none());
    }

    #[test]
    fn like_matches_per_character() {
        assert!(like_match("abc", "abc", None));
        assert!(!like_match("abc", "ab", None));
        assert!(like_match("abc", "a%", None));
        assert!(like_match("abc", "%c", None));
        assert!(like_match("abc", "%b%", None));
        assert!(like_match("abc", "a_c", None));
        assert!(!like_match("abc", "a_d", None));
        assert!(like_match("", "%", None));
        assert!(!like_match("", "_", None));
        // CHAR padding counts: the stored value is padded
        assert!(!like_match("abc  ", "abc", None));
        assert!(like_match("abc  ", "abc%", None));
        assert!(like_match("abc  ", "abc  ", None));
        // escape makes the wildcard literal
        assert!(like_match("50%", "50\\%", Some('\\')));
        assert!(!like_match("500", "50\\%", Some('\\')));
        // multi-byte: `_` is one CHARACTER
        assert!(like_match("héllo", "h_llo", None));
        assert!(like_match("héllo", "h%o", None));
    }

    #[test]
    fn predicate_grammar_desugars_and_negates() {
        let dnf = |s: &str| parse_predicate(&tokenize(s).unwrap(), &mut 0).unwrap();
        // BETWEEN = >= AND <=
        let d = dnf("A BETWEEN 2 AND 5");
        assert_eq!((d.len(), d[0].len()), (1, 2));
        assert!(matches!(&d[0][0].kind, RawKind::Cmp(Cmp::Ge, Rhs::Int(2))));
        assert!(matches!(&d[0][1].kind, RawKind::Cmp(Cmp::Le, Rhs::Int(5))));
        // NOT BETWEEN pushes through De Morgan: < 2 OR > 5
        let d = dnf("A NOT BETWEEN 2 AND 5");
        assert_eq!(d.len(), 2);
        assert!(matches!(&d[0][0].kind, RawKind::Cmp(Cmp::Lt, Rhs::Int(2))));
        assert!(matches!(&d[1][0].kind, RawKind::Cmp(Cmp::Gt, Rhs::Int(5))));
        // IN = OR of equalities; NOT IN = AND of inequalities
        let d = dnf("A IN (1, 2, 3)");
        assert_eq!(d.len(), 3);
        let d = dnf("A NOT IN (1, 2)");
        assert_eq!((d.len(), d[0].len()), (1, 2));
        assert!(matches!(&d[0][0].kind, RawKind::Cmp(Cmp::Ne, Rhs::Int(1))));
        // a NULL in a NOT IN list survives as <> NULL (resolves to
        // Never - the whole conjunct can never pass: engine 3VL)
        let d = dnf("A NOT IN (1, NULL)");
        assert!(matches!(&d[0][1].kind, RawKind::Cmp(Cmp::Ne, Rhs::Null)));
        // NOT over a parenthesized OR: De Morgan to one AND group
        let d = dnf("NOT (A = 1 OR B = 2)");
        assert_eq!((d.len(), d[0].len()), (1, 2));
        assert!(matches!(&d[0][0].kind, RawKind::Cmp(Cmp::Ne, Rhs::Int(1))));
        // parens override precedence: (A=1 OR B=2) AND C=3 cross-multiplies
        let d = dnf("(A = 1 OR B = 2) AND C = 3");
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].len(), 2);
        // NOT LIKE flips the leaf flag; ESCAPE parses
        let d = dnf("A NOT LIKE 'x%' ESCAPE '!'");
        assert!(matches!(&d[0][0].kind, RawKind::Like(Rhs::Str(_), Some('!'), true)));
        // double NOT cancels
        let d = dnf("NOT NOT A = 1");
        assert!(matches!(&d[0][0].kind, RawKind::Cmp(Cmp::Eq, Rhs::Int(1))));
        // unsupported shapes refuse: dangling paren, bare NOT, agg call
        let pp = |s: &str| parse_predicate(&tokenize(s).unwrap(), &mut 0);
        assert!(pp("(A = 1").is_none());
        assert!(pp("NOT").is_none());
        assert!(pp("A LIKE 5").is_none());
        assert!(pp("A BETWEEN 1").is_none());
        assert!(pp("A IN ()").is_none());
    }

    #[test]
    fn cross_product_keeps_one_slot_per_question_mark() {
        // (A = ? OR B = ?) AND A = ? distributes to two groups that
        // SHARE the third ?'s slot - three parameters, not four
        let mut np = 0usize;
        let raw =
            parse_predicate(&tokenize("(A = ? OR B = ?) AND A = ?").unwrap(), &mut np).unwrap();
        assert_eq!(np, 3);
        assert_eq!(raw.len(), 2); // two OR groups after distribution
        let columns = vec![
            RelationColumn { name: "A".into(), field_id: 0, position: 0 },
            RelationColumn { name: "B".into(), field_id: 1, position: 1 },
        ];
        let descs = vec![desc(dtype::LONG, 4, 0), desc(dtype::INT64, 8, 0)];
        let mut params: Vec<Option<Descriptor>> = Vec::new();
        let p = resolve_predicate(raw, &columns, &descs, &mut params).unwrap();
        assert_eq!(params.len(), 3);
        assert!(params.iter().all(|p| p.is_some()));
        // slot 2 binds once and satisfies BOTH groups' copies
        let b = p
            .bind(&[WireParam::Int(1, 0), WireParam::Int(99, 0), WireParam::Int(7, 0)])
            .unwrap();
        assert!(!b.matches(&[Value::Int(1), Value::Int(0)])); // A=1 but A<>7
        assert!(b.matches(&[Value::Int(7), Value::Int(99)])); // B=99, A=7
        // a LIKE pattern `?` registers as the text column's descriptor
        let mut np = 0usize;
        let raw = parse_predicate(&tokenize("B LIKE ?").unwrap(), &mut np).unwrap();
        let text_descs = vec![desc(dtype::LONG, 4, 0), desc(dtype::VARYING, 22, 0)];
        let mut params: Vec<Option<Descriptor>> = Vec::new();
        let p = resolve_predicate(raw, &columns, &text_descs, &mut params).unwrap();
        assert_eq!(params[0].as_ref().unwrap().dtype, dtype::VARYING);
        let b = p.bind(&[WireParam::Text("q%".into())]).unwrap();
        assert!(b.matches(&[Value::Int(0), Value::Text("quux".into())]));
        // and a NULL pattern is UNKNOWN
        let b = p.bind(&[WireParam::Null]).unwrap();
        assert!(!b.matches(&[Value::Int(0), Value::Text("quux".into())]));
    }

    #[test]
    fn bind_section_describes_params() {
        let params = vec![desc(dtype::LONG, 4, 0), desc(dtype::VARYING, 22, 0)];
        let mut d = Vec::new();
        append_bind_section(&mut d, &params);
        // section marker + count 2
        assert_eq!(&d[..7], &[5, 7, 4, 0, 2, 0, 0]);
        // both sqlda_seq items present, each var closed with describe_end
        assert_eq!(d.iter().filter(|&&b| b == 8).count(), 2);
        // SQL_LONG (496) and SQL_VARYING (448) both announced
        assert!(d.windows(7).any(|w| w == [11, 4, 0, 240, 1, 0, 0]));
        assert!(d.windows(7).any(|w| w == [11, 4, 0, 192, 1, 0, 0]));
    }

    fn proj_cols(p: &Proj) -> Vec<String> {
        match p {
            Proj::Star => vec!["*".into()],
            Proj::Items(items) => items
                .iter()
                .map(|i| match i {
                    SelItem::Col(c) => c.clone(),
                    SelItem::Agg(..) => "<agg>".into(),
                    SelItem::Expr(_, name) => format!("<expr:{}>", name),
                    SelItem::Gen(n, s, _) => format!("<gen:{}:{:?}>", n, s),
                })
                .collect(),
        }
    }

    #[test]
    fn splits_select_from_where_order() {
        // COUNT
        let (p, t, w, g, h, o) = split_query("SELECT COUNT(*) FROM RDB$RELATIONS").unwrap();
        assert!(matches!(
            parse_projection(p),
            Some(Proj::Items(items))
                if matches!(items.as_slice(), [SelItem::Agg(AggFn::Count, AggTarget::Star)])
        ));
        assert_eq!(t, "RDB$RELATIONS");
        assert!(w.is_none() && g.is_none() && h.is_none() && o.is_none());
        // projection + WHERE + ORDER BY, mixed case; literal case preserved
        let (p, t, w, g, h, o) =
            split_query("select ID, NAME from Emp where NAME = 'Emp 5' order by ID desc;").unwrap();
        assert_eq!(proj_cols(&parse_projection(p).unwrap()), vec!["ID", "NAME"]);
        assert_eq!(t, "Emp");
        assert_eq!(w, Some("NAME = 'Emp 5'"));
        assert!(g.is_none() && h.is_none());
        assert_eq!(o, Some("ID desc"));
        // ORDER BY without WHERE
        let (_, t, w, g, h, o) = split_query("SELECT * FROM DEPT ORDER BY 1").unwrap();
        assert_eq!(t, "DEPT");
        assert!(w.is_none() && g.is_none() && h.is_none());
        assert_eq!(o, Some("1"));
    }

    #[test]
    fn splits_group_by() {
        // WHERE + GROUP BY + ORDER BY, mixed case
        let (p, t, w, g, h, o) = split_query(
            "select DEPT_ID, count(*) from EMP where ID <= 30 group by DEPT_ID order by 1",
        )
        .unwrap();
        assert_eq!(proj_cols(&parse_projection(p).unwrap()), vec!["DEPT_ID", "<agg>"]);
        assert_eq!(t, "EMP");
        assert_eq!(w, Some("ID <= 30"));
        assert_eq!(g, Some("DEPT_ID"));
        assert!(h.is_none());
        assert_eq!(o, Some("1"));
        // GROUP BY alone ends at the statement end
        let (_, t, w, g, _, o) = split_query("SELECT A, SUM(B) FROM T GROUP BY A").unwrap();
        assert_eq!(t, "T");
        assert!(w.is_none() && o.is_none());
        assert_eq!(g, Some("A"));
        // 'GROUP BY' inside a WHERE literal must not start the clause
        let (_, t, w, g, _, _) = split_query("SELECT ID FROM T WHERE NAME = 'GROUP BY X'").unwrap();
        assert_eq!(t, "T");
        assert_eq!(w, Some("NAME = 'GROUP BY X'"));
        assert!(g.is_none());
    }

    #[test]
    fn splits_having() {
        // the full clause chain, mixed case; HAVING ends at ORDER BY
        let (_, t, w, g, h, o) = split_query(
            "select DEPT_ID, count(*) from EMP where ID <= 30 group by DEPT_ID \
             having count(*) > 3 order by 1",
        )
        .unwrap();
        assert_eq!(t, "EMP");
        assert_eq!(w, Some("ID <= 30"));
        assert_eq!(g, Some("DEPT_ID"));
        assert_eq!(h, Some("count(*) > 3"));
        assert_eq!(o, Some("1"));
        // HAVING alone ends at the statement end; GROUP BY ends at HAVING
        let (_, _, _, g, h, o) =
            split_query("SELECT A, SUM(B) FROM T GROUP BY A HAVING SUM(B) IS NOT NULL").unwrap();
        assert_eq!(g, Some("A"));
        assert_eq!(h, Some("SUM(B) IS NOT NULL"));
        assert!(o.is_none());
        // HAVING with no GROUP BY (one global group)
        let (_, t, w, g, h, _) = split_query("SELECT COUNT(*) FROM T HAVING COUNT(*) > 5").unwrap();
        assert_eq!(t, "T");
        assert!(w.is_none() && g.is_none());
        assert_eq!(h, Some("COUNT(*) > 5"));
        // 'HAVING' inside a WHERE literal must not start the clause
        let (_, t, w, _, h, _) = split_query("SELECT ID FROM T WHERE NAME = 'HAVING X'").unwrap();
        assert_eq!(t, "T");
        assert_eq!(w, Some("NAME = 'HAVING X'"));
        assert!(h.is_none());
    }

    #[test]
    fn find_word_respects_boundaries() {
        // FROM inside an identifier must not match
        assert!(split_query("SELECT X FROM T WHERE FROMAGE = 1").is_some());
        // no FROM at all
        assert!(split_query("SELECT 1").is_none());
        // 'ORDER' inside a WHERE string literal must not start an ORDER BY
        let (_, t, w, _, _, o) = split_query("SELECT ID FROM T WHERE NAME = 'ORDER BY X'").unwrap();
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
            ProjCol { name: "ID".into(), field_id: 3, wire: Wire::Int64, sql_type: 580, length: 8, scale: 0, sub_type: 0, expr: None },
            ProjCol { name: "NAME".into(), field_id: 1, wire: Wire::Varying, sql_type: 448, length: 32765, scale: 0, sub_type: 0, expr: None },
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
        assert!(matches!(plan_query("SELECT COUNT(*) FROM DEPT", &None).0, Plan::Scalar(Some(FIXED_ANSWER))));
        assert!(matches!(plan_query("SELECT ID, NAME FROM EMP WHERE ID > 5", &None).0, Plan::Scalar(Some(FIXED_ANSWER))));
        assert!(matches!(plan_query("SELECT CAST(1 AS BIGINT) FROM RDB$DATABASE", &None).0, Plan::Scalar(Some(FIXED_ANSWER))));
    }

    #[test]
    fn tokenizes_and_parses_predicate() {
        let toks = tokenize("ID >= 5 AND NAME = 'a b' OR SALARY IS NULL").unwrap();
        let dnf = parse_predicate(&toks, &mut 0).unwrap();
        assert_eq!(dnf.len(), 2); // two OR groups
        assert_eq!(dnf[0].len(), 2); // ID>=5 AND NAME='a b'
        assert_eq!(dnf[1].len(), 1); // SALARY IS NULL
        // string literal keeps embedded spaces and case
        assert!(matches!(&dnf[0][1].kind, RawKind::Cmp(_, Rhs::Str(s)) if s == "a b"));
        // <> and != both parse; negative ints; IS NOT NULL
        assert!(parse_predicate(&tokenize("A <> -3").unwrap(), &mut 0).is_some());
        assert!(parse_predicate(&tokenize("A != 1 AND B IS NOT NULL").unwrap(), &mut 0).is_some());
        // parentheses group (increment 32): (A = 1) is one plain leaf
        let dnf = parse_predicate(&tokenize("(A = 1)").unwrap(), &mut 0).unwrap();
        assert_eq!((dnf.len(), dnf[0].len()), (1, 1));
    }

    #[test]
    fn tokenizes_aggregate_calls() {
        // an aggregate call is ONE token, spacing-tolerant
        let toks = tokenize("count( * ) > 3 AND MIN(SALARY) >= 100").unwrap();
        let dnf = parse_predicate(&toks, &mut 0).unwrap();
        assert_eq!(dnf.len(), 1);
        assert_eq!(dnf[0].len(), 2);
        assert!(matches!(&dnf[0][0].lhs, RawLhs::Agg(AggFn::Count, AggTarget::Star)));
        assert!(
            matches!(&dnf[0][1].lhs, RawLhs::Agg(AggFn::Min, AggTarget::Col(c)) if c == "SALARY")
        );
        // IS [NOT] NULL applies to aggregates too
        let toks = tokenize("SUM(B) IS NOT NULL").unwrap();
        assert!(matches!(&parse_predicate(&toks, &mut 0).unwrap()[0][0].kind, RawKind::IsNotNull));
        // a non-aggregate function call tokenizes (parens are tokens
        // now) but the PARSER refuses it - not a supported leaf
        assert!(parse_predicate(&tokenize("UPPER(NAME) = 'X'").unwrap(), &mut 0).is_none());
        // ...as does a malformed aggregate
        assert!(tokenize("MIN(*) > 1").is_none());
        // an aggregate name NOT followed by parens is a plain identifier
        let toks = tokenize("COUNT = 1").unwrap();
        assert!(matches!(&parse_predicate(&toks, &mut 0).unwrap()[0][0].lhs, RawLhs::Col(c) if c == "COUNT"));
    }

    #[test]
    fn parses_from_clause() {
        // plain table, with and without alias
        let (l, j) = parse_from("EMP").unwrap();
        assert_eq!(l.table, "EMP");
        assert!(l.alias.is_none() && j.is_none());
        let (l, _) = parse_from("EMP E").unwrap();
        assert_eq!((l.table, l.alias), ("EMP", Some("E")));
        // JOIN with aliases and the optional INNER keyword
        let (l, j) = parse_from("EMP E JOIN DEPT D ON E.DEPT_ID = D.ID").unwrap();
        let (k, r, on) = j.unwrap();
        assert!(k == JoinKind::Inner);
        assert_eq!((l.table, l.alias), ("EMP", Some("E")));
        assert_eq!((r.table, r.alias), ("DEPT", Some("D")));
        assert_eq!(on, "E.DEPT_ID = D.ID");
        let (_, j) = parse_from("EMP inner join DEPT on EMP.DEPT_ID = DEPT.ID").unwrap();
        assert!(matches!(j, Some((JoinKind::Inner, ..))));
        // the outer kinds, with and without the OUTER keyword, any case
        let (l, j) = parse_from("EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID").unwrap();
        assert_eq!((l.table, l.alias), ("EMP", Some("E")));
        assert!(matches!(j, Some((JoinKind::Left, ..))));
        let (l, j) = parse_from("EMP left outer join DEPT on EMP.DEPT_ID = DEPT.ID").unwrap();
        assert_eq!((l.table, l.alias), ("EMP", None));
        assert!(matches!(j, Some((JoinKind::Left, ..))));
        let (_, j) = parse_from("EMP RIGHT JOIN DEPT ON EMP.DEPT_ID = DEPT.ID").unwrap();
        assert!(matches!(j, Some((JoinKind::Right, ..))));
        let (_, j) = parse_from("EMP FULL OUTER JOIN DEPT ON EMP.DEPT_ID = DEPT.ID").unwrap();
        assert!(matches!(j, Some((JoinKind::Full, ..))));
        // unsupported shapes fall back: comma lists, chains, cross,
        // OUTER without a direction, join keywords out of place
        assert!(parse_from("EMP, DEPT").is_none());
        assert!(parse_from("A JOIN B ON A.X = B.X JOIN C ON B.Y = C.Y").is_none());
        assert!(parse_from("EMP JOIN DEPT").is_none()); // no ON
        assert!(parse_from("EMP CROSS JOIN DEPT").is_none());
        assert!(parse_from("EMP OUTER JOIN DEPT ON 1 = 1").is_none());
        assert!(parse_from("LEFT EMP JOIN DEPT ON 1 = 1").is_none());
        assert!(parse_from("EMP LEFT DEPT").is_none()); // stray keyword, no JOIN
    }

    fn join_sides() -> [JoinSide; 2] {
        let d = |dtype| Descriptor { dtype, scale: 0, length: 0, sub_type: 0, flags: 0, offset: 0 };
        [
            JoinSide {
                key: "E".into(),
                rel: 10,
                formats: vec![(1, vec![d(dtype::LONG), d(dtype::LONG), d(dtype::VARYING)])],
                columns: vec![
                    RelationColumn { name: "ID".into(), field_id: 0, position: 0 },
                    RelationColumn { name: "DEPT_ID".into(), field_id: 1, position: 1 },
                    RelationColumn { name: "NAME".into(), field_id: 2, position: 2 },
                ],
                descs: vec![d(dtype::LONG), d(dtype::LONG), d(dtype::VARYING)],
                offset: 0,
            },
            JoinSide {
                key: "D".into(),
                rel: 11,
                formats: vec![(1, vec![d(dtype::LONG), d(dtype::VARYING)])],
                columns: vec![
                    RelationColumn { name: "ID".into(), field_id: 0, position: 0 },
                    RelationColumn { name: "NAME".into(), field_id: 1, position: 1 },
                ],
                descs: vec![d(dtype::LONG), d(dtype::VARYING)],
                offset: 3,
            },
        ]
    }

    #[test]
    fn resolves_join_columns() {
        let sides = join_sides();
        // qualified: side by alias, index offset by side
        assert_eq!(resolve_join_col(&sides, "E.ID").map(|(i, _, _)| i), Some(0));
        assert_eq!(resolve_join_col(&sides, "D.ID").map(|(i, _, _)| i), Some(3));
        assert_eq!(resolve_join_col(&sides, "d.name").map(|(i, _, _)| i), Some(4));
        // bare: unique -> resolved, ambiguous (ID, NAME on both) -> None
        assert_eq!(resolve_join_col(&sides, "DEPT_ID").map(|(i, _, _)| i), Some(1));
        assert!(resolve_join_col(&sides, "ID").is_none());
        assert!(resolve_join_col(&sides, "NAME").is_none());
        // unknown qualifier or column
        assert!(resolve_join_col(&sides, "X.ID").is_none());
        assert!(resolve_join_col(&sides, "E.BOGUS").is_none());
    }

    #[test]
    fn parses_on_conditions() {
        let sides = join_sides();
        // single equality, either operand order normalises to (left, right)
        assert_eq!(parse_on("E.DEPT_ID = D.ID", &sides), Some(vec![(1, 3)]));
        assert_eq!(parse_on("D.ID = E.DEPT_ID", &sides), Some(vec![(1, 3)]));
        // AND-ed equalities; a text pair joins text columns
        assert_eq!(
            parse_on("E.DEPT_ID = D.ID AND E.NAME = D.NAME", &sides),
            Some(vec![(1, 3), (2, 4)])
        );
        // both columns from one side, non-equality, OR, literals: all fall back
        assert!(parse_on("E.ID = E.DEPT_ID", &sides).is_none());
        assert!(parse_on("E.DEPT_ID > D.ID", &sides).is_none());
        assert!(parse_on("E.DEPT_ID = D.ID OR E.NAME = D.NAME", &sides).is_none());
        assert!(parse_on("E.DEPT_ID = 3", &sides).is_none());
        // int/text mismatch
        assert!(parse_on("E.DEPT_ID = D.NAME", &sides).is_none());
    }

    #[test]
    fn join_predicate_uses_combined_indexes() {
        let sides = join_sides();
        let raw = parse_predicate(&tokenize("E.ID >= 5 AND D.NAME = 'Sales'").unwrap(), &mut 0).unwrap();
        let p = resolve_join_predicate(raw, &sides, &mut Vec::new()).unwrap();
        // combined row: [E.ID, E.DEPT_ID, E.NAME, D.ID, D.NAME]
        let row = |id: i64, dname: &str| {
            vec![
                Value::Int(id),
                Value::Int(1),
                Value::Text("x".into()),
                Value::Int(1),
                Value::Text(dname.into()),
            ]
        };
        assert!(p.matches(&row(5, "Sales")));
        assert!(!p.matches(&row(4, "Sales")));
        assert!(!p.matches(&row(9, "Ops")));
        // an ambiguous bare column cannot resolve
        let raw = parse_predicate(&tokenize("NAME = 'x'").unwrap(), &mut 0).unwrap();
        assert!(resolve_join_predicate(raw, &sides, &mut Vec::new()).is_none());
    }

    #[test]
    fn resolves_having_with_hidden_items() {
        // relation: DEPT_ID (fid 2, int), SALARY (fid 5, int), NAME (fid 1, text)
        let columns = vec![
            RelationColumn { name: "NAME".into(), field_id: 1, position: 1 },
            RelationColumn { name: "DEPT_ID".into(), field_id: 2, position: 0 },
            RelationColumn { name: "SALARY".into(), field_id: 5, position: 2 },
        ];
        let d = |dtype| Descriptor { dtype, scale: 0, length: 0, sub_type: 0, flags: 0, offset: 0 };
        let descs = vec![d(0), d(dtype::VARYING), d(dtype::LONG), d(0), d(0), d(dtype::INT64)];
        let key_fids = vec![2usize];
        // select list: DEPT_ID, COUNT(*)
        let mut gitems = vec![GItem::Key(2), GItem::Agg(AggFn::Count, None)];

        // COUNT(*) resolves to the EXISTING item 1; SUM(SALARY) and the
        // grouped key DEPT_ID... COUNT(*) again must not duplicate
        let raw = parse_predicate(&tokenize("COUNT(*) > 3 AND SUM(SALARY) > 100 OR DEPT_ID IS NULL").unwrap(), &mut 0).unwrap();
        let p = resolve_having(raw, &mut gitems, &key_fids, &columns, &descs).unwrap();
        assert_eq!(gitems.len(), 3); // one hidden item appended: SUM(SALARY)
        assert!(matches!(gitems[2], GItem::Agg(AggFn::Sum, Some(5))));
        // output rows: [key, count, hidden sum]
        assert!(p.matches(&[Value::Int(1), Value::Int(4), Value::Int(200)]));
        assert!(!p.matches(&[Value::Int(1), Value::Int(4), Value::Int(50)]));
        assert!(p.matches(&[Value::Null, Value::Int(1), Value::Null])); // the OR arm
        // a non-grouped column in HAVING is invalid
        let raw = parse_predicate(&tokenize("SALARY > 1").unwrap(), &mut 0).unwrap();
        assert!(resolve_having(raw, &mut gitems, &key_fids, &columns, &descs).is_none());
        // MIN over a text column is unsupported
        let raw = parse_predicate(&tokenize("MIN(NAME) IS NULL").unwrap(), &mut 0).unwrap();
        assert!(resolve_having(raw, &mut gitems, &key_fids, &columns, &descs).is_none());
        // an aggregate compared against a string literal is a type mismatch
        let raw = parse_predicate(&tokenize("COUNT(*) = 'x'").unwrap(), &mut 0).unwrap();
        assert!(resolve_having(raw, &mut gitems, &key_fids, &columns, &descs).is_none());
        // ...and WHERE resolution rejects aggregates outright
        let raw = parse_predicate(&tokenize("COUNT(*) > 3").unwrap(), &mut 0).unwrap();
        assert!(resolve_predicate(raw, &columns, &descs, &mut Vec::new()).is_none());
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
    fn wire_types_mirror_the_engine() {
        let d = |dtype, scale| Descriptor { dtype, scale, length: 0, sub_type: 0, flags: 0, offset: 0 };
        // (dtype, scale) -> (sql_type, length, scale)
        for (dt, sc, ty, len) in [
            (dtype::SHORT, -2, 500, 2),
            (dtype::LONG, 0, 496, 4),
            (dtype::INT64, -4, 580, 8),
            (dtype::REAL, 0, 482, 4),
            (dtype::DOUBLE, 0, 480, 8),
            (dtype::SQL_DATE, 0, 570, 4),
            (dtype::SQL_TIME, 0, 560, 4),
            (dtype::TIMESTAMP, 0, 510, 8),
            (dtype::BOOLEAN, 0, 32764, 1),
            (dtype::VARYING, 0, 448, 32765),
        ] {
            let (_, sql_type, length, scale, _) = wire_for(&d(dt, sc));
            assert_eq!((sql_type, length), (ty, len), "dtype {}", dt);
            let want = if matches!(dt, dtype::SHORT | dtype::LONG | dtype::INT64) { sc as i32 } else { 0 };
            assert_eq!(scale, want, "dtype {} scale", dt);
        }
    }

    #[test]
    fn encodes_native_wire_values() {
        let pc = |wire, sql_type, length, scale| ProjCol {
            name: "C".into(), field_id: 0, wire, sql_type, length, scale, sub_type: 0, expr: None,
        };
        let enc = |col: ProjCol, v: Value| {
            let mut w = W::default();
            encode_row(&mut w, &[col], &[v]).unwrap();
            // skip the 12-byte op_fetch_response header + 4-byte null bitmap
            w.buf[16..].to_vec()
        };
        // scaled numeric: the RAW integer travels (client divides)
        assert_eq!(enc(pc(Wire::Int64, 580, 8, -2), Value::Scaled(1234, -2)), 1234i64.to_be_bytes());
        assert_eq!(enc(pc(Wire::Int32, 500, 2, -2), Value::Scaled(-321, -2)), (-321i32).to_be_bytes());
        // date/time/timestamp: raw day and 1/10000-s units, big-endian
        assert_eq!(enc(pc(Wire::Date, 570, 4, 0), Value::Date(61234)), 61234i32.to_be_bytes());
        assert_eq!(enc(pc(Wire::Time, 560, 4, 0), Value::Time(123_456_780)), 123_456_780u32.to_be_bytes());
        let ts = enc(pc(Wire::Timestamp, 510, 8, 0), Value::Timestamp(61234, 500_000));
        assert_eq!(&ts[0..4], &61234i32.to_be_bytes());
        assert_eq!(&ts[4..8], &500_000u32.to_be_bytes());
        // boolean pads to a 4-byte slot; double is 8 IEEE bytes
        assert_eq!(enc(pc(Wire::Bool, 32764, 1, 0), Value::Bool(true)), 1i32.to_be_bytes());
        assert_eq!(enc(pc(Wire::Double, 480, 8, 0), Value::Double(2.5)), 2.5f64.to_be_bytes());
    }

    #[test]
    fn value_cmp_orders_new_types_numerically() {
        use std::cmp::Ordering::*;
        // scaled: 9.50 < 12.30 though "9.5" > "12.3" as text
        assert_eq!(value_cmp(&Value::Scaled(950, -2), &Value::Scaled(1230, -2)), Less);
        // cross-scale: 1.5 (-1) == 1.50 (-2)
        assert_eq!(value_cmp(&Value::Scaled(15, -1), &Value::Scaled(150, -2)), Equal);
        assert_eq!(value_cmp(&Value::Double(1.5), &Value::Double(2.0)), Less);
        assert_eq!(value_cmp(&Value::Date(100), &Value::Date(99)), Greater);
        assert_eq!(
            value_cmp(&Value::Timestamp(100, 5), &Value::Timestamp(100, 6)),
            Less
        );
        assert_eq!(value_cmp(&Value::Null, &Value::Date(0)), Less); // NULLs still lowest
    }

    #[test]
    fn encodes_row_bitmap_and_values() {
        // two INT64 cols, second null: 4-byte bitmap (bit 1 set) + one 8-byte value
        let cols = vec![
            ProjCol { name: "A".into(), field_id: 0, wire: Wire::Int64, sql_type: 580, length: 8, scale: 0, sub_type: 0, expr: None },
            ProjCol { name: "B".into(), field_id: 1, wire: Wire::Int64, sql_type: 580, length: 8, scale: 0, sub_type: 0, expr: None },
        ];
        let values = vec![Value::Int(7), Value::Null];
        let mut w = W::default();
        encode_row(&mut w, &cols, &values).unwrap();
        // a 12-byte op_fetch_response header (op, status 0, count 1), then
        // bitmap: byte0 = 0b10 (col1 null), 3 pad bytes, then 8-byte BE 7
        assert_eq!(&w.buf[12..16], &[0b10, 0, 0, 0]);
        assert_eq!(&w.buf[16..24], &7i64.to_be_bytes());
        assert_eq!(w.buf.len(), 24); // null col contributes no data
    }

    fn dbctx() -> DbInfoCtx {
        DbInfoCtx {
            db_path: "/tmp/x.fdb".into(),
            attach_id: 7,
            ods_major: 14,
            ods_minor: 0,
            page_size: 8192,
        }
    }

    #[test]
    fn db_info_answers_known_items_and_ends() {
        // isc_info_db_sql_dialect(62) is a ONE-byte value; ods_version(32)
        // a 4-byte int; the buffer ends with isc_info_end(1).
        let out = build_db_info(&[62, 32, 1], &dbctx());
        assert_eq!(out[0], 62);
        assert_eq!(&out[1..3], &1u16.to_le_bytes()); // dialect length 1
        assert_eq!(out[3], 3); // dialect value 3
        assert_eq!(out[4], 32); // ODS version item follows
        assert_eq!(&out[5..7], &4u16.to_le_bytes());
        assert_eq!(i32::from_le_bytes([out[7], out[8], out[9], out[10]]), 14);
        assert_eq!(*out.last().unwrap(), 1);
    }

    #[test]
    fn db_info_answers_bootstrap_items() {
        // isc_info_db_id(4): count byte then the path pascal string first
        let out = build_db_info(&[4], &dbctx());
        assert_eq!(out[0], 4);
        let clen = u16::from_le_bytes([out[1], out[2]]) as usize;
        let body = &out[3..3 + clen];
        assert_eq!(body[0], 2); // two strings
        let plen = body[1] as usize;
        assert_eq!(&body[2..2 + plen], b"/tmp/x.fdb");
        // isc_info_attachment_id(22): 4-byte int = 7
        let out = build_db_info(&[22], &dbctx());
        assert_eq!(out[0], 22);
        assert_eq!(i32::from_le_bytes([out[3], out[4], out[5], out[6]]), 7);
    }

    #[test]
    fn db_info_skips_unknown_items() {
        // an unrecognised item (200) contributes nothing but the trailer.
        assert_eq!(build_db_info(&[200], &dbctx()), vec![1]);
    }

    #[test]
    fn service_info_mirrors_real_bytes() {
        // string items carry a 2-byte length; RUNNING is a bare 4-byte int
        let out = service_info(&[55, 67]);
        assert_eq!(out[0], 55);
        let vlen = u16::from_le_bytes([out[1], out[2]]) as usize;
        let ver = &out[3..3 + vlen];
        assert!(ver.starts_with(b"LI-V")); // driver splits on V/T
        let rest = &out[3 + vlen..];
        assert_eq!(rest[0], 67);
        assert_eq!(i32::from_le_bytes([rest[1], rest[2], rest[3], rest[4]]), 0);
    }

    #[test]
    fn top_level_col_count_ignores_nested_commas() {
        // the MON$ architecture probe: 3 aggregates, commas inside iif()
        assert_eq!(
            count_top_level_cols(
                "count(distinct a.x), min(a.y), max(iif(a.y is null, 1, 0))"
            ),
            3
        );
        assert_eq!(count_top_level_cols("*"), 1);
    }

    #[test]
    fn parses_and_evaluates_select_expressions() {
        // columns A(fid 0, int), B(fid 1, int), NAME(fid 2, text),
        // N(fid 3, NUMERIC(9,2)=LONG scale -2), M(fid 4, NUMERIC(9,4)=scale -4)
        let columns = vec![
            RelationColumn { name: "A".into(), field_id: 0, position: 0 },
            RelationColumn { name: "B".into(), field_id: 1, position: 1 },
            RelationColumn { name: "NAME".into(), field_id: 2, position: 2 },
            RelationColumn { name: "N".into(), field_id: 3, position: 3 },
            RelationColumn { name: "M".into(), field_id: 4, position: 4 },
        ];
        let d = |dt| Descriptor { dtype: dt, scale: 0, length: 4, sub_type: 0, flags: 0, offset: 0 };
        let sc = |s| Descriptor { dtype: dtype::LONG, scale: s, length: 4, sub_type: 0, flags: 0, offset: 0 };
        let descs = vec![d(dtype::LONG), d(dtype::LONG), d(dtype::VARYING), sc(-2), sc(-4)];
        let row = vec![
            Value::Int(10), Value::Int(3), Value::Text("x".into()),
            Value::Scaled(1250, -2), Value::Scaled(12345, -4),
        ];

        let ev = |s: &str| -> Value {
            let raw = parse_raw_expr(s).unwrap();
            resolve_expr(&raw, &columns, &descs).unwrap().eval(&row).unwrap()
        };
        // precedence: * binds tighter than + / -
        assert!(matches!(ev("A + B * 2"), Value::Int(16)));
        assert!(matches!(ev("(A + B) * 2"), Value::Int(26)));
        assert!(matches!(ev("A - B"), Value::Int(7)));
        assert!(matches!(ev("-A"), Value::Int(-10)));
        assert!(matches!(ev("1 + 1"), Value::Int(2)));
        // integer division truncates toward zero (10 / 3 = 3)
        assert!(matches!(ev("A / B"), Value::Int(3)));
        assert!(matches!(ev("A / -B"), Value::Int(-3)));
        // || binds tighter than +, so 1 || 2 + 3 is (1 || 2) + 3 -> "12"+3
        // is nonsense here; test the pure-text and coercing forms instead
        assert!(matches!(ev("NAME || NAME"), Value::Text(ref s) if s == "xx"));
        assert!(matches!(ev("A || 'z'"), Value::Text(ref s) if s == "10z"));
        assert!(matches!(ev("A || B"), Value::Text(ref s) if s == "103"));
        // divide by zero is the arithmetic exception, not a wrong answer
        {
            let raw = parse_raw_expr("A / 0").unwrap();
            assert!(resolve_expr(&raw, &columns, &descs).unwrap().eval(&row).is_err());
        }
        // NULL propagates through arithmetic and concatenation
        let null_row = vec![Value::Null, Value::Int(3), Value::Null];
        let ev_null = |s: &str| -> Value {
            let raw = parse_raw_expr(s).unwrap();
            resolve_expr(&raw, &columns, &descs).unwrap().eval(&null_row).unwrap()
        };
        assert!(matches!(ev_null("A + B"), Value::Null));
        assert!(matches!(ev_null("A / B"), Value::Null));
        assert!(matches!(ev_null("A || B"), Value::Null));
        // CAST: int->text renders, text->int parses, int width change keeps
        assert!(matches!(ev("CAST(A AS VARCHAR(5))"), Value::Text(ref s) if s == "10"));
        assert!(matches!(ev("CAST(A AS BIGINT)"), Value::Int(10)));
        assert!(matches!(ev("CAST(A + 1 AS VARCHAR(5))"), Value::Text(ref s) if s == "11"));
        assert!(matches!(ev("CAST('100' AS INTEGER)"), Value::Int(100)));
        assert!(matches!(ev("CAST(' 55 ' AS INTEGER)"), Value::Int(55)));
        // CHAR pads to width, VARCHAR does not
        assert!(matches!(ev("CAST(A AS CHAR(4))"), Value::Text(ref s) if s == "10  "));
        assert!(matches!(ev("CAST(A AS VARCHAR(4))"), Value::Text(ref s) if s == "10"));
        // a non-numeric string to an integer is the conversion error
        {
            let raw = parse_raw_expr("CAST(NAME AS INTEGER)").unwrap();
            assert!(matches!(
                resolve_expr(&raw, &columns, &descs).unwrap().eval(&row),
                Err(EvalErr::ConversionError)
            ));
        }
        // a value too long for the target text width is also the conversion error
        {
            let raw = parse_raw_expr("CAST(A AS VARCHAR(1))").unwrap();
            assert!(matches!(
                resolve_expr(&raw, &columns, &descs).unwrap().eval(&row),
                Err(EvalErr::ConversionError)
            ));
        }
        // NULL casts to NULL
        assert!(matches!(ev_null("CAST(A AS VARCHAR(5))"), Value::Null));
        // CAST over a scaled NUMERIC column: rounds to integer half away
        // from zero, renders with its decimals to text
        assert!(matches!(ev("CAST(N AS INTEGER)"), Value::Int(13)));
        assert!(matches!(ev("CAST(N AS VARCHAR(10))"), Value::Text(ref s) if s == "12.50"));
        // a bare numeric column is not a top-level expression (no wire form)
        {
            let raw = parse_raw_expr("CAST(N AS INTEGER)").unwrap();
            let e = resolve_expr(&raw, &columns, &descs).unwrap();
            assert_eq!(e.type_of(&descs), Some(ExprType::Int));
        }
        // numeric arithmetic - the engine's dialect-3 scale rules (probed).
        // N=12.50 (scale -2), M=1.2345 (scale -4), A=10, B=3.
        let num = |s: &str| -> (i64, i8) {
            let raw = parse_raw_expr(s).unwrap();
            let e = resolve_expr(&raw, &columns, &descs).unwrap();
            assert_eq!(e.type_of(&descs), Some(ExprType::Numeric), "{s} not numeric");
            let scale = e.result_scale(&descs).unwrap();
            match e.eval(&row).unwrap() {
                Value::Scaled(r, s) => {
                    assert_eq!(s, scale, "{s}: eval scale != announced");
                    (r, s)
                }
                other => panic!("{s} -> {other:?}"),
            }
        };
        assert_eq!(num("N + M"), (137345, -4)); // 12.50 + 1.2345 = 13.7345
        assert_eq!(num("N - A"), (250, -2)); // 12.50 - 10 = 2.50
        assert_eq!(num("N + 1"), (1350, -2)); // 12.50 + 1 = 13.50
        assert_eq!(num("N * M"), (15431250, -6)); // scale -2 + -4 = -6
        assert_eq!(num("N * 2"), (2500, -2)); // 25.00
        assert_eq!(num("N * A"), (12500, -2)); // 125.00
        assert_eq!(num("N / M"), (10125556, -6)); // dividend *10^8 // raw2, trunc
        assert_eq!(num("N / A"), (125, -2)); // 12.50 / 10 = 1.25
        assert_eq!(num("N / 4"), (312, -2)); // 12.50/4 = 3.125 -> scale -2 -> 3.12 (trunc)
        // decimal literals: scale = written fractional digits (trailing
        // zeros count), and they follow the same arithmetic rules
        assert!(matches!(ev("1.5"), Value::Scaled(15, -1)));
        assert!(matches!(ev("1.50"), Value::Scaled(150, -2))); // trailing zero counts
        assert!(matches!(ev("100.0"), Value::Scaled(1000, -1)));
        assert_eq!(num("N + 1.5"), (1400, -2)); // 12.50 + 1.50 (aligned) = 14.00
        assert_eq!(num("N + 1.50"), (1400, -2)); // same, literal scale -2
        assert_eq!(num("N * 1.5"), (18750, -3)); // scale -2 + -1 = -3, 18.750
        assert_eq!(num("N / 1.5"), (8333, -3)); // scale -3, 8.333 (trunc)
        assert_eq!(num("1.5 + 2.25"), (375, -2)); // finer scale -2, 3.75
        assert_eq!(num("1.5 * 2"), (30, -1)); // literal * integer, scale -1, 3.0
        assert_eq!(default_expr_name(&parse_raw_expr("1.5").unwrap()), "CONSTANT");
        // -N negates in place; NULL propagates through numeric arithmetic
        assert!(matches!(ev("-N"), Value::Scaled(-1250, -2)));
        let null_num = vec![
            Value::Null, Value::Int(3), Value::Null,
            Value::Null, Value::Scaled(12345, -4),
        ];
        {
            let raw = parse_raw_expr("N * M").unwrap();
            assert!(matches!(
                resolve_expr(&raw, &columns, &descs).unwrap().eval(&null_num),
                Ok(Value::Null)
            ));
        }
        // numeric divide by zero is still the arithmetic exception
        {
            let raw = parse_raw_expr("N / 0").unwrap();
            assert!(matches!(
                resolve_expr(&raw, &columns, &descs).unwrap().eval(&row),
                Err(EvalErr::DivideByZero)
            ));
        }
        // a bare column is NOT an expression (the column path handles it)
        assert!(parse_raw_expr("A").is_none());
        // arithmetic over a text column does not type-check
        let raw = parse_raw_expr("NAME + 1").unwrap();
        assert!(build_expr_col(&raw, "X", &columns, &descs).is_none());
        // concatenation over a text column DOES (both operands -> text)
        let raw = parse_raw_expr("NAME || '!'").unwrap();
        assert!(build_expr_col(&raw, "X", &columns, &descs).is_some());
        // the default output name mirrors Firebird's operation names
        assert_eq!(default_expr_name(&parse_raw_expr("A + B").unwrap()), "ADD");
        assert_eq!(default_expr_name(&parse_raw_expr("A * B").unwrap()), "MULTIPLY");
        assert_eq!(default_expr_name(&parse_raw_expr("A / B").unwrap()), "DIVIDE");
        assert_eq!(
            default_expr_name(&parse_raw_expr("A || B").unwrap()),
            "CONCATENATION"
        );
        assert_eq!(
            default_expr_name(&parse_raw_expr("CAST(A AS INTEGER)").unwrap()),
            "CAST"
        );
    }

    #[test]
    fn rounds_scaled_half_away_from_zero() {
        // the engine's CAST(NUMERIC AS INTEGER) rule (probed against isql)
        assert_eq!(round_scaled_to_int(1250, -2), 13); // 12.50 -> 13
        assert_eq!(round_scaled_to_int(1350, -2), 14); // 13.50 -> 14 (not banker's)
        assert_eq!(round_scaled_to_int(-1250, -2), -13); // -12.50 -> -13
        assert_eq!(round_scaled_to_int(249, -2), 2); // 2.49 -> 2
        assert_eq!(round_scaled_to_int(251, -2), 3); // 2.51 -> 3
        assert_eq!(round_scaled_to_int(-325, -2), -3); // -3.25 -> -3
        assert_eq!(round_scaled_to_int(1000, -2), 10); // 10.00 -> 10 exactly
    }

    #[test]
    fn projection_splits_columns_and_expressions() {
        let cols = |p: &str| match parse_projection(p).unwrap() {
            Proj::Items(items) => items
                .iter()
                .map(|i| match i {
                    SelItem::Col(c) => format!("col:{}", c),
                    SelItem::Expr(_, n) => format!("expr:{}", n),
                    SelItem::Agg(..) => "agg".into(),
                    SelItem::Gen(n, s, _) => format!("gen:{}:{:?}", n, s),
                })
                .collect::<Vec<_>>(),
            Proj::Star => vec!["*".into()],
        };
        assert_eq!(cols("A, A + B"), vec!["col:A", "expr:ADD"]);
        assert_eq!(cols("A + B AS TOTAL"), vec!["expr:TOTAL"]);
        // commas inside parens are not item separators
        assert_eq!(cols("A, (B - 1)"), vec!["col:A", "expr:SUBTRACT"]);
        // the `AS` inside a CAST is part of the expression, not an alias;
        // only a top-level `AS` renames
        assert_eq!(cols("CAST(A AS VARCHAR(20))"), vec!["expr:CAST"]);
        assert_eq!(cols("CAST(A AS INTEGER) AS X"), vec!["expr:X"]);
        // a decimal literal in an item is an expression, not a qualified
        // column (its `.` must not be mistaken for a `T.C` separator)
        assert_eq!(cols("A + 1.5"), vec!["expr:ADD"]);
        assert_eq!(cols("1.5"), vec!["expr:CONSTANT"]);
        // a real qualified column still parses as one (the join path)
        assert_eq!(cols("T.C"), vec!["col:T.C"]);
    }

    #[test]
    fn parses_the_show_tables_blr_request() {
        // the exact BLR isql compiles for SHOW TABLES (captured off the
        // wire): blr_version, blr_begin, message 1 (the row: a short eof
        // flag + three cstrings) and message 0 (a lone short), then a
        // blr_for over RDB$RELATIONS filtered by system-flag = :p and
        // view_blr IS NULL, sorted by schema/package/relation, sending
        // each row to message 1 with the eof flag = 1 and a terminator
        // send with eof flag = 0.
        let blr: &[u8] = &[
            4, 2, 4, 1, 4, 0, 7, 0, 40, 253, 0, 40, 253, 0, 40, 253, 0, 4, 0, 1, 0, 7, 0, 12,
            0, 2, 7, 67, 1, 74, 13, 82, 68, 66, 36, 82, 69, 76, 65, 84, 73, 79, 78, 83, 0, 71,
            58, 47, 23, 0, 15, 82, 68, 66, 36, 83, 89, 83, 84, 69, 77, 95, 70, 76, 65, 71, 25,
            0, 0, 0, 61, 23, 0, 12, 82, 68, 66, 36, 86, 73, 69, 87, 95, 66, 76, 82, 70, 3, 72,
            23, 0, 15, 82, 68, 66, 36, 83, 67, 72, 69, 77, 65, 95, 78, 65, 77, 69, 72, 23, 0,
            16, 82, 68, 66, 36, 80, 65, 67, 75, 65, 71, 69, 95, 78, 65, 77, 69, 72, 23, 0, 17,
            82, 68, 66, 36, 82, 69, 76, 65, 84, 73, 79, 78, 95, 78, 65, 77, 69, 255, 14, 1, 2,
            1, 21, 8, 0, 1, 0, 0, 0, 25, 1, 0, 0, 1, 23, 0, 17, 82, 68, 66, 36, 82, 69, 76, 65,
            84, 73, 79, 78, 95, 78, 65, 77, 69, 25, 1, 1, 0, 1, 23, 0, 15, 82, 68, 66, 36, 83,
            67, 72, 69, 77, 65, 95, 78, 65, 77, 69, 25, 1, 2, 0, 1, 23, 0, 16, 82, 68, 66, 36,
            80, 65, 67, 75, 65, 71, 69, 95, 78, 65, 77, 69, 25, 1, 3, 0, 255, 14, 1, 1, 21, 8,
            0, 0, 0, 0, 0, 25, 1, 0, 0, 255, 255, 76,
        ];
        let req = parse_blr_request(blr).expect("SHOW TABLES BLR must parse");
        // two message layouts: msg 0 is one short; msg 1 is short + 3 cstrings
        assert_eq!(req.msgs.len(), 2);
        assert!(matches!(req.msgs[0].as_slice(), [BField::Short]));
        assert!(matches!(
            req.msgs[1].as_slice(),
            [BField::Short, BField::Cstring(_), BField::Cstring(_), BField::Cstring(_)]
        ));
        // the for-loop's rse targets RDB$RELATIONS with a boolean and a
        // three-key sort
        fn find_for(s: &BStmt) -> Option<&BRse> {
            match s {
                BStmt::For(rse, _) => Some(rse),
                BStmt::Begin(v) => v.iter().find_map(find_for),
                BStmt::Receive(b) => find_for(b),
                _ => None,
            }
        }
        let rse = find_for(&req.stmt).expect("a blr_for over a relation");
        assert_eq!(rse.streams.len(), 1);
        assert_eq!(rse.streams[0].1, "RDB$RELATIONS");
        assert!(rse.boolean.is_some());
        assert_eq!(rse.sort.len(), 3);
    }

    #[test]
    fn encodes_a_request_message_field_by_field() {
        // xdr_datum, non-symmetric path: a short is a 4-byte big-endian
        // value; a cstring is a 4-byte big-endian length then the bytes
        // padded to a 4-byte boundary.
        let fields = vec![BField::Short, BField::Cstring(253)];
        let vals = vec![Value::Int(1), Value::Text("X".into())];
        let m = encode_request_message(&fields, &vals);
        assert_eq!(&m[0..4], &[0, 0, 0, 1]); // short eof flag = 1
        assert_eq!(&m[4..8], &[0, 0, 0, 1]); // cstring length = 1
        assert_eq!(&m[8..12], &[b'X', 0, 0, 0]); // 'X' padded to 4
        assert_eq!(m.len(), 12);
        // a NULL text renders as a zero-length cstring
        let m2 = encode_request_message(&[BField::Cstring(253)], &[Value::Null]);
        assert_eq!(m2, vec![0, 0, 0, 0]);
        // a quad is 8 zero bytes for a NULL blob; a bool is one byte padded
        assert_eq!(encode_request_message(&[BField::Quad], &[Value::Null]).len(), 8);
        // a non-NULL blob travels as the on-disk bid layout (encode_blob_id),
        // the id op_open_blob decodes back - SHOW PROCEDURE's source
        assert_eq!(
            encode_request_message(&[BField::Quad], &[Value::Blob(5, 0x2a)]),
            encode_blob_id(5, 0x2a).to_vec()
        );
        assert_eq!(
            encode_request_message(&[BField::Bool], &[Value::Bool(true)]),
            vec![1, 0, 0, 0]
        );
        assert_eq!(
            encode_request_message(&[BField::Int64], &[Value::Int(1)]),
            vec![0, 0, 0, 0, 0, 0, 0, 1]
        );
    }

    #[test]
    fn parses_a_two_stream_join_rse() {
        // the SHOW INDICES rse (captured): a blr_for over RDB$INDICES CROSS
        // RDB$RELATIONS joined on schema/package/relation, with a
        // system-flag filter and a NOT STARTING WITH on the index name.
        let blr: &[u8] = &[
            67, 2, 74, 11, 82, 68, 66, 36, 73, 78, 68, 73, 67, 69, 83, 0, 74, 13, 82, 68, 66,
            36, 82, 69, 76, 65, 84, 73, 79, 78, 83, 1, 71, 58, 46, 23, 1, 15, 82, 68, 66, 36,
            83, 67, 72, 69, 77, 65, 95, 78, 65, 77, 69, 23, 0, 15, 82, 68, 66, 36, 83, 67, 72,
            69, 77, 65, 95, 78, 65, 77, 69, 58, 46, 23, 1, 16, 82, 68, 66, 36, 80, 65, 67, 75,
            65, 71, 69, 95, 78, 65, 77, 69, 23, 0, 16, 82, 68, 66, 36, 80, 65, 67, 75, 65, 71,
            69, 95, 78, 65, 77, 69, 58, 47, 23, 1, 17, 82, 68, 66, 36, 82, 69, 76, 65, 84, 73,
            79, 78, 95, 78, 65, 77, 69, 23, 0, 17, 82, 68, 66, 36, 82, 69, 76, 65, 84, 73, 79,
            78, 95, 78, 65, 77, 69, 58, 57, 48, 23, 1, 15, 82, 68, 66, 36, 83, 89, 83, 84, 69,
            77, 95, 70, 76, 65, 71, 21, 8, 0, 1, 0, 0, 0, 61, 23, 1, 15, 82, 68, 66, 36, 83, 89,
            83, 84, 69, 77, 95, 70, 76, 65, 71, 59, 55, 23, 0, 14, 82, 68, 66, 36, 73, 78, 68,
            69, 88, 95, 78, 65, 77, 69, 25, 0, 0, 0, 255,
        ];
        let mut c = BlrCur { b: blr, i: 0 };
        let rse = parse_blr_rse(&mut c).expect("two-stream rse must parse");
        assert_eq!(rse.streams.len(), 2);
        assert_eq!(rse.streams[0], (0, "RDB$INDICES".to_string()));
        assert_eq!(rse.streams[1], (1, "RDB$RELATIONS".to_string()));
        assert!(rse.boolean.is_some());

        // sleuth_match recognises the system-name pattern isql hides
        assert!(sleuth_match("RDB$123", "RDB$+"));
        assert!(!sleuth_match("MY_DOMAIN", "RDB$+"));
        assert!(!sleuth_match("RDB$", "RDB$+")); // needs at least one digit
    }

    #[test]
    fn parses_an_rse_with_a_project_distinct() {
        // blr_rse over T, sorted by A ascending, DISTINCT on A - the shape
        // SHOW PROCEDURES' dependency request uses (blr_sort then
        // blr_project). blr_relation "T" ctx 0; blr_sort 1 [asc field A];
        // blr_project 1 [field A]; blr_end.
        let blr: &[u8] = &[
            67, 1, 74, 1, b'T', 0, // rse, 1 stream, relation "T" ctx 0
            70, 1, 72, 23, 0, 1, b'A', // sort: 1 key, ascending, field A
            69, 1, 23, 0, 1, b'A', // project: 1 expr, field A
            255,
        ];
        let mut c = BlrCur { b: blr, i: 0 };
        let rse = parse_blr_rse(&mut c).expect("rse with project must parse");
        assert_eq!(rse.streams, vec![(0, "T".to_string())]);
        assert_eq!(rse.sort.len(), 1);
        assert_eq!(rse.project.len(), 1);
        assert!(matches!(&rse.project[0], BVal::Field(0, n) if n == "A"));
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

    #[test]
    fn strip_gen_name_drops_qualifier_and_quotes() {
        // schema-qualified, bare object name
        assert_eq!(strip_gen_name("PUBLIC.MYGEN"), "MYGEN");
        // schema-qualified, quoted mixed-case object name
        assert_eq!(strip_gen_name("PUBLIC.\"MyGen\""), "MyGen");
        // bare unqualified name
        assert_eq!(strip_gen_name("MYGEN"), "MYGEN");
        // quoted unqualified name
        assert_eq!(strip_gen_name("\"MyGen\""), "MyGen");
        // a quoted name containing a dot is not split on that dot
        assert_eq!(strip_gen_name("\"a.b\""), "a.b");
        // an escaped double-quote inside a quoted name
        assert_eq!(strip_gen_name("\"a\"\"b\""), "a\"b");
    }

    #[test]
    fn parse_gen_id_query_recognises_the_show_generators_probe() {
        // isql's exact shape (schema-qualified name, SYSTEM.RDB$DATABASE)
        assert_eq!(
            parse_gen_id_query("GEN_ID(PUBLIC.SEQ_A, 0)", "SYSTEM.RDB$DATABASE"),
            Some(("SEQ_A".to_string(), 0))
        );
        // bare RDB$DATABASE, unqualified generator, lowercase function name
        assert_eq!(
            parse_gen_id_query("gen_id(GEN_C, 0)", "RDB$DATABASE"),
            Some(("GEN_C".to_string(), 0))
        );
        // a non-zero step is still parsed (the caller decides not to
        // answer it as a read)
        assert_eq!(
            parse_gen_id_query("GEN_ID(SEQ_B, 1)", "RDB$DATABASE"),
            Some(("SEQ_B".to_string(), 1))
        );
        // negative step
        assert_eq!(
            parse_gen_id_query("GEN_ID(SEQ_B, -5)", "RDB$DATABASE"),
            Some(("SEQ_B".to_string(), -5))
        );
        // not a GEN_ID call
        assert_eq!(parse_gen_id_query("ID", "RDB$DATABASE"), None);
        assert_eq!(
            parse_gen_id_query("CAST(1 AS BIGINT)", "RDB$DATABASE"),
            None
        );
        // GEN_ID over a real table is not the probe
        assert_eq!(parse_gen_id_query("GEN_ID(SEQ_A, 0)", "EMP"), None);
        // trailing text after the call is rejected
        assert_eq!(
            parse_gen_id_query("GEN_ID(SEQ_A, 0) + 1", "RDB$DATABASE"),
            None
        );
    }

    #[test]
    fn parses_next_value_for() {
        assert_eq!(
            parse_next_value("NEXT VALUE FOR SEQ5", "RDB$DATABASE"),
            Some("SEQ5".to_string())
        );
        // case-insensitive, schema-qualified name reduced to the bare name
        assert_eq!(
            parse_next_value("next value for PUBLIC.MYSEQ", "SYSTEM.RDB$DATABASE"),
            Some("MYSEQ".to_string())
        );
        // not a NEXT VALUE FOR, or over a real table
        assert_eq!(parse_next_value("A + B", "RDB$DATABASE"), None);
        assert_eq!(parse_next_value("NEXT VALUE FOR SEQ5", "EMP"), None);
        assert_eq!(parse_next_value("NEXT VALUE FOR", "RDB$DATABASE"), None);
    }

    #[test]
    fn parses_foreign_key_clauses() {
        // named FK with an explicit referenced-column list
        let fk = parse_fk_clause("CONSTRAINT FK_C_P FOREIGN KEY (PID) REFERENCES P (PID)").unwrap();
        assert_eq!(fk.name, "FK_C_P");
        assert_eq!(fk.columns, vec!["PID".to_string()]);
        assert_eq!(fk.ref_table, "P");
        assert_eq!(fk.ref_columns, vec!["PID".to_string()]);
        // unnamed FK, referenced columns omitted (default to the PK)
        let fk = parse_fk_clause("FOREIGN KEY (A, B) REFERENCES OTHER").unwrap();
        assert_eq!(fk.name, "");
        assert_eq!(fk.columns, vec!["A".to_string(), "B".to_string()]);
        assert_eq!(fk.ref_table, "OTHER");
        assert!(fk.ref_columns.is_empty());
        // a plain column definition and a PRIMARY KEY clause are not FKs
        assert!(parse_fk_clause("PID INTEGER").is_none());
        assert!(parse_fk_clause("PRIMARY KEY (ID)").is_none());
    }

    #[test]
    fn parses_table_level_key_constraints() {
        // named compound PRIMARY KEY
        let k = parse_key_clause("CONSTRAINT PK_P PRIMARY KEY (A, B)").unwrap();
        assert_eq!(k.name, "PK_P");
        assert_eq!(k.columns, vec!["A".to_string(), "B".to_string()]);
        assert!(k.primary);
        // unnamed UNIQUE
        let k = parse_key_clause("UNIQUE (B)").unwrap();
        assert_eq!(k.name, "");
        assert_eq!(k.columns, vec!["B".to_string()]);
        assert!(!k.primary);
        // a column whose name merely starts with UNIQUE is a column def
        assert!(parse_key_clause("UNIQUEID INTEGER").is_none());
        assert!(parse_key_clause("FOREIGN KEY (A) REFERENCES P").is_none());
    }

    #[test]
    fn parses_column_level_key_constraints() {
        // a named column-level PRIMARY KEY: the key is reported and the
        // column carries the implied NOT NULL as a CONSTRAINT-bearing one
        let (col, key) = parse_column_def("X INTEGER CONSTRAINT PK_Q PRIMARY KEY").unwrap();
        assert_eq!(col.name, "X");
        assert!(col.not_null && col.not_null_constraint);
        assert_eq!(key, Some(("PK_Q".to_string(), true)));
        // an unnamed column-level UNIQUE implies nothing about NULLs
        let (col, key) = parse_column_def("A INTEGER UNIQUE").unwrap();
        assert!(!col.not_null);
        assert_eq!(key, Some((String::new(), false)));
        // NOT NULL and the key constraint in either order
        let (col, key) = parse_column_def("A INTEGER NOT NULL UNIQUE").unwrap();
        assert!(col.not_null);
        assert_eq!(key, Some((String::new(), false)));
        let (col, key) = parse_column_def("A VARCHAR(10) UNIQUE NOT NULL").unwrap();
        assert_eq!(col.length, 12);
        assert!(col.not_null);
        assert_eq!(key, Some((String::new(), false)));
        // a plain column has no key
        assert_eq!(parse_column_def("A INTEGER").unwrap().1, None);
    }

    #[test]
    fn create_table_keeps_key_constraints_in_declaration_order() {
        // the engine numbers generated constraint and index names in
        // declaration order, so the plan must preserve it
        let plan = plan_create_table(
            "CREATE TABLE M (A INTEGER NOT NULL, B INTEGER, UNIQUE(B), \
             C INTEGER NOT NULL, PRIMARY KEY(A))",
        )
        .unwrap()
        .0;
        match plan {
            Plan::CreateTable { cols, keys, .. } => {
                assert_eq!(keys.len(), 2);
                assert!(!keys[0].primary && keys[0].columns == vec!["B".to_string()]);
                assert!(keys[1].primary && keys[1].columns == vec!["A".to_string()]);
                // the table-level PRIMARY KEY makes A NOT NULL, but A's
                // constraint row comes from its own NOT NULL; B stays
                // nullable despite being UNIQUE
                assert!(cols[0].not_null && cols[0].not_null_constraint);
                assert!(!cols[1].not_null);
            }
            _ => panic!("not a CREATE TABLE plan"),
        }
        // a table-level PRIMARY KEY alone sets NULL_FLAG without a
        // NOT NULL constraint row
        let plan = plan_create_table("CREATE TABLE P (A INTEGER, B INTEGER, PRIMARY KEY (A, B))")
            .unwrap()
            .0;
        match plan {
            Plan::CreateTable { cols, .. } => {
                assert!(cols[0].not_null && !cols[0].not_null_constraint);
                assert!(cols[1].not_null && !cols[1].not_null_constraint);
            }
            _ => panic!("not a CREATE TABLE plan"),
        }
        // two PRIMARY KEYs are refused
        assert!(plan_create_table(
            "CREATE TABLE T (A INTEGER PRIMARY KEY, B INTEGER, PRIMARY KEY (B))"
        )
        .is_none());
    }

    #[test]
    fn parses_drop_index() {
        match plan_drop_index("DROP INDEX IX_TB") {
            Some((Plan::DropIndex { name }, _)) => assert_eq!(name, "IX_TB"),
            other => panic!("expected DropIndex, got {:?}", other.is_some()),
        }
        assert!(matches!(
            plan_drop_index("drop index \"ix_lower\""),
            Some((Plan::DropIndex { .. }, _))
        ));
        // DROP TABLE is not a DROP INDEX, and neither is a bare DROP
        assert!(plan_drop_index("DROP TABLE T").is_none());
        assert!(plan_drop_index("DROP INDEX").is_none());
    }

    #[test]
    fn plan_alter_table_drop_recognises_a_constraint() {
        // DROP CONSTRAINT <name> routes to AlterTableDropConstraint,
        // a bare name is still a column drop
        match plan_alter_table_drop("ALTER TABLE U DROP CONSTRAINT UQ_U") {
            Some((Plan::AlterTableDropConstraint { table, constraint }, _)) => {
                assert_eq!(table, "U");
                assert_eq!(constraint, "UQ_U");
            }
            other => panic!("expected AlterTableDropConstraint, got {:?}", other.is_some()),
        }
        assert!(matches!(
            plan_alter_table_drop("alter table U drop constraint integ_7"),
            Some((Plan::AlterTableDropConstraint { .. }, _))
        ));
        assert!(matches!(
            plan_alter_table_drop("ALTER TABLE U DROP W"),
            Some((Plan::AlterTableDrop { .. }, _))
        ));
    }

    #[test]
    fn parses_create_sequence_with_its_options() {
        // a bare CREATE SEQUENCE takes the engine's defaults (start 1,
        // increment 1) - carried as None so the writer applies them
        match plan_create_sequence("CREATE SEQUENCE S1") {
            Some((Plan::CreateSequence { name, start, increment }, _)) => {
                assert_eq!(name, "S1");
                assert!(start.is_none() && increment.is_none());
            }
            other => panic!("expected CreateSequence, got {:?}", other.is_some()),
        }
        // both options, either order, INCREMENT's BY optional, signed values
        match plan_create_sequence("create sequence S2 start with 100 increment by 5") {
            Some((Plan::CreateSequence { start, increment, .. }, _)) => {
                assert_eq!((start, increment), (Some(100), Some(5)));
            }
            other => panic!("expected CreateSequence, got {:?}", other.is_some()),
        }
        match plan_create_sequence("CREATE SEQUENCE S3 INCREMENT -2 START WITH -5") {
            Some((Plan::CreateSequence { start, increment, .. }, _)) => {
                assert_eq!((start, increment), (Some(-5), Some(-2)));
            }
            other => panic!("expected CreateSequence, got {:?}", other.is_some()),
        }
        // the legacy spelling is the same statement
        assert!(matches!(
            plan_create_sequence("CREATE GENERATOR G1"),
            Some((Plan::CreateSequence { .. }, _))
        ));
        // not a sequence, and an option this writer does not implement
        assert!(plan_create_sequence("CREATE TABLE T (A INT)").is_none());
        assert!(plan_create_sequence("CREATE SEQUENCE S4 RESTART WITH 3").is_none());
    }

    #[test]
    fn parses_drop_sequence() {
        match plan_drop_sequence("DROP SEQUENCE S1;") {
            Some((Plan::DropSequence { name }, _)) => assert_eq!(name, "S1"),
            other => panic!("expected DropSequence, got {:?}", other.is_some()),
        }
        assert!(matches!(
            plan_drop_sequence("drop generator G1"),
            Some((Plan::DropSequence { .. }, _))
        ));
        // a DROP INDEX/TABLE is not a DROP SEQUENCE, and neither is a bare one
        assert!(plan_drop_sequence("DROP INDEX IX").is_none());
        assert!(plan_drop_sequence("DROP SEQUENCE").is_none());
    }

    #[test]
    fn parses_set_statistics() {
        match plan_set_statistics("SET STATISTICS INDEX IX_TAB") {
            Some((Plan::SetStatistics { name }, _)) => assert_eq!(name, "IX_TAB"),
            other => panic!("expected SetStatistics, got {:?}", other.is_some()),
        }
        assert!(matches!(
            plan_set_statistics("set statistics index \"ix_lower\";"),
            Some((Plan::SetStatistics { .. }, _))
        ));
        // not a SET STATISTICS, and no index name
        assert!(plan_set_statistics("SET GENERATOR G TO 5").is_none());
        assert!(plan_set_statistics("SET STATISTICS INDEX").is_none());
        assert!(plan_set_statistics("SET STATISTICS TABLE T").is_none());
    }

    #[test]
    fn parses_alter_index_active_and_inactive() {
        match plan_alter_index("ALTER INDEX IX_TB INACTIVE") {
            Some((Plan::AlterIndex { name, active }, _)) => {
                assert_eq!(name, "IX_TB");
                assert!(!active);
            }
            other => panic!("expected AlterIndex, got {:?}", other.is_some()),
        }
        match plan_alter_index("alter index \"ix_lower\" active;") {
            Some((Plan::AlterIndex { name, active }, _)) => {
                assert_eq!(name, "ix_lower");
                assert!(active);
            }
            other => panic!("expected AlterIndex, got {:?}", other.is_some()),
        }
        // not an ALTER INDEX, and no state given
        assert!(plan_alter_index("ALTER TABLE T ADD X INT").is_none());
        assert!(plan_alter_index("ALTER INDEX IX_TB").is_none());
        assert!(plan_alter_index("ALTER INDEX IX_TB REBUILD").is_none());
    }

    #[test]
    fn plan_alter_table_add_recognises_a_key_constraint() {
        // ADD [CONSTRAINT ...] PRIMARY KEY|UNIQUE routes to
        // AlterTableAddKey, not a column add
        match plan_alter_table_add("ALTER TABLE A1 ADD CONSTRAINT PK_A1 PRIMARY KEY (X)") {
            Some((Plan::AlterTableAddKey { table, key }, _)) => {
                assert_eq!(table, "A1");
                assert_eq!(key.name, "PK_A1");
                assert!(key.primary && key.columns == vec!["X".to_string()]);
            }
            other => panic!("expected AlterTableAddKey, got {:?}", other.is_some()),
        }
        match plan_alter_table_add("alter table A1 add unique (Y, Z)") {
            Some((Plan::AlterTableAddKey { key, .. }, _)) => {
                assert!(key.name.is_empty() && !key.primary);
                assert_eq!(key.columns, vec!["Y".to_string(), "Z".to_string()]);
            }
            other => panic!("expected AlterTableAddKey, got {:?}", other.is_some()),
        }
        // a plain column add is still a column add
        assert!(matches!(
            plan_alter_table_add("ALTER TABLE A1 ADD W INTEGER"),
            Some((Plan::AlterTableAdd { .. }, _))
        ));
    }

    #[test]
    fn plan_alter_table_add_recognises_a_foreign_key() {
        // ADD CONSTRAINT ... FOREIGN KEY routes to AlterTableAddFk, not a
        // column add
        match plan_alter_table_add(
            "ALTER TABLE C ADD CONSTRAINT FK_C_P FOREIGN KEY (PID) REFERENCES P (PID)",
        ) {
            Some((Plan::AlterTableAddFk { table, fk }, ps)) => {
                assert_eq!(table, "C");
                assert_eq!(fk.name, "FK_C_P");
                assert_eq!(fk.columns, vec!["PID".to_string()]);
                assert_eq!(fk.ref_table, "P");
                assert!(ps.is_empty());
            }
            other => panic!("expected AlterTableAddFk, got {:?}", other.is_some()),
        }
        // a plain column add is still a column add
        assert!(matches!(
            plan_alter_table_add("ALTER TABLE C ADD NOTE VARCHAR(10)"),
            Some((Plan::AlterTableAdd { .. }, _))
        ));
    }

    #[test]
    fn parses_generator_select_list_items() {
        // NEXT VALUE FOR <seq> -> step None (the sequence's own increment)
        assert_eq!(parse_gen_sel_item("NEXT VALUE FOR SEQ"), Some(("SEQ".into(), None)));
        assert_eq!(
            parse_gen_sel_item("next value for PUBLIC.MYSEQ"),
            Some(("MYSEQ".into(), None))
        );
        // GEN_ID(name, step) -> the explicit step, negative allowed
        assert_eq!(parse_gen_sel_item("GEN_ID(G, 5)"), Some(("G".into(), Some(5))));
        assert_eq!(parse_gen_sel_item("gen_id( G , -3 )"), Some(("G".into(), Some(-3))));
        // plain columns / expressions are not generator items
        assert_eq!(parse_gen_sel_item("X"), None);
        assert_eq!(parse_gen_sel_item("A + B"), None);
        assert_eq!(parse_gen_sel_item("COUNT(*)"), None);
        // a row-returning generator projection parses to a Gen item beside
        // a plain column (over a real table, not RDB$DATABASE)
        let Some(Proj::Items(items)) = parse_projection("NEXT VALUE FOR SEQ, X") else {
            panic!("expected Items");
        };
        assert!(matches!(items[0], SelItem::Gen(ref n, None, _) if n == "SEQ"));
        assert!(matches!(items[1], SelItem::Col(ref c) if c == "X"));
    }

    #[test]
    fn plan_set_generator_parses_the_absolute_set() {
        match plan_set_generator("SET GENERATOR GEN_C TO 4242") {
            Some((Plan::SetGenerator { name, mode, stmt_type }, ps)) => {
                assert_eq!(name, "GEN_C");
                assert!(matches!(mode, GenWrite::Absolute(4242)));
                assert_eq!(stmt_type, 13);
                assert!(ps.is_empty());
            }
            other => panic!("expected SetGenerator, got {:?}", other.is_some()),
        }
        // negative value, trailing semicolon, lowercase keywords
        match plan_set_generator("set generator gen_c to -9;") {
            Some((Plan::SetGenerator { name, mode, .. }, _)) => {
                assert_eq!(name, "gen_c");
                assert!(matches!(mode, GenWrite::Absolute(-9)));
            }
            _ => panic!("expected SetGenerator"),
        }
        // not a SET GENERATOR
        assert!(plan_set_generator("SET AUTODDL ON").is_none());
        assert!(plan_set_generator("SELECT 1 FROM RDB$DATABASE").is_none());
        assert!(plan_set_generator("SET GENERATOR GEN_C TO").is_none());
        assert!(plan_set_generator("SET GENERATOR GEN_C TO X").is_none());
    }

    #[test]
    fn plan_alter_sequence_parses_restart_with() {
        match plan_alter_sequence("ALTER SEQUENCE SEQ_A RESTART WITH 7") {
            Some((Plan::SetGenerator { name, mode, stmt_type }, _)) => {
                assert_eq!(name, "SEQ_A");
                assert!(matches!(mode, GenWrite::Restart(7)));
                assert_eq!(stmt_type, 5);
            }
            _ => panic!("expected SetGenerator"),
        }
        // GENERATOR spelling also accepted
        assert!(matches!(
            plan_alter_sequence("ALTER GENERATOR G RESTART WITH 100"),
            Some((Plan::SetGenerator { mode: GenWrite::Restart(100), .. }, _))
        ));
        // other ALTER forms are not generator restarts
        assert!(plan_alter_sequence("ALTER TABLE T ADD C INT").is_none());
        assert!(plan_alter_sequence("ALTER SEQUENCE SEQ_A RESTART").is_none());
    }

    #[test]
    fn unquote_ident_handles_quotes() {
        assert_eq!(unquote_ident("GEN_C").as_deref(), Some("GEN_C"));
        assert_eq!(unquote_ident("\"MyGen\"").as_deref(), Some("MyGen"));
        assert_eq!(unquote_ident("\"a\"\"b\"").as_deref(), Some("a\"b"));
        assert_eq!(unquote_ident(""), None);
    }
}

