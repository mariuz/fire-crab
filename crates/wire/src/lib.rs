//! # fire-crab-wire
//!
//! The Firebird wire protocol, converted from `src/remote/` - the
//! foundation of the firebird-qa milestone. This first slice is the
//! **connect/accept handshake**: the XDR framing (`src/remote/xdr.cpp`)
//! and the protocol-version negotiation (op_connect / op_accept /
//! op_cond_accept in `src/remote/protocol.h`, the `p_cnct` structure).
//!
//! A client opens TCP to the server, sends `op_connect` offering a list
//! of protocol versions with its architecture and packet-type range,
//! and the server replies selecting the highest version it also
//! supports (op_accept), possibly with authentication data
//! (op_accept_data / op_cond_accept). Getting the negotiated version
//! right is the first thing every higher operation - attach, prepare,
//! execute, fetch - depends on, and it is directly checkable against
//! the C++ client, which negotiates the same version with the same
//! server.
//!
//! Not yet converted (the remaining road to firebird-qa, in order):
//! the SRP proof and `op_cont_auth`, wire encryption (ChaCha/Arc4),
//! `op_attach`, statement allocation/prepare, `op_execute`/`op_fetch`.
//! See `docs/subsystem-map.md`.

pub mod crypto;
pub mod server;
pub mod srp;

use std::io::{Read, Write};
use std::net::TcpStream;

// Opcodes, src/remote/protocol.h
pub const OP_CONNECT: i32 = 1;
pub const OP_ACCEPT: i32 = 3;
pub const OP_REJECT: i32 = 4;
pub const OP_ATTACH: i32 = 19;
pub const OP_ACCEPT_DATA: i32 = 94;
pub const OP_COND_ACCEPT: i32 = 98;
pub const OP_RESPONSE: i32 = 9;
pub const OP_DETACH: i32 = 21;
pub const OP_CONT_AUTH: i32 = 92;
pub const OP_CRYPT: i32 = 96;
pub const OP_TRANSACTION: i32 = 29;
pub const OP_COMMIT: i32 = 30;
pub const OP_ROLLBACK: i32 = 31;
pub const OP_ALLOCATE_STATEMENT: i32 = 62;
pub const OP_EXECUTE: i32 = 63;
pub const OP_FETCH: i32 = 65;
pub const OP_FETCH_RESPONSE: i32 = 66;
pub const OP_FREE_STATEMENT: i32 = 67;
pub const OP_PREPARE_STATEMENT: i32 = 68;
pub const SQL_DIALECT_3: i32 = 3;
pub const DSQL_DROP: i32 = 1;

pub const CONNECT_VERSION3: i32 = 3;
pub const ARCH_GENERIC: i32 = 1;
pub const PTYPE_BATCH_SEND: i32 = 3;

// p_cnct_user_id tags (CNCT_*), protocol.h
const CNCT_USER: u8 = 1;
const CNCT_HOST: u8 = 4;
const CNCT_USER_VERIFICATION: u8 = 6;
const CNCT_SPECIFIC_DATA: u8 = 7;
const CNCT_PLUGIN_NAME: u8 = 8;
const CNCT_LOGIN: u8 = 9;
const CNCT_PLUGIN_LIST: u8 = 10;
const CNCT_CLIENT_CRYPT: u8 = 11;

/// XDR writer: big-endian 32-bit ints and length-prefixed opaque data
/// padded to a 4-byte boundary (src/remote/xdr.cpp).
#[derive(Default)]
pub struct XdrWriter {
    buf: Vec<u8>,
}

impl XdrWriter {
    pub fn int(&mut self, v: i32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_be_bytes());
        self
    }
    pub fn bytes(&mut self, data: &[u8]) -> &mut Self {
        self.int(data.len() as i32);
        self.buf.extend_from_slice(data);
        let pad = (4 - data.len() % 4) % 4;
        self.buf.extend(std::iter::repeat(0).take(pad));
        self
    }
    pub fn str(&mut self, s: &str) -> &mut Self {
        self.bytes(s.as_bytes())
    }
    pub fn finish(&self) -> &[u8] {
        &self.buf
    }
}

/// XDR reader over a TcpStream: the same framing in reverse.
pub struct XdrReader<'a> {
    stream: &'a mut TcpStream,
}

