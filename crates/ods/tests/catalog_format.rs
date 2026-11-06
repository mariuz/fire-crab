//! The format-time skeleton pages against `PAG_format_header` /
//! `PAG_format_pip` (pag.cpp:773-880) and the fresh engine file's static
//! bytes: a bare 2182 `CREATE DATABASE ... PAGE_SIZE 8192`, dumped
//! 2026-11-06. Generations, GUID, creation stamp, counters and the
//! `pages_page` anchor vary by construction phase and are masked; every
//! other byte is pinned.

use fire_crab_ods::catalog_format::{
    create_system_storage, descriptors_for, FIRST_PIP_PAGE, FIRST_SCN_PAGE, FORMAT_DB_IMPL,
    FORMAT_FLAGS, format_header_page, format_pip_page, format_scn_page, format_skeleton,
    read_pages_rows,
};
use fire_crab_ods::catalog_init::SYS_RELATIONS;
use fire_crab_ods::header::{HeaderPage, HDR_DATA_OFFSET};
use fire_crab_ods::pages::PageType;
use fire_crab_ods::pip::PipPage;
use fire_crab_ods::{page_at, Image};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

#[test]
fn header_static_bytes_match_pag_format_header() {
    // every byte 0..160 of a format-time header (guid AB.., fresh
    // file's creation stamp), except the generation (4..8), which the
    // engine's own creations vary
    let h = format_header_page(8192, &[0xABu8; 16], (61318, 450070090));
    assert_eq!(h.len(), 8192);
    let mut want = unhex(
        "01000000000000000000000000000000\
         00200e80000012000000000000000000\
         00000000940000000000000000000000\
         01000000000000000000000000000000\
         00000000000000000000000000000000\
         01010100abababababababababababab\
         abababab86ef00004a86d31a00000000\
         00000000000000000000000000000000\
         00000000000000000000000000000000\
         00000000000000000000000000000000",
    );
    want[4..8].copy_from_slice(&[0, 0, 0, 0]);
    assert_eq!(h[..160], want[..]);
    assert!(h[160..].iter().all(|b| *b == 0));
    // the static ranges equal the fresh 2182 file's
    assert_eq!(&h[16..24], &[0x00, 0x20, 0x0e, 0x80, 0x00, 0x00, 0x12, 0x00]);
    assert_eq!(&h[80..84], &FORMAT_DB_IMPL);
    assert_eq!(FORMAT_FLAGS, 0x12);
}

#[test]
fn header_decodes_and_names_its_fields() {
    let h = format_header_page(16384, &[0xCDu8; 16], (0, 0));
    let d = HeaderPage::decode(&h).unwrap();
    assert_eq!(d.pag.page_type, PageType::Header as u8);
    assert_eq!(d.page_size, 16384);
    assert_eq!(d.ods_version_raw, 0x800e);
    assert_eq!(d.ods_minor, 0);
    assert_eq!(d.flags, 0x12);
    assert_eq!(d.oldest_transaction, 1);
    assert_eq!(d.next_transaction, 0);
    assert_eq!(d.oldest_active, 0);
    assert_eq!(d.oldest_snapshot, 0);
    assert_eq!(d.next_attachment_id, 0);
    assert_eq!(d.pages_page, 0);
    assert_eq!(d.page_buffers, 0);
    assert_eq!(d.db_impl, [1, 1, 1, 0]);
    assert_eq!(d.guid, [0xCDu8; 16]);
    assert_eq!(d.creation_date, (0, 0));
    assert_eq!(d.shadow_count, 0);
    assert_eq!(HDR_DATA_OFFSET, 148);
    assert_eq!(h[148], 0); // HDR_end
}

#[test]
fn pip_marks_header_pip_scn_used() {
    assert_eq!((FIRST_PIP_PAGE, FIRST_SCN_PAGE), (1, 2));
    let p = format_pip_page(8192);
    assert_eq!(p.len(), 8192);
    let d = PipPage::decode(&p).unwrap();
    assert_eq!(d.min, 3);
    assert_eq!(d.used, 3);
    assert_eq!(p[0], PageType::PageInventory as u8);
    assert_eq!(&p[16..28], &[3, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0]);
    assert_eq!(p[28], 0xF8); // bits 0, 1, 2 clear
    assert!(p[29..].iter().all(|b| *b == 0xFF));
    assert_eq!(d.is_free(0), Some(false));
    assert_eq!(d.is_free(2), Some(false));
    assert_eq!(d.is_free(3), Some(true));
}

