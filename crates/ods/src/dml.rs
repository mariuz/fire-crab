//! Writing records: the first DML slice. `insert_record` places one new
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
//! This is an OFFLINE writer: it mutates a byte image the caller then
//! flushes as a whole. It does not implement careful-write ordering,
//! shadowing, or crash safety - the write is atomic only because the
//! caller rewrites the file in one piece while no engine is attached.
//! The differential for all of this is the engine itself: after an
//! insert, `isql` must SELECT the row back, `gfix -v` must find nothing
//! wrong, and `gbak` must back the file up.

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
    let aligned = (rec_len + 3) & !3; // ODS_ALIGNMENT placement

    // find a data page with room, and where in it the record goes
    let mut target: Option<(u32, u16, bool, usize)> = None; // (page_no, slot, append, offset)
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        let count = dp.count;
        // lowest used record offset = bottom of free space
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
            target = Some((dp_no, slot, append, offset));
            break;
        }
    }
    let Some((page_no, slot, append, offset)) = target else {
        return Err("no data page with enough free space".into());
    };

    let tx = allocate_committed_tx(file, page_size)?;
    if tx > u32::MAX as u64 {
        return Err("64-bit transaction ids (rhde) not supported yet".into());
    }

    // rhd (ods.h:894): transaction, b_page, b_line, flags, format, data
    let base = page_no as usize * page_size;
    let at = base + offset;
    put_u32(file, at, tx as u32);
    put_u32(file, at + 4, 0); // rhd_b_page: no back version
    put_u16(file, at + 8, 0); // rhd_b_line
    put_u16(file, at + 10, flags::NOT_PACKED); // stored raw, ods.h:1018
    file[at + 12] = format_no;
    file[at + RHD_DATA_OFFSET..at + rec_len].copy_from_slice(image);

    // directory entry + count
    let dir = base + DPG_RPT_OFFSET + slot as usize * 4;
    put_u16(file, dir, offset as u16);
    put_u16(file, dir + 2, rec_len as u16);
    if append {
        let count_at = base + 22; // dpg_count @22
        put_u16(file, count_at, u16_at(file, count_at) + 1);
    }

    Ok(InsertOutcome { tx_id: tx, page_no, slot })
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
}
