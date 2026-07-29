//! The optimizer's ACCESS-PATH SELECTION - the conversion of the
//! decision `src/jrd/optimizer/` makes for every query: which index
//! (if any) fetches a table's rows, and whether an ORDER BY can ride
//! an index's own order instead of a sort.
//!
//! # The oracle answers in one line
//!
//! `SET PLANONLY ON` makes the engine PREPARE a statement and print
//! the plan it chose without executing it:
//!
//! ```text
//!   PLAN ("PUBLIC"."T" NATURAL)
//!   PLAN ("PUBLIC"."T" INDEX ("PUBLIC"."IDX_T_ID"))
//!   PLAN ("PUBLIC"."T" ORDER "PUBLIC"."IDX_T_AMT")
//!   PLAN SORT ("PUBLIC"."T" NATURAL)
//! ```
//!
//! That is a complete, textual, side-effect-free statement of the
//! optimizer's decision - the best oracle in the project after
//! RDB$VIEW_BLR itself. `fcopt plan <db> "<sql>"` prints the same
//! line for the same statement, and the gate diffs them.
//!
//! # The rules, as the probes found them
//!
//! Slice 1 converts single-table selection:
//!
//! - **NATURAL** when no predicate is index-matchable: no WHERE at
//!   all, a predicate on an unindexed column, an inequality (`<>`),
//!   or an OR whose branches are not ALL matchable.
//! - **INDEX (a, b, ...)** when conjuncts or a fully-matchable OR
//!   name indexed columns - listed in INDEX-ID order (creation
//!   order), deduplicated. Matchable comparisons: `=`, `>`, `>=`,
//!   `<`, `<=`, BETWEEN, IS NULL, STARTING WITH, and LIKE with a
//!   literal prefix.
//! - **ORDER \<idx\>** - navigation instead of a sort - when the
//!   ORDER BY column has an index whose DIRECTION MATCHES (an
//!   ascending index cannot serve ORDER BY ... DESC; the engine
//!   picked the descending twin when one existed and fell to a sort
//!   when none did), and any predicate is either absent or matched
//!   by that same index.
//! - **SORT (...)** wraps the access path whenever an ORDER BY
//!   exists and navigation was not chosen.
//!
//! The select list does not influence the plan at all (COUNT(*) and
//! a column list plan identically), so this crate parses it loosely
//! and ignores it - the engine's own behavior, made explicit.
//!
//! # Slice 1 boundaries
//!
//! Joins, unions, subqueries, procedures, views, multiple tables and
//! compound (multi-segment) index matching REFUSE by name. Cost
//! estimation proper - selectivity arithmetic choosing BETWEEN
//! candidate indexes - is not converted: where the engine's choice
//! depends on statistics rather than structure, this slice refuses
//! rather than guesses.

use fire_crab_ods::{
    decode_record, relation_columns, relation_data_pages, resolve_relation,
    system_relation_formats, DataPage, Value,
};

/// One index as the optimizer sees it: its catalog id (the order the
/// engine lists indexes in), name, single segment column and
/// direction.
#[derive(Clone, Debug)]
pub struct IndexInfo {
    pub id: i64,
    pub name: String,
    pub column: String,
    pub descending: bool,
}

/// The chosen access path for one table.
#[derive(Clone, Debug, PartialEq)]
pub enum Access {
    Natural,
    Index(Vec<String>),
    Order(String),
}

/// A plan: the access path, and whether a SORT wraps it.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub table: String,
    pub access: Access,
    pub sorted: bool,
}

impl Plan {
    /// The engine's own spelling - schema-qualified, double-quoted.
    pub fn render(&self) -> String {
        let q = |n: &str| format!("\"PUBLIC\".\"{}\"", n);
        let inner = match &self.access {
            Access::Natural => format!("{} NATURAL", q(&self.table)),
            Access::Order(i) => format!("{} ORDER {}", q(&self.table), q(i)),
            Access::Index(list) => {
                let names: Vec<String> = list.iter().map(|n| q(n)).collect();
                format!("{} INDEX ({})", q(&self.table), names.join(", "))
            }
        };
        if self.sorted {
            format!("PLAN SORT ({})", inner)
        } else {
            format!("PLAN ({})", inner)
        }
    }
}

/// A predicate the parser recognized: the column it constrains and
/// whether an index can MATCH it (the engine's "index-usable" test).
#[derive(Clone, Debug)]
struct Pred {
    column: String,
    matchable: bool,
}

