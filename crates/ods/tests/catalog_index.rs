//! Slice 5 against the fresh 2182 file: index definitions, root
//! registration, tree contents and the skeleton completion (TIP and
//! generator pages, header counters). Oracle: `/tmp/s4probe.fdb` and
//! two pristine creates, read 2026-11-10; root entries and TIP bytes
//! scanned straight off those files.

use fire_crab_ods::btr::{find_index_root, lookup_key, walk_index_leaves};
use fire_crab_ods::btw::index_segments;
use fire_crab_ods::catalog_format::{create_system_storage, descriptors_for, format_skeleton};
use fire_crab_ods::catalog_index::{maintain_row, store_system_indexes};
use fire_crab_ods::catalog_index_def::SYS_INDICES;
use fire_crab_ods::catalog_init::SYS_RELATIONS;
use fire_crab_ods::catalog_rows::{encode_image, read_all_rows, store_core_catalog, Cell};
use fire_crab_ods::data::DataPage;
use fire_crab_ods::dml::insert_record_system;
use fire_crab_ods::format::{decode_record, max_recs_per_dp, Value};
use fire_crab_ods::{page_at, Image};

const PS: usize = 8192;

fn fresh_indexed() -> Image {
    let bytes = format_skeleton(PS, &[7u8; 16], (61318, 450070090));
    let mut file = Image::from_bytes(&bytes, PS);
    create_system_storage(&mut file, PS).unwrap();
    store_core_catalog(&mut file, PS, "SYSDBA").unwrap();
    store_system_indexes(&mut file, PS).unwrap();
    file
}

fn col(rel_id: u16, name: &str) -> usize {
    SYS_RELATIONS
        .iter()
        .find(|r| r.id == rel_id)
        .unwrap()
        .fields
        .iter()
        .position(|f| f.name == name)
        .unwrap()
}

fn text(v: &Value) -> Option<&str> {
    match v {
        Value::Text(s) => Some(s.trim_end()),
        Value::Null => None,
        v => panic!("expected text, got {v:?}"),
    }
}

fn int(v: &Value) -> Option<i64> {
    match v {
        Value::Int(n) => Some(*n),
        Value::Null => None,
        v => panic!("expected int, got {v:?}"),
    }
}

