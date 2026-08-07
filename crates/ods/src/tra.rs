//! The transaction system's durable half, converted from the TIP
//! machinery in `tra.cpp` and the version-chain rules in `vio.cpp`:
//! transaction-state lookup across the chained inventory pages, delta
//! back-version reconstruction (`Difference::apply`, sqz.cpp:515),
//! and the committed-only visibility walk - "which version of each
//! record would a reader see if it considers exactly the committed
//! transactions" - the core MVCC question, answerable from the raw
//! file because both the versions and the transaction states are
//! durable.

use crate::data::{flags, DataPage};
use crate::format::{decode_record, Descriptor, Value};
use crate::pointer::relation_data_pages;
use crate::tip::{TipPage, TxState};
use crate::u16_at;

/// All TIP pages in transaction order. TIPs chain through `tip_next`;
/// the head is the TIP no other TIP points to (page 2 in practice,
/// but derived, not assumed).
pub struct TipChain<'a> {
    pages: Vec<TipPage<'a>>,
    per_page: usize,
}

impl<'a> TipChain<'a> {
    pub fn read(file: &'a [u8], page_size: usize) -> Option<TipChain<'a>> {
        let mut tips: Vec<TipPage> = file
            .chunks_exact(page_size)
            .filter(|p| p[0] == crate::PageType::TransactionInventory as u8)
            .filter_map(TipPage::decode)
            .collect();
        if tips.is_empty() {
            return None;
        }
        // the head is the TIP no other TIP's tip_next points to
        let head = tips
            .iter()
            .map(|t| t.pag.page_no)
            .find(|no| !tips.iter().any(|t| t.next == *no))?;

        let mut ordered = Vec::with_capacity(tips.len());
        let mut cur = head;
        while cur != 0 {
            let pos = tips.iter().position(|t| t.pag.page_no == cur)?;
            let t = tips.swap_remove(pos);
            cur = t.next;
            ordered.push(t);
        }
        Some(TipChain {
            per_page: TipPage::transactions_per_page(page_size),
            pages: ordered,
        })
    }

    /// State of transaction `id` (tra.cpp's TIP lookup: page
    /// `id / per_page`, index `id % per_page`).
    pub fn state(&self, id: u64) -> Option<TxState> {
        let page = self.pages.get((id as usize) / self.per_page)?;
        page.state((id as usize) % self.per_page)
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }
}

/// `Difference::apply` (sqz.cpp:515): reconstruct the PRIOR version's
/// image by applying a differences stream to (a copy of) the newer
/// image. Positive control byte = take that many literal bytes from
/// the stream; negative = retain that many bytes of the newer image.
pub fn apply_differences(diff: &[u8], newer_image: &[u8]) -> Option<Vec<u8>> {
    let mut out = newer_image.to_vec();
    let mut p = 0usize; // position in out
    let mut d = 0usize; // position in diff
    while d < diff.len() && p < out.len() {
        let l = diff[d] as i8;
        d += 1;
        if l > 0 {
            let n = l as usize;
            if p + n > out.len() || d + n > diff.len() {
                return None; // BUGCHECK 176/177 territory
            }
            out[p..p + n].copy_from_slice(&diff[d..d + n]);
            p += n;
            d += n;
        } else {
            p += (-(l as i32)) as usize;
        }
    }
    // trailing difference bytes must be zero padding (sqz.cpp:553)
    if diff[d..].iter().any(|b| *b != 0) {
        return None;
    }
    out.truncate(p.min(out.len()));
    Some(out)
}

/// THE TRANSACTIONS A READER COUNTS AS ITS OWN - not one id, a SET.
///
/// A reader must see the uncommitted work of its own transaction, and
/// for a long time that was one number, because one attachment wrote
/// under one id. It is a set now because an UNDO WINDOW inside a
/// transaction - a savepoint, a PSQL body, a row-by-row statement -
/// writes under a NESTED id of its own, so that undoing the window is
/// `tra_dead` on that id and nothing else (the engine's savepoint
/// model, `tra.cpp`'s undo records seen from the durable side). All of
/// those ids belong to the same reader; a transaction that commits
/// flips every one of them, and one that rolls a window back flips
/// only that window's.
///
/// Order does not matter and the sets are tiny (one per open window),
/// so this is a `Vec` and the test is a linear scan - a `HashSet` here
/// costs more than it saves, and this is on the per-record path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OwnTx {
    ids: Vec<u64>,
}

