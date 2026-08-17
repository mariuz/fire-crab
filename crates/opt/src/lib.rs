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
//! Unions, subqueries, procedures, views and outer joins inside
//! chains refuse by name.
//!
//! # A unique lookup costs a FIXED four, and that decides join orders
//!
//! `Retrieval::getInversion` prices an indexed retrieval two ways
//! (Retrieval.cpp:371-384):
//!
//! ```text
//! if (unique)  cost = DEFAULT_INDEX_COST * indexes + 1;      // a fixed 4
//! else         cost = index scan + cardinality * selectivity;
//! ```
//!
//! The comment on the unique branch explains itself - "independent from a
//! possibly outdated statistics" - and the consequence is the most
//! counter-intuitive thing in this crate: on a database whose statistics
//! are zero, a UNIQUE lookup (4) costs MORE than a non-unique one (3), so
//! the engine drives the stream whose inner lookup is non-unique. Probed:
//! with `A.BX` indexed and `B.ID` a primary key the engine plans
//! `JOIN (B NATURAL, A INDEX (A_BX))` in BOTH SQL orders, while two
//! symmetric indexes keep the SQL order - because `findJoinOrder` replaces
//! its best arrangement only on a STRICTLY smaller cost.
//!
//! That is also why a chain of such links drives from its FAR end: two
//! non-unique lookups (3 + 3) beat two unique ones (4 + 4).
//!
//! # Outer joins: the kind decides who drives, and the plan NESTS
//!
//! An inner join may be reordered freely, so a chain of them flattens
//! into one `JOIN (a, b, c)` list. An outer join may not: the preserved
//! side and its optional side are ONE result that later joins see as a
//! unit, and the engine prints that structure -
//! `JOIN (JOIN (A NATURAL, B INDEX ...), C INDEX ...)`.
//!
//! Three laws, all probed against `SET PLANONLY ON`:
//!
//! * **LEFT**: the preserved (left) side drives, the optional side rides
//!   its key index if it has one.
//! * **RIGHT** is LEFT with the sides exchanged - the engine rewrites it
//!   and prints the swapped plan, so `A RIGHT JOIN B` drives B. The ON
//!   clause needs no rewriting, which is what makes the rewrite sound.
//! * **FULL** is BOTH directions at once, and says so:
//!   `JOIN (JOIN (A NATURAL, B INDEX ...), JOIN (B NATURAL, A INDEX ...))`.
//!   A plan that prints only one half is answering a different question.
//!
//! Inside a chain, an INNER join at the head is still free to swap before
//! the outer join wraps it (probed: `A JOIN B ... LEFT JOIN C ...` plans
//! `JOIN (JOIN (B NATURAL, A INDEX (A_BX)), C INDEX (PK_C))`).
//!
//! # The cost boundary, ENFORCED
//!
//! Single-table access paths are STRUCTURAL: the same plans come
//! back whether the table holds no rows or three thousand (verified
//! - a predicate on a column with one distinct value still takes
//! its index). JOIN plans are not. With real data the engine's
//! choice turns on cardinality and statistics: it drives the SMALLER
//! stream regardless of SQL order, and above a modest size it
//! abandons the nested loop for a HASH JOIN even when BOTH sides are
//! indexed (probed: 3000 x 5 rows nested-loops from the small side,
//! 3000 x 50 hashes, 3000 x 2500 hashes).
//!
//! Rather than guess that arithmetic, this crate MEASURES: a join
//! whose streams hold rows is refused, because the decision belongs
//! to a cost model that is not converted. Empty streams keep the
//! structural rules the gate pins. That turns a latent wrong answer
//! into a named refusal - the crate would otherwise print a
//! confident nested-loop plan where the engine hashes.

use fire_crab_ods::data::assembled_image;
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
    /// every segment, in key order - a COMPOUND index matches a
    /// predicate only on its LEADING segment (the prefix rule,
    /// probed: WHERE on the second segment alone plans NATURAL)
    pub columns: Vec<String>,
    pub descending: bool,
    /// `RDB$UNIQUE_FLAG` - and it changes the COST, not just the
    /// semantics: a unique equality retrieval is priced at a FIXED
    /// `DEFAULT_INDEX_COST * indexes + 1`, deliberately independent of
    /// statistics (Retrieval.cpp:371-376), while a non-unique one pays
    /// `index cost + cardinality * selectivity`. On a table whose
    /// statistics are zero that makes the NON-unique index look cheaper,
    /// which is why the engine drives the stream a reader expects to be
    /// the inner one.
    pub unique: bool,
}

impl IndexInfo {
    /// Can this index fetch rows for a predicate on `column`?
    pub fn matches(&self, column: &str) -> bool {
        self.columns
            .first()
            .is_some_and(|c| c.eq_ignore_ascii_case(column))
    }

    /// Can this index NAVIGATE the given ORDER BY? The order columns
    /// must be a PREFIX of the segments and every direction must
    /// agree (probed: ORDER BY x, z on an (x, y) index sorts, and so
    /// does a DESC order over an ascending index).
    pub fn navigates(&self, order: &[(String, bool)]) -> bool {
        order.len() <= self.columns.len()
            && order.iter().enumerate().all(|(i, (c, desc))| {
                self.columns[i].eq_ignore_ascii_case(c) && *desc == self.descending
            })
    }
}

/// The chosen access path for one table.
#[derive(Clone, Debug, PartialEq)]
pub enum Access {
    Natural,
    Index(Vec<String>),
    /// NAVIGATION, with the filter's own inversions beside it. The
    /// engine spells a navigated stream whose WHERE uses OTHER indexes
    /// (or an OR union) as `ORDER <nav> INDEX (<list>)` - probed:
    /// `AMT = 2 ORDER BY ID` is `ORDER IDX_ID INDEX (IDX_AMT)`, and
    /// `ID = 5 OR ID = 7 ORDER BY ID` is `ORDER IDX_ID INDEX (IDX_ID,
    /// IDX_ID)`. An empty `filter` is plain navigation.
    Order { nav: String, filter: Vec<String> },
}

/// How several streams combine (probed): nested-loop JOIN when the
/// inner stream's join column is indexed, HASH when neither side's
/// is (FB5+'s hash join, and only for INNER joins - an outer join
/// keeps its nested loop because the preserved side must drive).
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Combine {
    Single,
    Join,
    Hash,
}

/// One stream of a plan: how it is named in the plan text (its ALIAS
/// when the query gave one, else the table) and its access path.
#[derive(Clone, Debug, PartialEq)]
pub struct Stream {
    pub name: String,
    pub access: Access,
}

/// A plan's shape when it NESTS. Most plans are flat - one JOIN or HASH
/// over a list of streams - but an OUTER join makes a plan NODE: the
/// engine prints `JOIN (JOIN (A NATURAL, B INDEX ...), C INDEX ...)`,
/// where an inner-join chain of the same three streams would have printed
/// one flat `JOIN (C NATURAL, B INDEX ..., A INDEX ...)`.
///
/// That difference is the outer join's semantics showing through: the
/// preserved side and its optional side form ONE result that later joins
/// see as a unit, so they cannot be reordered into the same list.
#[derive(Clone, Debug, PartialEq)]
pub enum PlanNode {
    Stream(Stream),
    Join(Vec<PlanNode>),
    Hash(Vec<PlanNode>),
}

/// A plan: the streams, how they combine, and whether a SORT wraps
/// the whole thing.
///
/// `node` carries the nested shape when there is one; when it is `None`
/// the plan is the flat `streams`/`combine` pair. Keeping both is
/// deliberate - every flat plan in this crate (and its tests) predates
/// nesting, and a flat plan is what most queries produce.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub streams: Vec<Stream>,
    pub combine: Combine,
    pub sorted: bool,
    pub node: Option<PlanNode>,
}

impl Plan {
    /// The engine's own spelling - schema-qualified index names,
    /// double-quoted; stream names quoted BARE when they are aliases
    /// (probed: `PLAN JOIN ("A" NATURAL, ...)`).
    pub fn render(&self) -> String {
        let q = |n: &str| format!("\"PUBLIC\".\"{}\"", n);
        let one = |st: &Stream| -> String {
            let name = if st.name.contains('"') {
                st.name.clone()
            } else {
                format!("\"{}\"", st.name)
            };
            match &st.access {
                Access::Natural => format!("{} NATURAL", name),
                Access::Order { nav, filter } => {
                    if filter.is_empty() {
                        format!("{} ORDER {}", name, q(nav))
                    } else {
                        let names: Vec<String> = filter.iter().map(|n| q(n)).collect();
                        format!("{} ORDER {} INDEX ({})", name, q(nav), names.join(", "))
                    }
                }
                Access::Index(list) => {
                    let names: Vec<String> = list.iter().map(|n| q(n)).collect();
                    format!("{} INDEX ({})", name, names.join(", "))
                }
            }
        };
        if let Some(node) = &self.node {
            fn render_node(n: &PlanNode, one: &dyn Fn(&Stream) -> String) -> String {
                match n {
                    PlanNode::Stream(st) => one(st),
                    PlanNode::Join(parts) => format!(
                        "JOIN ({})",
                        parts
                            .iter()
                            .map(|p| render_node(p, one))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                    PlanNode::Hash(parts) => format!(
                        "HASH ({})",
                        parts
                            .iter()
                            .map(|p| render_node(p, one))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                }
            }
            let inner = render_node(node, &one);
            return if self.sorted {
                format!("PLAN SORT {}", inner)
            } else {
                format!("PLAN {}", inner)
            };
        }
        let body: Vec<String> = self.streams.iter().map(one).collect();
        let inner = match self.combine {
            Combine::Single => body.join(", "),
            Combine::Join => format!("JOIN ({})", body.join(", ")),
            Combine::Hash => format!("HASH ({})", body.join(", ")),
        };
        match (self.combine, self.sorted) {
            (Combine::Single, true) => format!("PLAN SORT ({})", inner),
            (Combine::Single, false) => format!("PLAN ({})", inner),
            (_, true) => format!("PLAN SORT {}", inner),
            (_, false) => format!("PLAN {}", inner),
        }
    }
}

/// A predicate the parser recognized: the column it constrains and
/// whether an index can MATCH it (the engine's "index-usable" test).
#[derive(Clone, Debug)]
struct Pred {
    column: String,
    matchable: bool,
    kind: PredKind,
}

/// The comparison's shape, which picks both the matched-segment REDUCE
/// factor (Retrieval.cpp:1091-1129) and the unindexed-filter factor
/// (Optimizer.h:52-58) in the navigate-vs-sort arithmetic.
#[derive(Clone, Copy, PartialEq, Debug)]
enum PredKind {
    Eq,
    Range,
    Between,
    Starting,
    Other,
}

/// Every single-segment index of a table, in catalog id order.
pub fn indexes_of(
    file: &fire_crab_ods::Image,
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
    let unique_f = fid("RDB$UNIQUE_FLAG");
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = fire_crab_ods::page_at(file, page_size, dp_no).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = assembled_image(file, page_size, &r) else { continue };
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
            if !segs.is_empty() {
                let unique =
                    matches!(unique_f.and_then(|f| values.get(f)), Some(Value::Int(1)));
                out.push(IndexInfo {
                    id: *id,
                    name: iname,
                    columns: segs,
                    descending,
                    unique,
                });
            }
        }
    }
    out.sort_by_key(|i| i.id);
    Ok(out)
}

