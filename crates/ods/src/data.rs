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
    /// same bit as DELTA - on a blob slot it means stream-mode (no
    /// segment framing), ods.h:1011-1012 (`rhd_stream_blob`)
    pub const STREAM_BLOB: u16 = 32;
    pub const LARGE: u16 = 64;
    pub const DAMAGED: u16 = 128;
    pub const GC_ACTIVE: u16 = 256;
    pub const UK_MODIFIED: u16 = 512;
    pub const LONG_TRANUM: u16 = 1024; // 64-bit transaction id (rhde)
    pub const NOT_PACKED: u16 = 2048; // image stored raw, no RLE (ods.h:1018)
}

pub const DPG_RPT_OFFSET: usize = 24;
pub const RHD_DATA_OFFSET: usize = 13; // RHD_SIZE, ods.h:912
pub const RHDE_DATA_OFFSET: usize = 16; // rhde_data, ods.h:934
/// `rhdf_data`, ods.h:961 - a FRAGMENTED record's header is nine bytes
/// longer than `rhd`'s, because it carries a forward pointer to the next
/// fragment (`rhdf_f_page` @16, `rhdf_f_line` @20).
pub const RHDF_DATA_OFFSET: usize = 22;
/// `rhdf_f_page` / `rhdf_f_line` (ods.h:947-948).
pub const RHDF_F_PAGE_OFFSET: usize = 16;
pub const RHDF_F_LINE_OFFSET: usize = 20;

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
    /// `(rhdf_f_page, rhdf_f_line)` when this record continues in a
    /// fragment elsewhere (ods.h:947-948); `None` otherwise.
    pub frag_ptr: Option<(u32, u16)>,
}

