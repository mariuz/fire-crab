//! Slice 4: the core catalog rows `INI_format` stores - relations,
//! relation fields, global fields, the database row, schemas and
//! generators - with their security classes and privilege rows
//! (ini.epp:705-842, 912-916). Later slices add indices (5), the
//! remaining rows (6) and formats + validation (7).
//!
//! Every value below is pinned twice: against the engine source that
//! computes it and against a live fresh database (6.0.0.2182,
//! `/tmp/s4probe.fdb`, read 2026-11-10). Where the two disagreed the
//! file won and the source reading is noted; where they agree only
//! one citation is given.
//!
//! Two deliberate folds keep this slice self-contained:
//!
//! - `RDB$DATABASE.RDB$SECURITY_CLASS` is written as `SQL$DATABASE`
//!   now, although the engine only patches it in later, when
//!   `DdlSecurity::store` runs (ini.epp:604-611). The value is a
//!   constant (`DATABASE_CLASS`), nothing reads the row between, and
//!   the end state is identical; slice 6 does not rewrite it.
//! - the generator classes are `SQL$451..463`, past the 201 intl
//!   classes (250..450) slice 6 has not replayed yet. The gap is a
//!   named constant the oracle confirms (`INTL_CLASSES_RESERVED`);
//!   slice 6 replaces the jump with the replayed consumption and
//!   asserts it equals 201.
//!
//! A third fold arrived with slice 6: the three relation classes
//! (plus default classes) the additional system-privilege grants
//! recompute via `GRANT_privileges` are written final here - the
//! recompute's page is full by the time slice 6 runs, so no rewrite
//! could land them.

use crate::catalog_format::descriptors_for;
use crate::catalog_init::{SysRelation, SYS_FIELDS, SYS_RELATIONS};
use crate::dml;
use crate::format::{decode_record, dtype, Descriptor, Value};
use crate::Image;