/// An index's segment columns, in key order (RDB$INDEX_SEGMENTS).
fn index_columns(
    file: &fire_crab_ods::Image,
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
        let Some(dp) = fire_crab_ods::page_at(file, page_size, dp_no).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = assembled_image(file, page_size, &r) else { continue };
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
    file: &fire_crab_ods::Image,
    page_size: usize,
    sql: &str,
) -> Result<Plan, String> {
    let up = sql.trim().trim_end_matches(';').to_uppercase();
    if !up.starts_with("SELECT ") {
        return Err("not a SELECT".into());
    }
    // FIRST n puts the optimizer in first-rows mode (favorFirstRows):
    // navigation that delivers the order without reading everything is
    // preferred however small the table - probed: FIRST 3 ORDER BY pk
    // NAVIGATES on a 6-row table whose bare ORDER BY sorts. A SKIP
    // without FIRST does not set it (probed: SKIP 2 still sorts).
    let favor_first = up["SELECT ".len()..].trim_start().starts_with("FIRST ");
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
    let from_s = after_from[..table_end].trim().to_string();
    // two-stream joins: `A [alias] JOIN B [alias] ON <key> = <key>`
    // (the comma form with an equi-join WHERE plans identically -
    // probed - and reaches here as a comma FROM)
    if from_s.contains(" JOIN ") || from_s.contains(',') {
        return plan_join(file, page_size, &from_s, where_s_of(after_from, where_at, order_at), order_at.map(|o| after_from[o + 5..].trim()));
    }
    let table = from_s;
    if table.is_empty() || table.contains(' ') {
        return Err("aliased single-table FROM unconverted".into());
    }
    if up.contains(" UNION ") || up.contains("(SELECT") {
        return Err("unions and subqueries unconverted".into());
    }
    let where_s = match (where_at, order_at) {
        (Some(w), Some(o)) if o > w => Some(after_from[w + 5..o].trim()),
        (Some(w), _) => Some(after_from[w + 5..].trim()),
        (None, _) => None,
    };
    let order_s = order_at.map(|o| after_from[o + 5..].trim());

    let indexes = indexes_of(file, page_size, &table)?;
    let by_col = |c: &str| -> Vec<&IndexInfo> {
        indexes.iter().filter(|i| i.matches(c)).collect()
    };

    // ---- the predicates -------------------------------------------
    let (preds, all_or_matchable, is_or) = match where_s {
        None => (Vec::new(), true, false),
        Some(w) => parse_predicates(w, &|c| !by_col(c).is_empty())?,
    };
    let mut matched: Vec<&IndexInfo> = Vec::new();
    // each matched conjunct/branch with its index and its comparison's
    // shape - what the navigate-vs-sort arithmetic below prices
    let mut pairs: Vec<(PredKind, &IndexInfo)> = Vec::new();
    if all_or_matchable {
        for p in preds.iter().filter(|p| p.matchable) {
            // the LOWEST-id index on the column (the engine's pick
            // among equals - an ascending index serves a range where
            // a descending twin exists)
            if let Some(i) = by_col(&p.column).into_iter().min_by_key(|i| i.id) {
                pairs.push((p.kind, i));
                // an OR union is ONE INVERSION PER BRANCH, listed in
                // BRANCH order (probed: `ID = 5 OR ID = 7` prints the
                // index twice; `AMT = 2 OR ID = 5` prints AMT first);
                // an AND's conjuncts on one index combine into ONE
                // scan and print once, id-ordered
                if is_or || !matched.iter().any(|m| m.name == i.name) {
                    matched.push(i);
                }
            }
        }
    }
    if !is_or {
        matched.sort_by_key(|i| i.id);
    }

    // ---- the ORDER BY ---------------------------------------------
    let order: Option<Vec<(String, bool)>> = match order_s {
        None => None,
        Some(o) => Some(parse_order_list(o)?),
    };
    if let Some(okeys) = &order {
        // navigation needs an index the ORDER BY is a PREFIX of,
        // directions agreeing (probed: DESC took the descending
        // twin, a non-prefix order sorts)
        let nav = indexes
            .iter()
            .filter(|i| i.navigates(okeys))
            .min_by_key(|i| i.id);
        if let Some(n) = nav {
            // WHAT RIDES THE WALK, WHAT SORTS - the engine's
            // applyNavigation (Retrieval.cpp:667-755), converted term by
            // term and checked cell by cell against the live optimizer on
            // empty, small and grown fixtures, with zero, stale and fresh
            // statistics alike.
            //
            // The filter's inversions that cannot merge into the
            // navigation are its LIST: an AND's nav-index conjuncts ride
            // the walk and drop out, everything else it matched stays;
            // an OR's branches ALL stay - the union cannot ride, even on
            // the nav index itself.
            let filter: Vec<String> = if is_or {
                matched.iter().map(|i| i.name.clone()).collect()
            } else {
                matched
                    .iter()
                    .filter(|i| i.name != n.name)
                    .map(|i| i.name.clone())
                    .collect()
            };
            let card = cardinality(file, page_size, &table).unwrap_or(1.0);
            // a matched conjunct/branch's selectivity: the index's own
            // figure (zero substituting the engine's leading-segment 0.1,
            // Retrieval.cpp:1019-1026), a range/BETWEEN/STARTING reduced
            // toward MAXIMUM_SELECTIVITY by its factor (:1125-1129)
            let pair_sel = |k: PredKind, i: &IndexInfo| -> f64 {
                let base = {
                    let s = index_selectivity(file, page_size, &i.name).unwrap_or(0.0);
                    if s <= 0.0 {
                        DEFAULT_SELECTIVITY
                    } else {
                        s
                    }
                };
                match k {
                    PredKind::Eq => base,
                    PredKind::Between => base + (1.0 - base) * 0.0025,
                    PredKind::Range => base + (1.0 - base) * 0.05,
                    PredKind::Starting | PredKind::Other => base + (1.0 - base) * 0.01,
                }
            };
            // the MATCHED part: an OR composes its branches by SUM
            // (a union names the union of the bands); an AND multiplies,
            // split by whether the conjunct rides the nav scratch
            let (match_sel, nav_ride_sel, nav_rides, has_sep_inversion) = if is_or {
                let sum: f64 = pairs.iter().map(|(k, i)| pair_sel(*k, i)).sum::<f64>().min(1.0);
                (if pairs.is_empty() { 1.0 } else { sum }, 1.0, false, !pairs.is_empty())
            } else {
                let mut ride = 1.0f64;
                let mut rides = false;
                let mut sep = 1.0f64;
                let mut has_sep = false;
                for (k, i) in &pairs {
                    if i.name == n.name {
                        ride *= pair_sel(*k, i);
                        rides = true;
                    } else {
                        sep *= pair_sel(*k, i);
                        has_sep = true;
                    }
                }
                (ride * sep, ride, rides, has_sep)
            };
            // the UNINDEXED conjuncts (or an unusable OR, whose branch
            // factors SUM) become filter factors, backed off behind the
            // matches (applyFilters passes matchCount as priorConjuncts)
            let factor_of = |k: PredKind| -> f64 {
                match k {
                    PredKind::Eq => 0.001,
                    PredKind::Between => 0.0025,
                    PredKind::Range => 0.05,
                    PredKind::Starting => 0.01,
                    PredKind::Other => 0.01,
                }
            };
            let factors: Vec<f64> = if is_or && !all_or_matchable {
                vec![preds.iter().map(|p| factor_of(p.kind)).sum::<f64>().min(1.0)]
            } else if !is_or {
                preds.iter().filter(|p| !p.matchable).map(|p| factor_of(p.kind)).collect()
            } else {
                Vec::new()
            };
            let filter_sel = estimate_selectivity(&factors, card, pairs.len());
            let cand_sel = match_sel * filter_sel;
            // "If the table looks like empty during preparation time ...
            // let's better be pessimistic and avoid external sorting"
            // (:681-686) - only when NO inversion sits beside the walk.
            // First-rows mode with NO local filtering skips the sort
            // outright (:684-685: favorFirstRows && selectivity ==
            // MAXIMUM_SELECTIVITY).
            let avoid_sorting = (card <= 1.0
                && !has_sep_inversion
                && !(is_or && !pairs.is_empty()))
                || (favor_first && cand_sel >= 1.0);
            let navigates = if avoid_sorting {
                true
            } else {
                // sortCost: copying in and out (2 x MEMCOPY 0.5) plus
                // quicksort's n log n at COST_FACTOR_QUICKSORT 0.1 -
                // log2 of a sub-row cardinality goes NEGATIVE, and that
                // is the engine's own arithmetic (it is what makes a
                // heavily-filtered sort nearly free)
                let c = card * cand_sel;
                let sort_cost = if c > 0.0 { c + 0.1 * c * c.log2() } else { 0.0 };
                // navigationCost: the walk's own cost only when nothing
                // rides it (a riding match accounts it in the candidate),
                // plus an index-leaf fetch per MATCH-cardinality record
                // at the nav scratch's selectivity (:710-717)
                let match_card = card * match_sel;
                let nav_cost = if favor_first {
                    // first-rows mode reprices the walk as "to the first
                    // matching record" (:727-737): a single retrieval
                    // (DEFAULT_INDEX_COST unless a match rides the walk)
                    // plus the fraction of the index walked to reach it
                    let base = if nav_rides { 0.0 } else { 3.0 };
                    let fraction = if cand_sel > 0.0 && card > 0.0 {
                        (1.0 / cand_sel) / card
                    } else {
                        1.0
                    };
                    base + index_pages(card) * fraction * nav_ride_sel
                } else {
                    let nav_cost0 = if nav_rides {
                        0.0
                    } else {
                        3.0 + 1.0 * index_pages(card)
                    };
                    nav_cost0 + match_card * nav_ride_sel
                };
                !(sort_cost < nav_cost)
            };
            if navigates {
                return Ok(Plan {
                    streams: vec![Stream {
                        name: qualified(&table),
                        access: Access::Order { nav: n.name.clone(), filter },
                    }],
                    combine: Combine::Single,
                    sorted: false,
                    node: None,
                });
            }
        }
    }
    let access = if matched.is_empty() {
        Access::Natural
    } else {
        Access::Index(matched.iter().map(|i| i.name.clone()).collect())
    };
    Ok(Plan {
        streams: vec![Stream { name: qualified(&table), access }],
        combine: Combine::Single,
        sorted: order.is_some(),
        node: None,
    })
}

/// The WHERE text between its keyword and the ORDER clause.
fn where_s_of<'a>(
    after_from: &'a str,
    where_at: Option<usize>,
    order_at: Option<usize>,
) -> Option<&'a str> {
    match (where_at, order_at) {
        (Some(w), Some(o)) if o > w => Some(after_from[w + 5..o].trim()),
        (Some(w), _) => Some(after_from[w + 5..].trim()),
        (None, _) => None,
    }
}

/// Plan a TWO-STREAM join. The probed decision: the inner (second)
/// stream must reach its rows by the join key's index, so the
/// optimizer picks whichever ORDER makes that possible - an INNER
/// join swaps the SQL order when only the first stream's key is
/// indexed. When NEITHER key is indexed the engine hashes (FB5+),
/// except under an OUTER join, whose preserved side must drive and
/// which therefore keeps its nested loop with both streams NATURAL.
/// Exchange the two sides of a two-stream join, keeping the ON clause:
/// `A LEFT JOIN B ON ...` becomes `B LEFT JOIN A ON ...`.
///
/// The ON predicate needs no rewriting - `A.BX = B.ID` means the same
/// either way round - which is exactly why the engine can treat RIGHT as
/// LEFT-reversed.
fn swap_join_sides(from_s: &str) -> Result<String, String> {
    let up = from_s.to_uppercase();
    let jpos = up.find(" JOIN ").ok_or("cannot split the join")?;
    let head = from_s[..jpos].trim();
    let rest = from_s[jpos + 6..].trim();
    // the join word(s) between the two sides
    let lhs = head
        .trim_end_matches(|_| false)
        .to_string();
    let (lhs, keyword) = {
        let u = lhs.to_uppercase();
        let mut cut = lhs.len();
        for kw in [" LEFT OUTER", " RIGHT OUTER", " FULL OUTER", " LEFT", " RIGHT", " FULL", " INNER"] {
            if let Some(p) = u.rfind(kw) {
                if p + kw.len() == lhs.len() {
                    cut = p;
                    break;
                }
            }
        }
        (lhs[..cut].trim().to_string(), lhs[cut..].trim().to_string())
    };
    let (rhs, on) = match rest.to_uppercase().find(" ON ") {
        Some(o) => (rest[..o].trim().to_string(), rest[o..].to_string()),
        None => (rest.to_string(), String::new()),
    };
    // RIGHT becomes LEFT once the sides move
    let kw = match keyword.to_uppercase().as_str() {
        k if k.starts_with("RIGHT") => "LEFT".to_string(),
        k if k.starts_with("LEFT") => "LEFT".to_string(),
        k if k.is_empty() => String::new(),
        k => k.to_string(),
    };
    Ok(if kw.is_empty() {
        format!("{} JOIN {}{}", rhs, lhs, on)
    } else {
        format!("{} {} JOIN {}{}", rhs, kw, lhs, on)
    })
}

