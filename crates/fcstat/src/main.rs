//! fcstat - a gstat-like inspector built on fire-crab-ods.
//!
//! The differential-testing face of the conversion: everything fcstat
//! prints can be compared field-for-field against `gstat -h` and
//! against MON$ queries on the live C++ engine. `qa/diff-gstat.sh`
//! automates that comparison; `bench/compare.sh` times the two.
//!
//!   fcstat header <db.fdb>          - the header page, gstat -h style
//!   fcstat census <db.fdb>          - whole-file page-type census
//!   fcstat tip <db.fdb>             - transaction states from the first TIP
//!   fcstat records <db.fdb> <rel>   - record-version walk of one relation
//!   fcstat rows <db.fdb> <rel>      - decoded rows (tab-separated), via the
//!                                     RDB\$FORMATS bootstrap
//!   fcstat bench-census <db.fdb> <iterations>

use fire_crab_ods::{
    census, decode_record, relation_data_pages, relation_formats, DataPage, HeaderPage, TipPage,
    TxState,
};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = "usage: fcstat header|census|tip <db.fdb> | fcstat bench-census <db.fdb> <iters>";
    if args.len() < 3 {
        eprintln!("{}", usage);
        std::process::exit(2);
    }

    // header only needs page 0; the whole-file commands read it all.
    let data = match read_input(&args[1], &args[2]) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("fcstat: cannot read {}: {}", args[2], e);
            std::process::exit(1);
        }
    };

    match args[1].as_str() {
        "header" => header(&data),
        "census" => census_cmd(&data),
        "tip" => tip(&data),
        "rows" => {
            let rel: u16 = match args.get(3).and_then(|s| s.parse().ok()) {
                Some(r) => r,
                None => {
                    eprintln!("usage: fcstat rows <db.fdb> <relation-id>");
                    std::process::exit(2);
                }
            };
            rows(&data, rel);
        }
        "records" => {
            let rel: u16 = match args.get(3).and_then(|s| s.parse().ok()) {
                Some(r) => r,
                None => {
                    eprintln!("usage: fcstat records <db.fdb> <relation-id>");
                    std::process::exit(2);
                }
            };
            records(&data, rel);
        }
        "bench-census" => {
            let iters: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(10);
            bench_census(&data, iters);
        }
        _ => {
            eprintln!("{}", usage);
            std::process::exit(2);
        }
    }
}

fn read_input(cmd: &str, path: &str) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    if cmd == "header" {
        // one page is enough - and it keeps the tool honest in the
        // wall-clock comparison against gstat -h
        let mut f = std::fs::File::open(path)?;
        let mut buf = vec![0u8; 16384];
        let n = f.read(&mut buf)?;
        buf.truncate(n);
        Ok(buf)
    } else {
        std::fs::read(path)
    }
}

fn decode_header(data: &[u8]) -> HeaderPage {
    match HeaderPage::decode(data) {
        Some(h) => h,
        None => {
            eprintln!("fcstat: not a Firebird database (no header page)");
            std::process::exit(1);
        }
    }
}

fn header(data: &[u8]) {
    let h = decode_header(data);
    println!("Page size\t\t{}", h.page_size);
    println!(
        "ODS version\t\t{}.{}{}",
        h.ods_major(),
        h.ods_minor,
        if h.is_firebird() {
            ""
        } else {
            " (non-Firebird!)"
        }
    );
    println!("Oldest transaction\t{}", h.oldest_transaction);
    println!("Oldest active\t\t{}", h.oldest_active);
    println!("Oldest snapshot\t\t{}", h.oldest_snapshot);
    println!("Next transaction\t{}", h.next_transaction);
    println!("Next attachment ID\t{}", h.next_attachment_id);
    println!("Page buffers\t\t{}", h.page_buffers);
    println!("PAGES relation at\t{}", h.pages_page);
    println!("Database GUID:\t{}", h.guid_string());
}

fn census_cmd(data: &[u8]) {
    let c = match census(data) {
        Some(c) => c,
        None => {
            eprintln!("fcstat: cannot take census (bad page size?)");
            std::process::exit(1);
        }
    };
    println!(
        "{} pages of {} bytes ({} bytes)",
        c.total_pages,
        c.page_size,
        c.total_pages * c.page_size as u64
    );
    for (i, count) in c.counts.iter().enumerate() {
        if *count > 0 {
            let t = fire_crab_ods::PageType::from_byte(i as u8).unwrap();
            println!("  {:26} {}", t.name(), count);
        }
    }
    if c.unknown > 0 {
        println!("  {:26} {}", "UNKNOWN", c.unknown);
    }
}