impl OwnTx {
    /// The committed-only walk: a reader with no transaction of its
    /// own, which is what a tool reading a quiet file is.
    pub fn none() -> OwnTx {
        OwnTx { ids: Vec::new() }
    }

    pub fn one(id: u64) -> OwnTx {
        OwnTx { ids: vec![id] }
    }

    pub fn of<I: IntoIterator<Item = u64>>(ids: I) -> OwnTx {
        OwnTx { ids: ids.into_iter().collect() }
    }

    pub fn push(&mut self, id: u64) {
        if !self.contains(id) {
            self.ids.push(id);
        }
    }

    pub fn contains(&self, id: u64) -> bool {
        self.ids.contains(&id)
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn ids(&self) -> &[u64] {
        &self.ids
    }
}

impl From<Option<u64>> for OwnTx {
    fn from(id: Option<u64>) -> OwnTx {
        match id {
            Some(id) => OwnTx::one(id),
            None => OwnTx::none(),
        }
    }
}

/// One visible row: its record number and decoded values.
pub struct VisibleRow {
    pub recno: u64,
    pub values: Vec<Value>,
    /// the record image the values were decoded from - kept so a caller
    /// that needs BYTES (an OCTETS column, a format-level check) can go
    /// back to the ground truth instead of a lossy string
    pub image: Vec<u8>,
    /// how many chain steps back the visible version was found
    pub versions_walked: u32,
    /// how many of those steps reconstructed a delta (rhd_delta)
    pub deltas_applied: u32,
}

/// The version of one record chain a reader should see, and the image
/// it decodes from: the newest version whose transaction the reader
/// COUNTS - committed, or the reader's own uncommitted work - walking
/// the back-version chain (`rhd_b_page`/`rhd_b_line`) and
/// reconstructing delta versions (the NEWER version's `rhd_delta` flag
/// says its prior is stored as differences).
///
/// `None` means the reader sees no row here at all: the version it
/// would see is a deleted stub, or there is no such version (an insert
/// by a transaction it does not count).
///
/// `own` is the reader's OWN transactions, whose uncommitted work it
/// must see - a statement reads what the statements before it in the
/// same transaction wrote, INCLUDING the ones an undo window inside it
/// wrote under a nested id. Pass [OwnTx::none] for the pure
/// committed-only walk (what a tool reading a quiet file wants).
///
/// The returned `format` is the FOUND VERSION's, not the chain head's:
/// an older version can carry an older format, and decoding it with
/// the head's descriptors reads the wrong bytes.
pub struct VisibleVersion {
    pub image: Vec<u8>,
    pub format: u8,
    /// chain steps back to it (0 = the primary version)
    pub walked: u32,
    pub deltas: u32,
}

pub fn visible_version(
    file: &[u8],
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
) -> Option<VisibleVersion> {
    let fetch_page = |no: u32| {
        let start = no as usize * page_size;
        file.get(start..start + page_size)
            .and_then(DataPage::decode)
    };
    let mut current = head.clone();
    let mut image: Option<Vec<u8>> = if current.flags & flags::DELETED != 0 {
        None // deleted stubs carry no data
    } else {
        crate::data::assembled_image(file, page_size, &current)
    };
    let mut walked = 0u32;
    let mut deltas = 0u32;
    loop {
        // THE SYSTEM TRANSACTION IS COMMITTED BY DEFINITION. Its TIP
        // slot reads `tra_active` in every real database (measured: id
        // 0's two bits are 0 while 1..n read 3), because it is not a
        // transaction anybody ever started - the engine answers for it
        // in code instead (tra.cpp's snapshot-state lookup returns
        // committed for number 0). The rows that carry it are the ones
        // only the system transaction may write, `RDB$PAGES` first
        // among them, so reading it as active would hide the catalog.
        let counts = current.transaction == 0
            || tips.state(current.transaction) == Some(TxState::Committed)
            || own.contains(current.transaction);
        if counts {
            if current.flags & flags::DELETED != 0 {
                return None; // the reader's row is a deleted stub
            }
            return Some(VisibleVersion {
                image: image?,
                format: current.format,
                walked,
                deltas,
            });
        }
        // not counted: step to the back version
        if current.back_page == 0 {
            return None; // an insert this reader does not count
        }
        let back = fetch_page(current.back_page)?.record(current.back_line)?;
        // ASSEMBLED. A fragmented BACK version used to end the walk,
        // dropping the row even when the primary was perfectly
        // readable - and the delta path below would then have applied
        // against an image that was never fetched.
        let back_data = crate::data::assembled_image(file, page_size, &back)?;
        image = if current.flags & flags::DELTA != 0 {
            // prior version stored as differences against the CURRENT
            // image (ods.h:1012)
            deltas += 1;
            Some(apply_differences(&back_data, image.as_deref()?)?)
        } else {
            Some(back_data)
        };
        current = back;
        walked += 1;
    }
}

/// Is there a version of this chain the reader counts, and is it a row?
///
/// The same walk as [visible_version] with the images left alone: a
/// COUNT does not need the bytes, only the answer, and assembling
/// every record to throw it away is what made counting expensive.
/// Deltas are irrelevant here for the same reason - a delta version
/// is still a version, and whether it is DELETED is in its header.
pub fn visible_exists(
    file: &[u8],
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
) -> bool {
    if head.flags & (flags::CHAIN | flags::FRAGMENT | flags::BLOB) != 0 {
        return false; // reached through its head, never walked as one
    }
    let mut current = head.clone();
    loop {
        let counts = current.transaction == 0
            || tips.state(current.transaction) == Some(TxState::Committed)
            || own.contains(current.transaction);
        if counts {
            return current.flags & flags::DELETED == 0;
        }
        if current.back_page == 0 {
            return false;
        }
        let start = current.back_page as usize * page_size;
        let Some(back) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
            .and_then(|dp| dp.record(current.back_line))
        else {
            return false;
        };
        current = back;
    }
}

/// The committed-only visibility walk (the vio.cpp rule a fresh
/// snapshot reader applies when every interesting transaction is
/// either committed or not): for each primary record, take the newest
/// version whose transaction is committed - walking the back-version
/// chain (`rhd_b_page`/`rhd_b_line`), reconstructing delta versions
/// (the NEWER version's `rhd_delta` flag says its prior is stored as
/// differences) - and drop the row if that version is a deleted stub
/// or no committed version exists (an uncommitted insert).
pub fn visible_rows(
    file: &[u8],
    page_size: usize,
    relation: u16,
    descs: &[Descriptor],
    tips: &TipChain,
) -> Vec<VisibleRow> {
    let recs_per_dp = crate::format::max_recs_per_dp(page_size);
    let mut out = Vec::new();

    for dp_no in relation_data_pages(file, page_size, relation) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            // only chain heads: back versions and blobs are reached
            // through their primaries. A FRAGMENT is skipped here for the
            // same reason - it is reached through its head, which carries
            // rhd_incomplete and is NOT filtered out - and the head's
            // image is assembled by the walk below.
            if r.flags & (flags::CHAIN | flags::BLOB | flags::FRAGMENT) != 0 {
                continue;
            }
            let recno = dp.sequence as u64 * recs_per_dp + r.slot as u64;
            // committed-only: a reader with no transaction of its own
            let Some(v) = visible_version(file, page_size, &r, tips, &OwnTx::none()) else {
                continue;
            };
            out.push(VisibleRow {
                recno,
                values: decode_record(&v.image, descs),
                image: v.image,
                versions_walked: v.walked,
                deltas_applied: v.deltas,
            });
        }
    }
    out
}