impl<'a> XdrReader<'a> {
    pub fn new(stream: &'a mut TcpStream) -> Self {
        XdrReader { stream }
    }
    pub fn take(&mut self, n: usize) -> std::io::Result<Vec<u8>> {
        let mut b = vec![0u8; n];
        self.stream.read_exact(&mut b)?;
        Ok(b)
    }
    pub fn int(&mut self) -> std::io::Result<i32> {
        let b = self.take(4)?;
        Ok(i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub fn bytes(&mut self) -> std::io::Result<Vec<u8>> {
        let n = self.int()? as usize;
        let data = self.take(n)?;
        let pad = (4 - n % 4) % 4;
        self.take(pad)?;
        Ok(data)
    }
}

/// The p_cnct_user_id block: a sequence of [tag][len][data] items
/// (protocol.h). For pure protocol negotiation we present a login,
/// the Srp256 plugin and list, a placeholder specific-data (the SRP
/// client key would go here to continue auth), and the wire-crypt
/// stance the default server config requires.
fn user_id_block(login: &str, specific_data: &[u8]) -> Vec<u8> {
    let mut p = Vec::new();
    let mut tlv = |tag: u8, data: &[u8]| {
        p.push(tag);
        p.push(data.len() as u8);
        p.extend_from_slice(data);
    };
    tlv(CNCT_LOGIN, login.as_bytes());
    tlv(CNCT_PLUGIN_NAME, b"Srp256");
    tlv(CNCT_PLUGIN_LIST, b"Srp256,Srp");
    // specific data (SRP key A as hex) in <=254-byte chunks, each with a
    // leading sequence byte (serialize.js addMultiblockPart)
    for (i, chunk) in specific_data.chunks(254).enumerate() {
        p.push(CNCT_SPECIFIC_DATA);
        p.push((chunk.len() + 1) as u8);
        p.push(i as u8);
        p.extend_from_slice(chunk);
    }
    // client wire-crypt stance ENABLED (4-byte LE) - the default
    // WireCrypt=Enabled server rejects a DISABLED client
    p.extend_from_slice(&[CNCT_CLIENT_CRYPT, 4, 1, 0, 0, 0]);
    p.extend_from_slice(&[CNCT_USER, login.len() as u8]);
    p.extend_from_slice(login.as_bytes());
    p.extend_from_slice(&[CNCT_HOST, 9]);
    p.extend_from_slice(b"localhost");
    p.extend_from_slice(&[CNCT_USER_VERIFICATION, 0]);
    p
}

/// The outcome of a negotiation.
#[derive(Debug, Clone)]
pub struct Negotiated {
    /// op_accept / op_accept_data / op_cond_accept
    pub opcode: i32,
    /// selected protocol version (flag bit masked off)
    pub version: i32,
    pub architecture: i32,
    pub packet_type: i32,
    /// plugin data for accept_data/cond_accept (salt + server key B),
    /// undecoded - the SRP step will parse it
    pub auth_data: Vec<u8>,
}

/// Connect to a Firebird server and negotiate a protocol version by
/// offering `versions` (e.g. 13..=20). Returns the server's selection.
/// This performs the op_connect exchange only - not authentication.
pub fn negotiate(
    host: &str,
    port: u16,
    db_path: &str,
    login: &str,
    versions: &[i32],
    specific_data: &[u8],
) -> std::io::Result<Negotiated> {
    let mut stream = TcpStream::connect((host, port))?;

    let uid = user_id_block(login, specific_data);
    let mut w = XdrWriter::default();
    w.int(OP_CONNECT)
        .int(OP_ATTACH)
        .int(CONNECT_VERSION3)
        .int(ARCH_GENERIC)
        .str(db_path)
        .int(versions.len() as i32)
        .bytes(&uid);
    // one protocol-version-info tuple per offered version:
    // (version | 0x8000, arch, min ptype, max ptype, weight)
    for (i, &v) in versions.iter().enumerate() {
        w.int(v | 0x8000)
            .int(ARCH_GENERIC)
            .int(PTYPE_BATCH_SEND)
            .int(PTYPE_BATCH_SEND)
            .int(i as i32 + 2);
    }
    stream.write_all(w.finish())?;

    let mut r = XdrReader::new(&mut stream);
    let opcode = r.int()?;
    if opcode == OP_REJECT {
        return Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "op_reject: no protocol/plugin in common",
        ));
    }
    let version = r.int()? & 0x7fff;
    let architecture = r.int()?;
    let packet_type = r.int()?;
    let auth_data = if opcode == OP_ACCEPT_DATA || opcode == OP_COND_ACCEPT {
        r.bytes()?
    } else {
        Vec::new()
    };

