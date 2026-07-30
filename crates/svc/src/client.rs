//! A Services client: `op_service_attach` / `op_service_info` /
//! `op_service_detach` over real TCP, authenticated with SRP.
//!
//! This is the half that makes the conversion checkable against the
//! engine: the same items `fbsvcmgr` asks the real server for, asked by
//! fire-crab and decoded by [`crate::decode`]. If our decoder and the
//! engine's tool print the same values for the same items, the response
//! grammar is right; if they differ on one item, the item's SHAPE (string
//! vs numeric) is wrong, which is the mistake this whole crate exists to
//! prevent.
//!
//! Only the auth handshake is shared with `fire-crab-wire` (through
//! `fire-crab-auth`); the framing here is deliberately minimal, because a
//! service connection needs no statements, no BLR and no transactions.

use fire_crab_auth::crypto::Rc4;
use fire_crab_auth::{client_start, Algo};
use std::io::{Read, Write};
use std::net::TcpStream;

const OP_CONNECT: i32 = 1;
const OP_REJECT: i32 = 4;
const OP_RESPONSE: i32 = 9;
const OP_ACCEPT: i32 = 3;
const OP_ACCEPT_DATA: i32 = 94;
const OP_COND_ACCEPT: i32 = 98;
const OP_CONT_AUTH: i32 = 92;
const OP_SERVICE_ATTACH: i32 = 82;
const OP_SERVICE_DETACH: i32 = 83;
const OP_SERVICE_INFO: i32 = 84;
const OP_SERVICE_START: i32 = 85;
const OP_CRYPT: i32 = 96;

const CNCT_USER: u8 = 1;
const CNCT_HOST: u8 = 4;
const CNCT_USER_VERIFICATION: u8 = 6;
const CNCT_SPECIFIC_DATA: u8 = 7;
const CNCT_PLUGIN_NAME: u8 = 8;
const CNCT_LOGIN: u8 = 9;
const CNCT_PLUGIN_LIST: u8 = 10;
const CNCT_CLIENT_CRYPT: u8 = 11;

#[derive(Default)]
struct Xdr(Vec<u8>);

impl Xdr {
    fn int(&mut self, v: i32) -> &mut Self {
        self.0.extend_from_slice(&v.to_be_bytes());
        self
    }
    fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.int(b.len() as i32);
        self.0.extend_from_slice(b);
        for _ in 0..((4 - b.len() % 4) % 4) {
            self.0.push(0);
        }
        self
    }
    fn str(&mut self, s: &str) -> &mut Self {
        self.bytes(s.as_bytes())
    }
}

/// Reads and writes go through the Arc4 keystream once `op_crypt` has
/// been accepted; before that `cipher` is None and the bytes are plain.
/// The PADDING is part of the stream: skipping its keystream desyncs the
/// cipher for every later packet, which shows up as a nonsense opcode
/// several operations later.
fn read_int(s: &mut TcpStream, dec: &mut Option<Rc4>) -> Result<i32, String> {
    let mut b = [0u8; 4];
    s.read_exact(&mut b).map_err(|e| e.to_string())?;
    if let Some(d) = dec.as_mut() {
        let p = d.transform(&b);
        return Ok(i32::from_be_bytes([p[0], p[1], p[2], p[3]]));
    }
    Ok(i32::from_be_bytes(b))
}

fn read_bytes(s: &mut TcpStream, dec: &mut Option<Rc4>) -> Result<Vec<u8>, String> {
    let n = read_int(s, dec)? as usize;
    let mut data = vec![0u8; n];
    s.read_exact(&mut data).map_err(|e| e.to_string())?;
    let mut pad = vec![0u8; (4 - n % 4) % 4];
    s.read_exact(&mut pad).map_err(|e| e.to_string())?;
    if let Some(d) = dec.as_mut() {
        let out = d.transform(&data);
        d.transform(&pad); // consume the padding keystream
        return Ok(out);
    }
    Ok(data)
}

fn write_all(s: &mut TcpStream, enc: &mut Option<Rc4>, buf: &[u8]) -> Result<(), String> {
    let out = match enc.as_mut() {
        Some(e) => e.transform(buf),
        None => buf.to_vec(),
    };
    s.write_all(&out).map_err(|e| e.to_string())
}