/// Header-vs-TIP invariants a healthy database file satisfies; each
/// violated invariant is returned as a message.
pub fn check_invariants(file: &[u8], page_size: usize) -> Vec<String> {
    let mut problems = Vec::new();
    let Some(h) = crate::HeaderPage::decode(file) else {
        return vec!["no header page".into()];
    };
    let _ = page_size;
    if h.oldest_transaction > h.oldest_active {
        problems.push(format!(
            "OIT {} > OAT {}",
            h.oldest_transaction, h.oldest_active
        ));
    }
    if h.oldest_active > h.next_transaction {
        problems.push(format!(
            "OAT {} > next {}",
            h.oldest_active, h.next_transaction
        ));
    }
    if h.oldest_snapshot > h.next_transaction {
        problems.push(format!(
            "OST {} > next {}",
            h.oldest_snapshot, h.next_transaction
        ));
    }
    problems
}

/// Convenience: page-size accessor for tools.
pub fn page_size_of(file: &[u8]) -> Option<usize> {
    Some(u16_at(file, 16) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The set a reader counts as its own. It was one id for as long as
    /// one attachment wrote under one transaction; an undo window writes
    /// under a nested one, so it is a set - and `None` (a tool reading a
    /// quiet file) must stay the EMPTY set rather than becoming
    /// "everything", which is the direction that would make a rolled-back
    /// row visible to `fcstat`.
    #[test]
    fn own_tx_is_a_set_and_none_is_empty() {
        let none = OwnTx::none();
        assert!(none.is_empty());
        assert!(!none.contains(0));
        assert!(!none.contains(7));
        assert_eq!(OwnTx::from(None), none);
        assert_eq!(OwnTx::from(Some(7)), OwnTx::one(7));

        let mut own = OwnTx::of([7u64, 9]);
        assert!(own.contains(7) && own.contains(9) && !own.contains(8));
        // pushing is idempotent: a window whose id is already counted
        // must not grow the set every time it is asked
        own.push(9);
        own.push(11);
        assert_eq!(own.ids(), &[7, 9, 11]);
    }

    #[test]
    fn apply_differences_matches_sqz_cpp() {
        // newer = "AAAABBBB"; diff: retain 4, replace 4 with "CCDD"
        let newer = b"AAAABBBB";
        let diff = [(-4i8) as u8, 4, b'C', b'C', b'D', b'D'];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AAAACCDD");

        // shortening: retain 2 only -> length 2
        let diff = [(-2i8) as u8];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AA");

        // literal overrun is an error (BUGCHECK 176)
        let diff = [3, b'X'];
        assert!(apply_differences(&diff, newer).is_none());

        // trailing nonzero garbage is an error (sqz.cpp:553)
        let newer2 = b"AB";
        let diff = [(-2i8) as u8, 7];
        assert!(apply_differences(&diff, newer2).is_none());
    }

    /// A file with one TIP page (page 1) whose transaction states the
    /// caller sets, and one data page (page 2) the caller fills.
    fn tip_file(page_size: usize, states: &[(u64, TxState)]) -> Vec<u8> {
        let mut f = vec![0u8; page_size * 3];
        f[0] = crate::PageType::Header as u8;
        f[16..18].copy_from_slice(&(page_size as u16).to_le_bytes());
        let t = page_size;
        f[t] = crate::PageType::TransactionInventory as u8;
        f[t + 12..t + 16].copy_from_slice(&1u32.to_le_bytes()); // pag_pageno
        for (id, st) in states {
            let byte = t + crate::tip::TIP_TRANSACTIONS_OFFSET + (*id as usize) / 4;
            let shift = 2 * ((*id as usize) % 4);
            f[byte] = (f[byte] & !(0b11 << shift)) | ((*st as u8) << shift);
        }
        f
    }

    /// COUNTING IS A VISIBILITY QUESTION, which is what the fast path
    /// behind `SELECT COUNT(*)` forgot: a rolled-back insert leaves a
    /// live primary header behind, and counting headers counts it.
    #[test]
    fn a_dead_transactions_row_is_not_counted() {
        let ps = 4096;
        let f = tip_file(
            ps,
            &[(11, TxState::Committed), (12, TxState::Dead), (13, TxState::Active)],
        );
        let tips = TipChain::read(&f, ps).expect("tip chain");
        assert_eq!(tips.state(11), Some(TxState::Committed));
        assert_eq!(tips.state(12), Some(TxState::Dead));
        assert_eq!(tips.state(13), Some(TxState::Active));
        // the system transaction reads ACTIVE in the file and counts
        // anyway - the engine answers for id 0 in code
        assert_eq!(tips.state(0), Some(TxState::Active));
    }
}
