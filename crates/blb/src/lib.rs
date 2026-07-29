//! Blob storage - the conversion of `src/jrd/blb.cpp`'s on-disk
//! addressing (`blh` headers, `blob_page` / `blp` pages, the three
//! address levels) and its creation path, differentially tested in
//! BOTH directions: the engine writes blobs this crate must read
//! byte-for-byte, and this crate writes blobs the engine must read
//! back, validate (`gfix`) and back up (`gbak`).
//!
//! # Blobs live outside the record
//!
//! A blob column stores an 8-byte id (`bid`: relation, record
//! number); the blob itself is a "record" of its own on the
//! relation's data pages - a slot whose bytes are not a record
//! header but a **blob header** (`blh`, `dpm.epp:2491` lays it down
//! in place of an `rhd`), flagged `rhd_blob` in the slot's flags
//! word. What follows the 28-byte header depends on the **level**:
//!
//! - **level 0**: the data itself, inline in the slot. One page
//!   ceiling - the whole blob must fit where a record would.
//! - **level 1**: a vector of page numbers (`blh_page[]`), each a
//!   **blob page** (`pag_type` 8): 28 bytes of header (`pag` +
//!   `blp_lead_page` + `blp_sequence` + `blp_length` + pad), then
//!   `blp_length` bytes of data. The vector must fit the slot, so
//!   level 1 tops out around a thousand pages.
//! - **level 2**: `blh_page[]` names blob POINTER pages (`pag_flags`
//!   & `blp_pointers`), whose data area is itself a vector of
//!   data-page numbers - the same before-you-point-there shape the
//!   careful-write chapter orders.
//!
//! Two content framings ride the same storage. **Segmented** blobs
//! (the default) store `[u16 length][payload]` per segment - the
//! byte stream this crate calls `raw` carries the framing, and
//! [`Blob::content`] strips it. **Stream** blobs
//! (`rhd_stream_blob` set in the slot flags) are raw bytes,
//! segment-free. `blh_length` counts PAYLOAD bytes (framing
//! excluded) - probed: the engine's `OCTET_LENGTH` equals it for
//! both framings.
//!
//! # The layout, pinned
//!
//! `ods.h` pins every offset with `static_assert`s; the unit tests
//! mirror them one-for-one, so a drifted field is a failing test
//! before it is a wrong byte:
//!
//! ```text
//! blh (32 bytes, ods.h:969)          blob_page (32, ods.h:271)
//!   0  blh_lead_page   u32             0  pag (type 8, flags)
//!   4  blh_max_sequence u32           16  blp_lead_page u32
//!   8  blh_max_segment u16            20  blp_sequence  u32
//!  10  blh_flags       u16            24  blp_length    u16
//!  12  blh_count       u32            26  blp_pad       u16
//!  16  blh_length      u64            28  data / page vector
//!  24  blh_sub_type    u16
//!  26  blh_charset     u8
//!  27  blh_level       u8
//!  28  blh_page[]      u32...
//! ```
//!
//! # The oracle, both directions
//!
//! Reading: the gate has the ENGINE create text blobs from empty
//! through multi-megabyte (doubling `UPDATE b SET c = c || c` walks
//! a blob up through all three levels), then compares `fcblb`'s
//! length and content slices against the engine's own
//! `OCTET_LENGTH` / `SUBSTRING` answers, cell for cell. Writing: the
//! gate has `fcblb` create blobs (level 0 and level 1, several
//! segment sizes) plus the records that reference them, and the
//! engine reads them back, `gfix -v -full` validates the file, and
//! `gbak` backs it up. An unknown level or a truncated page REFUSES -
//! never a guess.
//!
//! # Slice 1 boundaries
//!
//! Level-2 CREATION, blob garbage collection (orphaned blobs when
//! records die), blob filters, and the per-transaction temporary
//! blob namespace ride later slices. The wire server's existing
//! read path (`ods::format::read_blob`) remains in place; this crate
//! is the full conversion that will absorb it.

use fire_crab_ods::{allocate_page, insert_blob_slot, DataPage};

/// Slot-flags bits (`ods.h` rhd_* - the blob slot reuses the record
/// flags word at offset 10).
pub mod flags {
    /// rhd_blob: this slot is a blh, not a record (ods.h:1010)
    pub const BLOB: u16 = 16;
    /// rhd_stream_blob: raw bytes, no segment framing (ods.h:1011)
    pub const STREAM: u16 = 32;
}

/// `pag_flags` on a blob page.
pub const BLP_POINTERS: u8 = 0x01;

/// The 28 bytes of blob-page header before the data area.
pub const BLP_DATA_OFFSET: usize = 28;

