//! fcopt - the optimizer's decision, printed like the engine's.
//!
//!   fcopt plan <db.fdb> "<sql>"
//!
//! Prints the PLAN line `SET PLANONLY ON` would print for the same
//! statement, or `REFUSED: <reason>` outside the converted surface.

use fire_crab_opt::plan_query;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 || args[1] != "plan" {
        eprintln!("usage: fcopt plan <db.fdb> \"<sql>\"");
        std::process::exit(2);
    }
    let file = match std::fs::read(&args[2]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("fcopt: {}: {}", args[2], e);
            std::process::exit(1);
        }
    };
    let run = || -> Result<(), String> {
        let ps = fire_crab_ods::tra::page_size_of(&file).ok_or("bad page size")?;
        println!("{}", plan_query(&file, ps, &args[3])?.render());
        Ok(())
    };
    if let Err(e) = run() {
        eprintln!("REFUSED: {}", e);
        std::process::exit(1);
    }
}