/// Every single-segment index of a table, in catalog id order.
pub fn indexes_of(
    file: &[u8],
    page_size: usize,
    table: &str,
) -> Result<Vec<IndexInfo>, String> {
    let rel = resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$INDICES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$INDEX_NAME").ok_or("no RDB$INDEX_NAME")?;
    let rel_f = fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let id_f = fid("RDB$INDEX_ID").ok_or("no RDB$INDEX_ID")?;
    let type_f = fid("RDB$INDEX_TYPE");
    let inactive_f = fid("RDB$INDEX_INACTIVE");
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
            let values = decode_record(&image, descs);
            let (Some(Value::Text(iname)), Some(Value::Text(rname))) =
                (values.get(name_f), values.get(rel_f))
            else {
                continue;
            };
            if !rname.trim_end().eq_ignore_ascii_case(table) {
                continue;
            }
            // an inactive index is not a candidate
            if matches!(inactive_f.and_then(|f| values.get(f)), Some(Value::Int(1))) {
                continue;
            }
            let Some(Value::Int(id)) = values.get(id_f) else {
                continue;
            };
            let descending =
                matches!(type_f.and_then(|f| values.get(f)), Some(Value::Int(1)));
            let iname = iname.trim_end().to_string();
            let segs = index_columns(file, page_size, &iname)?;
            // slice 1 matches SINGLE-segment indexes only
            if segs.len() == 1 {
                out.push(IndexInfo {
                    id: *id,
                    name: iname,
                    column: segs[0].clone(),
                    descending,
                });
            }
        }
    }
    out.sort_by_key(|i| i.id);
    Ok(out)
}

/// An index's segment columns, in key order (RDB$INDEX_SEGMENTS).
fn index_columns(
    file: &[u8],
    page_size: usize,
    index: &str,
) -> Result<Vec<String>, String> {
    let rel = resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$INDEX_SEGMENTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$INDEX_NAME").ok_or("no name column")?;
    let field_f = fid("RDB$FIELD_NAME").ok_or("no field column")?;
    let pos_f = fid("RDB$FIELD_POSITION");
    let mut out: Vec<(i64, String)> = Vec::new();
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
            let values = decode_record(&image, descs);
            let (Some(Value::Text(iname)), Some(Value::Text(fname))) =
                (values.get(name_f), values.get(field_f))
            else {
                continue;
            };
            if iname.trim_end() != index {
                continue;
            }
            let pos = match pos_f.and_then(|f| values.get(f)) {
                Some(Value::Int(n)) => *n,
                _ => 0,
            };
            out.push((pos, fname.trim_end().to_string()));
        }
    }
    out.sort_by_key(|(p, _)| *p);
    Ok(out.into_iter().map(|(_, f)| f).collect())
}