/// The 28 bytes of blh before the inline data / page vector.
pub const BLH_DATA_OFFSET: usize = 28;

/// A decoded blob header - `blh`, ods.h:969, offsets pinned by the
/// unit tests exactly as the engine pins them with static_asserts.
#[derive(Clone, Debug, PartialEq)]
pub struct BlobHeader {
    /// first data page (redundancy - the vector is authoritative)
    pub lead_page: u32,
    /// the LAST page sequence number (pages number 0..=max_sequence;
    /// blb.cpp:2377 stops at `blb_sequence > blb_max_sequence`, so
    /// this is n_pages - 1, NOT the count - ods.h's "Number of data
    /// pages" comment misleads, and the engine reading one page past
    /// a count-valued field proved it)
    pub max_sequence: u32,
    /// the longest segment's payload length
    pub max_segment: u16,
    /// the slot flags word: rhd_blob, maybe rhd_stream_blob
    pub flags: u16,
    /// total number of segments
    pub count: u32,
    /// total PAYLOAD length - segment framing excluded (probed:
    /// equals the engine's OCTET_LENGTH for both framings)
    pub length: u64,
    pub sub_type: u16,
    pub charset: u8,
    /// 0 = inline, 1 = page vector, 2 = pointer-page vector
    pub level: u8,
}

impl BlobHeader {
    /// Decode a slot's leading 28 bytes. `None` when the slot is not
    /// a blob (the rhd_blob flag is the discriminator).
    pub fn decode(slot: &[u8]) -> Option<BlobHeader> {
        if slot.len() < BLH_DATA_OFFSET {
            return None;
        }
        let flags = u16le(slot, 10);
        if flags & flags::BLOB == 0 {
            return None;
        }
        Some(BlobHeader {
            lead_page: u32le(slot, 0),
            max_sequence: u32le(slot, 4),
            max_segment: u16le(slot, 8),
            flags,
            count: u32le(slot, 12),
            length: u64le(slot, 16),
            sub_type: u16le(slot, 24),
            charset: slot[26],
            level: slot[27],
        })
    }

    /// Encode the 28 header bytes (the caller appends inline data or
    /// the page vector).
    pub fn encode(&self) -> Vec<u8> {
        let mut b = Vec::with_capacity(BLH_DATA_OFFSET);
        b.extend_from_slice(&self.lead_page.to_le_bytes());
        b.extend_from_slice(&self.max_sequence.to_le_bytes());
        b.extend_from_slice(&self.max_segment.to_le_bytes());
        b.extend_from_slice(&self.flags.to_le_bytes());
        b.extend_from_slice(&self.count.to_le_bytes());
        b.extend_from_slice(&self.length.to_le_bytes());
        b.extend_from_slice(&self.sub_type.to_le_bytes());
        b.push(self.charset);
        b.push(self.level);
        b
    }

    /// Stream blobs carry raw bytes; segmented blobs carry framed
    /// segments.
    pub fn is_stream(&self) -> bool {
        self.flags & flags::STREAM != 0
    }
}

/// A blob read off the file: its header and the raw byte stream
/// (framing included for segmented blobs).
pub struct Blob {
    pub header: BlobHeader,
    pub raw: Vec<u8>,
}

impl Blob {
    /// The payload: raw for stream blobs, deframed for segmented.
    pub fn content(&self) -> Vec<u8> {
        if self.header.is_stream() {
            return self.raw[..(self.header.length as usize).min(self.raw.len())].to_vec();
        }
        let mut out = Vec::with_capacity(self.header.length as usize);
        for seg in self.segments() {
            out.extend_from_slice(seg);
        }
        out
    }

    /// The segments, in order - `BLB_get_segment`'s view.
    pub fn segments(&self) -> SegmentIter<'_> {
        SegmentIter { raw: &self.raw, at: 0, remaining: self.header.length as usize }
    }
}

/// Iterator over `[u16 length][payload]` frames.
pub struct SegmentIter<'a> {
    raw: &'a [u8],
    at: usize,
    remaining: usize,
}

impl<'a> Iterator for SegmentIter<'a> {
    type Item = &'a [u8];
    fn next(&mut self) -> Option<&'a [u8]> {
        if self.remaining == 0 || self.at + 2 > self.raw.len() {
            return None;
        }
        let n = u16le(self.raw, self.at) as usize;
        self.at += 2;
        let seg = self.raw.get(self.at..self.at + n)?;
        self.at += n;
        self.remaining = self.remaining.saturating_sub(n);
        Some(seg)
    }
}