/// A chain with an outer join in it. The engine builds a plan NODE per
/// outer join and nests them LEFT-DEEP, in the SQL's own order - the
/// optional side of a LEFT join cannot be reordered ahead of the side it
/// preserves, so unlike an inner chain there is nothing to arrange.
///
/// Probed on the engine:
/// ```text
/// A LEFT JOIN B ON A.BX=B.ID LEFT JOIN C ON B.CX=C.ID
///   -> JOIN (JOIN (A NATURAL, B INDEX (PK_B)), C INDEX (PK_C))
/// A JOIN B ON A.BX=B.ID LEFT JOIN C ON B.CX=C.ID
///   -> JOIN (JOIN (B NATURAL, A INDEX (A_BX)), C INDEX (PK_C))
/// ```
/// The second is the interesting one: the INNER join at the head is still
/// free to swap (B drives A through A_BX), and only then does the outer
/// join wrap it.
fn plan_outer_chain(
    file: &fire_crab_ods::Image,
    page_size: usize,
    from_s: &str,
    where_s: Option<&str>,
    order_s: Option<&str>,
) -> Result<Plan, String> {
    // split into the head (everything before the LAST join) and the tail
    // stream that join attaches
    let up = from_s.to_uppercase();
    let last = up.rfind(" JOIN ").ok_or("cannot split the chain")?;
    let head_end = ["  LEFT", " LEFT", " RIGHT", " FULL", " INNER", " OUTER"]
        .iter()
        .filter_map(|kw| {
            let p = up[..last].rfind(kw)?;
            if p + kw.len() == last {
                Some(p)
            } else {
                None
            }
        })
        .min()
        .unwrap_or(last);
    let head = from_s[..head_end].trim();
    let tail_kind = outer_kind(&from_s[head_end..last + 6]);
    let rest = from_s[last + 6..].trim();
    let (tail, on_s) = match rest.to_uppercase().find(" ON ") {
        Some(o) => (rest[..o].trim(), rest[o + 4..].trim().to_string()),
        None => return Err("outer join in a chain without an ON clause".into()),
    };
    if tail_kind == OuterKind::Full {
        return Err("FULL join inside a chain unconverted".into());
    }
    if tail_kind == OuterKind::Right {
        return Err("RIGHT join inside a chain unconverted".into());
    }
    // the head is a plan in its own right - recursively, so a three-way
    // chain nests twice
    let head_plan = plan_join(file, page_size, head, where_s, None)?;
    // the tail stream rides the ON key's index if it has one
    let (ttab, tali) = split_alias(tail)?;
    let tidx = indexes_of(file, page_size, &ttab)?;
    let tcol = on_column_for(&on_s, &tali)?;
    let access = match tidx
        .iter()
        .filter(|i| i.matches(&tcol) && !i.descending)
        .min_by_key(|i| i.id)
    {
        Some(i) => Access::Index(vec![i.name.clone()]),
        None => Access::Natural,
    };
    let head_node = match head_plan.node.clone() {
        Some(n) => n,
        None => match head_plan.combine {
            Combine::Single => PlanNode::Stream(head_plan.streams[0].clone()),
            Combine::Hash => PlanNode::Hash(
                head_plan.streams.iter().cloned().map(PlanNode::Stream).collect(),
            ),
            Combine::Join => PlanNode::Join(
                head_plan.streams.iter().cloned().map(PlanNode::Stream).collect(),
            ),
        },
    };
    let tail_stream = Stream { name: tali, access };
    let mut streams = head_plan.streams.clone();
    streams.push(tail_stream.clone());
    Ok(Plan {
        streams,
        combine: Combine::Join,
        sorted: order_s.is_some(),
        node: Some(PlanNode::Join(vec![head_node, PlanNode::Stream(tail_stream)])),
    })
}

/// The column of `alias` mentioned in an ON clause `x.a = y.b`.
fn on_column_for(on_s: &str, alias: &str) -> Result<String, String> {
    // the stream name may arrive schema-qualified (`"PUBLIC"."C"`), while
    // the ON clause names it bare (`C.ID`)
    let bare = alias
        .rsplit('.')
        .next()
        .unwrap_or(alias)
        .trim_matches('"');
    for side in on_s.split('=') {
        let side = side.trim();
        if let Some((q, c)) = side.split_once('.') {
            if q.trim().trim_matches('"').eq_ignore_ascii_case(bare) {
                return Ok(c.trim().trim_matches('"').to_string());
            }
        }
    }
    Err(format!("no ON column for {}", alias))
}

/// Which outer join, if any - the KIND matters, not just the fact.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OuterKind {
    Inner,
    Left,
    Right,
    Full,
}

/// The kind of the FIRST join in a FROM clause.
fn outer_kind(from_s: &str) -> OuterKind {
    let up = from_s.to_uppercase();
    let at = |k: &str| up.find(k).unwrap_or(usize::MAX);
    let (l, r, f) = (at(" LEFT "), at(" RIGHT "), at(" FULL "));
    let first = l.min(r).min(f);
    if first == usize::MAX {
        OuterKind::Inner
    } else if first == l {
        OuterKind::Left
    } else if first == r {
        OuterKind::Right
    } else {
        OuterKind::Full
    }
}

fn plan_join(
    file: &fire_crab_ods::Image,
    page_size: usize,
    from_s: &str,
    where_s: Option<&str>,
    order_s: Option<&str>,
) -> Result<Plan, String> {
    let kind = outer_kind(from_s);
    let outer = kind != OuterKind::Inner;
    // three or more streams with an outer join anywhere: an outer join
    // makes a plan NODE, so the chain nests instead of flattening
    if from_s.matches(" JOIN ").count() > 1 {
        if outer {
            return plan_outer_chain(file, page_size, from_s, where_s, order_s);
        }
        return plan_chain(file, page_size, from_s, where_s, order_s);
    }
    // A RIGHT join is a LEFT join with the sides exchanged: the
    // PRESERVED side is the right one, so it drives. The engine does
    // this rewrite in the parser, and the plan it prints is the
    // swapped-left plan - not the left-driving one, which is what
    // fire-crab printed before this slice.
    if kind == OuterKind::Right {
        let swapped = swap_join_sides(from_s)?;
        return plan_join(file, page_size, &swapped, where_s, order_s);
    }
    // A FULL join is BOTH directions, and the engine says so: it plans
    // `JOIN (JOIN (A ..., B ...), JOIN (B ..., A ...))` - the union of
    // the left-driving and right-driving nested loops. Anything that
    // prints one of the two halves is answering a different question.
    if kind == OuterKind::Full {
        let left_first = from_s.replacen(" FULL ", " LEFT ", 1);
        let a = plan_join(file, page_size, &left_first, where_s, order_s)?;
        let swapped = swap_join_sides(&left_first)?;
        let b = plan_join(file, page_size, &swapped, where_s, order_s)?;
        let as_node = |p: &Plan| -> PlanNode {
            PlanNode::Join(p.streams.iter().cloned().map(PlanNode::Stream).collect())
        };
        return Ok(Plan {
            streams: a.streams.iter().chain(b.streams.iter()).cloned().collect(),
            combine: Combine::Join,
            sorted: order_s.is_some(),
            node: Some(PlanNode::Join(vec![as_node(&a), as_node(&b)])),
        });
    }
    // split the two sides and the ON clause
    let (lhs, rest) = if let Some(j) = from_s.find(" JOIN ") {
        (from_s[..j].trim(), from_s[j + 6..].trim())
    } else {
        let c = from_s.find(',').ok_or("cannot split the FROM")?;
        (from_s[..c].trim(), from_s[c + 1..].trim())
    };
    let lhs_raw = lhs;
    let lhs = lhs_raw
        .trim_end_matches(" LEFT")
        .trim_end_matches(" RIGHT")
        .trim_end_matches(" FULL")
        .trim_end_matches(" INNER")
        .trim_end_matches(" OUTER")
        .trim();
    let (rhs, on_s) = match rest.find(" ON ") {
        Some(o) => (rest[..o].trim(), rest[o + 4..].trim().to_string()),
        None => {
            // the comma form: the equi-join lives in the WHERE
            let w = where_s.ok_or("comma join without a join predicate")?;
            (rest, w.to_string())
        }
    };
    // INNER joins go through the general equivalence-class planner
    // (it subsumes the two-stream swap); its no-arrangement error is
    // where the HASH join lives
    if !outer {
        match plan_chain(file, page_size, from_s, where_s, order_s) {
            Ok(p) => return Ok(p),
            Err(e) if e.starts_with("no arrangement") => {
                let (_, lali) = split_alias(lhs)?;
                let rhs_decl = match rest.find(" ON ") {
                    Some(o) => rest[..o].trim(),
                    None => rest,
                };
                let (_, rali) = split_alias(rhs_decl)?;
                return Ok(Plan {
                    streams: vec![
                        Stream { name: lali, access: Access::Natural },
                        Stream { name: rali, access: Access::Natural },
                    ],
                    combine: Combine::Hash,
                    sorted: order_s.is_some(),
                    node: None,
                });
            }
            Err(e) => return Err(e),
        }
    }
    let (ltab, lali) = split_alias(lhs)?;
    let (rtab, rali) = split_alias(rhs)?;
    cost_free_or_refuse(file, page_size, &[ltab.clone(), rtab.clone()])?;
    // the join key: <qualifier>.<col> = <qualifier>.<col>
    let (lcol, rcol) = parse_join_key(&on_s, &lali, &rali)?;
    let lidx = indexes_of(file, page_size, &ltab)?;
    let ridx = indexes_of(file, page_size, &rtab)?;
    let find = |ix: &[IndexInfo], c: &str| -> Option<IndexInfo> {
        ix.iter()
            .filter(|i| i.matches(c) && !i.descending)
            .min_by_key(|i| i.id)
            .cloned()
    };
    let l_key_idx = find(&lidx, &lcol);
    let r_key_idx = find(&ridx, &rcol);
    // the type families must agree for an index to serve the join
    // (probed: a VARCHAR = INTEGER join hashed even though one side
    // was indexed)
    let same_family = column_family(file, page_size, &ltab, &lcol)?
        == column_family(file, page_size, &rtab, &rcol)?;
    // driving choice
    let (driver, inner, driver_idx, inner_key_idx, dali, iali) =
        match (&r_key_idx, &l_key_idx, outer, same_family) {
            (_, _, _, false) | (None, None, _, _) => {
                // no usable inner index: HASH (inner joins) or a
                // natural nested loop (outer joins keep their order)
                return Ok(Plan {
                    streams: vec![
                        Stream { name: lali.clone(), access: Access::Natural },
                        Stream { name: rali.clone(), access: Access::Natural },
                    ],
                    combine: if outer { Combine::Join } else { Combine::Hash },
                    sorted: order_s.is_some(),
                    node: None,
                });
            }
            (Some(ri), Some(li), false, true) => {
                // BOTH keys are indexed, so both arrangements are legal and
                // the engine picks the cheaper - where "cheaper" is decided
                // by `retrieval_cost`, whose unique branch is a FIXED 4.
                // On a database whose statistics are zero that makes the
                // non-unique side cheaper, and the engine drives the stream
                // whose inner lookup is non-unique (probed in both SQL
                // orders). Equal costs keep the SQL order, which is the
                // engine's own tie-break: `findJoinOrder` replaces the best
                // arrangement only on a STRICTLY smaller cost
                // (InnerJoin.cpp:366).
                let sel_r = index_selectivity(file, page_size, &ri.name)?;
                let sel_l = index_selectivity(file, page_size, &li.name)?;
                let card_l = cardinality(file, page_size, &ltab)?;
                let card_r = cardinality(file, page_size, &rtab)?;
                let drive_l = retrieval_cost(ri.unique, sel_r, card_r);
                let drive_r = retrieval_cost(li.unique, sel_l, card_l);
                if drive_r < drive_l {
                    // the RIGHT stream drives, the left rides its index
                    (
                        rtab.clone(),
                        ltab.clone(),
                        ridx.clone(),
                        li.clone(),
                        rali.clone(),
                        lali.clone(),
                    )
                } else {
                    (
                        ltab.clone(),
                        rtab.clone(),
                        lidx.clone(),
                        ri.clone(),
                        lali.clone(),
                        rali.clone(),
                    )
                }
            }
            (Some(ri), Some(_), true, true) => {
                // an OUTER join has no choice: the preserved side drives,
                // whatever the costs say
                (
                    ltab.clone(),
                    rtab.clone(),
                    lidx.clone(),
                    ri.clone(),
                    lali.clone(),
                    rali.clone(),
                )
            }
            (Some(ri), _, _, _) => {
                (ltab.clone(), rtab.clone(), lidx.clone(), ri.clone(), lali.clone(), rali.clone())
            }
            (None, Some(li), false, _) => {
                // only the LEFT key is indexed: an inner join swaps
                (rtab.clone(), ltab.clone(), ridx.clone(), li.clone(), rali.clone(), lali.clone())
            }
            (None, Some(_), true, _) => {
                return Ok(Plan {
                    streams: vec![
                        Stream { name: lali.clone(), access: Access::Natural },
                        Stream { name: rali.clone(), access: Access::Natural },
                    ],
                    combine: Combine::Join,
                    sorted: order_s.is_some(),
                    node: None,
                })
            }
        };
    let _ = &inner;
    // the DRIVING stream's own access: its WHERE predicate, or an
    // ORDER BY it can navigate, else NATURAL
    let mut drive_access = Access::Natural;
    let mut sorted = order_s.is_some();
    let drive_col = |q: &str| -> Option<String> {
        let (qual, col) = q.split_once('.')?;
        if qual.trim().eq_ignore_ascii_case(dali.trim_matches('"')) {
            Some(col.trim().to_string())
        } else {
            None
        }
    };
    if let Some(w) = where_s {
        // only conjuncts qualified to the driver, matchable, count
        for part in split_kw(w, "AND") {
            let part = part.trim();
            if part.contains('=') && part.contains('.') {
                let mut halves = part.split('=');
                let lhs_q = halves.next().unwrap_or("").trim();
                let rhs_q = halves.next().unwrap_or("").trim();
                // BOTH sides qualified = the join predicate itself
                // (the comma form carries it in the WHERE), never a
                // driving filter
                if rhs_q.contains('.') && !rhs_q.contains('\'') {
                    continue;
                }
                if let Some(col) = drive_col(lhs_q) {
                    if let Some(i) = find(&driver_idx, &col) {
                        drive_access = Access::Index(vec![i.name]);
                    }
                }
            }
        }
    }
    if let Some(o) = order_s {
        let (ocol, odesc) = parse_order(o)?;
        let ocol = ocol.split('.').next_back().unwrap_or(&ocol).to_string();
        if let Some(i) = driver_idx
            .iter()
            .filter(|i| i.navigates(&[(ocol.clone(), odesc)]))
            .min_by_key(|i| i.id)
        {
            drive_access = Access::Order { nav: i.name.clone(), filter: Vec::new() };
            sorted = false;
        }
    }
    let _ = driver;
    Ok(Plan {
        streams: vec![
            Stream { name: dali, access: drive_access },
            Stream {
                name: iali,
                access: Access::Index(vec![inner_key_idx.name]),
            },
        ],
        combine: Combine::Join,
        sorted,
        node: None,
    })
}

