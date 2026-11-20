//! Slice 4 against a live fresh database: the core catalog rows this
//! code stores, decoded back and compared with what 6.0.0.2182 stores
//! for the same create (`/tmp/s4probe.fdb`, read 2026-11-10; the ACL
//! and blob-header bytes scanned straight off that file).

use fire_crab_ods::catalog_format::{create_system_storage, descriptors_for, format_skeleton};
use fire_crab_ods::catalog_init::SYS_RELATIONS;
use fire_crab_ods::catalog_rows::{
    ddl_acl, encode_image, nonrelation_acl, read_all_rows, relation_acl, schema_acl,
    store_core_catalog, Cell, SecurityAlloc, SYS_GENERATORS,
};
use fire_crab_ods::data::DataPage;
use fire_crab_ods::format::{max_recs_per_dp, read_blob_content, Value};
use fire_crab_ods::pointer::relation_data_pages;
use fire_crab_ods::{page_at, Image};

const PS: usize = 8192;

fn fresh_core() -> Image {
    let bytes = format_skeleton(PS, &[7u8; 16], (61318, 450070090));
    let mut file = Image::from_bytes(&bytes, PS);
    create_system_storage(&mut file, PS).unwrap();
    store_core_catalog(&mut file, PS, "SYSDBA").unwrap();
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
    // decode hands back the engine-wire CHAR, blank-padded to its
    // declared width; SQL comparison ignores the padding, so do we
    // (the encoder's own padding is pinned separately below).
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

fn blob(v: &Value) -> Option<(u16, u64)> {
    match v {
        Value::Blob(rel, num) => Some((*rel, *num)),
        Value::Null => None,
        v => panic!("expected blob, got {v:?}"),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The raw slot bytes (the blh) behind a blob id, for subtype/charset
/// checks - the payload readers never show the header.
fn blob_slot(file: &Image, relation: u16, recno: u64) -> Vec<u8> {
    let recs = max_recs_per_dp(PS);
    let dp_no = relation_data_pages(file, PS, relation)[(recno / recs) as usize];
    let dp = DataPage::decode(page_at(file, PS, dp_no).unwrap()).unwrap();
    dp.slot_bytes((recno % recs) as u16).unwrap().to_vec()
}

#[test]
fn encode_image_pads_and_nulls() {
    let rel = SYS_RELATIONS.iter().find(|r| r.id == 1).unwrap();
    let descs = descriptors_for(rel);
    let (c_id, c_cs, c_desc) =
        (col(1, "RDB$RELATION_ID"), col(1, "RDB$CHARACTER_SET_NAME"), col(1, "RDB$DESCRIPTION"));
    let image = encode_image(
        &descs,
        &[(c_id, Cell::Int(0)), (c_cs, Cell::Text("NONE")), (c_desc, Cell::BlobId(9, 0x1_0000_0007))],
    );
    // every other field NULL, the three set
    for i in 0..descs.len() {
        let set = image[i / 8] & (1 << (i % 8)) != 0;
        assert_eq!(set, i != c_id && i != c_cs && i != c_desc, "null bit {i}");
    }
    // the CHAR is blank-padded to its full 252 bytes, no NULs
    let at = descs[c_cs].offset as usize;
    assert_eq!(&image[at..at + 4], b"NONE");
    assert!(image[at + 4..at + 252].iter().all(|&b| b == b' '));
    // the bid: u16 rel, reserved, number_up, u32 number
    let at = descs[c_desc].offset as usize;
    assert_eq!(&image[at..at + 8], &[9, 0, 0, 1, 7, 0, 0, 0]);
}

#[test]
fn acl_builders_match_engine_bytes() {
    // Raw blob payloads scanned off the fresh 2182 file.
    assert_eq!(
        hex(&relation_acl("SYSDBA")),
        "0201030653595344424100020106030407090800010002040000"
    );
    assert_eq!(
        hex(&nonrelation_acl("SYSDBA", false)),
        "0201030653595344424100020106030c000100020c0000"
    );
    assert_eq!(
        hex(&nonrelation_acl("SYSDBA", true)),
        "0201030653595344424100020106030b0c000100020b0c0000"
    );
    assert_eq!(hex(&ddl_acl("SYSDBA")), "0201030653595344424100020106030000");
    // GRANT_privileges order: alter, control, drop, usage.
    assert_eq!(
        hex(&schema_acl("SYSDBA")),
        "0201030653595344424100020601030c000100020c0000"
    );
}

#[test]
fn core_row_counts() {
    let file = fresh_core();
    let n = |rel| read_all_rows(&file, PS, rel).len();
    assert_eq!(n(6), 60, "RDB$RELATIONS");
    assert_eq!(n(5), 598, "RDB$RELATION_FIELDS");
    assert_eq!(n(2), 187, "RDB$FIELDS");
    assert_eq!(n(1), 1, "RDB$DATABASE");
    assert_eq!(n(56), 2, "RDB$SCHEMAS");
    assert_eq!(n(20), 13, "RDB$GENERATORS");
    assert_eq!(n(9), 322, "RDB$SECURITY_CLASSES");
    assert_eq!(n(18), 764, "RDB$USER_PRIVILEGES");
}

#[test]
fn relations_carry_class_pairs_and_format_zero() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 6);
    let (c_id, c_schema, c_name, c_type, c_owner, c_sec, c_dflt, c_fid, c_fmt, c_flag, c_dbkey, c_desc) =
        (
            col(6, "RDB$RELATION_ID"),
            col(6, "RDB$SCHEMA_NAME"),
            col(6, "RDB$RELATION_NAME"),
            col(6, "RDB$RELATION_TYPE"),
            col(6, "RDB$OWNER_NAME"),
            col(6, "RDB$SECURITY_CLASS"),
            col(6, "RDB$DEFAULT_CLASS"),
            col(6, "RDB$FIELD_ID"),
            col(6, "RDB$FORMAT"),
            col(6, "RDB$SYSTEM_FLAG"),
            col(6, "RDB$DBKEY_LENGTH"),
            col(6, "RDB$DESCRIPTION"),
        );
    assert_eq!(rows.len(), 60);
    for (i, row) in rows.iter().enumerate() {
        let n = i + 1;
        assert_eq!(text(&row[c_sec]), Some(format!("SQL${n}").as_str()));
        assert_eq!(text(&row[c_dflt]), Some(format!("SQL$DEFAULT{n}").as_str()));
        assert_eq!(int(&row[c_fmt]), Some(0), "FORMAT of {}", text(&row[c_name]).unwrap());
        assert_eq!(text(&row[c_schema]), Some("SYSTEM"));
        assert_eq!(text(&row[c_owner]), Some("SYSDBA"));
        assert_eq!(int(&row[c_flag]), Some(1));
        assert_eq!(int(&row[c_dbkey]), Some(8));
        assert_eq!(text(&row[c_desc]), None);
    }
    // spot rows off the oracle, in id order
    assert_eq!(int(&rows[0][c_id]), Some(0));
    assert_eq!(text(&rows[0][c_name]), Some("RDB$PAGES"));
    assert_eq!(int(&rows[0][c_fid]), Some(4));
    assert_eq!(int(&rows[1][c_fid]), Some(7));
    assert_eq!(int(&rows[5][c_fid]), Some(24));
    assert_eq!(int(&rows[59][c_fid]), Some(9));
    assert_eq!(int(&rows[33][c_type]), Some(3), "MON$DATABASE is virtual");
    assert_eq!(int(&rows[0][c_type]), Some(0), "RDB$PAGES is persistent");
}

#[test]
fn database_relation_fields_exact() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 5);
    let (c_rel, c_name, c_src, c_pos, c_id, c_flag, c_update) = (
        col(5, "RDB$RELATION_NAME"),
        col(5, "RDB$FIELD_NAME"),
        col(5, "RDB$FIELD_SOURCE"),
        col(5, "RDB$FIELD_POSITION"),
        col(5, "RDB$FIELD_ID"),
        col(5, "RDB$SYSTEM_FLAG"),
        col(5, "RDB$UPDATE_FLAG"),
    );
    let db: Vec<_> = rows.iter().filter(|r| text(&r[c_rel]) == Some("RDB$DATABASE")).collect();
    let want = [
        ("RDB$DESCRIPTION", "RDB$DESCRIPTION", 1),
        ("RDB$RELATION_ID", "RDB$RELATION_ID", 0),
        ("RDB$SECURITY_CLASS", "RDB$SECURITY_CLASS", 1),
        ("RDB$CHARACTER_SET_NAME", "RDB$CHARACTER_SET_NAME", 1),
        ("RDB$LINGER", "RDB$LINGER", 1),
        ("RDB$SQL_SECURITY", "RDB$SQL_SECURITY", 1),
        ("RDB$CHARACTER_SET_SCHEMA_NAME", "RDB$SCHEMA_NAME", 1),
    ];
    assert_eq!(db.len(), want.len());
    for (i, row) in db.iter().enumerate() {
        assert_eq!(text(&row[c_name]), Some(want[i].0));
        assert_eq!(text(&row[c_src]), Some(want[i].1));
        assert_eq!(int(&row[c_pos]), Some(i as i64));
        assert_eq!(int(&row[c_id]), Some(i as i64));
        assert_eq!(int(&row[c_update]), Some(want[i].2));
        assert_eq!(int(&row[c_flag]), Some(1));
    }
}