/// Read a blob by its id (relation, record number) - all three
/// levels. Refuses (with a reason) rather than guessing at anything
/// out of shape: an unknown level, a page of the wrong type, a
/// truncated vector.
pub fn read_blob(
    file: &[u8],
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Result<Blob, String> {
    let slot = blob_slot(file, page_size, relation, recno)?;
    let header = BlobHeader::decode(&slot).ok_or("slot is not a blob")?;
    let raw = match header.level {
        0 => slot[BLH_DATA_OFFSET..].to_vec(),
        1 => {
            let mut out = Vec::new();
            for page in page_vector(&slot) {
                out.extend_from_slice(&blob_page_data(file, page_size, page, false)?);
            }
            out
        }
        2 => {
            // pointer pages: each names data pages in its own data
            // area - the vector-of-vectors level
            let mut out = Vec::new();
            for pp in page_vector(&slot) {
                let pointers = blob_page_data(file, page_size, pp, true)?;
                for at in (0..pointers.len()).step_by(4) {
                    let dp = u32le(&pointers, at);
                    if dp == 0 {
                        break;
                    }
                    out.extend_from_slice(&blob_page_data(file, page_size, dp, false)?);
                }
            }
            out
        }
        other => return Err(format!("blob level {} unconverted", other)),
    };
    Ok(Blob { header, raw })
}

/// The blob slot's bytes off its data page.
fn blob_slot(
    file: &[u8],
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Result<Vec<u8>, String> {
    let recs = fire_crab_ods::format::max_recs_per_dp(page_size) as u64;
    let pages = fire_crab_ods::relation_data_pages(file, page_size, relation);
    let dp_no = *pages
        .get((recno / recs) as usize)
        .ok_or("blob id names a page past the relation")?;
    let start = dp_no as usize * page_size;
    let dp = DataPage::decode(file.get(start..start + page_size).ok_or("page past EOF")?)
        .ok_or("blob id names a non-data page")?;
    dp.slot_bytes((recno % recs) as u16)
        .map(|b| b.to_vec())
        .ok_or_else(|| "blob slot is empty".into())
}

/// The u32 page vector after a blh (zero-terminated or slot-bounded).
fn page_vector(slot: &[u8]) -> Vec<u32> {
    let mut out = Vec::new();
    let mut at = BLH_DATA_OFFSET;
    while at + 4 <= slot.len() {
        let p = u32le(slot, at);
        if p == 0 {
            break;
        }
        out.push(p);
        at += 4;
    }
    out
}

/// One blob page's data area - `blp_length` bytes from offset 28.
/// `pointers` says which kind the caller expects; a mismatch refuses
/// (the level said one thing, the page another).
fn blob_page_data(
    file: &[u8],
    page_size: usize,
    page: u32,
    pointers: bool,
) -> Result<Vec<u8>, String> {
    let start = page as usize * page_size;
    let p = file
        .get(start..start + page_size)
        .ok_or_else(|| format!("blob page {} past EOF", page))?;
    if p[0] != 8 {
        return Err(format!("page {} is not a blob page (type {})", page, p[0]));
    }
    let is_pointers = p[1] & BLP_POINTERS != 0;
    if is_pointers != pointers {
        return Err(format!(
            "page {} is a {} page where a {} page was expected",
            page,
            if is_pointers { "pointer" } else { "data" },
            if pointers { "pointer" } else { "data" },
        ));
    }
    let len = u16le(p, 24) as usize; // blp_length
    p.get(BLP_DATA_OFFSET..BLP_DATA_OFFSET + len)
        .map(|b| b.to_vec())
        .ok_or_else(|| format!("blob page {} shorter than its blp_length", page))
}

/// Create a segmented blob from `segments`, choosing the level the
/// content demands - inline (level 0) when the framed stream fits a
/// data-page slot, a page vector (level 1) otherwise. Returns the
/// blob's record number for the referencing record's `bid`.
/// Level 2 refuses: unconverted, never guessed.
pub fn create_blob(
    file: &mut Vec<u8>,
    page_size: usize,
    relation: u16,
    segments: &[Vec<u8>],
    sub_type: u16,
    charset: u8,
) -> Result<u64, String> {
    let payload: usize = segments.iter().map(|s| s.len()).sum();
    let max_segment = segments.iter().map(|s| s.len()).max().unwrap_or(0);
    if max_segment > u16::MAX as usize {
        return Err("blob segment longer than a u16 frame".into());
    }
    // the framed stream: [u16 len][payload] per segment
    let mut raw = Vec::with_capacity(payload + segments.len() * 2);
    for seg in segments {
        raw.extend_from_slice(&(seg.len() as u16).to_le_bytes());
        raw.extend_from_slice(seg);
    }
    let mut header = BlobHeader {
        lead_page: 0,
        max_sequence: 0,
        max_segment: max_segment as u16,
        flags: flags::BLOB,
        count: segments.len() as u32,
        length: payload as u64,
        sub_type,
        charset,
        level: 0,
    };
    // level 0: the whole framed stream rides in the slot
    let slot_cap = page_size - 24 /* DPG_RPT_OFFSET */ - 4;
    if BLH_DATA_OFFSET + raw.len() <= slot_cap {
        let mut blh = header.encode();
        blh.extend_from_slice(&raw);
        return insert_blob_slot(file, page_size, relation, &blh);
    }
    // levels 1 and 2: chunk the framed stream over blob DATA pages
    // (blob-wide lead, global sequence - probed on the engine's own
    // level-2 blob: every data page carries the blob's first data
    // page as blp_lead_page and its global index as blp_sequence)
    let per_page = page_size - BLP_DATA_OFFSET;
    let n_pages = raw.len().div_ceil(per_page);
    let mut pages = Vec::with_capacity(n_pages);
    for _ in 0..n_pages {
        pages.push(allocate_page(file, page_size)?);
    }
    let lead = pages[0];
    for (seq, (page, chunk)) in pages.iter().zip(raw.chunks(per_page)).enumerate() {
        write_blob_page(file, page_size, *page, lead, seq as u32, 0, chunk);
    }
    header.lead_page = lead;
    // the last DATA sequence, not the count (blb.cpp:2377)
    header.max_sequence = (n_pages - 1) as u32;
    if BLH_DATA_OFFSET + n_pages * 4 <= slot_cap {
        // level 1: the data-page vector rides the slot
        header.level = 1;
        let mut blh = header.encode();
        for p in &pages {
            blh.extend_from_slice(&p.to_le_bytes());
        }
        return insert_blob_slot(file, page_size, relation, &blh);
    }
    // level 2: the vector itself overflows the slot - chunk it over
    // POINTER pages (pag_flags |= blp_pointers), whose data areas
    // are u32 data-page vectors; the slot holds the pointer-page
    // vector. Probed on the engine's level-2 blob: pointer pages
    // carry the blob-wide lead and sequence 0, and blp_length is the
    // BYTE length of the entries.
    let per_ptr = per_page / 4;
    let mut ptr_pages = Vec::new();
    for chunk in pages.chunks(per_ptr) {
        let pp = allocate_page(file, page_size)?;
        let mut entries = Vec::with_capacity(chunk.len() * 4);
        for p in chunk {
            entries.extend_from_slice(&p.to_le_bytes());
        }
        write_blob_page(file, page_size, pp, lead, 0, BLP_POINTERS, &entries);
        ptr_pages.push(pp);
    }
    if BLH_DATA_OFFSET + ptr_pages.len() * 4 > slot_cap {
        return Err("level-3 blobs do not exist - the pointer vector cannot overflow".into());
    }
    header.level = 2;
    let mut blh = header.encode();
    for p in &ptr_pages {
        blh.extend_from_slice(&p.to_le_bytes());
    }
    insert_blob_slot(file, page_size, relation, &blh)
}

/// Lay one blob page down: type 8, the given flags, the blob-wide
/// lead page, the sequence, and the data area with its blp_length.
fn write_blob_page(
    file: &mut Vec<u8>,
    page_size: usize,
    page: u32,
    lead: u32,
    sequence: u32,
    pflags: u8,
    data: &[u8],
) {
    let base = page as usize * page_size;
    file[base..base + page_size].fill(0);
    file[base] = 8; // pag_type blob
    file[base + 1] = pflags;
    file[base + 12..base + 16].copy_from_slice(&page.to_le_bytes()); // pag_pageno
    file[base + 16..base + 20].copy_from_slice(&lead.to_le_bytes()); // blp_lead_page
    file[base + 20..base + 24].copy_from_slice(&sequence.to_le_bytes()); // blp_sequence
    file[base + 24..base + 26].copy_from_slice(&(data.len() as u16).to_le_bytes());
    file[base + BLP_DATA_OFFSET..base + BLP_DATA_OFFSET + data.len()].copy_from_slice(data);
}

/// The whole content by blob id, framing decided by the blob itself -
/// the adapter the wire server serves through (op_open_blob /
/// op_get_segment hand out CONTENT; the framing is storage detail).
pub fn read_blob_content(
    file: &[u8],
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Option<Vec<u8>> {
    read_blob(file, page_size, relation, recno).ok().map(|b| b.content())
}

fn u16le(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}
fn u32le(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}
fn u64le(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header() -> BlobHeader {
        BlobHeader {
            lead_page: 0x11223344,
            max_sequence: 7,
            max_segment: 900,
            flags: flags::BLOB,
            count: 3,
            length: 0x1_0000_0001,
            sub_type: 1,
            charset: 4,
            level: 1,
        }
    }

    /// The ods.h static_asserts, mirrored: every field at its pinned
    /// offset, 28 header bytes before the data.
    #[test]
    fn blh_offsets_pin_the_ods_layout() {
        let b = header().encode();
        assert_eq!(b.len(), BLH_DATA_OFFSET);
        assert_eq!(u32le(&b, 0), 0x11223344, "blh_lead_page @0");
        assert_eq!(u32le(&b, 4), 7, "blh_max_sequence @4");
        assert_eq!(u16le(&b, 8), 900, "blh_max_segment @8");
        assert_eq!(u16le(&b, 10), flags::BLOB, "blh_flags @10");
        assert_eq!(u32le(&b, 12), 3, "blh_count @12");
        assert_eq!(u64le(&b, 16), 0x1_0000_0001, "blh_length @16");
        assert_eq!(u16le(&b, 24), 1, "blh_sub_type @24");
        assert_eq!(b[26], 4, "blh_charset @26");
        assert_eq!(b[27], 1, "blh_level @27");
    }

    #[test]
    fn header_roundtrips() {
        let h = header();
        let mut slot = h.encode();
        slot.extend_from_slice(&[0u8; 8]);
        assert_eq!(BlobHeader::decode(&slot).unwrap(), h);
    }

    #[test]
    fn non_blob_slots_refuse() {
        // a record slot: flags word without rhd_blob
        let mut slot = vec![0u8; 32];
        slot[10] = 0;
        assert!(BlobHeader::decode(&slot).is_none());
        assert!(BlobHeader::decode(&[0u8; 10]).is_none());
    }

    #[test]
    fn segment_framing_roundtrips() {
        let segs: Vec<Vec<u8>> = vec![b"one".to_vec(), Vec::new(), b"three".to_vec()];
        let mut raw = Vec::new();
        for s in &segs {
            raw.extend_from_slice(&(s.len() as u16).to_le_bytes());
            raw.extend_from_slice(s);
        }
        let blob = Blob {
            header: BlobHeader {
                length: 8, // "one" + "" + "three"
                count: 3,
                ..header()
            },
            raw,
        };
        let got: Vec<Vec<u8>> = blob.segments().map(|s| s.to_vec()).collect();
        // the zero-length middle segment survives framing
        assert_eq!(got, segs);
        assert_eq!(blob.content(), b"onethree");
    }

    #[test]
    fn stream_blobs_take_raw_bytes() {
        let blob = Blob {
            header: BlobHeader {
                flags: flags::BLOB | flags::STREAM,
                length: 5,
                ..header()
            },
            raw: b"hello???".to_vec(),
        };
        assert!(blob.header.is_stream());
        // length truncates trailing slack
        assert_eq!(blob.content(), b"hello");
    }

    #[test]
    fn empty_blob_is_a_blob() {
        let blob = Blob {
            header: BlobHeader { length: 0, count: 0, ..header() },
            raw: Vec::new(),
        };
        assert_eq!(blob.content(), b"");
        assert_eq!(blob.segments().count(), 0);
    }

    #[test]
    fn page_vector_stops_at_zero_or_slot_end() {
        let mut slot = header().encode();
        slot.extend_from_slice(&5u32.to_le_bytes());
        slot.extend_from_slice(&9u32.to_le_bytes());
        slot.extend_from_slice(&0u32.to_le_bytes());
        slot.extend_from_slice(&77u32.to_le_bytes()); // past the terminator
        assert_eq!(page_vector(&slot), vec![5, 9]);
        let bare = header().encode();
        assert!(page_vector(&bare).is_empty());
    }

    /// Level selection: the framed stream against the slot ceiling.
    #[test]
    fn level_zero_ceiling_math() {
        let ps = 4096usize;
        let slot_cap = ps - 24 - 4;
        // the largest single-segment level-0 blob: header + frame + payload
        let max0 = slot_cap - BLH_DATA_OFFSET - 2;
        assert_eq!(max0, 4038);
        // one byte more must go to pages: ceil((2 + 4039) / (4096-28)) = 1 page
        assert_eq!((2usize + max0 + 1).div_ceil(ps - BLP_DATA_OFFSET), 1);
    }
}