#[test]
fn scn_page_is_type_and_zeros() {
    let s = format_scn_page(32768);
    assert_eq!(s.len(), 32768);
    assert_eq!(s[0], PageType::ScnInventory as u8);
    assert!(s[1..].iter().all(|b| *b == 0));
}

#[test]
fn skeleton_is_three_pages_for_every_size() {
    for ps in [8192usize, 16384, 32768] {
        let f = format_skeleton(ps, &[0u8; 16], (1, 1));
        assert_eq!(f.len(), 3 * ps);
        assert_eq!(f[0], PageType::Header as u8);
        assert_eq!(f[ps], PageType::PageInventory as u8);
        assert_eq!(f[2 * ps], PageType::ScnInventory as u8);
    }
}

#[test]
fn pages_descriptors_follow_the_offset_walk() {
    let pages = SYS_RELATIONS.iter().find(|r| r.id == 0).unwrap();
    let descs = descriptors_for(pages);
    assert_eq!(descs.len(), 4);
    let offs: Vec<u32> = descs.iter().map(|d| d.offset).collect();
    assert_eq!(offs, [4, 8, 12, 16]); // LONG, SHORT, LONG, SHORT, 4-aligned
    let end = descs.iter().map(|d| d.offset + d.length as u32).max().unwrap();
    assert_eq!(end, 18); // the template's raw image length
}

#[test]
fn ported_tables_reproduce_the_bootstrap_offsets() {
    // the differential-tested pins sysfmt asserts for RDB$RELATION_FIELDS,
    // recomputed from the ported tables instead of the compiled-in Def
    let rfr = SYS_RELATIONS.iter().find(|r| r.id == 5).unwrap();
    let descs = descriptors_for(rfr);
    assert_eq!(descs[0].offset, 4); // RDB$FIELD_NAME
    assert_eq!(descs[1].offset, 256); // RDB$RELATION_NAME
    assert_eq!(descs[6].offset, 1394); // RDB$FIELD_POSITION
    assert_eq!(descs[9].offset, 1410); // RDB$FIELD_ID
}

#[test]
fn system_storage_matches_the_fresh_file() {
    // the 40 persistent relations, in relfields order: 0..32 then
    // 42, 45, 47, 51, 52, 56, 59 (MON$/SEC$ are virtual, storage-less)
    let persistent: Vec<u16> = SYS_RELATIONS.iter().filter(|r| r.persistent).map(|r| r.id).collect();
    assert_eq!(persistent.len(), 40);
    assert_eq!(&persistent[..33], (0..=32).collect::<Vec<_>>().as_slice());
    assert_eq!(&persistent[33..], [42, 45, 47, 51, 52, 56, 59]);
    let bytes = format_skeleton(8192, &[7u8; 16], (61318, 450070090));
    let mut file = Image::from_bytes(&bytes, 8192);
    create_system_storage(&mut file, 8192).unwrap();
    // the header anchors relation 0's pointer page
    let hdr = HeaderPage::decode(page_at(&file, 8192, 0).unwrap()).unwrap();
    assert_eq!(hdr.pages_page, 3);
    // all 80 rows, in creation order, page numbers included
    let rows = read_pages_rows(&file, 8192);
    assert_eq!(rows.len(), 80);
    let mut want = Vec::new();
    for (i, rel) in persistent.iter().enumerate() {
        let ptr = 3 + (i as i64) * 2 + if i == 0 { 0 } else { 1 };
        want.push((*rel as i64, 4, ptr, 0));
        want.push((*rel as i64, 6, ptr + 1, 0));
    }
    assert_eq!(rows, want);
    // the page-type sequence is the fresh file's prefix: data page 5
    // holds the rows, everything else pointer/root in pairs
    let ty = |p: u32| page_at(&file, 8192, p).unwrap()[0];
    assert_eq!(file.byte_len(), 84 * 8192);
    assert_eq!((ty(0), ty(1), ty(2)), (1, 2, 10));
    assert_eq!(ty(5), PageType::Data as u8);
    for p in [3u32, 4] {
        assert_eq!(ty(p), if p % 2 == 1 { 4 } else { 6 }, "page {p}");
    }
    for p in 6..84u32 {
        assert_eq!(ty(p), if p % 2 == 0 { 4 } else { 6 }, "page {p}");
    }
}