#[test]
fn definitions_match_fresh_file() {
    let file = fresh_indexed();
    let indices = read_all_rows(&file, PS, 4);
    let segments = read_all_rows(&file, PS, 3);
    let constraints = read_all_rows(&file, PS, 22);
    assert_eq!(indices.len(), 100, "RDB$INDICES");
    assert_eq!(segments.len(), 177, "RDB$INDEX_SEGMENTS");
    assert_eq!(constraints.len(), 32, "RDB$RELATION_CONSTRAINTS");

    let (i_name, i_rel, i_id, i_uniq, i_count, i_type, i_inactive, i_stats, i_desc, i_fmt) = (
        col(4, "RDB$INDEX_NAME"),
        col(4, "RDB$RELATION_NAME"),
        col(4, "RDB$INDEX_ID"),
        col(4, "RDB$UNIQUE_FLAG"),
        col(4, "RDB$SEGMENT_COUNT"),
        col(4, "RDB$INDEX_TYPE"),
        col(4, "RDB$INDEX_INACTIVE"),
        col(4, "RDB$STATISTICS"),
        col(4, "RDB$DESCRIPTION"),
        col(4, "RDB$FORMAT"),
    );
    let by_name = |name: &str| indices.iter().find(|r| text(&r[i_name]) == Some(name)).unwrap();
    // per-relation INDEX_IDs run 1.. in idx.h order
    assert_eq!(int(&by_name("RDB$INDEX_0")[i_id]), Some(1));
    assert_eq!(int(&by_name("RDB$INDEX_1")[i_id]), Some(2));
    assert_eq!(int(&by_name("RDB$INDEX_59")[i_id]), Some(3));
    assert_eq!(text(&by_name("RDB$INDEX_59")[i_rel]), Some("RDB$RELATIONS"));
    assert_eq!(int(&by_name("RDB$INDEX_59")[i_uniq]), Some(1));
    assert_eq!(int(&by_name("RDB$INDEX_59")[i_count]), Some(3));
    assert_eq!(int(&by_name("RDB$INDEX_59")[i_type]), None);
    // the descending unique index
    assert_eq!(int(&by_name("RDB$INDEX_44")[i_uniq]), Some(1));
    assert_eq!(int(&by_name("RDB$INDEX_44")[i_count]), Some(2));
    assert_eq!(int(&by_name("RDB$INDEX_44")[i_type]), Some(1));
    for row in &indices {
        assert_eq!(int(&row[i_inactive]), Some(0));
        assert_eq!(int(&row[i_stats]), None, "statistics stay NULL");
        assert_eq!(text(&row[i_desc]), None);
        assert_eq!(int(&row[i_fmt]), None);
    }

    // INDEX_84 lists 3 segments, stores 2 - the engine's count wins
    let (s_idx, s_pos, s_field) =
        (col(3, "RDB$INDEX_NAME"), col(3, "RDB$FIELD_POSITION"), col(3, "RDB$FIELD_NAME"));
    let segs84: Vec<_> = segments.iter().filter(|r| text(&r[s_idx]) == Some("RDB$INDEX_84")).collect();
    assert_eq!(segs84.len(), 2);
    assert_eq!(text(&segs84[0][s_field]), Some("RDB$RELATION_SCHEMA_NAME"));
    assert_eq!(int(&segs84[0][s_pos]), Some(0));
    assert_eq!(text(&segs84[1][s_field]), Some("RDB$PACKAGE_NAME"));
    assert_eq!(int(&segs84[1][s_pos]), Some(1));
    let segs59: Vec<_> = segments.iter().filter(|r| text(&r[s_idx]) == Some("RDB$INDEX_59")).collect();
    assert_eq!(segs59.len(), 3);
    assert_eq!(text(&segs59[2][s_field]), Some("RDB$RELATION_NAME"));

    let (c_name, c_type, c_idx, c_rel, c_defer, c_init) = (
        col(22, "RDB$CONSTRAINT_NAME"),
        col(22, "RDB$CONSTRAINT_TYPE"),
        col(22, "RDB$INDEX_NAME"),
        col(22, "RDB$RELATION_NAME"),
        col(22, "RDB$DEFERRABLE"),
        col(22, "RDB$INITIALLY_DEFERRED"),
    );
    for row in &constraints {
        assert_eq!(text(&row[c_type]), Some("UNIQUE"));
        assert_eq!(text(&row[c_name]), text(&row[c_idx]));
        assert_eq!(text(&row[c_defer]), Some("NO"));
        assert_eq!(text(&row[c_init]), Some("NO"));
    }
    let c59 = constraints.iter().find(|r| text(&r[c_name]) == Some("RDB$INDEX_59")).unwrap();
    assert_eq!(text(&c59[c_rel]), Some("RDB$RELATIONS"));
}

#[test]
fn roots_carry_table_itypes() {
    // (field, itype) pairs and flags scanned off the engine file's
    // own roots - the port's positions against engine truth.
    let file = fresh_indexed();
    let check = |rel: u16, slot: u8, count: usize, flags: u16, segs: &[(u16, u16)]| {
        let (got_segs, got_flags) = index_segments(&file, PS, rel, slot, count).unwrap();
        assert_eq!(got_flags, flags, "rel {rel} slot {slot} flags");
        assert_eq!(got_segs, segs, "rel {rel} slot {slot} segments");
        let e = find_index_root(&file, PS, rel).unwrap().entry(slot).unwrap();
        assert_ne!(e.root_page, 0, "rel {rel} slot {slot} has a root");
        assert_eq!(e.key_count as usize, count);
    };
    check(6, 0, 1, 0, &[(8, 4)]);
    check(6, 1, 1, 0, &[(3, 0)]);
    check(6, 2, 3, 1, &[(18, 4), (19, 4), (8, 4)]);
    check(19, 0, 1, 1, &[(0, 0)]); // int64 keyed idx_numeric, forced
    check(32, 0, 2, 3, &[(2, 0), (0, 0)]);
    check(32, 1, 1, 1, &[(3, 1)]);
    check(32, 2, 1, 2, &[(1, 12)]);
    check(4, 0, 1, 0, &[(0, 4)]);
    check(4, 3, 3, 1, &[(15, 4), (18, 4), (0, 4)]);
    check(4, 5, 2, 0, &[(16, 4), (8, 4)]);
    check(18, 0, 1, 0, &[(4, 4)]);
    check(18, 3, 2, 0, &[(9, 4), (0, 4)]);
    // every index registered exactly once per relation
    for idx in SYS_INDICES {
        let rel = SYS_RELATIONS.iter().find(|r| r.name == idx.relation).unwrap().id;
        let ordinal = SYS_INDICES[..idx.id as usize].iter().filter(|i| i.relation == idx.relation).count();
        assert!(find_index_root(&file, PS, rel).unwrap().entry(ordinal as u8).is_some());
    }
}

