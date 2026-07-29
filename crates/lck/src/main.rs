//! fclck - the lock-table oracle interface.
//!
//!   fclck compat <A> <B>          COMPATIBLE or CONFLICT for two modes
//!                                 (none null SR PR SW PW EX)
//!   fclck matrix                  print the full 7x7 table
//!   fclck pin-source <lock.cpp>   re-parse the ENGINE's compatibility
//!                                 table from source and diff it
//!                                 cell-by-cell against this crate's -
//!                                 exit 1 on any difference
//!
//! `compat` answers the live gate's question: while a transaction
//! holds a table reservation in mode A, does a NO WAIT reservation in
//! mode B succeed (COMPATIBLE) or fail with "lock conflict on no wait
//! transaction" (CONFLICT)? `pin-source` keeps the transcription
//! honest against the vendored engine.

use fire_crab_lck::{compatible, parse_engine_matrix, Mode, COMPATIBILITY};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = || {
        eprintln!("usage: fclck compat <A> <B> | matrix | pin-source <lock.cpp>");
        std::process::exit(2);
    };
    match args.get(1).map(|s| s.as_str()) {
        Some("compat") if args.len() == 4 => {
            let a = Mode::from_short(&args[2]).unwrap_or_else(|| {
                eprintln!("unknown mode {}", args[2]);
                std::process::exit(2);
            });
            let b = Mode::from_short(&args[3]).unwrap_or_else(|| {
                eprintln!("unknown mode {}", args[3]);
                std::process::exit(2);
            });
            println!("{}", if compatible(a, b) { "COMPATIBLE" } else { "CONFLICT" });
        }
        Some("matrix") if args.len() == 2 => {
            print!("      ");
            for m in Mode::ALL {
                print!("{:>5}", m.short());
            }
            println!();
            for a in Mode::ALL {
                print!("{:>5} ", a.short());
                for b in Mode::ALL {
                    print!("{:>5}", if compatible(a, b) { "+" } else { "-" });
                }
                println!();
            }
        }
        Some("pin-source") if args.len() == 3 => {
            let src = std::fs::read_to_string(&args[2]).unwrap_or_else(|e| {
                eprintln!("fclck: {}: {}", args[2], e);
                std::process::exit(1);
            });
            match parse_engine_matrix(&src) {
                Ok(engine) if engine == COMPATIBILITY => {
                    println!("OK matrix matches the engine source cell-for-cell");
                }
                Ok(engine) => {
                    for a in Mode::ALL {
                        for b in Mode::ALL {
                            let (i, j) = (a as usize, b as usize);
                            if engine[i][j] != COMPATIBILITY[i][j] {
                                println!(
                                    "DIFF {}/{}: engine={} fclck={}",
                                    a.short(),
                                    b.short(),
                                    engine[i][j],
                                    COMPATIBILITY[i][j]
                                );
                            }
                        }
                    }
                    std::process::exit(1);
                }
                Err(e) => {
                    eprintln!("fclck: {}", e);
                    std::process::exit(1);
                }
            }
        }
        _ => usage(),
    }
}