/// Plan an INNER join of THREE OR MORE streams by the rule the
/// probes settled: build EQUIVALENCE CLASSES from every equi-join
/// predicate (so `D.Z = B.UID` and `A.ID = B.UID` put A.ID, B.UID
/// and D.Z in one class), then find an arrangement in which every
/// stream after the first reaches its rows through an index on a
/// column of a class it SHARES WITH AN ALREADY-PLACED STREAM. The
/// engine tries drivers in SQL order and keeps the remaining streams
/// in SQL order too - which is why an unindexable link ends up
/// driving: no arrangement starting anywhere else completes.
fn plan_chain(
    file: &fire_crab_ods::Image,
    page_size: usize,
    from_s: &str,
    where_s: Option<&str>,
    order_s: Option<&str>,
) -> Result<Plan, String> {
    // split `A a JOIN B b ON <k> JOIN C c ON <k>` into declarations
    // and ON clauses
    let mut parts: Vec<&str> = Vec::new();
    let mut rest = from_s;
    loop {
        let j = rest.find(" JOIN ").map(|j| (j, 6));
        let c = rest.find(',').map(|c| (c, 1));
        match match (j, c) {
            (Some(a), Some(b)) if a.0 < b.0 => Some(a),
            (Some(_), Some(b)) => Some(b),
            (a, b) => a.or(b),
        } {
            Some((at, skip)) => {
                parts.push(rest[..at].trim());
                rest = &rest[at + skip..];
            }
            None => break,
        }
    }
    parts.push(rest.trim());
    let mut tables: Vec<String> = Vec::new();
    let mut names: Vec<String> = Vec::new();
    let mut ons: Vec<String> = Vec::new();
    for (i, p) in parts.iter().enumerate() {
        let (decl, on) = match p.find(" ON ") {
            Some(o) => (p[..o].trim(), Some(p[o + 4..].trim().to_string())),
            None => (p.trim(), None),
        };
        let (tab, name) = split_alias(decl)?;
        tables.push(tab);
        names.push(name);
        match (i, on) {
            (0, None) => {}
            (0, Some(_)) => return Err("the first stream carries an ON".into()),
            (_, Some(o)) => ons.push(o),
            // the comma form carries its equalities in the WHERE
            (_, None) => {}
        }
    }
    if tables.len() > 2 {
        cost_free_or_refuse(file, page_size, &tables)?;
    }
    let n = tables.len();
    let bare: Vec<String> = names
        .iter()
        .map(|x| x.trim_matches('"').rsplit('.').next().unwrap_or(x).trim_matches('"').to_string())
        .collect();
    let indexes: Vec<Vec<IndexInfo>> = tables
        .iter()
        .map(|t| indexes_of(file, page_size, t))
        .collect::<Result<_, _>>()?;

    // ---- the equivalence classes -----------------------------------
    // each class is a set of (stream, column) pairs the join
    // predicates prove equal
    let mut classes: Vec<Vec<(usize, String)>> = Vec::new();
    let mut add_pair = |a: (usize, String), b: (usize, String), classes: &mut Vec<Vec<(usize, String)>>| {
        let find = |c: &(usize, String), classes: &Vec<Vec<(usize, String)>>| {
            classes.iter().position(|cl| {
                cl.iter().any(|(s, col)| *s == c.0 && col.eq_ignore_ascii_case(&c.1))
            })
        };
        match (find(&a, classes), find(&b, classes)) {
            (None, None) => classes.push(vec![a, b]),
            (Some(i), None) => classes[i].push(b),
            (None, Some(j)) => classes[j].push(a),
            (Some(i), Some(j)) if i != j => {
                let merged = classes[j].clone();
                classes[i].extend(merged);
                classes.remove(j);
            }
            _ => {}
        }
    };
    let qual_of = |q: &str| -> Option<usize> {
        bare.iter().position(|b| b.eq_ignore_ascii_case(q.trim().trim_matches('"')))
    };
    let mut collect_equi = |text: &str, classes: &mut Vec<Vec<(usize, String)>>| {
        for clause in split_kw(text, "AND") {
            let Some((a, b)) = clause.split_once('=') else { continue };
            let (Some((aq, ac)), Some((bq, bc))) =
                (a.trim().split_once('.'), b.trim().split_once('.'))
            else {
                continue;
            };
            if let (Some(ai), Some(bi)) = (qual_of(aq), qual_of(bq)) {
                let (acol, bcol) = (
                    ac.trim().trim_matches('"').to_string(),
                    bc.trim().trim_matches('"').to_string(),
                );
                // an equality across TYPE FAMILIES proves nothing an
                // index can use (probed: a VARCHAR = INTEGER join
                // hashes even with an indexed side)
                let fam_a = column_family(file, page_size, &tables[ai], &acol);
                let fam_b = column_family(file, page_size, &tables[bi], &bcol);
                if !matches!((fam_a, fam_b), (Ok(x), Ok(y)) if x == y) {
                    continue;
                }
                add_pair((ai, acol), (bi, bcol), classes);
            }
        }
    };
    for on in &ons {
        collect_equi(on, &mut classes);
    }
    if let Some(w) = where_s {
        collect_equi(w, &mut classes);
    }

    // ---- can stream `s` be reached by index from `placed`? ---------
    let reach = |s: usize, placed: &[usize]| -> Option<IndexInfo> {
        for cl in &classes {
            // a column of s in this class, and a column of some
            // already-placed stream in the SAME class
            let joined = cl.iter().any(|(t, _)| placed.contains(t));
            if !joined {
                continue;
            }
            for (t, col) in cl.iter().filter(|(t, _)| *t == s) {
                if let Some(i) = indexes[*t]
                    .iter()
                    .filter(|x| x.matches(col) && !x.descending)
                    .min_by_key(|x| x.id)
                {
                    return Some(i.clone());
                }
            }
        }
        None
    };
    // ---- the cardinality bands decide a TWO-stream join ----------
    // (the structural reachability rules below still say WHETHER an
    // arrangement is possible; the band says WHICH the engine picks)
    let mut driver_order: Vec<usize> = (0..n).collect();
    // Whether the two-stream COST model above has already decided the
    // order. When it has, the arrangement search must not second-guess it
    // - the band/cost decision is the converted engine model for
    // populated tables, while the per-arrangement costing below is what
    // decides when statistics are absent.
    let mut order_decided = false;
    if n == 2 {
        let ca = cardinality(file, page_size, &tables[0])?;
        let cb = cardinality(file, page_size, &tables[1])?;
        // the COST MODEL decides when the statistics behind it are
        // fresh; a zero selectivity means they were never computed
        // for the data now present, and the crate falls back to the
        // probed bands rather than costing with a number the engine
        // itself distrusts
        // the key's index: its SELECTIVITY and whether it is UNIQUE, which
        // price the inner retrieval differently (Retrieval.cpp:371)
        let key_sel = |si: usize, col: &str| -> Result<Option<(f64, bool)>, String> {
            let ix = indexes_of(file, page_size, &tables[si])?;
            match ix
                .iter()
                .filter(|x| x.matches(col) && !x.descending)
                .min_by_key(|x| x.id)
            {
                None => Ok(None),
                Some(i) => Ok(Some((
                    index_selectivity(file, page_size, &i.name)?,
                    i.unique,
                ))),
            }
        };
        // the join key columns per stream, from the first class that
        // spans both
        let mut cols: Option<(String, String)> = None;
        for cl in &classes {
            let a = cl.iter().find(|(t, _)| *t == 0).map(|(_, c)| c.clone());
            let b = cl.iter().find(|(t, _)| *t == 1).map(|(_, c)| c.clone());
            if let (Some(a), Some(b)) = (a, b) {
                cols = Some((a, b));
                break;
            }
        }
        // ONE side's key indexed and the other's not: the engine builds
        // the nested loop with the INDEXED side as the inner (probed:
        // `JOIN (B NATURAL, A INDEX)` on the empty fixtures) - the old
        // cardinality bands' arrangement search finds exactly that, so
        // the half-indexed case keeps them
        let mut half_indexed = false;
        let costed = match &cols {
            None => None,
            Some((ca_col, cb_col)) => {
                let sa = key_sel(0, ca_col)?;
                let sb = key_sel(1, cb_col)?;
                if sa.is_some() != sb.is_some() {
                    half_indexed = true;
                }
                match (sa, sb) {
                    (Some((sa, ua)), Some((sb, ub))) => {
                        // a ZERO selectivity on a POPULATED index means
                        // the statistics were never computed for the
                        // A ZERO stored selectivity is the engine's
                        // SUBSTITUTION case, not a refusal.
                        // Retrieval.cpp:1019-1026:
                        //
                        //   auto selectivity = idx->idx_rpt[j].idx_selectivity;
                        //   if (selectivity <= 0)
                        //       selectivity = MAX(scratch.selectivity * DEFAULT_SELECTIVITY,
                        //                         minSelectivity);
                        //
                        // It is PER MATCHED SEGMENT and geometric -
                        // `scratch.selectivity` is the running compound
                        // figure (:978 sets it to MAXIMUM_SELECTIVITY,
                        // :1055 overwrites it per fully matched segment),
                        // so two matched segments give 0.1 then 0.01,
                        // not 0.1 twice.
                        //
                        // And for the LEADING segment the MAX is DEAD
                        // CODE: `scratch.selectivity` is still 1.0 there,
                        // so the expression is
                        // `MAX(0.1, MIN(1/cardinality, 0.1))` whose right
                        // operand cannot exceed 0.1 by construction. The
                        // substituted leading figure is EXACTLY 0.1 at
                        // every cardinality. This crate only ever matches
                        // segment 0 (`IndexInfo::matches`), so that is the
                        // whole conversion.
                        //
                        // This replaces a REFUSAL that stood on a false
                        // premise - "the engine keeps costing with
                        // internal state this crate has not converted".
                        // The state was DEFAULT_SELECTIVITY, and it is
                        // one constant.
                        let sa = if sa <= 0.0 { DEFAULT_SELECTIVITY } else { sa };
                        let sb = if sb <= 0.0 { DEFAULT_SELECTIVITY } else { sb };
                        // FOUR TOTALS, and each carries the DRIVER's
                        // own scan.
                        //
                        // The driver is not free. InnerJoin.cpp:323
                        // seeds `findBestOrder(0, innerStream, ..., 0.0,
                        // 1.0)`, which looks like a zero - but :377
                        // calls `estimateCost(position = 0, ...)` under
                        // no guard, and :192 charges `loopCost =
                        // candidate->cost * cardinality` with
                        // cardinality == 1.0. A bare natural scan's
                        // candidate cost is the stream's own row count
                        // (Retrieval.cpp:308-316 builds a dummy
                        // candidate with selectivity 1.0 and cost 0,
                        // then :1145 adds `cardinality * 1.0`). So
                        // position 0 costs the driver's cardinality.
                        //
                        // Comparing inner-side costs only - which is
                        // what leaving it out did - cancels the driver's
                        // price. That is harmless when the two sides are
                        // similar and wrong when they differ
                        // hundredfold, which is exactly the shape a
                        // keyed join is for.
                        //
                        // And BOTH hash orientations are priced. The
                        // engine reaches them through its two starting
                        // streams (InnerJoin.cpp:318-323) and prices the
                        // stream at `position` as the hashed one against
                        // the priors probing (:229-234, where
                        // `hashCardinality`/`currentCardinality` come
                        // from the NEW stream and `cardinality` from the
                        // priors). `formRiver`'s swap (:575-581) is
                        // POST-decision - it sits behind
                        // `equiMatches.hasData()`, which :269-270 fills
                        // only after `hashCost <= loopCost` has already
                        // passed - so it renormalises the printed sides
                        // rather than restricting what gets costed.
                        // each stream's OWN filter scales the rows it
                        // feeds forward (the engine's estimateSelectivity;
                        // an unpriceable shape keeps the raw cardinality)
                        let fa = stream_filter_selectivity(
                            where_s, 0, &qual_of, ca,
                            &|c| indexes[0].iter().any(|x| x.matches(c)),
                        )
                        .unwrap_or(1.0);
                        let fb = stream_filter_selectivity(
                            where_s, 1, &qual_of, cb,
                            &|c| indexes[1].iter().any(|x| x.matches(c)),
                        )
                        .unwrap_or(1.0);
                        let (ca_f, cb_f) = (ca * fa, cb * fb);
                        // the seed terms stay RAW: position 0 pays the
                        // driver's own SCAN, which reads every row the
                        // filter then drops
                        let loop_ab = ca + loop_cost(ca_f, cb, sb, ub); // A drives, B indexed
                        let loop_ba = cb + loop_cost(cb_f, ca, sa, ua); // B drives, A indexed
                        // avoidHashJoin (InnerJoin.cpp:217): a stream
                        // that looks empty or single-rowed at prepare
                        // time is never hashed - the engine distrusts
                        // its own cardinality there
                        let hash_ab = if cb <= 1.0 {
                            f64::INFINITY
                        } else {
                            ca + hash_cost(ca_f, cb, fb, sb, ub) // A probes, B hashed
                        };
                        let hash_ba = if ca <= 1.0 {
                            f64::INFINITY
                        } else {
                            cb + hash_cost(cb_f, ca, fa, sa, ua) // B probes, A hashed
                        };
                        let best_loop = loop_ab.min(loop_ba);
                        let best_hash = hash_ab.min(hash_ba);
                        // `<=`, not `<`: InnerJoin.cpp:236 is
                        // `if (hashCost <= loopCost && ...)`. Ties are
                        // not rare - (5,8), (10,20), (15,40), (9,18) and
                        // (12,28) are all exact - so the direction of the
                        // tie decides real cells.
                        if best_hash <= best_loop {
                            Some(JoinShape::Hash)
                        } else if loop_ba < loop_ab {
                            Some(JoinShape::Swap)
                        } else {
                            Some(JoinShape::SqlOrder)
                        }
                    }
                    _ => None,
                }
            }
        };
        // A shape from the COST model is final; one from the probed
        // cardinality BANDS is not, when it merely says "keep the SQL
        // order" - that was the right answer on every database the bands
        // were probed against, and those all had symmetric indexes. The
        // per-arrangement costing below is what distinguishes a unique
        // inner lookup from a non-unique one.
        // does the ON (or the comma form's WHERE) carry ANY equality
        // between the two streams? The equivalence classes exclude a
        // CROSS-FAMILY pair - rightly, for INDEX use - but the engine
        // still HASHES one (probed: `A.NAME = B.UA`, VARCHAR = INTEGER,
        // is `PLAN HASH`), so the hash law keys on the raw equality
        let mut has_equi = cols.is_some();
        if !has_equi {
            let mut check = |text: &str| {
                for clause in split_kw(text, "AND") {
                    if let Some((a, b)) = clause.split_once('=') {
                        if b.contains('\'') {
                            continue;
                        }
                        if let (Some((aq, _)), Some((bq, _))) =
                            (a.trim().split_once('.'), b.trim().split_once('.'))
                        {
                            if qual_of(aq).is_some() && qual_of(bq).is_some() {
                                has_equi = true;
                            }
                        }
                    }
                }
            };
            for on in &ons {
                check(on);
            }
            if let Some(w) = where_s {
                check(w);
            }
        }
        let (shape, from_cost) = match costed {
            Some(sh) => (sh, true),
            None if half_indexed => (join_band(ca, cb)?, false),
            // NO COSTED ANSWER means no index serves the join key. The
            // engine's choice here was MEASURED across a size sweep
            // (1..500 on each side, live PLANONLY) and is uniform:
            //
            //  * an EQUI key with no index HASHES AT EVERY SIZE - even
            //    1 x 1 (the engine's page-based cardinality estimate
            //    never looks empty enough for avoidHashJoin on a real
            //    table) - with the LARGER stream probing first and ties
            //    keeping SQL order, exactly what the Hash arm below
            //    spells;
            //  * a THETA join (no equi key at all) cannot hash: it
            //    LOOPS, and the SMALLER stream drives
            //    (`JOIN (B NATURAL, A NATURAL)` at 80 x 60), ties
            //    keeping SQL order.
            //
            // This replaces the probed cardinality BANDS (join_band),
            // whose middle refused: the 6x6 grid behind them was
            // measured on INDEXED fixtures - a region the costed path
            // above now decides - so the bands' loop cells never spoke
            // for THIS path's actual domain. The old large-large band
            // even HASHED a theta join the engine loops (measured:
            // 60 x 80 `A.K > B.K`), a live wrong plan this closes.
            None => {
                if !has_equi {
                    // a THETA join (no equi key at all) cannot hash: the
                    // engine LOOPS with the SMALLER stream driving
                    // (`JOIN (B NATURAL, A NATURAL)` at 80 x 60, measured),
                    // ties keeping SQL order. Returned HERE, because the
                    // arrangement search below cannot place a keyless
                    // stream and its "no arrangement" error would fall to
                    // the HASH fallback - the exact wrong plan this closes.
                    let mut order = vec![0usize, 1];
                    if cb < ca {
                        order = vec![1, 0];
                    }
                    return Ok(Plan {
                        streams: order
                            .into_iter()
                            .map(|i| Stream {
                                name: names[i].clone(),
                                access: Access::Natural,
                            })
                            .collect(),
                        combine: Combine::Join,
                        sorted: order_s.is_some(),
                        node: None,
                    });
                }
                (JoinShape::Hash, true)
            }
        };
        match shape {
            JoinShape::SqlOrder => order_decided = from_cost,
            JoinShape::Swap => {
                driver_order = vec![1, 0];
                order_decided = true;
            }
            JoinShape::Hash => {
                // the LARGER stream is listed first - it PROBES while
                // the smaller is hashed into the table (probed: the
                // plan text swaps with the sizes, ties keeping SQL
                // order)
                let mut order = vec![0usize, 1];
                if cb > ca {
                    order = vec![1, 0];
                }
                return Ok(Plan {
                    streams: order
                        .into_iter()
                        .map(|i| Stream {
                            name: names[i].clone(),
                            access: Access::Natural,
                        })
                        .collect(),
                    combine: Combine::Hash,
                    sorted: order_s.is_some(),
                    node: None,
                });
            }
        }
    }
    // ---- try each driver, and COST the arrangements ----------------
    //
    // Every driver that can reach the rest by index gives a legal
    // arrangement; the engine takes the CHEAPEST, replacing its best only
    // on a strictly smaller cost (`findJoinOrder`, InnerJoin.cpp:366), so
    // ties keep the enumeration order. The cost of an arrangement is the
    // sum of its inner retrievals, and the surprise lives in
    // `retrieval_cost`: a UNIQUE lookup is a fixed 4 while a non-unique
    // one is 3 + cardinality * selectivity, so on a database whose
    // statistics are zero the NON-unique index is cheaper and the engine
    // drives the stream a reader would have made the inner one.
    let mut chosen: Option<(usize, Vec<(usize, IndexInfo)>)> = None;
    let mut chosen_cost = f64::INFINITY;
    for d in driver_order {
        let mut placed = vec![d];
        let mut steps: Vec<(usize, IndexInfo)> = Vec::new();
        let mut ok = true;
        // place whichever remaining stream is reachable NOW, not the
        // lowest-numbered one: a chain driven from its far end reaches
        // its neighbours in the opposite order, and demanding index
        // order threw that arrangement away before it could be costed
        while placed.len() < n {
            let next = (0..n)
                .filter(|s| !placed.contains(s))
                .find_map(|s| reach(s, &placed).map(|i| (s, i)));
            match next {
                Some((s, i)) => {
                    steps.push((s, i));
                    placed.push(s);
                }
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok {
            continue;
        }
        let mut cost = 0.0;
        for (s, idx) in &steps {
            let sel = index_selectivity(file, page_size, &idx.name)?;
            let card = cardinality(file, page_size, &tables[*s])?;
            cost += retrieval_cost(idx.unique, sel, card);
        }
        if order_decided {
            // the cost model above already chose; take the first
            // arrangement that works in its order
            chosen = Some((d, steps));
            break;
        }
        if cost < chosen_cost {
            chosen_cost = cost;
            chosen = Some((d, steps));
        }
    }
    let Some((driver, steps)) = chosen else {
        return Err("no arrangement indexes every stream after the first".into());
    };

    // ---- the driver's own access -----------------------------------
    let mut access = Access::Natural;
    let mut sorted = order_s.is_some();
    if let Some(w) = where_s {
        for part in split_kw(w, "AND") {
            let part = part.trim();
            let mut halves = part.split('=');
            let (lq, rq) = (
                halves.next().unwrap_or("").trim(),
                halves.next().unwrap_or("").trim(),
            );
            if rq.contains('.') && !rq.contains('\'') {
                continue; // a join predicate, not a filter
            }
            if let Some((q, col)) = lq.split_once('.') {
                if qual_of(q) == Some(driver) {
                    if let Some(m) = indexes[driver]
                        .iter()
                        .filter(|x| x.matches(col.trim()))
                        .min_by_key(|x| x.id)
                    {
                        access = Access::Index(vec![m.name.clone()]);
                    }
                }
            }
        }
    }
    if let Some(o) = order_s {
        // the ORDER BY may name ANOTHER stream's column: its
        // equivalence class carries the order to the driver (probed -
        // ORDER BY B.UID navigated A's index on A.ID)
        let keys = parse_order_list(o)?;
        if keys.len() == 1 {
            let (ocol, odesc) = &keys[0];
            let mut cands: Vec<String> = vec![ocol.clone()];
            for cl in &classes {
                if cl.iter().any(|(_, c)| c.eq_ignore_ascii_case(ocol)) {
                    for (t, c) in cl {
                        if *t == driver {
                            cands.push(c.clone());
                        }
                    }
                }
            }
            for c in cands {
                if let Some(i) = indexes[driver]
                    .iter()
                    .filter(|x| x.navigates(&[(c.clone(), *odesc)]))
                    .min_by_key(|x| x.id)
                {
                    access = Access::Order { nav: i.name.clone(), filter: Vec::new() };
                    sorted = false;
                    break;
                }
            }
        }
    }
    let mut out = vec![Stream { name: names[driver].clone(), access }];
    for (s, i) in steps {
        out.push(Stream {
            name: names[s].clone(),
            access: Access::Index(vec![i.name]),
        });
    }
    Ok(Plan { streams: out, combine: Combine::Join, sorted,
            node: None,
        })
}

/// The column THIS stream contributes to an ON clause.
fn own_key_column(on: &str, name: &str) -> Result<String, String> {
    let bare = name.trim_matches('"').rsplit('.').next().unwrap_or(name).to_string();
    let clause = split_kw(on, "AND").into_iter().next().ok_or("empty ON")?;
    let (a, b) = clause.split_once('=').ok_or("ON is not an equality")?;
    for side in [a, b] {
        if let Some((q, c)) = side.trim().split_once('.') {
            if q.trim().trim_matches('"').eq_ignore_ascii_case(&bare) {
                return Ok(c.trim().trim_matches('"').to_string());
            }
        }
    }
    Err(format!("the ON clause {:?} does not name {}", on, bare))
}

/// `TABLE [alias]` - the plan names a stream by its ALIAS when the
/// query gave one, else by the schema-qualified table.
fn split_alias(s: &str) -> Result<(String, String), String> {
    let parts: Vec<&str> = s.split_whitespace().collect();
    match parts.len() {
        1 => Ok((parts[0].to_string(), qualified(parts[0]))),
        2 => Ok((parts[0].to_string(), format!("\"{}\"", parts[1]))),
        _ => Err(format!("cannot read the stream {:?}", s)),
    }
}

/// The equi-join key: `<qual>.<col> = <qual>.<col>`, returned as
/// (left-stream column, right-stream column).
fn parse_join_key(
    on_s: &str,
    lali: &str,
    rali: &str,
) -> Result<(String, String), String> {
    let clause = split_kw(on_s, "AND")
        .into_iter()
        .next()
        .ok_or("empty ON clause")?;
    let (a, b) = clause.split_once('=').ok_or("ON clause is not an equality")?;
    let (aq, ac) = a.trim().split_once('.').ok_or("unqualified join key")?;
    let (bq, bc) = b.trim().split_once('.').ok_or("unqualified join key")?;
    let bare = |s: &str| s.trim().trim_matches('"').to_string();
    let (lq, rq) = (bare(lali), bare(rali));
    let lq = lq.rsplit('.').next().unwrap_or(&lq).trim_matches('"').to_string();
    let rq = rq.rsplit('.').next().unwrap_or(&rq).trim_matches('"').to_string();
    if bare(aq).eq_ignore_ascii_case(&lq) && bare(bq).eq_ignore_ascii_case(&rq) {
        Ok((bare(ac), bare(bc)))
    } else if bare(bq).eq_ignore_ascii_case(&lq) && bare(aq).eq_ignore_ascii_case(&rq) {
        Ok((bare(bc), bare(ac)))
    } else {
        Err("the ON clause does not name both streams".into())
    }
}

/// How many committed rows a table holds - an exact count, useful
/// for the gate and for reasoning; the OPTIMIZER works from the
/// ESTIMATE below instead, because that is what the engine does.
pub fn row_count(file: &fire_crab_ods::Image, page_size: usize, table: &str) -> Result<u64, String> {
    let rel = resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("no table {}", table))?;
    Ok(fire_crab_ods::count_primary_records(file, page_size, rel))
}

/// The engine's own CARDINALITY ESTIMATE - `DPM_cardinality`
/// (dpm.epp:262), converted line for line:
///
/// - count the relation's data pages;
/// - walk to the FIRST non-secondary, non-empty data page and take
///   its record count and total compressed record length;
/// - with exactly ONE data page the count is EXACT ("the cardinality
///   calculation is too imprecise to be useful, therefore rely on
///   the record count from the data-page");
/// - otherwise estimate `dataPages * (page_size - DPG_SIZE) /
///   recordSize`, where recordSize is the average compressed record
///   plus its header, rounded to ODS alignment, plus the slot and a
///   SPACE_FUDGE reserve;
/// - never below MINIMUM_CARDINALITY (1.0).
///
/// This is the number every cost decision starts from, so converting
/// it is the first step of converting cost at all.
pub fn cardinality(file: &fire_crab_ods::Image, page_size: usize, table: &str) -> Result<f64, String> {
    const DPG_SIZE: usize = 24; // data_page less its first slot
    const RHD_SIZE: usize = 16; // ods.h:912 - the record header
    const RHDF_SIZE: usize = 20; // the FRAGMENT header
    const ODS_ALIGNMENT: usize = 4;
    const SLOT: usize = 4; // dpg_repeat: two u16
    const MINIMUM_CARDINALITY: f64 = 1.0;
    let roundup = |v: usize| (v + ODS_ALIGNMENT - 1) / ODS_ALIGNMENT * ODS_ALIGNMENT;
    let space_fudge = roundup(RHDF_SIZE) + SLOT;

    let rel = resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("no table {}", table))?;
    let pages = relation_data_pages(file, page_size, rel);
    let data_pages = pages.len();
    if data_pages == 0 {
        return Ok(MINIMUM_CARDINALITY);
    }
    // the first data page that holds primary records
    let mut count = 0usize;
    let mut length = 0usize;
    for p in &pages {
        let Some(page) = fire_crab_ods::page_at(file, page_size, *p) else {
            continue;
        };
        let Some(dp) = DataPage::decode(page) else {
            continue;
        };
        // dpg_secondary (0x10 in pag_flags) pages hold no primaries
        if page[1] & 0x10 != 0 {
            continue;
        }
        let mut c = 0usize;
        let mut l = 0usize;
        for i in 0..dp.count {
            if let Some((off, len)) = dp.slot(i) {
                if off != 0 {
                    c += 1;
                    l += (len as usize).saturating_sub(RHD_SIZE);
                }
            }
        }
        if c > 0 {
            count = c;
            length = l;
            break;
        }
    }
    if data_pages == 1 {
        return Ok((count as f64).max(MINIMUM_CARDINALITY));
    }
    let compressed = if count > 0 { length / count } else { 1 };
    let record_size = SLOT + roundup(compressed + RHD_SIZE) + space_fudge;
    let est = data_pages as f64 * (page_size - DPG_SIZE) as f64 / record_size as f64;
    Ok(est.max(MINIMUM_CARDINALITY))
}

