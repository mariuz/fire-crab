//! fcdsql - compile a view-shaped SELECT to BLR and print it as hex,
//! the form `qa/dsql-view-blr.sh` compares against isql's OCTETS
//! rendering of the engine's own RDB$VIEW_BLR.

fn main() {
    let sql: String = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    if sql.trim().is_empty() {
        eprintln!("usage: fcdsql <select statement>");
        std::process::exit(2);
    }
    let is_proc = sql.trim_start().to_uppercase().starts_with("CREATE PROCEDURE");
    let compiled = if is_proc {
        fire_crab_dsql::compile_procedure_hex(&sql)
    } else {
        fire_crab_dsql::compile_view_select_hex(&sql)
    };
    match compiled {
        Some(hex) => println!("{}", hex),
        None => {
            println!("REFUSED");
            std::process::exit(1);
        }
    }
}
