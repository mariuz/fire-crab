//! Writing records: the DML slice. `insert_record` places one new
//! committed record into an existing data page of a database FILE image,
//! doing what the engine's `VIO_store`/`DPM_store`/`TRA_commit` chain
//! does for the simplest case:
//!
//!   - allocate a transaction id from `hdr_next_transaction` (ods.h:669)
//!     and advance the header,
//!   - mark it committed in the transaction inventory (two bits, tra.h:
//!     487-490 - the same bits `TipChain` reads),
//!   - lay a record header + image into a data-page slot (dpm.epp's
//!     directory: offsets grow down from the page end, `dpg_rpt` entries
//!     grow up), flagged `rhd_not_packed` (ods.h:1018) so no RLE encoder
//!     is needed - the engine both writes and reads such records.
//!
//! `update_records`/`delete_records` are the MVCC half of `VIO_modify`/
//! `VIO_erase` + `DPM_update`: the current version is COPIED to a fresh
//! slot and flagged `rhd_chain` (a back version - ods.h:1007), then the
//! primary slot is rewritten under the new transaction with its
//! `rhd_b_page`/`rhd_b_line` pointing at the copy. An update's new
//! primary carries the new image; a delete's is a header-only DELETED
//! stub (`rhd_deleted`, no data - what `VIO_erase` leaves). The back
//! version is a FULL image, never a delta - legal on disk (the engine
//! writes full back versions itself whenever a delta would not shrink),
//! and exactly what the chain walk in `tra.rs` and the engine's own
//! garbage collector consume.
//!
//! When every existing data page is full, the relation GROWS: a page
//! is allocated from the PIP (`PAG_allocate_pages`, pag.cpp - the file
//! itself extending when the page lies past EOF), formatted as a data
//! page, and hooked into the relation's last pointer page with its
//! fill-bits byte (`DPM_allocate` + dpm.epp's extend path).
//!
//! This is an OFFLINE writer: it mutates a byte image the caller then
//! flushes as a whole. It does not implement careful-write ordering,
//! shadowing, crash safety, or index maintenance (DML on indexed
//! tables must be refused by callers until it does) - the write is
//! atomic only because the caller rewrites the file in one piece while
//! no engine is attached. The differential for all of this is the
//! engine itself: after DML, `isql` must see exactly the changed rows,
//! `gfix -v` must find nothing wrong - including the PIP and
//! pointer-page bookkeeping allocation touches - and `gfix -sweep`
//! must garbage-collect the very version chains written here.

use crate::data::{flags, DataPage, DPG_RPT_OFFSET, RHDF_DATA_OFFSET, RHD_DATA_OFFSET};
use crate::format::data_pages_per_pp;
use crate::pages::{PageHeader, PageType};
use crate::pip::{PipPage, PIP_BITS_OFFSET};
use crate::pointer::relation_data_pages;
use crate::tip::{TipPage, TIP_TRANSACTIONS_OFFSET};
use crate::{u16_at, u32_at, u64_at};

/// Where an insert landed - reported for tracing and tests.
#[derive(Debug, PartialEq)]
pub struct InsertOutcome {
    pub tx_id: u64,
    pub page_no: u32,
    pub slot: u16,
}

/// What a multi-record DML statement did: the single transaction all
/// its versions were written under, and how many records it touched.
#[derive(Debug, PartialEq)]
pub struct DmlOutcome {
    pub tx_id: u64,
    pub affected: usize,
}

pub(crate) fn put_u16(file: &mut [u8], at: usize, v: u16) {
    file[at..at + 2].copy_from_slice(&v.to_le_bytes());
}
pub(crate) fn put_u32(file: &mut [u8], at: usize, v: u32) {
    file[at..at + 4].copy_from_slice(&v.to_le_bytes());
}
fn put_u64(file: &mut [u8], at: usize, v: u64) {
    file[at..at + 8].copy_from_slice(&v.to_le_bytes());
}

/// Where transaction `tx`'s two bits live: the byte index in the file
/// and the shift within it. TIP pages chain via `tip_next`; the head is
/// the one no other TIP points to (the same walk `TipChain` does, done
/// index-wise so the caller can mutate).
fn tip_bits_at(file: &[u8], page_size: usize, tx: u64) -> Result<(u32, usize, u32), String> {
    let tips: Vec<(usize, u32, u32)> = file
        .chunks_exact(page_size)
        .enumerate()
        .filter(|(_, p)| p[0] == PageType::TransactionInventory as u8)
        .filter_map(|(i, p)| TipPage::decode(p).map(|t| (i, t.pag.page_no, t.next)))
        .collect();
    if tips.is_empty() {
        return Err("no transaction inventory pages".into());
    }
    let mut ordered: Vec<usize> = Vec::new();
    let mut cur = tips
        .iter()
        .map(|&(_, no, _)| no)
        .find(|no| !tips.iter().any(|&(_, _, next)| next == *no))
        .ok_or("TIP chain has no head")?;
    while cur != 0 {
        let &(idx, _, next) = tips
            .iter()
            .find(|&&(_, no, _)| no == cur)
            .ok_or("broken TIP chain")?;
        ordered.push(idx);
        cur = next;
    }
    let per_page = TipPage::transactions_per_page(page_size);
    let tip_idx = *ordered
        .get(tx as usize / per_page)
        .ok_or("transaction id beyond the TIP chain")?;
    let within = tx as usize % per_page;
    // the TIP page, the byte WITHIN it, and the 2-bit shift - the slot
    // is read/written through page_mut, not at an absolute file offset
    Ok((
        tip_idx as u32,
        TIP_TRANSACTIONS_OFFSET + within / 4,
        2 * (within % 4) as u32,
    ))
}

/// Put a transaction into a state in the TIP - `tra_active` 0,
/// `tra_limbo` 1, `tra_dead` 2, `tra_committed` 3 (tra.h:487).
///
/// The bits are CLEARED before the new state goes in: a commit follows
/// an active slot, and OR-ing onto whatever was there is only correct
/// when the slot reads zero.
pub fn set_tx_state(
    file: &mut [u8],
    page_size: usize,
    tx: u64,
    state: crate::tip::TxState,
) -> Result<(), String> {
    let (tip_page, byte, shift) = tip_bits_at(file, page_size, tx)?;
    let page = crate::page_mut(file, page_size, tip_page).ok_or("TIP page outside the file")?;
    let b = page.get_mut(byte).ok_or("TIP byte outside the page")?;
    *b = (*b & !(0b11 << shift)) | ((state as u8) << shift);
    Ok(())
}

/// Reserve a fresh transaction id, leaving it ACTIVE in the TIP - what
/// a transaction that has begun writing but not committed looks like to
/// everybody else, which is the whole point: a reader that walks the
/// versions skips a record written under it and takes the committed one
/// behind it.
///
/// The id is `hdr_next_transaction + 1`, and the header is advanced to
/// it so nobody else reserves the same one.
pub fn begin_active_tx(file: &mut [u8], page_size: usize) -> Result<u64, String> {
    // hdr_next_transaction @40 lives on the header, page 0
    let tx = u64_at(
        crate::page_at(file, page_size, 0).ok_or("no header page")?,
        40,
    ) + 1;
    // it must EXIST in the chain before the header claims it
    set_tx_state(file, page_size, tx, crate::tip::TxState::Active)?;
    put_u64(
        crate::page_mut(file, page_size, 0).ok_or("no header page")?,
        40,
        tx,
    );
    Ok(tx)
}