/// An op_response: (handle, data, first gds code).
fn read_response(s: &mut TcpStream, dec: &mut Option<Rc4>) -> Result<(i32, Vec<u8>, i32), String> {
    let handle = read_int(s, dec)?;
    read_int(s, dec)?; // blob id
    read_int(s, dec)?;
    let data = read_bytes(s, dec)?;
    let mut gds = 0;
    loop {
        let t = read_int(s, dec)?;
        if t == 0 {
            break;
        } else if t == 1 || t == 4 || t == 19 {
            let c = read_int(s, dec)?;
            if t == 1 && gds == 0 {
                gds = c;
            }
        } else {
            read_bytes(s, dec)?;
        }
    }
    Ok((handle, data, gds))
}

fn user_id_block(login: &str, a_hex: &str) -> Vec<u8> {
    let mut p = Vec::new();
    let mut tlv = |tag: u8, data: &[u8]| {
        p.push(tag);
        p.push(data.len() as u8);
        p.extend_from_slice(data);
    };
    tlv(CNCT_LOGIN, login.as_bytes());
    tlv(CNCT_PLUGIN_NAME, b"Srp256");
    tlv(CNCT_PLUGIN_LIST, b"Srp256");
    for (i, chunk) in a_hex.as_bytes().chunks(254).enumerate() {
        p.push(CNCT_SPECIFIC_DATA);
        p.push((chunk.len() + 1) as u8);
        p.push(i as u8);
        p.extend_from_slice(chunk);
    }
    p.extend_from_slice(&[CNCT_CLIENT_CRYPT, 4, 1, 0, 0, 0]);
    p.extend_from_slice(&[CNCT_USER, login.len() as u8]);
    p.extend_from_slice(login.as_bytes());
    p.extend_from_slice(&[CNCT_HOST, 9]);
    p.extend_from_slice(b"localhost");
    p.extend_from_slice(&[CNCT_USER_VERIFICATION, 0]);
    p
}

/// An attached service manager.
pub struct Service {
    stream: TcpStream,
    handle: i32,
    enc: Option<Rc4>,
    dec: Option<Rc4>,
}

impl Service {
    /// Attach to `service_mgr` on a live server: op_connect (presenting
    /// A), the SRP proof, then op_service_attach with an SPB.
    ///
    /// Wire encryption is then negotiated with `op_crypt("Arc4",
    /// "Symmetric")`, keyed by the SRP session key. It is not optional in
    /// practice: a client that declares the wire-crypt stance ENABLED and
    /// then sends plaintext is refused by the default server with
    /// `isc_miss_wirecrypt` (335545065) at op_service_attach - the
    /// declaration is a promise.
    pub fn attach(
        host: &str,
        port: u16,
        user: &str,
        password: &str,
        a_bytes: &[u8],
    ) -> Result<Service, String> {
        let user = user.to_uppercase();
        let client = client_start(a_bytes);
        let uid = user_id_block(&user, &client.a_hex);

        let mut w = Xdr::default();
        w.int(OP_CONNECT)
            .int(OP_SERVICE_ATTACH) // the operation we intend
            .int(3) // CONNECT_VERSION3
            .int(1) // arch generic
            .str("service_mgr")
            .int(1)
            .bytes(&uid);
        w.int(13 | 0x8000).int(1).int(3).int(3).int(2);

        let mut s = TcpStream::connect((host, port)).map_err(|e| e.to_string())?;
        s.set_read_timeout(Some(std::time::Duration::from_secs(15)))
            .map_err(|e| e.to_string())?;
        let mut none: Option<Rc4> = None;
        s.write_all(&w.0).map_err(|e| e.to_string())?;

        let op = read_int(&mut s, &mut none)?;
        if op == OP_REJECT {
            return Err("op_reject".into());
        }
        if op == OP_RESPONSE {
            let (_, _, gds) = read_response(&mut s, &mut none)?;
            return Err(format!("connect refused, gds {}", gds));
        }
        if op != OP_ACCEPT_DATA && op != OP_COND_ACCEPT && op != OP_ACCEPT {
            return Err(format!("unexpected op {} after op_connect", op));
        }
        read_int(&mut s, &mut none)?; // protocol
        read_int(&mut s, &mut none)?; // arch
        read_int(&mut s, &mut none)?; // ptype
        if op == OP_ACCEPT {
            return Err("server did not negotiate SRP".into());
        }
        let data = read_bytes(&mut s, &mut none)?;
        let _plugin = read_bytes(&mut s, &mut none)?;
        read_int(&mut s, &mut none)?; // authenticated
        read_bytes(&mut s, &mut none)?; // keys

        let salt_len = u16::from_le_bytes([data[0], data[1]]) as usize;
        let salt = &data[2..2 + salt_len];
        let key_len = u16::from_le_bytes([data[2 + salt_len], data[3 + salt_len]]) as usize;
        let b_hex =
            String::from_utf8_lossy(&data[4 + salt_len..4 + salt_len + key_len]).into_owned();
        let proof = client.proof_with(Algo::Srp256, &user, password, salt, &b_hex);

        let mut w = Xdr::default();
        w.int(OP_CONT_AUTH)
            .str(&proof.m_hex)
            .str("Srp256")
            .str("Srp256")
            .str("");
        s.write_all(&w.0).map_err(|e| e.to_string())?;
        if read_int(&mut s, &mut none)? != OP_RESPONSE {
            return Err("expected op_response to op_cont_auth".into());
        }
        let (_, _, gds) = read_response(&mut s, &mut none)?;
        if gds != 0 {
            return Err(format!("authentication failed, gds {}", gds));
        }

        // op_crypt: Arc4 both ways, keyed by K. Sent in the clear; every
        // byte after it is enciphered.
        let mut enc = Some(Rc4::new(&proof.session_key));
        let mut dec = Some(Rc4::new(&proof.session_key));
        let mut w = Xdr::default();
        w.int(OP_CRYPT).str("Arc4").str("Symmetric");
        s.write_all(&w.0).map_err(|e| e.to_string())?;
        if read_int(&mut s, &mut dec)? != OP_RESPONSE {
            return Err("expected op_response to op_crypt".into());
        }
        let (_, _, gds) = read_response(&mut s, &mut dec)?;
        if gds != 0 {
            return Err(format!("wire encryption refused, gds {}", gds));
        }

        // op_service_attach: database id 0, the service name, the SPB
        let spb = crate::attach_spb(&user, "", "fcsvc", "fire-crab");
        let mut w = Xdr::default();
        w.int(OP_SERVICE_ATTACH)
            .int(0)
            .str("service_mgr")
            .bytes(&spb);
        write_all(&mut s, &mut enc, &w.0)?;
        if read_int(&mut s, &mut dec)? != OP_RESPONSE {
            return Err("expected op_response to op_service_attach".into());
        }
        let (handle, _, gds) = read_response(&mut s, &mut dec)?;
        if gds != 0 {
            return Err(format!("service attach failed, gds {}", gds));
        }
        Ok(Service {
            stream: s,
            handle,
            enc,
            dec,
        })
    }

