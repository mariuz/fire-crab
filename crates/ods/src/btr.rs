//! B-tree index pages, converted from `struct index_root_page` /
//! `struct btree_page` (ods.h:376/296) and the node encoding in
//! `btn.h` (`IndexNode::readNode`, btn.h:111-262): a three-bit flag
//! field packed with the low bits of a varint record number, optional
//! varint page number (non-leaf), varint prefix and length, then the
//! key's suffix bytes — prefix compression against the previous key.
//!
//! The walk this module offers is the leaf-level scan the engine's
//! index retrievals bottom out in: descend the leftmost spine, then
//! follow `btr_sibling` across the level, reconstructing full keys by
//! prefix decompression and yielding `(key, record number)` in index
//! order.

use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at, u64_at};

/// One index on an index root page (`irt_repeat`, ods.h:383; 24
/// bytes, offsets pinned by the asserts at ods.h:420-427).
#[derive(Clone, Debug)]
pub struct IndexRootEntry {
    /// Index id = slot position (what RDB$INDICES.RDB$INDEX_ID - 1
    /// refers to)
    pub id: u8,
    pub transaction: u64,
    /// Root btree page, 0 if the slot is empty
    pub root_page: u32,
    pub flags: u16,
    pub state: u8,
    pub key_count: u8,
}

pub struct IndexRootPage<'a> {
    pub pag: PageHeader,
    pub relation: u16,
    pub count: u16,
    page: &'a [u8],
}

impl<'a> IndexRootPage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<IndexRootPage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::IndexRoot as u8 {
            return None;
        }
        Some(IndexRootPage {
            pag,
            relation: u16_at(page, 16), // irt_relation @16
            count: u16_at(page, 18),    // irt_count @18
            page,
        })
    }

    pub fn entry(&self, id: u8) -> Option<IndexRootEntry> {
        if id as u16 >= self.count {
            return None;
        }
        let at = 24 + id as usize * 24; // irt_rpt @24, 24 bytes each
        let e = self.page.get(at..at + 24)?;
        Some(IndexRootEntry {
            id,
            transaction: u64_at(e, 0), // irt_transaction @0
            root_page: u32_at(e, 8),   // irt_page_num @8
            flags: u16_at(e, 18),      // irt_flags @18
            state: e[20],              // irt_state @20
            key_count: e[21],          // irt_keys @21
        })
    }

    /// The relation's indexes that carry entries - every slot with a
    /// root page, whatever its state in ods.h's lifecycle. A DROPPED
    /// index is one of them: its tree lives on until the index is
    /// physically removed (`irt_commit`/`irt_drop` keep `irt_page_num`,
    /// and `getRoot()` only reports 0 for `irt_unused`), and the
    /// engine's own validation walks it - `gfix` reports "Index n is
    /// corrupt {missing entries for record m}" the moment a writer adds
    /// a record without keying it into that tree.
    ///
    /// What a dropped index stops doing is ENFORCING: `setDrop`
    /// (ods.h:613) clears `irt_unique | irt_foreign | irt_primary`, so
    /// the flags this iterator hands back turn uniqueness off by
    /// themselves - the same mechanism the engine relies on.
    pub fn live_entries(&self) -> impl Iterator<Item = IndexRootEntry> + '_ {
        self.entries().filter(|e| e.root_page != 0 && e.state != IRT_UNUSED)
    }

    pub fn entries(&self) -> impl Iterator<Item = IndexRootEntry> + '_ {
        (0..self.count.min(255) as u8).filter_map(|i| self.entry(i))
    }
}

/// `irt_unused` - an empty index-root slot (ods.h:450).
pub const IRT_UNUSED: u8 = 0;
/// `irt_normal` - the settled working state of an index (ods.h:453).
pub const IRT_NORMAL: u8 = 3;
/// `irt_drop` - a dropped index awaiting physical removal (ods.h:456).
pub const IRT_DROP: u8 = 6;

