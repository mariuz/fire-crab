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

const RELATION_ID_OFFSET: usize = 32;
const RELATION_NAME_OFFSET: usize = 42;
const RELATION_NAME_LEN: usize = 252;

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
pub fn list_relations(file: &[u8], page_size: usize) -> Vec<(u16, String)> {
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, REL_RELATIONS) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            if let Some(image) = r.image() {
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
pub fn resolve_relation(file: &[u8], page_size: usize, name: &str) -> Option<u16> {
    let want = name.trim();
    for (id, rel_name) in list_relations(file, page_size) {
        if rel_name.eq_ignore_ascii_case(want) {
            return Some(id);
        }
    }
    None
}

/// Count the committed primary record versions of a relation by walking
/// its data pages - the low-level equivalent of `SELECT COUNT(*)`. On a
/// database with no uncommitted work and no pending back-versions/garbage
/// (a freshly created or gbak-restored file), this equals the row count
/// the engine returns; the same clean-file precondition `qa/diff-select.sh`
/// relies on. (Full MVCC-visibility counting lives in `tra::visible_rows`.)
pub fn count_primary_records(file: &[u8], page_size: usize, relation: u16) -> u64 {
    let mut primary = 0u64;
    for dp_no in relation_data_pages(file, page_size, relation) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
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