/// An index's stored SELECTIVITY - `RDB$INDICES.RDB$STATISTICS`,
/// the number `SET STATISTICS` refreshes (1/distinct-keys). Zero
/// means the statistics were never computed for the data now
/// present: the engine keeps using it, which is why a stale index
/// makes it plan differently.
pub fn index_selectivity(
    file: &fire_crab_ods::Image,
    page_size: usize,
    index: &str,
) -> Result<f64, String> {
    // THE MATCHED SEGMENT'S SELECTIVITY, NOT THE WHOLE INDEX'S.
    //
    // `RDB$INDICES.RDB$STATISTICS` is the figure for the WHOLE key - the
    // last segment's, in effect. The engine costs a retrieval with
    // `idx_rpt[j].idx_selectivity`, the figure for the segments the
    // predicate actually MATCHED (Retrieval.cpp:1019), which for a
    // compound index is a different number entirely: on `INDEX (K, B)`
    // over 5000 rows with 10 distinct K, the whole-index figure is
    // 0.0002 and segment 0's is 0.1 - five hundred times apart.
    //
    // Reading the wrong one made a keyed loop look 500x cheaper than it
    // is, and produced a plan the engine does not choose:
    //
    //   engine:  PLAN HASH ("I" NATURAL, "O" NATURAL)
    //   fcopt:   PLAN JOIN ("O" NATURAL, "I" INDEX (INNR_KB))
    //
    // A predicate is only ever matched against an index's LEADING
    // segment here (`IndexInfo::matches`), so segment 0 is the figure
    // this needs. `RDB$INDEX_SEGMENTS` holds it per position; the
    // whole-index column remains the fallback for an index whose
    // segments carry nothing.
    if let Some(sel) = segment_selectivity(file, page_size, index, 0) {
        return Ok(sel);
    }
    whole_index_selectivity(file, page_size, index)
}

