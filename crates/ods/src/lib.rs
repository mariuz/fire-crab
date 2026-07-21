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

pub mod data;
pub mod header;
pub mod pages;
pub mod pip;
pub mod pointer;
pub mod sqz;
pub mod tip;

pub use data::{DataPage, RecordHeader};
pub use header::HeaderPage;
pub use pages::{census, PageType};
pub use pip::PipPage;
pub use pointer::{relation_data_pages, PointerPage};
pub use tip::{TipPage, TxState};

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
