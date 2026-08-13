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
        let Some(dp) = crate::page_at(file, page_size, page)
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
        let Some(dp) = crate::page_at(file, page_size, dp_no)
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
        let Some(dp) = crate::page_at(file, page_size, dp_no)
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

// ===================================================================
// THE WRITE HALF: performing the sweep this module used to predict.
//
// `gfix -sweep` is an ATTACH (isc_dpb_sweep, tag 10) and the work is
// record-level: back out what dead transactions left, expunge deleted
// stubs, and collect the back chains no reader can want. The
// classification above is the specification; what follows makes the
// file match it, with the one liberty fire-crab's isolation model
// grants: THIS server has no snapshots, so no committed back version is
// ever still wanted - the oldest-snapshot threshold that gates the
// engine's collection is always "everything" here.
//
// MEASURED LAWS the shape below comes from (a fire-crab-written file
// with dead transactions, swept by the LIVE ENGINE):
//
//   * versions collapse to the live count, rows unchanged;
//   * the TIP's DEAD ENTRIES STAY DEAD - the sweep does not rewrite
//     history, it advances `hdr_oldest_transaction` PAST it;
//   * oldest-active and oldest-snapshot land at next-transaction.
//
// FAIL-CLOSED, per chain: a chain with a fragmented member, an
// undecodable page, a promotion that does not fit its page, or a LIMBO
// transaction is left whole and counted, never half-freed. A relation
// carrying BLOB records is left whole too - freeing a version without
// freeing its blobs leaks them, and the blob walk is its own slice.

/// What one sweep did, for the trace and the gate's teeth.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SweepOutcome {
    pub relations_swept: usize,
    /// relations left alone because their pages carry blob records
    pub relations_skipped_blob: usize,
    /// chains left alone: fragmented members, limbo, no room to promote
    pub chains_skipped: u64,
    /// record versions physically freed
    pub versions_removed: u64,
    /// whole records removed (rolled-back inserts, expunged deletes)
    pub records_removed: u64,
    /// ACTIVE transactions with no living owner, marked dead on the way
    pub stale_actives: u64,
}

/// One chain member as the walk sees it.
struct Member {
    page: u32,
    slot: u16,
    transaction: u64,
    back_page: u32,
    back_line: u16,
    flags: u16,
}

/// Free a record slot: zero its directory entry. The bytes stay where
/// they are - `find_space` measures free space from the LIVE entries,
/// so a zeroed slot is reusable room, which is also what the engine's
/// own lazily-compacted pages look like.
fn free_slot(file: &mut [u8], page_size: usize, page: u32, slot: u16) {
    let p = crate::page_mut(file, page_size, page).expect("free_slot: page out of range");
    let dir = crate::data::DPG_RPT_OFFSET + slot as usize * 4;
    crate::dml::put_u16(p, dir, 0);
    crate::dml::put_u16(p, dir + 2, 0);
}

/// Read one record's header fields straight off the page.
fn member_at(file: &[u8], page_size: usize, page: u32, slot: u16) -> Option<Member> {
    let dp = crate::page_at(file, page_size, page).and_then(DataPage::decode)?;
    let r = dp.record(slot)?;
    Some(Member {
        page,
        slot,
        transaction: r.transaction,
        back_page: r.back_page,
        back_line: r.back_line,
        flags: r.flags,
    })
}

/// The whole back chain FROM (page, line), validated: every member
/// present, none fragmented. `None` = the chain cannot be swept safely.
fn chain_members(
    file: &[u8],
    page_size: usize,
    mut page: u32,
    mut line: u16,
) -> Option<Vec<Member>> {
    let mut out = Vec::new();
    let mut hops = 0;
    while page != 0 {
        if hops >= 100_000 {
            return None;
        }
        hops += 1;
        let m = member_at(file, page_size, page, line)?;
        if m.flags & (flags::FRAGMENT | flags::INCOMPLETE) != 0 {
            return None;
        }
        page = m.back_page;
        line = m.back_line;
        out.push(m);
    }
    Some(out)
}

/// Every relation with a pointer page, straight off the pages - the
/// same catalog-free reading `relation_data_pages` does.
fn relations_of(file: &[u8], page_size: usize) -> Vec<u16> {
    let mut rels: Vec<u16> = file
        .chunks_exact(page_size)
        .filter(|p| p[0] == crate::PageType::Pointer as u8)
        .map(|p| crate::u16_at(p, 26)) // ppg_relation
        .collect();
    rels.sort_unstable();
    rels.dedup();
    rels
}

