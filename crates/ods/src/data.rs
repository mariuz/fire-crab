//! Data pages (`struct data_page`, ods.h:339) and record headers
//! (`struct rhd`/`rhde`, ods.h:894/916): the slot directory
//! (`dpg_rpt` offset/length pairs) and the record version headers it
//! points at, including the MVCC flags (ods.h:1006-1017) that the
//! record walk classifies versions with.

use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at};

/// Record header flags, ods.h:1006-1017.
pub mod flags {
    pub const DELETED: u16 = 1; // logically deleted stub
    pub const CHAIN: u16 = 2; // an old (back) version
    pub const FRAGMENT: u16 = 4; // continuation fragment
    pub const INCOMPLETE: u16 = 8; // record continues in fragments
    pub const BLOB: u16 = 16; // a blob, not a record
    pub const DELTA: u16 = 32; // prior version stored as differences
    pub const LARGE: u16 = 64;
    pub const DAMAGED: u16 = 128;
    pub const GC_ACTIVE: u16 = 256;
    pub const UK_MODIFIED: u16 = 512;
    pub const LONG_TRANUM: u16 = 1024; // 64-bit transaction id (rhde)
}

pub const DPG_RPT_OFFSET: usize = 24;
pub const RHD_DATA_OFFSET: usize = 13; // RHD_SIZE, ods.h:912
pub const RHDE_DATA_OFFSET: usize = 16; // rhde_data, ods.h:934

pub struct DataPage<'a> {
    pub pag: PageHeader,
    /// `dpg_sequence` - sequence within the relation
    pub sequence: u32,
    /// `dpg_relation` - owning relation id
    pub relation: u16,
    /// `dpg_count` - slots in the directory
    pub count: u16,
    page: &'a [u8],
}

/// One decoded record segment header (a primary version, back
/// version, fragment, blob or deleted stub - see `flags`).
#[derive(Clone, Debug)]
pub struct RecordHeader<'a> {
    pub slot: u16,
    /// Full transaction id; the high 16 bits come from `rhde_tra_high`
    /// when LONG_TRANUM is set (ods.h:916-925)
    pub transaction: u64,
    pub back_page: u32,
    pub back_line: u16,
    pub flags: u16,
    pub format: u8,
    /// The still-RLE-compressed record payload (feed to `sqz::unpack`)
    pub packed_data: &'a [u8],
}

impl RecordHeader<'_> {
    /// A primary, present record version - what `SELECT COUNT(*)`
    /// counts on a database with no uncommitted work: not a back
    /// version, not a fragment continuation, not a blob, not deleted.
    pub fn is_primary_record(&self) -> bool {
        self.flags & (flags::CHAIN | flags::FRAGMENT | flags::BLOB | flags::DELETED) == 0
    }
}