    /// One `op_service_info` round trip: the raw answer bytes, for
    /// [`crate::decode`].
    pub fn info(&mut self, items: &[u8], buffer_length: i32) -> Result<Vec<u8>, String> {
        let mut w = Xdr::default();
        w.int(OP_SERVICE_INFO)
            .int(self.handle)
            .int(0) // incarnation
            .bytes(&crate::send_items_timeout(1))
            .bytes(&crate::receive_items(items))
            .int(buffer_length);
        write_all(&mut self.stream, &mut self.enc, &w.0)?;
        if read_int(&mut self.stream, &mut self.dec)? != OP_RESPONSE {
            return Err("expected op_response to op_service_info".into());
        }
        let (_, data, gds) = read_response(&mut self.stream, &mut self.dec)?;
        if gds != 0 {
            return Err(format!("service info failed, gds {}", gds));
        }
        Ok(data)
    }

    /// `op_service_start`: hand the service manager an action SPB. The
    /// action then runs on the SERVER and its text comes back through
    /// `isc_info_svc_line` / `isc_info_svc_to_eof` - so a client's job is
    /// two operations, start and poll, not one.
    pub fn start(&mut self, spb: &[u8]) -> Result<(), String> {
        let mut w = Xdr::default();
        w.int(OP_SERVICE_START)
            .int(self.handle)
            .int(0) // incarnation
            .bytes(spb);
        write_all(&mut self.stream, &mut self.enc, &w.0)?;
        if read_int(&mut self.stream, &mut self.dec)? != OP_RESPONSE {
            return Err("expected op_response to op_service_start".into());
        }
        let (_, _, gds) = read_response(&mut self.stream, &mut self.dec)?;
        if gds != 0 {
            return Err(format!("service start failed, gds {}", gds));
        }
        Ok(())
    }

    pub fn detach(&mut self) -> Result<(), String> {
        let mut w = Xdr::default();
        w.int(OP_SERVICE_DETACH).int(self.handle);
        write_all(&mut self.stream, &mut self.enc, &w.0)?;
        if read_int(&mut self.stream, &mut self.dec)? == OP_RESPONSE {
            read_response(&mut self.stream, &mut self.dec)?;
        }
        Ok(())
    }
}