/// Allocate a fresh transaction id and mark it committed in the TIP.
/// The id is `hdr_next_transaction + 1` and the header is advanced to
/// it - correct whether the field holds the last id assigned or the
/// next to assign (the allocated id is unused either way, and future
/// engine transactions start above it).
///
/// This is the SETTLED write's allocation - a catalog row, a generator
/// page, anything whose visibility is not the transaction's to decide.
/// A user-table write in an open transaction takes [begin_active_tx]
/// instead and is committed at COMMIT.
pub(crate) fn allocate_committed_tx(file: &mut [u8], page_size: usize) -> Result<u64, String> {
    // hdr_next_transaction @40 lives on the header, page 0
    let tx = u64_at(
        crate::page_at(file, page_size, 0).ok_or("no header page")?,
        40,
    ) + 1;
    set_tx_state(file, page_size, tx, crate::tip::TxState::Committed)?;
    put_u64(
        crate::page_mut(file, page_size, 0).ok_or("no header page")?,
        40,
        tx,
    );
    Ok(tx)
}

/// A landing spot for a record: the page, the directory slot (an empty
/// one reused, or a fresh one appended), and the byte offset inside the
/// page where the record body goes.
struct Spot {
    page_no: u32,
    slot: u16,
    append: bool,
    offset: usize,
}

/// Find the first data page of `rel` with room for a `rec_len`-byte
/// record plus (if no empty slot is reusable) one more directory entry.
/// Free space on a data page is the gap between the directory's end and
/// the lowest used record offset - records grow down from the page end,
/// entries grow up (dpm.epp's layout).
fn find_space(file: &[u8], page_size: usize, rel: u16, rec_len: usize) -> Option<Spot> {
    let aligned = (rec_len + 3) & !3; // ODS_ALIGNMENT placement
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(page) = crate::page_at(file, page_size, dp_no) else {
            continue;
        };
        let Some(dp) = DataPage::decode(page) else {
            continue;
        };
        let count = dp.count;
        let mut bottom = page_size;
        let mut reuse: Option<u16> = None;
        for i in 0..count {
            let at = DPG_RPT_OFFSET + i as usize * 4;
            let (off, len) = (u16_at(page, at) as usize, u16_at(page, at + 2) as usize);
            if len == 0 {
                if reuse.is_none() {
                    reuse = Some(i);
                }
            } else if off < bottom {
                bottom = off;
            }
        }
        let (slot, append) = match reuse {
            Some(i) => (i, false),
            None => (count, true),
        };
        let dir_top = DPG_RPT_OFFSET + (count as usize + if append { 1 } else { 0 }) * 4;
        if bottom >= dir_top + aligned {
            let offset = (bottom - aligned) & !3;
            return Some(Spot { page_no: dp_no, slot, append, offset });
        }
    }
    None
}

/// Lay `rec` down at a found spot and point the directory at it. The
/// owning pointer page's per-slot fill bits are updated too: a record
/// landing on a page clears its `ppg_dp_empty` (0x10) bit - the
/// engine's DPM keeps those in sync and `gfix -v -full` warns when a
/// pointer page calls a non-empty data page empty.
fn write_at_spot(file: &mut [u8], page_size: usize, spot: &Spot, rec: &[u8]) {
    {
        // every byte here is on ONE page - the record body, its slot
        // directory entry, and the page's own count - so it is written
        // through that page (page-local offsets) rather than absolute
        // ones into the whole file.
        let page = crate::page_mut(file, page_size, spot.page_no)
            .expect("write_at_spot: page out of range");
        page[spot.offset..spot.offset + rec.len()].copy_from_slice(rec);
        let dir = DPG_RPT_OFFSET + spot.slot as usize * 4;
        put_u16(page, dir, spot.offset as u16);
        put_u16(page, dir + 2, rec.len() as u16);
        if spot.append {
            let count_at = 22; // dpg_count @22
            put_u16(page, count_at, u16_at(page, count_at) + 1);
        }
    }
    clear_fill_bits(file, page_size, spot.page_no, 0x10); // ppg_dp_empty
}

/// Find `page_no`'s slot on its relation's pointer pages and clear
/// `mask` in the fill-bits byte (ods.h:841-853: one byte per slot
/// after the full page-number vector capacity).
fn clear_fill_bits(file: &mut [u8], page_size: usize, page_no: u32, mask: u8) {
    let rel = u16_at(
        crate::page_at(file, page_size, page_no).expect("clear_fill_bits: page out of range"),
        20,
    ); // dpg_relation @20
    let capacity = data_pages_per_pp(page_size) as usize;
    let pps: Vec<usize> = file
        .chunks_exact(page_size)
        .enumerate()
        .filter(|(_, p)| p[0] == PageType::Pointer as u8 && u16_at(p, 26) == rel)
        .map(|(i, _)| i)
        .collect();
    for pp in pps {
        let page = crate::page_mut(file, page_size, pp as u32)
            .expect("clear_fill_bits: pointer page out of range");
        for slot in 0..capacity {
            if u32_at(page, 32 + slot * 4) == page_no {
                page[32 + capacity * 4 + slot] &= !mask;
                return;
            }
        }
    }
}

/// Serialize an rhd (ods.h:894) + data: transaction, b_page, b_line,
/// flags, format, then the record body.
fn rhd_bytes(tx: u32, b_page: u32, b_line: u16, rflags: u16, format: u8, data: &[u8]) -> Vec<u8> {
    let mut rec = Vec::with_capacity(RHD_DATA_OFFSET + data.len());
    rec.extend_from_slice(&tx.to_le_bytes());
    rec.extend_from_slice(&b_page.to_le_bytes());
    rec.extend_from_slice(&b_line.to_le_bytes());
    rec.extend_from_slice(&rflags.to_le_bytes());
    rec.push(format);
    rec.extend_from_slice(data);
    rec
}

/// Allocate one page from the first PIP (`PAG_allocate_pages`,
/// pag.cpp): the first set bit (set = FREE, ods.h:753) is cleared,
/// `pip_used` incremented and the `pip_min` hint advanced. The FILE
/// GROWS when the allocated page lies beyond its current end - free
/// bits past EOF are how the engine extends a database. Only the first
/// PIP (page 1) is handled; a database needing its second PIP (65312
/// pages at 8K) fails honestly.
/// Allocate one page from the first PIP: clear its free bit, bump the
/// used count and min-free hint, extend the file to cover it. Public
/// for the blob crate - blob pages are plain PIP allocations that no
/// pointer page ever names (dpm.epp allocates them the same way).
pub fn allocate_page(file: &mut Vec<u8>, page_size: usize) -> Result<u32, String> {
    let per_pip = PipPage::pages_per_pip(page_size);
    // PIP 0 is page 1: find a free page on it, then claim it - both
    // page-local on the PIP, the file only GROWS to cover the result
    let found = {
        let pip_bytes = crate::page_at(file, page_size, 1).ok_or("no PIP page")?;
        let pip = PipPage::decode(pip_bytes).ok_or("page 1 is not a PIP")?;
        let start = pip.min as usize;
        (start..per_pip)
            .chain(0..start) // the hint is only a hint
            .find(|&i| {
                pip_bytes
                    .get(PIP_BITS_OFFSET + i / 8)
                    .is_some_and(|b| b & (1 << (i % 8)) != 0)
            })
            .ok_or("first PIP exhausted (second-PIP allocation not converted)")?
    };
    {
        let pip = crate::page_mut(file, page_size, 1).ok_or("no PIP page")?;
        pip[PIP_BITS_OFFSET + found / 8] &= !(1 << (found % 8));
        let used = u32_at(pip, 24) + 1;
        pip[24..28].copy_from_slice(&used.to_le_bytes());
        if found as u32 >= u32_at(pip, 16) {
            pip[16..20].copy_from_slice(&((found as u32) + 1).to_le_bytes());
        }
    }
    let need = (found + 1) * page_size;
    if file.len() < need {
        file.resize(need, 0);
    }
    Ok(found as u32)
}