#[test]
fn fields_sample_exact() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 2);
    let (c_name, c_type, c_len, c_scale, c_sub, c_cs, c_coll, c_charlen, c_seg, c_null, c_sec, c_owner, c_dflt) =
        (
            col(2, "RDB$FIELD_NAME"),
            col(2, "RDB$FIELD_TYPE"),
            col(2, "RDB$FIELD_LENGTH"),
            col(2, "RDB$FIELD_SCALE"),
            col(2, "RDB$FIELD_SUB_TYPE"),
            col(2, "RDB$CHARACTER_SET_ID"),
            col(2, "RDB$COLLATION_ID"),
            col(2, "RDB$CHARACTER_LENGTH"),
            col(2, "RDB$SEGMENT_LENGTH"),
            col(2, "RDB$NULL_FLAG"),
            col(2, "RDB$SECURITY_CLASS"),
            col(2, "RDB$OWNER_NAME"),
            col(2, "RDB$DEFAULT_VALUE"),
        );
    let by_name = |name: &str| rows.iter().find(|r| text(&r[c_name]) == Some(name)).unwrap();
    for row in &rows {
        assert_eq!(text(&row[c_owner]), Some("SYSDBA"));
        assert_eq!(int(&row[c_scale]), Some(0));
    }
    let f = by_name("RDB$FIELD_NAME");
    assert_eq!(
        (int(&f[c_type]), int(&f[c_len]), int(&f[c_sub]), int(&f[c_cs]), int(&f[c_coll])),
        (Some(14), Some(252), Some(3), Some(4), Some(0))
    );
    assert_eq!((int(&f[c_charlen]), int(&f[c_seg]), int(&f[c_null])), (Some(63), None, Some(0)));
    assert_eq!(text(&f[c_sec]), Some("SQL$66"));
    let f = by_name("RDB$DESCRIPTION");
    assert_eq!(
        (int(&f[c_type]), int(&f[c_sub]), int(&f[c_cs]), int(&f[c_seg])),
        (Some(261), Some(1), Some(4), Some(80))
    );
    assert_eq!(text(&f[c_sec]), Some("SQL$63"));
    let f = by_name("RDB$DEFERRABLE");
    assert_eq!(
        (int(&f[c_type]), int(&f[c_len]), int(&f[c_sub]), int(&f[c_cs]), int(&f[c_coll])),
        (Some(14), Some(3), None, Some(0), Some(0))
    );
    // the BLR default, byte for byte off the fresh file
    let (rel, num) = blob(&f[c_dflt]).unwrap();
    assert_eq!(read_blob_content(&file, PS, rel, num).unwrap(), vec![5, 21, 15, 2, 0, 2, 0, 78, 79, 76]);
    let slot = blob_slot(&file, rel, num);
    assert_eq!(u16::from_le_bytes([slot[24], slot[25]]), 2, "default subtype");
    assert_eq!(slot[26], 1, "default charset");
    let f = by_name("RDB$REMOTE_PROTOCOL");
    assert_eq!(
        (int(&f[c_type]), int(&f[c_sub]), int(&f[c_cs]), int(&f[c_coll])),
        (Some(37), Some(2), Some(2), Some(0))
    );
    let f = by_name("RDB$FIELD_PRECISION");
    assert_eq!(int(&f[c_type]), Some(7));
    assert_eq!(int(&f[c_sub]), None);
    assert_eq!(text(&f[c_sec]), Some("SQL$150"));
    let f = by_name("RDB$MATCH_OPTION");
    let (rel, num) = blob(&f[c_dflt]).unwrap();
    assert_eq!(read_blob_content(&file, PS, rel, num).unwrap().len(), 12);
    assert_eq!(by_name("RDB$BOOLEAN").get(c_type).map(int), Some(Some(23)));
    assert_eq!(by_name("RDB$TIMESTAMP_TZ").get(c_type).map(int), Some(Some(29)));
}

