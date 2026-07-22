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
//! This is an OFFLINE writer: it mutates a byte image the caller then
//! flushes as a whole. It does not implement careful-write ordering,
//! shadowing, crash safety, page allocation, or index maintenance - the
//! write is atomic only because the caller rewrites the file in one
//! piece while no engine is attached. The differential for all of this
//! is the engine itself: after DML, `isql` must see exactly the changed
//! rows, `gfix -v` must find nothing wrong, and `gfix -sweep` must
//! garbage-collect the very version chains written here.

use crate::data::{flags, DataPage, DPG_RPT_OFFSET, RHD_DATA_OFFSET};
use crate::pages::PageType;
use crate::pointer::relation_data_pages;
use crate::tip::{TipPage, TIP_TRANSACTIONS_OFFSET};
use crate::u16_at;

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

fn put_u16(file: &mut [u8], at: usize, v: u16) {
    file[at..at + 2].copy_from_slice(&v.to_le_bytes());
}
fn put_u32(file: &mut [u8], at: usize, v: u32) {
    file[at..at + 4].copy_from_slice(&v.to_le_bytes());
}
fn put_u64(file: &mut [u8], at: usize, v: u64) {
    file[at..at + 8].copy_from_slice(&v.to_le_bytes());
}

/// Allocate a fresh transaction id and mark it committed in the TIP.
/// The id is `hdr_next_transaction + 1` and the header is advanced to
/// it - correct whether the field holds the last id assigned or the
/// next to assign (the allocated id is unused either way, and future
/// engine transactions start above it).
fn allocate_committed_tx(file: &mut [u8], page_size: usize) -> Result<u64, String> {
    let tx = u64::from_le_bytes(file[40..48].try_into().unwrap()) + 1; // hdr_next_transaction @40
    // find the TIP page holding this transaction's two bits: TIP pages
    // chain via tip_next; the head is the one no other TIP points to
    // (the same walk TipChain does, done index-wise so we can mutate)
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
    let byte = tip_idx * page_size + TIP_TRANSACTIONS_OFFSET + within / 4;
    let shift = 2 * (within % 4);
    // tra_committed = 3; a fresh slot reads 0 (active), so OR suffices
    file[byte] |= 3u8 << shift;
    put_u64(file, 40, tx);
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
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        let count = dp.count;
        let mut bottom = page_size;
        let mut reuse: Option<u16> = None;
        for i in 0..count {
            let at = start + DPG_RPT_OFFSET + i as usize * 4;
            let (off, len) = (u16_at(file, at) as usize, u16_at(file, at + 2) as usize);
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

/// Lay `rec` down at a found spot and point the directory at it.
fn write_at_spot(file: &mut [u8], page_size: usize, spot: &Spot, rec: &[u8]) {
    let base = spot.page_no as usize * page_size;
    file[base + spot.offset..base + spot.offset + rec.len()].copy_from_slice(rec);
    let dir = base + DPG_RPT_OFFSET + spot.slot as usize * 4;
    put_u16(file, dir, spot.offset as u16);
    put_u16(file, dir + 2, rec.len() as u16);
    if spot.append {
        let count_at = base + 22; // dpg_count @22
        put_u16(file, count_at, u16_at(file, count_at) + 1);
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

/// Insert one record image (uncompressed, exactly the format's image
/// bytes: null-flag area + fields at their descriptor offsets) into the
/// first data page of `rel` with room. The record is stored NOT_PACKED
/// under a freshly committed transaction. Fails - changing nothing - if
/// no existing data page has space (page allocation is not converted
/// yet) or the transaction cannot be allocated.
pub fn insert_record(
    file: &mut [u8],
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
    let rec_len = RHD_DATA_OFFSET + image.len();
    let spot = find_space(file, page_size, rel, rec_len)
        .ok_or("no data page with enough free space")?;

    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }

    let rec = rhd_bytes(tx as u32, 0, 0, flags::NOT_PACKED, format_no, image);
    write_at_spot(file, page_size, &spot, &rec);
    Ok(InsertOutcome { tx_id: tx, page_no: spot.page_no, slot: spot.slot })
}

/// Copy the live primary record at (`page_no`, `slot`) - byte for byte,
/// its own transaction, flags and any further back pointer preserved -
/// into a fresh slot, flagged `rhd_chain`: it becomes the new primary's
/// back version, extending any existing chain (`VIO_modify`'s "the old
/// version goes to a new address" half of `DPM_update`). Returns where
/// the copy landed plus the record's format, for the caller's stub.
fn push_back_version(
    file: &mut [u8],
    page_size: usize,
    rel: u16,
    page_no: u32,
    slot: u16,
) -> Result<(u32, u16, u8), String> {
    let base = page_no as usize * page_size;
    let dir = base + DPG_RPT_OFFSET + slot as usize * 4;
    let (off, len) = (u16_at(file, dir) as usize, u16_at(file, dir + 2) as usize);
    if len < RHD_DATA_OFFSET || base + off + len > file.len() {
        return Err("target slot is empty or corrupt".into());
    }
    let mut rec = file[base + off..base + off + len].to_vec();
    let rflags = u16_at(&rec, 10);
    if rflags
        & (flags::CHAIN | flags::BLOB | flags::FRAGMENT | flags::INCOMPLETE | flags::DELETED)
        != 0
    {
        return Err("target is not a live primary record version".into());
    }
    let format = rec[12];
    put_u16(&mut rec, 10, rflags | flags::CHAIN);
    let spot =
        find_space(file, page_size, rel, rec.len()).ok_or("no room for the back version")?;
    write_at_spot(file, page_size, &spot, &rec);
    Ok((spot.page_no, spot.slot, format))
}

/// Rewrite the primary slot in place: same page, same line (the record
/// number is positional - dpg_sequence and the slot index), new body.
/// The new body may be longer than the old (an RLE-packed record's
/// unpacked successor usually is), so space is re-found on the page
/// with the old body's bytes counted as free.
fn rewrite_primary(
    file: &mut [u8],
    page_size: usize,
    page_no: u32,
    slot: u16,
    rec: &[u8],
) -> Result<(), String> {
    let base = page_no as usize * page_size;
    let count = u16_at(file, base + 22) as usize; // dpg_count
    if slot as usize >= count {
        return Err("primary slot out of range".into());
    }
    let aligned = (rec.len() + 3) & !3;
    let mut bottom = page_size;
    for i in 0..count {
        if i == slot as usize {
            continue; // the old body is being replaced - its space is free
        }
        let at = base + DPG_RPT_OFFSET + i * 4;
        let (off, len) = (u16_at(file, at) as usize, u16_at(file, at + 2) as usize);
        if len != 0 && off < bottom {
            bottom = off;
        }
    }
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
    file: &mut [u8],
    page_size: usize,
    rel: u16,
    targets: &[(u32, u16, Vec<u8>)],
    format_no: u8,
) -> Result<DmlOutcome, String> {
    if targets.is_empty() {
        return Ok(DmlOutcome { tx_id: 0, affected: 0 });
    }
    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }
    for (page_no, slot, image) in targets {
        let (b_page, b_line, _) = push_back_version(file, page_size, rel, *page_no, *slot)?;
        let rec = rhd_bytes(tx as u32, b_page, b_line, flags::NOT_PACKED, format_no, image);
        rewrite_primary(file, page_size, *page_no, *slot, &rec)?;
    }
    Ok(DmlOutcome { tx_id: tx, affected: targets.len() })
}

/// Delete the primary record versions at `targets` under ONE freshly
/// committed transaction: each old version becomes a back version and
/// each primary slot is rewritten as a header-only DELETED stub
/// pointing at it - `VIO_erase`'s deleted stub, which readers treat as
/// "row gone" and the engine's garbage collector later expunges along
/// with the chain.
pub fn delete_records(
    file: &mut [u8],
    page_size: usize,
    rel: u16,
    targets: &[(u32, u16)],
) -> Result<DmlOutcome, String> {
    if targets.is_empty() {
        return Ok(DmlOutcome { tx_id: 0, affected: 0 });
    }
    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }
    for (page_no, slot) in targets {
        let (b_page, b_line, format) = push_back_version(file, page_size, rel, *page_no, *slot)?;
        let stub = rhd_bytes(tx as u32, b_page, b_line, flags::DELETED, format, &[]);
        rewrite_primary(file, page_size, *page_no, *slot, &stub)?;
    }
    Ok(DmlOutcome { tx_id: tx, affected: targets.len() })
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