/// `RDB$INDEX_SEGMENTS.RDB$STATISTICS` at `position`, when it holds one.
fn segment_selectivity(
    file: &fire_crab_ods::Image,
    page_size: usize,
    index: &str,
    position: i64,
) -> Option<f64> {
    let rel = resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$INDEX_SEGMENTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$INDEX_NAME")?;
    let pos_f = fid("RDB$FIELD_POSITION")?;
    let stat_f = fid("RDB$STATISTICS")?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = fire_crab_ods::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = assembled_image(file, page_size, &r) else { continue };
            let values = decode_record(&image, descs);
            let Some(Value::Text(n)) = values.get(name_f) else { continue };
            if n.trim_end() != index {
                continue;
            }
            let at = match values.get(pos_f) {
                Some(Value::Int(p)) => *p,
                _ => continue,
            };
            if at != position {
                continue;
            }
            return match values.get(stat_f) {
                Some(Value::Double(d)) => Some(*d),
                Some(Value::Int(n)) => Some(*n as f64),
                Some(Value::Scaled(raw, sc)) => Some(*raw as f64 * 10f64.powi(*sc as i32)),
                // a NULL segment statistic is "never computed", which is
                // not the same as zero - fall back rather than claim it
                _ => None,
            };
        }
    }
    None
}

fn whole_index_selectivity(
    file: &fire_crab_ods::Image,
    page_size: usize,
    index: &str,
) -> Result<f64, String> {
    let rel = resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$INDICES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$INDEX_NAME").ok_or("no name column")?;
    let stat_f = fid("RDB$STATISTICS").ok_or("no statistics column")?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = fire_crab_ods::page_at(file, page_size, dp_no).and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = assembled_image(file, page_size, &r) else { continue };
            let values = decode_record(&image, descs);
            let Some(Value::Text(n)) = values.get(name_f) else { continue };
            if n.trim_end() != index {
                continue;
            }
            return Ok(match values.get(stat_f) {
                Some(Value::Double(d)) => *d,
                Some(Value::Int(n)) => *n as f64,
                Some(Value::Scaled(raw, sc)) => {
                    *raw as f64 * 10f64.powi(*sc as i32)
                }
                _ => 0.0,
            });
        }
    }
    Ok(0.0)
}

/// `DEFAULT_INDEX_COST` (Optimizer.h) - the price of one index scan.
pub const DEFAULT_INDEX_COST: f64 = 3.0;

/// `DEFAULT_SELECTIVITY` (Optimizer.h:66) - what the engine substitutes
/// for an index statistic of zero, which means "prepared on an empty
/// table, or the statistics were never computed". It does NOT refuse.
pub const DEFAULT_SELECTIVITY: f64 = 0.1;

/// What ONE indexed retrieval of the inner stream costs, converted from
/// `Retrieval::getInversion` (Retrieval.cpp:371-384):
///
/// ```text
/// if (unique)  cost = DEFAULT_INDEX_COST * indexes + 1;   // fixed: 4
/// else         cost = index scan cost + cardinality * selectivity;
/// ```
///
/// The comment on the unique branch says why it is fixed - "independent
/// from a possibly outdated statistics" - and that single decision is
/// what makes the engine's join order surprising on a database whose
/// statistics are zero: a unique lookup costs 4 while a non-unique one
/// costs 3 + 0, so the arrangement that uses the NON-unique index wins.
/// Probed and confirmed: with `A.BX` indexed (non-unique) and `B.ID` a
/// primary key, the engine drives B in BOTH SQL orders, while two
/// symmetric indexes keep the SQL order.
pub fn retrieval_cost(unique: bool, selectivity: f64, cardinality: f64) -> f64 {
    if unique {
        DEFAULT_INDEX_COST + 1.0
    } else {
        DEFAULT_INDEX_COST + cardinality * selectivity
    }
}