#[test]
fn generators_exact() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 20);
    let (c_name, c_id, c_flag, c_owner, c_sec, c_init, c_incr, c_desc) = (
        col(20, "RDB$GENERATOR_NAME"),
        col(20, "RDB$GENERATOR_ID"),
        col(20, "RDB$SYSTEM_FLAG"),
        col(20, "RDB$OWNER_NAME"),
        col(20, "RDB$SECURITY_CLASS"),
        col(20, "RDB$INITIAL_VALUE"),
        col(20, "RDB$GENERATOR_INCREMENT"),
        col(20, "RDB$DESCRIPTION"),
    );
    assert_eq!(rows.len(), SYS_GENERATORS.len());
    for (i, row) in rows.iter().enumerate() {
        let (name, id, description) = SYS_GENERATORS[i];
        assert_eq!(text(&row[c_name]), Some(name));
        assert_eq!(int(&row[c_id]), Some(id as i64));
        assert_eq!(int(&row[c_flag]), Some(1));
        assert_eq!(text(&row[c_owner]), Some("SYSDBA"));
        assert_eq!(text(&row[c_sec]), Some(format!("SQL${}", 451 + i).as_str()));
        assert_eq!(int(&row[c_init]), Some(0));
        assert_eq!(int(&row[c_incr]), Some(0));
        match description {
            Some(want) => {
                let (rel, num) = blob(&row[c_desc]).unwrap();
                assert_eq!(read_blob_content(&file, PS, rel, num).unwrap(), want.as_bytes());
                let slot = blob_slot(&file, rel, num);
                assert_eq!(u16::from_le_bytes([slot[24], slot[25]]), 1, "description subtype");
                assert_eq!(slot[26], 4, "description charset");
            }
            None => assert_eq!(blob(&row[c_desc]), None),
        }
    }
}