/// Perform the sweep. `is_held` answers whether an ACTIVE transaction
/// still belongs to a living attachment (the lock table's question);
/// one that does is skipped, one that does not is garbage - marked DEAD
/// in the TIP and backed out like any other dead transaction.
pub fn sweep(
    file: &mut Vec<u8>,
    page_size: usize,
    is_held: &dyn Fn(u64) -> bool,
) -> Result<SweepOutcome, String> {
    let mut out = SweepOutcome::default();
    let mut stale_marked: Vec<u64> = Vec::new();
    for rel in relations_of(file, page_size) {
        let pages = relation_data_pages(file, page_size, rel);
        // a relation whose pages carry BLOB records is left whole
        let mut has_blob = false;
        'blobscan: for dp_no in &pages {
            let Some(dp) = crate::page_at(file, page_size, *dp_no).and_then(DataPage::decode) else {
                continue;
            };
            for r in dp.records() {
                if r.flags & flags::BLOB != 0 {
                    has_blob = true;
                    break 'blobscan;
                }
            }
        }
        if has_blob {
            out.relations_skipped_blob += 1;
            continue;
        }
        out.relations_swept += 1;
        for dp_no in pages {
            let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
                continue;
            };
            let heads: Vec<u16> = dp
                .records()
                .filter(|r| r.flags & (flags::CHAIN | flags::FRAGMENT | flags::BLOB) == 0)
                .map(|r| r.slot)
                .collect();
            'heads: for slot in heads {
                // the head is re-read each iteration: a promotion
                // REPLACES it, and the new head is judged afresh
                loop {
                    let Some(head) = member_at(file, page_size, dp_no, slot) else {
                        break;
                    };
                    if head.flags & (flags::FRAGMENT | flags::INCOMPLETE) != 0 {
                        out.chains_skipped += 1;
                        continue 'heads;
                    }
                    let tips = TipChain::read(file, page_size)
                        .ok_or("no transaction inventory to sweep against")?;
                    let state = if head.transaction == 0 {
                        Some(TxState::Committed)
                    } else {
                        tips.state(head.transaction)
                    };
                    match state {
                        Some(TxState::Active) => {
                            if is_held(head.transaction) {
                                continue 'heads; // somebody's live work
                            }
                            // an active nobody owns is a rollback that
                            // never landed - the engine's probe on the
                            // transaction lock reaches the same verdict
                            if !stale_marked.contains(&head.transaction) {
                                crate::dml::set_tx_state(
                                    file,
                                    page_size,
                                    head.transaction,
                                    TxState::Dead,
                                )?;
                                stale_marked.push(head.transaction);
                                out.stale_actives += 1;
                            }
                            // ...and the loop re-reads it as dead
                        }
                        Some(TxState::Dead) => {
                            if head.back_page == 0 {
                                // a rolled-back INSERT: the record was
                                // never anything else
                                free_slot(file, page_size, dp_no, slot);
                                out.versions_removed += 1;
                                out.records_removed += 1;
                                continue 'heads;
                            }
                            // a rolled-back UPDATE (or DELETE): the back
                            // version is the record. PROMOTE it into the
                            // head slot, then judge the new head again.
                            let Some(back) =
                                member_at(file, page_size, head.back_page, head.back_line)
                            else {
                                out.chains_skipped += 1;
                                continue 'heads;
                            };
                            if back.flags & (flags::FRAGMENT | flags::INCOMPLETE) != 0 {
                                out.chains_skipped += 1;
                                continue 'heads;
                            }
                            // the stored image of the promoted version:
                            // a DELTA back version reconstructs against
                            // the head it is about to replace
                            let image = {
                                let back_hdr = {
                                    let dp2 = crate::page_at(file, page_size, head.back_page)
                                        .and_then(DataPage::decode)
                                        .ok_or("back page undecodable mid-sweep")?;
                                    dp2.record(head.back_line)
                                        .ok_or("back slot gone mid-sweep")?
                                        .clone()
                                };
                                let back_data =
                                    crate::data::assembled_image(file, page_size, &back_hdr);
                                let Some(back_data) = back_data else {
                                    out.chains_skipped += 1;
                                    continue 'heads;
                                };
                                if head.flags & flags::DELTA != 0 {
                                    let head_hdr = {
                                        let dp2 = crate::page_at(file, page_size, dp_no)
                                            .and_then(DataPage::decode)
                                            .ok_or("head page undecodable mid-sweep")?;
                                        dp2.record(slot)
                                            .ok_or("head slot gone mid-sweep")?
                                            .clone()
                                    };
                                    let Some(head_img) =
                                        crate::data::assembled_image(file, page_size, &head_hdr)
                                    else {
                                        out.chains_skipped += 1;
                                        continue 'heads;
                                    };
                                    match crate::tra::apply_differences(&back_data, &head_img) {
                                        Some(img) => img,
                                        None => {
                                            out.chains_skipped += 1;
                                            continue 'heads;
                                        }
                                    }
                                } else {
                                    back_data
                                }
                            };
                            // a 64-bit id would truncate in the 32-bit
                            // header slot below (LONG_TRANUM is a reader
                            // here, not a writer) - skip, never corrupt
                            if back.transaction > u32::MAX as u64 {
                                out.chains_skipped += 1;
                                continue 'heads;
                            }
                            // rebuild the record: the back version's own
                            // identity, CHAIN dropped (it is the head
                            // now), DELTA dropped (the image is stored
                            // whole)
                            // pack the image the way dml stores records:
                            // RLE when it shrinks, raw + NOT_PACKED when
                            // it does not - the flag must match the bytes
                            let packed = crate::sqz::pack(&image);
                            let (body, new_flags): (&[u8], u16) = if packed.len() < image.len() {
                                (
                                    &packed,
                                    back.flags & !(flags::CHAIN | flags::DELTA | flags::NOT_PACKED),
                                )
                            } else {
                                (
                                    &image,
                                    (back.flags & !(flags::CHAIN | flags::DELTA))
                                        | flags::NOT_PACKED,
                                )
                            };
                            let mut rec =
                                Vec::with_capacity(crate::data::RHD_DATA_OFFSET + body.len());
                            rec.extend_from_slice(&(back.transaction as u32).to_le_bytes());
                            rec.extend_from_slice(&back.back_page.to_le_bytes());
                            rec.extend_from_slice(&back.back_line.to_le_bytes());
                            rec.extend_from_slice(&new_flags.to_le_bytes());
                            rec.push({
                                let dp2 = crate::page_at(file, page_size, head.back_page)
                                    .and_then(DataPage::decode)
                                    .ok_or("back page undecodable mid-sweep")?;
                                dp2.record(head.back_line)
                                    .ok_or("back slot gone mid-sweep")?
                                    .format
                            });
                            rec.extend_from_slice(body);
                            // the ORDER is the fail-closed guarantee:
                            // rewrite first (nothing is freed if the
                            // page has no room), free the back slot only
                            // after the promotion is on the page
                            if crate::dml::rewrite_primary(file, page_size, dp_no, slot, &rec)
                                .is_err()
                            {
                                out.chains_skipped += 1;
                                continue 'heads;
                            }
                            free_slot(file, page_size, head.back_page, head.back_line);
                            out.versions_removed += 1;
                            // loop: judge the promoted head
                        }
                        Some(TxState::Committed) => {
                            if head.flags & flags::DELETED != 0 {
                                // an expunge: the stub and its whole
                                // chain go (no snapshot here can want
                                // them)
                                let Some(chain) =
                                    chain_members(file, page_size, dp_no, slot)
                                else {
                                    out.chains_skipped += 1;
                                    continue 'heads;
                                };
                                for m in &chain {
                                    free_slot(file, page_size, m.page, m.slot);
                                }
                                out.versions_removed += chain.len() as u64;
                                out.records_removed += 1;
                                continue 'heads;
                            }
                            if head.back_page != 0 {
                                // a live record's history: collect the
                                // chain BELOW the head, then cut the
                                // head's back pointer
                                let Some(chain) = chain_members(
                                    file,
                                    page_size,
                                    head.back_page,
                                    head.back_line,
                                ) else {
                                    out.chains_skipped += 1;
                                    continue 'heads;
                                };
                                for m in &chain {
                                    free_slot(file, page_size, m.page, m.slot);
                                }
                                out.versions_removed += chain.len() as u64;
                                let page = crate::page_mut(file, page_size, dp_no)
                                    .expect("gc head page out of range");
                                let dir = crate::data::DPG_RPT_OFFSET + slot as usize * 4;
                                let off = crate::u16_at(page, dir) as usize;
                                crate::dml::put_u32(page, off + 4, 0); // rhd_b_page
                                crate::dml::put_u16(page, off + 8, 0); // rhd_b_line
                            }
                            continue 'heads;
                        }
                        // limbo, or a state the TIP cannot answer:
                        // two-phase commit's territory, left whole
                        _ => {
                            out.chains_skipped += 1;
                            continue 'heads;
                        }
                    }
                }
            }
        }
    }
    // the header: nothing below next is interesting any more - the
    // engine lands oldest-active and oldest-snapshot at next and
    // oldest-transaction just below it (its own sweep transaction);
    // this server burns no id, so all three land at next
    let next = crate::u64_at(file, 40);
    file[48..56].copy_from_slice(&next.to_le_bytes()); // hdr_oldest_transaction
    file[56..64].copy_from_slice(&next.to_le_bytes()); // hdr_oldest_active
    file[64..72].copy_from_slice(&next.to_le_bytes()); // hdr_oldest_snapshot
    Ok(out)
}