    Ok(Negotiated {
        opcode,
        version,
        architecture,
        packet_type,
        auth_data,
    })
}

use crate::crypto::Rc4;
use crate::srp::{client_start, SrpClient};

/// A live, authenticated attachment to a database over the encrypted
/// wire - the point where fire-crab first LOGS IN to the engine.
pub struct Attachment {
    stream: TcpStream,
    enc: Rc4,
    dec: Rc4,
    pub protocol: i32,
    pub handle: i32,
}

/// Read one XDR int, decrypting through `dec` if present.
fn read_int_maybe(stream: &mut TcpStream, dec: Option<&mut Rc4>) -> std::io::Result<i32> {
    let mut b = [0u8; 4];
    stream.read_exact(&mut b)?;
    if let Some(d) = dec {
        let p = d.transform(&b);
        Ok(i32::from_be_bytes([p[0], p[1], p[2], p[3]]))
    } else {
        Ok(i32::from_be_bytes(b))
    }
}

fn read_bytes_maybe(stream: &mut TcpStream, dec: &mut Option<Rc4>) -> std::io::Result<Vec<u8>> {
    let n = read_int_maybe(stream, dec.as_mut())? as usize;
    let mut data = vec![0u8; n];
    stream.read_exact(&mut data)?;
    let pad = (4 - n % 4) % 4;
    let mut p = vec![0u8; pad];
    stream.read_exact(&mut p)?;
    if let Some(d) = dec.as_mut() {
        let mut all = d.transform(&data);
        d.transform(&p); // consume the padding keystream
        all.truncate(n);
        return Ok(all);
    }
    Ok(data)
}

/// Consume an op_response (handle, blob id, data, status vector),
/// returning the object handle or an error carrying the status.
fn read_response(stream: &mut TcpStream, dec: &mut Option<Rc4>) -> std::io::Result<i32> {
    let handle = read_int_maybe(stream, dec.as_mut())?;
    // blob id (2 ints)
    read_int_maybe(stream, dec.as_mut())?;
    read_int_maybe(stream, dec.as_mut())?;
    read_bytes_maybe(stream, dec)?; // response data
    let mut msgs = Vec::new();
    loop {
        let t = read_int_maybe(stream, dec.as_mut())?;
        if t == 0 {
            break;
        } else if t == 1 || t == 4 || t == 19 {
            let c = read_int_maybe(stream, dec.as_mut())?;
            if t == 1 && c != 0 {
                msgs.push(format!("gds {}", c));
            }
        } else {
            let b = read_bytes_maybe(stream, dec)?;
            msgs.push(String::from_utf8_lossy(&b).into_owned());
        }
    }
    if !msgs.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("server error: {}", msgs.join(", ")),
        ));
    }
    Ok(handle)
}