/// Grow a relation by one data page (`DPM_allocate` + the extend half
/// of dpm.epp's store path): allocate a page, format it as an empty
/// data page with the next `dpg_sequence`, and hook it into the
/// relation's LAST pointer page - the slot appended, the per-slot fill
/// byte (ods.h:841-853, one byte after the slot vector's full
/// `dataPagesPerPP` capacity) zeroed: the page is about to receive its
/// first record, so it is neither full nor empty.
fn extend_relation(file: &mut Vec<u8>, page_size: usize, rel: u16) -> Result<u32, String> {
    let sequence = relation_data_pages(file, page_size, rel).len() as u32;

    // the relation's last pointer page (highest ppg_sequence)
    let mut last: Option<(u32, u32)> = None; // (page number, sequence)
    for (i, p) in file.chunks_exact(page_size).enumerate() {
        if p[0] == PageType::Pointer as u8
            && PageHeader::decode(p).is_some()
            && u16_at(p, 26) == rel
        {
            let seq = u32_at(p, 16);
            if last.map_or(true, |(_, s)| seq > s) {
                last = Some((i as u32, seq));
            }
        }
    }
    let (pp, _) = last.ok_or("relation has no pointer page")?;
    let capacity = data_pages_per_pp(page_size) as usize;
    let slot = u16_at(
        crate::page_at(file, page_size, pp).ok_or("pointer page out of range")?,
        24,
    ) as usize; // ppg_count
    if slot >= capacity {
        return Err("pointer page full (new pointer pages not converted)".into());
    }

    let page_no = allocate_page(file, page_size)?;
    {
        // the freshly grown data page, formatted empty with its sequence
        let page = crate::page_mut(file, page_size, page_no).ok_or("new data page out of range")?;
        page.fill(0); // a freed page keeps stale bytes
        page[0] = PageType::Data as u8;
        page[12..16].copy_from_slice(&page_no.to_le_bytes()); // pag_pageno @12
        page[16..20].copy_from_slice(&sequence.to_le_bytes()); // dpg_sequence
        page[20..22].copy_from_slice(&rel.to_le_bytes()); // dpg_relation
                                                          // dpg_count stays 0
    }
    {
        // hook it into the relation's last pointer page
        let ppage = crate::page_mut(file, page_size, pp).ok_or("pointer page out of range")?;
        ppage[32 + slot * 4..36 + slot * 4].copy_from_slice(&page_no.to_le_bytes());
        ppage[32 + capacity * 4 + slot] = 0; // fill bits: not full, not empty
        ppage[24..26].copy_from_slice(&((slot as u16) + 1).to_le_bytes());
    }
    Ok(page_no)
}

/// Insert one record image (uncompressed, exactly the format's image
/// bytes: null-flag area + fields at their descriptor offsets) into the
/// first data page of `rel` with room - GROWING the relation by a
/// freshly allocated page when every existing one is full. The record
/// is stored NOT_PACKED under a freshly committed transaction.
pub fn insert_record(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    format_no: u8,
    image: &[u8],
) -> Result<InsertOutcome, String> {
    if u64::from(u16::try_from(RHD_DATA_OFFSET + image.len()).map_err(|_| "record too large")?)
        > page_size as u64
    {
        return Err("record larger than a page".into());
    }
    insert_record_as(file, page_size, rel, format_no, image, None)
}

/// [insert_record] under a transaction the CALLER owns - the wire
/// server's open transaction, still active in the TIP, so the row is
/// invisible to everybody else until that transaction commits.
pub fn insert_record_under(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    format_no: u8,
    image: &[u8],
    tx: u32,
) -> Result<InsertOutcome, String> {
    if u64::from(u16::try_from(RHD_DATA_OFFSET + image.len()).map_err(|_| "record too large")?)
        > page_size as u64
    {
        return Err("record larger than a page".into());
    }
    insert_record_as(file, page_size, rel, format_no, image, Some(tx))
}

/// [insert_record] under the SYSTEM transaction (id 0, no TIP work):
/// what `RDB$PAGES` rows require - the engine's `get_header`
/// (dpm.epp) posts isc_wrong_page for any relation-0 record whose
/// transaction is not 0 ("RDB$PAGES relation should be modified only
/// by system transaction"), and its release-build error path then
/// leaves a latched buffer behind - the attach appears to hang.
pub fn insert_record_system(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    format_no: u8,
    image: &[u8],
) -> Result<InsertOutcome, String> {
    insert_record_as(file, page_size, rel, format_no, image, Some(0))
}

fn insert_record_as(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    format_no: u8,
    image: &[u8],
    fixed_tx: Option<u32>,
) -> Result<InsertOutcome, String> {
    let rec_len = RHD_DATA_OFFSET + image.len();
    let spot = match find_space(file, page_size, rel, rec_len) {
        Some(s) => s,
        None => {
            // every existing page is full: grow the relation and retry
            extend_relation(file, page_size, rel)?;
            find_space(file, page_size, rel, rec_len)
                .ok_or("no room even on a fresh data page")?
        }
    };

    let tx = match fixed_tx {
        Some(t) => t as u64,
        None => {
            let tx = allocate_committed_tx(file, page_size)?;
            if tx > u32::MAX as u64 {
                return Err("64-bit transaction ids (rhde) not supported yet".into());
            }
            tx
        }
    };

    let rec = rhd_bytes(tx as u32, 0, 0, flags::NOT_PACKED, format_no, image);
    write_at_spot(file, page_size, &spot, &rec);
    // a primary record on the page contradicts dpg_secondary ("primary
    // record versions not stored on this page", ods.h:370) - the engine
    // clears it when storing a primary, and gfix -v -full checks
    // dpg_secondary lives in pag_flags @1 on the primary's own page
    crate::page_mut(file, page_size, spot.page_no)
        .expect("primary flags page out of range")[1] &= !0x10;
    // ...and the pointer page mirrors it per slot (ppg_dp_secondary)
    clear_fill_bits(file, page_size, spot.page_no, 0x08);
    Ok(InsertOutcome { tx_id: tx, page_no: spot.page_no, slot: spot.slot })
}

/// Release one page back to the PIP (`PAG_release_page`): its bit set
/// free again, `pip_used` decremented, the `pip_min` hint lowered.
/// The page bytes are left as-is - a freed page keeps stale content,
/// exactly like the engine (allocation zeroes on reuse).
pub(crate) fn release_page(file: &mut [u8], page_size: usize, page_no: u32) -> Result<(), String> {
    let per_pip = PipPage::pages_per_pip(page_size);
    if page_no as usize >= per_pip {
        return Err("page beyond the first PIP".into());
    }
    // every field is on PIP 0 (page 1); page-local offsets
    let pip = crate::page_mut(file, page_size, 1).ok_or("no PIP page")?;
    let bit = PIP_BITS_OFFSET + page_no as usize / 8;
    let mask = 1u8 << (page_no % 8);
    if pip[bit] & mask != 0 {
        return Ok(()); // already free
    }
    pip[bit] |= mask; // set = FREE (ods.h:753)
    let used = u32_at(pip, 24); // pip_used @24
    put_u32(pip, 24, used.saturating_sub(1));
    if u32_at(pip, 16) > page_no {
        // pip_min @16
        put_u32(pip, 16, page_no);
    }
    Ok(())
}

