//! Slice 7: the assembled database holds the whole catalog at
//! every served page size. Per-slice byte pins live in the slice
//! tests; this file pins the assembly (counts, classes, generators).

use fire_crab_ods::catalog_assemble::assemble_fresh_database;
use fire_crab_ods::catalog_init::SYS_RELATIONS;
use fire_crab_ods::catalog_rows::read_all_rows;
use fire_crab_ods::format::Value;
use fire_crab_ods::Image;

fn check_one(page_size: usize) {
    let bytes =
        assemble_fresh_database(page_size, &[7u8; 16], (61318, 450070090), "SYSDBA").unwrap();
    let file = Image::from_bytes(&bytes, page_size);
    let count = |id: u16| read_all_rows(&file, page_size, id).len();
    for (id, want) in [
        (6, 60),   // relations
        (2, 187),  // fields
        (5, 598),  // relation fields
        (4, 100),  // indices
        (11, 298), // types
        (28, 52),  // character sets
        (29, 149), // collations
        (42, 4),   // packages
        (26, 12),  // procedures
        (27, 36),  // procedure params
        (14, 7),   // functions
        (15, 21),  // function args
        (59, 3),   // constants
        (51, 1),   // publications
        (31, 1),   // roles
        (18, 1243), // privileges (SYSDBA owner: one role grant)
        (9, 554),  // security classes
        (12, 0),   // formats: fresh files carry none
    ] {
        assert_eq!(count(id), want, "rel {id} at {page_size}");
    }
    // classes continuous, generators at their end values
    let rel = SYS_RELATIONS.iter().find(|r| r.id == 9).unwrap();
    let c = rel.fields.iter().position(|f| f.name == "RDB$SECURITY_CLASS").unwrap();
    let names: Vec<String> = read_all_rows(&file, page_size, 9)
        .iter()
        .map(|r| match &r[c] {
            Value::Text(s) => s.trim().to_string(),
            v => panic!("class name decodes text, got {v:?}"),
        })
        .collect();
    for n in 1..=468u32 {
        assert!(names.contains(&format!("SQL${n}")), "SQL${n} at {page_size}");
    }
    for (id, want) in [(0, 13), (1, 468), (2, 60), (3, 12), (10, 7), (12, 4), (13, 128)] {
        assert_eq!(fire_crab_ods::gen::read(&file, page_size, id), want, "gen {id} at {page_size}");
    }
}

#[test]
fn assembly_holds_at_8192() {
    check_one(8192);
}

#[test]
fn assembly_holds_at_16384() {
    check_one(16384);
}

#[test]
fn assembly_holds_at_32768() {
    check_one(32768);
}

#[test]
fn system_patch_runs_on_the_assembly() {
    // the op_create DEFAULT CHARACTER SET step (`patch_system_row`
    // on RDB$DATABASE): it failed "no TIP" before the skeleton
    // stamped pageno@12 on its TIP page.
    let bytes =
        assemble_fresh_database(8192, &[7u8; 16], (61318, 450070090), "SYSDBA").unwrap();
    let mut file = Image::from_bytes(&bytes, 8192);
    let rel = fire_crab_ods::resolve_relation(&file, 8192, "RDB$DATABASE").unwrap();
    fire_crab_ods::ddl::patch_system_row(
        &mut file,
        8192,
        "RDB$DATABASE",
        rel,
        |_| true,
        &[("RDB$CHARACTER_SET_NAME", fire_crab_ods::ddl::SysValue::Text("UTF8"))],
    )
    .unwrap();
    let rows = read_all_rows(&file, 8192, 1);
    assert_eq!(rows.len(), 1);
    let pos = SYS_RELATIONS
        .iter()
        .find(|r| r.id == 1)
        .unwrap()
        .fields
        .iter()
        .position(|f| f.name == "RDB$CHARACTER_SET_NAME")
        .unwrap();
    match &rows[0][pos] {
        Value::Text(s) => assert_eq!(s.trim_end(), "UTF8"),
        v => panic!("charset patched to text, got {v:?}"),
    }
}