#[cfg(test)]
mod sweep_tests {
    use super::*;
    use crate::dml::{
        begin_active_tx, delete_records_under, insert_record, insert_record_under, set_tx_state,
        update_record_under,
    };
    use crate::PageType;

    /// The same four-page scratch dml's own tests use: header, TIP, a
    /// pointer page for relation 42, one data page with a pre-existing
    /// 20-byte record in slot 0.
    fn scratch_file(page_size: usize) -> Vec<u8> {
        use crate::dml::{put_u16, put_u32};
        fn put_u64(f: &mut [u8], at: usize, v: u64) {
            f[at..at + 8].copy_from_slice(&v.to_le_bytes());
        }
        let mut f = vec![0u8; page_size * 4];
        f[0] = PageType::Header as u8;
        f[16..18].copy_from_slice(&(page_size as u16).to_le_bytes());
        put_u64(&mut f, 40, 10);
        let t = page_size;
        f[t] = PageType::TransactionInventory as u8;
        put_u32(&mut f, t + 12, 1);
        let p = page_size * 2;
        f[p] = PageType::Pointer as u8;
        put_u32(&mut f, p + 12, 2);
        put_u16(&mut f, p + 24, 1);
        put_u16(&mut f, p + 26, 42);
        put_u32(&mut f, p + 32, 3);
        let d = page_size * 3;
        f[d] = PageType::Data as u8;
        put_u32(&mut f, d + 12, 3);
        put_u16(&mut f, d + 20, 42);
        put_u16(&mut f, d + 22, 1);
        let off = page_size - 20;
        put_u16(&mut f, d + 24, off as u16);
        put_u16(&mut f, d + 26, 20);
        f
    }