/// Write a level-0 SEGMENTED blob into `rel`'s data pages: the 32-byte
/// blh header (ods.h:969, offsets pinned by the static_asserts there)
/// followed by the segments, each `[u16 length][bytes]` - exactly the
/// framing `read_blob` strips. `blh_length` counts the segment
/// PAYLOADS only (framing excluded - the engine's blb_length), the
/// slot's directory length covers header + framed body. Charset is
/// always 1, as the engine writes for its metadata blobs (differential
/// probe of RDB$FORMATS/RDB$RUNTIME blobs). Returns the blob's record
/// number - what a blob id in an owning record points at.
pub fn insert_blob(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    segments: &[Vec<u8>],
    sub_type: u16,
) -> Result<u64, String> {
    // charset 1 is what the engine writes for its binary metadata blobs
    // (RDB$FORMATS/RDB$RUNTIME, ACLs) - probe-confirmed
    insert_blob_cs(file, page_size, rel, segments, sub_type, 1)
}

/// [insert_blob] with an explicit `blh_charset`. A subtype-1 TEXT blob -
/// a `COMMENT ON` description - carries charset 4 (UTF8, the metadata
/// charset), not 1; the engine's `CAST(RDB$DESCRIPTION AS VARCHAR)`
/// decodes through the blob's own charset, so it must match.
pub fn insert_blob_cs(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    segments: &[Vec<u8>],
    sub_type: u16,
    charset: u8,
) -> Result<u64, String> {
    let payload: usize = segments.iter().map(|s| s.len()).sum();
    let max_segment = segments.iter().map(|s| s.len()).max().unwrap_or(0);
    if max_segment > u16::MAX as usize {
        return Err("blob segment too long".into());
    }
    let mut rec = Vec::with_capacity(32 + payload + segments.len() * 2);
    rec.extend_from_slice(&0u32.to_le_bytes()); // blh_lead_page
    rec.extend_from_slice(&0u32.to_le_bytes()); // blh_max_sequence
    rec.extend_from_slice(&(max_segment as u16).to_le_bytes()); // blh_max_segment
    rec.extend_from_slice(&flags::BLOB.to_le_bytes()); // blh_flags
    rec.extend_from_slice(&(segments.len() as u32).to_le_bytes()); // blh_count
    rec.extend_from_slice(&(payload as u64).to_le_bytes()); // blh_length
    rec.extend_from_slice(&sub_type.to_le_bytes()); // blh_sub_type
    rec.push(charset); // blh_charset
    rec.push(0); // blh_level: data inline
    for seg in segments {
        rec.extend_from_slice(&(seg.len() as u16).to_le_bytes());
        rec.extend_from_slice(seg);
    }
    insert_blob_slot(file, page_size, rel, &rec)
}

/// Write a fully built blh (header + inline payload or page vector)
/// into a data-page slot of `rel` and return its record number - the
/// slot-placement tail every blob level shares (dpm.epp:2491 lays the
/// blh down in place of a record header). The caller owns the blh
/// bytes; this owns WHERE they live.
pub fn insert_blob_slot(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    blh: &[u8],
) -> Result<u64, String> {
    if blh.len() > page_size - DPG_RPT_OFFSET - 4 {
        return Err("blob header larger than a data-page slot".into());
    }
    let spot = match find_space(file, page_size, rel, blh.len()) {
        Some(s) => s,
        None => {
            extend_relation(file, page_size, rel)?;
            find_space(file, page_size, rel, blh.len())
                .ok_or("no room for the blob even on a fresh data page")?
        }
    };
    write_at_spot(file, page_size, &spot, blh);
    // the blob's record number: positional, like any record's
    let seq = crate::u32_at(
        crate::page_at(file, page_size, spot.page_no).ok_or("blob page out of range")?,
        16,
    ) as u64;
    Ok(seq * crate::format::max_recs_per_dp(page_size) + spot.slot as u64)
}

/// Copy the live primary record at (`page_no`, `slot`) - byte for byte,
/// its own transaction, flags and any further back pointer preserved -
/// into a fresh slot, flagged `rhd_chain`: it becomes the new primary's
/// back version, extending any existing chain (`VIO_modify`'s "the old
/// version goes to a new address" half of `DPM_update`). Returns where
/// the copy landed plus the record's format, for the caller's stub.
/// Poke a FRAGMENTED record's HEAD in place, leaving its tail untouched.
///
/// The five catalogue patch sites in `ddl.rs` change one or two fixed
/// fields of a system row - a blob id, a name, a flag - and then write
/// the whole image back through [update_records], which refuses a
/// fragmented record because [push_back_version] rejects
/// `rhd_incomplete`. On an ordinary `gbak`-restored database that refusal
/// costs 88 `COMMENT ON TABLE` and 92 `DROP INDEX` statements the engine
/// performs happily.
///
/// It is avoidable for the shape those sites actually have. MEASURED on a
/// restored 220-table schema: the head's own unpacked bytes are a BYTE
/// PREFIX of the assembled image in 266 of 266 fragmented rows, and every
/// field those sites poke lands inside it - 88 of 88 and 178 of 178. So
/// the change never reaches the tail, and the tail never has to move.
///
/// THE GUARD IS THE WHOLE DESIGN. Every poked range must end within the
/// head's unpacked length, or this refuses and the caller fails exactly
/// as it does today. A poke that ran past the head would have to re-split
/// the record across pages, which needs an `rhdf` writer, packed-stream
/// truncation, tail teardown and page compaction - four pieces of machinery
/// fire-crab does not have, each of which is a new way to write into a
/// user's database. Nothing in those 180 statements needs one.
///
/// What is deliberately NOT touched: the transaction id, the back
/// pointer, the format byte, `rhdf_f_page`/`rhdf_f_line`, and every
/// fragment after the head. This is a byte edit inside one record's own
/// payload, not a record rewrite - which is also why it does not push a
/// back version. Catalogue patches in the engine do not either.
///
/// Validated against the live engine before being written: 155 index
/// rows rewritten this way leave `gfix -v -full` silent, a full
/// column-by-column differential against an untouched baseline is
/// byte-identical INCLUDING tail-resident `RDB$SCHEMA_NAME`, and comment
/// text poked into 88 fragmented rows reads back through Firebird.
pub fn patch_head_in_place(
    file: &mut [u8],
    page_size: usize,
    page_no: u32,
    slot: u16,
    pokes: &[(usize, Vec<u8>)],
) -> Result<(), String> {
    let dir = DPG_RPT_OFFSET + slot as usize * 4; // page-local
    // the head's payload starts at RHDF_DATA_OFFSET, not RHD's 13
    let data_at = crate::data::RHDF_DATA_OFFSET;
    // read the slot entry and the head's packed payload off ITS page; the
    // payload is cloned out, so the read borrow drops before the repack
    let (off, len, rflags, packed) = {
        let page = crate::page_at(file, page_size, page_no).ok_or("page number out of range")?;
        if dir + 4 > page.len() {
            return Err("slot directory beyond the file".into());
        }
        let (off, len) = (u16_at(page, dir) as usize, u16_at(page, dir + 2) as usize);
        if len == 0 || off + len > page.len() {
            return Err("target slot is empty or corrupt".into());
        }
        let rflags = u16_at(page, off + 10);
        if rflags & flags::INCOMPLETE == 0 {
            return Err("not a fragmented record - use the ordinary update path".into());
        }
        if len < data_at {
            return Err("fragmented head shorter than its own header".into());
        }
        (off, len, rflags, page[off + data_at..off + len].to_vec())
    };
    let mut head = if rflags & flags::NOT_PACKED != 0 {
        packed.clone()
    } else {
        crate::sqz::unpack(&packed).ok_or("the head's payload does not decompress")?
    };
    // THE GUARD. Every poke must land entirely inside the head.
    for (at, bytes) in pokes {
        let end = at.checked_add(bytes.len()).ok_or("poke range overflows")?;
        if end > head.len() {
            return Err(
                "the field to patch lies past the record's first fragment;                  rewriting it would have to re-split the record across pages"
                    .into(),
            );
        }
    }
    for (at, bytes) in pokes {
        head[*at..*at + bytes.len()].copy_from_slice(bytes);
    }
    let repacked = if rflags & flags::NOT_PACKED != 0 {
        head
    } else {
        crate::sqz::pack(&head)
    };
    // The body must still fit the slot it already occupies. It normally
    // shrinks or holds (measured: -5 to -2 bytes on the COMMENT ON path,
    // and 155 of 155 index rows fit), because a poke changes bytes rather
    // than adding them - but a value that compresses worse than the one it
    // replaces can grow, and moving the body would mean re-pointing a
    // fragment chain this function promises not to touch.
    if data_at + repacked.len() > len {
        return Err(
            "the patched head no longer fits its slot; relocating it would              move a record whose tail points at this page"
                .into(),
        );
    }
    let page = crate::page_mut(file, page_size, page_no).ok_or("page number out of range")?;
    let start = off + data_at; // page-local
    page[start..start + repacked.len()].copy_from_slice(&repacked);
    // zero the remainder of the old body so no stale bytes remain inside
    // the record's own extent
    for b in page[start + repacked.len()..off + len].iter_mut() {
        *b = 0;
    }
    // and shorten the directory entry to what the record now occupies
    put_u16(page, dir + 2, (data_at + repacked.len()) as u16);
    Ok(())
}

