//! # fire-crab-ods
//!
//! Rust decoding of Firebird's on-disk structure (ODS 14, Firebird 6),
//! converted from `src/jrd/ods.h` in the Firebird source tree. This is
//! fire-crab's first conversion slice: the storage layer, bottom-up,
//! chosen because every byte it produces can be checked against the
//! C++ engine's own files and tools (`gstat`) - differential testing
//! from day one.
//!
//! ## Conversion notes (methodology in `docs/methodology.md`)
//!
//! - Every struct here mirrors a C++ struct whose layout is pinned by
//!   `static_assert`s in `ods.h`; the same offsets are pinned by unit
//!   tests below. The C++ engine reads pages by casting buffers to
//!   `struct pag*`; the Rust conversion reads fields with explicit
//!   little-endian accessors instead - no `unsafe`, no alignment or
//!   endianness assumptions. (Firebird databases are little-endian on
//!   all supported platforms; big-endian hosts got a converted format
//!   historically, which fire-crab does not support, matching modern
//!   Firebird.)
//! - C++ `USHORT/ULONG/FB_UINT64` become `u16/u32/u64`. Transaction
//!   ids are `u64` (48-bit on disk since ODS 12+ widened markers).
//! - Record compression is converted from `src/jrd/sqz.cpp` including
//!   the Firebird 4+ extended run lengths (control bytes -1/-2).

pub mod blr;
pub mod btr;
pub mod btw;
pub mod catalog;
pub mod data;
pub mod ddl;
pub mod decfloat;
pub mod dml;
pub mod expr;
pub mod format;
pub mod gc;
pub mod gen;
pub mod header;
pub mod intl;
pub mod pages;
pub mod pip;
pub mod pointer;
pub mod sqz;
pub mod sysfmt;
pub mod tip;
pub mod tra;
pub mod val;
pub mod tz;

pub use blr::{decode as decode_blr, BlrDecode};
pub use btr::{walk_index_leaves, BtreePage, IndexRootPage};
pub use catalog::{
    count_primary_records, list_relations, relation_columns, resolve_relation, RelationColumn,
};
pub use data::{DataPage, RecordHeader};
pub use dml::{allocate_page, begin_active_tx, begin_committed_tx, delete_records, delete_records_under, insert_blob_slot, insert_record, insert_record_under, set_tx_state, update_record_under, update_records, DmlOutcome, InsertOutcome};
pub use header::{header_report, variable_header, HeaderClumplet};
pub use format::{
    decode_record, field_bytes, read_blob_content, relation_formats, Descriptor, Value,
};
pub use gc::{analyze as gc_analyze, version_count, GcReport};
pub use header::HeaderPage;
pub use pages::{census, PageType};
pub use pip::PipPage;
pub use sysfmt::system_relation_formats;
pub use pointer::{relation_data_pages, PointerPage};
pub use tip::{TipPage, TxState};
pub use tra::{visible_rows, Snapshot, TipChain};

/// The bytes of page `page`, or `None` when the image does not hold a
/// whole page there.
///
/// This is the ONE place the page-address arithmetic lives: a page is at
/// `page * page_size` in the contiguous image, `page_size` bytes long.
/// Every reader that wants "page N" asks here rather than computing an
/// absolute offset of its own - which is the seam a page-addressed image
/// (`Vec<Arc<[u8]>>`) replaces without touching a single caller: the
/// callers already speak in page numbers, and only this body changes from
/// a slice of one buffer to an index into many. The checked arithmetic
/// answers `None` for an out-of-range page exactly as the `file.get(..)`
/// it replaces did, and never panics on a page number past the file.
#[inline]
pub fn page_at(file: &[u8], page_size: usize, page: u32) -> Option<&[u8]> {
    let start = (page as usize).checked_mul(page_size)?;
    let end = start.checked_add(page_size)?;
    file.get(start..end)
}

/// The MUTABLE bytes of page `page` - the write-side twin of `page_at`,
/// and the accessor a page-addressed image reaches through to give a
/// writer a page of its own (`Arc::make_mut` on that one page) rather
/// than a slice of a shared buffer. A caller writes a FIELD by indexing
/// into the returned page at its page-local offset (`page[22..24]`, the
/// data-page count) rather than at `page * page_size + 22` in the file -
/// the two are the same bytes today, but only the first survives the
/// image ceasing to be contiguous.
#[inline]
pub fn page_mut(file: &mut [u8], page_size: usize, page: u32) -> Option<&mut [u8]> {
    let start = (page as usize).checked_mul(page_size)?;
    let end = start.checked_add(page_size)?;
    file.get_mut(start..end)
}

/// Read a `u16` at `offset`, little-endian, like the engine's
/// in-memory access to an aligned USHORT field on x86/ARM.
#[inline]
pub(crate) fn u16_at(buf: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([buf[offset], buf[offset + 1]])
}

#[inline]
pub(crate) fn u32_at(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
    ])
}

#[inline]
pub(crate) fn u64_at(buf: &[u8], offset: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&buf[offset..offset + 8]);
    u64::from_le_bytes(b)
}