    const NOBODY: &dyn Fn(u64) -> bool = &|_| false;

    /// THE FOUR SHAPES A SWEEP MEETS, on one file: a rolled-back insert
    /// vanishes whole; a rolled-back update is PROMOTED back to the
    /// value before it; a committed update's history is collected under
    /// a live head; and a version belonging to a HELD active
    /// transaction is not touched at all.
    #[test]
    fn a_sweep_collects_what_no_reader_can_want() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let img_a = vec![0u8, 1, 1, 1, 5, 5];
        let img_b = vec![0u8, 2, 2, 2, 6, 6];

        // slot A: committed insert, then a committed update (a back version)
        let a = insert_record(&mut f, ps, 42, 1, &img_a).unwrap();
        let tx1 = begin_active_tx(&mut f, ps).unwrap();
        update_record_under(&mut f, ps, 42, tx1 as u32, a.page_no, a.slot, &img_b, 1).unwrap();
        set_tx_state(&mut f, ps, tx1, TxState::Committed).unwrap();

        // slot B: a rolled-back INSERT
        let tx2 = begin_active_tx(&mut f, ps).unwrap();
        insert_record_under(&mut f, ps, 42, 1, &img_a, tx2 as u32).unwrap();
        set_tx_state(&mut f, ps, tx2, TxState::Dead).unwrap();