fn push_back_version(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    page_no: u32,
    slot: u16,
) -> Result<(u32, u16, u8), String> {
    // read the live version off its page (page-local), clone it, and flag
    // it a back version - all before find_space/write_at_spot take the
    // file mutably; a record never spans its page, so the bound is the
    // page's length
    let (rec, format) = {
        let page = crate::page_at(file, page_size, page_no).ok_or("target page out of range")?;
        let dir = DPG_RPT_OFFSET + slot as usize * 4;
        let (off, len) = (u16_at(page, dir) as usize, u16_at(page, dir + 2) as usize);
        if len < RHD_DATA_OFFSET || off + len > page.len() {
            return Err("target slot is empty or corrupt".into());
        }
        let mut rec = page[off..off + len].to_vec();
        let rflags = u16_at(&rec, 10);
        if rflags
            & (flags::CHAIN | flags::BLOB | flags::FRAGMENT | flags::INCOMPLETE | flags::DELETED)
            != 0
        {
            return Err("target is not a live primary record version".into());
        }
        let format = rec[12];
        put_u16(&mut rec, 10, rflags | flags::CHAIN);
        (rec, format)
    };
    let spot = match find_space(file, page_size, rel, rec.len()) {
        Some(s) => s,
        None => {
            extend_relation(file, page_size, rel)?;
            find_space(file, page_size, rel, rec.len())
                .ok_or("no room for the back version even on a fresh page")?
        }
    };
    write_at_spot(file, page_size, &spot, &rec);
    Ok((spot.page_no, spot.slot, format))
}

/// Rewrite the primary slot in place: same page, same line (the record
/// number is positional - dpg_sequence and the slot index), new body.
/// The new body may be longer than the old (an RLE-packed record's
/// unpacked successor usually is), so space is re-found on the page
/// with the old body's bytes counted as free.
pub(crate) fn rewrite_primary(
    file: &mut [u8],
    page_size: usize,
    page_no: u32,
    slot: u16,
    rec: &[u8],
) -> Result<(), String> {
    // the placement decision reads only THIS page's directory; each read
    // is page-local, and the borrow is dropped before write_at_spot takes
    // the file mutably
    let (count, old_off, old_len) = {
        let page = crate::page_at(file, page_size, page_no).ok_or("primary page out of range")?;
        let count = u16_at(page, 22) as usize; // dpg_count
        if slot as usize >= count {
            return Err("primary slot out of range".into());
        }
        let dir = DPG_RPT_OFFSET + slot as usize * 4;
        (count, u16_at(page, dir) as usize, u16_at(page, dir + 2) as usize)
    };
    // a new body no longer than the old reuses the old body's own
    // space in place - which is the COMMON case (same format, same
    // image length) and the only reusable space on a FULL page, where
    // the freed slot sits mid-page and the bottom-of-free-space model
    // below cannot see it
    if old_len >= rec.len() && old_off != 0 {
        write_at_spot(
            file,
            page_size,
            &Spot { page_no, slot, append: false, offset: old_off },
            rec,
        );
        return Ok(());
    }
    let aligned = (rec.len() + 3) & !3;
    let bottom = {
        let page = crate::page_at(file, page_size, page_no).ok_or("primary page out of range")?;
        let mut bottom = page_size;
        for i in 0..count {
            if i == slot as usize {
                continue; // the old body is being replaced - its space is free
            }
            let at = DPG_RPT_OFFSET + i * 4;
            let (off, len) = (u16_at(page, at) as usize, u16_at(page, at + 2) as usize);
            if len != 0 && off < bottom {
                bottom = off;
            }
        }
        bottom
    };
    let dir_top = DPG_RPT_OFFSET + count * 4;
    if bottom < dir_top + aligned {
        return Err("no room on the page for the new record version".into());
    }
    let offset = (bottom - aligned) & !3;
    write_at_spot(
        file,
        page_size,
        &Spot { page_no, slot, append: false, offset },
        rec,
    );
    Ok(())
}

/// Update the primary record versions at `targets` - (page, slot, new
/// unpacked image) - under ONE freshly committed transaction: each old
/// version becomes a `rhd_chain` back version, each primary slot is
/// rewritten NOT_PACKED with the new image and a back pointer to it.
/// An empty target list allocates nothing and changes nothing. On an
/// error partway the file image is left inconsistent - callers work on
/// a copy and discard it (the whole-file-flush model).
pub fn update_records(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    targets: &[(u32, u16, Vec<u8>)],
    format_no: u8,
) -> Result<DmlOutcome, String> {
    if targets.is_empty() {
        return Ok(DmlOutcome { tx_id: 0, affected: 0 });
    }
    let tx = begin_committed_tx(file, page_size)?;
    for (page_no, slot, image) in targets {
        update_record_under(file, page_size, rel, tx, *page_no, *slot, image, format_no)?;
    }
    Ok(DmlOutcome { tx_id: tx as u64, affected: targets.len() })
}

/// Allocate ONE committed transaction id for a statement's writes - the
/// prologue [update_records] ran inline before it was split out so a
/// caller can interleave its per-row writes with per-row constraint
/// checks (the engine enforces UNIQUE/PK row at a time, in record-number
/// order, seeing the rows the same statement already rewrote).
pub fn begin_committed_tx(file: &mut Vec<u8>, page_size: usize) -> Result<u32, String> {
    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }
    Ok(tx as u32)
}