/// The full login: op_connect negotiation -> SRP proof (op_cont_auth)
/// -> op_crypt (Arc4) -> op_attach, over TCP to a live server. Returns
/// an authenticated Attachment.
pub fn login(
    host: &str,
    port: u16,
    db_path: &str,
    user: &str,
    password: &str,
    a_bytes: &[u8],
    versions: &[i32],
) -> std::io::Result<Attachment> {
    let user = user.to_uppercase(); // unquoted identifiers uppercased
    let srp: SrpClient = client_start(a_bytes);

    // -- op_connect, presenting A --
    let uid = user_id_block(&user, srp.a_hex.as_bytes());
    let offered = versions;
    let mut w = XdrWriter::default();
    w.int(OP_CONNECT)
        .int(OP_ATTACH)
        .int(CONNECT_VERSION3)
        .int(ARCH_GENERIC)
        .str(db_path)
        .int(offered.len() as i32)
        .bytes(&uid);
    for (i, &v) in offered.iter().enumerate() {
        w.int(v | 0x8000)
            .int(ARCH_GENERIC)
            .int(PTYPE_BATCH_SEND)
            .int(PTYPE_BATCH_SEND)
            .int(i as i32 + 2);
    }
    let mut stream = TcpStream::connect((host, port))?;
    // never block forever on an unexpected/closed response (e.g. the
    // anti-enumeration path for a nonexistent user)
    stream.set_read_timeout(Some(std::time::Duration::from_secs(10)))?;
    stream.write_all(w.finish())?;

    let opcode = read_int_maybe(&mut stream, None)?;
    if opcode == OP_REJECT {
        return Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "op_reject",
        ));
    }
    let protocol = read_int_maybe(&mut stream, None)? & 0x7fff;
    read_int_maybe(&mut stream, None)?; // arch
    read_int_maybe(&mut stream, None)?; // ptype
    let mut none: Option<Rc4> = None;
    let data = read_bytes_maybe(&mut stream, &mut none)?; // salt + B
    let _plugin = read_bytes_maybe(&mut stream, &mut none)?;
    read_int_maybe(&mut stream, None)?; // authenticated flag
    read_bytes_maybe(&mut stream, &mut none)?; // p_acpt_keys

    // salt + B are 2-byte-LE-length-prefixed inside `data`
    let salt_len = u16::from_le_bytes([data[0], data[1]]) as usize;
    let salt = &data[2..2 + salt_len];
    let key_len = u16::from_le_bytes([data[2 + salt_len], data[3 + salt_len]]) as usize;
    let b_hex = String::from_utf8_lossy(&data[4 + salt_len..4 + salt_len + key_len]).into_owned();

    // -- op_cont_auth with the proof M --
    let proof = srp.proof(&user, password, salt, &b_hex);
    let mut w = XdrWriter::default();
    w.int(OP_CONT_AUTH)
        .str(&proof.m_hex)
        .str("Srp256")
        .str("Srp256,Srp")
        .str("");
    stream.write_all(w.finish())?;
    if read_int_maybe(&mut stream, None)? != OP_RESPONSE {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "expected op_response to op_cont_auth",
        ));
    }
    read_response(&mut stream, &mut none)?;

    // -- op_crypt: Arc4 keyed by the session key K --
    let mut enc = Rc4::new(&proof.session_key);
    let mut dec_opt = Some(Rc4::new(&proof.session_key));
    let mut w = XdrWriter::default();
    w.int(OP_CRYPT).str("Arc4").str("Symmetric");
    stream.write_all(w.finish())?; // sent in cleartext
    if read_int_maybe(&mut stream, dec_opt.as_mut())? != OP_RESPONSE {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "expected op_response to op_crypt",
        ));
    }
    read_response(&mut stream, &mut dec_opt)?;

    // -- op_attach (encrypted), minimal DPB, no credentials --
    let mut dpb = vec![1u8]; // isc_dpb_version1
    dpb.push(48);
    dpb.push(4);
    dpb.extend_from_slice(b"NONE"); // isc_dpb_lc_ctype
    dpb.push(28);
    dpb.push(user.len() as u8);
    dpb.extend_from_slice(user.as_bytes()); // isc_dpb_user_name
    let mut w = XdrWriter::default();
    w.int(OP_ATTACH).int(0).str(db_path).bytes(&dpb);
    stream.write_all(&enc.transform(w.finish()))?;
    if read_int_maybe(&mut stream, dec_opt.as_mut())? != OP_RESPONSE {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "expected op_response to op_attach",
        ));
    }
    let handle = read_response(&mut stream, &mut dec_opt)?;

    Ok(Attachment {
        stream,
        enc,
        dec: dec_opt.unwrap(),
        protocol,
        handle,
    })
}

// XSQLDA describe items requested on prepare (isc_info_sql_*). We only
// need to know the prepare succeeded; the describe is parsed by higher
// layers later, so a compact request suffices.
const DESCRIBE_ITEMS: &[u8] = &[
    21, // isc_info_sql_stmt_type
    5,  // isc_info_sql_bind
    7,  // isc_info_sql_describe_vars
    8,  // isc_info_sql_describe_end
    4,  // isc_info_sql_select
    7,  // isc_info_sql_describe_vars
    9,  // isc_info_sql_sqlda_seq
    11, // isc_info_sql_type
    12, // isc_info_sql_sub_type
    13, // isc_info_sql_scale
    14, // isc_info_sql_length
    15, // isc_info_sql_null_ind
    16, // isc_info_sql_field
    17, // isc_info_sql_relation
    18, // isc_info_sql_owner
    19, // isc_info_sql_alias
    8,  // isc_info_sql_describe_end
];