        // slot C: committed insert, then a ROLLED-BACK update
        let c = insert_record(&mut f, ps, 42, 1, &img_a).unwrap();
        let tx3 = begin_active_tx(&mut f, ps).unwrap();
        update_record_under(&mut f, ps, 42, tx3 as u32, c.page_no, c.slot, &img_b, 1).unwrap();
        set_tx_state(&mut f, ps, tx3, TxState::Dead).unwrap();

        // slot D: an insert under a HELD active transaction
        let tx4 = begin_active_tx(&mut f, ps).unwrap();
        let d = insert_record_under(&mut f, ps, 42, 1, &img_b, tx4 as u32).unwrap();

        let before = version_count(&f, ps, 42);
        let held = move |tx: u64| tx == tx4;
        let out = sweep(&mut f, ps, &held).unwrap();

        // A: history collected (1 back version); B: gone whole; C: the
        // dead update backed out (1 version); D: untouched
        assert_eq!(out.records_removed, 1, "the rolled-back insert");
        assert_eq!(out.versions_removed, 3);
        assert_eq!(out.stale_actives, 0);
        assert_eq!(version_count(&f, ps, 42), before - 3);

        // C reads its PRE-UPDATE image again - the promotion, verified
        // by bytes and not by counts
        let dp = crate::data::DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        let head_c = dp.record(c.slot).unwrap();
        assert_eq!(head_c.back_page, 0, "no chain left under C");
        // (a stored image may carry alignment padding past the format's
        // fields - the value bytes are what the assertion is about)
        let unpadded = |got: Vec<u8>, want: &[u8]| {
            got.starts_with(want) && got[want.len()..].iter().all(|b| *b == 0)
        };
        assert!(
            unpadded(crate::data::assembled_image(&f, ps, &head_c).unwrap(), &img_a),
            "the rolled-back update was backed out to the prior value"
        );
        // A keeps its POST-update image, history gone
        let head_a = dp.record(a.slot).unwrap();
        assert_eq!(head_a.back_page, 0);
        assert!(unpadded(crate::data::assembled_image(&f, ps, &head_a).unwrap(), &img_b));
        // D still there, still active
        assert!(dp.record(d.slot).is_some());

        // and a SECOND sweep finds nothing - idempotence is the cheap
        // proof nothing half-done was left behind
        let again = sweep(&mut f, ps, &held).unwrap();
        assert_eq!(again.versions_removed, 0);
        assert_eq!(again.records_removed, 0);
    }

    /// A committed DELETE is expunged - the stub and the chain behind
    /// it - and a STALE active (nobody holds its lock) is marked dead
    /// and backed out like the rollback it failed to be.
    #[test]
    fn stubs_are_expunged_and_stale_actives_are_dead() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let img = vec![0u8, 3, 3, 3, 7, 7];

        // a committed insert then a committed DELETE: stub over a version
        let a = insert_record(&mut f, ps, 42, 1, &img).unwrap();
        let tx1 = begin_active_tx(&mut f, ps).unwrap();
        delete_records_under(&mut f, ps, 42, &[(a.page_no, a.slot)], tx1 as u32).unwrap();
        set_tx_state(&mut f, ps, tx1, TxState::Committed).unwrap();

        // an insert under an active NOBODY holds
        let tx2 = begin_active_tx(&mut f, ps).unwrap();
        let b = insert_record_under(&mut f, ps, 42, 1, &img, tx2 as u32).unwrap();

        let out = sweep(&mut f, ps, NOBODY).unwrap();
        assert_eq!(out.stale_actives, 1, "the orphaned active was named");
        assert_eq!(out.records_removed, 2, "the expunged delete and the orphan");
        let dp = crate::data::DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        assert!(dp.record(a.slot).is_none(), "the stub and its chain are gone");
        assert!(dp.record(b.slot).is_none(), "the orphan's row is gone");
        // ...and the TIP now says DEAD where it said active
        let tips = TipChain::read(&f, ps).unwrap();
        assert_eq!(tips.state(tx2), Some(TxState::Dead));
        // the header moved past all of it
        let next = crate::u64_at(&f, 40);
        assert_eq!(crate::u64_at(&f, 48), next, "oldest transaction");
        assert_eq!(crate::u64_at(&f, 64), next, "oldest snapshot");
    }
}