/// Rewrite ONE primary record version under an already-allocated
/// transaction - the loop body of [update_records], exposed so the wire
/// server can write and then index-check each row before touching the
/// next.
pub fn update_record_under(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    tx: u32,
    page_no: u32,
    slot: u16,
    image: &[u8],
    format_no: u8,
) -> Result<(), String> {
    let (b_page, b_line, _) = push_back_version(file, page_size, rel, page_no, slot)?;
    // RLE-pack the new version, as the engine stores records: the
    // primary must stay at its positional slot, so a NOT_PACKED
    // (uncompressed) image can overflow a tight page - packed, it is
    // the same size class as the original the slot already held
    let packed = crate::sqz::pack(image);
    let mut rec = if packed.len() < image.len() {
        rhd_bytes(tx, b_page, b_line, 0, format_no, &packed)
    } else {
        rhd_bytes(tx, b_page, b_line, flags::NOT_PACKED, format_no, image)
    };
    // dpm.epp's FILL: the engine zero-pads every stored record to
    // RHDF_SIZE (`fill = (RHDF_SIZE - header_size) - size`, dpm.epp:471)
    // so any slot can later become a fragment header in place. The pad
    // is legal on both encodings - validation forgives a zero tail on a
    // NOT_PACKED record, and a 0x00 control byte in an RLE stream is a
    // zero-length literal, a no-op (the engine memsets the fill AFTER
    // dcc.pack, so its own packed records carry the same tail). A
    // single-INT record written here without it is byte-shorter than
    // the engine's, harmless today but a gratuitous divergence.
    if rec.len() < RHDF_DATA_OFFSET {
        rec.resize(RHDF_DATA_OFFSET, 0);
    }
    rewrite_primary(file, page_size, page_no, slot, &rec)
}

/// Delete the primary record versions at `targets` under ONE freshly
/// committed transaction: each old version becomes a back version and
/// each primary slot is rewritten as a header-only DELETED stub
/// pointing at it - `VIO_erase`'s deleted stub, which readers treat as
/// "row gone" and the engine's garbage collector later expunges along
/// with the chain.
pub fn delete_records(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    targets: &[(u32, u16)],
) -> Result<DmlOutcome, String> {
    // the empty check comes FIRST: a statement that deletes nothing
    // burns no transaction id (a unit test holds this - it is what
    // makes `DELETE ... WHERE <no match>` free)
    if targets.is_empty() {
        return Ok(DmlOutcome { tx_id: 0, affected: 0 });
    }
    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }
    delete_records_under(file, page_size, rel, targets, tx as u32)
}

