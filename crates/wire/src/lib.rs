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

use std::io::{Read, Write};
use std::net::TcpStream;

// Opcodes, src/remote/protocol.h
pub const OP_CONNECT: i32 = 1;
pub const OP_ACCEPT: i32 = 3;
pub const OP_REJECT: i32 = 4;
pub const OP_ATTACH: i32 = 19;
pub const OP_ACCEPT_DATA: i32 = 94;
pub const OP_COND_ACCEPT: i32 = 98;

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