impl<'a> DataPage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<DataPage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::Data as u8 {
            return None;
        }
        Some(DataPage {
            pag,
            sequence: u32_at(page, 16), // dpg_sequence @16
            relation: u16_at(page, 20), // dpg_relation @20
            count: u16_at(page, 22),    // dpg_count @22
            page,
        })
    }

    /// The (offset, length) directory entry for `slot`
    /// (dpg_rpt @24, 4 bytes per entry; length 0 = empty slot).
    pub fn slot(&self, i: u16) -> Option<(u16, u16)> {
        if i >= self.count {
            return None;
        }
        let at = DPG_RPT_OFFSET + i as usize * 4;
        Some((u16_at(self.page, at), u16_at(self.page, at + 2)))
    }

    /// Decode the record header in `slot`, if the slot is occupied
    /// and sane (offset/length inside the page).
    pub fn record(&self, i: u16) -> Option<RecordHeader<'a>> {
        let (offset, length) = self.slot(i)?;
        if length == 0 {
            return None;
        }
        let start = offset as usize;
        let end = start + length as usize;
        if start < DPG_RPT_OFFSET || end > self.page.len() || length < RHD_DATA_OFFSET as u16 {
            return None;
        }
        let r = &self.page[start..end];

        let flags = u16_at(r, 10); // rhd_flags @10
        let (transaction, data_at) = if flags & flags::LONG_TRANUM != 0 {
            // rhde: 64-bit id split low/high (ods.h:918/923)
            let low = u32_at(r, 0) as u64;
            let high = u16_at(r, 14) as u64;
            (high << 32 | low, RHDE_DATA_OFFSET)
        } else {
            (u32_at(r, 0) as u64, RHD_DATA_OFFSET)
        };
        if r.len() < data_at {
            return None;
        }

        Some(RecordHeader {
            slot: i,
            transaction,
            back_page: u32_at(r, 4), // rhd_b_page @4
            back_line: u16_at(r, 8), // rhd_b_line @8
            flags,
            format: r[12], // rhd_format @12
            packed_data: &r[data_at..],
        })
    }

    /// All occupied record segments on the page.
    pub fn records(&self) -> impl Iterator<Item = RecordHeader<'a>> + '_ {
        (0..self.count).filter_map(|i| self.record(i))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_page(records: &[(u16, &[u8])]) -> Vec<u8> {
        // build a data page with the given (flags, payload) records
        let mut page = vec![0u8; 4096];
        page[0] = 5; // pag_data
        page[16..20].copy_from_slice(&2u32.to_le_bytes()); // dpg_sequence
        page[20..22].copy_from_slice(&128u16.to_le_bytes()); // dpg_relation
        page[22..24].copy_from_slice(&(records.len() as u16).to_le_bytes());

        let mut write_at = 4096;
        for (i, (fl, payload)) in records.iter().enumerate() {
            let len = RHD_DATA_OFFSET + payload.len();
            write_at -= len;
            let r = write_at;
            page[r..r + 4].copy_from_slice(&7u32.to_le_bytes()); // rhd_transaction
            page[r + 4..r + 8].copy_from_slice(&0u32.to_le_bytes()); // rhd_b_page
            page[r + 8..r + 10].copy_from_slice(&0u16.to_le_bytes()); // rhd_b_line
            page[r + 10..r + 12].copy_from_slice(&fl.to_le_bytes()); // rhd_flags
            page[r + 12] = 1; // rhd_format
            page[r + 13..r + 13 + payload.len()].copy_from_slice(payload);

            let e = DPG_RPT_OFFSET + i * 4;
            page[e..e + 2].copy_from_slice(&(r as u16).to_le_bytes());
            page[e + 2..e + 4].copy_from_slice(&(len as u16).to_le_bytes());
        }
        page
    }

    #[test]
    fn dpg_layout_and_record_walk() {
        let page = mk_page(&[
            (0, b"\x02hi"),            // primary
            (flags::CHAIN, b"\x02ol"), // back version
            (flags::DELETED, b""),     // deleted stub
        ]);
        let dp = DataPage::decode(&page).unwrap();
        assert_eq!(dp.sequence, 2);
        assert_eq!(dp.relation, 128);
        assert_eq!(dp.count, 3);

        let recs: Vec<_> = dp.records().collect();
        assert_eq!(recs.len(), 3);
        assert_eq!(recs[0].transaction, 7);
        assert_eq!(recs[0].format, 1);
        assert!(recs[0].is_primary_record());
        assert!(!recs[1].is_primary_record());
        assert!(!recs[2].is_primary_record());
        assert_eq!(crate::sqz::unpack(recs[0].packed_data).unwrap(), b"hi");
    }

    #[test]
    fn long_tranum_uses_rhde_layout() {
        // the payload bytes double as the rhde_tra_high slot (offset
        // 14-15 of the record) plus one data byte past rhde_data
        let mut page = mk_page(&[(flags::LONG_TRANUM, b"\x00\x00\x00")]);
        // patch rhde_tra_high (offset 14 in the record) to 3
        let (off, _len) = DataPage::decode(&page).unwrap().slot(0).unwrap();
        page[off as usize + 14..off as usize + 16].copy_from_slice(&3u16.to_le_bytes());

        let dp = DataPage::decode(&page).unwrap();
        let r = dp.record(0).unwrap();
        assert_eq!(r.transaction, (3u64 << 32) | 7);
    }

    #[test]
    fn empty_and_insane_slots_are_skipped() {
        let mut page = mk_page(&[(0, b"\x02hi")]);
        // grow the directory with an empty slot and a lying slot
        page[22..24].copy_from_slice(&3u16.to_le_bytes());
        let e1 = DPG_RPT_OFFSET + 4; // slot 1: length 0
        page[e1..e1 + 4].copy_from_slice(&0u32.to_le_bytes());
        let e2 = DPG_RPT_OFFSET + 8; // slot 2: points past the page
        page[e2..e2 + 2].copy_from_slice(&4000u16.to_le_bytes());
        page[e2 + 2..e2 + 4].copy_from_slice(&500u16.to_le_bytes());

        let dp = DataPage::decode(&page).unwrap();
        assert_eq!(dp.records().count(), 1);
    }
}
