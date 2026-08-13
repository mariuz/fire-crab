//! Metadata resolution - the piece the engine's `MET`/`metd` layer does
//! from the system catalog. To turn a table *name* from a query into the
//! relation id the storage layer walks, we read `RDB$RELATIONS`
//! (relation 6) straight from its data pages.
//!
//! `RDB$RELATIONS` is bootstrap metadata: its own record format is not in
//! `RDB$FORMATS` (system relations are formatted by the engine at
//! creation, not through the catalog), so - exactly as `format.rs`
//! hardcodes the `RDB$FORMATS` system format - we hardcode the two field
//! offsets we need. Both were confirmed against the live engine across
//! every database tested (name->id identical to
//! `SELECT RDB$RELATION_ID, RDB$RELATION_NAME FROM RDB$RELATIONS`):
//!
//!   RDB$RELATION_ID   SHORT       at record-image offset 32
//!   RDB$RELATION_NAME CHAR(252)   at record-image offset 42
//!
//! (252 = CHAR(63) in a 4-byte-per-char UTF8 metadata database, space
//! padded.) Reading by fixed offset avoids the null-bitmap bookkeeping a
//! partial descriptor list would need; neither field is ever null.

use crate::data::{flags, DataPage};
use crate::pointer::relation_data_pages;

/// `RDB$RELATIONS` - the relation whose rows name every relation.
pub const REL_RELATIONS: u16 = 6;
/// `RDB$RELATION_FIELDS` - the relation whose rows name every column.
pub const REL_RELATION_FIELDS: u16 = 5;

const RELATION_ID_OFFSET: usize = 32;
const RELATION_NAME_OFFSET: usize = 42;
pub(crate) const RELATION_NAME_LEN: usize = 252;

// Field offsets in the RDB$RELATION_FIELDS record image, hardcoded the
// same way and for the same reason as the RDB$RELATIONS offsets above
// (system relation, not in RDB$FORMATS). All confirmed against the live
// engine: reading these reproduces
//   SELECT RDB$RELATION_NAME, RDB$FIELD_NAME, RDB$FIELD_ID FROM RDB$RELATION_FIELDS
// identically across every database tested.
//
//   RDB$FIELD_NAME     CHAR(252) at offset 4
//   RDB$RELATION_NAME  CHAR(252) at offset 256    (= 4 + 252)
//   RDB$FIELD_POSITION SHORT     at offset 1394
//   RDB$FIELD_ID       SHORT     at offset 1410
//
// RDB$FIELD_ID is the index the stored record format lays columns out by,
// and therefore the index into `decode_record`'s output. It is NOT the
// same as RDB$FIELD_POSITION (the column's ordinal in the table): when a
// table mixes column widths the engine reorders fields physically by
// alignment, so a BIGINT declared after an INTEGER gets a lower field id.
// The two coincide only for uniform-width tables - which is why the
// distinction is easy to miss and must be got right. FIELD_POSITION
// (offset 1394) gives the SELECT * / declaration order.
const RF_FIELD_NAME_OFFSET: usize = 4;
const RF_RELATION_NAME_OFFSET: usize = 256;
const RF_FIELD_POSITION_OFFSET: usize = 1394;
const RF_FIELD_ID_OFFSET: usize = 1410;
const RF_NAME_LEN: usize = 252;

/// Read one `RDB$RELATIONS` record image into (relation id, trimmed name).
fn relation_row(image: &[u8]) -> Option<(u16, String)> {
    if image.len() < RELATION_NAME_OFFSET + RELATION_NAME_LEN {
        return None;
    }
    let id = u16::from_le_bytes([image[RELATION_ID_OFFSET], image[RELATION_ID_OFFSET + 1]]);
    let raw = &image[RELATION_NAME_OFFSET..RELATION_NAME_OFFSET + RELATION_NAME_LEN];
    let name = String::from_utf8_lossy(raw);
    let name = name.trim_end_matches(|c| c == ' ' || c == '\0').to_string();
    if name.is_empty() {
        return None;
    }
    Some((id, name))
}

/// Every (relation id, name) pair in the database, read from the raw
/// `RDB$RELATIONS` data pages - the from-file mirror of
/// `SELECT RDB$RELATION_ID, RDB$RELATION_NAME FROM RDB$RELATIONS`.
pub fn list_relations(file: &crate::Image, page_size: usize) -> Vec<(u16, String)> {
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, REL_RELATIONS) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            if let Some(image) = crate::data::assembled_image(file, page_size, &r) {
                if let Some(row) = relation_row(&image) {
                    out.push(row);
                }
            }
        }
    }
    out
}

/// Resolve a table name to its relation id (case-insensitive, matching
/// the engine's unquoted-identifier folding). Returns None if no relation
/// of that name exists.
pub fn resolve_relation(file: &crate::Image, page_size: usize, name: &str) -> Option<u16> {
    let want = name.trim();
    for (id, rel_name) in list_relations(file, page_size) {
        if rel_name.eq_ignore_ascii_case(want) {
            return Some(id);
        }
    }
    None
}

/// One column of a relation: its name, the field id that indexes the
/// stored record format (and hence `decode_record`'s output), and its
/// position (declaration ordinal, the SELECT * order).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelationColumn {
    pub name: String,
    pub field_id: u16,
    pub position: u16,
}