fn tip(data: &[u8]) {
    let h = decode_header(data);
    let page_size = h.page_size as usize;

    // Find the first TIP by scanning (the header's clumplets would
    // name it; a scan is enough for the tool's purpose).
    let tip_page = data
        .chunks_exact(page_size)
        .find(|p| p[0] == 3)
        .and_then(TipPage::decode);
    let tip_page = match tip_page {
        Some(t) => t,
        None => {
            eprintln!("fcstat: no TIP found");
            std::process::exit(1);
        }
    };

    let mut counts = [0u64; 4];
    let interesting = (h.next_transaction as usize).min(TipPage::transactions_per_page(page_size));
    for id in 0..interesting {
        if let Some(s) = tip_page.state(id) {
            counts[s as usize] += 1;
        }
    }
    println!(
        "transactions 0..{} on first TIP (next chain page {}):",
        interesting, tip_page.next
    );
    for s in [
        TxState::Active,
        TxState::Limbo,
        TxState::Dead,
        TxState::Committed,
    ] {
        println!("  {:10} {}", s.name(), counts[s as usize]);
    }
}

/// Walk one relation's data pages via its pointer pages and classify
/// every record segment - the low-level mirror of SELECT COUNT(*).
/// On a database with no uncommitted work and no pending garbage
/// (e.g. freshly restored), `primary records` equals the row count.
fn records(data: &[u8], relation: u16) {
    let h = decode_header(data);
    let page_size = h.page_size as usize;

    let dp_numbers = relation_data_pages(data, page_size, relation);
    if dp_numbers.is_empty() {
        println!("relation {}: no pointer pages found", relation);
        return;
    }

    let mut pages = 0u64;
    let mut primary = 0u64;
    let mut back = 0u64;
    let mut fragments = 0u64;
    let mut blobs = 0u64;
    let mut deleted = 0u64;
    let mut unpack_errors = 0u64;

    for dp_no in dp_numbers {
        let start = dp_no as usize * page_size;
        let Some(page) = data.get(start..start + page_size) else {
            eprintln!("fcstat: data page {} beyond end of file", dp_no);
            continue;
        };
        let Some(dp) = DataPage::decode(page) else {
            eprintln!("fcstat: page {} is not a data page", dp_no);
            continue;
        };
        if dp.relation != relation {
            eprintln!("fcstat: page {} belongs to relation {}", dp_no, dp.relation);
            continue;
        }
        pages += 1;
        for r in dp.records() {
            use fire_crab_ods::data::flags;
            if r.flags & flags::BLOB != 0 {
                blobs += 1;
            } else if r.flags & flags::FRAGMENT != 0 {
                fragments += 1;
            } else if r.flags & flags::CHAIN != 0 {
                back += 1;
            } else if r.flags & flags::DELETED != 0 {
                deleted += 1;
            } else {
                primary += 1;
                // every complete primary must yield a record image
                if r.flags & flags::INCOMPLETE == 0 && r.image().is_none() {
                    unpack_errors += 1;
                }
            }
        }
    }

    println!("relation {}: {} data pages", relation, pages);
    println!("  primary records   {}", primary);
    println!("  back versions     {}", back);
    println!("  fragments         {}", fragments);
    println!("  blobs             {}", blobs);
    println!("  deleted stubs     {}", deleted);
    if unpack_errors > 0 {
        println!("  UNPACK ERRORS     {}", unpack_errors);
    }
}

/// Decode every primary record of a relation into column values,
/// using the format each record names in rhd_format, obtained through
/// the RDB\$FORMATS bootstrap (system format hardcoded, exactly like
/// the engine's own metadata bootstrap). Output: one tab-separated
/// line per row - the raw material for qa/diff-rows.sh.
fn rows(data: &[u8], relation: u16) {
    let h = decode_header(data);
    let page_size = h.page_size as usize;

    let formats = relation_formats(data, page_size, relation);
    if formats.is_empty() {
        eprintln!(
            "fcstat: no formats for relation {} in RDB$FORMATS (system relation?)",
            relation
        );
        std::process::exit(1);
    }

    for dp_no in relation_data_pages(data, page_size, relation) {
        let start = dp_no as usize * page_size;
        let Some(dp) = data
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else {
                eprintln!("fcstat: sqz error at page {} slot {}", dp_no, r.slot);
                continue;
            };
            let Some((_, descs)) = formats
                .iter()
                .find(|(n, _)| *n == r.format)
                .or_else(|| formats.iter().max_by_key(|(n, _)| *n))
            else {
                continue;
            };
            let row = decode_record(&image, descs);
            let line: Vec<String> = row.iter().map(|v| v.render()).collect();
            println!("{}", line.join("\t"));
        }
    }
}

fn bench_census(data: &[u8], iters: u32) {
    // warmup
    let c = census(data).expect("census failed");
    let start = Instant::now();
    for _ in 0..iters {
        std::hint::black_box(census(std::hint::black_box(data)));
    }
    let elapsed = start.elapsed();
    // the census reads ONE byte per page, so report pages/s - a
    // bytes-spanned MB/s figure would be flattering nonsense
    let pages = c.total_pages as f64 * iters as f64;
    println!(
        "census of {} pages x{}: {:.3} ms total, {:.1} M pages/s",
        c.total_pages,
        iters,
        elapsed.as_secs_f64() * 1000.0,
        pages / elapsed.as_secs_f64() / 1_000_000.0
    );
}
