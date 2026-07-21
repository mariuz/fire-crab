//! The database header page (`struct header_page`, ods.h:639), the
//! root of everything: page size, ODS version, the four transaction
//! markers (64-bit since the ODS 12+ widening), the database GUID.
//! Offsets are pinned by the static_asserts at ods.h:661-685 and
//! mirrored by the tests below.

use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at, u64_at};

/// ODS major version numbers carry a "Firebird" flag bit.
/// (ODS_FIREBIRD_FLAG in ods.h; ODS 14.0 reads 0x800e raw.)
pub const ODS_FIREBIRD_FLAG: u16 = 0x8000;

#[derive(Clone, Debug)]
pub struct HeaderPage {
    pub pag: PageHeader,
    pub page_size: u16,
    /// Raw ODS version word including the Firebird flag (e.g. 0x800e)
    pub ods_version_raw: u16,
    pub ods_minor: u16,
    pub flags: u16,
    pub backup_mode: u8,
    pub shutdown_mode: u8,
    pub replica_mode: u8,
    /// Page number of the RDB$PAGES relation's first pointer page -
    /// the bootstrap anchor the catalog is found through
    pub pages_page: u32,
    pub page_buffers: u32,
    pub next_transaction: u64,
    pub oldest_transaction: u64,
    pub oldest_active: u64,
    pub oldest_snapshot: u64,
    pub next_attachment_id: u64,
    pub guid: [u8; 16],
}

impl HeaderPage {
    /// ODS major version with the Firebird flag stripped (14 for
    /// Firebird 6).
    pub fn ods_major(&self) -> u16 {
        self.ods_version_raw & !ODS_FIREBIRD_FLAG
    }

    pub fn is_firebird(&self) -> bool {
        self.ods_version_raw & ODS_FIREBIRD_FLAG != 0
    }

    /// Decode page 0 of a database file. Returns None if the buffer
    /// is too small or not a header page.
    pub fn decode(page: &[u8]) -> Option<HeaderPage> {
        if page.len() < 100 {
            return None;
        }
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::Header as u8 {
            return None;
        }
        let mut guid = [0u8; 16];
        guid.copy_from_slice(&page[84..100]); // hdr_guid, offset 84

        Some(HeaderPage {
            pag,
            page_size: u16_at(page, 16),          // hdr_page_size
            ods_version_raw: u16_at(page, 18),    // hdr_ods_version
            ods_minor: u16_at(page, 20),          // hdr_ods_minor
            flags: u16_at(page, 22),              // hdr_flags
            backup_mode: page[24],                // hdr_backup_mode
            shutdown_mode: page[25],              // hdr_shutdown_mode
            replica_mode: page[26],               // hdr_replica_mode
            pages_page: u32_at(page, 28),         // hdr_PAGES
            page_buffers: u32_at(page, 32),       // hdr_page_buffers
            next_transaction: u64_at(page, 40),   // hdr_next_transaction
            oldest_transaction: u64_at(page, 48), // hdr_oldest_transaction
            oldest_active: u64_at(page, 56),      // hdr_oldest_active
            oldest_snapshot: u64_at(page, 64),    // hdr_oldest_snapshot
            next_attachment_id: u64_at(page, 72), // hdr_attachment_id
            guid,
        })
    }

    /// Render the GUID the way the engine prints it:
    /// {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} with the first three
    /// groups little-endian (Windows GUID convention, as used by
    /// Firebird's Guid class).
    pub fn guid_string(&self) -> String {
        let g = &self.guid;
        format!(
            "{{{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}}}",
            u32::from_le_bytes([g[0], g[1], g[2], g[3]]),
            u16::from_le_bytes([g[4], g[5]]),
            u16::from_le_bytes([g[6], g[7]]),
            g[8],
            g[9],
            g[10],
            g[11],
            g[12],
            g[13],
            g[14],
            g[15]
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a synthetic header page with a distinct value at every
    /// field offset pinned by ods.h:661-685, and check each lands in
    /// the right struct member - the Rust mirror of the C++
    /// static_asserts plus a semantic decode check.
    #[test]
    fn header_layout_matches_ods_h() {
        let mut page = vec![0u8; 8192];
        page[0] = 1; // pag_header
        page[16..18].copy_from_slice(&8192u16.to_le_bytes()); // hdr_page_size @16
        page[18..20].copy_from_slice(&0x800eu16.to_le_bytes()); // hdr_ods_version @18
        page[20..22].copy_from_slice(&0u16.to_le_bytes()); // hdr_ods_minor @20
        page[22..24].copy_from_slice(&0x1234u16.to_le_bytes()); // hdr_flags @22
        page[24] = 1; // hdr_backup_mode @24
        page[25] = 2; // hdr_shutdown_mode @25
        page[26] = 3; // hdr_replica_mode @26
        page[28..32].copy_from_slice(&3u32.to_le_bytes()); // hdr_PAGES @28
        page[32..36].copy_from_slice(&2048u32.to_le_bytes()); // hdr_page_buffers @32
        page[40..48].copy_from_slice(&29u64.to_le_bytes()); // hdr_next_transaction @40
        page[48..56].copy_from_slice(&28u64.to_le_bytes()); // hdr_oldest_transaction @48
        page[56..64].copy_from_slice(&29u64.to_le_bytes()); // hdr_oldest_active @56
        page[64..72].copy_from_slice(&29u64.to_le_bytes()); // hdr_oldest_snapshot @64
        page[72..80].copy_from_slice(&7u64.to_le_bytes()); // hdr_attachment_id @72
        page[84..100].copy_from_slice(&[0xAA; 16]); // hdr_guid @84

        let h = HeaderPage::decode(&page).unwrap();
        assert_eq!(h.page_size, 8192);
        assert_eq!(h.ods_major(), 14);
        assert!(h.is_firebird());
        assert_eq!(h.flags, 0x1234);
        assert_eq!(h.backup_mode, 1);
        assert_eq!(h.shutdown_mode, 2);
        assert_eq!(h.replica_mode, 3);
        assert_eq!(h.pages_page, 3);
        assert_eq!(h.page_buffers, 2048);
        assert_eq!(h.next_transaction, 29);
        assert_eq!(h.oldest_transaction, 28);
        assert_eq!(h.oldest_active, 29);
        assert_eq!(h.oldest_snapshot, 29);
        assert_eq!(h.next_attachment_id, 7);
        assert_eq!(h.guid, [0xAA; 16]);
    }

    #[test]
    fn rejects_non_header_pages() {
        let mut page = vec![0u8; 8192];
        page[0] = 5; // a data page
        assert!(HeaderPage::decode(&page).is_none());
    }
}