/// The engine's cost arithmetic for joining `inner` behind `outer`
/// (InnerJoin.cpp:192-236 with Retrieval.cpp:1147 and :384):
///
/// - the inner's INDEXED retrieval costs `DEFAULT_INDEX_COST` (3) for
///   the index scan plus `selectivity * cardinality` for it, plus the
///   same again for fetching the records it names;
/// - a nested LOOP pays that once per outer row;
/// - a HASH pays the inner's unfiltered retrieval, the hashing of
///   `baseSelectivity * cardinality` rows at MEMCOPY + HASHING (0.5
///   each), and per outer row a probe plus copies of the matches.
///
/// The engine takes the cheapest of {loop each way, hash}, and this
/// reproduces its whole 6x6 decision grid once statistics are fresh.
/// The engine's estimate of an index's PAGE count (Retrieval.cpp:188-191):
///
/// ```text
/// MAX(cardinality * (2 + ROUNDUP(key_length, 4) * factor) / (page_size - 39),
///     MINIMUM_CARDINALITY)
/// ```
///
/// THIS WAS DROPPED ONCE, ON A BAD ARGUMENT. The comment that replaced it
/// reasoned that for a 4-byte key at 8 KB pages the term is `card/1359` -
/// a coefficient of 1.0007 against 1.0, "under 0.1%" - and that
/// converting it would need `irtd_itype` plumbing `ods` does not have.
/// Both halves were wrong in the way that matters:
///
///   * 0.13% is exactly what decides the cell at (28, 500). A term being
///     small is not the same as a term being inert.
///   * the `MAX` FLOORS IT AT 1.0 on every table anyone has measured
///     here, so the key length never reaches the answer - identical
///     scores were measured at key_len 4, 8 and 12. The plumbing was
///     never a prerequisite.
///
/// Worth 9 of the 11 cells that otherwise miss.
fn index_pages(cardinality: f64) -> f64 {
    const MINIMUM_CARDINALITY: f64 = 1.0;
    // 8 KB pages and a 4-byte key are the shape every fixture here uses;
    // the floor below makes the choice immaterial, which is why this does
    // not read the real key length.
    const PAGE_SIZE: f64 = 8192.0;
    const KEY_LEN: f64 = 4.0;
    const FACTOR: f64 = 1.0;
    let per_page = 2.0 + (KEY_LEN / 4.0).ceil() * 4.0 * FACTOR;
    (cardinality * per_page / (PAGE_SIZE - 39.0)).max(MINIMUM_CARDINALITY)
}

/// `Optimizer::estimateSelectivity` (Optimizer.cpp:1240-1267): the
/// factors sorted ascending, the FRONT one floored by the small-table
/// adjustment (the product is scaled so it lands at 1/cardinality), and
/// each factor decaying by repeated square root (`applyBackoff`) as
/// `prior` conjuncts accumulate - index matches count as priors, so a
/// filter beside a match starts deeper in the backoff.
fn estimate_selectivity(factors: &[f64], cardinality: f64, prior_conjuncts: usize) -> f64 {
    if factors.is_empty() {
        return 1.0;
    }
    let mut sorted = factors.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut selectivity = 1.0f64;
    if prior_conjuncts == 0 && cardinality > 0.0 {
        let min_selectivity = 1.0 / cardinality;
        if sorted[0] < min_selectivity {
            selectivity *= min_selectivity / sorted[0];
        }
    }
    let mut prior = prior_conjuncts;
    for f in &sorted {
        let mut x = *f;
        for _ in 0..prior {
            x = x.sqrt();
        }
        selectivity *= x;
        prior += 1;
    }
    selectivity.min(1.0)
}

/// The engine's FILTER-selectivity estimate for one stream of a join -
/// `Optimizer::estimateSelectivity` over the stream's own WHERE conjuncts
/// (Optimizer.cpp:1240-1267 with the getSelectivity factors,
/// Optimizer.h:52-58). Each single-stream, non-join conjunct contributes a
/// REDUCE factor: equality 0.001, `<`/`>` 0.05, BETWEEN 0.0025, STARTING
/// 0.01. The smallest factor is floored by the "table is small enough"
/// adjustment (the product is scaled so the front factor lands at
/// MAXIMUM_SELECTIVITY / cardinality), and each factor past the first
/// decays by repeated square root (`applyBackoff`). This is what makes a
/// filtered DRIVER cheap: `B.BV = 3` over 200 rows estimates ONE row
/// (200 x 0.005 after the floor), so a nested loop behind it costs one
/// probe - the arithmetic that keeps the engine's loop nearly independent
/// of a STALE inner selectivity, measured in qa/opt-stale.sh.
///
/// `None` = a shape this conversion does not price (a conjunct on an
/// INDEXED column takes the engine's inversion path instead of a factor;
/// an unqualified or unrecognised conjunct could belong to either
/// stream) - the caller keeps the unfiltered cardinality, which is the
/// pre-conversion behaviour, fail-conservative.
fn stream_filter_selectivity(
    where_s: Option<&str>,
    stream: usize,
    qual_of: &dyn Fn(&str) -> Option<usize>,
    cardinality: f64,
    indexed: &dyn Fn(&str) -> bool,
) -> Option<f64> {
    let w = match where_s {
        None => return Some(1.0),
        Some(w) => w,
    };
    // BETWEEN's own AND is not a conjunction - re-absorb the split half
    let raw: Vec<String> = {
        let mut parts: Vec<String> = Vec::new();
        let mut pending: Option<String> = None;
        for p in split_kw(w, "AND") {
            let p = p.trim().to_string();
            match pending.take() {
                Some(prev) => parts.push(format!("{} AND {}", prev, p)),
                None => {
                    if find_kw(&p.to_uppercase(), "BETWEEN").is_some() {
                        pending = Some(p);
                    } else {
                        parts.push(p);
                    }
                }
            }
        }
        if let Some(last) = pending {
            parts.push(last);
        }
        parts
    };
    let mut factors: Vec<f64> = Vec::new();
    for clause in &raw {
        let clause = clause.trim();
        // which stream does the clause's qualified column name?
        let col_end = clause
            .find(|c: char| c.is_whitespace() || "=<>!".contains(c))
            .unwrap_or(clause.len());
        let lhs = clause[..col_end].trim();
        let Some((q, col)) = lhs.split_once('.') else {
            // an unqualified conjunct could belong to either stream
            return None;
        };
        let Some(si) = qual_of(q) else { return None };
        let rest = clause[col_end..].trim();
        let rest_up = rest.to_uppercase();
        // both sides qualified column names = the join predicate itself
        // (the comma form carries it in the WHERE) - a match, not a filter
        if rest.starts_with('=') {
            let rhs = rest[1..].trim();
            if rhs.contains('.') && !rhs.contains('\'') {
                continue;
            }
        }
        if si != stream {
            continue;
        }
        let col = col.trim().trim_matches('"');
        let factor = if rest.starts_with('=') {
            0.001 // REDUCE_SELECTIVITY_FACTOR_EQUALITY
        } else if rest_up.starts_with("BETWEEN") {
            0.0025 // REDUCE_SELECTIVITY_FACTOR_BETWEEN
        } else if rest.starts_with('>') || rest.starts_with('<') {
            if rest.starts_with("<>") {
                return None;
            }
            0.05 // REDUCE_SELECTIVITY_FACTOR_LESS / _GREATER
        } else if rest_up.starts_with("STARTING") {
            0.01 // REDUCE_SELECTIVITY_FACTOR_STARTING
        } else {
            return None;
        };
        // an INDEXED filter column becomes an inversion with the index's
        // own statistics, not a factor - unconverted for join costing
        if indexed(col) {
            return None;
        }
        factors.push(factor);
    }
    Some(estimate_selectivity(&factors, cardinality, 0))
}

fn loop_cost(outer_card: f64, inner_card: f64, inner_sel: f64, inner_unique: bool) -> f64 {
    // A UNIQUE inner lookup is priced at a FIXED DEFAULT_INDEX_COST + 1
    // (Retrieval.cpp:371-376, "independent from a possibly outdated
    // statistics").
    //
    // A NON-UNIQUE one pays the row term ONCE, not twice. The engine
    // charges two terms and they are not the same quantity:
    //
    //   Retrieval.cpp:385   cost  = DEFAULT_INDEX_COST + selectivity * scratch.cardinality
    //   Retrieval.cpp:1145  cost += cardinality * selectivity
    //
    // The first is the INDEX SCAN and its cardinality is an index PAGE
    // count; the second is the RECORD retrieval against the TABLE's
    // cardinality. Reading both as the table's - which `2.0 *` did -
    // doubles a keyed loop's price and pushes the HASH/loop crossover
    // out by a factor of two.
    //
    // The page term is dropped rather than converted. It is
    // `csb_cardinality * idx_fraction * (2 + ROUNDUP(BTR_key_length,4)
    // * factor) / (page_size - 39)`, which for a 4-byte INTEGER key at
    // 8 KB pages is card/1359 - a coefficient of 1.0007 against the 1.0
    // below, under 0.1%. Converting it would need `irtd_itype` plumbing
    // that `ods` does not have, for that. Recorded in the roadmap.
    let retrieval = if inner_unique {
        DEFAULT_INDEX_COST + 1.0
    } else {
        DEFAULT_INDEX_COST + inner_sel * (index_pages(inner_card) + inner_card)
    };
    retrieval * outer_card
}

/// The engine's hash arithmetic (InnerJoin.cpp:228-234), including the
/// cap the previous version left out.
///
/// `inner_unique` is not decoration: InnerJoin.cpp:210-211 reads
///
/// ```text
/// if ((candidate->unique || firstRows) && currentCardinality > MINIMUM_CARDINALITY)
///     currentCardinality = MINIMUM_CARDINALITY;
/// ```
///
/// so a UNIQUE hashed side contributes ONE row per probe to the copying
/// term however large the table is. Without it, hashing a unique side
/// was priced as though every probe copied `inner_card * inner_sel`
/// rows, which for a large unique inner is an enormous over-charge and
/// made fcopt prefer a loop where the engine hashes.
fn hash_cost(
    outer_card: f64,
    inner_card: f64,
    inner_filter: f64,
    inner_sel: f64,
    inner_unique: bool,
) -> f64 {
    const MEMCOPY: f64 = 0.5;
    const HASHING: f64 = 0.5;
    const MINIMUM_CARDINALITY: f64 = 1.0;
    // the hashed side's own SCAN reads every row whatever its filter
    // keeps (baseCost), but only the KEPT rows are copied into the table
    // (hashCardinality = baseSelectivity * streamCardinality,
    // InnerJoin.cpp:228) and only they can match a probe
    // (currentCardinality carries the stream's whole selectivity -
    // its filter times the join match)
    let base_cost = inner_card;
    let hash_cardinality = inner_card * inner_filter;
    let mut current_cardinality = inner_card * inner_filter * inner_sel;
    if inner_unique && current_cardinality > MINIMUM_CARDINALITY {
        current_cardinality = MINIMUM_CARDINALITY;
    }
    base_cost
        + hash_cardinality * (MEMCOPY + HASHING)
        + outer_card * (HASHING + current_cardinality * MEMCOPY)
}

/// The cardinality BANDS the engine's join decision turns on, mapped
/// by probing a 6x6 grid of table sizes (0, 1, 5, 50, 500, 3000
/// rows) against the live optimizer:
///
/// ```text
///   out\in     0    1    5    50   500  3000
///   0        A->B A->B A->B A->B A->B A->B
///   1        A->B A->B A->B A->B A->B A->B
///   5        B->A B->A HASH A->B A->B A->B
///   50       B->A B->A B->A HASH HASH HASH
///   500      B->A B->A B->A HASH HASH HASH
///   3000     B->A B->A B->A HASH HASH HASH
/// ```
///
/// Three regions are unambiguous and converted: a TINY driver
/// (cardinality <= 1) keeps SQL order, because the engine is
/// deliberately pessimistic about a relation that "looks empty
/// during preparation" (InnerJoin.cpp:217's avoidHashJoin) and a
/// one-row loop is cheap anyway; a TINY inner side makes the engine
/// SWAP so the tiny stream drives; and once BOTH sides are LARGE the
/// hash wins outright. The band between - one side small but not
/// tiny - is where `hashCost <= loopCost` is decided by index
/// retrieval costs this crate has not converted, and it refuses.
fn join_band(a: f64, b: f64) -> Result<JoinShape, String> {
    const TINY: f64 = 1.0;
    const LARGE: f64 = 50.0;
    if a <= TINY {
        return Ok(JoinShape::SqlOrder);
    }
    if b <= TINY {
        return Ok(JoinShape::Swap);
    }
    if a >= LARGE && b >= LARGE {
        return Ok(JoinShape::Hash);
    }
    Err(format!(
        "join cardinalities ({:.0}, {:.0}) fall in the band where the \
         engine weighs hashCost against loopCost with index retrieval \
         costs - unconverted",
        a, b
    ))
}