/// One non-NULL record cell. NULLs are the absence of a cell: the
/// encoder starts with every null bit set, as an engine `STORE`
/// leaves unassigned fields NULL.
pub enum Cell<'a> {
    Int(i64),
    /// blank-padded `CHAR`: the engine stores no NULs even where the
    /// source `strcpy`s or pokes `[1] = 0` (probed: every text byte
    /// past the value is 0x20 on a fresh 2182 file).
    Text(&'a str),
    Varying(&'a str),
    /// raw bytes for a fixed CHAR the value fills exactly: the
    /// owner's `0xff` system-privilege mask is not valid UTF-8, so it
    /// cannot ride `Text` (slice 6).
    Raw(&'a [u8]),
    /// a blob id: (relation, record number).
    BlobId(u16, u64),
}

/// A record image from cells: null bitmap all set, then each value
/// at its descriptor's offset - the `encode_int_image` walk grown to
/// text, varying and blob ids, which is all slice 4 stores.
pub fn encode_image(descs: &[Descriptor], cells: &[(usize, Cell)]) -> Vec<u8> {
    let len = descs.iter().map(|d| d.offset as usize + d.length as usize).max().unwrap_or(0);
    let mut image = vec![0u8; len.max(crate::format::flag_bytes(descs.len()))];
    for i in 0..descs.len() {
        image[i / 8] |= 1 << (i % 8);
    }
    for (fid, cell) in cells {
        let d = &descs[*fid];
        match cell {
            Cell::Int(v) => {
                let bytes = v.to_le_bytes();
                let n = d.length as usize;
                assert!(n == 1 || n == 2 || n == 4 || n == 8, "non-integer width {n}");
                image[d.offset as usize..d.offset as usize + n].copy_from_slice(&bytes[..n]);
            }
            Cell::Text(s) => {
                assert_eq!(d.dtype, dtype::TEXT, "text cell on dtype {}", d.dtype);
                let bytes = s.as_bytes();
                let n = d.length as usize;
                assert!(bytes.len() <= n, "{s} overflows CHAR({n})");
                image[d.offset as usize..d.offset as usize + bytes.len()].copy_from_slice(bytes);
                for b in &mut image[d.offset as usize + bytes.len()..d.offset as usize + n] {
                    *b = b' ';
                }
            }
            Cell::Varying(s) => {
                assert_eq!(d.dtype, dtype::VARYING, "varying cell on dtype {}", d.dtype);
                let bytes = s.as_bytes();
                let n = d.length as usize;
                assert!(bytes.len() + 2 <= n, "{s} overflows VARCHAR({})", n - 2);
                image[d.offset as usize..d.offset as usize + 2]
                    .copy_from_slice(&(bytes.len() as u16).to_le_bytes());
                image[d.offset as usize + 2..d.offset as usize + 2 + bytes.len()]
                    .copy_from_slice(bytes);
            }
            Cell::Raw(raw) => {
                assert_eq!(d.dtype, dtype::TEXT, "raw cell on dtype {}", d.dtype);
                let n = d.length as usize;
                assert_eq!(raw.len(), n, "raw cell fills CHAR({n}) exactly");
                image[d.offset as usize..d.offset as usize + n].copy_from_slice(raw);
            }
            Cell::BlobId(rel, num) => {
                // bid (RecordNumber.h:63-71, little-endian branch): u16
                // relation, u8 reserved, u8 number_up, u32 number.
                assert_eq!(d.length, 8, "blob id on width {}", d.length);
                let at = d.offset as usize;
                image[at..at + 2].copy_from_slice(&rel.to_le_bytes());
                image[at + 2] = 0;
                image[at + 3] = (num >> 32) as u8;
                image[at + 4..at + 8].copy_from_slice(&(*num as u32).to_le_bytes());
            }
        }
        image[fid / 8] &= !(1 << (fid % 8));
    }
    image
}

// ---------------------------------------------------------------------------
// Security-class ACLs (acl.h codes, ini.epp:150-330 shapes)
// ---------------------------------------------------------------------------

pub(crate) const ACL_VERSION: u8 = 2;
pub(crate) const ACL_END: u8 = 0;
pub(crate) const ACL_ID_LIST: u8 = 1;
pub(crate) const ACL_PRIV_LIST: u8 = 2;
pub(crate) const ID_PERSON: u8 = 3;
/// `id_privilege` (acl.h:77): the id-list a `GRANT_privileges`
/// recomputation writes for a system-privilege grantee (slice 6).
pub(crate) const ID_PRIVILEGE: u8 = 15;
pub(crate) const PRIV_CONTROL: u8 = 1;
pub(crate) const PRIV_DROP: u8 = 3;
pub(crate) const PRIV_SELECT: u8 = 4;
pub(crate) const PRIV_ALTER: u8 = 6;
pub(crate) const PRIV_INSERT: u8 = 7;
pub(crate) const PRIV_DELETE: u8 = 8;
pub(crate) const PRIV_UPDATE: u8 = 9;
/// `priv_references` (acl.h:49): the recomputed relation ACLs carry
/// it, the constructor ones do not (slice 6).
pub(crate) const PRIV_REFERENCES: u8 = 10;
pub(crate) const PRIV_EXECUTE: u8 = 11;
pub(crate) const PRIV_USAGE: u8 = 12;

pub(crate) fn acl_head(out: &mut Vec<u8>, owner: &str) {
    out.push(ACL_VERSION);
    out.push(ACL_ID_LIST);
    out.push(ID_PERSON);
    out.push(owner.len() as u8);
    out.extend_from_slice(owner.as_bytes());
    out.push(ACL_END);
}

/// The relation ACL (`RelationSecurity`, ini.epp:223-263): owner
/// control/alter/drop/select/insert/update/delete, PUBLIC select.
/// 26 bytes for SYSDBA on the fresh file.
pub fn relation_acl(owner: &str) -> Vec<u8> {
    let mut acl = Vec::new();
    acl_head(&mut acl, owner);
    acl.extend_from_slice(&[
        ACL_PRIV_LIST,
        PRIV_CONTROL,
        PRIV_ALTER,
        PRIV_DROP,
        PRIV_SELECT,
        PRIV_INSERT,
        PRIV_UPDATE,
        PRIV_DELETE,
        ACL_END,
    ]);
    acl.push(ACL_ID_LIST);
    acl.push(ACL_END);
    acl.extend_from_slice(&[ACL_PRIV_LIST, PRIV_SELECT, ACL_END]);
    acl.push(ACL_END); // the walk_acl() terminator ini.epp keeps
    acl
}

/// The non-relation ACL (`NonRelationSecurity`, ini.epp:323-365):
/// owner control/alter/drop/[execute]/usage, PUBLIC [execute]/usage.
/// 23 bytes (25 packaged) for SYSDBA on the fresh file.
pub fn nonrelation_acl(owner: &str, package: bool) -> Vec<u8> {
    let mut owner_privs = vec![PRIV_CONTROL, PRIV_ALTER, PRIV_DROP, PRIV_USAGE];
    let mut public_privs = vec![PRIV_USAGE];
    if package {
        // ini.epp inserts at count - 2, counting its priv_list/end
        // sentinels: execute lands after drop / before usage.
        owner_privs.insert(3, PRIV_EXECUTE);
        public_privs.insert(0, PRIV_EXECUTE);
    }
    let mut acl = Vec::new();
    acl_head(&mut acl, owner);
    acl.push(ACL_PRIV_LIST);
    acl.extend_from_slice(&owner_privs);
    acl.push(ACL_END);
    acl.push(ACL_ID_LIST);
    acl.push(ACL_END);
    acl.push(ACL_PRIV_LIST);
    acl.extend_from_slice(&public_privs);
    acl.push(ACL_END);
    acl.push(ACL_END);
    acl
}

/// The DDL ACL (`DdlSecurity`, ini.epp:536-562): owner
/// control/alter/drop, no PUBLIC section. 17 bytes for SYSDBA.
pub fn ddl_acl(owner: &str) -> Vec<u8> {
    let mut acl = Vec::new();
    acl_head(&mut acl, owner);
    acl.extend_from_slice(&[ACL_PRIV_LIST, PRIV_CONTROL, PRIV_ALTER, PRIV_DROP, ACL_END]);
    acl.push(ACL_END);
    acl
}

/// The schema ACL as `GRANT_privileges` rebuilds it (grant.epp:89+):
/// `grant_user` moves owner control/drop/alter/usage through
/// `SCL_move_priv`'s `p_names` order (alter, control, drop, usage -
/// scl.epp:94-108), then the PUBLIC usage wildcard; the single
/// `ACL_end` (no walk terminator: `finish_security_class` adds one).
/// 23 bytes for SYSDBA, byte-pinned off the fresh file.
pub fn schema_acl(owner: &str) -> Vec<u8> {
    let mut acl = Vec::new();
    acl.push(ACL_VERSION);
    acl.push(ACL_ID_LIST);
    acl.push(ID_PERSON);
    acl.push(owner.len() as u8);
    acl.extend_from_slice(owner.as_bytes());
    // SCL_move_priv: end, priv_list, privs in p_names order, 0.
    acl.extend_from_slice(&[
        ACL_END,
        ACL_PRIV_LIST,
        PRIV_ALTER,
        PRIV_CONTROL,
        PRIV_DROP,
        PRIV_USAGE,
        ACL_END,
    ]);
    acl.extend_from_slice(&[ACL_ID_LIST, ACL_END, ACL_PRIV_LIST, PRIV_USAGE, ACL_END]);
    acl.push(ACL_END);
    acl
}

/// The admin role's class ACL: owner-only control/alter/drop/usage
/// (`RoleSecurity`, ini.epp:443-475). No PUBLIC section: role
/// membership rides privilege rows, not the class. 18 bytes for
/// SYSDBA. Stored by slice 6.
pub fn role_acl(owner: &str) -> Vec<u8> {
    let mut acl = Vec::new();
    acl_head(&mut acl, owner);
    acl.extend_from_slice(&[ACL_PRIV_LIST, PRIV_CONTROL, PRIV_ALTER, PRIV_DROP, PRIV_USAGE, ACL_END]);
    acl.push(ACL_END);
    acl
}

/// A relation's class ACL after `GRANT_privileges` recomputes it for
/// a system-privilege grant (grant.epp:89+): the owner id-list with
/// the full relation mask, the privilege id-list (`id_privilege`,
/// acl.h:77) with S/I/U/D/R, and the PUBLIC id-list with select -
/// every priv-list in `SCL_move_priv`'s `p_names` order
/// (scl.epp:94-108), which is why the owner's privs run
/// alter/control/drop/insert/update/delete/select/references here
/// and not in constructor order. Like `schema_acl`, written final
/// where the class is stored: the recompute's page is full by the
/// time slice 6 runs, so no rewrite could land it.
pub fn grant_relation_acl(owner: &str, priv_user: &str) -> Vec<u8> {
    let mut acl = Vec::new();
    acl_head(&mut acl, owner);
    acl.extend_from_slice(&[
        ACL_PRIV_LIST,
        PRIV_ALTER,
        PRIV_CONTROL,
        PRIV_DROP,
        PRIV_INSERT,
        PRIV_UPDATE,
        PRIV_DELETE,
        PRIV_SELECT,
        PRIV_REFERENCES,
        ACL_END,
    ]);
    acl.push(ACL_ID_LIST);
    acl.push(ID_PRIVILEGE);
    acl.push(priv_user.len() as u8);
    acl.extend_from_slice(priv_user.as_bytes());
    acl.push(ACL_END);
    acl.extend_from_slice(&[
        ACL_PRIV_LIST,
        PRIV_INSERT,
        PRIV_UPDATE,
        PRIV_DELETE,
        PRIV_SELECT,
        PRIV_REFERENCES,
        ACL_END,
    ]);
    acl.push(ACL_ID_LIST);
    acl.push(ACL_END);
    acl.extend_from_slice(&[ACL_PRIV_LIST, PRIV_SELECT, ACL_END]);
    acl.push(ACL_END);
    acl
}

// ---------------------------------------------------------------------------
// The class-number allocator
// ---------------------------------------------------------------------------

/// The `RDB$SECURITY_CLASS` (1) / `SQL$DEFAULT` (2) generator
/// counters as `INI_format` consumes them: relations take `SQL$n`
/// and `SQL$DEFAULT$n` in lockstep, everything else takes `SQL$n`
/// only (ini.epp:266-277, 370-379).
pub struct SecurityAlloc {
    sec: u32,
    dflt: u32,
}

impl SecurityAlloc {
    pub fn new() -> Self {
        SecurityAlloc { sec: 0, dflt: 0 }
    }

    /// `storeSecurityClass`: `SQL$` + next `RDB$SECURITY_CLASS` value.
    pub fn next_sec(&mut self) -> String {
        self.sec += 1;
        format!("SQL${}", self.sec)
    }

    /// The relation default class: `SQL$DEFAULT` + next value.
    pub fn next_default(&mut self) -> String {
        self.dflt += 1;
        format!("SQL$DEFAULT{}", self.dflt)
    }

    /// The `RDB$SECURITY_CLASS` counter's current value - slice 6
    /// asserts its pipeline position and generator end value off it.
    pub fn sec_current(&self) -> u32 {
        self.sec
    }

    /// The `SQL$DEFAULT` counter's current value (slice 6's
    /// generator end value).
    pub fn dflt_current(&self) -> u32 {
        self.dflt
    }

    /// Skip numbers a later slice's replay consumes. Slice 4 uses it
    /// once, for the intl range; slice 6 replays the range with
    /// explicit numbers and asserts the replayed count equals the
    /// reservation.
    pub fn reserve_sec(&mut self, n: u32) {
        self.sec += n;
    }
}

impl Default for SecurityAlloc {
    fn default() -> Self {
        Self::new()
    }
}

/// The `SQL$250..450` classes `store_intlnames` consumes between the
/// schemas (248/249) and the generators (451..463): 201 classes on
/// the fresh file (401 twenty-three-byte standard ACLs minus the 187
/// fields minus the 13 generators). Slice 6 replays the consumption
/// and asserts this number.
pub const INTL_CLASSES_RESERVED: u32 = 201;

// ---------------------------------------------------------------------------
// The system generators (trig.h:74-87, constants.h:156-158)
// ---------------------------------------------------------------------------

/// (name, id, description): `RDB$GENERATORS` rows in table order.
pub const SYS_GENERATORS: &[(&str, u16, Option<&str>)] = &[
    ("RDB$SECURITY_CLASS", 1, None),
    ("SQL$DEFAULT", 2, None),
    ("RDB$PROCEDURES", 3, Some("Procedure ID")),
    ("RDB$EXCEPTIONS", 4, Some("Exception ID")),
    ("RDB$CONSTRAINT_NAME", 5, Some("Implicit constraint name")),
    ("RDB$FIELD_NAME", 6, Some("Implicit domain name")),
    ("RDB$INDEX_NAME", 7, Some("Implicit index name")),
    ("RDB$TRIGGER_NAME", 8, Some("Implicit trigger name")),
    ("RDB$BACKUP_HISTORY", 9, Some("Nbackup technology")),
    ("RDB$FUNCTIONS", 10, Some("Function ID")),
    ("RDB$GENERATOR_NAME", 11, Some("Implicit generator name")),
    ("RDB$PACKAGES", 12, Some("Package ID")),
    ("RDB$RELATIONS", 13, Some("Relation ID")),
];

// ---------------------------------------------------------------------------
// Row writers
// ---------------------------------------------------------------------------

fn rel_by_id(id: u16) -> &'static SysRelation {
    SYS_RELATIONS.iter().find(|r| r.id == id).unwrap_or_else(|| panic!("no ported relation {id}"))
}

pub(crate) fn rel_by_name(name: &str) -> &'static SysRelation {
    SYS_RELATIONS.iter().find(|r| r.name == name).unwrap_or_else(|| panic!("no ported relation {name}"))
}

