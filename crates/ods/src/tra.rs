//! The transaction system's durable half, converted from the TIP
//! machinery in `tra.cpp` and the version-chain rules in `vio.cpp`:
//! transaction-state lookup across the chained inventory pages, delta
//! back-version reconstruction (`Difference::apply`, sqz.cpp:515),
//! and the committed-only visibility walk - "which version of each
//! record would a reader see if it considers exactly the committed
//! transactions" - the core MVCC question, answerable from the raw
//! file because both the versions and the transaction states are
//! durable.

use crate::data::{flags, DataPage};
use crate::format::{decode_record, Descriptor, Value};
use crate::pointer::relation_data_pages;
use crate::tip::{TipPage, TxState};
use crate::u16_at;

/// All TIP pages in transaction order. TIPs chain through `tip_next`;
/// the head is the TIP no other TIP points to (page 2 in practice,
/// but derived, not assumed).
pub struct TipChain<'a> {
    pages: Vec<TipPage<'a>>,
    per_page: usize,
}

impl<'a> TipChain<'a> {
    pub fn read(file: &'a [u8], page_size: usize) -> Option<TipChain<'a>> {
        let mut tips: Vec<TipPage> = file
            .chunks_exact(page_size)
            .filter(|p| p[0] == crate::PageType::TransactionInventory as u8)
            .filter_map(TipPage::decode)
            .collect();
        if tips.is_empty() {
            return None;
        }
        // the head is the TIP no other TIP's tip_next points to
        let head = tips
            .iter()
            .map(|t| t.pag.page_no)
            .find(|no| !tips.iter().any(|t| t.next == *no))?;

        let mut ordered = Vec::with_capacity(tips.len());
        let mut cur = head;
        while cur != 0 {
            let pos = tips.iter().position(|t| t.pag.page_no == cur)?;
            let t = tips.swap_remove(pos);
            cur = t.next;
            ordered.push(t);
        }
        Some(TipChain {
            per_page: TipPage::transactions_per_page(page_size),
            pages: ordered,
        })
    }

    /// State of transaction `id` (tra.cpp's TIP lookup: page
    /// `id / per_page`, index `id % per_page`).
    pub fn state(&self, id: u64) -> Option<TxState> {
        let page = self.pages.get((id as usize) / self.per_page)?;
        page.state((id as usize) % self.per_page)
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }
}

/// `Difference::apply` (sqz.cpp:515): reconstruct the PRIOR version's
/// image by applying a differences stream to (a copy of) the newer
/// image. Positive control byte = take that many literal bytes from
/// the stream; negative = retain that many bytes of the newer image.
pub fn apply_differences(diff: &[u8], newer_image: &[u8]) -> Option<Vec<u8>> {
    let mut out = newer_image.to_vec();
    let mut p = 0usize; // position in out
    let mut d = 0usize; // position in diff
    while d < diff.len() && p < out.len() {
        let l = diff[d] as i8;
        d += 1;
        if l > 0 {
            let n = l as usize;
            if p + n > out.len() || d + n > diff.len() {
                return None; // BUGCHECK 176/177 territory
            }
            out[p..p + n].copy_from_slice(&diff[d..d + n]);
            p += n;
            d += n;
        } else {
            p += (-(l as i32)) as usize;
        }
    }
    // trailing difference bytes must be zero padding (sqz.cpp:553)
    if diff[d..].iter().any(|b| *b != 0) {
        return None;
    }
    out.truncate(p.min(out.len()));
    Some(out)
}

/// One visible row: its record number and decoded values.
pub struct VisibleRow {
    pub recno: u64,
    pub values: Vec<Value>,
    /// how many chain steps back the visible version was found
    pub versions_walked: u32,
    /// how many of those steps reconstructed a delta (rhd_delta)
    pub deltas_applied: u32,
}

/// The committed-only visibility walk (the vio.cpp rule a fresh
/// snapshot reader applies when every interesting transaction is
/// either committed or not): for each primary record, take the newest
/// version whose transaction is committed - walking the back-version
/// chain (`rhd_b_page`/`rhd_b_line`), reconstructing delta versions
/// (the NEWER version's `rhd_delta` flag says its prior is stored as
/// differences) - and drop the row if that version is a deleted stub
/// or no committed version exists (an uncommitted insert).
pub fn visible_rows(
    file: &[u8],
    page_size: usize,
    relation: u16,
    descs: &[Descriptor],
    tips: &TipChain,
) -> Vec<VisibleRow> {
    let recs_per_dp = crate::format::max_recs_per_dp(page_size);
    let mut out = Vec::new();

    let fetch_page = |no: u32| {
        let start = no as usize * page_size;
        file.get(start..start + page_size)
            .and_then(DataPage::decode)
    };

    for dp_no in relation_data_pages(file, page_size, relation) {
        let Some(dp) = fetch_page(dp_no) else {
            continue;
        };
        for r in dp.records() {
            // only chain heads: back versions and blobs are reached
            // through their primaries; fragments not yet handled
            if r.flags & (flags::CHAIN | flags::BLOB | flags::FRAGMENT) != 0 {
                continue;
            }
            let recno = dp.sequence as u64 * recs_per_dp + r.slot as u64;

            let mut current = r.clone();
            let mut image: Option<Vec<u8>> = if current.flags & flags::DELETED != 0 {
                None // deleted stubs carry no data
            } else {
                current.image()
            };
            let mut walked = 0u32;
            let mut deltas = 0u32;

            loop {
                let committed = tips.state(current.transaction) == Some(TxState::Committed);
                if committed {
                    if current.flags & flags::DELETED == 0 {
                        if let Some(img) = image {
                            out.push(VisibleRow {
                                recno,
                                values: decode_record(&img, descs),
                                versions_walked: walked,
                                deltas_applied: deltas,
                            });
                        }
                    }
                    break;
                }
                // not committed: step to the back version
                if current.back_page == 0 {
                    break; // uncommitted insert - no committed version
                }
                let Some(bdp) = fetch_page(current.back_page) else {
                    break;
                };
                let Some(back) = bdp.record(current.back_line) else {
                    break;
                };
                let Some(back_data) = back.image() else { break };

                image = if current.flags & flags::DELTA != 0 {
                    // prior version stored as differences against the
                    // CURRENT image (ods.h:1012)
                    deltas += 1;
                    match image
                        .as_deref()
                        .and_then(|img| apply_differences(&back_data, img))
                    {
                        Some(prior) => Some(prior),
                        None => break,
                    }
                } else {
                    Some(back_data)
                };
                current = back;
                walked += 1;
            }
        }
    }
    out
}

/// Header-vs-TIP invariants a healthy database file satisfies; each
/// violated invariant is returned as a message.
pub fn check_invariants(file: &[u8], page_size: usize) -> Vec<String> {
    let mut problems = Vec::new();
    let Some(h) = crate::HeaderPage::decode(file) else {
        return vec!["no header page".into()];
    };
    let _ = page_size;
    if h.oldest_transaction > h.oldest_active {
        problems.push(format!(
            "OIT {} > OAT {}",
            h.oldest_transaction, h.oldest_active
        ));
    }
    if h.oldest_active > h.next_transaction {
        problems.push(format!(
            "OAT {} > next {}",
            h.oldest_active, h.next_transaction
        ));
    }
    if h.oldest_snapshot > h.next_transaction {
        problems.push(format!(
            "OST {} > next {}",
            h.oldest_snapshot, h.next_transaction
        ));
    }
    problems
}

/// Convenience: page-size accessor for tools.
pub fn page_size_of(file: &[u8]) -> Option<usize> {
    Some(u16_at(file, 16) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_differences_matches_sqz_cpp() {
        // newer = "AAAABBBB"; diff: retain 4, replace 4 with "CCDD"
        let newer = b"AAAABBBB";
        let diff = [(-4i8) as u8, 4, b'C', b'C', b'D', b'D'];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AAAACCDD");

        // shortening: retain 2 only -> length 2
        let diff = [(-2i8) as u8];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AA");

        // literal overrun is an error (BUGCHECK 176)
        let diff = [3, b'X'];
        assert!(apply_differences(&diff, newer).is_none());

        // trailing nonzero garbage is an error (sqz.cpp:553)
        let newer2 = b"AB";
        let diff = [(-2i8) as u8, 7];
        assert!(apply_differences(&diff, newer2).is_none());
    }
}
