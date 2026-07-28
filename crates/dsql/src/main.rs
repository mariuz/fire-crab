//! fcdsql - compile a view-shaped SELECT to BLR and print it as hex,
//! the form `qa/dsql-view-blr.sh` compares against isql's OCTETS
//! rendering of the engine's own RDB$VIEW_BLR.

fn main() {
    let sql: String = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    if sql.trim().is_empty() {
        eprintln!("usage: fcdsql <select statement>");
        std::process::exit(2);
    }
    match fire_crab_dsql::compile_view_select_hex(&sql) {
        Some(hex) => println!("{}", hex),
        None => {
            println!("REFUSED");
            std::process::exit(1);
        }
    }
}
