//! Transaction inventory pages (`struct tx_inv_page`, ods.h:862): two
//! bits per transaction, the durable heart of Firebird's MVCC. The
//! states are tra.h:487-490.

use crate::pages::{PageHeader, PageType};
use crate::u32_at;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum TxState {
    /// `tra_active` - or simply never started yet
    Active = 0,
    /// `tra_limbo` - prepared, two-phase-commit undecided
    Limbo = 1,
    /// `tra_dead` - rolled back
    Dead = 2,
    /// `tra_committed`
    Committed = 3,
}

impl TxState {
    pub fn name(self) -> &'static str {
        match self {
            TxState::Active => "active",
            TxState::Limbo => "limbo",
            TxState::Dead => "dead",
            TxState::Committed => "committed",
        }
    }
}

pub struct TipPage<'a> {
    pub pag: PageHeader,
    /// `tip_next` - next TIP in the chain (offset 16)
    pub next: u32,
    /// The 2-bits-per-transaction state array (offset 20)
    bits: &'a [u8],
}

pub const TIP_TRANSACTIONS_OFFSET: usize = 20;

impl<'a> TipPage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<TipPage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::TransactionInventory as u8 {
            return None;
        }
        Some(TipPage {
            pag,
            next: u32_at(page, 16),
            bits: &page[TIP_TRANSACTIONS_OFFSET..],
        })
    }

    /// Transactions described per TIP page for a given page size -
    /// the engine's `transactions per tip` (4 per byte).
    pub fn transactions_per_page(page_size: usize) -> usize {
        (page_size - TIP_TRANSACTIONS_OFFSET) * 4
    }

    /// The state of the transaction at `index` WITHIN this page
    /// (i.e. transaction id modulo transactions_per_page).
    pub fn state(&self, index: usize) -> Option<TxState> {
        let byte = self.bits.get(index / 4)?;
        let shift = (index % 4) * 2;
        Some(match (byte >> shift) & 0b11 {
            0 => TxState::Active,
            1 => TxState::Limbo,
            2 => TxState::Dead,
            _ => TxState::Committed,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tip_layout_and_two_bit_states() {
        let mut page = vec![0u8; 4096];
        page[0] = 3; // pag_transactions
        page[16..20].copy_from_slice(&99u32.to_le_bytes()); // tip_next @16

        // transactions 0..4 in the first bits byte (offset 20):
        // 0 committed (11), 1 dead (10), 2 limbo (01), 3 active (00)
        page[20] = 0b00_01_10_11;
        // transaction 4 committed - second byte, low bits
        page[21] = 0b00000011;

        let tip = TipPage::decode(&page).unwrap();
        assert_eq!(tip.next, 99);
        assert_eq!(tip.state(0), Some(TxState::Committed));
        assert_eq!(tip.state(1), Some(TxState::Dead));
        assert_eq!(tip.state(2), Some(TxState::Limbo));
        assert_eq!(tip.state(3), Some(TxState::Active));
        assert_eq!(tip.state(4), Some(TxState::Committed));
    }

    #[test]
    fn capacity_matches_engine_formula() {
        // 8K pages: (8192-20)*4 = 32688 transactions per TIP
        assert_eq!(TipPage::transactions_per_page(8192), 32688);
    }
}
