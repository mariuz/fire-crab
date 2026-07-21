//! The generic page header (`struct pag`, ods.h:248) and the page-type
//! census. Every page in a Firebird database file starts with these 16
//! bytes; the C++ layout is pinned by static_asserts (ods.h:258-264)
//! and mirrored by the tests at the bottom of this file.

use crate::{u16_at, u32_at};

/// Page types, from ods.h:204-214 (`pag_*` constants).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum PageType {
    Undefined = 0,
    /// Database header page (`pag_header`)
    Header = 1,
    /// Page inventory page / PIP (`pag_pages`)
    PageInventory = 2,
    /// Transaction inventory page / TIP (`pag_transactions`)
    TransactionInventory = 3,
    /// Pointer page (`pag_pointer`)
    Pointer = 4,
    /// Data page (`pag_data`)
    Data = 5,
    /// Index root page (`pag_root`)
    IndexRoot = 6,
    /// B-tree page (`pag_index`)
    Index = 7,
    /// Blob page (`pag_blob`)
    Blob = 8,
    /// Generator page (`pag_ids`)
    Generators = 9,
    /// SCN inventory page (`pag_scns`)
    ScnInventory = 10,
}

impl PageType {
    pub fn from_byte(b: u8) -> Option<PageType> {
        use PageType::*;
        Some(match b {
            0 => Undefined,
            1 => Header,
            2 => PageInventory,
            3 => TransactionInventory,
            4 => Pointer,
            5 => Data,
            6 => IndexRoot,
            7 => Index,
            8 => Blob,
            9 => Generators,
            10 => ScnInventory,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        use PageType::*;
        match self {
            Undefined => "undefined",
            Header => "header",
            PageInventory => "page inventory (PIP)",
            TransactionInventory => "transaction inventory (TIP)",
            Pointer => "pointer",
            Data => "data",
            IndexRoot => "index root",
            Index => "b-tree",
            Blob => "blob",
            Generators => "generators",
            ScnInventory => "SCN inventory",
        }
    }
}

/// The 16-byte generic page header present at the start of every page
/// (`struct pag`).
#[derive(Clone, Copy, Debug)]
pub struct PageHeader {
    pub page_type: u8,
    pub flags: u8,
    pub generation: u32,
    pub scn: u32,
    /// `pag_pageno` - the page's own number, kept for validation
    pub page_no: u32,
}

pub const PAGE_HEADER_SIZE: usize = 16;

impl PageHeader {
    /// Decode from the first 16 bytes of a page buffer.
    /// Offsets pinned by ods.h:259-264.
    pub fn decode(page: &[u8]) -> Option<PageHeader> {
        if page.len() < PAGE_HEADER_SIZE {
            return None;
        }
        Some(PageHeader {
            page_type: page[0],
            flags: page[1],
            // offset 2: pag_reserved (alignment only)
            generation: u32_at(page, 4),
            scn: u32_at(page, 8),
            page_no: u32_at(page, 12),
        })
    }
}

/// A whole-file page-type census: `counts[type]` pages of each type,
/// plus anything unrecognized. The equivalent view from the C++ side
/// is a walk of the PIP + per-page `pag_type` reads - `gstat -d` shows
/// the same totals grouped by relation.
#[derive(Clone, Debug, Default)]
pub struct Census {
    pub page_size: usize,
    pub total_pages: u64,
    pub counts: [u64; 11],
    pub unknown: u64,
}

/// Census over a full database file image (or any prefix of whole
/// pages). The page size is taken from the header page.
pub fn census(file: &[u8]) -> Option<Census> {
    let page_size = u16_at(file, 16) as usize; // hdr_page_size, ods.h:642
    if page_size == 0 || !page_size.is_power_of_two() || file.len() < page_size {
        return None;
    }
    let mut c = Census {
        page_size,
        ..Default::default()
    };
    for chunk in file.chunks_exact(page_size) {
        c.total_pages += 1;
        match PageType::from_byte(chunk[0]) {
            Some(t) => c.counts[t as usize] += 1,
            None => c.unknown += 1,
        }
    }
    Some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mirror of the C++ static_asserts (ods.h:258-264): a synthetic
    /// page with distinct bytes at every offset decodes to the fields
    /// the C++ struct would overlay.
    #[test]
    fn pag_layout_matches_ods_h() {
        let mut page = vec![0u8; 32];
        page[0] = 5; // pag_type = pag_data
        page[1] = 0x02; // pag_flags
        page[4..8].copy_from_slice(&7u32.to_le_bytes()); // pag_generation
        page[8..12].copy_from_slice(&9u32.to_le_bytes()); // pag_scn
        page[12..16].copy_from_slice(&42u32.to_le_bytes()); // pag_pageno

        let h = PageHeader::decode(&page).unwrap();
        assert_eq!(h.page_type, 5);
        assert_eq!(h.flags, 0x02);
        assert_eq!(h.generation, 7);
        assert_eq!(h.scn, 9);
        assert_eq!(h.page_no, 42);
    }

    #[test]
    fn page_type_names_cover_all_ods14_types() {
        for b in 0..=10u8 {
            assert!(PageType::from_byte(b).is_some(), "type {} unmapped", b);
        }
        assert!(PageType::from_byte(11).is_none());
    }
}
