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

    pub fn entries(&self) -> impl Iterator<Item = IndexRootEntry> + '_ {
        (0..self.count.min(255) as u8).filter_map(|i| self.entry(i))
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;

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
