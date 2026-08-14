//! fcauth - the authentication oracle interface.
//!
//!   fcauth verifier <user> <password> <salt-hex>
//!        the user-manager computation: prints
//!          `SALT_TEXT <t>` - the salt as it travels (minimal hex text)
//!          `X <hex>`       - x = SHA1(salt_text | SHA1(user:password))
//!          `V <hex>`       - v = g^x mod N, the bytes CREATE USER stores
//!        `<salt-hex>` is the STORED salt (32 raw bytes, hex-encoded) -
//!        exactly what `SELECT PLG$SALT FROM plg$srp.plg$srp` prints.
//!
//!   fcauth vectors [<algo>]
//!        deterministic intermediate values (a = 07*128, b = 09*128,
//!        salt = "5A"*32 text, SYSDBA/masterkey) for cross-checking
//!        against another implementation: A, B, U, X, S, K, M. `<algo>`
//!        is Srp256 (default) or Srp.
//!
//!   fcauth login <host> <port> <db> <user> <password> [<algo>]
//!        a REAL SRP handshake against a live Firebird server: op_connect
//!        presenting A, op_cond_accept/op_accept_data carrying salt and
//!        B, op_cont_auth carrying our proof M. Prints
//!          `AUTH OK plugin=<p> proto=<v> key=<hex>`   (server accepted)
//!          `AUTH FAIL gds=<n>`                        (server refused)
//!        and nothing else - this is the auth exchange alone, with no
//!        attachment, so a success means the SERVER'S OWN SRP plugin
//!        recomputed our proof from its stored verifier and agreed.
//!
//! Deliberately NOT here: password prompting or reading. The oracle is
//! driven by a gate with test credentials; it is not a login tool.

use fire_crab_auth::{
    bytes_to_hex_upper, client_start, compute_verifier, hex_to_bytes, salt_text, user_hash, Algo,
};
use std::io::{Read, Write};
use std::net::TcpStream;

const OP_CONNECT: i32 = 1;
const OP_ACCEPT: i32 = 3;
const OP_REJECT: i32 = 4;
const OP_ATTACH: i32 = 19;
const OP_ACCEPT_DATA: i32 = 94;
const OP_COND_ACCEPT: i32 = 98;
const OP_RESPONSE: i32 = 9;
const OP_CONT_AUTH: i32 = 92;
const CONNECT_VERSION3: i32 = 3;
const ARCH_GENERIC: i32 = 1;
const PTYPE_BATCH_SEND: i32 = 3;

// p_cnct_user_id tags (protocol.h)
const CNCT_USER: u8 = 1;
const CNCT_HOST: u8 = 4;
const CNCT_USER_VERIFICATION: u8 = 6;
const CNCT_SPECIFIC_DATA: u8 = 7;
const CNCT_PLUGIN_NAME: u8 = 8;
const CNCT_LOGIN: u8 = 9;
const CNCT_PLUGIN_LIST: u8 = 10;
const CNCT_CLIENT_CRYPT: u8 = 11;

/// XDR: 4-byte big-endian ints, byte strings padded to 4.
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

fn read_int(s: &mut TcpStream) -> Result<i32, String> {
    let mut b = [0u8; 4];
    s.read_exact(&mut b).map_err(|e| e.to_string())?;
    Ok(i32::from_be_bytes(b))
}

fn read_bytes(s: &mut TcpStream) -> Result<Vec<u8>, String> {
    let n = read_int(s)? as usize;
    let mut data = vec![0u8; n];
    s.read_exact(&mut data).map_err(|e| e.to_string())?;
    let mut pad = vec![0u8; (4 - n % 4) % 4];
    s.read_exact(&mut pad).map_err(|e| e.to_string())?;
    Ok(data)
}

/// The p_cnct_user_id block, with the plugin we intend to use.
fn user_id_block(login: &str, algo: Algo, a_hex: &str) -> Vec<u8> {
    let mut p = Vec::new();
    let mut tlv = |tag: u8, data: &[u8]| {
        p.push(tag);
        p.push(data.len() as u8);
        p.extend_from_slice(data);
    };
    tlv(CNCT_LOGIN, login.as_bytes());
    tlv(CNCT_PLUGIN_NAME, algo.plugin_name().as_bytes());
    // Offer ONLY the plugin we are testing. A list would let the server
    // pick the other one, and then a passing gate would prove nothing
    // about the variant we asked for.
    tlv(CNCT_PLUGIN_LIST, algo.plugin_name().as_bytes());
    for (i, chunk) in a_hex.as_bytes().chunks(254).enumerate() {
        p.push(CNCT_SPECIFIC_DATA);
        p.push((chunk.len() + 1) as u8);
        p.push(i as u8);
        p.extend_from_slice(chunk);
    }
    // wire-crypt stance ENABLED: a default (WireCrypt=Enabled) server
    // refuses a client that declares it disabled
    p.extend_from_slice(&[CNCT_CLIENT_CRYPT, 4, 1, 0, 0, 0]);
    p.extend_from_slice(&[CNCT_USER, login.len() as u8]);
    p.extend_from_slice(login.as_bytes());
    p.extend_from_slice(&[CNCT_HOST, 9]);
    p.extend_from_slice(b"localhost");
    p.extend_from_slice(&[CNCT_USER_VERIFICATION, 0]);
    p
}