#[test]
fn schemas_and_database_exact() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 56);
    let (c_name, c_owner, c_flag, c_sec, c_cs_schema, c_cs) = (
        col(56, "RDB$SCHEMA_NAME"),
        col(56, "RDB$OWNER_NAME"),
        col(56, "RDB$SYSTEM_FLAG"),
        col(56, "RDB$SECURITY_CLASS"),
        col(56, "RDB$CHARACTER_SET_SCHEMA_NAME"),
        col(56, "RDB$CHARACTER_SET_NAME"),
    );
    assert_eq!(rows.len(), 2);
    assert_eq!(text(&rows[0][c_name]), Some("SYSTEM"));
    assert_eq!(int(&rows[0][c_flag]), Some(1));
    assert_eq!(text(&rows[0][c_sec]), Some("SQL$248"));
    assert_eq!(text(&rows[0][c_cs_schema]), Some("SYSTEM"));
    assert_eq!(text(&rows[0][c_cs]), Some("UTF8"));
    assert_eq!(text(&rows[1][c_name]), Some("PUBLIC"));
    assert_eq!(int(&rows[1][c_flag]), Some(0));
    assert_eq!(text(&rows[1][c_sec]), Some("SQL$249"));
    assert_eq!(text(&rows[1][c_cs]), None);
    for row in &rows {
        assert_eq!(text(&row[c_owner]), Some("SYSDBA"));
    }

    let rows = read_all_rows(&file, PS, 1);
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert_eq!(int(&row[col(1, "RDB$RELATION_ID")]), Some(0));
    assert_eq!(text(&row[col(1, "RDB$CHARACTER_SET_NAME")]), Some("NONE"));
    assert_eq!(text(&row[col(1, "RDB$CHARACTER_SET_SCHEMA_NAME")]), Some("SYSTEM"));
    assert_eq!(text(&row[col(1, "RDB$SECURITY_CLASS")]), Some("SQL$DATABASE"));
    assert_eq!(text(&row[col(1, "RDB$DESCRIPTION")]), None);
}