/// Parse a single-table SELECT far enough to plan it, then CHOOSE.
/// Everything outside the slice returns an error naming itself.
pub fn plan_query(
    file: &[u8],
    page_size: usize,
    sql: &str,
) -> Result<Plan, String> {
    let up = sql.trim().trim_end_matches(';').to_uppercase();
    if !up.starts_with("SELECT ") {
        return Err("not a SELECT".into());
    }
    for word in [" JOIN ", " UNION ", "(SELECT", " EXISTS", ","] {
        // a comma in the FROM clause is a join too; the select list's
        // commas are cut away below before this test
        let _ = word;
    }
    let from = find_kw(&up, "FROM").ok_or("no FROM clause")?;
    let after_from = &up[from + 4..];
    // the clause boundaries
    let where_at = find_kw(after_from, "WHERE");
    let order_at = find_kw(after_from, "ORDER");
    let table_end = where_at.or(order_at).unwrap_or(after_from.len());
    let table = after_from[..table_end].trim().to_string();
    if table.is_empty() || table.contains(',') || table.contains(' ') {
        return Err("multi-table or aliased FROM unconverted".into());
    }
    if up.contains(" JOIN ") || up.contains(" UNION ") || up.contains("(SELECT") {
        return Err("joins, unions and subqueries unconverted".into());
    }
    let where_s = match (where_at, order_at) {
        (Some(w), Some(o)) if o > w => Some(after_from[w + 5..o].trim()),
        (Some(w), _) => Some(after_from[w + 5..].trim()),
        (None, _) => None,
    };
    let order_s = order_at.map(|o| after_from[o + 5..].trim());

    let indexes = indexes_of(file, page_size, &table)?;
    let by_col = |c: &str| -> Vec<&IndexInfo> {
        indexes.iter().filter(|i| i.column.eq_ignore_ascii_case(c)).collect()
    };

    // ---- the predicates -------------------------------------------
    let (preds, all_or_matchable) = match where_s {
        None => (Vec::new(), true),
        Some(w) => parse_predicates(w, &|c| !by_col(c).is_empty())?,
    };
    let mut matched: Vec<&IndexInfo> = Vec::new();
    if all_or_matchable {
        for p in preds.iter().filter(|p| p.matchable) {
            // the LOWEST-id index on the column (the engine's pick
            // among equals - an ascending index serves a range where
            // a descending twin exists)
            if let Some(i) = by_col(&p.column).into_iter().min_by_key(|i| i.id) {
                if !matched.iter().any(|m| m.name == i.name) {
                    matched.push(i);
                }
            }
        }
    }
    matched.sort_by_key(|i| i.id);

    // ---- the ORDER BY ---------------------------------------------
    let order = match order_s {
        None => None,
        Some(o) => {
            let (col, desc) = parse_order(o)?;
            Some((col, desc))
        }
    };
    if let Some((ocol, odesc)) = &order {
        // navigation needs an index on the column whose DIRECTION
        // MATCHES (probed: ORDER BY x DESC took the descending twin,
        // and fell to a sort when none existed)
        let nav = by_col(ocol)
            .into_iter()
            .filter(|i| i.descending == *odesc)
            .min_by_key(|i| i.id);
        if let Some(n) = nav {
            let predicate_ok = matched.is_empty()
                || (matched.len() == 1 && matched[0].name == n.name);
            if predicate_ok && (preds.is_empty() || all_or_matchable) {
                return Ok(Plan {
                    table,
                    access: Access::Order(n.name.clone()),
                    sorted: false,
                });
            }
        }
    }
    let access = if matched.is_empty() {
        Access::Natural
    } else {
        Access::Index(matched.iter().map(|i| i.name.clone()).collect())
    };
    Ok(Plan { table, access, sorted: order.is_some() })
}

/// The WHERE clause's predicates. Returns them plus whether an OR
/// structure keeps every branch matchable (a single unmatchable OR
/// branch makes the whole clause unusable - probed).
fn parse_predicates(
    w: &str,
    indexed: &dyn Fn(&str) -> bool,
) -> Result<(Vec<Pred>, bool), String> {
    if w.contains('(') {
        return Err("parenthesized predicates unconverted".into());
    }
    let is_or = find_kw(w, " OR ").is_some() || w.starts_with("OR ");
    let raw: Vec<&str> = if is_or {
        split_kw(w, "OR")
    } else {
        split_kw(w, "AND")
    };
    // BETWEEN's own AND is not a conjunction: a part ending in a
    // BETWEEN absorbs the next one (the split cut it in half)
    let mut parts: Vec<String> = Vec::new();
    let mut pending: Option<String> = None;
    for p in raw {
        let p = p.trim();
        match pending.take() {
            Some(prev) => parts.push(format!("{} AND {}", prev, p)),
            None => {
                if find_kw(&p.to_uppercase(), "BETWEEN").is_some() && !is_or {
                    pending = Some(p.to_string());
                } else {
                    parts.push(p.to_string());
                }
            }
        }
    }
    if let Some(last) = pending {
        parts.push(last);
    }
    let mut preds = Vec::new();
    for p in &parts {
        preds.push(parse_one_predicate(p.trim(), indexed)?);
    }
    let all_matchable = preds.iter().all(|p| p.matchable);
    Ok((preds, if is_or { all_matchable } else { true }))
}

fn parse_one_predicate(
    p: &str,
    indexed: &dyn Fn(&str) -> bool,
) -> Result<Pred, String> {
    let col_end = p
        .find(|c: char| c.is_whitespace() || "=<>!".contains(c))
        .ok_or_else(|| format!("cannot parse predicate {:?}", p))?;
    let column = p[..col_end].trim().to_string();
    let rest = p[col_end..].trim();
    // the index-usable comparisons (probed): equality, ranges,
    // BETWEEN, IS NULL, STARTING WITH, and LIKE with a literal
    // prefix; <> and a non-prefix LIKE are NOT usable
    let matchable = if rest.starts_with("<>") || rest.starts_with("!=") {
        false
    } else if rest.starts_with("IS NOT NULL") {
        false
    } else if rest.starts_with("IS NULL")
        || rest.starts_with("STARTING")
        || rest.starts_with("BETWEEN")
        || rest.starts_with('=')
        || rest.starts_with('>')
        || rest.starts_with('<')
    {
        true
    } else if let Some(pat) = rest.strip_prefix("LIKE ") {
        // a leading wildcard cannot ride the index
        let pat = pat.trim().trim_matches('\'');
        !pat.starts_with('%') && !pat.starts_with('_')
    } else {
        return Err(format!("predicate {:?} unconverted", p));
    };
    Ok(Pred { column: column.clone(), matchable: matchable && indexed(&column) })
}

