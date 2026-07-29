//! fccch - the careful-write crash harness.
//!
//!   fccch crash-matrix <db.fdb> <outdir> <nrows> [naive]
//!
//! Performs a real multi-page operation on a copy of the database -
//! `nrows` inserts through `fire_crab_ods::dml`, sized to grow the
//! relation so header, TIP, PIP, pointer and data pages all change -
//! then sequences the changed pages through the fire-crab-cch cache
//! (careful order) or in the EXACT REVERSE (naive), and writes every
//! crash prefix to `<outdir>/crash-<k>.fdb`: the file as it would
//! exist had the process died after the k-th page write.
//!
//! Prints one `ORDER <k> <page> <type>` line per write and a final
//! `PREFIXES <n>` line. The gate then holds each prefix against the
//! ENGINE's own tools: gfix -v -full must find nothing, and isql must
//! read exactly the rows committed before the operation began.

use fire_crab_cch::{careful_plan, changed_pages, crash_prefix, page_type};
use fire_crab_ods::{relation_columns, relation_formats, resolve_relation};

fn type_name(t: u8) -> &'static str {
    match t {
        1 => "header",
        2 => "pip",
        3 => "tip",
        4 => "pointer",
        5 => "data",
        6 => "index-root",
        7 => "btree",
        8 => "blob",
        9 => "generator",
        _ => "?",
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 || args[1] != "crash-matrix" {
        eprintln!("usage: fccch crash-matrix <db.fdb> <outdir> <nrows> [naive]");
        std::process::exit(2);
    }
    let naive = args.get(5).map(|a| a == "naive").unwrap_or(false);
    let run = || -> Result<(), String> {
        let before = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
        let page_size =
            fire_crab_ods::tra::page_size_of(&before).ok_or("cannot read the page size")?;
        let nrows: usize = args[4].parse().map_err(|_| "nrows is not a number")?;

        // the operation: nrows inserts into T (one CHAR column), on a
        // scratch copy - fire-crab's own write path, whole-file mode
        let rel = resolve_relation(&before, page_size, "T").ok_or("no table T")?;
        let formats = relation_formats(&before, page_size, rel);
        let (format_no, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("T has no format")?;
        let cols = relation_columns(&before, page_size, "T");
        let text_col = cols.first().ok_or("T has no columns")?;
        let d = descs
            .get(text_col.field_id as usize)
            .ok_or("no descriptor for the text column")?;
        let fmt_length = descs
            .iter()
            .map(|d| d.offset as usize + d.length as usize)
            .max()
            .unwrap_or(0);
        let mut after = before.clone();
        for i in 0..nrows {
            let mut image = vec![0u8; fmt_length];
            let text = format!("row-{:06}", i);
            let dst =
                &mut image[d.offset as usize..d.offset as usize + d.length as usize];
            for b in dst.iter_mut() {
                *b = b' ';
            }
            dst[..text.len()].copy_from_slice(text.as_bytes());
            fire_crab_ods::insert_record(&mut after, page_size, rel, *format_no, &image)?;
        }

        // the write order: the precedence-graph flush, or its reverse
        let plan = careful_plan(&before, &after, page_size);
        let mut order: Vec<u32> = plan.write_order().to_vec();
        {
            let changed = changed_pages(&before, &after, page_size);
            if order.len() != changed.len() {
                return Err("flush did not write every changed page".into());
            }
            let mut types = std::collections::BTreeSet::new();
            for &p in &changed {
                types.insert(page_type(&after, page_size, p));
            }
            if types.len() < 4 {
                return Err(format!(
                    "workload too small - only {} page types changed; raise nrows",
                    types.len()
                ));
            }
        }
        if naive {
            order.reverse();
        }

        std::fs::create_dir_all(&args[3]).map_err(|e| e.to_string())?;
        for (k, &p) in order.iter().enumerate() {
            println!("ORDER {} {} {}", k, p, type_name(page_type(&after, page_size, p)));
        }
        for k in 0..=order.len() {
            let img = crash_prefix(&before, &after, page_size, &order, k);
            let path = format!("{}/crash-{:03}.fdb", args[3], k);
            std::fs::write(&path, img).map_err(|e| e.to_string())?;
        }
        println!("PREFIXES {}", order.len() + 1);
        Ok(())
    };
    if let Err(e) = run() {
        eprintln!("fccch: {}", e);
        std::process::exit(1);
    }
}