/// A read-committed, record-version, wait TPB (isc_tpb_*).
const TPB_READ_COMMITTED: &[u8] = &[
    3,  /*version3*/
    8,  /*read*/
    15, /*read_committed*/
    17, /*rec_version*/
    6,  /*wait*/
];

// SQL type codes (ibase). We coerce to two wire shapes at fetch time,
// exactly as the reference clients do: integer-family (scale 0) -> INT64,
// text-family -> VARYING. Other types are reported as unsupported.
const SQL_VARYING: u32 = 448;
const SQL_TEXT: u32 = 452;
const SQL_SHORT: u32 = 500;
const SQL_LONG: u32 = 496;
const SQL_INT64: u32 = 580;

/// A column's fetch category, decided from the prepare describe.
#[derive(Clone, Copy, PartialEq)]
enum ColKind {
    Int,
    Text(u16),
    Unsupported,
}

/// Minimal parse of the prepare describe buffer: for each SELECT column,
/// extract (sqltype, scale) and reduce to a ColKind. The buffer is a
/// stream of isc_info_sql_* items, each (except terminators) carrying a
/// 2-byte LE length then that many payload bytes.
fn parse_describe(buf: &[u8]) -> Option<Vec<ColKind>> {
    // Locate the column section: the marker bytes isc_info_sql_select(4),
    // isc_info_sql_describe_vars(7), then a 2-byte length (0x0004) and the
    // 4-byte column count. Header items before this are a mix of bare
    // codes (bind=5, select=4) and length-prefixed ones, so we scan for
    // the exact 4-byte marker rather than trying to skip each item.
    let mut i = (0..buf.len().saturating_sub(3))
        .find(|&j| buf[j] == 4 && buf[j + 1] == 7 && buf[j + 2] == 4 && buf[j + 3] == 0)?;
    i += 8; // past marker(2) + length(2) + column-count(4)

    // Column items are uniform: [code][u16 le len][payload], except the
    // bare terminators describe_end(8) and isc_info_end(1).
    let mut cols: Vec<ColKind> = Vec::new();
    let mut cur_type: Option<u32> = None;
    let mut cur_scale: i32 = 0;
    let mut cur_len: u16 = 0;
    while i < buf.len() {
        let code = buf[i] as u32;
        i += 1;
        match code {
            8 => {
                if let Some(t) = cur_type.take() {
                    let base = t & !1;
                    cols.push(match base {
                        // coerced text keeps its declared length (the fetch
                        // BLR emits blr_varying with this length)
                        SQL_TEXT | SQL_VARYING => ColKind::Text(cur_len),
                        SQL_SHORT | SQL_LONG | SQL_INT64 if cur_scale == 0 => ColKind::Int,
                        _ => ColKind::Unsupported,
                    });
                    cur_scale = 0;
                    cur_len = 0;
                }
            }
            1 => break,
            _ => {
                if i + 2 > buf.len() {
                    break;
                }
                let plen = u16::from_le_bytes([buf[i], buf[i + 1]]) as usize;
                let payload = buf.get(i + 2..i + 2 + plen)?;
                match code {
                    11 => cur_type = Some(le_i32(payload) as u32),
                    13 => cur_scale = le_i32(payload),
                    14 => cur_len = le_i32(payload) as u16, // isc_info_sql_length
                    _ => {}
                }
                i += 2 + plen;
            }
        }
    }
    if cols.is_empty() {
        None
    } else {
        Some(cols)
    }
}

fn le_i32(b: &[u8]) -> i32 {
    let mut v = [0u8; 4];
    for (i, x) in b.iter().take(4).enumerate() {
        v[i] = *x;
    }
    i32::from_le_bytes(v)
}