/// A b-tree bucket (`btree_page`, ods.h:296; offsets pinned by
/// ods.h:312-324). Nodes begin after the jump table.
pub struct BtreePage<'a> {
    pub pag: PageHeader,
    pub sibling: u32,
    pub left_sibling: u32,
    pub relation: u16,
    pub length: u16,
    pub index_id: u8,
    /// 0 = leaf
    pub level: u8,
    pub jump_size: u16,
    page: &'a [u8],
}

pub const BTR_NODES_OFFSET: usize = 39; // btr_nodes @39 (BTR_SIZE)

impl<'a> BtreePage<'a> {
    pub fn decode(page: &'a [u8]) -> Option<BtreePage<'a>> {
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::Index as u8 {
            return None;
        }
        Some(BtreePage {
            pag,
            sibling: u32_at(page, 16),      // btr_sibling @16
            left_sibling: u32_at(page, 20), // btr_left_sibling @20
            relation: u16_at(page, 28),     // btr_relation @28
            length: u16_at(page, 30),       // btr_length @30
            index_id: page[32],             // btr_id @32
            level: page[33],                // btr_level @33
            jump_size: u16_at(page, 36),    // btr_jump_size @36
            page,
        })
    }

    /// Offset of the first node: `getPointerFirstNode` = BTR_SIZE +
    /// btr_jump_size (the jump table sits between header and nodes).
    pub fn first_node(&self) -> usize {
        BTR_NODES_OFFSET + self.jump_size as usize
    }

    pub fn bytes(&self) -> &'a [u8] {
        self.page
    }
}

/// One decoded index node (btn.h readNode).
#[derive(Clone, Debug, Default)]
pub struct IndexNode {
    pub is_end_bucket: bool,
    pub is_end_level: bool,
    pub prefix: u16,
    pub length: u16,
    pub record_number: u64,
    /// Only meaningful on non-leaf pages
    pub page_number: u32,
    /// Offset of the suffix bytes within the page
    pub data_at: usize,
    /// Offset just past this node (the next node)
    pub next_at: usize,
}

const BTN_END_LEVEL: u8 = 1; // btn.h:40
const BTN_END_BUCKET: u8 = 2;
const BTN_ZERO_PREFIX_ZERO_LENGTH: u8 = 3;
const BTN_ZERO_LENGTH: u8 = 4;
const BTN_ONE_LENGTH: u8 = 5;

/// Port of `IndexNode::readNode` (btn.h:111): decode the node at
/// `at`, returning None if the page ends mid-node.
pub fn read_node(page: &[u8], at: usize, leaf: bool) -> Option<IndexNode> {
    let mut p = at;
    let first = *page.get(p)?;
    p += 1;
    let internal_flags = (first & 0xE0) >> 5;
    let mut number: u64 = (first & 0x1F) as u64;

    let mut node = IndexNode {
        is_end_level: internal_flags == BTN_END_LEVEL,
        is_end_bucket: internal_flags == BTN_END_BUCKET,
        ..Default::default()
    };
    if node.is_end_level {
        node.data_at = p;
        node.next_at = p;
        return Some(node);
    }

    // varint record number: 5 bits in the first byte, then 7-bit
    // continuation bytes at shifts 5/12/19/26/33 (btn.h:146-176)
    let mut shift = 5;
    loop {
        let b = *page.get(p)? as u64;
        p += 1;
        number |= (b & 0x7F) << shift;
        if b < 128 || shift >= 33 {
            break;
        }
        shift += 7;
    }
    node.record_number = number;

    if !leaf {
        // varint page number, shifts 0/7/14/21/28 (btn.h:190-214)
        let mut pn: u32 = 0;
        let mut shift = 0;
        loop {
            let b = *page.get(p)? as u32;
            p += 1;
            if shift == 28 {
                pn |= (b & 0x0F) << 28;
                break;
            }
            pn |= (b & 0x7F) << shift;
            if b < 128 {
                break;
            }
            shift += 7;
        }
        node.page_number = pn;
    }

    // prefix: up to 14 bits (btn.h:217-231)
    if internal_flags != BTN_ZERO_PREFIX_ZERO_LENGTH {
        let b = *page.get(p)? as u16;
        p += 1;
        node.prefix = b & 0x7F;
        if b & 0x80 != 0 {
            let b2 = *page.get(p)? as u16;
            p += 1;
            node.prefix |= (b2 & 0x7F) << 7;
        }
    }

    // length: flag-encoded 0/1, else up to 14 bits (btn.h:234-255)
    node.length = match internal_flags {
        BTN_ZERO_LENGTH | BTN_ZERO_PREFIX_ZERO_LENGTH => 0,
        BTN_ONE_LENGTH => 1,
        _ => {
            let b = *page.get(p)? as u16;
            p += 1;
            let mut len = b & 0x7F;
            if b & 0x80 != 0 {
                let b2 = *page.get(p)? as u16;
                p += 1;
                len |= (b2 & 0x7F) << 7;
            }
            len
        }
    };

    node.data_at = p;
    node.next_at = p + node.length as usize;
    if node.next_at > page.len() {
        return None;
    }
    Some(node)
}