fn col(rel: &SysRelation, name: &str) -> usize {
    rel.fields.iter().position(|f| f.name == name).unwrap_or_else(|| panic!("{} has no {name}", rel.name))
}

/// A column position by relation id and field name, for the sibling
/// catalog writers (slices 5+).
pub(crate) fn rel_col(rel_id: u16, name: &str) -> usize {
    col(rel_by_id(rel_id), name)
}

fn global_name(key: &str) -> &'static str {
    SYS_FIELDS.iter().find(|g| g.key == key).unwrap_or_else(|| panic!("unknown global {key}")).name
}

/// Every decoded row of a system relation, in file order - the tests'
/// oracle window.
pub fn read_all_rows(file: &Image, page_size: usize, rel_id: u16) -> Vec<Vec<Value>> {
    use crate::data::DataPage;
    use crate::pointer::relation_data_pages;
    let rel = rel_by_id(rel_id);
    let descs = descriptors_for(rel);
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, rel_id) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, None) else {
                continue;
            };
            out.push(decode_record(&image, &descs));
        }
    }
    out
}

/// One `RDB$SECURITY_CLASSES` row: name + ACL blob. ACL blobs carry
/// subtype 3 (`RDB$ACL`'s column subtype) and charset 1, probed byte
/// for byte off the fresh file.
fn store_class(file: &mut Image, page_size: usize, name: &str, acl: &[u8]) -> Result<(), String> {
    let num = dml::insert_blob(file, page_size, 9, &[acl.to_vec()], 3)?;
    let rel = rel_by_id(9);
    let image = encode_image(
        &descriptors_for(rel),
        &[
            (col(rel, "RDB$SECURITY_CLASS"), Cell::Text(name)),
            (col(rel, "RDB$ACL"), Cell::BlobId(9, num)),
        ],
    );
    dml::insert_record_system(file, page_size, 9, 0, &image)?;
    Ok(())
}