/// Read an op_response's status vector, returning the first gds code (0
/// when the response is clean).
fn response_gds(s: &mut TcpStream) -> Result<i32, String> {
    read_int(s)?; // object handle
    read_int(s)?; // blob id (2 ints)
    read_int(s)?;
    read_bytes(s)?; // response data
    let mut first = 0;
    loop {
        let t = read_int(s)?;
        if t == 0 {
            break;
        } else if t == 1 || t == 4 || t == 19 {
            let c = read_int(s)?;
            if t == 1 && first == 0 {
                first = c;
            }
        } else {
            read_bytes(s)?;
        }
    }
    Ok(first)
}

/// The SRP exchange alone, against a live server.
fn login(
    host: &str,
    port: u16,
    db: &str,
    user: &str,
    password: &str,
    algo: Algo,
) -> Result<(), String> {
    let user = user.to_uppercase(); // unquoted identifiers are uppercased
    // A fixed private key `a` keeps the oracle reproducible. That is safe
    // for a test oracle and wrong for a client: `a` must be random per
    // connection, or a recorded handshake replays.
    let client = client_start(&[0x31u8; 128]);

    let uid = user_id_block(&user, algo, &client.a_hex);
    let mut w = Xdr::default();
    w.int(OP_CONNECT)
        .int(OP_ATTACH)
        .int(CONNECT_VERSION3)
        .int(ARCH_GENERIC)
        .str(db)
        .int(1)
        .bytes(&uid);
    // one offer: protocol 13, the first version that speaks SRP
    w.int(13 | 0x8000)
        .int(ARCH_GENERIC)
        .int(PTYPE_BATCH_SEND)
        .int(PTYPE_BATCH_SEND)
        .int(2);

    let mut s = TcpStream::connect((host, port)).map_err(|e| e.to_string())?;
    s.set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .map_err(|e| e.to_string())?;
    s.write_all(&w.0).map_err(|e| e.to_string())?;

    let op = read_int(&mut s)?;
    if op == OP_REJECT {
        return Err("op_reject: the server refused the connection".into());
    }
    if op == OP_RESPONSE {
        // The server answered the CONNECT itself with an error, which is
        // what happens when no offered auth plugin is one it serves: a
        // default firebird.conf has `AuthServer = Srp256` only, so
        // offering just `Srp` never reaches a proof. Report the engine's
        // own code rather than guessing at a reason.
        println!("CONNECT REFUSED gds={}", response_gds(&mut s)?);
        return Ok(());
    }
    if op != OP_ACCEPT_DATA && op != OP_COND_ACCEPT && op != OP_ACCEPT {
        return Err(format!("unexpected op {} in answer to op_connect", op));
    }
    let proto = read_int(&mut s)? & 0x7fff;
    read_int(&mut s)?; // arch
    read_int(&mut s)?; // ptype
    if op == OP_ACCEPT {
        // no auth data: the server would want a cleartext password, which
        // means SRP was not negotiated at all
        return Err("plain op_accept: the server did not negotiate SRP".into());
    }
    let data = read_bytes(&mut s)?; // salt + B
    let plugin = String::from_utf8_lossy(&read_bytes(&mut s)?).into_owned();
    read_int(&mut s)?; // authenticated flag
    read_bytes(&mut s)?; // p_acpt_keys

    if plugin != algo.plugin_name() {
        return Err(format!(
            "server chose plugin {} but we offered only {}",
            plugin,
            algo.plugin_name()
        ));
    }
    // salt and B are 2-byte-LE-length-prefixed inside the auth data
    if data.len() < 4 {
        return Err("auth data too short for salt + B".into());
    }
    let salt_len = u16::from_le_bytes([data[0], data[1]]) as usize;
    let salt = &data[2..2 + salt_len];
    let key_len = u16::from_le_bytes([data[2 + salt_len], data[3 + salt_len]]) as usize;
    let b_hex = String::from_utf8_lossy(&data[4 + salt_len..4 + salt_len + key_len]).into_owned();

    let proof = client.proof_with(algo, &user, password, salt, &b_hex);
    let mut w = Xdr::default();
    w.int(OP_CONT_AUTH)
        .str(&proof.m_hex)
        .str(algo.plugin_name())
        .str(algo.plugin_name())
        .str("");
    s.write_all(&w.0).map_err(|e| e.to_string())?;

    if read_int(&mut s)? != OP_RESPONSE {
        return Err("expected op_response to op_cont_auth".into());
    }
    let gds = response_gds(&mut s)?;
    // the salt the SERVER sent is the hex text of its stored salt, so a
    // 63-character salt here is the one-in-sixteen case
    println!("SALT_LEN {}", salt_len);
    if gds == 0 {
        println!(
            "AUTH OK plugin={} proto={} key={}",
            plugin,
            proto,
            bytes_to_hex_upper(&proof.session_key)
        );
    } else {
        println!("AUTH FAIL gds={}", gds);
    }
    Ok(())
}

