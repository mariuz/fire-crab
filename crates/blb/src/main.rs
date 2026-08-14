//! fcblb - the blob-storage oracle interface.
//!
//!   fcblb scan   <db> <table> <column>
//!        one line per visible row: `<i> level=<l> segments=<n>
//!        maxseg=<m> length=<len>` (or `<i> <null>`) - the header
//!        fields the engine's own OCTET_LENGTH must agree with
//!   fcblb slices <db> <table> <column> <row-index>
//!        LEN / HEAD / MID / TAIL lines for content comparison
//!        against the engine's SUBSTRING answers (text blobs)
//!   fcblb write  <db> <table> <column> <content-file> <seg-size>
//!        create a blob from the file's bytes (segments of the given
//!        size), insert a record referencing it, print `RECNO <n>
//!        LEVEL <l>` - for the engine to read back. A segment size
//!        of 0 writes a STREAM blob (raw, unframed - the shape the
//!        API's BPB requests and SQL cannot produce)
//!
//! Row indexes are positions in the committed-visibility scan, the
//! same order a fresh table answers `SELECT` in.

use fire_crab_blb::{create_blob, read_blob};
use fire_crab_ods::{
    insert_record, relation_columns, relation_formats, resolve_relation, visible_rows,
    TipChain, Value,
};

const SLICE: usize = 64;

fn blob_ids(
    file: &fire_crab_ods::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Result<Vec<Option<(u16, u64)>>, String> {
    let rel = resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("no table {}", table))?;
    let formats = relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("table has no format")?;
    let cols = relation_columns(file, page_size, table);
    let col = cols
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(column))
        .ok_or_else(|| format!("no column {}", column))?;
    let tips = TipChain::read(file, page_size).ok_or("cannot read the TIP chain")?;
    Ok(visible_rows(file, page_size, rel, descs, &tips)
        .into_iter()
        .map(|r| match r.values.get(col.field_id as usize) {
            Some(Value::Blob(brel, brec)) => Some((*brel, *brec)),
            _ => None,
        })
        .collect())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("");
    match cmd {
        "scan" if args.len() == 5 => {
            let file = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
            let ps = fire_crab_ods::tra::page_size_of(&file).ok_or("bad page size")?;
            let file = fire_crab_ods::Image::from_bytes(&file, ps);
            for (i, id) in blob_ids(&file, ps, &args[3].to_ascii_uppercase(), &args[4])?
                .iter()
                .enumerate()
            {
                match id {
                    None => println!("{} <null>", i),
                    Some((brel, brec)) => {
                        let blob = read_blob(&file, ps, *brel, *brec)?;
                        println!(
                            "{} level={} segments={} maxseg={} length={}",
                            i,
                            blob.header.level,
                            blob.header.count,
                            blob.header.max_segment,
                            blob.header.length
                        );
                    }
                }
            }
        }
        "slices" if args.len() == 6 => {
            let file = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
            let ps = fire_crab_ods::tra::page_size_of(&file).ok_or("bad page size")?;
            let file = fire_crab_ods::Image::from_bytes(&file, ps);
            let idx: usize = args[5].parse().map_err(|_| "bad row index")?;
            let ids = blob_ids(&file, ps, &args[3].to_ascii_uppercase(), &args[4])?;
            let (brel, brec) = ids
                .get(idx)
                .ok_or("row index past the table")?
                .ok_or("row's blob is NULL")?;
            let content = read_blob(&file, ps, brel, brec)?.content();
            let text = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
            println!("LEN {}", content.len());
            println!("HEAD {}", text(&content[..SLICE.min(content.len())]));
            let mid = (content.len() / 2).min(content.len().saturating_sub(1));
            println!(
                "MID {}",
                text(&content[mid..(mid + SLICE).min(content.len())])
            );
            println!(
                "TAIL {}",
                text(&content[content.len().saturating_sub(SLICE)..])
            );
        }
        "write" if args.len() == 7 => {
            let file = std::fs::read(&args[2]).map_err(|e| e.to_string())?;
            let ps = fire_crab_ods::tra::page_size_of(&file).ok_or("bad page size")?;
            let mut file = fire_crab_ods::Image::from_bytes(&file, ps);
            let content = std::fs::read(&args[5]).map_err(|e| e.to_string())?;
            let seg: usize = args[6].parse().map_err(|_| "bad segment size")?;
            let table = args[3].to_ascii_uppercase();
            let rel = resolve_relation(&file, ps, &table)
                .ok_or_else(|| format!("no table {}", table))?;
            let formats = relation_formats(&file, ps, rel);
            let (format_no, descs) = formats
                .iter()
                .max_by_key(|(n, _)| *n)
                .ok_or("table has no format")?;
            let cols = relation_columns(&file, ps, &table);
            let col = cols
                .iter()
                .find(|c| c.name.eq_ignore_ascii_case(&args[4]))
                .ok_or_else(|| format!("no column {}", args[4]))?;
            let d = descs
                .get(col.field_id as usize)
                .ok_or("no descriptor for the column")?;
            // seg == 0 asks for a STREAM blob: raw content, no frames
            let recno = if seg == 0 {
                fire_crab_blb::create_stream_blob(&mut file, ps, rel, &content, 1, 4)?
            } else {
                let segments: Vec<Vec<u8>> =
                    content.chunks(seg).map(|c| c.to_vec()).collect();
                // sub_type 1 (TEXT), charset 4 (UTF8) - what an ascii
                // comparison workload wants
                create_blob(&mut file, ps, rel, &segments, 1, 4)?
            };
            let level = read_blob(&file, ps, rel, recno)?.header.level;
            // the referencing record: bid = u16 relation, u8 pad,
            // u8 recno-high, u32 recno-low (RecordNumber.h:63-71)
            let fmt_length = descs
                .iter()
                .map(|d| d.offset as usize + d.length as usize)
                .max()
                .unwrap_or(0);
            let mut image = vec![0u8; fmt_length];
            let at = d.offset as usize;
            image[at..at + 2].copy_from_slice(&rel.to_le_bytes());
            image[at + 2] = 0;
            image[at + 3] = (recno >> 32) as u8;
            image[at + 4..at + 8].copy_from_slice(&(recno as u32).to_le_bytes());
            insert_record(&mut file, ps, rel, *format_no, &image)?;
            std::fs::write(&args[2], file.to_bytes()).map_err(|e| e.to_string())?;
            println!("RECNO {} LEVEL {}", recno, level);
        }
        _ => {
            eprintln!(
                "usage: fcblb scan <db> <table> <col> | slices <db> <table> <col> <row> | write <db> <table> <col> <file> <segsize>"
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