pub(crate) struct Priv<'a> {
    pub(crate) user: &'a str,
    pub(crate) schema: Option<&'a str>,
    pub(crate) object: &'a str,
    pub(crate) priv_c: &'a str,
    pub(crate) grant: i64,
    pub(crate) user_type: i64,
    pub(crate) obj_type: i64,
    pub(crate) grantor: Option<&'a str>,
    /// `RDB$FIELD_NAME`: `None` everywhere except slice 6's role
    /// membership grants, which flag the default role with `D`.
    pub(crate) field: Option<&'a str>,
}

/// The cells of one `RDB$USER_PRIVILEGES` row, shared by the
/// slice-4 writer and slice 6's maintaining writer.
pub(crate) fn priv_cells<'a>(rel: &SysRelation, p: &Priv<'a>) -> Vec<(usize, Cell<'a>)> {
    let mut cells = vec![
        (col(rel, "RDB$USER"), Cell::Text(p.user)),
        (col(rel, "RDB$RELATION_NAME"), Cell::Text(p.object)),
        (col(rel, "RDB$PRIVILEGE"), Cell::Text(p.priv_c)),
        (col(rel, "RDB$GRANT_OPTION"), Cell::Int(p.grant)),
        (col(rel, "RDB$USER_TYPE"), Cell::Int(p.user_type)),
        (col(rel, "RDB$OBJECT_TYPE"), Cell::Int(p.obj_type)),
    ];
    if let Some(schema) = p.schema {
        cells.push((col(rel, "RDB$RELATION_SCHEMA_NAME"), Cell::Text(schema)));
    }
    if let Some(grantor) = p.grantor {
        cells.push((col(rel, "RDB$GRANTOR"), Cell::Text(grantor)));
    }
    if let Some(field) = p.field {
        cells.push((col(rel, "RDB$FIELD_NAME"), Cell::Text(field)));
    }
    cells
}