/// [delete_records] under a transaction the CALLER owns and will
/// commit later - the wire server's open transaction. The stub is
/// written the same way; what changes is that a reader who does not
/// count that transaction walks past the stub to the version behind
/// it and still sees the row.
pub fn delete_records_under(
    file: &mut Vec<u8>,
    page_size: usize,
    rel: u16,
    targets: &[(u32, u16)],
    tx: u32,
) -> Result<DmlOutcome, String> {
    if targets.is_empty() {
        return Ok(DmlOutcome { tx_id: 0, affected: 0 });
    }
    for (page_no, slot) in targets {
        let (b_page, b_line, format) = push_back_version(file, page_size, rel, *page_no, *slot)?;
        let stub = rhd_bytes(tx, b_page, b_line, flags::DELETED, format, &[]);
        rewrite_primary(file, page_size, *page_no, *slot, &stub)?;
    }
    Ok(DmlOutcome { tx_id: tx as u64, affected: targets.len() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::flags;

    /// A minimal two-page file: a header page (page 0) with
    /// next_transaction, a TIP (page 1), a pointer page (page 2) for
    /// relation 42 listing one data page (page 3) with one existing
    /// record.
    fn scratch_file(page_size: usize) -> Vec<u8> {
        let mut f = vec![0u8; page_size * 4];
        // header
        f[0] = PageType::Header as u8;
        f[16..18].copy_from_slice(&(page_size as u16).to_le_bytes());
        put_u64(&mut f, 40, 10); // next_transaction
        // TIP page 1
        let t = page_size;
        f[t] = PageType::TransactionInventory as u8;
        put_u32(&mut f, t + 12, 1); // pag_pageno @12
        // pointer page 2 for relation 42 -> data page 3
        let p = page_size * 2;
        f[p] = PageType::Pointer as u8;
        put_u32(&mut f, p + 12, 2); // pag_pageno @12
        put_u16(&mut f, p + 24, 1); // ppg_count @24
        put_u16(&mut f, p + 26, 42); // ppg_relation @26
        put_u32(&mut f, p + 32, 3); // first slot: data page 3
        // data page 3 with one 20-byte record at the end
        let d = page_size * 3;
        f[d] = PageType::Data as u8;
        f[d + 1] = 0;
        put_u32(&mut f, d + 12, 3); // pag_pageno @12
        put_u16(&mut f, d + 20, 42); // dpg_relation
        put_u16(&mut f, d + 22, 1); // dpg_count
        let off = page_size - 20;
        put_u16(&mut f, d + 24, off as u16);
        put_u16(&mut f, d + 26, 20);
        f
    }

    /// AN OPEN TRANSACTION LOOKS DIFFERENT IN THE FILE, which is the
    /// whole reason for it: its records are on the pages and its slot
    /// in the TIP reads `tra_active`, so a reader that walks the
    /// versions skips them until the commit flips the bits.
    #[test]
    fn a_transaction_is_active_until_it_is_committed() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let tx = begin_active_tx(&mut f, ps).unwrap();
        assert_eq!(tx, 11);
        assert_eq!(u64::from_le_bytes(f[40..48].try_into().unwrap()), 11); // header claimed it
        let bits = |f: &[u8], id: usize| (f[ps + TIP_TRANSACTIONS_OFFSET + id / 4] >> (2 * (id % 4))) & 3;
        assert_eq!(bits(&f, 11), 0, "tra_active");

        let image = vec![0u8, 7, 7, 7, 1, 2, 3, 4];
        let out = insert_record_under(&mut f, ps, 42, 1, &image, tx as u32).unwrap();
        assert_eq!(out.tx_id, 11, "the row carries the OPEN transaction");
        assert_eq!(bits(&f, 11), 0, "and writing did not commit it");
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        assert_eq!(dp.record(1).unwrap().transaction, 11);

        // commit: the same slot, the same row, two bits later
        set_tx_state(&mut f, ps, tx, crate::tip::TxState::Committed).unwrap();
        assert_eq!(bits(&f, 11), 3, "tra_committed");
        // and a rollback is a state too - the bits are CLEARED first,
        // so 3 -> 2 works and does not read as committed-or-dead
        set_tx_state(&mut f, ps, tx, crate::tip::TxState::Dead).unwrap();
        assert_eq!(bits(&f, 11), 2, "tra_dead");
    }

    /// A statement-owned delete writes the same stub as the settled
    /// one; what differs is whose transaction it carries.
    #[test]
    fn a_delete_can_carry_an_open_transaction() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let image = vec![0u8, 7, 7, 7, 9, 9];
        let ins = insert_record(&mut f, ps, 42, 1, &image).unwrap();
        let tx = begin_active_tx(&mut f, ps).unwrap();
        let out = delete_records_under(&mut f, ps, 42, &[(ins.page_no, ins.slot)], tx as u32).unwrap();
        assert_eq!(out.affected, 1);
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        let stub = dp.record(ins.slot).unwrap();
        assert!(stub.flags & flags::DELETED != 0);
        assert_eq!(stub.transaction, tx);
        let byte = ps + TIP_TRANSACTIONS_OFFSET + (tx as usize) / 4;
        assert_eq!((f[byte] >> (2 * (tx as usize % 4))) & 3, 0, "still active");
    }

    #[test]
    fn inserts_a_committed_not_packed_record() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let image = vec![0u8, 7, 7, 7, 1, 2, 3, 4]; // 8-byte image
        let out = insert_record(&mut f, ps, 42, 1, &image).unwrap();
        assert_eq!(out, InsertOutcome { tx_id: 11, page_no: 3, slot: 1 });
        // header advanced
        assert_eq!(u64::from_le_bytes(f[40..48].try_into().unwrap()), 11);
        // TIP: tx 11 committed (bits 3 at position 11)
        let byte = ps + TIP_TRANSACTIONS_OFFSET + 11 / 4;
        assert_eq!((f[byte] >> (2 * (11 % 4))) & 3, 3);
        // the record decodes back through the normal read path
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        assert_eq!(dp.count, 2);
        let rec = dp.record(1).unwrap();
        assert_eq!(rec.transaction, 11);
        assert_eq!(rec.format, 1);
        assert!(rec.flags & flags::NOT_PACKED != 0);
        assert!(rec.is_primary_record());
        assert_eq!(rec.image().unwrap(), image);
        // placed below the existing record, 4-aligned
        let (off, len) = dp.slot(1).unwrap();
        assert_eq!(len as usize, RHD_DATA_OFFSET + image.len());
        assert_eq!(off % 4, 0);
        assert!((off as usize + len as usize) <= ps - 20);
    }

    #[test]
    fn reuses_an_empty_slot_and_fails_when_full() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        // empty slot 1 in the directory (count 2, zero length)
        let d = ps * 3;
        put_u16(&mut f, d + 22, 2);
        put_u16(&mut f, d + 28, 0);
        put_u16(&mut f, d + 30, 0);
        let out = insert_record(&mut f, ps, 42, 1, &[0u8; 8]).unwrap();
        assert_eq!(out.slot, 1); // reused, not appended
        assert_eq!(DataPage::decode(&f[d..d + ps]).unwrap().count, 2);
        // an image too big for the remaining space fails cleanly
        let huge = vec![0u8; ps];
        assert!(insert_record(&mut f, ps, 42, 1, &huge).is_err());
    }

    #[test]
    fn update_chains_the_old_version_behind_the_new() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let old = vec![0u8, 1, 1, 1, 1, 1, 1, 1];
        let ins = insert_record(&mut f, ps, 42, 1, &old).unwrap();
        let new = vec![0u8, 2, 2, 2, 2, 2, 2, 2];
        let out =
            update_records(&mut f, ps, 42, &[(ins.page_no, ins.slot, new.clone())], 1).unwrap();
        assert_eq!(out, DmlOutcome { tx_id: 12, affected: 1 });
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        // the primary: new image, new tx, back pointer set
        let head = dp.record(ins.slot).unwrap();
        assert_eq!(head.transaction, 12);
        assert!(head.is_primary_record());
        assert_eq!(head.image().unwrap(), new);
        assert_eq!(head.back_page, 3);
        // the back version: byte copy of the old under rhd_chain
        let back = dp.record(head.back_line).unwrap();
        assert!(back.flags & flags::CHAIN != 0);
        assert!(!back.is_primary_record());
        assert_eq!(back.transaction, ins.tx_id);
        assert_eq!(back.image().unwrap(), old);
        assert_eq!(back.back_page, 0); // the chain ends at the insert
        // a second update extends the chain through the copy
        let newer = vec![0u8, 3, 3, 3, 3, 3, 3, 3];
        update_records(&mut f, ps, 42, &[(ins.page_no, ins.slot, newer.clone())], 1).unwrap();
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        let head = dp.record(ins.slot).unwrap();
        assert_eq!(head.image().unwrap(), newer);
        let mid = dp.record(head.back_line).unwrap();
        assert_eq!(mid.transaction, 12);
        assert_eq!(mid.image().unwrap(), new);
        assert!(mid.back_page != 0); // still points at the oldest copy
        // versions on the page: the scratch file's own record, the
        // chain head, and the two back copies
        assert_eq!(crate::gc::version_count(&f, ps, 42), 4);
    }

    #[test]
    fn insert_grows_the_relation_when_pages_are_full() {
        let ps = 4096;
        // header 0, PIP 1 (pages 0-4 used, rest free), TIP 2, pointer 3
        // (rel 42 -> data page 4), data 4 nearly full
        let mut f = vec![0u8; ps * 5];
        f[0] = PageType::Header as u8;
        f[16..18].copy_from_slice(&(ps as u16).to_le_bytes());
        put_u64(&mut f, 40, 10);
        let pip = ps;
        f[pip] = PageType::PageInventory as u8;
        put_u32(&mut f, pip + 12, 1);
        for b in &mut f[pip + PIP_BITS_OFFSET..pip + ps] {
            *b = 0xFF; // everything free...
        }
        f[pip + PIP_BITS_OFFSET] = 0b1110_0000; // ...except pages 0-4
        put_u32(&mut f, pip + 16, 5); // pip_min
        put_u32(&mut f, pip + 24, 5); // pip_used
        let t = ps * 2;
        f[t] = PageType::TransactionInventory as u8;
        put_u32(&mut f, t + 12, 2);
        let p = ps * 3;
        f[p] = PageType::Pointer as u8;
        put_u32(&mut f, p + 12, 3);
        put_u16(&mut f, p + 24, 1); // ppg_count
        put_u16(&mut f, p + 26, 42); // ppg_relation
        put_u32(&mut f, p + 32, 4); // slot 0: data page 4
        let d = ps * 4;
        f[d] = PageType::Data as u8;
        put_u32(&mut f, d + 12, 4);
        put_u16(&mut f, d + 20, 42);
        put_u16(&mut f, d + 22, 1);
        // one record occupying almost the whole page
        let big = ps - DPG_RPT_OFFSET - 4 - 32;
        put_u16(&mut f, d + 24, (ps - big) as u16);
        put_u16(&mut f, d + 26, big as u16);

        // no room on page 4: the insert must allocate page 5
        let image = vec![0u8; 64];
        let out = insert_record(&mut f, ps, 42, 1, &image).unwrap();
        assert_eq!((out.page_no, out.slot), (5, 0));
        assert_eq!(f.len(), ps * 6); // the FILE grew
        // the new page is a formatted data page with the next sequence
        let dp = DataPage::decode(&f[ps * 5..ps * 6]).unwrap();
        assert_eq!((dp.relation, dp.sequence, dp.count), (42, 1, 1));
        assert_eq!(dp.pag.page_no, 5);
        assert_eq!(dp.record(0).unwrap().image().unwrap(), image);
        // hooked into the pointer page, fill byte clear
        assert_eq!(u16_at(&f, p + 24), 2); // ppg_count
        assert_eq!(u32_at(&f, p + 36), 5); // slot 1 -> page 5
        let cap = data_pages_per_pp(ps) as usize;
        assert_eq!(f[p + 32 + cap * 4 + 1], 0);
        // the PIP: bit 5 cleared, hint and used advanced
        let pip = PipPage::decode(&f[ps..ps * 2]).unwrap();
        assert_eq!(pip.is_free(5), Some(false));
        assert_eq!(pip.is_free(6), Some(true));
        assert_eq!((pip.min, pip.used), (6, 6));
        // a second insert too big for page 5's remaining space grows again
        let big_img = vec![7u8; ps - 100];
        let out2 = insert_record(&mut f, ps, 42, 1, &big_img).unwrap();
        assert_eq!(out2.page_no, 6); // grew again
        assert_eq!(f.len(), ps * 7);
    }

    #[test]
    fn delete_leaves_a_stub_over_the_chain() {
        let ps = 4096;
        let mut f = scratch_file(ps);
        let image = vec![0u8, 9, 9, 9, 9, 9, 9, 9];
        let ins = insert_record(&mut f, ps, 42, 1, &image).unwrap();
        let out = delete_records(&mut f, ps, 42, &[(ins.page_no, ins.slot)]).unwrap();
        assert_eq!(out, DmlOutcome { tx_id: 12, affected: 1 });
        let dp = DataPage::decode(&f[ps * 3..ps * 4]).unwrap();
        let stub = dp.record(ins.slot).unwrap();
        assert!(stub.flags & flags::DELETED != 0);
        assert!(!stub.is_primary_record()); // COUNT no longer sees it
        assert!(stub.packed_data.is_empty()); // header-only, VIO_erase-style
        assert_eq!(stub.transaction, 12);
        assert_eq!(stub.format, 1);
        let back = dp.record(stub.back_line).unwrap();
        assert!(back.flags & flags::CHAIN != 0);
        assert_eq!(back.image().unwrap(), image);
        // deleting the stub again is refused - it is not a live primary
        assert!(delete_records(&mut f, ps, 42, &[(ins.page_no, ins.slot)]).is_err());
        // an empty target list is a no-op that burns no transaction
        let before = u64::from_le_bytes(f[40..48].try_into().unwrap());
        assert_eq!(
            delete_records(&mut f, ps, 42, &[]).unwrap(),
            DmlOutcome { tx_id: 0, affected: 0 }
        );
        assert_eq!(u64::from_le_bytes(f[40..48].try_into().unwrap()), before);
    }
}