impl Attachment {
    fn send_enc(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        let ct = self.enc.transform(bytes);
        self.stream.write_all(&ct)
    }
    fn recv_int(&mut self) -> std::io::Result<i32> {
        let mut d = Some(std::mem::replace(&mut self.dec, Rc4::new(&[0])));
        let v = read_int_maybe(&mut self.stream, d.as_mut());
        self.dec = d.unwrap();
        v
    }
    fn recv_response(&mut self) -> std::io::Result<i32> {
        let mut d = Some(std::mem::replace(&mut self.dec, Rc4::new(&[0])));
        let v = read_response(&mut self.stream, &mut d);
        self.dec = d.unwrap();
        v
    }
    fn recv_bytes(&mut self) -> std::io::Result<Vec<u8>> {
        let mut d = Some(std::mem::replace(&mut self.dec, Rc4::new(&[0])));
        let v = read_bytes_maybe(&mut self.stream, &mut d);
        self.dec = d.unwrap();
        v
    }

    fn expect_response(&mut self) -> std::io::Result<i32> {
        if self.recv_int()? != OP_RESPONSE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "expected op_response",
            ));
        }
        self.recv_response()
    }

    /// Run a query that returns a single BIGINT column, one row -
    /// prepare, execute, fetch - and return the value. Proves the
    /// statement pipeline works end-to-end; the differential compares
    /// it to `SELECT ... FROM` through isql.
    pub fn query_i64(&mut self, sql: &str) -> std::io::Result<i64> {
        // op_transaction
        let mut w = XdrWriter::default();
        w.int(OP_TRANSACTION)
            .int(self.handle)
            .bytes(TPB_READ_COMMITTED);
        self.send_enc(w.finish())?;
        let tr = self.expect_response()?;

        // op_allocate_statement (immediate response with the real handle)
        let mut w = XdrWriter::default();
        w.int(OP_ALLOCATE_STATEMENT).int(self.handle);
        self.send_enc(w.finish())?;
        let stmt = self.expect_response()?;

        // op_prepare_statement with the real statement handle
        let mut w = XdrWriter::default();
        w.int(OP_PREPARE_STATEMENT)
            .int(tr)
            .int(stmt)
            .int(SQL_DIALECT_3)
            .str(sql)
            .bytes(DESCRIBE_ITEMS)
            .int(32768);
        self.send_enc(w.finish())?;
        self.expect_response()?; // describe info ignored

        // op_execute (no input parameters)
        let mut w = XdrWriter::default();
        w.int(OP_EXECUTE).int(stmt).int(tr).bytes(&[]).int(0).int(0);
        self.send_enc(w.finish())?;
        self.expect_response()?;

        // op_fetch: request 1 row, output BLR describing one INT64 column
        // blr_version5, blr_begin, blr_message 0, len=cols*2, [INT64,scale][SHORT,scale nullind], blr_end, blr_eoc
        let fetch_blr: &[u8] = &[5, 2, 4, 0, 2, 0, 16, 0, 7, 0, 255, 76];
        let mut w = XdrWriter::default();
        w.int(OP_FETCH).int(stmt).bytes(fetch_blr).int(0).int(1);
        self.send_enc(w.finish())?;

        let op = self.recv_int()?;
        if op == OP_RESPONSE {
            // an error came back instead of rows
            self.recv_response()?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "fetch: unexpected op_response",
            ));
        }
        if op != OP_FETCH_RESPONSE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("fetch: op {}", op),
            ));
        }
        let status = self.recv_int()?;
        let messages = self.recv_int()?;
        if status == 100 || messages == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "fetch: no row",
            ));
        }
        // protocol-13 row: null bitmap (ceil(1/8)=1 byte, padded to 4), then i64 (big-endian)
        let mut d = Some(std::mem::replace(&mut self.dec, Rc4::new(&[0])));
        let nullmap = {
            let mut b = vec![0u8; 4];
            self.stream.read_exact(&mut b)?;
            d.as_mut().unwrap().transform(&b)
        };
        let value = {
            let mut b = [0u8; 8];
            self.stream.read_exact(&mut b)?;
            let p = d.as_mut().unwrap().transform(&b);
            i64::from_be_bytes([p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]])
        };
        self.dec = d.unwrap();
        let is_null = nullmap[0] & 1 != 0;

        // op_fetch(count=1) is followed by a terminating op_fetch_response
        // (messages=0) marking end-of-batch; consume it so it does not leak
        // into the next op.
        let term = self.recv_int()?;
        if term == OP_FETCH_RESPONSE {
            self.recv_int()?; // status
            self.recv_int()?; // messages (0)
        }

        // op_free_statement (drop), then commit + read both responses
        let mut w = XdrWriter::default();
        w.int(OP_FREE_STATEMENT).int(stmt).int(DSQL_DROP);
        self.send_enc(w.finish())?;
        self.expect_response()?;
        let mut w = XdrWriter::default();
        w.int(OP_COMMIT).int(tr);
        self.send_enc(w.finish())?;
        self.expect_response()?;

        if is_null {
            Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "value is null",
            ))
        } else {
            Ok(value)
        }
    }
}