/// One `RDB$USER_PRIVILEGES` row. Slice-4 callers leave `field`
/// `None` and run before the index builds, so no maintenance.
pub(crate) fn store_priv(file: &mut Image, page_size: usize, p: &Priv) -> Result<(), String> {
    let rel = rel_by_id(18);
    let image = encode_image(&descriptors_for(rel), &priv_cells(rel, p));
    dml::insert_record_system(file, page_size, 18, 0, &image)?;
    Ok(())
}

/// `RDB$RELATIONS` + `RDB$RELATION_FIELDS` (ini.epp:722-759): each
/// relation's fields first, then the relation row with its `SQL$n` /
/// `SQL$DEFAULT$n` pair and its six privilege rows (owner S/I/U/D/R
/// with grant, PUBLIC S). `RDB$FORMAT` is 0 on a fresh file for
/// every relation (`getLatestFormat` over one format).
pub fn store_relations(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    for rel in SYS_RELATIONS {
        let rf = rel_by_id(5);
        let rf_descs = descriptors_for(rf);
        let (c_schema, c_rel, c_field, c_src_schema, c_src, c_pos, c_id, c_flag, c_update) = (
            col(rf, "RDB$SCHEMA_NAME"),
            col(rf, "RDB$RELATION_NAME"),
            col(rf, "RDB$FIELD_NAME"),
            col(rf, "RDB$FIELD_SOURCE_SCHEMA_NAME"),
            col(rf, "RDB$FIELD_SOURCE"),
            col(rf, "RDB$FIELD_POSITION"),
            col(rf, "RDB$FIELD_ID"),
            col(rf, "RDB$SYSTEM_FLAG"),
            col(rf, "RDB$UPDATE_FLAG"),
        );
        for (field_id, f) in rel.fields.iter().enumerate() {
            let image = encode_image(
                &rf_descs,
                &[
                    (c_schema, Cell::Text("SYSTEM")),
                    (c_rel, Cell::Text(rel.name)),
                    (c_field, Cell::Text(f.name)),
                    (c_src_schema, Cell::Text("SYSTEM")),
                    (c_src, Cell::Text(global_name(f.global))),
                    (c_pos, Cell::Int(field_id as i64)),
                    (c_id, Cell::Int(field_id as i64)),
                    (c_flag, Cell::Int(1)),
                    (c_update, Cell::Int(i64::from(f.update))),
                ],
            );
            dml::insert_record_system(file, page_size, 5, 0, &image)?;
        }

        let sec = alloc.next_sec();
        let dflt = alloc.next_default();
        // The three relations the additional system-privilege grants
        // recompute (ini.epp:941-956): written final, never rewritten -
        // the recompute's page is full by the time slice 6 runs. Same
        // fold as the DATABASE class and the schema ACLs.
        let acl = match rel.name {
            "RDB$TYPES" => grant_relation_acl(owner, "3"),
            "RDB$BACKUP_HISTORY" => grant_relation_acl(owner, "4"),
            "RDB$DB_CREATORS" => grant_relation_acl(owner, "22"),
            _ => relation_acl(owner),
        };
        store_class(file, page_size, &sec, &acl)?;
        store_class(file, page_size, &dflt, &acl)?;

        let rr = rel_by_id(6);
        let image = encode_image(
            &descriptors_for(rr),
            &[
                (col(rr, "RDB$RELATION_ID"), Cell::Int(i64::from(rel.id))),
                (col(rr, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                (col(rr, "RDB$RELATION_NAME"), Cell::Text(rel.name)),
                (
                    col(rr, "RDB$RELATION_TYPE"),
                    Cell::Int(if rel.persistent { 0 } else { 3 }),
                ),
                (col(rr, "RDB$OWNER_NAME"), Cell::Text(owner)),
                (col(rr, "RDB$SECURITY_CLASS"), Cell::Text(&sec)),
                (col(rr, "RDB$DEFAULT_CLASS"), Cell::Text(&dflt)),
                (col(rr, "RDB$FIELD_ID"), Cell::Int(rel.fields.len() as i64)),
                (col(rr, "RDB$FORMAT"), Cell::Int(0)),
                (col(rr, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                (col(rr, "RDB$DBKEY_LENGTH"), Cell::Int(8)),
            ],
        );
        dml::insert_record_system(file, page_size, 6, 0, &image)?;

        for priv_c in ["S", "I", "U", "D", "R"] {
            // ALL_PRIVILEGES, dyn.h:35
            store_priv(
                file,
                page_size,
                &Priv {
                    user: owner,
                    schema: Some("SYSTEM"),
                    object: rel.name,
                    priv_c,
                    grant: 1,
                    user_type: 8, // obj_user
                    obj_type: 0,  // obj_relation
                    grantor: None,
                    field: None,
                },
            )?;
            if priv_c == "S" {
                store_priv(
                    file,
                    page_size,
                    &Priv {
                        user: "PUBLIC",
                        schema: Some("SYSTEM"),
                        object: rel.name,
                        priv_c,
                        grant: 0,
                        user_type: 8,
                        obj_type: 0,
                        grantor: None,
                        field: None,
                    },
                )?;
            }
        }
    }
    Ok(())
}

/// The `RDB$FIELD_TYPE` code (`blr_*`, blr.h) for a global's dtype
/// (dsc_pub.h), the `store_global_field` switch (ini.epp:1561-1671).
fn field_type_of(dtype: u8) -> i64 {
    match dtype {
        16 => 35,  // dtype_timestamp -> blr_timestamp
        26 => 29,  // dtype_timestamp_tz -> blr_timestamp_tz
        15 => 13,  // dtype_sql_time -> blr_sql_time
        14 => 12,  // dtype_sql_date -> blr_sql_date
        8 => 7,    // dtype_short -> blr_short
        9 => 8,    // dtype_long -> blr_long
        19 => 16,  // dtype_int64 -> blr_int64
        12 => 27,  // dtype_double -> blr_double
        1 => 14,   // dtype_text -> blr_text
        3 => 37,   // dtype_varying -> blr_varying
        17 => 261, // dtype_blob -> blr_blob
        21 => 23,  // dtype_boolean -> blr_bool
        d => panic!("global dtype {d} has no RDB$FIELD_TYPE mapping"),
    }
}

/// `RDB$FIELDS` (ini.epp:762-767 + `store_global_field`): one row per
/// global with its `SQL$n` class and its two USAGE grants (owner
/// with grant, PUBLIC without).
pub fn store_fields(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    let rel = rel_by_id(2);
    let descs = descriptors_for(rel);
    let (c_schema, c_name, c_len, c_scale, c_flag, c_owner, c_sec, c_sub, c_cs, c_coll, c_seg, c_charlen, c_dflt, c_type, c_null) = (
        col(rel, "RDB$SCHEMA_NAME"),
        col(rel, "RDB$FIELD_NAME"),
        col(rel, "RDB$FIELD_LENGTH"),
        col(rel, "RDB$FIELD_SCALE"),
        col(rel, "RDB$SYSTEM_FLAG"),
        col(rel, "RDB$OWNER_NAME"),
        col(rel, "RDB$SECURITY_CLASS"),
        col(rel, "RDB$FIELD_SUB_TYPE"),
        col(rel, "RDB$CHARACTER_SET_ID"),
        col(rel, "RDB$COLLATION_ID"),
        col(rel, "RDB$SEGMENT_LENGTH"),
        col(rel, "RDB$CHARACTER_LENGTH"),
        col(rel, "RDB$DEFAULT_VALUE"),
        col(rel, "RDB$FIELD_TYPE"),
        col(rel, "RDB$NULL_FLAG"),
    );
    for g in SYS_FIELDS {
        let sec = alloc.next_sec();
        store_class(file, page_size, &sec, &nonrelation_acl(owner, false))?;

        let mut cells = vec![
            (c_schema, Cell::Text("SYSTEM")),
            (c_name, Cell::Text(g.name)),
            (c_len, Cell::Int(i64::from(g.length))),
            (c_scale, Cell::Int(0)),
            (c_flag, Cell::Int(1)),
            (c_owner, Cell::Text(owner)),
            (c_sec, Cell::Text(&sec)),
            (c_type, Cell::Int(field_type_of(g.dtype))),
            (c_null, Cell::Int(i64::from(!g.nullable))),
        ];
        match g.dtype {
            8 | 9 | 19 => {
                // dsc_num_type_numeric/decimal keep their subtype; no
                // system global uses them, the branch is for fidelity.
                if g.sub_type == 1 || g.sub_type == 2 {
                    cells.push((c_sub, Cell::Int(i64::from(g.sub_type))));
                }
            }
            1 | 3 => {
                // dsc_text_type_fixed = 1 -> CS_BINARY, ascii = 2 ->
                // CS_ASCII, metadata = 3 -> CS_METADATA (dsc.h:625-627,
                // intl.h:96-98); anything else is CS_NONE with the
                // subtype NULL.
                let (cs, collate, sub, charlen) = match g.sub_type {
                    3 => (4, 0, Some(3), Some(i64::from(g.length) / 4)),
                    2 => (2, 0, Some(2), None),
                    1 => (1, 0, Some(1), None),
                    _ => (0, 0, None, None),
                };
                cells.push((c_cs, Cell::Int(cs)));
                cells.push((c_coll, Cell::Int(collate)));
                if let Some(sub) = sub {
                    cells.push((c_sub, Cell::Int(sub)));
                }
                if let Some(charlen) = charlen {
                    cells.push((c_charlen, Cell::Int(charlen)));
                }
            }
            17 => {
                cells.push((c_sub, Cell::Int(i64::from(g.sub_type))));
                cells.push((c_seg, Cell::Int(80)));
                if g.sub_type == 1 {
                    // isc_blob_text
                    cells.push((c_cs, Cell::Int(4)));
                }
            }
            _ => {}
        }
        if let Some(dflt) = g.default {
            // BLR defaults ride binary blobs: subtype 2 (the column's),
            // charset 1, probed off the fresh file.
            let num = dml::insert_blob_cs(file, page_size, 2, &[dflt.to_vec()], 2, 1)?;
            cells.push((c_dflt, Cell::BlobId(2, num)));
        }
        let image = encode_image(&descs, &cells);
        dml::insert_record_system(file, page_size, 2, 0, &image)?;

        for (user, grant) in [(owner, 1), ("PUBLIC", 0)] {
            store_priv(
                file,
                page_size,
                &Priv {
                    user,
                    schema: Some("SYSTEM"),
                    object: g.name,
                    priv_c: "G",
                    grant,
                    user_type: 8, // obj_user
                    obj_type: 9,  // obj_field
                    grantor: None,
                    field: None,
                },
            )?;
        }
    }
    Ok(())
}

/// The single `RDB$DATABASE` row (ini.epp:777-783): id 0, the default
/// charset, and - folded in from `DdlSecurity::store` - the
/// `SQL$DATABASE` class (see the module note).
pub fn store_database(file: &mut Image, page_size: usize) -> Result<(), String> {
    let rel = rel_by_id(1);
    let image = encode_image(
        &descriptors_for(rel),
        &[
            (col(rel, "RDB$RELATION_ID"), Cell::Int(0)),
            (col(rel, "RDB$CHARACTER_SET_NAME"), Cell::Text("NONE")),
            (col(rel, "RDB$CHARACTER_SET_SCHEMA_NAME"), Cell::Text("SYSTEM")),
            (col(rel, "RDB$SECURITY_CLASS"), Cell::Text("SQL$DATABASE")),
        ],
    );
    dml::insert_record_system(file, page_size, 1, 0, &image)?;
    Ok(())
}

/// `RDB$SCHEMAS` (ini.epp:789-836): SYSTEM (flagged, UTF8) and PUBLIC
/// with their `SQL$n` classes - carrying the `GRANT_privileges`
/// ACL, which runs after the indices - and one USAGE grant each to
/// owner and PUBLIC. `storeGrant` hardcodes grant option 0 and a NULL
/// schema name; the PUBLIC grants (only) name the owner as grantor.
pub fn store_schemas(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    let rel = rel_by_id(56);
    let descs = descriptors_for(rel);
    for (schema, flag, charset) in [("SYSTEM", 1, true), ("PUBLIC", 0, false)] {
        let sec = alloc.next_sec();
        store_class(file, page_size, &sec, &schema_acl(owner))?;
        let mut cells = vec![
            (col(rel, "RDB$SCHEMA_NAME"), Cell::Text(schema)),
            (col(rel, "RDB$OWNER_NAME"), Cell::Text(owner)),
            (col(rel, "RDB$SYSTEM_FLAG"), Cell::Int(flag)),
            (col(rel, "RDB$SECURITY_CLASS"), Cell::Text(&sec)),
        ];
        if charset {
            cells.push((col(rel, "RDB$CHARACTER_SET_SCHEMA_NAME"), Cell::Text("SYSTEM")));
            cells.push((col(rel, "RDB$CHARACTER_SET_NAME"), Cell::Text("UTF8")));
        }
        let image = encode_image(&descs, &cells);
        dml::insert_record_system(file, page_size, 56, 0, &image)?;

        for user in [owner, "PUBLIC"] {
            store_priv(
                file,
                page_size,
                &Priv {
                    user,
                    schema: None,
                    object: schema,
                    priv_c: "G",
                    grant: 0,
                    user_type: 8,  // obj_user
                    obj_type: 38,  // obj_schema
                    grantor: if schema == "PUBLIC" { Some(owner) } else { None },
                    field: None,
                },
            )?;
        }
    }
    Ok(())
}

/// `RDB$GENERATORS` (ini.epp:910-916 + `store_generator`): the 13
/// rows with their `SQL$451..463` classes and USAGE grants. Initial
/// value and increment are 0; descriptions ride metadata-text blobs
/// (subtype 1, charset 4, probed).
pub fn store_generators(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    alloc.reserve_sec(INTL_CLASSES_RESERVED);
    let rel = rel_by_id(20);
    let descs = descriptors_for(rel);
    for (name, id, description) in SYS_GENERATORS {
        let sec = alloc.next_sec();
        store_class(file, page_size, &sec, &nonrelation_acl(owner, false))?;
        let mut cells = vec![
            (col(rel, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
            (col(rel, "RDB$GENERATOR_NAME"), Cell::Text(name)),
            (col(rel, "RDB$GENERATOR_ID"), Cell::Int(i64::from(*id))),
            (col(rel, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
            (col(rel, "RDB$OWNER_NAME"), Cell::Text(owner)),
            (col(rel, "RDB$SECURITY_CLASS"), Cell::Text(&sec)),
            (col(rel, "RDB$INITIAL_VALUE"), Cell::Int(0)),
            (col(rel, "RDB$GENERATOR_INCREMENT"), Cell::Int(0)),
        ];
        if let Some(description) = description {
            let num = dml::insert_blob_cs(
                file,
                page_size,
                20,
                &[description.as_bytes().to_vec()],
                1,
                4,
            )?;
            cells.push((col(rel, "RDB$DESCRIPTION"), Cell::BlobId(20, num)));
        }
        let image = encode_image(&descs, &cells);
        dml::insert_record_system(file, page_size, 20, 0, &image)?;

        for (user, grant) in [(owner, 1), ("PUBLIC", 0)] {
            store_priv(
                file,
                page_size,
                &Priv {
                    user,
                    schema: Some("SYSTEM"),
                    object: name,
                    priv_c: "G",
                    grant,
                    user_type: 8,  // obj_user
                    obj_type: 14,  // obj_generator
                    grantor: None,
                    field: None,
                },
            )?;
        }
    }
    Ok(())
}

/// The whole slice: relations, fields, database, schemas (with the
/// intl gap), generators - 60 + 598 + 187 + 1 + 2 + 13 rows, 322
/// security classes, 764 privilege rows.
pub fn store_core_catalog(
    file: &mut Image,
    page_size: usize,
    owner: &str,
) -> Result<SecurityAlloc, String> {
    let mut alloc = SecurityAlloc::new();
    store_relations(file, page_size, owner, &mut alloc)?;
    store_fields(file, page_size, owner, &mut alloc)?;
    store_database(file, page_size)?;
    store_schemas(file, page_size, owner, &mut alloc)?;
    store_generators(file, page_size, owner, &mut alloc)?;
    Ok(alloc)
}
