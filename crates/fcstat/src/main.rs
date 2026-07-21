//! fcstat - a gstat-like inspector built on fire-crab-ods.
//!
//! The differential-testing face of the conversion: everything fcstat
//! prints can be compared field-for-field against `gstat -h` and
//! against MON$ queries on the live C++ engine. `qa/diff-gstat.sh`
//! automates that comparison; `bench/compare.sh` times the two.
//!
//!   fcstat header <db.fdb>     - the header page, gstat -h style
//!   fcstat census <db.fdb>     - whole-file page-type census
//!   fcstat tip <db.fdb>        - transaction states from the first TIP
//!   fcstat bench-census <db.fdb> <iterations>

use fire_crab_ods::{census, HeaderPage, TipPage, TxState};
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