/// Find a relation's index root page by scanning (catalog-free, like
/// the pointer-page scan).
pub fn find_index_root<'a>(
    file: &'a [u8],
    page_size: usize,
    relation: u16,
) -> Option<IndexRootPage<'a>> {
    file.chunks_exact(page_size)
        .filter(|p| p[0] == PageType::IndexRoot as u8)
        .filter_map(IndexRootPage::decode)
        .find(|irt| irt.relation == relation)
}

/// Walk one index's leaf level in order, yielding `(key, recno)` with
/// keys reconstructed by prefix decompression. Descends the leftmost
/// spine from the root, then follows `btr_sibling`; a page's walk
/// stops at END_BUCKET (the sibling continues the level) and the
/// level ends at END_LEVEL.
pub fn walk_index_leaves(
    file: &[u8],
    page_size: usize,
    relation: u16,
    index_id: u8,
) -> Option<Vec<(Vec<u8>, u64)>> {
    let root_no = find_index_root(file, page_size, relation)?
        .entry(index_id)?
        .root_page;
    if root_no == 0 {
        return None;
    }
    let get = |no: u32| {
        let start = no as usize * page_size;
        file.get(start..start + page_size)
            .and_then(BtreePage::decode)
    };

    // descend to the leftmost leaf
    let mut page = get(root_no)?;
    while page.level > 0 {
        let node = read_node(page.bytes(), page.first_node(), false)?;
        page = get(node.page_number)?;
    }

    let mut out = Vec::new();
    let mut key: Vec<u8> = Vec::new();
    loop {
        let bytes = page.bytes();
        let mut at = page.first_node();
        loop {
            let node = read_node(bytes, at, true)?;
            if node.is_end_level {
                return Some(out);
            }
            if node.is_end_bucket {
                break;
            }
            key.truncate(node.prefix as usize);
            key.extend_from_slice(&bytes[node.data_at..node.data_at + node.length as usize]);
            out.push((key.clone(), node.record_number));
            at = node.next_at;
        }
        if page.sibling == 0 {
            return Some(out);
        }
        page = get(page.sibling)?;
    }
}

/// Descend the tree to `key` and collect the record numbers of every
/// leaf entry whose key EQUALS it - a port of the retrieval half of
/// `BTR_lookup`/`BTR_find_page` (btr.cpp), where `walk_index_leaves`
/// is the whole-level walk.
///
/// This is what makes a retrieval INDEX-DRIVEN rather than a scan: the
/// tree is descended once per level, and only the leaf pages holding
/// the key are read. What it returns is a set of CANDIDATES, never an
/// answer: index entries survive the rows they describe (an UPDATE adds
/// the new key and leaves the old one for garbage collection, a DELETE
/// removes nothing), so the caller must fetch each record and apply the
/// predicate. That is the engine's own arrangement, and it is why a
/// stale entry costs a wasted fetch rather than a wrong row.
///
/// Duplicates may span pages, so the sibling chain is followed while
/// the key still matches.
pub fn lookup_key(
    file: &[u8],
    page_size: usize,
    relation: u16,
    index_id: u8,
    key: &[u8],
) -> Option<Vec<(Vec<u8>, u64)>> {
    lookup_range(
        file,
        page_size,
        relation,
        index_id,
        Some((key, true)),
        Some((key, true)),
    )
}

