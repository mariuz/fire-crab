//! fcsvc - the Services-manager oracle interface.
//!
//!   fcsvc info <host> <port> <item>...
//!        attach to `service_mgr` on a live server, ask for the named
//!        items and print one decoded answer per line:
//!          `<item-name> <value>`
//!        Items are the fbsvcmgr names without the prefix:
//!          server_version implementation user_dbpath get_env
//!          get_env_lock get_env_msg version capabilities running
//!          stdin svr_db_info
//!        With `--raw` the response bytes are printed as hex instead -
//!        the form to diff byte-for-byte between two servers.
//!
//!   fcsvc info-buffer <host> <port> <bytes> <item>...
//!        the same, with an explicit response-buffer length: the way to
//!        see the ENGINE's truncation behaviour (isc_info_truncated) and
//!        compare it with ours.
//!
//!   fcsvc parse <grammar> <hex>
//!        parse a captured service buffer under one of the four
//!        grammars (`attach`, `send`, `receive`, `start`) and print its
//!        clumplets - `<tag> <name> <len> <text-or-number>`.
//!
//!   fcsvc answer <items-hex> <buffer-length>
//!        the SERVER side, offline: print what fire-crab would answer a
//!        given receive-items buffer, as hex. Feeding one server's
//!        request to both implementations is the byte-level differential.
//!
//! Credentials come from ISC_USER / ISC_PASSWORD (default
//! SYSDBA/masterkey), like the other fire-crab oracles.

use fire_crab_svc::{
    action, build_start_db_stats, decode, info, parse, spb, sts, Answer, Grammar, ServerInfo,
    SRP_A,
};

fn item_code(name: &str) -> Option<u8> {
    Some(match name {
        "server_version" => info::SERVER_VERSION,
        "implementation" => info::IMPLEMENTATION,
        "user_dbpath" => info::USER_DBPATH,
        "get_env" => info::GET_ENV,
        "get_env_lock" => info::GET_ENV_LOCK,
        "get_env_msg" => info::GET_ENV_MSG,
        "version" => info::VERSION,
        "capabilities" => info::CAPABILITIES,
        "running" => info::RUNNING,
        "stdin" => info::STDIN,
        "svr_db_info" => info::SVR_DB_INFO,
        "limbo_trans" => info::LIMBO_TRANS,
        "get_license" => info::GET_LICENSE,
        _ => return None,
    })
}

/// The reverse map, for printing answers by name.
fn item_name(code: u8) -> String {
    let n = match code {
        info::SERVER_VERSION => "server_version",
        info::IMPLEMENTATION => "implementation",
        info::USER_DBPATH => "user_dbpath",
        info::GET_ENV => "get_env",
        info::GET_ENV_LOCK => "get_env_lock",
        info::GET_ENV_MSG => "get_env_msg",
        info::VERSION => "version",
        info::CAPABILITIES => "capabilities",
        info::RUNNING => "running",
        info::STDIN => "stdin",
        info::SVR_DB_INFO => "svr_db_info",
        info::LIMBO_TRANS => "limbo_trans",
        info::TRUNCATED => "truncated",
        info::ERROR => "error",
        info::FLAG_END => "flag_end",
        info::END => "end",
        spb::NUM_ATT => "num_att",
        spb::NUM_DB => "num_db",
        spb::DBNAME => "dbname",
        _ => return format!("item_{}", code),
    };
    n.to_string()
}

fn spb_name(tag: u8) -> String {
    let n = match tag {
        spb::USER_NAME => "user_name",
        spb::PASSWORD => "password",
        spb::DUMMY_PACKET_INTERVAL => "dummy_packet_interval",
        spb::COMMAND_LINE => "command_line",
        spb::DBNAME => "dbname",
        spb::OPTIONS => "options",
        spb::PROCESS_ID => "process_id",
        spb::PROCESS_NAME => "process_name",
        spb::UTF8_FILENAME => "utf8_filename",
        spb::CLIENT_VERSION => "client_version",
        spb::EXPECTED_DB => "expected_db",
        spb::CONFIG => "config",
        action::BACKUP => "action_backup",
        _ => return format!("tag_{}", tag),
    };
    n.to_string()
}