#[test]
fn trees_key_current_rows() {
    let file = fresh_indexed();
    // every tree holds exactly its relation's rows - no partial or
    // expression indices in the system catalog. (A duplicate under a
    // unique index would already have failed the build, as the
    // engine's does.)
    for idx in SYS_INDICES {
        let rel = SYS_RELATIONS.iter().find(|r| r.name == idx.relation).unwrap().id;
        let ordinal = SYS_INDICES[..idx.id as usize].iter().filter(|i| i.relation == idx.relation).count();
        let entries = walk_index_leaves(&file, PS, rel, ordinal as u8).unwrap();
        let rows = read_all_rows(&file, PS, rel).len();
        assert_eq!(entries.len(), rows, "RDB$INDEX_{} entries", idx.id);
    }
    // spot lookups through the reader
    let hit = lookup_key(&file, PS, 6, 0, b"RDB$DATABASE", false).unwrap();
    assert_eq!(hit.len(), 1);
    let hit = lookup_key(&file, PS, 9, 0, b"SQL$1", false).unwrap();
    assert_eq!(hit.len(), 1);
    let hit = lookup_key(&file, PS, 20, 0, b"RDB$PROCEDURES", false).unwrap();
    assert_eq!(hit.len(), 1);
    // NULL-key byte fidelity is the engine's to judge (gfix -v -full
    // over the flipped file, slice 7); here the roundtrip proves the
    // tree and the reader agree. INDEX_59's middle segment is NULL on
    // every system relation.
    let rows = read_all_rows(&file, PS, 6);
    let c_name = col(6, "RDB$RELATION_NAME");
    let row = rows.iter().find(|r| text(&r[c_name]) == Some("RDB$DATABASE")).unwrap();
    let c_schema = col(6, "RDB$SCHEMA_NAME");
    let c_pkg = col(6, "RDB$PACKAGE_NAME");
    let key = fire_crab_ods::btw::build_index_key(
        &[
            fire_crab_ods::btw::KeySeg { itype: 4, value: &row[c_schema], scale: 0, charset: 4 },
            fire_crab_ods::btw::KeySeg { itype: 4, value: &row[c_pkg], scale: 0, charset: 4 },
            fire_crab_ods::btw::KeySeg { itype: 4, value: &row[c_name], scale: 0, charset: 4 },
        ],
        false,
    )
    .unwrap()
    .0;
    let hit = lookup_key(&file, PS, 6, 2, &key, false).unwrap();
    assert_eq!(hit.len(), 1);
}