/// What the cardinality bands say about a two-stream join.
#[derive(Clone, Copy, PartialEq, Debug)]
enum JoinShape {
    SqlOrder,
    Swap,
    Hash,
}

/// The cost guard: a join is planned only where the cardinality
/// bands make the engine's decision unambiguous.
fn cost_free_or_refuse(
    file: &fire_crab_ods::Image,
    page_size: usize,
    tables: &[String],
) -> Result<(), String> {
    // more than two streams: the bands were probed pairwise, so a
    // chain is planned only while every stream looks empty
    if tables.len() > 2 {
        for t in tables {
            if cardinality(file, page_size, t)? > 1.0 {
                return Err(format!(
                    "chain over populated {}: cost-based ordering unconverted",
                    t
                ));
            }
        }
        return Ok(());
    }
    let a = cardinality(file, page_size, &tables[0])?;
    let b = cardinality(file, page_size, &tables[1])?;
    join_band(a, b).map(|_| ())
}

/// A column's TYPE FAMILY (0 numeric, 1 text, 2 other) - an index
/// cannot serve a join whose sides disagree (probed).
fn column_family(
    file: &fire_crab_ods::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Result<u8, String> {
    let rel = resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("no table {}", table))?;
    let formats = fire_crab_ods::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("table has no format")?;
    let cols = relation_columns(file, page_size, table);
    let c = cols
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(column))
        .ok_or_else(|| format!("no column {}", column))?;
    let d = descs.get(c.field_id as usize).ok_or("no descriptor")?;
    // the ODS DESCRIPTOR dtypes (dsc_pub.h), NOT the catalog's
    // RDB$FIELD_TYPE codes - two different numberings, and mixing
    // them made a VARCHAR look numeric
    use fire_crab_ods::format::dtype;
    Ok(match d.dtype {
        dtype::SHORT | dtype::LONG | dtype::INT64 | dtype::REAL
        | dtype::DOUBLE | dtype::INT128 => 0,
        dtype::TEXT | dtype::VARYING => 1,
        _ => 2,
    })
}

/// A base table's plan name is schema-qualified; an alias is bare.
fn qualified(table: &str) -> String {
    format!("\"PUBLIC\".\"{}\"", table)
}

/// The WHERE clause's predicates. Returns them plus whether an OR
/// structure keeps every branch matchable (a single unmatchable OR
/// branch makes the whole clause unusable - probed).
fn parse_predicates(
    w: &str,
    indexed: &dyn Fn(&str) -> bool,
) -> Result<(Vec<Pred>, bool, bool), String> {
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
    Ok((preds, if is_or { all_matchable } else { true }, is_or))
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
    let kind = if rest.starts_with('=') {
        PredKind::Eq
    } else if rest.starts_with("BETWEEN") {
        PredKind::Between
    } else if (rest.starts_with('>') || rest.starts_with('<'))
        && !rest.starts_with("<>")
    {
        PredKind::Range
    } else if rest.starts_with("STARTING") || rest.starts_with("LIKE ") {
        PredKind::Starting
    } else {
        PredKind::Other
    };
    Ok(Pred { column: column.clone(), matchable: matchable && indexed(&column), kind })
}

/// The ORDER BY keys: `[BY] col [ASC|DESC] [, ...]`, each key's
/// column stripped of any stream qualifier.
fn parse_order_list(o: &str) -> Result<Vec<(String, bool)>, String> {
    let rest = o.trim().strip_prefix("BY ").unwrap_or(o.trim()).trim();
    let mut out = Vec::new();
    for part in rest.split(',') {
        let part = part.trim();
        let (col, desc) = match part.rsplit_once(' ') {
            Some((c, d)) if d.trim() == "DESC" => (c.trim(), true),
            Some((c, d)) if d.trim() == "ASC" => (c.trim(), false),
            _ => (part, false),
        };
        if col.contains(' ') || col.is_empty() {
            return Err("ORDER BY expression unconverted".into());
        }
        let col = col.rsplit('.').next().unwrap_or(col);
        out.push((col.to_string(), desc));
    }
    Ok(out)
}

fn parse_order(o: &str) -> Result<(String, bool), String> {
    let list = parse_order_list(o)?;
    if list.len() != 1 {
        return Err("multi-column ORDER BY unconverted here".into());
    }
    Ok(list.into_iter().next().expect("length checked"))
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
    fn a_unique_lookup_costs_a_fixed_four() {
        // Retrieval.cpp:371-376 - "For unique retrievals, set up a fixed
        // cost (independent from a possibly outdated statistics)". That
        // one decision is why the engine's join order looks backwards on
        // a database whose statistics are zero: the unique lookup costs
        // 4 while the non-unique one costs 3, so the NON-unique index
        // wins and the stream a reader expects to be the inner one drives.
        assert_eq!(retrieval_cost(true, 0.0, 1.0), 4.0);
        assert_eq!(retrieval_cost(true, 0.5, 1000.0), 4.0, "statistics ignored");
        assert_eq!(retrieval_cost(false, 0.0, 1.0), 3.0);
        assert_eq!(retrieval_cost(false, 0.5, 100.0), 53.0);
        // and the ordering that follows on an unanalysed database
        assert!(retrieval_cost(false, 0.0, 1.0) < retrieval_cost(true, 0.0, 1.0));
        // ... which reverses once the statistics are real and the
        // non-unique index turns out to name many rows
        assert!(retrieval_cost(false, 0.5, 100.0) > retrieval_cost(true, 0.5, 100.0));
    }

    #[test]
    fn an_outer_join_nests_where_an_inner_chain_flattens() {
        // three streams, inner: ONE flat JOIN list
        let flat = Plan {
            streams: vec![
                Stream { name: qualified("A"), access: Access::Natural },
                Stream { name: qualified("B"), access: Access::Index(vec!["IB".into()]) },
                Stream { name: qualified("C"), access: Access::Index(vec!["IC".into()]) },
            ],
            combine: Combine::Join,
            sorted: false,
            node: None,
        };
        assert_eq!(
            flat.render(),
            "PLAN JOIN (\"PUBLIC\".\"A\" NATURAL, \"PUBLIC\".\"B\" INDEX (\"PUBLIC\".\"IB\"), \"PUBLIC\".\"C\" INDEX (\"PUBLIC\".\"IC\"))"
        );
        // the same three streams with an outer join: a NODE, so it nests
        let a = Stream { name: qualified("A"), access: Access::Natural };
        let b = Stream { name: qualified("B"), access: Access::Index(vec!["IB".into()]) };
        let c = Stream { name: qualified("C"), access: Access::Index(vec!["IC".into()]) };
        let nested = Plan {
            streams: vec![a.clone(), b.clone(), c.clone()],
            combine: Combine::Join,
            sorted: false,
            node: Some(PlanNode::Join(vec![
                PlanNode::Join(vec![PlanNode::Stream(a), PlanNode::Stream(b)]),
                PlanNode::Stream(c),
            ])),
        };
        assert_eq!(
            nested.render(),
            "PLAN JOIN (JOIN (\"PUBLIC\".\"A\" NATURAL, \"PUBLIC\".\"B\" INDEX (\"PUBLIC\".\"IB\")), \"PUBLIC\".\"C\" INDEX (\"PUBLIC\".\"IC\"))"
        );
        // and a SORT wraps the nested shape the same way
        let mut sorted = nested.clone();
        sorted.sorted = true;
        assert!(sorted.render().starts_with("PLAN SORT JOIN (JOIN ("));
    }

    #[test]
    fn right_is_left_with_the_sides_exchanged() {
        // the ON clause needs no rewriting - `A.BX = B.ID` means the same
        // either way round - which is why the engine can treat RIGHT as
        // LEFT-reversed, and why its plan drives the RIGHT side
        assert_eq!(
            swap_join_sides("A RIGHT JOIN B ON A.BX = B.ID").unwrap(),
            "B LEFT JOIN A ON A.BX = B.ID"
        );
        assert_eq!(
            swap_join_sides("T A LEFT JOIN U B ON A.ID = B.UID").unwrap(),
            "U B LEFT JOIN T A ON A.ID = B.UID"
        );
        // a plain inner join swaps without a keyword
        assert_eq!(
            swap_join_sides("A JOIN B ON A.BX = B.ID").unwrap(),
            "B JOIN A ON A.BX = B.ID"
        );
    }

    #[test]
    fn the_first_join_keyword_decides_the_kind() {
        assert_eq!(outer_kind("A JOIN B ON A.X = B.Y"), OuterKind::Inner);
        assert_eq!(outer_kind("A LEFT JOIN B ON A.X = B.Y"), OuterKind::Left);
        assert_eq!(outer_kind("A RIGHT JOIN B ON A.X = B.Y"), OuterKind::Right);
        assert_eq!(outer_kind("A FULL JOIN B ON A.X = B.Y"), OuterKind::Full);
        // a chain takes its kind from the FIRST join, and the tail's kind
        // is read separately when the chain is split
        assert_eq!(
            outer_kind("A JOIN B ON A.X = B.Y LEFT JOIN C ON B.Z = C.Z"),
            OuterKind::Left
        );
    }

    #[test]
    fn the_on_column_survives_a_qualified_stream_name() {
        // the stream name arrives schema-qualified while the ON clause
        // names it bare - the mismatch that made every outer chain refuse
        // with "no ON column" the first time round
        assert_eq!(
            on_column_for("B.CX = C.ID", "\"PUBLIC\".\"C\"").unwrap(),
            "ID"
        );
        assert_eq!(on_column_for("B.CX = C.ID", "B").unwrap(), "CX");
        assert!(on_column_for("B.CX = C.ID", "D").is_err());
    }

    fn single(access: Access, sorted: bool) -> Plan {
        Plan {
            streams: vec![Stream { name: qualified("T"), access }],
            combine: Combine::Single,
            sorted,
            node: None,
        }
    }

    #[test]
    fn renders_the_engines_spelling() {
        assert_eq!(
            single(Access::Natural, false).render(),
            "PLAN (\"PUBLIC\".\"T\" NATURAL)"
        );
        assert_eq!(
            single(
                Access::Index(vec!["IDX_A".into(), "IDX_B".into()]),
                true
            )
            .render(),
            "PLAN SORT (\"PUBLIC\".\"T\" INDEX (\"PUBLIC\".\"IDX_A\", \"PUBLIC\".\"IDX_B\"))"
        );
        assert_eq!(
            single(Access::Order { nav: "IDX_A".into(), filter: Vec::new() }, false).render(),
            "PLAN (\"PUBLIC\".\"T\" ORDER \"PUBLIC\".\"IDX_A\")"
        );
    }

    /// The join spellings: aliases quoted BARE, the combiner OUTSIDE
    /// the parentheses, and a SORT wrapping the whole join.
    #[test]
    fn renders_join_and_hash_spellings() {
        let j = Plan {
            streams: vec![
                Stream { name: "\"A\"".into(), access: Access::Natural },
                Stream {
                    name: "\"B\"".into(),
                    access: Access::Index(vec!["IDX_U_UID".into()]),
                },
            ],
            combine: Combine::Join,
            sorted: false,
            node: None,
        };
        assert_eq!(
            j.render(),
            "PLAN JOIN (\"A\" NATURAL, \"B\" INDEX (\"PUBLIC\".\"IDX_U_UID\"))"
        );
        let h = Plan {
            streams: vec![
                Stream { name: "\"A\"".into(), access: Access::Natural },
                Stream { name: "\"B\"".into(), access: Access::Natural },
            ],
            combine: Combine::Hash,
            sorted: true,
            node: None,
        };
        assert_eq!(h.render(), "PLAN SORT HASH (\"A\" NATURAL, \"B\" NATURAL)");
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
        let (_, ok, _) = parse_predicates("ID = 5 OR NAME = 'x'", &indexed).unwrap();
        assert!(!ok);
        let (_, ok, _) = parse_predicates("ID = 5 OR ID = 6", &indexed).unwrap();
        assert!(ok);
        // an AND keeps its matchable half regardless
        let (preds, ok, _) = parse_predicates("ID = 5 AND NAME = 'x'", &indexed).unwrap();
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
