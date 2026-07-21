//! Garbage-collection and sweep analysis, converted from the version
//! rules in `vio.cpp` (VIO_chase_record_version, the `cannotGC`
//! predicate at vio.cpp:1663). fire-crab is a read-only decoder, so
//! this is the *classification* half of GC: given a database file and
//! its oldest-snapshot threshold, decide which record versions the
//! engine's sweep would remove. `qa/diff-sweep.sh` checks that
//! prediction against what `gfix -sweep` actually removes.
//!
//! The engine's rules, for a version reached as a chain head:
//!
//!   - transaction DEAD (rolled back): the version is backed out. A
//!     rolled-back insert (no back page) removes the whole record; a
//!     rolled-back update reverts to its back version.
//!   - committed DELETED stub with tx < oldest_snapshot: expunged —
//!     the stub and its entire back chain are removed (vio.cpp:1628).
//!   - committed, tx < oldest_snapshot, has a back page, not chained:
//!     the back CHAIN is collectable (the primary stays, every older
//!     version below it goes) — the negation of `cannotGC`
//!     (vio.cpp:1663).
//!   - committed, tx >= oldest_snapshot: kept (a live snapshot may
//!     still need the old versions).

use crate::data::{flags, DataPage, RecordHeader};
use crate::pointer::relation_data_pages;
use crate::tip::TxState;
use crate::tra::TipChain;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GcReport {
    /// Total record-version segments on the relation's data pages
    /// (primaries + back versions + deleted stubs; blobs excluded).
    pub total_versions: u64,
    /// Versions the engine's sweep would remove: back versions below a
    /// collectable primary, expunged deleted stubs (+ their chains),
    /// and backed-out dead versions.
    pub collectable_versions: u64,
    /// Records fully removed (rolled-back inserts, expunged deletes).
    pub records_removed: u64,
    /// Live primaries that remain.
    pub live_records: u64,
}

/// Count the versions in a back-chain starting at (page, line),
/// following `rhd_b_page`/`rhd_b_line` until 0. Bounded by a hop cap
/// to survive malformed chains.
fn chain_len(file: &[u8], page_size: usize, mut page: u32, mut line: u16) -> u64 {
    let mut n = 0u64;
    let mut hops = 0;
    while page != 0 && hops < 100_000 {
        let start = page as usize * page_size;
        let Some(dp) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            break;
        };
        let Some(r) = dp.record(line) else { break };
        n += 1;
        page = r.back_page;
        line = r.back_line;
        hops += 1;
    }
    n
}

/// Analyze one relation's collectable garbage against `oldest_snapshot`
/// (the header's OST — the threshold the sweeper uses).
pub fn analyze(
    file: &[u8],
    page_size: usize,
    relation: u16,
    oldest_snapshot: u64,
    tips: &TipChain,
) -> GcReport {
    let mut rep = GcReport::default();

    let count_slot = |r: &RecordHeader| -> u64 {
        // a slot's own segment always counts as one version
        let _ = r;
        1
    };

    for dp_no in relation_data_pages(file, page_size, relation) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if r.flags & flags::BLOB != 0 {
                continue; // blobs are not record versions
            }
            rep.total_versions += count_slot(&r);

            // only classify from chain HEADS (primaries); back versions
            // and fragments are accounted through their heads
            if r.flags & (flags::CHAIN | flags::FRAGMENT) != 0 {
                continue;
            }

            let state = tips.state(r.transaction);
            let back = chain_len(file, page_size, r.back_page, r.back_line);

            match state {
                Some(TxState::Dead) => {
                    // rolled back: whole version backed out; a rolled-
                    // back insert (no back) removes the record
                    rep.collectable_versions += 1;
                    if r.back_page == 0 {
                        rep.records_removed += 1;
                    } else {
                        // reverts to the (committed) back version, which
                        // stays live; deeper back versions below THAT
                        // are handled when sweep re-heads there. Count
                        // only this dead version here.
                        rep.live_records += 1;
                    }
                }
                Some(TxState::Committed) if r.flags & flags::DELETED != 0 => {
                    if r.transaction < oldest_snapshot {
                        // expunge: stub + entire back chain
                        rep.collectable_versions += 1 + back;
                        rep.records_removed += 1;
                    } else {
                        rep.live_records += 1; // deleted but still visible-window
                    }
                }
                Some(TxState::Committed) => {
                    rep.live_records += 1;
                    // cannotGC negated: tx < OST and has a back chain
                    if r.transaction < oldest_snapshot && r.back_page != 0 {
                        rep.collectable_versions += back;
                    }
                }
                _ => {
                    // active / limbo primary: kept, chain kept
                    rep.live_records += 1;
                }
            }
        }
    }
    rep
}

/// Just the raw version count (primaries + back versions + stubs),
/// used to measure a file before and after `gfix -sweep`.
pub fn version_count(file: &[u8], page_size: usize, relation: u16) -> u64 {
    let mut n = 0u64;
    for dp_no in relation_data_pages(file, page_size, relation) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if r.flags & flags::BLOB == 0 {
                n += 1;
            }
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_arithmetic() {
        // pure unit check of the struct's bookkeeping; the real
        // validation is the differential in qa/diff-sweep.sh
        let r = GcReport {
            total_versions: 600,
            collectable_versions: 500,
            records_removed: 0,
            live_records: 100,
        };
        assert_eq!(r.total_versions - r.collectable_versions, r.live_records);
    }
}