#[test]
fn privilege_shapes() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 18);
    let (c_user, c_schema, c_obj, c_field, c_priv, c_grant, c_utype, c_otype, c_grantor) = (
        col(18, "RDB$USER"),
        col(18, "RDB$RELATION_SCHEMA_NAME"),
        col(18, "RDB$RELATION_NAME"),
        col(18, "RDB$FIELD_NAME"),
        col(18, "RDB$PRIVILEGE"),
        col(18, "RDB$GRANT_OPTION"),
        col(18, "RDB$USER_TYPE"),
        col(18, "RDB$OBJECT_TYPE"),
        col(18, "RDB$GRANTOR"),
    );
    let of = |obj: &str, otype: i64| {
        rows.iter()
            .filter(|r| text(&r[c_obj]) == Some(obj) && int(&r[c_otype]) == Some(otype))
            .collect::<Vec<_>>()
    };
    // the relation grants: owner S/I/U/D/R with grant, PUBLIC S
    let db = of("RDB$DATABASE", 0);
    assert_eq!(db.len(), 6);
    for row in &db {
        assert_eq!(text(&row[c_schema]), Some("SYSTEM"));
        assert_eq!(text(&row[c_field]), None);
        assert_eq!(int(&row[c_utype]), Some(8));
        assert_eq!(text(&row[c_grantor]), None);
        match text(&row[c_user]) {
            Some("SYSDBA") => {
                assert_eq!(int(&row[c_grant]), Some(1));
                assert!(["S", "I", "U", "D", "R"].contains(&text(&row[c_priv]).unwrap()));
            }
            Some("PUBLIC") => {
                assert_eq!(int(&row[c_grant]), Some(0));
                assert_eq!(text(&row[c_priv]), Some("S"));
            }
            u => panic!("unexpected grantee {u:?}"),
        }
    }
    // the field grants: owner G with grant, PUBLIC G
    let f = of("RDB$FIELD_NAME", 9);
    assert_eq!(f.len(), 2);
    for row in &f {
        assert_eq!(text(&row[c_schema]), Some("SYSTEM"));
        assert_eq!(text(&row[c_priv]), Some("G"));
        assert_eq!(text(&row[c_grantor]), None);
    }
    // the schema grants: NULL schema name, grant option 0 throughout,
    // the PUBLIC ones naming the owner as grantor
    let s = of("SYSTEM", 38);
    assert_eq!(s.len(), 2);
    for row in &s {
        assert_eq!(text(&row[c_schema]), None);
        assert_eq!(int(&row[c_grant]), Some(0));
        assert_eq!(text(&row[c_grantor]), None);
    }
    let p = of("PUBLIC", 38);
    assert_eq!(p.len(), 2);
    for row in &p {
        assert_eq!(text(&row[c_grantor]), Some("SYSDBA"));
        assert_eq!(int(&row[c_grant]), Some(0));
    }
    // the generator grants
    let g = of("RDB$PROCEDURES", 14);
    assert_eq!(g.len(), 2);
    for row in &g {
        assert_eq!(text(&row[c_schema]), Some("SYSTEM"));
        assert_eq!(text(&row[c_priv]), Some("G"));
    }
}

#[test]
fn class_numbering_and_acl_bytes() {
    let file = fresh_core();
    let rows = read_all_rows(&file, PS, 9);
    let (c_name, c_acl) = (col(9, "RDB$SECURITY_CLASS"), col(9, "RDB$ACL"));
    let names: Vec<&str> = rows.iter().map(|r| text(&r[c_name]).unwrap()).collect();
    let mut want: Vec<String> = (1..=60).map(|n| format!("SQL${n}")).collect();
    want.extend((1..=60).map(|n| format!("SQL$DEFAULT{n}")));
    want.extend((61..=249).map(|n| format!("SQL${n}")));
    want.extend((451..=463).map(|n| format!("SQL${n}")));
    assert_eq!(names.len(), want.len());
    for w in &want {
        assert!(names.contains(&w.as_str()), "missing class {w}");
    }
    let acl_of = |name: &str| {
        let row = rows.iter().find(|r| text(&r[c_name]) == Some(name)).unwrap();
        let (rel, num) = blob(&row[c_acl]).unwrap();
        let payload = read_blob_content(&file, PS, rel, num).unwrap();
        let slot = blob_slot(&file, rel, num);
        assert_eq!(u16::from_le_bytes([slot[24], slot[25]]), 3, "{name} subtype");
        assert_eq!(slot[26], 1, "{name} charset");
        payload
    };
    assert_eq!(acl_of("SQL$1"), relation_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$DEFAULT1"), relation_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$61"), nonrelation_acl("SYSDBA", false));
    assert_eq!(acl_of("SQL$248"), schema_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$451"), nonrelation_acl("SYSDBA", false));
}

#[test]
fn allocator_pairs_and_reserves() {
    let mut alloc = SecurityAlloc::new();
    assert_eq!(alloc.next_sec(), "SQL$1");
    assert_eq!(alloc.next_default(), "SQL$DEFAULT1");
    assert_eq!(alloc.next_sec(), "SQL$2");
    alloc.reserve_sec(201);
    assert_eq!(alloc.next_sec(), "SQL$204");
}