/// The stored pair for a user, as bytes (salt, verifier).
fn stored_pair(sec_db: &str, user: &str) -> Result<(Vec<u8>, Vec<u8>), String> {
    let file = std::fs::read(sec_db).map_err(|e| e.to_string())?;
    let ps = fire_crab_ods::tra::page_size_of(&file).ok_or("bad page size")?;
    let image = fire_crab_ods::Image::from_bytes(&file, ps);
    let rel = fire_crab_ods::resolve_relation(&image, ps, "PLG$SRP")
        .ok_or("no PLG$SRP relation - is this a security database?")?;
    let formats = fire_crab_ods::relation_formats(&image, ps, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("PLG$SRP has no format")?;
    let cols = fire_crab_ods::relation_columns(&image, ps, "PLG$SRP");
    let field = |name: &str| -> Result<usize, String> {
        cols.iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
            .map(|c| c.field_id as usize)
            .ok_or_else(|| format!("no column {}", name))
    };
    let (fname, fver, fsalt) = (
        field("PLG$USER_NAME")?,
        field("PLG$VERIFIER")?,
        field("PLG$SALT")?,
    );
    let tips = fire_crab_ods::TipChain::read(&image, ps).ok_or("cannot read the TIP chain")?;
    for row in fire_crab_ods::visible_rows(&image, ps, rel, descs, &tips) {
        let name = match row.values.get(fname) {
            Some(fire_crab_ods::Value::Text(t)) => t.trim().to_string(),
            _ => continue,
        };
        if !name.eq_ignore_ascii_case(user) {
            continue;
        }
        let raw = |i: usize| -> Result<Vec<u8>, String> {
            fire_crab_ods::field_bytes(&row.image, &descs[i], i)
                .ok_or_else(|| format!("{}: field {} is NULL", name, i))
        };
        return Ok((raw(fsalt)?, raw(fver)?));
    }
    Err(format!("no user {} in PLG$SRP", user))
}

/// Prove that the engine's STORED verifier is the one this password
/// produces, by running the whole exchange locally: a client that knows
/// the password against a server half that holds only the stored bytes -
/// which is precisely the split the engine has.
fn check(sec_db: &str, user: &str, password: &str, algo: Algo) -> Result<(), String> {
    let (salt, verifier) = stored_pair(sec_db, user)?;
    let text = salt_text(&salt);
    let ours = compute_verifier(user, password, text.as_bytes());
    println!("SALT_LEN {}", text.len());
    println!(
        "RECOMPUTED {}",
        if ours == verifier { "MATCH" } else { "DIFFER" }
    );
    let server = fire_crab_auth::SrpVerifier::from_stored(user, text.as_bytes(), &verifier);
    let client = client_start(&[0x31u8; 128]);
    let (b_priv, b_hex) = server.server_public(&[0x57u8; 128]);
    let proof = client.proof_with(algo, user, password, text.as_bytes(), &b_hex);
    match server.verify_with(algo, &client.a_hex, &b_priv, &b_hex, &proof.m_hex) {
        Some(k) => println!("PROOF ACCEPTED key={}", bytes_to_hex_upper(&k)),
        None => println!("PROOF REJECTED"),
    }
    Ok(())
}

/// Read one user's stored SRP pair out of the ENGINE's own security
/// database - with fire-crab's ODS decoder, straight from the file.
///
/// Going through the file rather than SQL is not a shortcut, it is the
/// only route: `databases.conf` ships the `security.db` alias with
/// `RemoteAccess = false`, so no client may attach to the security
/// database over TCP, and a direct attach collides with the running
/// server ("Database already opened with engine instance"). fire-crab
/// reads pages, so it needs no attachment at all.
///
/// `PLG$VERIFIER` and `PLG$SALT` are `CHARACTER SET OCTETS`, so they must
/// be read as BYTES ([`fire_crab_ods::field_bytes`]); decoding them as
/// text replaces every byte above 0x7F and the verifier stops being a
/// number.
fn stored(sec_db: &str, user: &str) -> Result<(), String> {
    let (salt, verifier) = stored_pair(sec_db, user)?;
    println!("USER {}", user);
    println!("SALT {}", bytes_to_hex_upper(&salt));
    println!("VERIFIER {}", bytes_to_hex_upper(&verifier));
    Ok(())
}

fn vectors(algo: Algo) {
    let salt = salt_text(&[0x5Au8; 32]);
    let client = client_start(&[7u8; 128]);
    let verifier = fire_crab_auth::SrpVerifier::new("SYSDBA", "masterkey", salt.as_bytes());
    let (b_priv, b_hex) = verifier.server_public(&[9u8; 128]);
    let proof = client.proof_with(algo, "SYSDBA", "masterkey", salt.as_bytes(), &b_hex);
    println!("ALGO {}", algo.plugin_name());
    println!("SALT {}", salt);
    println!("A {}", client.a_hex);
    println!("B {}", b_hex);
    println!("U {}", proof.scramble_hex);
    println!("X {}", proof.x_hex);
    println!("S {}", proof.secret_hex);
    println!("K {}", bytes_to_hex_upper(&proof.session_key));
    println!("M {}", proof.m_hex);
    // the server half must reach the same K without the password
    println!(
        "SERVER_K {}",
        bytes_to_hex_upper(&verifier.session_key(&client.a_hex, &b_priv, &b_hex))
    );
    println!("V {}", bytes_to_hex_upper(&verifier.verifier_bytes()));
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let algo_at = |i: usize| -> Result<Algo, String> {
        match args.get(i) {
            None => Ok(Algo::Srp256),
            Some(a) => Algo::from_plugin_name(a).ok_or_else(|| format!("unknown plugin {}", a)),
        }
    };
    match args.get(1).map(|s| s.as_str()).unwrap_or("") {
        "verifier" if args.len() == 5 => {
            let salt_bytes = hex_to_bytes(&args[4]);
            let text = salt_text(&salt_bytes);
            let x = user_hash(&args[2], &args[3], text.as_bytes());
            println!("SALT_TEXT {}", text);
            println!("X {}", bytes_to_hex_upper(&x.to_bytes_be()));
            println!(
                "V {}",
                bytes_to_hex_upper(&compute_verifier(&args[2], &args[3], text.as_bytes()))
            );
        }
        // the same, but hashing the salt the WRONG ways - so a gate can
        // show that only the minimal-hex-text form matches the engine
        "verifier-padded" if args.len() == 5 => {
            let salt_bytes = hex_to_bytes(&args[4]);
            let padded = bytes_to_hex_upper(&salt_bytes);
            println!(
                "V_PADDED {}",
                bytes_to_hex_upper(&compute_verifier(&args[2], &args[3], padded.as_bytes()))
            );
            println!(
                "V_RAW {}",
                bytes_to_hex_upper(&compute_verifier(&args[2], &args[3], &salt_bytes))
            );
        }
        "stored" if args.len() == 4 => stored(&args[2], &args[3].to_ascii_uppercase())?,
        "check" if args.len() >= 5 => {
            check(&args[2], &args[3].to_ascii_uppercase(), &args[4], algo_at(5)?)?
        }
        "vectors" => vectors(algo_at(2)?),
        "login" if args.len() >= 7 => {
            let port: u16 = args[3].parse().map_err(|_| "bad port")?;
            login(
                &args[2],
                port,
                &args[4],
                &args[5],
                &args[6],
                algo_at(7)?,
            )?;
        }
        _ => {
            eprintln!(
                "usage: fcauth verifier <user> <pass> <salt-hex> | verifier-padded <user> <pass> <salt-hex>\n\
                 \x20      | stored <security-db-file> <user>\n\
                 \x20      | check <security-db-file> <user> <pass> [Srp|Srp256]\n\
                 \x20      | vectors [Srp|Srp256] | login <host> <port> <db> <user> <pass> [Srp|Srp256]"
            );
            std::process::exit(2);
        }
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("REFUSED: {}", e);
        std::process::exit(1);
    }
}
