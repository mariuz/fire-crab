//! fcwire - the fire-crab wire-protocol client tool.
//!   fcwire negotiate <host:port> <db-path>
use fire_crab_wire::{login, negotiate};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 || (args[1] != "negotiate" && args[1] != "login" && args[1] != "query") {
        eprintln!(
            "usage: fcwire negotiate|login|query <host:port> <db-path> [user] [password] [sql]"
        );
        std::process::exit(2);
    }
    let (host, port) = match args[2].rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().unwrap_or(3050)),
        None => (args[2].clone(), 3050u16),
    };
    let mut rnd = vec![0u8; 128];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut rnd);
    }
    if args[1] == "query" {
        let user = args.get(4).cloned().unwrap_or_else(|| "SYSDBA".into());
        let pass = args.get(5).cloned().unwrap_or_else(|| "masterkey".into());
        let sql = args
            .get(6)
            .cloned()
            .unwrap_or_else(|| "SELECT COUNT(*) FROM RDB$RELATIONS".into());
        match login(&host, port, &args[3], &user, &pass, &rnd, &[13]) {
            Ok(mut att) => match att.query_i64(&sql) {
                Ok(v) => {
                    println!("VALUE {}", v);
                    let _ = att.detach();
                }
                Err(e) => {
                    eprintln!("fcwire query: {}", e);
                    let _ = att.detach();
                    std::process::exit(1);
                }
            },
            Err(e) => {
                eprintln!("fcwire login: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }
    if args[1] == "login" {
        let user = args.get(4).cloned().unwrap_or_else(|| "SYSDBA".into());
        let pass = args.get(5).cloned().unwrap_or_else(|| "masterkey".into());
        match login(
            &host,
            port,
            &args[3],
            &user,
            &pass,
            &rnd,
            &[13, 16, 17, 18, 19, 20],
        ) {
            Ok(mut att) => {
                println!(
                    "logged in: protocol {}, attachment handle {}",
                    att.protocol, att.handle
                );
                println!("HANDLE {}", att.handle);
                if let Some(secs) = args.get(6).and_then(|s| s.parse::<u64>().ok()) {
                    std::thread::sleep(std::time::Duration::from_secs(secs));
                }
                let _ = att.detach();
                println!("detached.");
            }
            Err(e) => {
                eprintln!("fcwire login: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }
    // 128 bytes of "SRP key A" placeholder from /dev/urandom, rendered
    // as hex text (the real key is g^a mod N; negotiation does not need
    // a valid one, only well-formed specific-data)
    let mut a = vec![0u8; 128];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut a);
    }
    let a_hex: String = a.iter().map(|b| format!("{:02X}", b)).collect();

    // optional 4th arg: comma-separated protocol versions to offer
    let offered: Vec<i32> = args
        .get(4)
        .map(|s| s.split(',').filter_map(|x| x.trim().parse().ok()).collect())
        .unwrap_or_else(|| vec![13, 16, 17, 18, 19, 20]); // FB3 .. FB6
    match negotiate(&host, port, &args[3], "SYSDBA", &offered, a_hex.as_bytes()) {
        Ok(n) => {
            let name = match n.opcode {
                3 => "op_accept",
                94 => "op_accept_data",
                98 => "op_cond_accept",
                o => {
                    println!("opcode {}", o);
                    "?"
                }
            };
            println!(
                "negotiated: {} protocol {} arch {} ptype {}",
                name, n.version, n.architecture, n.packet_type
            );
            println!("PROTOCOL {}", n.version);
        }
        Err(e) => {
            eprintln!("fcwire: {}", e);
            std::process::exit(1);
        }
    }
}
