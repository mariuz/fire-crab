//! Page inventory pages (`struct page_inv_page`, ods.h:751): one bit
//! per page, SET meaning FREE. The Nth PIP lives at page number
//! `pages_per_pip * N - 1` (ods.h:786), except PIP 0 which is always
//! page 1.

use crate::pages::{PageHeader, PageType};
use crate::u32_at;

pub struct PipPage<'a> {
    pub pag: PageHeader,
    /// `pip_min` - lowest possibly-free page managed by this PIP
    pub min: u32,
    /// `pip_extent` - lowest free 8-page extent
    pub extent: u32,
    /// `pip_used` - pages allocated from this PIP
    pub used: u32,
    bits: &'a [u8],
}

pub const PIP_BITS_OFFSET: usize = 28;

impl<'a> PipPage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<PipPage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::PageInventory as u8 {
            return None;
        }
        Some(PipPage {
            pag,
            min: u32_at(page, 16),    // pip_min @16
            extent: u32_at(page, 20), // pip_extent @20
            used: u32_at(page, 24),   // pip_used @24
            bits: &page[PIP_BITS_OFFSET..],
        })
    }

    /// Pages described per PIP for a page size (8 per bitmap byte).
    pub fn pages_per_pip(page_size: usize) -> usize {
        (page_size - PIP_BITS_OFFSET) * 8
    }

    /// Is the page at `index` WITHIN this PIP free? (bit set = free)
    pub fn is_free(&self, index: usize) -> Option<bool> {
        let byte = self.bits.get(index / 8)?;
        Some(byte & (1 << (index % 8)) != 0)
    }

    /// Count free pages among the first `n` managed by this PIP.
    pub fn free_count(&self, n: usize) -> usize {
        (0..n).filter(|&i| self.is_free(i) == Some(true)).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pip_layout_and_bitmap() {
        let mut page = vec![0u8; 4096];
        page[0] = 2; // pag_pages
        page[16..20].copy_from_slice(&100u32.to_le_bytes()); // pip_min @16
        page[20..24].copy_from_slice(&96u32.to_le_bytes()); // pip_extent @20
        page[24..28].copy_from_slice(&97u32.to_le_bytes()); // pip_used @24
        page[28] = 0b0000_0101; // pages 0 and 2 free

        let pip = PipPage::decode(&page).unwrap();
        assert_eq!(pip.min, 100);
        assert_eq!(pip.extent, 96);
        assert_eq!(pip.used, 97);
        assert_eq!(pip.is_free(0), Some(true));
        assert_eq!(pip.is_free(1), Some(false));
        assert_eq!(pip.is_free(2), Some(true));
        assert_eq!(pip.free_count(8), 2);
    }

    #[test]
    fn capacity_matches_engine_formula() {
        // 8K pages: (8192-28)*8 = 65312 pages per PIP
        assert_eq!(PipPage::pages_per_pip(8192), 65312);
    }
}