/// Descend to `lo` and walk the leaf level to `hi`, collecting record
/// numbers - the retrieval half of `BTR_lookup`/`BTR_find_page`
/// (btr.cpp), where `walk_index_leaves` is the whole-level walk.
///
/// Each bound is `(key, inclusive)`; `None` means unbounded on that
/// side. An EQUALITY is the degenerate case where both bounds are the
/// same key, inclusive, which is why there is one function here rather
/// than two - the descent and the stop condition are the part that is
/// easy to get subtly wrong.
///
/// This is what makes a retrieval INDEX-DRIVEN rather than a scan: the
/// tree is descended once per level, and only the leaf pages inside the
/// range are read.
///
/// What it returns is a set of CANDIDATES, never an answer - each as
/// `(key, record number)`. Index entries survive the rows they describe:
/// an UPDATE adds the new key and LEAVES THE OLD ONE for garbage
/// collection, and a DELETE removes nothing. So the caller must fetch
/// each record and check TWO things, not one:
///
///   - the predicate, as it would over a full scan; and
///   - that the record STILL CARRIES THIS KEY.
///
/// The second is not optional. A record whose key changed is named by
/// BOTH entries, and if a range covers both it is fetched twice and, in
/// a navigating retrieval, appears at the OLD key's position. The
/// predicate cannot catch either - the row genuinely matches. That is
/// why the key travels back with the record number.
///
/// The key encoding is ORDER-PRESERVING (that is what `compress` is
/// for), so a byte range IS a value range - for an ASCENDING index. A
/// descending one complements its keys, so its caller must hand the
/// bounds over already swapped.
pub fn lookup_range(
    file: &[u8],
    page_size: usize,
    relation: u16,
    index_id: u8,
    lo: Option<(&[u8], bool)>,
    hi: Option<(&[u8], bool)>,
) -> Option<Vec<(Vec<u8>, u64)>> {
    let root_no = find_index_root(file, page_size, relation)?
        .entry(index_id)?
        .root_page;
    if root_no == 0 {
        return None;
    }
    let get = |no: u32| {
        let start = no as usize * page_size;
        file.get(start..start + page_size).and_then(BtreePage::decode)
    };

    // Descend: on each non-leaf page take the LAST node whose key is
    // <= the lower bound (the leftmost node otherwise), which is the
    // child whose range can hold it. With no lower bound the descent is
    // down the leftmost spine, which is where `walk_index_leaves`
    // starts too.
    let mut page = get(root_no)?;
    while page.level > 0 {
        let bytes = page.bytes();
        let mut at = page.first_node();
        let mut node_key: Vec<u8> = Vec::new();
        let mut chosen: Option<u32> = None;
        loop {
            let node = read_node(bytes, at, false)?;
            if node.is_end_level || node.is_end_bucket {
                break;
            }
            node_key.truncate(node.prefix as usize);
            node_key.extend_from_slice(&bytes[node.data_at..node.data_at + node.length as usize]);
            if let Some((lo_key, _)) = lo {
                // STRICTLY LESS, and that word is the whole of it. A
                // non-leaf node's key is the LOWEST key of its child
                // page, so when one value's duplicates span several leaf
                // pages, SEVERAL non-leaf nodes carry that same key.
                // Advancing while `key <= target` lands on the LAST of
                // them and skips every earlier page that also holds it -
                // which loses rows silently, because they never become
                // candidates for the predicate to judge. The child that
                // can contain the FIRST occurrence is the last one whose
                // key is strictly less than the target (or the leftmost,
                // when even that is not less).
                if chosen.is_some() && node_key.as_slice() >= lo_key {
                    break;
                }
            } else if chosen.is_some() {
                break; // unbounded below: the leftmost child
            }
            chosen = Some(node.page_number);
            at = node.next_at;
        }
        match chosen {
            Some(next) => page = get(next)?,
            None if page.sibling != 0 => {
                page = get(page.sibling)?;
                continue;
            }
            None => return Some(Vec::new()),
        }
    }

    // Walk the leaf level, keeping what the bounds admit and stopping
    // at the first key past the upper one.
    let mut out = Vec::new();
    let mut leaf_key: Vec<u8> = Vec::new();
    loop {
        let bytes = page.bytes();
        let mut at = page.first_node();
        loop {
            let node = read_node(bytes, at, true)?;
            if node.is_end_level {
                return Some(out);
            }
            if node.is_end_bucket {
                break;
            }
            leaf_key.truncate(node.prefix as usize);
            leaf_key.extend_from_slice(&bytes[node.data_at..node.data_at + node.length as usize]);
            if let Some((hi_key, incl)) = hi {
                let past = match leaf_key.as_slice().cmp(hi_key) {
                    std::cmp::Ordering::Greater => true,
                    std::cmp::Ordering::Equal => !incl,
                    std::cmp::Ordering::Less => false,
                };
                if past {
                    return Some(out);
                }
            }
            let admitted = match lo {
                None => true,
                Some((lo_key, incl)) => match leaf_key.as_slice().cmp(lo_key) {
                    std::cmp::Ordering::Less => false,
                    std::cmp::Ordering::Equal => incl,
                    std::cmp::Ordering::Greater => true,
                },
            };
            if admitted {
                // the KEY travels with the record number: an entry
                // outlives the version that put it there, so the caller
                // has to be able to ask whether the record it names
                // still carries this key
                out.push((leaf_key.clone(), node.record_number));
            }
            at = node.next_at;
        }
        if page.sibling == 0 {
            return Some(out);
        }
        page = get(page.sibling)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recnos_of(r: Option<Vec<(Vec<u8>, u64)>>) -> Vec<u64> {
        r.unwrap().into_iter().map(|(_, n)| n).collect()
    }

    /// The retrieval half against the WRITE half: build a real index
    /// with `btw::insert_index_entry`, then ask `lookup_key` for keys
    /// that are there, keys that are not, and a key with duplicates.
    ///
    /// A round trip is the right shape here because the two halves are
    /// the two directions of one format: a descent that agreed with a
    /// hand-built page but not with the writer would be a test of the
    /// test.
    #[test]
    fn lookup_key_finds_what_the_writer_put_there() {
        let page_size = 1024usize;
        let rel = 128u16;
        // page 0 unused, page 1 the index root, page 2 the tree root
        let mut file = vec![0u8; page_size * 8];
        file[page_size] = PageType::IndexRoot as u8;
        file[page_size + 16..page_size + 18].copy_from_slice(&rel.to_le_bytes());
        file[page_size + 18..page_size + 20].copy_from_slice(&1u16.to_le_bytes()); // irt_count
        // one index entry: id 0, root page 2 (irt_page_num @8 of the slot)
        let entry_at = page_size + 24;
        file[entry_at + 8..entry_at + 12].copy_from_slice(&2u32.to_le_bytes());
        file[entry_at + 20] = IRT_NORMAL;
        crate::btw::write_empty_root(&mut file, page_size, 2, rel, 0).unwrap();

        let key = |n: u8| vec![0xC0, n];
        for (n, recno) in [(1u8, 10u64), (3, 30), (5, 50), (3, 31), (7, 70)] {
            crate::btw::insert_index_entry(&mut file, page_size, rel, 0, &key(n), recno, false)
                .unwrap();
        }

        // a key with one entry
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(5))), vec![50]);
        // the first and the last, which are where a descent goes wrong
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(1))), vec![10]);
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(7))), vec![70]);
        // DUPLICATES come back together, in record-number order
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(3))), vec![30, 31]);
        // a key that is not there is an EMPTY answer, not a nearby one -
        // returning the neighbour is how an index lookup invents rows
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(4))), Vec::<u64>::new());
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(0))), Vec::<u64>::new());
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(9))), Vec::<u64>::new());
        // and the whole level still walks, so the two agree
        let all = walk_index_leaves(&file, page_size, rel, 0).unwrap();
        assert_eq!(all.len(), 5);
        assert_eq!(all.first().map(|(_, r)| *r), Some(10));
    }

    /// The RANGE half, on the same writer-built tree: each bound is
    /// optional and each carries its own inclusivity, which is exactly
    /// where an off-by-one row lives.
    #[test]
    fn lookup_range_respects_both_bounds() {
        let page_size = 1024usize;
        let rel = 128u16;
        let mut file = vec![0u8; page_size * 8];
        file[page_size] = PageType::IndexRoot as u8;
        file[page_size + 16..page_size + 18].copy_from_slice(&rel.to_le_bytes());
        file[page_size + 18..page_size + 20].copy_from_slice(&1u16.to_le_bytes());
        let entry_at = page_size + 24;
        file[entry_at + 8..entry_at + 12].copy_from_slice(&2u32.to_le_bytes());
        file[entry_at + 20] = IRT_NORMAL;
        crate::btw::write_empty_root(&mut file, page_size, 2, rel, 0).unwrap();

        let key = |n: u8| vec![0xC0, n];
        for n in [1u8, 3, 5, 7, 9] {
            crate::btw::insert_index_entry(
                &mut file, page_size, rel, 0, &key(n), n as u64 * 10, false,
            )
            .unwrap();
        }
        let range = |lo: Option<(u8, bool)>, hi: Option<(u8, bool)>| {
            let lk = lo.map(|(n, i)| (key(n), i));
            let hk = hi.map(|(n, i)| (key(n), i));
            lookup_range(
                &file,
                page_size,
                rel,
                0,
                lk.as_ref().map(|(k, i)| (k.as_slice(), *i)),
                hk.as_ref().map(|(k, i)| (k.as_slice(), *i)),
            )
            .unwrap()
            .into_iter()
            .map(|(_, r)| r)
            .collect::<Vec<u64>>()
        };

        // inclusivity, one bound at a time
        assert_eq!(range(Some((5, true)), None), vec![50, 70, 90]);
        assert_eq!(range(Some((5, false)), None), vec![70, 90]);
        assert_eq!(range(None, Some((5, true))), vec![10, 30, 50]);
        assert_eq!(range(None, Some((5, false))), vec![10, 30]);
        // both bounds, and a bound that falls BETWEEN two keys
        assert_eq!(range(Some((3, true)), Some((7, true))), vec![30, 50, 70]);
        assert_eq!(range(Some((4, true)), Some((6, true))), vec![50]);
        // unbounded both ways is the whole level
        assert_eq!(range(None, None), vec![10, 30, 50, 70, 90]);
        // past the ends, and CROSSED bounds - an empty answer, not a
        // wrapped one
        assert_eq!(range(Some((9, false)), None), Vec::<u64>::new());
        assert_eq!(range(None, Some((1, false))), Vec::<u64>::new());
        assert_eq!(range(Some((7, true)), Some((3, true))), Vec::<u64>::new());
        // and an equality is the degenerate range, which is what
        // `lookup_key` asks for
        assert_eq!(range(Some((5, true)), Some((5, true))), vec![50]);
        assert_eq!(recnos_of(lookup_key(&file, page_size, rel, 0, &key(5))), vec![50]);
    }

    // A DUPLICATE RUN THAT SPANS LEAF PAGES - the descent's page
    // boundary - is NOT tested here, and the reason is worth recording.
    // Building such a tree in memory means letting the writer SPLIT,
    // which needs a page-inventory page to allocate from; a hand-built
    // PIP produced a tree the writer then walked forever. The real
    // thing is covered end-to-end instead, by
    // qa/serve-real-index.sh's 6000-identical-key fixture against the
    // live engine - which is where the bug was found in the first
    // place, and where a single-page tree could never have found it.

    /// Every slot with a root page carries entries, whatever its state
    /// - a freshly engine-created index idles in irt_rollback (2) and a
    /// dropped one sits in irt_drop (6) with its tree still validated.
    /// Only an unused slot is skipped; a dropped index's flags come
    /// back cleared, which is what turns its uniqueness off.
    #[test]
    fn every_slot_with_a_root_page_carries_entries() {
        let page_size = 1024usize;
        let mut page = vec![0u8; page_size];
        page[0] = 6; // pag_root
        page[16..18].copy_from_slice(&128u16.to_le_bytes()); // irt_relation
        page[18..20].copy_from_slice(&4u16.to_le_bytes()); // irt_count
        // slot 3 is unused: no root page, state irt_unused
        for (slot, state, root) in [(0u8, 2u8, 100u32), (1, 3, 101), (2, IRT_DROP, 102), (3, 0, 0)] {
            let at = 24 + slot as usize * 24;
            page[at + 8..at + 12].copy_from_slice(&root.to_le_bytes());
            page[at + 20] = state;
            page[at + 21] = 1; // one key
        }
        let irt = IndexRootPage::decode(&page).expect("index root");
        let live: Vec<u8> = irt.live_entries().map(|e| e.id).collect();
        assert_eq!(live, vec![0, 1, 2], "the dropped index's tree is maintained too");
        assert_eq!(irt.entries().count(), 4, "every slot is still visible");
    }

    /// Hand-encode nodes per btn.h and decode them back.
    #[test]
    fn node_decode_matches_btn_h() {
        // leaf node: flags 0 (generic), recno 300 = 0b100101100:
        // low 5 bits = 0b01100 in byte0, continuation (300>>5)=9,
        // prefix 2, length 3, data "abc"
        let page = [
            0b000_01100u8,
            9,
            2,
            3,
            b'a',
            b'b',
            b'c',        // node
            0b001_00000, // END_LEVEL
        ];
        let n = read_node(&page, 0, true).unwrap();
        assert!(!n.is_end_level && !n.is_end_bucket);
        assert_eq!(n.record_number, 300);
        assert_eq!(n.prefix, 2);
        assert_eq!(n.length, 3);
        assert_eq!(&page[n.data_at..n.data_at + 3], b"abc");

        let end = read_node(&page, n.next_at, true).unwrap();
        assert!(end.is_end_level);
    }

    #[test]
    fn node_flag_encodings() {
        // BTN_ZERO_PREFIX_ZERO_LENGTH (3): recno 5, no prefix/length bytes
        let page = [0b011_00101u8, 0];
        let n = read_node(&page, 0, true).unwrap();
        assert_eq!(n.record_number, 5);
        assert_eq!((n.prefix, n.length), (0, 0));

        // BTN_ONE_LENGTH (5): recno 1, prefix 4, length 1, one data byte
        let page = [0b101_00001u8, 0, 4, b'z'];
        let n = read_node(&page, 0, true).unwrap();
        assert_eq!((n.prefix, n.length), (4, 1));
        assert_eq!(page[n.data_at], b'z');
    }

    #[test]
    fn nonleaf_node_reads_page_number() {
        // flags 4 (BTN_ZERO_LENGTH): recno 0, page number 200 (varint
        // 2 bytes: 0x80|72, 1), prefix 0
        let page = [0b100_00000u8, 0, 0xC8, 1, 0];
        let n = read_node(&page, 0, false).unwrap();
        assert_eq!(n.page_number, 200);
        assert_eq!(n.length, 0);
    }

    #[test]
    fn multibyte_recno_varint() {
        // recno = 1_000_000: bits = 0xF4240.
        // low5 = 0b00000; b1 = (1000000>>5)&0x7F | cont; ...
        let recno: u64 = 1_000_000;
        let mut bytes = vec![(recno & 0x1F) as u8];
        let mut rest = recno >> 5;
        loop {
            let mut b = (rest & 0x7F) as u8;
            rest >>= 7;
            if rest != 0 {
                b |= 0x80;
            }
            bytes.push(b);
            if rest == 0 {
                break;
            }
        }
        bytes.extend_from_slice(&[0, 0]); // prefix 0, length 0
        let n = read_node(&bytes, 0, true).unwrap();
        assert_eq!(n.record_number, recno);
    }
}