#[test]
fn skeleton_pages_and_counters() {
    let file = fresh_indexed();
    // the TIP page: transactions 1..4 committed, rest virgin
    let mut tip_no = None;
    let mut gen_no = None;
    for (pno, page) in file.pages().enumerate() {
        if page[0] == 3 {
            tip_no = Some(pno as u32);
            assert_eq!(u32::from_le_bytes(page[16..20].try_into().unwrap()), 0, "tip_next");
            assert_eq!(page[20], 0xfc);
            assert_eq!(page[21], 0x03);
            assert!(page[22..28].iter().all(|&b| b == 0));
        }
        if page[0] == 9 {
            gen_no = Some(pno as u32);
            assert_eq!(u32::from_le_bytes(page[16..20].try_into().unwrap()), 0, "gpg_sequence");
        }
    }
    let (tip_no, gen_no) = (tip_no.unwrap(), gen_no.unwrap());
    assert_eq!(fire_crab_ods::gen::read(&file, PS, 13), 128);
    for id in [0, 1, 2, 3, 10, 12] {
        assert_eq!(fire_crab_ods::gen::read(&file, PS, id), 0, "gen {id} waits for slice 6");
    }
    // RDB$PAGES ends with the gen row then the TIP row
    let pages = read_all_rows(&file, PS, 0);
    assert_eq!(pages.len(), 82);
    let (c_page, c_rel, c_seq, c_type) =
        (col(0, "RDB$PAGE_NUMBER"), col(0, "RDB$RELATION_ID"), col(0, "RDB$PAGE_SEQUENCE"), col(0, "RDB$PAGE_TYPE"));
    assert_eq!(int(&pages[80][c_type]), Some(9));
    assert_eq!(int(&pages[80][c_page]), Some(gen_no as i64));
    assert_eq!(int(&pages[81][c_type]), Some(3));
    assert_eq!(int(&pages[81][c_page]), Some(tip_no as i64));
    for row in &pages[80..] {
        assert_eq!(int(&row[c_rel]), Some(0));
        assert_eq!(int(&row[c_seq]), Some(0));
    }
    // create-time counters (ods.h:747-749); next attachment is 1 -
    // this path never attaches.
    let header = page_at(&file, PS, 0).unwrap();
    let u64at = |at: usize| u64::from_le_bytes(header[at..at + 8].try_into().unwrap());
    assert_eq!(u64at(40), 4);
    assert_eq!(u64at(48), 2);
    assert_eq!(u64at(56), 3);
    assert_eq!(u64at(64), 3);
    assert_eq!(u64at(72), 1);
}

#[test]
fn maintain_row_keys_new_rows() {
    // slice 6's half, proven early on a scratch row: store, maintain,
    // find through the reader.
    let mut file = fresh_indexed();
    let rel = SYS_RELATIONS.iter().find(|r| r.id == 11).unwrap();
    let descs = descriptors_for(rel);
    let image = encode_image(
        &descs,
        &[
            (col(11, "RDB$FIELD_NAME"), Cell::Text("RDB$SCRATCH")),
            (col(11, "RDB$TYPE_NAME"), Cell::Text("SCRATCH_TYPE")),
            (col(11, "RDB$TYPE"), Cell::Int(1)),
            (col(11, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
        ],
    );
    let outcome = insert_record_system(&mut file, PS, 11, 0, &image).unwrap();
    let dp = DataPage::decode(page_at(&file, PS, outcome.page_no).unwrap()).unwrap();
    let recno = dp.sequence as u64 * max_recs_per_dp(PS) + outcome.slot as u64;
    let values = decode_record(&image, &descs);
    maintain_row(&mut file, PS, 11, recno, &values, &descs).unwrap();
    let hit = lookup_key(&file, PS, 11, 0, b"SCRATCH_TYPE", false).unwrap();
    assert_eq!(hit, vec![(b"SCRATCH_TYPE".to_vec(), recno)]);
}

#[test]
fn skeleton_pages_stamp_pageno_and_tip_chain_reads() {
    // slice 7 caught the skeleton zeroing pageno@12 on its PIP, TIP
    // and generator pages: the engine tolerates it, but fire-crab's
    // own TIP walk (and every DDL through it) reads page_no@12.
    let file = fresh_indexed();
    let n = file.byte_len() / PS;
    for no in 0..n as u32 {
        let page = page_at(&file, PS, no).unwrap();
        let pageno = u32::from_le_bytes([page[12], page[13], page[14], page[15]]);
        assert_eq!(pageno, no, "page {no} stamps pageno@12");
    }
    let chain = fire_crab_ods::tra::TipChain::read(&file, PS).expect("TIP chain reads");
    assert_eq!(chain.page_count(), 1);
}
