//! Pointer pages (`struct pointer_page`, ods.h:814): each relation's
//! ordered vector of data-page numbers. RDB$PAGES maps a relation to
//! its pointer pages; the pages themselves chain through `ppg_next`.
//! A data page slot of 0 means "no page here (yet)".

use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at};

pub struct PointerPage<'a> {
    pub pag: PageHeader,
    /// `ppg_sequence` - which pointer page of the relation this is
    pub sequence: u32,
    /// `ppg_next` - next pointer page, 0 at the end of the chain
    pub next: u32,
    /// `ppg_count` - active slots on this page
    pub count: u16,
    /// `ppg_relation` - owning relation id
    pub relation: u16,
    /// `ppg_min_space` - lowest slot with space available
    pub min_space: u16,
    slots: &'a [u8],
}

pub const PPG_PAGE_OFFSET: usize = 32;

impl<'a> PointerPage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<PointerPage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::Pointer as u8 {
            return None;
        }
        Some(PointerPage {
            pag,
            sequence: u32_at(page, 16),  // ppg_sequence @16
            next: u32_at(page, 20),      // ppg_next @20
            count: u16_at(page, 24),     // ppg_count @24
            relation: u16_at(page, 26),  // ppg_relation @26
            min_space: u16_at(page, 28), // ppg_min_space @28
            slots: &page[PPG_PAGE_OFFSET..],
        })
    }

    /// The data-page number in slot `i` (0 = empty slot).
    pub fn data_page(&self, i: usize) -> Option<u32> {
        if i >= self.count as usize {
            return None;
        }
        Some(u32_at(self.slots, i * 4))
    }

    /// Iterate the non-empty data-page numbers on this pointer page.
    pub fn data_pages(&self) -> impl Iterator<Item = u32> + '_ {
        (0..self.count as usize).filter_map(|i| {
            let p = self.data_page(i)?;
            (p != 0).then_some(p)
        })
    }
}

/// Walk every pointer page of `relation` in a whole-file image
/// (scanning for owners rather than reading RDB$PAGES - catalog-free,
/// which is what a low-level tool wants), yielding data page numbers
/// in (sequence, slot) order.
pub fn relation_data_pages(file: &[u8], page_size: usize, relation: u16) -> Vec<u32> {
    let mut pps: Vec<PointerPage> = file
        .chunks_exact(page_size)
        .filter(|p| p[0] == PageType::Pointer as u8)
        .filter_map(PointerPage::decode)
        .filter(|pp| pp.relation == relation)
        .collect();
    pps.sort_by_key(|pp| pp.sequence);
    pps.iter()
        .flat_map(|pp| pp.data_pages().collect::<Vec<_>>())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pointer_layout_and_slots() {
        let mut page = vec![0u8; 4096];
        page[0] = 4; // pag_pointer
        page[16..20].copy_from_slice(&1u32.to_le_bytes()); // ppg_sequence @16
        page[20..24].copy_from_slice(&77u32.to_le_bytes()); // ppg_next @20
        page[24..26].copy_from_slice(&3u16.to_le_bytes()); // ppg_count @24
        page[26..28].copy_from_slice(&128u16.to_le_bytes()); // ppg_relation @26
        page[28..30].copy_from_slice(&2u16.to_le_bytes()); // ppg_min_space @28
        page[32..36].copy_from_slice(&200u32.to_le_bytes()); // slot 0 @32
        page[36..40].copy_from_slice(&0u32.to_le_bytes()); // slot 1 empty
        page[40..44].copy_from_slice(&201u32.to_le_bytes()); // slot 2

        let pp = PointerPage::decode(&page).unwrap();
        assert_eq!(pp.sequence, 1);
        assert_eq!(pp.next, 77);
        assert_eq!(pp.count, 3);
        assert_eq!(pp.relation, 128);
        assert_eq!(pp.min_space, 2);
        assert_eq!(pp.data_pages().collect::<Vec<_>>(), vec![200, 201]);
        assert_eq!(pp.data_page(3), None); // beyond ppg_count
    }
}
