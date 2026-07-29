//! fccch - the careful-write crash harness.
//!
//!   fccch crash-matrix <db.fdb> <outdir> <workload> <n> [naive]
//!
//! Workloads: `insert` (n rows into T - header, TIP, PIP, pointer
//! and data pages all change), `indexed` (the same inserts PLUS
//! B-tree maintenance on T's index - btree pages join the ensemble),
//! `delete` (delete n committed rows - version-chain stubs, TIP and
//! header; the commit flip still goes LAST, so every interrupted
//! prefix answers the ORIGINAL rows).
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
use fire_crab_ods::{
    delete_records, relation_columns, relation_formats, resolve_relation, Value,
};

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
    if args.len() < 6 || args[1] != "crash-matrix" {
        eprintln!("usage: fccch crash-matrix <db.fdb> <outdir> <workload> <n> [naive]");
        std::process::exit(2);
    }
    let naive = args.get(6).map(|a| a == "naive").unwrap_or(false);
    let run = || -> Result<(), String> {
        let before = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
        let page_size =
            fire_crab_ods::tra::page_size_of(&before).ok_or("cannot read the page size")?;
        let workload = args[4].as_str();
        let n: usize = args[5].parse().map_err(|_| "n is not a number")?;

        let rel = resolve_relation(&before, page_size, "T").ok_or("no table T")?;
        let formats = relation_formats(&before, page_size, rel);
        let (format_no, descs) = formats
            .iter()
            .max_by_key(|(no, _)| *no)
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
        match workload {
            "insert" | "indexed" => {
                // n inserts through fire-crab's own write path; the
                // indexed workload maintains T's B-tree per row,
                // exactly as the wire server's insert does
                let index = if workload == "indexed" {
                    let irt =
                        fire_crab_ods::btr::find_index_root(&before, page_size, rel)
                            .ok_or("indexed workload needs an index root")?;
                    let e = irt
                        .live_entries()
                        .next()
                        .ok_or("indexed workload needs a live index")?;
                    let (segs, _flags) = fire_crab_ods::btw::index_segments(
                        &before,
                        page_size,
                        rel,
                        e.id,
                        e.key_count as usize,
                    )
                    .ok_or("cannot read the index segments")?;
                    Some((e.id, segs))
                } else {
                    None
                };
                let recs = fire_crab_ods::format::max_recs_per_dp(page_size);
                for i in 0..n {
                    let mut image = vec![0u8; fmt_length];
                    let text = format!("row-{:06}", i);
                    let dst = &mut image
                        [d.offset as usize..d.offset as usize + d.length as usize];
                    for b in dst.iter_mut() {
                        *b = b' ';
                    }
                    dst[..text.len()].copy_from_slice(text.as_bytes());
                    let out = fire_crab_ods::insert_record(
                        &mut after, page_size, rel, *format_no, &image,
                    )?;
                    if let Some((id, segs)) = &index {
                        let seq = u32::from_le_bytes(
                            after[out.page_no as usize * page_size + 16
                                ..out.page_no as usize * page_size + 20]
                                .try_into()
                                .unwrap(),
                        ) as u64;
                        let recno = seq * recs + out.slot as u64;
                        let values = fire_crab_ods::decode_record(&image, descs);
                        let null = Value::Null;
                        let ksegs: Vec<fire_crab_ods::btw::KeySeg<'_>> = segs
                            .iter()
                            .map(|(fid, itype)| fire_crab_ods::btw::KeySeg {
                                itype: *itype,
                                value: values.get(*fid as usize).unwrap_or(&null),
                                scale: descs
                                    .get(*fid as usize)
                                    .map(|d| d.scale)
                                    .unwrap_or(0),
                            })
                            .collect();
                        let (key, _all_null) =
                            fire_crab_ods::btw::build_index_key(&ksegs, false)
                                .ok_or("cannot build the index key")?;
                        fire_crab_ods::btw::insert_index_entry(
                            &mut after, page_size, rel, *id, &key, recno, false,
                        )?;
                    }
                }
            }
            "delete" => {
                // delete the first n committed rows - version-chain
                // stubs over the same pages, TIP and header move
                let recs = fire_crab_ods::format::max_recs_per_dp(page_size);
                let pages =
                    fire_crab_ods::relation_data_pages(&before, page_size, rel);
                let tips = fire_crab_ods::TipChain::read(&before, page_size)
                    .ok_or("no TIP chain")?;
                let targets: Vec<(u32, u16)> =
                    fire_crab_ods::visible_rows(&before, page_size, rel, descs, &tips)
                        .into_iter()
                        .take(n)
                        .map(|vr| {
                            let dp = pages[(vr.recno / recs) as usize];
                            (dp, (vr.recno % recs) as u16)
                        })
                        .collect();
                if targets.len() < n {
                    return Err("not enough rows to delete".into());
                }
                delete_records(&mut after, page_size, rel, &targets)?;
            }
            other => return Err(format!("unknown workload {}", other)),
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
            // deletes legitimately touch only header, data and TIP -
            // version stubs allocate no pages
            let min_types = if workload == "delete" { 3 } else { 4 };
            if types.len() < min_types {
                return Err(format!(
                    "workload too small - only {} page types changed; raise n",
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
