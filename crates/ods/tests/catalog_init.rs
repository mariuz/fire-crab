//! The generated skeleton tables against the reference template's RDB$
//! rows: every (id, name, field count) and the global fields' shapes.
//! Oracle: `crates/ods/templates/empty-8192.fdb.z` (made by 6.0.0.2196),
//! read with the 2182 isql on 2026-11-06.

use fire_crab_ods::catalog_init::{SYS_FIELDS, SYS_RELATIONS};

#[test]
fn table_counts_match_the_template() {
    assert_eq!(SYS_RELATIONS.len(), 60, "RDB$RELATIONS rows");
    let fields: usize = SYS_RELATIONS.iter().map(|r| r.fields.len()).sum();
    assert_eq!(fields, 598, "RDB$RELATION_FIELDS rows");
    assert_eq!(SYS_FIELDS.len(), 187, "RDB$FIELDS rows");
}

#[test]
fn relation_ids_and_names_in_file_order() {
    let want = [
        (0, "RDB$PAGES"),
        (1, "RDB$DATABASE"),
        (2, "RDB$FIELDS"),
        (3, "RDB$INDEX_SEGMENTS"),
        (4, "RDB$INDICES"),
        (5, "RDB$RELATION_FIELDS"),
        (6, "RDB$RELATIONS"),
        (7, "RDB$VIEW_RELATIONS"),
        (8, "RDB$FORMATS"),
        (9, "RDB$SECURITY_CLASSES"),
        (10, "RDB$FILES"),
        (11, "RDB$TYPES"),
        (12, "RDB$TRIGGERS"),
        (13, "RDB$DEPENDENCIES"),
        (14, "RDB$FUNCTIONS"),
        (15, "RDB$FUNCTION_ARGUMENTS"),
        (16, "RDB$FILTERS"),
        (17, "RDB$TRIGGER_MESSAGES"),
        (18, "RDB$USER_PRIVILEGES"),
        (19, "RDB$TRANSACTIONS"),
        (20, "RDB$GENERATORS"),
        (21, "RDB$FIELD_DIMENSIONS"),
        (22, "RDB$RELATION_CONSTRAINTS"),
        (23, "RDB$REF_CONSTRAINTS"),
        (24, "RDB$CHECK_CONSTRAINTS"),
        (25, "RDB$LOG_FILES"),
        (26, "RDB$PROCEDURES"),
        (27, "RDB$PROCEDURE_PARAMETERS"),
        (28, "RDB$CHARACTER_SETS"),
        (29, "RDB$COLLATIONS"),
        (30, "RDB$EXCEPTIONS"),
        (31, "RDB$ROLES"),
        (32, "RDB$BACKUP_HISTORY"),
        (33, "MON$DATABASE"),
        (34, "MON$ATTACHMENTS"),
        (35, "MON$TRANSACTIONS"),
        (36, "MON$STATEMENTS"),
        (37, "MON$CALL_STACK"),
        (38, "MON$IO_STATS"),
        (39, "MON$RECORD_STATS"),
        (40, "MON$CONTEXT_VARIABLES"),
        (41, "MON$MEMORY_USAGE"),
        (42, "RDB$PACKAGES"),
        (43, "SEC$USERS"),
        (44, "SEC$USER_ATTRIBUTES"),
        (45, "RDB$AUTH_MAPPING"),
        (46, "SEC$GLOBAL_AUTH_MAPPING"),
        (47, "RDB$DB_CREATORS"),
        (48, "SEC$DB_CREATORS"),
        (49, "MON$TABLE_STATS"),
        (50, "RDB$TIME_ZONES"),
        (51, "RDB$PUBLICATIONS"),
        (52, "RDB$PUBLICATION_TABLES"),
        (53, "RDB$CONFIG"),
        (54, "RDB$KEYWORDS"),
        (55, "MON$COMPILED_STATEMENTS"),
        (56, "RDB$SCHEMAS"),
        (57, "MON$LOCAL_TEMPORARY_TABLES"),
        (58, "MON$LOCAL_TEMPORARY_TABLE_COLUMNS"),
        (59, "RDB$CONSTANTS"),
    ];
    assert_eq!(SYS_RELATIONS.len(), want.len());
    for (r, w) in SYS_RELATIONS.iter().zip(want) {
        assert_eq!((r.id, r.name), w);
    }
}