impl RecordHeader<'_> {
    /// A primary, present record version - what `SELECT COUNT(*)`
    /// counts on a database with no uncommitted work: not a back
    /// version, not a fragment continuation, not a blob, not deleted.
    pub fn is_primary_record(&self) -> bool {
        self.flags & (flags::CHAIN | flags::FRAGMENT | flags::BLOB | flags::DELETED) == 0
    }

    /// Where this record continues, when it does: `(rhdf_f_page,
    /// rhdf_f_line)` (ods.h:947-948). `None` for an ordinary record.
    pub fn next_fragment(&self) -> Option<(u32, u16)> {
        self.frag_ptr
    }

    /// The unpacked record image: `NOT_PACKED` records (ods.h:1018,
    /// stored "as is") pass through, everything else goes through the
    /// sqz codec.
    ///
    /// **A FRAGMENTED RECORD ANSWERS `None` HERE, DELIBERATELY.** Its
    /// payload is only the first piece of the row; the rest lives on
    /// other pages and this type cannot reach them. Returning the piece
    /// would hand every caller a short image whose later fields decode
    /// as missing or wrong - silently. Callers that can reach the file
    /// use [assembled_image], which follows the chain; the rest keep
    /// skipping the record, which is what they did before this was
    /// understood (the mis-offset payload happened to fail to unpack)
    /// and is the safe half of the two behaviours.
    pub fn image(&self) -> Option<Vec<u8>> {
        self.image_prefix(usize::MAX)
    }

    /// [image], decompressing only enough to cover the first `min_len`
    /// bytes - the prefix a reader that decodes only low-offset fields
    /// needs. `usize::MAX` is the whole record, exactly as [image] was.
    /// A fragmented head has no single packed stream to cut, so this
    /// declines it (as [image] does) and the assembler handles it whole.
    pub fn image_prefix(&self, min_len: usize) -> Option<Vec<u8>> {
        if self.flags & flags::INCOMPLETE != 0 {
            return None;
        }
        if self.flags & flags::NOT_PACKED != 0 {
            let n = min_len.min(self.packed_data.len());
            Some(self.packed_data[..n].to_vec())
        } else {
            crate::sqz::unpack_prefix(self.packed_data, min_len)
        }
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

    /// The raw bytes of an occupied slot. For blob slots this is the
    /// `blh` struct itself - dpm.epp:2491 lays the blh down IN PLACE
    /// of a record header (`blh_flags` aliases `rhd_flags` at offset
    /// 10), so blob slots must not be parsed as rhd.
    pub fn slot_bytes(&self, i: u16) -> Option<&'a [u8]> {
        let (offset, length) = self.slot(i)?;
        if length == 0 {
            return None;
        }
        let start = offset as usize;
        let end = start + length as usize;
        if start < DPG_RPT_OFFSET || end > self.page.len() {
            return None;
        }
        Some(&self.page[start..end])
    }

    /// Decode the record header in `slot`, if the slot is occupied
    /// and sane (offset/length inside the page). Blob slots (see
    /// [DataPage::slot_bytes]) yield a header whose `packed_data` is
    /// empty - use `slot_bytes` for the blh.
    pub fn record(&self, i: u16) -> Option<RecordHeader<'a>> {
        let r = self.slot_bytes(i)?;
        if r.len() < RHD_DATA_OFFSET {
            return None;
        }

        let flags = u16_at(r, 10); // rhd_flags @10 (= blh_flags @10)
        if flags & flags::BLOB != 0 {
            return Some(RecordHeader {
                slot: i,
                transaction: 0,
                back_page: 0,
                back_line: 0,
                flags,
                format: 0,
                packed_data: &[],
                frag_ptr: None,
            });
        }
        // WHICH HEADER IS THIS? Three layouts, and the choice used to be
        // made on LONG_TRANUM alone - which silently mis-read every
        // FRAGMENTED record, because `rhdf` is longer than both.
        //
        // A record that continues elsewhere carries `rhd_incomplete` and
        // is stored as `rhdf`: nine bytes longer than `rhd`, the extra
        // being `rhdf_tra_high` plus the forward pointer. Reading its
        // payload from offset 13 therefore starts NINE BYTES EARLY, on
        // the pointer itself - measured on a live database, the bytes
        // fire-crab called payload began `81 81 81 | 27 10 00 00 | 06 00`,
        // which is padding, then f_page = 4135, then f_line = 6.
        let (transaction, data_at) = if flags & flags::INCOMPLETE != 0 {
            // rhdf's payload starts at 22 whatever the transaction width.
            // But the HIGH WORD is only present when LONG_TRANUM says so
            // - `Ods::getTraNum` (ods.cpp:157-169) reads it ONLY inside
            // `if (rhd_flags & rhd_long_tranum)`, and picks the rhdf or
            // rhde field by rhd_incomplete INSIDE that test. Reading it
            // unconditionally invents a transaction: on the fixture here
            // the bytes at 14 are 0x8181, which would have made every
            // fragmented row claim transaction 0x8181_00000000 + its
            // real id, and MVCC visibility is decided on that number.
            let low = u32_at(r, 0) as u64;
            let high = if flags & flags::LONG_TRANUM != 0 {
                u16_at(r, 14) as u64
            } else {
                0
            };
            (high << 32 | low, RHDF_DATA_OFFSET)
        } else if flags & flags::LONG_TRANUM != 0 {
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
            frag_ptr: (flags & flags::INCOMPLETE != 0).then(|| {
                (u32_at(r, RHDF_F_PAGE_OFFSET), u16_at(r, RHDF_F_LINE_OFFSET))
            }),
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

/// The WHOLE record image, following the fragment chain when there is
/// one. `None` for the same reasons [RecordHeader::image] answers `None`,
/// plus a broken or looping chain.
///
/// A record too large for one page is stored as a head carrying
/// `rhd_incomplete` and a forward pointer (`rhdf_f_page` @16,
/// `rhdf_f_line` @20, data at 22), plus continuation fragments carrying
/// `rhd_fragment`, each pointing at the next.
///
/// **EACH PIECE IS DECODED WITH ITS OWN FLAGS, and that is not a detail.**
/// `vio.cpp:1849` unpacks the head, then `:1861-1865` loops
/// `while (rpb_flags & rpb_incomplete) { DPM_fetch_fragment(); unpack(rpb, ...) }`
/// - and `unpack` (vio.cpp:575-602) tests `rpb_not_packed` on every call.
/// So `NOT_PACKED` is a property of the PIECE, not of the record, and a
/// chain can mix a raw head with a compressed tail.
///
/// The first version of this function joined the compressed bytes and
/// unpacked once. That gives the same answer whenever every piece is
/// packed - measured, a head unpacking to 828 bytes and its fragment to
/// 754 give exactly 1582 either way, because the codec is a byte stream
/// with no header of its own - and it is simply WRONG on a mixed chain,
/// where it either splices raw bytes into a compressed stream or (as it
/// did) refuses the record and loses the row. The all-packed case is not
/// the general case; it is what one fixture happened to contain.
///
/// What this recovers is not academic. On a 99-relation database
/// `RDB$INDEX_SEGMENTS` held fifteen fragmented rows, and because they
/// were unreadable SEVENTEEN of sixty-nine indexes did not exist as far
/// as the optimizer was concerned - `WHERE K = 5` planned NATURAL where
/// the engine planned INDEX. The first row this assembled decoded to
/// `PK_BS2P_500` on table `BS2P_500`, the first index on that list.
pub fn assembled_image(
    file: &crate::Image,
    page_size: usize,
    head: &RecordHeader<'_>,
) -> Option<Vec<u8>> {
    assembled_image_prefix(file, page_size, head, usize::MAX)
}

/// [assembled_image], decompressing only enough to cover the first
/// `min_len` bytes of a NON-FRAGMENTED head - so a scan projecting a
/// low-offset column decompresses a prefix instead of the whole record.
/// A fragmented record is spread across pages and reconstructed whole
/// (the prefix cut does not apply), and `usize::MAX` is the whole record
/// either way, exactly as [assembled_image] always was.
///
/// SAFETY: the returned image may be SHORTER than the record, so a field
/// whose bytes fall past `min_len` reads out of bounds and decodes to
/// `Unsupported`. The caller must pass a `min_len` covering every field
/// it reads (an over-estimate is safe, an under-estimate is a wrong
/// answer), and must NOT feed a prefix into MVCC delta reconstruction,
/// which needs the whole image - see the re-decompress in
/// `tra::visible_version_2pc`.
pub fn assembled_image_prefix(
    file: &crate::Image,
    page_size: usize,
    head: &RecordHeader<'_>,
    min_len: usize,
) -> Option<Vec<u8>> {
    if head.flags & flags::INCOMPLETE == 0 {
        return head.image_prefix(min_len);
    }
    // one piece, by ITS OWN flags (vio.cpp:575-602)
    let piece = |flags: u16, bytes: &[u8]| -> Option<Vec<u8>> {
        if flags & flags::NOT_PACKED != 0 {
            Some(bytes.to_vec())
        } else {
            crate::sqz::unpack(bytes)
        }
    };
    let mut out = piece(head.flags, head.packed_data)?;
    let mut next = head.next_fragment();
    // A chain longer than the file has pages is a corrupt file, not a
    // long record; bound it rather than loop forever.
    let max_hops = (file.byte_len() / page_size.max(1)).max(1);
    let mut hops = 0usize;
    while let Some((pno, line)) = next {
        hops += 1;
        if pno == 0 || hops > max_hops {
            return None;
        }
        let dp = crate::page_at(file, page_size, pno).and_then(DataPage::decode)?;
        let frag = dp.record(line)?;
        if frag.flags & flags::FRAGMENT == 0 {
            return None; // the chain points at something that is not one
        }
        out.extend_from_slice(&piece(frag.flags, frag.packed_data)?);
        next = frag.next_fragment();
    }
    Some(out)
}

#[cfg(test)]
mod frag_tests {
    use super::*;

    /// Build a two-page file: page 1 holds a fragmented HEAD pointing at
    /// page 2 slot 0, which holds the continuation.
    fn two_page_chain(head_payload: &[u8], frag_payload: &[u8], frag_flags: u16) -> Vec<u8> {
        let ps = 4096usize;
        let mut file = vec![0u8; ps * 3];
        // --- page 1: the head, rhdf layout, INCOMPLETE ---
        let p = ps; // page index 1
        file[p] = 5; // pag_data
        file[p + 16..p + 20].copy_from_slice(&0u32.to_le_bytes());
        file[p + 20..p + 22].copy_from_slice(&128u16.to_le_bytes());
        file[p + 22..p + 24].copy_from_slice(&1u16.to_le_bytes());
        let len = RHDF_DATA_OFFSET + head_payload.len();
        let r = ps - len; // offset within the page
        let a = p + r;
        file[a + 10..a + 12].copy_from_slice(&flags::INCOMPLETE.to_le_bytes());
        file[a + 12] = 1;
        file[a + RHDF_F_PAGE_OFFSET..a + RHDF_F_PAGE_OFFSET + 4]
            .copy_from_slice(&2u32.to_le_bytes()); // next page = 2
        file[a + RHDF_F_LINE_OFFSET..a + RHDF_F_LINE_OFFSET + 2]
            .copy_from_slice(&0u16.to_le_bytes()); // next line = 0
        file[a + RHDF_DATA_OFFSET..a + RHDF_DATA_OFFSET + head_payload.len()]
            .copy_from_slice(head_payload);
        file[p + DPG_RPT_OFFSET..p + DPG_RPT_OFFSET + 2]
            .copy_from_slice(&(r as u16).to_le_bytes());
        file[p + DPG_RPT_OFFSET + 2..p + DPG_RPT_OFFSET + 4]
            .copy_from_slice(&(len as u16).to_le_bytes());
        // --- page 2: the terminal fragment, plain rhd layout ---
        let q = ps * 2;
        file[q] = 5;
        file[q + 16..q + 20].copy_from_slice(&1u32.to_le_bytes());
        file[q + 20..q + 22].copy_from_slice(&128u16.to_le_bytes());
        file[q + 22..q + 24].copy_from_slice(&1u16.to_le_bytes());
        let flen = RHD_DATA_OFFSET + frag_payload.len();
        let fr = ps - flen;
        let b = q + fr;
        file[b + 10..b + 12].copy_from_slice(&frag_flags.to_le_bytes());
        file[b + 12] = 1;
        file[b + RHD_DATA_OFFSET..b + RHD_DATA_OFFSET + frag_payload.len()]
            .copy_from_slice(frag_payload);
        file[q + DPG_RPT_OFFSET..q + DPG_RPT_OFFSET + 2]
            .copy_from_slice(&(fr as u16).to_le_bytes());
        file[q + DPG_RPT_OFFSET + 2..q + DPG_RPT_OFFSET + 4]
            .copy_from_slice(&(flen as u16).to_le_bytes());
        file
    }

    // one RLE literal run of n bytes: control byte n (positive = literal)
    fn lit(bytes: &[u8]) -> Vec<u8> {
        let mut v = vec![bytes.len() as u8];
        v.extend_from_slice(bytes);
        v
    }

    #[test]
    fn a_fragmented_head_reads_its_payload_from_offset_22() {
        // THE BUG THIS PINS: the data offset used to be chosen on
        // LONG_TRANUM alone, so a fragmented record's payload was read
        // from 13 - nine bytes early, starting on rhdf_f_page itself.
        let file = two_page_chain(&lit(b"HEAD"), &lit(b"TAIL"), flags::FRAGMENT);
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        let head = dp.record(0).unwrap();
        assert_eq!(head.flags & flags::INCOMPLETE, flags::INCOMPLETE);
        // the payload begins at the literal run, not at the pointer
        assert_eq!(head.packed_data, lit(b"HEAD").as_slice());
        // and the forward pointer is decoded, not swallowed as data
        assert_eq!(head.next_fragment(), Some((2, 0)));
    }

    #[test]
    fn image_declines_a_fragment_rather_than_returning_half_a_row() {
        // Every caller that cannot reach the file keeps SKIPPING the
        // record. Handing back the head's piece would be a short image
        // whose later fields decode as missing or wrong, silently.
        let file = two_page_chain(&lit(b"HEAD"), &lit(b"TAIL"), flags::FRAGMENT);
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        assert!(dp.record(0).unwrap().image().is_none());
    }

    #[test]
    fn assembled_image_follows_the_chain() {
        let file = two_page_chain(&lit(b"HEAD"), &lit(b"TAIL"), flags::FRAGMENT);
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        let head = dp.record(0).unwrap();
        assert_eq!(
            assembled_image(&crate::Image::from_bytes(&file, 4096), 4096,&head),
            Some(b"HEADTAIL".to_vec())
        );
    }

    #[test]
    fn an_unfragmented_record_is_unaffected() {
        let file = two_page_chain(&lit(b"HEAD"), &lit(b"TAIL"), flags::FRAGMENT);
        let dp = DataPage::decode(&file[8192..12288]).unwrap();
        let frag = dp.record(0).unwrap();
        // the terminal piece on its own is an ordinary rhd record
        assert_eq!(frag.next_fragment(), None);
        assert_eq!(assembled_image(&crate::Image::from_bytes(&file, 4096), 4096,&frag), Some(b"TAIL".to_vec()));
    }

    /// A MIXED chain: a raw head and a compressed tail. The engine
    /// decodes each piece by its own `rpb_not_packed` (vio.cpp:575-602,
    /// called per fragment at :1849 and :1864), so this must assemble -
    /// the first version of `assembled_image` REFUSED it, and the row
    /// was lost.
    #[test]
    fn a_chain_may_mix_packed_and_raw_pieces() {
        // head stored raw, fragment compressed
        let file = two_page_chain(b"HEAD", &lit(b"TAIL"), flags::FRAGMENT);
        // mark the head NOT_PACKED
        let mut file = file;
        let ps = 4096usize;
        let len = RHDF_DATA_OFFSET + 4;
        let a = ps + (ps - len);
        file[a + 10..a + 12]
            .copy_from_slice(&(flags::INCOMPLETE | flags::NOT_PACKED).to_le_bytes());
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        let head = dp.record(0).unwrap();
        assert_eq!(
            assembled_image(&crate::Image::from_bytes(&file, 4096), 4096,&head),
            Some(b"HEADTAIL".to_vec())
        );
    }

    #[test]
    fn a_chain_pointing_at_a_non_fragment_is_refused() {
        // corruption, or a pointer into a live row - either way, do not
        // splice someone else's bytes onto this record
        let file = two_page_chain(&lit(b"HEAD"), &lit(b"TAIL"), 0);
        let dp = DataPage::decode(&file[4096..8192]).unwrap();
        let head = dp.record(0).unwrap();
        assert_eq!(assembled_image(&crate::Image::from_bytes(&file, 4096), 4096,&head), None);
    }
}

#[cfg(test)]
mod frag_tranum_tests {
    use super::*;

    /// A fragmented record without LONG_TRANUM must NOT read a high
    /// word. `Ods::getTraNum` (ods.cpp:157-169) reads `rhdf_tra_high`
    /// only inside `if (rhd_flags & rhd_long_tranum)`, and MVCC
    /// visibility is decided on the number this produces - inventing a
    /// high word would make a fragmented row claim a transaction 2^32
    /// times too large.
    #[test]
    fn a_fragment_without_long_tranum_has_no_high_word() {
        let ps = 4096usize;
        let mut page = vec![0u8; ps];
        page[0] = 5;
        page[20..22].copy_from_slice(&128u16.to_le_bytes());
        page[22..24].copy_from_slice(&1u16.to_le_bytes());
        let len = RHDF_DATA_OFFSET + 2;
        let r = ps - len;
        page[r..r + 4].copy_from_slice(&99u32.to_le_bytes()); // low id = 99
        // bytes 14-15 are NOT a transaction high word here; set them to
        // the same 0x8181 the live fixture happened to carry
        page[r + 14..r + 16].copy_from_slice(&0x8181u16.to_le_bytes());
        page[r + 10..r + 12].copy_from_slice(&flags::INCOMPLETE.to_le_bytes());
        page[r + DPG_RPT_OFFSET - DPG_RPT_OFFSET] = page[r]; // no-op, keep layout explicit
        page[DPG_RPT_OFFSET..DPG_RPT_OFFSET + 2].copy_from_slice(&(r as u16).to_le_bytes());
        page[DPG_RPT_OFFSET + 2..DPG_RPT_OFFSET + 4].copy_from_slice(&(len as u16).to_le_bytes());
        let dp = DataPage::decode(&page).unwrap();
        assert_eq!(dp.record(0).unwrap().transaction, 99);

        // ... and WITH the flag, it does read one
        page[r + 10..r + 12]
            .copy_from_slice(&(flags::INCOMPLETE | flags::LONG_TRANUM).to_le_bytes());
        let dp = DataPage::decode(&page).unwrap();
        assert_eq!(dp.record(0).unwrap().transaction, 0x8181u64 << 32 | 99);
    }
}