#[cfg(test)]
mod head_patch_tests {
    use super::*;
    use crate::data::{DataPage, RHDF_DATA_OFFSET, RHDF_F_LINE_OFFSET, RHDF_F_PAGE_OFFSET};

    /// One page holding a fragmented HEAD at slot 0, pointing at page 2.
    fn page_with_head(payload: &[u8], head_flags: u16) -> Vec<u8> {
        let ps = 4096usize;
        let mut file = vec![0u8; ps * 3];
        let p = ps;
        file[p] = 5; // pag_data
        file[p + 20..p + 22].copy_from_slice(&128u16.to_le_bytes());
        file[p + 22..p + 24].copy_from_slice(&1u16.to_le_bytes());
        let packed = crate::sqz::pack(payload);
        let len = RHDF_DATA_OFFSET + packed.len();
        let r = ps - ((len + 3) & !3);
        let a = p + r;
        file[a..a + 4].copy_from_slice(&42u32.to_le_bytes()); // transaction
        file[a + 4..a + 8].copy_from_slice(&7u32.to_le_bytes()); // back page
        file[a + 8..a + 10].copy_from_slice(&3u16.to_le_bytes()); // back line
        file[a + 10..a + 12].copy_from_slice(&head_flags.to_le_bytes());
        file[a + 12] = 5; // format
        file[a + RHDF_F_PAGE_OFFSET..a + RHDF_F_PAGE_OFFSET + 4]
            .copy_from_slice(&2u32.to_le_bytes());
        file[a + RHDF_F_LINE_OFFSET..a + RHDF_F_LINE_OFFSET + 2]
            .copy_from_slice(&9u16.to_le_bytes());
        file[a + RHDF_DATA_OFFSET..a + RHDF_DATA_OFFSET + packed.len()]
            .copy_from_slice(&packed);
        file[p + DPG_RPT_OFFSET..p + DPG_RPT_OFFSET + 2]
            .copy_from_slice(&(r as u16).to_le_bytes());
        file[p + DPG_RPT_OFFSET + 2..p + DPG_RPT_OFFSET + 4]
            .copy_from_slice(&(len as u16).to_le_bytes());
        file
    }

    fn head_bytes(file: &[u8]) -> Vec<u8> {
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        let r = dp.record(0).unwrap();
        crate::sqz::unpack(r.packed_data).unwrap()
    }

    #[test]
    fn a_poke_inside_the_head_lands_and_changes_nothing_else() {
        let payload = b"AAAABBBBCCCCDDDDEEEEFFFF".to_vec();
        let mut file = page_with_head(&payload, flags::INCOMPLETE);
        let before = DataPage::decode(&file[4096..8192]).unwrap().record(0).unwrap();
        let (tx, bp, bl, fmt, fp) =
            (before.transaction, before.back_page, before.back_line, before.format,
             before.next_fragment());

        patch_head_in_place(&mut file, 4096, 1, 0, &[(8, b"ZZZZ".to_vec())]).unwrap();

        let mut want = payload.clone();
        want[8..12].copy_from_slice(b"ZZZZ");
        assert_eq!(head_bytes(&file), want);

        // and NOTHING else about the record moved
        let after = DataPage::decode(&file[4096..8192]).unwrap().record(0).unwrap();
        assert_eq!(after.transaction, tx, "transaction id must not change");
        assert_eq!(after.back_page, bp, "back pointer must not change");
        assert_eq!(after.back_line, bl);
        assert_eq!(after.format, fmt, "format must not be re-stamped");
        assert_eq!(after.next_fragment(), fp, "the fragment pointer must survive");
        assert_eq!(after.flags & flags::INCOMPLETE, flags::INCOMPLETE);
    }

    #[test]
    fn a_poke_past_the_head_is_refused() {
        // THE GUARD. A field living in the tail would need the record
        // re-split across pages - four pieces of machinery fire-crab does
        // not have. It must refuse, not write half of it.
        let mut file = page_with_head(b"SHORTPAYLOAD", flags::INCOMPLETE);
        let err = patch_head_in_place(&mut file, 4096, 1, 0, &[(10, b"XXXXXXXX".to_vec())])
            .unwrap_err();
        assert!(err.contains("past the record's first fragment"), "{}", err);
        // and the record is untouched
        assert_eq!(head_bytes(&file), b"SHORTPAYLOAD".to_vec());
    }

    #[test]
    fn an_unfragmented_record_is_refused_here() {
        // this path is only for fragmented records; an ordinary one must
        // go through update_records, which pushes a back version
        let mut file = page_with_head(b"AAAABBBB", 0);
        let err = patch_head_in_place(&mut file, 4096, 1, 0, &[(0, b"ZZZZ".to_vec())])
            .unwrap_err();
        assert!(err.contains("not a fragmented record"), "{}", err);
    }

    #[test]
    fn a_poke_that_would_grow_the_body_past_its_slot_is_refused() {
        // a highly compressible payload leaves a small slot; poking
        // incompressible bytes into it can make the repacked body longer
        // than the space the record occupies, and moving it would strand
        // a tail that points here
        let payload = vec![b'A'; 200];
        let mut file = page_with_head(&payload, flags::INCOMPLETE);
        let noise: Vec<u8> = (0..180u16).map(|i| (i * 7 % 251) as u8).collect();
        let r = patch_head_in_place(&mut file, 4096, 1, 0, &[(0, noise)]);
        assert!(r.is_err(), "an over-long repack must be refused");
        assert!(r.unwrap_err().contains("no longer fits its slot"));
        // untouched
        assert_eq!(head_bytes(&file), payload);
    }
}
