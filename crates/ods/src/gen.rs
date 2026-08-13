//! The generator vector - where `GEN_ID` values actually live.
//!
//! A generator's current value is not a catalog column: `RDB$GENERATORS`
//! only names it and records its `RDB$GENERATOR_ID`, and that id is an
//! index into a flat vector of `SINT64`s spread over the database's
//! `pag_ids` pages (dpm.epp:1439). Slot `id % gens_per_page` on the page
//! whose `gpg_sequence` is `id / gens_per_page`, where `gens_per_page` is
//! `(page_size - offsetof(generator_page, gpg_values)) / 8` = `(ps-24)/8`
//! (ods.cpp:81). The value is a native little-endian `SINT64` the engine
//! dereferences directly.
//!
//! Two slots are not user generators at all and never appear in
//! `RDB$GENERATORS`: slot 0 is the MASTER generator (constants.h:134,
//! `MASTER_GENERATOR` - the empty name in the system schema, special-cased
//! in ExprNodes.cpp:7168), the counter every new metadata object's id
//! comes from, and slot 1 belongs to `RDB$SECURITY_CLASS`, the counter
//! behind the `SQL$<n>` security-class names. Creating an object bumps
//! both, which is why they are written here and not by any DML.

use crate::PageType;

/// How many generator values fit on one `pag_ids` page.
fn gens_per_page(page_size: usize) -> usize {
    page_size.saturating_sub(24) / 8
}

/// The byte offset of generator `id`'s `SINT64` value. None if the
/// generator page that would hold it has not been allocated - the
/// engine's `DPM_gen_id` grows the vector on demand; fire-crab writes
/// into the vector that exists.
pub fn slot_offset(bytes: &[u8], page_size: usize, id: i64) -> Option<(u32, usize)> {
    if id < 0 {
        return None;
    }
    let id = id as usize;
    let per = gens_per_page(page_size);
    if per == 0 {
        return None;
    }
    let sequence = (id / per) as u32;
    let offset = id % per;
    let pages = (bytes.len() / page_size) as u32;
    for pno in 0..pages {
        let page = crate::page_at(bytes, page_size, pno)?;
        if page[0] != PageType::Generators as u8 {
            continue;
        }
        let seq = u32::from_le_bytes([page[16], page[17], page[18], page[19]]);
        if seq == sequence {
            // the slot's PAGE and its PAGE-LOCAL offset - a generator
            // value read/written through page_at/page_mut, no absolute
            // offset into the whole image
            return Some((pno, 24 + offset * 8));
        }
    }
    None
}

/// Read generator `id`'s stored value. A generator whose page has never
/// been allocated reads 0 - the engine's zero-initialised slot.
pub fn read(bytes: &[u8], page_size: usize, id: i64) -> i64 {
    match slot_offset(bytes, page_size, id) {
        Some((pno, at)) => {
            match crate::page_at(bytes, page_size, pno).and_then(|p| p.get(at..at + 8)) {
                Some(raw) => i64::from_le_bytes(raw.try_into().unwrap_or([0; 8])),
                None => 0,
            }
        }
        None => 0,
    }
}

/// Write generator `id`'s value into its slot.
pub fn write(bytes: &mut [u8], page_size: usize, id: i64, value: i64) -> Result<(), String> {
    let (pno, at) = slot_offset(bytes, page_size, id).ok_or("generator page not allocated")?;
    let page = crate::page_mut(bytes, page_size, pno).ok_or("generator page out of range")?;
    page[at..at + 8].copy_from_slice(&value.to_le_bytes());
    Ok(())
}

/// Add `step` to generator `id` and return the new value - `GEN_ID`.
pub fn bump(bytes: &mut [u8], page_size: usize, id: i64, step: i64) -> Result<i64, String> {
    let next = read(bytes, page_size, id).wrapping_add(step);
    write(bytes, page_size, id, next)?;
    Ok(next)
}

/// Slot 0: the master generator, source of every metadata object id.
pub const MASTER: i64 = 0;
/// Slot 1: `RDB$SECURITY_CLASS`, source of the `SQL$<n>` class names.
pub const SECURITY_CLASS: i64 = 1;

#[cfg(test)]
mod tests {
    use super::*;

    /// A two-page file whose second page is a generator page (sequence 0).
    fn scratch(page_size: usize) -> Vec<u8> {
        let mut f = vec![0u8; page_size * 2];
        f[page_size] = PageType::Generators as u8;
        f[page_size + 16..page_size + 20].copy_from_slice(&0u32.to_le_bytes());
        f
    }

    #[test]
    fn slot_arithmetic_follows_the_page_sequence() {
        let ps = 8192;
        let f = scratch(ps);
        // sequence 0 holds ids 0..(ps-24)/8
        assert_eq!(slot_offset(&f, ps, 0), Some((1, 24)));
        assert_eq!(slot_offset(&f, ps, 3), Some((1, 24 + 24)));
        // the page for the next sequence does not exist
        assert_eq!(slot_offset(&f, ps, gens_per_page(ps) as i64), None);
        assert_eq!(slot_offset(&f, ps, -1), None);
    }

    #[test]
    fn a_bump_reads_back_what_it_wrote() {
        let ps = 8192;
        let mut f = scratch(ps);
        assert_eq!(read(&f, ps, 7), 0);
        assert_eq!(bump(&mut f, ps, 7, 5).unwrap(), 5);
        assert_eq!(bump(&mut f, ps, 7, 5).unwrap(), 10);
        write(&mut f, ps, 7, -3).unwrap();
        assert_eq!(read(&f, ps, 7), -3);
        // an unallocated page is an error to write, 0 to read
        assert!(write(&mut f, ps, 100_000, 1).is_err());
        assert_eq!(read(&f, ps, 100_000), 0);
    }
}