impl Attachment {
    /// Run a general SELECT and return every row as text columns -
    /// prepare, learn the column shape from the describe, fetch in
    /// batches, decode INT64 and VARYING (the coerced wire shapes),
    /// honor the null bitmap. The broad differential: any integer/text
    /// SELECT compared to isql.
    pub fn query_rows(&mut self, sql: &str) -> std::io::Result<Vec<Vec<String>>> {
        let ioerr = |m: &str| std::io::Error::new(std::io::ErrorKind::Other, m.to_string());

        let mut w = XdrWriter::default();
        w.int(OP_TRANSACTION)
            .int(self.handle)
            .bytes(TPB_READ_COMMITTED);
        self.send_enc(w.finish())?;
        let tr = self.expect_response()?;

        let mut w = XdrWriter::default();
        w.int(OP_ALLOCATE_STATEMENT).int(self.handle);
        self.send_enc(w.finish())?;
        let stmt = self.expect_response()?;

        let mut w = XdrWriter::default();
        w.int(OP_PREPARE_STATEMENT)
            .int(tr)
            .int(stmt)
            .int(SQL_DIALECT_3)
            .str(sql)
            .bytes(DESCRIBE_ITEMS)
            .int(32768);
        self.send_enc(w.finish())?;
        // the prepare op_response's DATA field carries the describe buffer
        if self.recv_int()? != OP_RESPONSE {
            return Err(ioerr("expected op_response to prepare"));
        }
        self.recv_int()?; // handle
        self.recv_int()?; // blob id lo
        self.recv_int()?; // blob id hi
        let describe = self.recv_bytes()?;
        // drain the status vector
        loop {
            let t = self.recv_int()?;
            if t == 0 {
                break;
            } else if t == 1 || t == 4 || t == 19 {
                self.recv_int()?;
            } else {
                self.recv_bytes()?;
            }
        }
        if std::env::var("D_DUMP").is_ok() {
            eprint!("DESCRIBE {} bytes:", describe.len());
            for b in &describe {
                eprint!(" {:02x}", b);
            }
            eprintln!();
        }
        let kinds = parse_describe(&describe).ok_or_else(|| ioerr("could not parse describe"))?;
        if kinds.iter().any(|k| *k == ColKind::Unsupported) {
            return Err(ioerr(
                "query has a column type not yet supported (int/text only)",
            ));
        }

        // op_execute (no params)
        let mut w = XdrWriter::default();
        w.int(OP_EXECUTE).int(stmt).int(tr).bytes(&[]).int(0).int(0);
        self.send_enc(w.finish())?;
        self.expect_response()?;

        // build the fetch output BLR from the column kinds
        let mut blr: Vec<u8> = vec![5, 2, 4, 0]; // version5, begin, message, msg#0
        let msg_len = (kinds.len() * 2) as u16;
        blr.extend_from_slice(&msg_len.to_le_bytes());
        for k in &kinds {
            match k {
                ColKind::Int => blr.extend_from_slice(&[16, 0]), // blr_int64, scale
                ColKind::Text(len) => {
                    blr.push(37); // blr_varying
                    blr.extend_from_slice(&len.to_le_bytes());
                }
                ColKind::Unsupported => unreachable!(),
            }
            blr.extend_from_slice(&[7, 0]); // blr_short nullind
        }
        blr.extend_from_slice(&[255, 76]); // blr_end, blr_eoc

        let ncols = kinds.len();
        let nullmap_len = {
            let bytes = ncols.div_ceil(8);
            if bytes % 4 == 0 {
                bytes
            } else {
                bytes + 4 - bytes % 4
            }
        };

        let mut rows: Vec<Vec<String>> = Vec::new();
        'outer: loop {
            let mut w = XdrWriter::default();
            w.int(OP_FETCH).int(stmt).bytes(&blr).int(0).int(200);
            self.send_enc(w.finish())?;

            let mut got_in_batch = 0;
            loop {
                let op = self.recv_int()?;
                if op == OP_RESPONSE {
                    self.recv_response()?;
                    return Err(ioerr("fetch: unexpected op_response"));
                }
                if op != OP_FETCH_RESPONSE {
                    return Err(ioerr("fetch: unexpected op"));
                }
                let status = self.recv_int()?;
                let messages = self.recv_int()?;
                if status == 100 {
                    break 'outer;
                }
                if messages == 0 {
                    // end of this batch; re-fetch if we saw rows
                    if got_in_batch == 0 {
                        break 'outer;
                    }
                    break;
                }
                // a row: null bitmap then values
                let nullmap = self.recv_raw(nullmap_len)?;
                let mut row = Vec::with_capacity(ncols);
                for (ci, k) in kinds.iter().enumerate() {
                    let is_null = nullmap[ci / 8] >> (ci % 8) & 1 != 0;
                    if is_null {
                        row.push("<null>".to_string());
                        continue;
                    }
                    match k {
                        ColKind::Int => {
                            let b = self.recv_raw(8)?;
                            let v = i64::from_be_bytes(b[..8].try_into().unwrap());
                            row.push(v.to_string());
                        }
                        ColKind::Text(_) => {
                            let d = self.recv_bytes()?;
                            row.push(String::from_utf8_lossy(&d).trim_end().to_string());
                        }
                        ColKind::Unsupported => unreachable!(),
                    }
                }
                rows.push(row);
                got_in_batch += 1;
            }
        }

