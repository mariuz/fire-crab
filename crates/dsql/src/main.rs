//! fcdsql - compile a view-shaped SELECT to BLR and print it as hex,
//! the form `qa/dsql-view-blr.sh` compares against isql's OCTETS
//! rendering of the engine's own RDB$VIEW_BLR.

/// `FCDSQL_CATALOG`: the tables a statement may read, with their column
/// types, so the typed shapes (a CASE / NULLIF / FILTER / IN list over a
/// column) compile the way the server compiles them with the database's
/// catalog at hand. `T(ID INTEGER, S VARCHAR(20) CHARACTER SET UTF8);
/// SRC(ID INTEGER)` - relations split on `;`, columns on top-level commas.
fn catalog_from_env() {
    let Ok(cat) = std::env::var("FCDSQL_CATALOG") else { return };
    let mut entries = Vec::new();
    for rel in cat.split(';').map(str::trim).filter(|r| !r.is_empty()) {
        let Some((name, rest)) = rel.split_once('(') else { continue };
        let cols_text = rest.trim_end().strip_suffix(')').unwrap_or(rest.trim_end());
        let mut cols = Vec::new();
        let mut depth = 0i32;
        let mut cur = String::new();
        let mut parts: Vec<String> = Vec::new();
        for ch in cols_text.chars() {
            match ch {
                '(' => { depth += 1; cur.push(ch); }
                ')' => { depth -= 1; cur.push(ch); }
                ',' if depth == 0 => parts.push(std::mem::take(&mut cur)),
                _ => cur.push(ch),
            }
        }
        if !cur.trim().is_empty() { parts.push(cur); }
        for part in parts {
            let part = part.trim();
            let Some((col, ty)) = part.split_once(' ') else { continue };
            cols.push((col.trim().to_ascii_uppercase(), fire_crab_dsql::type_spec_of(ty.trim())));
        }
        entries.push((name.trim().to_ascii_uppercase(), cols));
    }
    fire_crab_dsql::set_catalog_typed(entries);
}

fn main() {
    catalog_from_env();
    let sql: String = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    if sql.trim().is_empty() {
        eprintln!("usage: fcdsql <select statement>");
        std::process::exit(2);
    }
    let upper = sql.trim_start().to_uppercase();
    let compiled = if upper.starts_with("CREATE PROCEDURE") {
        fire_crab_dsql::compile_procedure_hex(&sql)
    } else if upper.starts_with("CREATE TRIGGER") {
        fire_crab_dsql::compile_trigger_hex(&sql)
    } else if upper.starts_with("DEFAULT") {
        fire_crab_dsql::compile_default_hex(&sql)
    } else if upper.starts_with("COMPUTED") {
        fire_crab_dsql::compile_computed_hex(&sql)
    } else if upper.starts_with("CHECK") {
        // a domain's CHECK speaks of VALUE; a table's names columns
        if upper.contains("VALUE") {
            fire_crab_dsql::compile_validation_hex(&sql)
        } else {
            fire_crab_dsql::compile_check_hex(&sql)
        }
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
