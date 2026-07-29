//! fcexe - execute a stored procedure's BLR against a database file.
//!
//!   fcexe <db.fdb> <PROCNAME> [arg ...]
//!
//! Reads `RDB$PROCEDURE_BLR` from the catalog (the same bytes
//! fire-crab-dsql matches from the SQL text), runs the request through
//! the fire-crab-exe looper, and prints one pipe-joined line per row
//! the procedure SUSPENDs - the shape `SELECT * FROM <proc>` answers
//! on the engine, for the differential gate to compare.

use fire_crab_exe::{execute, parse, procedure_blr};
use fire_crab_ods::Value;

fn page_size_of(file: &[u8]) -> Option<usize> {
    fire_crab_ods::tra::page_size_of(file)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: fcexe <db.fdb> <PROCNAME> [arg ...]");
        std::process::exit(2);
    }
    let file = match std::fs::read(&args[1]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("fcexe: {}: {}", args[1], e);
            std::process::exit(1);
        }
    };
    let run = || -> Result<(), String> {
        let page_size = page_size_of(&file).ok_or("cannot read the page size")?;
        let name = args[2].trim().to_ascii_uppercase();
        let blr = procedure_blr(&file, page_size, &name)?;
        let request = parse(&blr)?;
        // message 1 is the output contract: (value, null-flag) pairs
        // and the trailing EOF short
        let out_slots = request
            .messages
            .iter()
            .find(|(n, _)| *n == 1)
            .map(|(_, s)| s.len())
            .ok_or("request has no output message")?;
        if out_slots < 3 || out_slots % 2 == 0 {
            return Err("output message is not (value, null)* + EOF".into());
        }
        let outputs = (out_slots - 1) / 2;
        for (msg, buf) in execute(&file, page_size, &request, &args[3..])? {
            if msg != 1 {
                continue;
            }
            // the EOF slot: 1 = a row, 0 = end of the cursor
            match buf.last() {
                Some(Value::Int(1)) => {}
                _ => continue,
            }
            let mut cells = Vec::new();
            for i in 0..outputs {
                let null = matches!(buf.get(2 * i + 1), Some(Value::Int(f)) if *f != 0);
                if null {
                    cells.push("<null>".to_string());
                } else {
                    let v = buf.get(2 * i).cloned().unwrap_or(Value::Null);
                    cells.push(match v {
                        Value::Null => "<null>".to_string(),
                        Value::Text(t) => t.trim_end_matches(' ').to_string(),
                        other => other.render(),
                    });
                }
            }
            println!("{}", cells.join("|"));
        }
        Ok(())
    };
    if let Err(e) = run() {
        eprintln!("REFUSED: {}", e);
        std::process::exit(1);
    }
}