fn cstr(image: &[u8], off: usize) -> Option<String> {
    if image.len() < off + RF_NAME_LEN {
        return None;
    }
    let raw = &image[off..off + RF_NAME_LEN];
    let s = String::from_utf8_lossy(raw);
    let s = s.trim_end_matches(|c| c == ' ' || c == '\0').to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// The columns of a relation, read from `RDB$RELATION_FIELDS` and ordered
/// by field id (the record-format / SELECT * order). The relation is
/// matched by name because `RDB$RELATION_FIELDS` is keyed by name, which
/// is what a query gives us.
pub fn relation_columns(file: &crate::Image, page_size: usize, relation_name: &str) -> Vec<RelationColumn> {
    // A SYSTEM relation's columns are memoised, for the same reason and
    // with the same safety argument as [crate::sysfmt::system_relation_formats]:
    // this walks every data page of RDB$RELATION_FIELDS on every call and
    // has 120 call sites, and after the format cache landed it was 60.9%
    // of what the server still burned per statement (with `sqz::unpack`
    // and `cstr` beneath it).
    //
    // ONLY system relations. A user relation's column set changes under
    // ALTER TABLE - that is most of what DDL does - and serving a stale
    // one would resolve names against columns the table no longer has.
    // A system relation's columns are fixed by the ODS for the life of
    // the database. The key carries the ODS major and the page size so
    // two attachments to different databases cannot share an entry.
    if let Some(hit) = cached_system_columns(file, page_size, relation_name) {
        return hit;
    }
    relation_columns_uncached(file, page_size, relation_name)
}

fn cached_system_columns(
    file: &crate::Image,
    page_size: usize,
    relation_name: &str,
) -> Option<Vec<RelationColumn>> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    let name = relation_name.trim();
    if !(name.starts_with("RDB$") || name.starts_with("MON$") || name.starts_with("SEC$")) {
        return None;
    }
    let ods = crate::header::HeaderPage::decode(crate::page_at(file, page_size, 0)?)?.ods_major();
    static CACHE: OnceLock<Mutex<HashMap<(u16, usize, String), Vec<RelationColumn>>>> =
        OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = (ods, page_size, name.to_string());
    if let Ok(g) = cache.lock() {
        if let Some(hit) = g.get(&key) {
            return Some(hit.clone());
        }
    }
    let computed = relation_columns_uncached(file, page_size, relation_name);
    if let Ok(mut g) = cache.lock() {
        g.insert(key, computed.clone());
    }
    Some(computed)
}

fn relation_columns_uncached(
    file: &crate::Image,
    page_size: usize,
    relation_name: &str,
) -> Vec<RelationColumn> {
    let want = relation_name.trim();
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, REL_RELATION_FIELDS) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let Some(rname) = cstr(&image, RF_RELATION_NAME_OFFSET) else {
                continue;
            };
            if !rname.eq_ignore_ascii_case(want) {
                continue;
            }
            let Some(name) = cstr(&image, RF_FIELD_NAME_OFFSET) else {
                continue;
            };
            if image.len() < RF_FIELD_ID_OFFSET + 2 {
                continue;
            }
            let field_id =
                u16::from_le_bytes([image[RF_FIELD_ID_OFFSET], image[RF_FIELD_ID_OFFSET + 1]]);
            let position = u16::from_le_bytes([
                image[RF_FIELD_POSITION_OFFSET],
                image[RF_FIELD_POSITION_OFFSET + 1],
            ]);
            out.push(RelationColumn {
                name,
                field_id,
                position,
            });
        }
    }
    // declaration order (what SELECT * returns)
    out.sort_by_key(|c| c.position);
    out
}

/// Count the committed primary record versions of a relation by walking
/// its data pages - the low-level equivalent of `SELECT COUNT(*)`. On a
/// database with no uncommitted work and no pending back-versions/garbage
/// (a freshly created or gbak-restored file), this equals the row count
/// the engine returns; the same clean-file precondition `qa/diff-select.sh`
/// relies on. (Full MVCC-visibility counting lives in `tra::visible_rows`.)
pub fn count_primary_records(file: &crate::Image, page_size: usize, relation: u16) -> u64 {
    let mut primary = 0u64;
    for dp_no in relation_data_pages(file, page_size, relation) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        if dp.relation != relation {
            continue;
        }
        for r in dp.records() {
            let f = r.flags;
            let non_primary = flags::BLOB | flags::FRAGMENT | flags::CHAIN | flags::DELETED;
            if f & non_primary == 0 {
                primary += 1;
            }
        }
    }
    primary
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relation_row_reads_id_and_trims_name() {
        // craft an image with id=6 @32 and "RDB$RELATIONS" @42, space-padded
        let mut img = vec![0u8; RELATION_NAME_OFFSET + RELATION_NAME_LEN];
        img[RELATION_ID_OFFSET..RELATION_ID_OFFSET + 2].copy_from_slice(&6u16.to_le_bytes());
        let name = b"RDB$RELATIONS";
        img[RELATION_NAME_OFFSET..RELATION_NAME_OFFSET + name.len()].copy_from_slice(name);
        for b in &mut img[RELATION_NAME_OFFSET + name.len()..] {
            *b = b' ';
        }
        assert_eq!(relation_row(&img), Some((6, "RDB$RELATIONS".to_string())));
    }

    #[test]
    fn relation_row_rejects_short_image() {
        assert_eq!(relation_row(&[0u8; 10]), None);
    }
}
