//! fcpio - the platform-I/O oracle interface.
//!
//!   fcpio pages <db>
//!        `PAGE_SIZE <ps>` / `LENGTH <bytes>` / `PAGES <n>` / `WHOLE
//!        yes|no` - the PIO_get_number_of_pages arithmetic, to be compared
//!        with the engine's own `MON$DATABASE.MON$PAGES`
//!
//!   fcpio offset <page> <page-size>
//!        the seek_file law, as a number
//!
//!   fcpio read <db> <page>
//!        read exactly that page through the offset arithmetic and print
//!        `PAGE <n> OFFSET <o> TYPE <t> <name>` - the page TYPE is what
//!        makes this checkable against the engine, which records types for
//!        many pages in RDB$PAGES
//!
//!   fcpio header <db> [<bytes>]
//!        PIO_header: read the first bytes without knowing the page size,
//!        and print the page size found inside them
//!
//!   fcpio lock <db>
//!        `LOCK BUSY|FREE` - whether anyone holds the engine's flock on
//!        the file (what it reports as isc_already_opened)
//!
//!   fcpio extend-plan <file-pages> <ext-pages> <page-size>
//!   fcpio init-plan <start-page> <pages> <page-size>
//!   fcpio flags [ro] [fw] [nocache]
//!        the three arithmetic/flag laws as pure functions
//!
//!   fcpio zero-tail <db>
//!        how many trailing pages are entirely zeros - the visible trace
//!        of PIO_init_data
//!
//! Reads only. `fcpio` never writes to a database: the write path is
//! covered by unit tests on scratch files, because a gate that mutates a
//! live database file has no business doing so.

use fire_crab_pio::{
    extend_plan, hdr, header_attribute_names, init_data_plan, lock_probe, number_of_pages,
    page_offset, plan_for_header, LockState, OpenPlan, Pio,
};

fn page_type_name(t: u8) -> &'static str {
    // ods.h pag_types
    match t {
        0 => "undefined",
        1 => "header",
        2 => "pages (PIP)",
        3 => "transactions (TIP)",
        4 => "pointer",
        5 => "data",
        6 => "index root",
        7 => "index B-tree",
        8 => "blob",
        9 => "generators",
        10 => "SCN inventory",
        _ => "unknown",
    }
}

fn page_size_of(path: &str) -> Result<u32, String> {
    // the page size lives at offset 16 of the header page (ods.h), which
    // is why PIO_header exists: you cannot read a page until you have
    // read this
    let head = Pio::header(path, 32)?;
    let ps = u16::from_le_bytes([head[16], head[17]]) as u32;
    if ps == 0 {
        return Err("header page reports page size 0".into());
    }
    Ok(ps)
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let num = |i: usize| -> Result<u64, String> {
        args.get(i)
            .ok_or("missing argument")?
            .parse::<u64>()
            .map_err(|_| format!("not a number: {}", args[i]))
    };
    match args.get(1).map(|s| s.as_str()).unwrap_or("") {
        "pages" if args.len() == 3 => {
            let ps = page_size_of(&args[2])?;
            let len = std::fs::metadata(&args[2])
                .map_err(|e| e.to_string())?
                .len();
            println!("PAGE_SIZE {}", ps);
            println!("LENGTH {}", len);
            println!("PAGES {}", number_of_pages(len, ps));
            println!(
                "WHOLE {}",
                if fire_crab_pio::length_is_whole_pages(len, ps) {
                    "yes"
                } else {
                    "no"
                }
            );
        }
        "offset" if args.len() == 4 => {
            println!("OFFSET {}", page_offset(num(2)? as u32, num(3)? as u32));
        }
        "read" if args.len() == 4 => {
            let ps = page_size_of(&args[2])?;
            let pio = Pio::open(
                &args[2],
                ps,
                OpenPlan {
                    read_only: true,
                    ..Default::default()
                },
            )?;
            let page = num(3)? as u32;
            let data = pio.read_page(page)?;
            let t = data[0];
            println!(
                "PAGE {} OFFSET {} TYPE {} {}",
                page,
                page_offset(page, ps),
                t,
                page_type_name(t)
            );
        }
        "header" if args.len() >= 3 => {
            let len = if args.len() > 3 { num(3)? as usize } else { 32 };
            let head = Pio::header(&args[2], len)?;
            println!("READ {}", head.len());
            println!("TYPE {} {}", head[0], page_type_name(head[0]));
            if len >= 18 {
                println!("PAGE_SIZE {}", u16::from_le_bytes([head[16], head[17]]));
            }
        }
        // the header flags that decide the open mode, and the mode they
        // decide - the link between the ODS and this layer
        "attributes" if args.len() == 3 => {
            let head = Pio::header(&args[2], 32)?;
            let flags = u16::from_le_bytes([
                head[hdr::FLAGS_OFFSET],
                head[hdr::FLAGS_OFFSET + 1],
            ]);
            let names = header_attribute_names(flags);
            println!("FLAGS {}", flags);
            println!(
                "ATTRIBUTES {}",
                if names.is_empty() {
                    "-".to_string()
                } else {
                    names.join(",")
                }
            );
            let plan = plan_for_header(flags, false);
            println!("OPEN {}", plan.open_flag_names().join("|"));
        }
        "lock" if args.len() == 3 => {
            println!(
                "LOCK {}",
                match lock_probe(&args[2])? {
                    LockState::Free => "FREE",
                    LockState::Busy => "BUSY",
                }
            );
        }
        "extend-plan" if args.len() == 5 => {
            let (off, len) = extend_plan(num(2)? as u32, num(3)? as u32, num(4)? as u32);
            println!("OFFSET {}", off);
            println!("LENGTH {}", len);
        }
        "init-plan" if args.len() == 5 => {
            let (start, pages, calls) =
                init_data_plan(num(2)? as u32, num(3)? as u16, num(4)? as u32);
            println!("START {}", start);
            println!("PAGES {}", pages);
            println!("SYSCALLS {}", calls);
        }
        "flags" => {
            let has = |n: &str| args.iter().any(|a| a == n);
            let plan = OpenPlan {
                read_only: has("ro"),
                force_write: has("fw"),
                no_fs_cache: has("nocache"),
            };
            println!("OPEN {}", plan.open_flag_names().join("|"));
            println!("FIL_FLAGS {}", plan.fil_flags());
        }
        "zero-tail" if args.len() == 3 => {
            let ps = page_size_of(&args[2])?;
            let pio = Pio::open(
                &args[2],
                ps,
                OpenPlan {
                    read_only: true,
                    ..Default::default()
                },
            )?;
            let pages = pio.pages()?;
            let mut zero = 0u32;
            for p in (0..pages).rev() {
                if pio.read_page(p)?.iter().all(|b| *b == 0) {
                    zero += 1;
                } else {
                    break;
                }
            }
            println!("PAGES {}", pages);
            println!("ZERO_TAIL {}", zero);
        }
        _ => {
            eprintln!(
                "usage: fcpio pages <db> | offset <page> <page-size> | read <db> <page>\n\
                 \x20      | header <db> [bytes] | attributes <db> | lock <db> | zero-tail <db>\n\
                 \x20      | extend-plan <file-pages> <ext-pages> <page-size>\n\
                 \x20      | init-plan <start-page> <pages> <page-size>\n\
                 \x20      | flags [ro] [fw] [nocache]"
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