fn hex_to_bytes(h: &str) -> Result<Vec<u8>, String> {
    if h.len() % 2 != 0 {
        return Err("hex must have an even number of digits".into());
    }
    (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

/// The values fire-crab's own service manager reports. Kept here (rather
/// than probed) because this command exists to show the ENCODING; the
/// values a live fcwire reports come from its own configuration.
fn demo_server() -> ServerInfo {
    ServerInfo {
        server_version: "LI-V6.0.0.2076 Firebird 6.0 fire-crab".into(),
        implementation: "Firebird/Linux/ARM64".into(),
        security_db: "/opt/firebird/security6.fdb".into(),
        root: "/opt/firebird/".into(),
        lock_dir: "/tmp/firebird/".into(),
        msg_dir: "/opt/firebird/".into(),
        service_version: 2,
        capabilities: 0,
        attachments: 0,
        databases: vec![],
    }
}

fn query(args: &[String], with_buffer: bool) -> Result<(), String> {
    let base = if with_buffer { 5 } else { 4 };
    let host = &args[2];
    let port: u16 = args[3].parse().map_err(|_| "bad port")?;
    let buffer_length: i32 = if with_buffer {
        args[4].parse().map_err(|_| "bad buffer length")?
    } else {
        16384
    };
    let mut raw = false;
    let mut items = Vec::new();
    for a in &args[base..] {
        if a == "--raw" {
            raw = true;
            continue;
        }
        items.push(item_code(a).ok_or_else(|| format!("unknown item {}", a))?);
    }
    if items.is_empty() {
        return Err("no items requested".into());
    }
    let user = std::env::var("ISC_USER").unwrap_or_else(|_| "SYSDBA".into());
    let password = std::env::var("ISC_PASSWORD").unwrap_or_else(|_| "masterkey".into());

    let mut svc = fire_crab_svc::client::Service::attach(host, port, &user, &password, SRP_A)?;
    let answer = svc.info(&items, buffer_length)?;
    let _ = svc.detach();

    if raw {
        println!("{}", hex(&answer));
        return Ok(());
    }
    for a in decode(&answer)? {
        match a {
            Answer::Text(t, v) => println!("{} {}", item_name(t), v),
            Answer::Number(t, v) => println!("{} {}", item_name(t), v),
            Answer::Marker(t) => println!("{}", item_name(t)),
        }
    }
    Ok(())
}

/// Drive a real service ACTION and poll its output stream. This is the
/// probe that pins the framing: `--raw` prints the response bytes of every
/// poll, so the engine's own line/EOF convention can be read off the wire
/// rather than guessed.
fn stats(args: &[String]) -> Result<(), String> {
    let host = &args[2];
    let port: u16 = args[3].parse().map_err(|_| "bad port")?;
    let db = &args[4];
    let raw = args.iter().any(|a| a == "--raw");
    let eof = args.iter().any(|a| a == "--eof");
    // The analyses are named explicitly. `hdr_pages` is the default only
    // when no other analysis is asked for, because the engine REFUSES the
    // combination: "option -h is incompatible with options -a, -d, -i, -r,
    // -schema, -s and -t" (gstat message 38 = gds 336920614), which the
    // service enforces server-side.
    let mut opts = 0u32;
    for (name, bit) in [
        ("hdr", sts::HDR_PAGES),
        ("data", sts::DATA_PAGES),
        ("idx", sts::IDX_PAGES),
        ("sys", sts::SYS_RELATIONS),
        ("versions", sts::RECORD_VERSIONS),
        ("encryption", sts::ENCRYPTION),
    ] {
        if args.iter().any(|a| a == name) {
            opts |= bit;
        }
    }
    if opts == 0 {
        opts = sts::HDR_PAGES;
    }
    let user = std::env::var("ISC_USER").unwrap_or_else(|_| "SYSDBA".into());
    let password = std::env::var("ISC_PASSWORD").unwrap_or_else(|_| "masterkey".into());
    let mut svc = fire_crab_svc::client::Service::attach(host, port, &user, &password, SRP_A)?;
    svc.start(&build_start_db_stats(db, opts))?;

    let item = if eof { info::TO_EOF } else { info::LINE };
    // poll until the stream says it is finished: an empty text item, the
    // engine's end-of-output convention
    for _ in 0..2000 {
        let answer = svc.info(&[item], 8192)?;
        if raw {
            println!("RAW {}", hex(&answer));
        }
        let decoded = decode(&answer)?;
        let mut done = false;
        // in --raw mode print ONLY the wire bytes: interleaving the decoded
        // text would put it on the same line and hide the framing a gate is
        // trying to compare
        for a in &decoded {
            match a {
                Answer::Text(_, t) if t.is_empty() => done = true,
                Answer::Text(_, t) => {
                    if !raw {
                        print!("{}", t);
                    }
                }
                Answer::Number(t, v) => {
                    if !raw {
                        println!("[{} {}]", item_name(*t), v)
                    }
                }
                Answer::Marker(m) => {
                    if *m == info::DATA_NOT_READY {
                        // the action is still running: keep polling
                    } else if !raw {
                        println!("[{}]", item_name(*m));
                    }
                }
            }
        }
        if done {
            break;
        }
    }
    let _ = svc.detach();
    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()).unwrap_or("") {
        "info" if args.len() >= 5 => query(&args, false)?,
        "stats" if args.len() >= 5 => stats(&args)?,
        "info-buffer" if args.len() >= 6 => query(&args, true)?,
        "parse" if args.len() == 4 => {
            let grammar = match args[2].as_str() {
                "attach" => Grammar::SpbAttach,
                "send" => Grammar::SpbSendItems,
                "receive" => Grammar::SpbReceiveItems,
                "start" => Grammar::SpbStart,
                g => return Err(format!("unknown grammar {}", g)),
            };
            let b = parse(grammar, &hex_to_bytes(&args[3])?)?;
            if let Some(v) = b.version {
                println!("VERSION {}", v);
            }
            for c in &b.items {
                let printable = c.data.iter().all(|b| *b >= 0x20 && *b < 0x7f);
                let val = if c.data.is_empty() {
                    String::new()
                } else if printable {
                    c.text()
                } else {
                    format!("{} (0x{})", c.number(), hex(&c.data))
                };
                println!("{} {} {} {}", c.tag, spb_name(c.tag), c.data.len(), val);
            }
        }
        "answer" if args.len() == 4 => {
            let items = hex_to_bytes(&args[2])?;
            let len: usize = args[3].parse().map_err(|_| "bad buffer length")?;
            match demo_server().answer(&items, len) {
                Ok(bytes) => println!("{}", hex(&bytes)),
                Err(e) => return Err(e.to_string()),
            }
        }
        _ => {
            eprintln!(
                "usage: fcsvc info <host> <port> <item>... [--raw]\n\
                 \x20      | info-buffer <host> <port> <bytes> <item>...\n\
                 \x20      | parse <attach|send|receive|start> <hex>\n\
                 \x20      | answer <items-hex> <buffer-length>\n\
                 \x20      | stats <host> <port> <db> [data idx sys versions] [--eof] [--raw]"
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