        let mut w = XdrWriter::default();
        w.int(OP_FREE_STATEMENT).int(stmt).int(DSQL_DROP);
        self.send_enc(w.finish())?;
        self.expect_response()?;
        let mut w = XdrWriter::default();
        w.int(OP_COMMIT).int(tr);
        self.send_enc(w.finish())?;
        self.expect_response()?;

        Ok(rows)
    }

    /// Read `n` raw bytes, decrypting through the session cipher.
    fn recv_raw(&mut self, n: usize) -> std::io::Result<Vec<u8>> {
        let mut b = vec![0u8; n];
        self.stream.read_exact(&mut b)?;
        Ok(self.dec.transform(&b))
    }
}

impl Attachment {
    /// op_detach: close the attachment cleanly.
    pub fn detach(&mut self) -> std::io::Result<()> {
        let mut w = XdrWriter::default();
        w.int(OP_DETACH).int(self.handle);
        self.stream.write_all(&self.enc.transform(w.finish()))?;
        let mut dec = Some(std::mem::replace(&mut self.dec, Rc4::new(&[0])));
        if read_int_maybe(&mut self.stream, dec.as_mut())? == OP_RESPONSE {
            read_response(&mut self.stream, &mut dec)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xdr_opaque_pads_to_four() {
        let mut w = XdrWriter::default();
        w.str("abc"); // len 3 -> 4 (len) + 3 + 1 pad = 8 bytes
        assert_eq!(w.finish(), &[0, 0, 0, 3, b'a', b'b', b'c', 0]);

        let mut w = XdrWriter::default();
        w.str("abcd"); // len 4 -> no pad
        assert_eq!(w.finish().len(), 8);
    }

    #[test]
    fn int_is_big_endian() {
        let mut w = XdrWriter::default();
        w.int(OP_CONNECT);
        assert_eq!(w.finish(), &[0, 0, 0, 1]);
    }

    #[test]
    fn user_id_block_has_login_and_crypt() {
        let b = user_id_block("SYSDBA", b"");
        assert_eq!(b[0], CNCT_LOGIN);
        assert_eq!(b[1], 6);
        assert_eq!(&b[2..8], b"SYSDBA");
        // wire-crypt stance present
        assert!(b.windows(2).any(|w| w == [CNCT_CLIENT_CRYPT, 4]));
    }
}