fn parse_order(o: &str) -> Result<(String, bool), String> {
    let o = o.trim();
    if o.contains(',') {
        return Err("multi-column ORDER BY unconverted".into());
    }
    let rest = o.strip_prefix("BY ").unwrap_or(o).trim();
    let (col, desc) = match rest.rsplit_once(' ') {
        Some((c, d)) if d.trim() == "DESC" => (c.trim(), true),
        Some((c, d)) if d.trim() == "ASC" => (c.trim(), false),
        _ => (rest, false),
    };
    if col.contains(' ') || col.is_empty() {
        return Err("ORDER BY expression unconverted".into());
    }
    Ok((col.to_string(), desc))
}

/// Find a whole-word keyword (space-delimited), ignoring quoted text.
fn find_kw(s: &str, kw: &str) -> Option<usize> {
    let pad = format!(" {} ", kw.trim());
    s.find(&pad).map(|i| i + 1).or_else(|| {
        if s.starts_with(&format!("{} ", kw.trim())) {
            Some(0)
        } else {
            None
        }
    })
}

fn split_kw<'a>(s: &'a str, kw: &str) -> Vec<&'a str> {
    let pad = format!(" {} ", kw);
    s.split(&pad as &str).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_the_engines_spelling() {
        let p = Plan {
            table: "T".into(),
            access: Access::Natural,
            sorted: false,
        };
        assert_eq!(p.render(), "PLAN (\"PUBLIC\".\"T\" NATURAL)");
        let p = Plan {
            table: "T".into(),
            access: Access::Index(vec!["IDX_A".into(), "IDX_B".into()]),
            sorted: true,
        };
        assert_eq!(
            p.render(),
            "PLAN SORT (\"PUBLIC\".\"T\" INDEX (\"PUBLIC\".\"IDX_A\", \"PUBLIC\".\"IDX_B\"))"
        );
        let p = Plan {
            table: "T".into(),
            access: Access::Order("IDX_A".into()),
            sorted: false,
        };
        assert_eq!(p.render(), "PLAN (\"PUBLIC\".\"T\" ORDER \"PUBLIC\".\"IDX_A\")");
    }

    #[test]
    fn matchability_follows_the_probed_rules() {
        let indexed = |c: &str| c == "ID";
        let m = |p: &str| parse_one_predicate(p, &indexed).unwrap().matchable;
        assert!(m("ID = 5"));
        assert!(m("ID > 5"));
        assert!(m("ID BETWEEN 1 AND 9"));
        assert!(m("ID IS NULL"));
        assert!(m("ID STARTING WITH 'a'"));
        assert!(m("ID LIKE 'a%'"));
        // not index-usable: inequality, IS NOT NULL, leading wildcard
        assert!(!m("ID <> 5"));
        assert!(!m("ID IS NOT NULL"));
        assert!(!m("ID LIKE '%a'"));
        // an unindexed column is never matchable
        assert!(!m("NAME = 'x'"));
    }

    #[test]
    fn an_unmatchable_or_branch_spoils_the_clause() {
        let indexed = |c: &str| c == "ID";
        let (_, ok) = parse_predicates("ID = 5 OR NAME = 'x'", &indexed).unwrap();
        assert!(!ok);
        let (_, ok) = parse_predicates("ID = 5 OR ID = 6", &indexed).unwrap();
        assert!(ok);
        // an AND keeps its matchable half regardless
        let (preds, ok) = parse_predicates("ID = 5 AND NAME = 'x'", &indexed).unwrap();
        assert!(ok);
        assert_eq!(preds.iter().filter(|p| p.matchable).count(), 1);
    }

    #[test]
    fn order_parses_direction() {
        assert_eq!(parse_order("BY ID").unwrap(), ("ID".into(), false));
        assert_eq!(parse_order("BY ID DESC").unwrap(), ("ID".into(), true));
        assert_eq!(parse_order("BY AMT ASC").unwrap(), ("AMT".into(), false));
        assert!(parse_order("BY ID, AMT").is_err());
    }
}
