//! fcexe - execute a stored procedure's BLR against a database file.
//!
//!   fcexe <db.fdb> <PROCNAME> [arg ...]
//!
//! Reads `RDB$PROCEDURE_BLR` from the catalog (the same bytes
//! fire-crab-dsql matches from the SQL text), runs the request through
//! the fire-crab-exe looper, and prints one pipe-joined line per row
//! the procedure SUSPENDs - the shape `SELECT * FROM <proc>` answers
//! on the engine, for the differential gate to compare.

use fire_crab_exe::{execute, parse};
use fire_crab_ods::{
    decode_record, read_blob_content, relation_columns, relation_data_pages,
    resolve_relation, system_relation_formats, DataPage, Value,
};

fn page_size_of(file: &[u8]) -> Option<usize> {
    fire_crab_ods::tra::page_size_of(file)
}

/// The catalog read: RDB$PROCEDURES' committed primary row named
/// `name`, its RDB$PROCEDURE_BLR blob.
fn procedure_blr(file: &[u8], page_size: usize, name: &str) -> Result<Vec<u8>, String> {
    let rel = resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES format")?;
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("empty format list")?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| {
        cols.iter()
            .find(|c| c.name == n)
            .map(|c| c.field_id as usize)
    };
    let name_f = fid("RDB$PROCEDURE_NAME").ok_or("no RDB$PROCEDURE_NAME column")?;
    let blr_f = fid("RDB$PROCEDURE_BLR").ok_or("no RDB$PROCEDURE_BLR column")?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
            let values = decode_record(&image, descs);
            let Some(Value::Text(t)) = values.get(name_f) else {
                continue;
            };
            if t.trim_end() != name {
                continue;
            }
            return match values.get(blr_f) {
                Some(Value::Blob(brel, brec)) => {
                    read_blob_content(file, page_size, *brel, *brec)
                        .ok_or_else(|| "cannot read the BLR blob".into())
                }
                _ => Err(format!("procedure {} has no BLR", name)),
            };
        }
    }
    Err(format!("procedure {} not found", name))
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