#[test]
fn per_relation_field_counts() {
    let want = [
        ("RDB$PAGES", 4),
        ("RDB$DATABASE", 7),
        ("RDB$FIELDS", 31),
        ("RDB$INDEX_SEGMENTS", 6),
        ("RDB$INDICES", 19),
        ("RDB$RELATION_FIELDS", 24),
        ("RDB$RELATIONS", 21),
        ("RDB$VIEW_RELATIONS", 8),
        ("RDB$FORMATS", 3),
        ("RDB$SECURITY_CLASSES", 3),
        ("RDB$FILES", 6),
        ("RDB$TYPES", 5),
        ("RDB$TRIGGERS", 16),
        ("RDB$DEPENDENCIES", 8),
        ("RDB$FUNCTIONS", 23),
        ("RDB$FUNCTION_ARGUMENTS", 25),
        ("RDB$FILTERS", 9),
        ("RDB$TRIGGER_MESSAGES", 4),
        ("RDB$USER_PRIVILEGES", 10),
        ("RDB$TRANSACTIONS", 4),
        ("RDB$GENERATORS", 9),
        ("RDB$FIELD_DIMENSIONS", 5),
        ("RDB$RELATION_CONSTRAINTS", 7),
        ("RDB$REF_CONSTRAINTS", 7),
        ("RDB$CHECK_CONSTRAINTS", 3),
        ("RDB$LOG_FILES", 6),
        ("RDB$PROCEDURES", 20),
        ("RDB$PROCEDURE_PARAMETERS", 18),
        ("RDB$CHARACTER_SETS", 13),
        ("RDB$COLLATIONS", 12),
        ("RDB$EXCEPTIONS", 8),
        ("RDB$ROLES", 6),
        ("RDB$BACKUP_HISTORY", 6),
        ("MON$DATABASE", 28),
        ("MON$ATTACHMENTS", 29),
        ("MON$TRANSACTIONS", 14),
        ("MON$STATEMENTS", 11),
        ("MON$CALL_STACK", 12),
        ("MON$IO_STATS", 6),
        ("MON$RECORD_STATS", 17),
        ("MON$CONTEXT_VARIABLES", 4),
        ("MON$MEMORY_USAGE", 6),
        ("RDB$PACKAGES", 11),
        ("SEC$USERS", 8),
        ("SEC$USER_ATTRIBUTES", 4),
        ("RDB$AUTH_MAPPING", 10),
        ("SEC$GLOBAL_AUTH_MAPPING", 9),
        ("RDB$DB_CREATORS", 2),
        ("SEC$DB_CREATORS", 2),
        ("MON$TABLE_STATS", 7),
        ("RDB$TIME_ZONES", 2),
        ("RDB$PUBLICATIONS", 5),
        ("RDB$PUBLICATION_TABLES", 3),
        ("RDB$CONFIG", 6),
        ("RDB$KEYWORDS", 2),
        ("MON$COMPILED_STATEMENTS", 8),
        ("RDB$SCHEMAS", 8),
        ("MON$LOCAL_TEMPORARY_TABLES", 5),
        ("MON$LOCAL_TEMPORARY_TABLE_COLUMNS", 14),
        ("RDB$CONSTANTS", 9),
    ];
    assert_eq!(SYS_RELATIONS.len(), want.len());
    for (r, w) in SYS_RELATIONS.iter().zip(want) {
        assert_eq!((r.name, r.fields.len()), w, "{}", r.name);
    }
}

#[test]
fn global_field_shapes_and_sums() {
    let len: u32 = SYS_FIELDS.iter().map(|f| u32::from(f.length)).sum();
    assert_eq!(len, 118184, "SUM(RDB$FIELD_LENGTH)");
    let sub: i32 = SYS_FIELDS.iter().map(|f| i32::from(f.sub_type)).sum();
    assert_eq!(sub, 207, "SUM(RDB$FIELD_SUB_TYPE)");
    // (name, dtype, length, sub_type, nullable); dtypes are dsc_pub.h
    // numbers (text=1, short=8, blob=17)
    for (name, dt, ln, st, nl) in [
        ("RDB$FIELD_NAME", 1, 252, 3, true),
        ("RDB$CHARACTER_SET_NAME", 1, 252, 3, true),
        ("RDB$DESCRIPTION", 17, 8, 1, true),
        ("RDB$FIELD_PRECISION", 8, 2, 0, true),
        ("RDB$SYSTEM_FLAG", 8, 2, 0, false),
    ] {
        let f = SYS_FIELDS.iter().find(|f| f.name == name).unwrap();
        assert_eq!((f.dtype, f.length, f.sub_type, f.nullable), (dt, ln, st, nl), "{name}");
    }
    // the four globals carrying a default BLR (dflt.h)
    let mut with_default: Vec<_> =
        SYS_FIELDS.iter().filter(|f| f.default.is_some()).map(|f| f.name).collect();
    with_default.sort_unstable();
    assert_eq!(with_default, ["RDB$DEFERRABLE", "RDB$MATCH_OPTION", "RDB$RULE", "RDB$SYSTEM_PRIVILEGES"]);
    // spot bytes: 'NO' in ASCII, blr_version5 .. blr_eoc
    let f = SYS_FIELDS.iter().find(|f| f.name == "RDB$DEFERRABLE").unwrap();
    assert_eq!(f.default.unwrap(), &[5, 21, 15, 2, 0, 2, 0, b'N', b'O', 76]);
}

#[test]
fn every_relation_field_resolves_its_global() {
    for r in SYS_RELATIONS {
        for f in r.fields {
            assert!(
                SYS_FIELDS.iter().any(|g| g.key == f.global),
                "{} references unknown global {}",
                r.name,
                f.global
            );
        }
    }
}
