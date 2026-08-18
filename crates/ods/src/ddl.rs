//! DDL write path: CREATE TABLE, converted from the engine's own
//! sequence - `RelationNode` DDL (DdlNodes.epp `make_version`,
//! :8570-9000) storing the catalog rows, `makeFormat` (:9455) laying
//! the physical format and storing `RDB$FORMATS` with the packed
//! descriptor blob, the `RDB$RUNTIME` field-summary blob
//! (`putSummaryRecord`, :9292 - `[tag][payload]` per segment), and
//! `DPM_create_relation` (dpm.epp:588) allocating the pointer and
//! index-root pages and registering both in `RDB$PAGES`.
//!
//! Everything here was pinned by a differential probe first: two
//! engine-created databases differing by exactly one CREATE TABLE,
//! their catalog rows, blob bytes and page structures diffed. Facts
//! that came out of that probe rather than assumption:
//!   - field ids are assigned in DECLARATION order for a fresh table
//!     (ID=0, NAME=1, ... - not alphabetical, not by alignment);
//!   - the descriptor blob is `[u16 count][count x 12-byte packed
//!     Ods::Descriptor][u16 0 defaults]` in ONE segment;
//!   - the runtime blob is, per field: RSR_field_id(0) u16,
//!     RSR_field_name(1), RSR_field_source(25) as the QUOTED
//!     `"PUBLIC"."RDB$n"`, RSR_field_length(19) u16,
//!     RSR_character_length(26) u16 (text only), RSR_field_pos(27)
//!     u16 - nothing else for a plain nullable column;
//!   - blh_charset is 1 for both metadata blobs, blh_length counts
//!     segment payloads only;
//!   - auto-domains are `RDB$<n>`; the engine's own
//!     `DYN_UTIL_generate_field_name` loops until unused, so naming
//!     ours max+1 cannot break later engine-side DDL;
//!   - the security-class/owner columns can stay NULL: SYSDBA access
//!     does not consult them (asserted by the gate - the engine both
//!     reads and writes the table).
//!
//! System-catalog INDEXES are maintained on every row this module
//! inserts (the engine resolves metadata through them - a missing
//! entry makes the table invisible to its lookups, and `gfix -v`
//! reports it): segments read from the irtd arrays, keys built by
//! [crate::btw::build_index_key] - `idx_metadata` text and numeric
//! segments, unique enforcement included (a duplicate table name
//! refuses on the RDB$RELATIONS unique index exactly like a duplicate
//! key anywhere else).

use crate::btr::find_index_root;
use crate::btw;
use crate::catalog::{list_relations, relation_columns};
use crate::data::{DataPage, DPG_RPT_OFFSET, RHD_DATA_OFFSET};
use crate::dml;
use crate::format::{decode_record, flag_bytes, max_recs_per_dp, Value};
use crate::gen;
use crate::pointer::relation_data_pages;
use crate::sysfmt::{compute_format, compute_format_mixed, system_relation_formats};
use crate::{u16_at, u32_at, Descriptor};

/// Whether a type's `RDB$FIELD_SUB_TYPE` is written at all: the engine
/// stores one (0 or the declared NUMERIC/DECIMAL code) only for the
/// exact-int family and text; FLOAT/DOUBLE/DATE/TIME/TIMESTAMP/BOOLEAN
/// rows keep it NULL (probed).
fn subtype_carried(field_type: i16) -> bool {
    // 261 = blob, whose sub_type is the whole point of the column
    matches!(field_type, 7 | 8 | 16 | 26 | 14 | 37 | 261)
}

/// One column of a CREATE TABLE: its name, the external catalog type
/// code (`RDB$FIELD_TYPE`), and the storage descriptor pieces.
#[derive(Clone)]
pub struct ColumnDef {
    pub name: String,
    /// RDB$FIELD_TYPE: 7 smallint, 8 integer, 16 int64, 14 text,
    /// 37 varying, 12 date, 13 time, 35 timestamp, 23 boolean,
    /// 27 double, 10 float
    pub field_type: i16,
    /// dsc dtype (dsc.h codes - what the descriptor blob carries)
    pub dtype: u8,
    /// stored length (dsc_length: VARCHAR includes the count word)
    pub length: u16,
    pub scale: i8,
    /// RDB$FIELD_SUB_TYPE (1/2 for NUMERIC/DECIMAL, else 0)
    pub sub_type: i16,
    /// RDB$FIELD_PRECISION as the engine writes it for a declared column
    /// (probed, incl domains and ALTER ADD): `Some(0)` for the plain
    /// exact-int family (SMALLINT/INTEGER/BIGINT/INT128), the declared
    /// `p` for NUMERIC/DECIMAL(p,s), `None` (SQL NULL) for every other
    /// type. A computed column ignores this - its result precision
    /// travels in [ComputedCol::precision].
    pub precision: Option<i16>,
    /// character length, for CHAR/VARCHAR (charset NONE: == bytes)
    pub char_len: Option<u16>,
    /// NOT NULL - explicit, or implied by PRIMARY KEY membership
    pub not_null: bool,
    /// whether this column's NOT NULL is a COLUMN-level declaration
    /// (`... NOT NULL` or a column-level `PRIMARY KEY`). The engine
    /// writes an `INTEG_<n>` "NOT NULL" constraint row only for those;
    /// a TABLE-level `PRIMARY KEY (a, b)` sets its columns' NULL_FLAG
    /// but writes no constraint row (probed: table P vs table Q).
    pub not_null_constraint: bool,
    /// a column `DEFAULT <literal>`, if any: the source text
    /// (`DEFAULT 0`) and its value BLR
    pub default: Option<ColumnDefault>,
    /// when the column's type is a user domain (`X DOM_I`), the domain's
    /// name; the type fields above are placeholders, resolved from the
    /// domain's `RDB$FIELDS` row at [create_table]. `None` for a built-in type.
    pub domain: Option<String>,
    /// a `GENERATED ... AS IDENTITY` clause: an implicit generator backs the
    /// column and its next value fills it. `None` for an ordinary column.
    pub identity: Option<IdentityDef>,
    /// a `COMPUTED BY (<expr>)` column: the expression, compiled. The
    /// ColumnDef's type fields carry the expression's RESULT type - inferred
    /// by the caller from the engine's dialect-3 rules, not declared.
    pub computed: Option<ComputedCol>,
}

/// The pieces of a `COMPUTED BY (<expr>)` column the catalog stores: the
/// verbatim parenthesised source text (`RDB$COMPUTED_SOURCE`), the
/// compiled expression BLR (`RDB$COMPUTED_BLR`), and the result type's
/// `RDB$FIELD_PRECISION` (the engine writes it for a computed field where
/// a plain declared column gets 0/NULL: SHORT 4, LONG 9, INT64 18).
#[derive(Clone)]
pub struct ComputedCol {
    pub source: String,
    pub blr: Vec<u8>,
    pub precision: i16,
}

/// A column's `GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY
/// [(START WITH <n> [INCREMENT [BY] <n>])]`.
#[derive(Clone)]
pub struct IdentityDef {
    /// `RDB$IDENTITY_TYPE`: 0 = GENERATED ALWAYS, 1 = GENERATED BY DEFAULT
    pub identity_type: i16,
    pub start: i64,
    pub increment: i64,
}

/// A column (or domain) `DEFAULT <literal>`: the `RDB$DEFAULT_SOURCE` text
/// and the `RDB$DEFAULT_VALUE` BLR.
#[derive(Clone)]
pub struct ColumnDefault {
    pub source: String,
    pub value_blr: Vec<u8>,
}

/// The BLR of an integer-literal default - `blr_version5, blr_literal,
/// blr_long, scale 0, the 4-byte value, blr_eoc`. The engine writes a
/// literal as `blr_long` regardless of the column width (probe: a SMALLINT
/// and a BIGINT default both carry a 4-byte `blr_long` value).
pub fn int_default_blr(value: i32) -> Vec<u8> {
    let mut b = vec![5u8, 21, 8, 0]; // version5, blr_literal, blr_long, scale
    b.extend_from_slice(&value.to_le_bytes());
    b.push(76); // blr_eoc
    b
}

/// The BLR of a string-literal default - `blr_version5, blr_literal,
/// blr_text2, charset 0, the 2-byte length, the bytes, blr_eoc`. The
/// literal carries its own length, not the column's (no padding).
pub fn str_default_blr(text: &str) -> Vec<u8> {
    let mut b = vec![5u8, 21, 15, 0, 0]; // version5, literal, blr_text2, charset(2 bytes)
    b.extend_from_slice(&(text.len() as u16).to_le_bytes());
    b.extend_from_slice(text.as_bytes());
    b.push(76); // blr_eoc
    b
}

/// The BLR of a `DEFAULT <context-value-keyword>` - each a fixed byte
/// sequence (probed): the date/time/user values are one opcode
/// (`blr_version5, <op>, blr_eoc`); LOCALTIME/LOCALTIMESTAMP carry a
/// default-precision byte; CURRENT_CONNECTION/TRANSACTION are
/// `blr_internal_info` (177) with an info-code literal. None for anything a
/// full expression compiler would be needed for.
pub fn keyword_default_blr(keyword: &str) -> Option<Vec<u8>> {
    Some(match keyword.trim().to_ascii_uppercase().as_str() {
        "CURRENT_DATE" => vec![5, 160, 76],
        "CURRENT_TIMESTAMP" => vec![5, 161, 76],
        "CURRENT_TIME" => vec![5, 162, 76],
        "CURRENT_USER" | "USER" => vec![5, 44, 76], // blr_user_name
        "CURRENT_ROLE" => vec![5, 174, 76],
        "LOCALTIMESTAMP" => vec![5, 214, 3, 76], // default precision 3
        "LOCALTIME" => vec![5, 215, 0, 76],      // default precision 0
        // blr_internal_info, blr_literal blr_long <info-code>, blr_eoc
        "CURRENT_CONNECTION" => vec![5, 177, 21, 8, 0, 1, 0, 0, 0, 76],
        "CURRENT_TRANSACTION" => vec![5, 177, 21, 8, 0, 2, 0, 0, 0, 76],
        _ => return None,
    })
}

/// The BLR of a `DEFAULT NULL` - `blr_version5, blr_null, blr_eoc`. The
/// engine stores this explicitly (source `DEFAULT NULL`), distinct from a
/// column with no default at all (which has neither source nor value); the
/// applied result is the same NULL, but the catalog records the intent.
pub fn null_default_blr() -> Vec<u8> {
    vec![5u8, 45, 76] // version5, blr_null, blr_eoc
}

/// One table-level key constraint of a CREATE TABLE: a `PRIMARY KEY` or
/// a `UNIQUE`, named or not. Both are backed by a unique index; the
/// engine names that index after the constraint when the constraint is
/// named, and generates `RDB$PRIMARY<n>` / `RDB$<n>` when it is not.
#[derive(Clone)]
pub struct KeyDef {
    /// constraint name, empty when the statement did not name it
    pub name: String,
    /// key columns, in key order
    pub columns: Vec<String>,
    /// PRIMARY KEY (true) or UNIQUE (false)
    pub primary: bool,
}

/// One `[CONSTRAINT <name>] CHECK (<condition>)` of a CREATE TABLE: the
/// verbatim source text from the CHECK keyword on (`RDB$TRIGGER_SOURCE`),
/// the compiled trigger BLR (the NEGATED condition inside the
/// if-failed-raise wrapper - [crate::expr::check_trigger_blr]), and the
/// fields the condition references, first-seen order (the trigger's
/// `RDB$DEPENDENCIES` rows).
#[derive(Clone)]
pub struct CheckDef {
    /// constraint name, empty when the statement did not name it
    pub name: String,
    pub source: String,
    pub trigger_blr: Vec<u8>,
    pub fields: Vec<String>,
}

/// A table-level constraint of a CREATE TABLE, in DECLARATION order -
/// the order the engine's generated INTEG_<n> names follow (probed: a
/// CHECK declared between a NOT NULL column and the PRIMARY KEY numbers
/// between them).
#[derive(Clone)]
pub enum TableConstraint {
    Key(KeyDef),
    Check(CheckDef),
}

/// Values a system-catalog row is built from, keyed by column name.
enum SysVal<'a> {
    I(i64),
    S(&'a str),
    /// a DOUBLE PRECISION catalog column (index selectivity)
    F(f64),
    /// the 8 on-disk blob-id bytes
    B([u8; 8]),
    /// a binary CHAR (CHARACTER SET OCTETS) column - the bytes verbatim,
    /// zero-padded (not space-padded) to the column length. `RDB$ROLES`'s
    /// `RDB$SYSTEM_PRIVILEGES` is a CHAR(8) OCTETS of eight zero bytes.
    O(&'a [u8]),
    /// set the column's NULL bit (an in-place patch only - `sys_insert`
    /// starts every field NULL already)
    Null,
}

/// The 8 wire/disk bytes of a blob id (RecordNumber.h:63-71) - also in
/// the server's `encode_blob_id`; duplicated here because the id goes
/// INTO catalog record images.
fn blob_id_bytes(rel: u16, num: u64) -> [u8; 8] {
    let mut b = [0u8; 8];
    b[0..2].copy_from_slice(&rel.to_le_bytes());
    b[3] = (num >> 32) as u8;
    b[4..8].copy_from_slice(&(num as u32).to_le_bytes());
    b
}

/// Walk every committed-looking primary record of a system relation,
/// decoded with `descs`.
fn walk_rows(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(&[Value]),
) {
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            cb(&decode_record(&image, descs));
        }
    }
}

/// The shape of a new system-relation row: format number 0 - every
/// engine-written system record carries it (probe: rels 0/2/5/6/8,
/// 900+ records, all format 0) - and the computed format's walk-end
/// length (`fmt_length`; rel 8's probe image was exactly it).
fn system_row_shape(descs: &[Descriptor]) -> (u8, usize) {
    let end = descs
        .iter()
        .map(|d| d.offset as usize + d.length as usize)
        .max()
        .unwrap_or(0);
    (0, end)
}

/// Encode one value at a catalog column's descriptor. Only the types
/// the system catalog actually stores in the rows we write.
fn encode_sys_value(d: &Descriptor, v: &SysVal<'_>) -> Result<Vec<u8>, String> {
    use crate::format::dtype;
    Ok(match (v, d.dtype) {
        (SysVal::I(n), dtype::SHORT) => (i16::try_from(*n).map_err(|_| "short range")?)
            .to_le_bytes()
            .to_vec(),
        (SysVal::I(n), dtype::LONG) => (i32::try_from(*n).map_err(|_| "long range")?)
            .to_le_bytes()
            .to_vec(),
        (SysVal::I(n), dtype::INT64) => n.to_le_bytes().to_vec(),
        (SysVal::S(s), dtype::TEXT) => {
            let b = s.as_bytes();
            if b.len() > d.length as usize {
                return Err("text too long for catalog column".into());
            }
            let mut out = b.to_vec();
            out.resize(d.length as usize, b' ');
            out
        }
        (SysVal::S(s), dtype::VARYING) => {
            let b = s.as_bytes();
            if b.len() + 2 > d.length as usize {
                return Err("varchar too long for catalog column".into());
            }
            let mut out = (b.len() as u16).to_le_bytes().to_vec();
            out.extend_from_slice(b);
            out
        }
        (SysVal::F(v), dtype::DOUBLE) => v.to_le_bytes().to_vec(),
        (SysVal::B(id), dtype::BLOB) => id.to_vec(),
        (SysVal::O(b), dtype::TEXT) => {
            if b.len() > d.length as usize {
                return Err("octets too long for catalog column".into());
            }
            let mut out = b.to_vec();
            out.resize(d.length as usize, 0); // OCTETS pad byte is 0, not space
            out
        }
        (SysVal::Null, _) => return Err("SysVal::Null has no encoding".into()),
        _ => return Err("catalog value/type mismatch".into()),
    })
}

/// Insert one row into a system relation - image built at the
/// relation's computed (ini.epp-walk) format, EVERY index of the
/// relation maintained. This is what makes the row real to the
/// engine: its metadata lookups go through these indexes.
fn sys_insert(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let formats =
        system_relation_formats(file, page_size, rel_name).ok_or("no computed system format")?;
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("empty system format")?;
    let columns = relation_columns(file, page_size, rel_name);
    let (format_no, image_len) = system_row_shape(descs);

    let mut image = vec![0u8; image_len];
    for i in 0..descs.len() {
        image[i / 8] |= 1 << (i % 8); // start all-NULL
    }
    let mut key_values: Vec<Value> = vec![Value::Null; descs.len()];
    for (name, v) in values {
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| format!("unknown catalog column {}", name))?;
        let fid = rc.field_id as usize;
        let d = descs.get(fid).ok_or("field beyond computed format")?;
        let bytes = encode_sys_value(d, v)?;
        let at = d.offset as usize;
        if at + bytes.len() > image.len() {
            return Err("catalog image shorter than its format".into());
        }
        image[at..at + bytes.len()].copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        key_values[fid] = match v {
            SysVal::I(n) => Value::Int(*n),
            SysVal::S(s) => Value::Text((*s).to_string()),
            // no catalog index covers a blob, a selectivity or a NULL
            SysVal::B(_) | SysVal::F(_) | SysVal::O(_) | SysVal::Null => Value::Null,
        };
    }

    // RDB$PAGES rows must be system-transaction (tx 0) records - the
    // engine's get_header refuses anything else with isc_wrong_page
    let out = if rel == 0 {
        dml::insert_record_system(file, page_size, rel, format_no, &image)?
    } else {
        dml::insert_record(file, page_size, rel, format_no, &image)?
    };
    let seq = u32_at(
        crate::page_at(file, page_size, out.page_no).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + out.slot as u64;

    maintain_indexes(file, page_size, rel, recno, &key_values, descs)
}

/// Key one record into every index of its relation - what the engine
/// does on any write that changes an INDEXED value. Insertion is the
/// obvious caller; the other is an in-place row rewrite that changes a
/// key column (renaming an index in RDB$INDICES, say), where the old
/// entry stays behind for garbage collection but the NEW key needs an
/// entry of its own: `gfix` reports "Index n is corrupt {missing
/// entries for record m}" otherwise.
fn maintain_indexes(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    recno: u64,
    key_values: &[Value],
    descs: &[Descriptor],
) -> Result<(), String> {
    let Some(irt) = find_index_root(file, page_size, rel) else {
        return Ok(());
    };
    let entries: Vec<_> = irt.live_entries().map(|e| (e.id, e.key_count)).collect();
    for (id, key_count) in entries {
        let (segs, iflags) = btw::index_segments(file, page_size, rel, id, key_count as usize)
            .ok_or("unreadable system index segments")?;
        let null = Value::Null;
        let key_segs: Vec<btw::KeySeg<'_>> = segs
            .iter()
            .map(|(field, itype)| btw::KeySeg {
                itype: *itype,
                value: key_values.get(*field as usize).unwrap_or(&null),
                scale: descs.get(*field as usize).map_or(0, |d| d.scale),
                // system-catalog text is UTF8/metadata - no codepage
                charset: 0,
            })
            .collect();
        let (key, all_null) = btw::build_index_key(&key_segs, iflags & btw::IRT_DESCENDING != 0)
            .ok_or("unsupported system index key")?;
        btw::insert_index_entry(
            file,
            page_size,
            rel,
            id,
            &key,
            recno,
            iflags & btw::IRT_UNIQUE != 0 && !all_null,
            iflags & btw::IRT_DESCENDING != 0,
        )?;
    }
    Ok(())
}

/// The next free `RDB$<n>` auto-domain number: one past the highest in
/// RDB$FIELDS. The engine's own generator skips used names, so this
/// cannot break later engine-side DDL.
fn next_domain_number(file: &crate::Image, page_size: usize) -> Result<u64, String> {
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")
        .ok_or("no computed RDB$FIELDS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_fid = relation_columns(file, page_size, "RDB$FIELDS")
        .iter()
        .find(|c| c.name == "RDB$FIELD_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$FIELD_NAME column")?;
    let mut max = 0u64;
    walk_rows(file, page_size, 2, descs, |values| {
        if let Some(Value::Text(t)) = values.get(name_fid) {
            let t = t.trim_end();
            if let Some(num) = t.strip_prefix("RDB$").and_then(|s| s.parse::<u64>().ok()) {
                max = max.max(num);
            }
        }
    });
    Ok(max + 1)
}

/// Write a format descriptor blob (makeFormat): one segment of
/// `[u16 count][count x 12B packed descriptors][u16 0 defaults]`. Stored
/// in `RDB$FORMATS.RDB$DESCRIPTOR`; the engine reads it to lay out records
/// of that format version.
fn write_format_blob(
    file: &mut crate::Image,
    page_size: usize,
    descs: &[Descriptor],
) -> Result<u64, String> {
    let mut fmt_payload = Vec::with_capacity(2 + descs.len() * 12 + 2);
    fmt_payload.extend_from_slice(&(descs.len() as u16).to_le_bytes());
    for d in descs {
        fmt_payload.push(d.dtype);
        fmt_payload.push(d.scale as u8);
        fmt_payload.extend_from_slice(&d.length.to_le_bytes());
        fmt_payload.extend_from_slice(&(d.sub_type as u16).to_le_bytes());
        fmt_payload.extend_from_slice(&d.flags.to_le_bytes());
        fmt_payload.extend_from_slice(&d.offset.to_le_bytes());
    }
    fmt_payload.extend_from_slice(&0u16.to_le_bytes());
    dml::insert_blob(file, page_size, 8, &[fmt_payload], 6)
}

/// Turn a relation's current descriptors back into the `(dtype, length,
/// scale, sub_type)` tuples `compute_format` consumes. `compute_format`
/// re-adds the VARYING count word, so it is stripped here first - without
/// which each ALTER would inflate every VARYING column by two more bytes.
fn descs_to_fields(descs: &[Descriptor]) -> Vec<(u8, u16, i8, i16)> {
    descs
        .iter()
        .map(|d| {
            let gfld = if d.dtype == crate::format::dtype::VARYING {
                d.length.saturating_sub(2)
            } else {
                d.length
            };
            (d.dtype, gfld, d.scale, d.sub_type)
        })
        .collect()
}

/// The `compute_format` input tuple for a *declared* column. A ColumnDef's
/// `length` for VARYING already carries the 2-byte count word (VARCHAR(n) =>
/// n+2), but `compute_format` re-adds it, so strip it here - the mirror of
/// `descs_to_fields`. Without this the descriptor double-counts the count word
/// (VARCHAR(6) => dsc_length 10 where the engine writes 8).
fn col_field(dtype: u8, length: u16, scale: i8, sub_type: i16) -> (u8, u16, i8, i16) {
    let gfld = if dtype == crate::format::dtype::VARYING {
        length.saturating_sub(2)
    } else {
        length
    };
    (dtype, gfld, scale, sub_type)
}

/// Whether a format contains a COMPUTED field: a descriptor at offset 0
/// with a real type. No stored field can live at offset 0 (the null
/// flags do), and a DROPPED-field placeholder there is all-zero - a
/// nonzero length at offset 0 can only be a computed column.
pub fn has_computed_field(descs: &[Descriptor]) -> bool {
    descs.iter().any(|d| d.offset == 0 && d.length != 0)
}

/// Every COMPUTED column of a table, with the field names its stored
/// expression references: `(column name, Some(referenced names))`, or
/// `None` names when the BLR is outside the surface
/// [crate::expr::field_names_of_blr] can read - the caller must then
/// assume it references anything.
fn computed_dependencies(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Vec<(String, Option<Vec<String>>)> {
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    // (column name, field source) of the table's columns
    let Some(rf_formats) = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
    else {
        return Vec::new();
    };
    let Some((_, rf_descs)) = rf_formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rf_rel), Some(rf_name), Some(rf_src)) = (
        rf_fid("RDB$RELATION_NAME"),
        rf_fid("RDB$FIELD_NAME"),
        rf_fid("RDB$FIELD_SOURCE"),
    ) else {
        return Vec::new();
    };
    let mut members: Vec<(String, String)> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rf_rel)).as_deref() != Some(table) {
            return;
        }
        if let (Some(name), Some(src)) = (text(vals.get(rf_name)), text(vals.get(rf_src))) {
            members.push((name, src));
        }
    });
    // each source's RDB$COMPUTED_BLR, decoded to its field names
    let Some(f_formats) = system_relation_formats(file, page_size, "RDB$FIELDS") else {
        return Vec::new();
    };
    let Some((_, f_descs)) = f_formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let fcols = relation_columns(file, page_size, "RDB$FIELDS");
    let ffid = |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(fname_f), Some(cblr_f)) = (ffid("RDB$FIELD_NAME"), ffid("RDB$COMPUTED_BLR"))
    else {
        return Vec::new();
    };
    let mut blobs: Vec<(String, u16, u64)> = Vec::new();
    walk_rows(file, page_size, 2, f_descs, |vals| {
        let Some(fname) = text(vals.get(fname_f)) else { return };
        let Some((col, _)) = members.iter().find(|(_, s)| *s == fname) else {
            return;
        };
        if let Some(Value::Blob(r, n)) = vals.get(cblr_f) {
            blobs.push((col.clone(), *r, *n));
        }
    });
    blobs
        .into_iter()
        .map(|(col, r, n)| {
            let names = crate::format::read_blob_content(file, page_size, r, n)
                .and_then(|b| crate::expr::field_names_of_blr(&b));
            (col, names)
        })
        .collect()
}

/// Locate a system relation's primary row whose decoded values satisfy
/// `pred`: its data page and slot. For an in-place catalog update or
/// delete (ALTER).
fn find_sys_row_slot(
    file: &crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
) -> Option<(u32, u16)> {
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let dp = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            if pred(&decode_record(&image, descs)) {
                return Some((dp_no, r.slot));
            }
        }
    }
    None
}

/// Locate the `RDB$RELATIONS` primary row for `table`: its data page,
/// slot, current record image, and record format number - what an
/// in-place catalog update (ALTER) needs to rewrite the row.
fn find_relations_row(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<(u32, u16, Vec<u8>, u8)> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let name_fid = relation_columns(file, page_size, "RDB$RELATIONS")
        .iter()
        .find(|c| c.name == "RDB$RELATION_NAME")
        .map(|c| c.field_id as usize)?;
    for dp_no in relation_data_pages(file, page_size, 6) {
        let dp = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let vals = decode_record(&image, descs);
            if let Some(Value::Text(t)) = vals.get(name_fid) {
                if t.trim_end().eq_ignore_ascii_case(table) {
                    return Some((dp_no, r.slot, image, r.format));
                }
            }
        }
    }
    None
}

/// Rebuild the `RDB$RUNTIME` field summary for a table from its current
/// `RDB$RELATION_FIELDS` rows (the engine's DSQL layer resolves columns
/// through this blob, so after an ALTER it must list every field). Each
/// field contributes the same segment sequence `make_version` writes:
/// id, name, source (as the quoted `"PUBLIC"."RDB$n"`), length, character
/// length for text, position, and a not-null marker. `descs` is the new
/// full format, indexed by field id, for lengths.
fn rebuild_runtime_blob(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    descs: &[Descriptor],
) -> Result<u64, String> {
    use crate::format::dtype;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid_of = |name: &str| cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let name_fid = fid_of("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rel_fid = fid_of("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let id_fid = fid_of("RDB$FIELD_ID").ok_or("no RDB$FIELD_ID")?;
    let src_fid = fid_of("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let pos_fid = fid_of("RDB$FIELD_POSITION").ok_or("no RDB$FIELD_POSITION")?;
    let null_fid = fid_of("RDB$NULL_FLAG");
    let default_fid = fid_of("RDB$DEFAULT_VALUE");
    let gen_fid = fid_of("RDB$GENERATOR_NAME");
    let idt_fid = fid_of("RDB$IDENTITY_TYPE");
    let base_fid = fid_of("RDB$BASE_FIELD");
    let vctx_fid = fid_of("RDB$VIEW_CONTEXT");
    let mut view_links: Vec<(String, i64, String)> = Vec::new();

    // collect (field_id, name, source, position, not_null), by field id
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let int = |v: Option<&Value>| match v {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    };
    #[allow(clippy::type_complexity)]
    let mut fields: Vec<(
        u16,
        String,
        String,
        u16,
        bool,
        Option<(u16, u64)>,
        Option<(String, i16)>,
    )> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rel_fid)).as_deref() != Some(table) {
            return;
        }
        let (Some(name), Some(id), Some(src), Some(pos)) = (
            text(vals.get(name_fid)),
            int(vals.get(id_fid)),
            text(vals.get(src_fid)),
            int(vals.get(pos_fid)),
        ) else {
            return;
        };
        let not_null = null_fid.and_then(|f| int(vals.get(f))) == Some(1);
        // the column's DEFAULT blob, if any, to re-emit as RSR_default_value
        let default = default_fid.and_then(|f| match vals.get(f) {
            Some(Value::Blob(r, n)) => Some((*r, *n)),
            _ => None,
        });
        // an identity column's generator name and type, to re-emit (tags 22/23)
        let identity = idt_fid.and_then(|f| int(vals.get(f))).and_then(|t| {
            gen_fid
                .and_then(|g| text(vals.get(g)))
                .map(|g| (g, t as i16))
        });
        // a VIEW field's context + base, for the runtime's
        // RSR_view_context / RSR_base_field segments
        if let (Some(bf), Some(vf)) = (base_fid, vctx_fid) {
            if let (Some(crate::format::Value::Text(b)), Some(crate::format::Value::Int(c))) =
                (vals.get(bf), vals.get(vf))
            {
                view_links.push((name.clone(), *c, b.trim_end().to_string()));
            }
        }
        fields.push((id as u16, name, src, pos as u16, not_null, default, identity));
    });
    fields.sort_by_key(|f| f.0);

    // per field SOURCE, from its RDB$FIELDS row: a COMPUTED field's
    // expression BLR (re-emitted as RSR_computed_blr = 4, between the
    // length and position segments - probed order), and a DOMAIN's
    // DEFAULT (a domain column with no column-level default INHERITS
    // the domain's, and the engine's rebuilt summary carries it -
    // probed on ALTER DOMAIN rename, where the engine's runtime kept
    // the RSR_default_value segment this rebuild used to drop)
    let mut computed_blobs: Vec<(String, (u16, u64))> = Vec::new();
    let mut domain_defaults: Vec<(String, (u16, u64))> = Vec::new();
    if let Some(f_formats) = system_relation_formats(file, page_size, "RDB$FIELDS") {
        if let Some((_, f_descs)) = f_formats.iter().max_by_key(|(n, _)| *n) {
            let fcols = relation_columns(file, page_size, "RDB$FIELDS");
            let ffid =
                |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(fname_f), Some(cblr_f), dval_f) = (
                ffid("RDB$FIELD_NAME"),
                ffid("RDB$COMPUTED_BLR"),
                ffid("RDB$DEFAULT_VALUE"),
            ) {
                walk_rows(file, page_size, 2, f_descs, |vals| {
                    let Some(fname) = text(vals.get(fname_f)) else { return };
                    if !fields.iter().any(|f| f.2 == fname) {
                        return;
                    }
                    if let Some(Value::Blob(r, n)) = vals.get(cblr_f) {
                        computed_blobs.push((fname.clone(), (*r, *n)));
                    }
                    if let Some(Some(Value::Blob(r, n))) = dval_f.map(|f| vals.get(f)) {
                        domain_defaults.push((fname, (*r, *n)));
                    }
                });
            }
        }
    }

    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    for (id, name, src, pos, not_null, default, identity) in &fields {
        let d = descs.get(*id as usize).ok_or("field beyond format")?;
        runtime.push(seg(0, &id.to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, name.as_bytes())); // RSR_field_name
        // a VIEW's field carries its context and base field - the
        // relation loader binds fld_source through them
        // (met.epp RSR_view_context / RSR_base_field)
        if let Some((ctx, base)) = view_links.iter().find(|(n, ..)| n == name).map(|(_, c, b)| (*c, b)) {
            runtime.push(seg(2, &(ctx as u16).to_le_bytes())); // RSR_view_context
            runtime.push(seg(3, base.as_bytes())); // RSR_base_field
        }
        let qsrc = format!("\"PUBLIC\".\"{}\"", src);
        runtime.push(seg(25, qsrc.as_bytes())); // RSR_field_source
        let char_len = match d.dtype {
            dtype::VARYING => Some(d.length.saturating_sub(2)),
            dtype::TEXT => Some(d.length),
            _ => None,
        };
        // RSR_field_length is the byte (declared) length, not the storage
        // length - a VARYING's is d.length minus its 2-byte count word
        runtime.push(seg(19, &char_len.unwrap_or(d.length).to_le_bytes()));
        if let Some(cl) = char_len {
            runtime.push(seg(26, &cl.to_le_bytes())); // RSR_character_length
        }
        // the computed expression (RSR_computed_blr = 4) before the position
        if let Some((_, (r, n))) = computed_blobs.iter().find(|(s, _)| s == src) {
            if let Some(blr) = crate::format::read_blob_content(file, page_size, *r, *n) {
                runtime.push(seg(4, &blr));
            }
        }
        runtime.push(seg(27, &pos.to_le_bytes())); // RSR_field_pos
        // re-emit the column DEFAULT (RSR_default_value = 6) so an ALTER
        // does not drop it from the summary the engine applies defaults
        // from; a domain column with no column-level default inherits
        // the DOMAIN's
        let effective_default = default
            .map(|(r, n)| (r, n))
            .or_else(|| domain_defaults.iter().find(|(s, _)| s == src).map(|(_, b)| *b));
        if let Some((r, n)) = effective_default {
            if let Some(blr) = crate::format::read_blob_content(file, page_size, r, n) {
                runtime.push(seg(6, &blr));
            }
        }
        if *not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
        // re-emit an identity field's generator (22) and type (23) so an ALTER
        // does not strip it - without them the column stops auto-generating
        if let Some((gen_name, itype)) = identity {
            runtime.push(seg(22, gen_name.as_bytes()));
            runtime.push(seg(23, &(*itype as u16).to_le_bytes()));
        }
    }
    // the relation's triggers (RSR_trigger_name = 9): the engine loads a
    // relation's trigger vector from these runtime entries, NOT by scanning
    // RDB$TRIGGERS by relation name - so a trigger absent here never fires
    for tname in relation_trigger_names(file, page_size, table) {
        runtime.push(seg(9, tname.as_bytes()));
    }
    dml::insert_blob(file, page_size, 6, &runtime, 5)
}

/// The names of a relation's triggers in the order the engine lists
/// them in the relation's `RDB$RUNTIME` summary: by (RDB$TRIGGER_
/// SEQUENCE, then name LEXICALLY) - probed three ways: user triggers at
/// positions 0/1/5 list in position order regardless of name or event;
/// same-position triggers list lexically (CHECK_10 before CHECK_7); the
/// event type does not participate.
fn relation_trigger_names(file: &crate::Image, page_size: usize, table: &str) -> Vec<String> {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$TRIGGERS"),
        system_relation_formats(file, page_size, "RDB$TRIGGERS"),
    ) else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(file, page_size, "RDB$TRIGGERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(rn_f), Some(type_f), Some(seq_f)) = (
        fid("RDB$TRIGGER_NAME"),
        fid("RDB$RELATION_NAME"),
        fid("RDB$TRIGGER_TYPE"),
        fid("RDB$TRIGGER_SEQUENCE"),
    ) else {
        return Vec::new();
    };
    let mut trigs: Vec<(i64, i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(rn_f), table) {
            if let Some(Value::Text(t)) = v.get(name_f) {
                let ttype = match v.get(type_f) {
                    Some(Value::Int(n)) => *n,
                    _ => 0,
                };
                let seq = match v.get(seq_f) {
                    Some(Value::Int(n)) => *n,
                    _ => 0,
                };
                trigs.push((ttype, seq, t.trim_end().to_string()));
            }
        }
    });
    trigs.sort_by(|(_, s1, n1), (_, s2, n2)| s1.cmp(s2).then_with(|| n1.cmp(n2)));
    trigs.into_iter().map(|(_, _, n)| n).collect()
}

/// `ALTER TABLE <table> ADD <column>`: append one column to an existing
/// table. The engine models this as a new *format version* - existing
/// records keep their old format (and read the new column as NULL), new
/// records use the new one. The sequence mirrors the tail of
/// [create_table] for the single new field, plus a version rewrite of the
/// `RDB$RELATIONS` row to bump its `RDB$FORMAT` and field count.
pub fn alter_table_add_column(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col: &ColumnDef,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    // existing columns: reject a duplicate name, find the next field id
    let existing = relation_columns(file, page_size, &table);
    if existing
        .iter()
        .any(|c| c.name.eq_ignore_ascii_case(&col.name))
    {
        return Err(format!("column {} already exists", col.name));
    }
    let new_fid = existing.iter().map(|c| c.field_id + 1).max().unwrap_or(0);

    // the new full format: existing descriptors + the new field, offsets
    // recomputed by the same ini.epp walk (append-stable, so the existing
    // fields keep their offsets and the new one lands at the end)
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    // a computed column has no storage to constrain or default into
    if col.computed.is_some() && (col.not_null || col.default.is_some() || col.identity.is_some())
    {
        return Err(format!("computed column {} cannot carry constraints", col.name));
    }
    // existing COMPUTED fields (descriptor at offset 0) keep their
    // offset-0 descriptors through the recompute; the stored-offset walk
    // skips them, so existing stored fields keep their offsets and a new
    // stored field lands after the last stored one (probed: adding a
    // BIGINT to `(A INTEGER, C COMPUTED BY (A))` lands it at offset 8)
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field(col.dtype, col.length, col.scale, col.sub_type);
    fields.push((dt, l, s, st, col.computed.is_some()));
    let new_descs = compute_format_mixed(&fields);
    if new_descs.len() != fields.len() {
        return Err("format computation failed".into());
    }

    // locate the RDB$RELATIONS row and read its current format number
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table)
            .ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| -> Option<usize> {
        rel_cols
            .iter()
            .find(|c| c.name == name)
            .map(|c| c.field_id as usize)
    };
    let cur_vals = decode_record(&rel_image, rel_descs);
    let cur_format_no = match cur_vals.get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?) {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- write the new format version blob + RDB$FORMATS row ----------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- the new column's domain, RDB$FIELDS and RDB$RELATION_FIELDS --
    let domain_num = next_domain_number(file, page_size)?;
    let dom = format!("RDB${}", domain_num);
    let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&dom)),
        ("RDB$FIELD_TYPE", SysVal::I(col.field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(col))),
        ("RDB$FIELD_SCALE", SysVal::I(col.scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        // an auto-domain is owned by the table's owner (no security class)
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(col.field_type) {
        field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(col.sub_type as i64)));
    }
    if let Some(cl) = col.char_len {
        field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
        field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        field_vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
    }
    // a computed column: the verbatim `(expr)` source + compiled BLR +
    // the result type's precision, exactly as create_table writes them
    let computed_blobs = match &col.computed {
        Some(cp) => {
            let src =
                dml::insert_blob_cs(file, page_size, 2, &[cp.source.as_bytes().to_vec()], 1, 4)?;
            let blr = dml::insert_blob(file, page_size, 2, &[cp.blr.clone()], 2)?;
            Some((src, blr, cp.precision))
        }
        None => None,
    };
    if let Some((src, blr, precision)) = computed_blobs {
        field_vals.push(("RDB$COMPUTED_SOURCE", SysVal::B(blob_id_bytes(2, src))));
        field_vals.push(("RDB$COMPUTED_BLR", SysVal::B(blob_id_bytes(2, blr))));
        field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(precision as i64)));
    } else if let Some(p) = col.precision {
        // a plain added column's precision, same rule as create_table
        field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &field_vals)?;

    let rf_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&col.name)),
        ("RDB$RELATION_NAME", SysVal::S(&table)),
        ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
        ("RDB$FIELD_POSITION", SysVal::I(new_fid as i64)),
        // a computed column is read-only: RDB$UPDATE_FLAG 0 (probed)
        ("RDB$UPDATE_FLAG", SysVal::I(if col.computed.is_some() { 0 } else { 1 })),
        ("RDB$FIELD_ID", SysVal::I(new_fid as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
        // every built-in-typed column gets RDB$COLLATION_ID 0, text or not
        // (probed - the same as create_table's non-domain columns)
        ("RDB$COLLATION_ID", SysVal::I(0)),
    ];
    sys_insert(file, page_size, "RDB$RELATION_FIELDS", 5, &rf_vals)?;

    // --- rebuild RDB$RUNTIME for all fields (incl. the new one, now in
    // RDB$RELATION_FIELDS) so DSQL resolves the added column ------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT, RDB$FIELD_ID and RDB$RUNTIME in
    // place (a version rewrite of the row) -----------------------------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8)); // clear NULL bit (already set)
        Ok(())
    };
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$FIELD_ID", SysVal::I((new_fid + 1) as i64))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(
        file,
        page_size,
        6,
        &[(rel_page, rel_slot, rel_image)],
        rec_format,
    )?;

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// A field's `RDB$FIELD_LENGTH`: the byte length, which for a `VARCHAR` is
/// the character count, not the `+2` count-word storage length a
/// [ColumnDef]'s `length` carries. A `CHAR`'s length is already the count;
/// a non-text type has no `char_len` and uses `length` directly.
fn catalog_field_length(col: &ColumnDef) -> i64 {
    col.char_len.map(|c| c as i64).unwrap_or(col.length as i64)
}

/// `ALTER DOMAIN <old> TO <new>`: rename the domain's RDB$FIELDS row IN
/// PLACE and key the NEW name into the catalog's name index - the old
/// entry stays behind pointing at the live row with a stale key, the
/// same shape every engine update leaves until garbage collection, and
/// what validation demands is that the CURRENT key be findable
/// ([maintain_indexes]'s second caller). Every column using the domain
/// gets its RDB$FIELD_SOURCE patched (not an indexed column) and its
/// table's RDB$RUNTIME rebuilt - the summary quotes the source name, so
/// without the rebuild the engine would still resolve columns through
/// the OLD name (probed: the engine updates both on rename, and the
/// domain's DEFAULT keeps applying afterwards).
pub fn rename_domain(
    file: &mut crate::Image,
    page_size: usize,
    old: &str,
    new: &str,
) -> Result<(), String> {
    let old = old.trim().trim_matches('"').to_ascii_uppercase();
    let new = new.trim().trim_matches('"').to_ascii_uppercase();
    if old.starts_with("RDB$") || new.starts_with("RDB$") {
        return Err("system domains cannot be renamed".into());
    }
    if !domain_exists(file, page_size, &old) {
        return Err(format!("domain {} not found", old));
    }
    if domain_exists(file, page_size, &new) {
        return Err(format!("domain {} already exists", new));
    }

    // the RDB$FIELDS row: patch RDB$FIELD_NAME in place
    let formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (_, f_descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let f_descs = f_descs.clone();
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let name_fid = f_cols
        .iter()
        .find(|c| c.name == "RDB$FIELD_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$FIELD_NAME")?;
    let mut hit: Option<(u32, u16, Vec<u8>, u8)> = None;
    for dp_no in relation_data_pages(file, page_size, 2) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let vals = decode_record(&image, &f_descs);
            if text_eq(vals.get(name_fid), &old) {
                hit = Some((dp_no, r.slot, image, r.format));
            }
        }
    }
    let (page, slot, mut image, rec_format) = hit.ok_or("domain row not found")?;
    let d = f_descs.get(name_fid).ok_or("field beyond format")?;
    let bytes = encode_sys_value(d, &SysVal::S(&new))?;
    let at = d.offset as usize;
    image
        .get_mut(at..at + bytes.len())
        .ok_or("image shorter than format")?
        .copy_from_slice(&bytes);
    // key the RENAMED row into the catalog's indexes from its FULL
    // patched image - the name index is compound ((schema, name) at ODS
    // 14), so a name-only key would insert an entry the engine's DDL
    // lookup never finds (caught live: SELECT ... WHERE RDB$FIELD_NAME
    // found the row through the index while CREATE TABLE <domain> said
    // the domain did not exist)
    let key_values = decode_record(&image, &f_descs);
    dml::update_records(file, page_size, 2, &[(page, slot, image)], rec_format)?;

    let seq = u32_at(
        crate::page_at(file, page_size, page).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + slot as u64;
    maintain_indexes(file, page_size, 2, recno, &key_values, &f_descs)?;

    // every column whose RDB$FIELD_SOURCE is the domain: patch the source
    // (not an indexed column) and remember its table for a runtime rebuild
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_descs = rf_descs.clone();
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let src_fid = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let rel_fid = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let mut patches: Vec<(u32, u16, Vec<u8>, u8)> = Vec::new();
    let mut tables: Vec<String> = Vec::new();
    for dp_no in relation_data_pages(file, page_size, 5) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let vals = decode_record(&image, &rf_descs);
            if !text_eq(vals.get(src_fid), &old) {
                continue;
            }
            if let Some(Value::Text(t)) = vals.get(rel_fid) {
                let t = t.trim_end().to_string();
                if !tables.contains(&t) {
                    tables.push(t);
                }
            }
            patches.push((dp_no, r.slot, image, r.format));
        }
    }
    let sd = rf_descs.get(src_fid).ok_or("field beyond format")?;
    let sbytes = encode_sys_value(sd, &SysVal::S(&new))?;
    for (dp_no, slot, mut image, fmt) in patches {
        let at = sd.offset as usize;
        image
            .get_mut(at..at + sbytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&sbytes);
        // RDB$FIELD_SOURCE is INDEXED at ODS 14 (RDB$INDEX_3, and the
        // schema-qualified RDB$INDEX_61) - the patched row's new source
        // needs entries under its new key, like the rel-2 row above
        // (gfix: "missing entries for record n" otherwise, caught live)
        let key_values = decode_record(&image, &rf_descs);
        dml::update_records(file, page_size, 5, &[(dp_no, slot, image)], fmt)?;
        let seq = u32_at(
            crate::page_at(file, page_size, dp_no).ok_or("data page out of range")?,
            16,
        ) as u64;
        let recno = seq * max_recs_per_dp(page_size) + slot as u64;
        maintain_indexes(file, page_size, 5, recno, &key_values, &rf_descs)?;
    }
    for t in &tables {
        update_relation_runtime(file, page_size, t)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// Whether an `RDB$FIELDS` domain of this name exists.
fn domain_exists(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$FIELDS"),
        system_relation_formats(file, page_size, "RDB$FIELDS"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let name_f = match relation_columns(file, page_size, "RDB$FIELDS")
        .iter()
        .find(|c| c.name == "RDB$FIELD_NAME")
    {
        Some(c) => c.field_id as usize,
        None => return false,
    };
    let mut found = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), name) {
            found = true;
        }
    });
    found
}

/// Give `table` a NEW FORMAT VERSION with the fields at `fids` retyped
/// to `new_col`'s storage - the per-dependent-table half of an in-use
/// `ALTER DOMAIN TYPE` (the engine bumps every dependent table's format
/// by exactly one per statement, however many of its columns use the
/// domain - probed). The same repack-insert-rebuild-bump sequence the
/// column ALTER TYPE performs after its own guards: existing records
/// keep their old format and read back promoted.
fn reformat_for_retype(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fids: &[usize],
    new_col: &ColumnDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    // the new format: each dependent field's descriptor replaced, all
    // repacked; a COMPUTED field keeps its offset-0 descriptor
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field(new_col.dtype, new_col.length, new_col.scale, new_col.sub_type);
    for fid in fids {
        let f = fields
            .get_mut(*fid)
            .ok_or("dependent field beyond the format")?;
        if f.4 {
            return Err(format!("cannot retype a computed field of {}", table));
        }
        *f = (dt, l, s, st, false);
    }
    let new_descs = compute_format_mixed(&fields);

    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field =
        |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_format_no = match decode_record(&rel_image, rel_descs)
        .get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?)
    {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    let runtime = rebuild_runtime_blob(file, page_size, table, &new_descs)?;
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;
    Ok(())
}

/// Every table.column that uses a domain as its `RDB$FIELD_SOURCE`,
/// as (relation name, column name) pairs - what the ALTER DOMAIN TYPE
/// dependents guard walks.
fn domain_dependents(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Result<Vec<(String, String)>, String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let fn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let src_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_SOURCE")?;
    let mut out = Vec::new();
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(src_f), name) {
            if let (Some(Value::Text(t)), Some(Value::Text(c))) = (v.get(rn_f), v.get(fn_f)) {
                out.push((t.trim_end().to_string(), c.trim_end().to_string()));
            }
        }
    });
    Ok(out)
}

/// The first table.column that uses a domain as its `RDB$FIELD_SOURCE`
/// (None if the domain is unused) - a `DROP DOMAIN` is refused while it
/// is in use.
fn domain_user(file: &crate::Image, page_size: usize, name: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rn_f, src_f) = (fid("RDB$RELATION_NAME")?, fid("RDB$FIELD_SOURCE")?);
    let mut used = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if used.is_none() && text_eq(v.get(src_f), name) {
            if let Some(Value::Text(t)) = v.get(rn_f) {
                used = Some(t.trim_end().to_string());
            }
        }
    });
    used
}

/// `CREATE DOMAIN <name> [AS] <type> [NOT NULL]` - a standalone field
/// definition, one `RDB$FIELDS` row named by the user (no relation link,
/// no security class). The same row a table column's auto-domain gets,
/// with the user's name; `NOT NULL` sets `RDB$NULL_FLAG` on the domain
/// itself (a table column keeps its NOT NULL on `RDB$RELATION_FIELDS`).
pub fn create_domain(file: &mut crate::Image, page_size: usize, col: &ColumnDef) -> Result<(), String> {
    let name = col.name.trim().trim_matches('"').to_ascii_uppercase();
    if name.is_empty() {
        return Err("a domain needs a name".into());
    }
    if domain_exists(file, page_size, &name) {
        return Err(format!("Domain {} already exists", name));
    }
    // a user domain carries a security class and owner, like a sequence: the
    // SQL$<n> class holds the owner's alter/control/drop/usage ACL, and the
    // owner takes a USAGE ('G', object type 9) privilege row
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&name)),
        ("RDB$FIELD_TYPE", SysVal::I(col.field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(col))),
        ("RDB$FIELD_SCALE", SysVal::I(col.scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SECURITY_CLASS", SysVal::S(&class)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(col.field_type) {
        vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(col.sub_type as i64)));
    }
    if let Some(cl) = col.char_len {
        vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0))); // NONE
        vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
    }
    if let Some(p) = col.precision {
        // same rule as a table column's auto-domain: 0 for plain exact
        // ints, the declared p for NUMERIC/DECIMAL (probed on domains)
        vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
    }
    if col.not_null {
        vals.push(("RDB$NULL_FLAG", SysVal::I(1)));
    }
    // a domain DEFAULT lives on the domain's own RDB$FIELDS row (the source
    // text, subtype 1 charset 4 like a description, and the value BLR,
    // subtype 2) - the same two blobs a table column's default gets, but on
    // RDB$FIELDS (2) rather than RDB$RELATION_FIELDS (5). A column that then
    // uses the domain without its own default inherits this at insert time.
    if let Some(def) = &col.default {
        let src = dml::insert_blob_cs(file, page_size, 2, &[def.source.as_bytes().to_vec()], 1, 4)?;
        let val = dml::insert_blob(file, page_size, 2, &[def.value_blr.clone()], 2)?;
        vals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(2, src))));
        vals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(2, val))));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)?;
    store_privileges(file, page_size, &name, 9, &["G"])?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP DOMAIN <name>` - delete the `RDB$FIELDS` row. Refused while a
/// table column still uses the domain as its `RDB$FIELD_SOURCE`, or when
/// the domain does not exist.
pub fn drop_domain(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    if let Some(user) = domain_user(file, page_size, &want) {
        return Err(format!("Domain {} is used in table {}", want, user));
    }
    // the domain's security class and its owner privilege go with it (the
    // engine drops both), then the RDB$FIELDS row
    let class = domain_security_class(file, page_size, &want);
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| text_eq(v.get(name_f), &nm))?;
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
    let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
    let dn = want.clone();
    delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
        text_eq(v.get(rn_f), &dn) && matches!(v.get(ot_f), Some(Value::Int(9)))
    })?;
    advance_oldest_transactions(file, page_size)
}

/// A domain's `RDB$SECURITY_CLASS` off its `RDB$FIELDS` row (None if unset).
fn domain_security_class(file: &crate::Image, page_size: usize, dname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let sc_f = fid("RDB$SECURITY_CLASS")?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), dname) {
            if let Some(Value::Text(t)) = v.get(sc_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

/// `ALTER DOMAIN <name> SET DEFAULT <lit>` / `DROP DEFAULT` - set (or
/// replace, or clear) the default on the domain's own `RDB$FIELDS` row. A
/// SET writes the two blobs a `CREATE DOMAIN ... DEFAULT` writes
/// (`RDB$DEFAULT_SOURCE`, subtype 1 charset 4; `RDB$DEFAULT_VALUE`, the BLR,
/// subtype 2) and patches them in; a DROP (`default` = None) patches both to
/// NULL, leaving any prior blob orphaned - exactly as the engine does. A
/// column that uses the domain without its own default sees the change on its
/// next insert.
pub fn alter_domain_default(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    default: Option<&ColumnDefault>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    let (src_val, val_val) = match default {
        Some(def) => {
            let src =
                dml::insert_blob_cs(file, page_size, 2, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 2, &[def.value_blr.clone()], 2)?;
            (
                SysVal::B(blob_id_bytes(2, src)),
                SysVal::B(blob_id_bytes(2, val)),
            )
        }
        None => (SysVal::Null, SysVal::Null),
    };
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$FIELDS",
        2,
        move |v| text_eq(v.get(name_f), &nm),
        &[
            ("RDB$DEFAULT_SOURCE", src_val),
            ("RDB$DEFAULT_VALUE", val_val),
        ],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER DOMAIN <name> SET NOT NULL` / `DROP NOT NULL` - the nullability of a
/// domain, on its own `RDB$FIELDS` row. SET writes `RDB$NULL_FLAG` = 1, DROP
/// writes 0 (probe: a dropped constraint leaves the flag at 0, distinct from a
/// domain that never had one, whose flag is NULL). A column that uses the
/// domain inherits the constraint; the engine enforces it on the next insert.
///
/// This is the catalog write only: the engine additionally validates that no
/// existing row of any column using the domain is NULL before a SET, which an
/// offline writer over freshly-created (unused) domains never has to.
pub fn alter_domain_not_null(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    not_null: bool,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    let flag: i64 = if not_null { 1 } else { 0 };
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$FIELDS",
        2,
        move |v| text_eq(v.get(name_f), &nm),
        &[("RDB$NULL_FLAG", SysVal::I(flag))],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `RDB$FIELD_TYPE` -> dsc dtype, for the int and text families
/// [type_change_supported] understands (enough to widen a domain).
pub fn field_type_to_dtype(ft: i16) -> Option<u8> {
    use crate::format::dtype;
    Some(match ft {
        7 => dtype::SHORT,
        8 => dtype::LONG,
        16 => dtype::INT64,
        26 => dtype::INT128,
        10 => dtype::REAL,
        27 => dtype::DOUBLE,
        12 => dtype::SQL_DATE,
        13 => dtype::SQL_TIME,
        35 => dtype::TIMESTAMP,
        23 => dtype::BOOLEAN,
        14 => dtype::TEXT,
        37 => dtype::VARYING,
        _ => return None,
    })
}

/// A domain's current `(field_type, byte length, scale, sub_type)` off its
/// `RDB$FIELDS` row.
pub fn domain_type_info(file: &crate::Image, page_size: usize, name: &str) -> Option<(i16, u16, i8, i16)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let ft_f = fid("RDB$FIELD_TYPE")?;
    let len_f = fid("RDB$FIELD_LENGTH")?;
    let sc_f = fid("RDB$FIELD_SCALE")?;
    let sub_f = fid("RDB$FIELD_SUB_TYPE")?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), name) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            out = Some((
                geti(ft_f) as i16,
                geti(len_f) as u16,
                geti(sc_f) as i8,
                geti(sub_f) as i16,
            ));
        }
    });
    out
}

/// A user domain's full resolved type, for a column declared with it. The
/// descriptor pieces (dtype, dsc_length, scale, sub_type, char_len), plus the
/// domain's own `NOT NULL` and `DEFAULT` (which a column of the domain
/// inherits) - read once off the domain's `RDB$FIELDS` row.
pub struct DomainType {
    pub field_type: i16,
    pub dtype: u8,
    pub length: u16,
    pub scale: i8,
    pub sub_type: i16,
    pub char_len: Option<u16>,
    pub not_null: bool,
    pub default_blr: Option<Vec<u8>>,
}

fn resolve_domain_type(file: &crate::Image, page_size: usize, dname: &str) -> Option<DomainType> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let ft_f = fid("RDB$FIELD_TYPE")?;
    let len_f = fid("RDB$FIELD_LENGTH")?;
    let sc_f = fid("RDB$FIELD_SCALE")?;
    let sub_f = fid("RDB$FIELD_SUB_TYPE")?;
    let cl_f = fid("RDB$CHARACTER_LENGTH");
    let nf_f = fid("RDB$NULL_FLAG");
    let dv_f = fid("RDB$DEFAULT_VALUE");
    let mut found: Option<(i16, u16, i8, i16, Option<u16>, bool, Option<(u16, u64)>)> = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_none() && text_eq(v.get(name_f), dname) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            let char_len = cl_f.and_then(|f| match v.get(f) {
                Some(Value::Int(i)) => Some(*i as u16),
                _ => None,
            });
            let not_null = nf_f.map_or(false, |f| matches!(v.get(f), Some(Value::Int(1))));
            let def = dv_f.and_then(|f| match v.get(f) {
                Some(Value::Blob(r, n)) => Some((*r, *n)),
                _ => None,
            });
            found = Some((
                geti(ft_f) as i16,
                geti(len_f) as u16,
                geti(sc_f) as i8,
                geti(sub_f) as i16,
                char_len,
                not_null,
                def,
            ));
        }
    });
    let (field_type, byte_len, scale, sub_type, char_len, not_null, def) = found?;
    let dtype = field_type_to_dtype(field_type)?;
    // dsc_length: a VARYING carries its 2-byte count word, other types do not
    let length = if dtype == crate::format::dtype::VARYING {
        byte_len + 2
    } else {
        byte_len
    };
    let default_blr = def.and_then(|(r, n)| crate::format::read_blob_content(file, page_size, r, n));
    Some(DomainType {
        field_type,
        dtype,
        length,
        scale,
        sub_type,
        char_len,
        not_null,
        default_blr,
    })
}

/// `ALTER DOMAIN <name> TYPE <newtype>` - retype a domain in place on its
/// `RDB$FIELDS` row (`RDB$FIELD_TYPE` / `LENGTH` / `SCALE` / `SUB_TYPE`, and
/// `RDB$CHARACTER_LENGTH` for text). Only a widening this write path performs
/// (see [type_change_supported]) - a SMALLINT to a wider integer, a CHAR or
/// VARCHAR to a same-or-longer one; a narrowing errors, as the engine's does
/// ("must be at least N characters"). This is the unused-domain case:
/// fire-crab does not yet declare a domain-typed column, so there is no table
/// format to carry along.
pub fn alter_domain_type(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    new_col: &ColumnDef,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    let (old_ft, old_len, old_scale, old_sub) = domain_type_info(file, page_size, &want)
        .ok_or_else(|| format!("Domain {} not found", want))?;
    let old_dtype = field_type_to_dtype(old_ft)
        .ok_or("the domain's current type is not one this path retypes")?;
    // the old descriptor, in the same length convention new_col uses
    // (a VARYING's dsc_length carries the 2-byte count word)
    let old_dsc_len = if old_dtype == crate::format::dtype::VARYING {
        old_len + 2
    } else {
        old_len
    };
    let old_desc = Descriptor {
        dtype: old_dtype,
        scale: old_scale,
        length: old_dsc_len,
        sub_type: old_sub,
        flags: 0,
        offset: 0,
    };
    if !type_change_supported(&old_desc, new_col) {
        return Err(format!(
            "cannot change datatype for domain {}; conversion not supported",
            want
        ));
    }
    // the dependents guard, before any write. The engine's rule
    // (probed): a dependent column inside a FOREIGN KEY index refuses -
    // "Cannot modify index used by an Integrity Constraint" - while
    // PK/UNIQUE and plain-indexed dependents retype fine, each
    // dependent TABLE getting one new format version below.
    let deps = domain_dependents(file, page_size, &want)?;
    for (t, c) in &deps {
        if indices_containing(file, page_size, t, c)?.iter().any(|(_, fk)| *fk) {
            return Err("Cannot modify index used by an Integrity Constraint".into());
        }
    }
    // group the dependents by table and resolve their field ids now
    // (pure reads) - any unresolvable dependent refuses before a write
    let mut by_table: Vec<(String, Vec<usize>)> = Vec::new();
    for (t, c) in &deps {
        let cols = relation_columns(file, page_size, t);
        let fid = cols
            .iter()
            .find(|rc| rc.name.eq_ignore_ascii_case(c))
            .map(|rc| rc.field_id as usize)
            .ok_or_else(|| format!("dependent column {}.{} not found", t, c))?;
        match by_table.iter_mut().find(|(name, _)| name == t) {
            Some((_, fids)) => fids.push(fid),
            None => by_table.push((t.clone(), vec![fid])),
        }
    }
    // patch the domain's RDB$FIELDS row in place (mirror of the column
    // ALTER TYPE retype, minus the table format/runtime it does not have)
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let f_fid = |n: &str| f_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let f_name_fid = f_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let dom_pred = {
        let dom = want.clone();
        move |vals: &[Value]| text_eq(vals.get(f_name_fid), &dom)
    };
    let (fpage, fslot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred)
        .ok_or("RDB$FIELDS domain row not found")?;
    let f_formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (f_format_no, f_descs) = {
        let (n, d) = f_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let mut f_image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, fpage).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(fslot)
            .and_then(|r| r.image())
            .ok_or("no field image")?
    };
    let patch_field = |image: &mut [u8], nm: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = f_fid(nm).ok_or_else(|| format!("no {} column", nm))?;
        let d = f_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch_field(&mut f_image, "RDB$FIELD_TYPE", SysVal::I(new_col.field_type as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(new_col)))?;
    patch_field(&mut f_image, "RDB$FIELD_SCALE", SysVal::I(new_col.scale as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SUB_TYPE", SysVal::I(new_col.sub_type as i64))?;
    if let Some(p) = new_col.precision {
        // the engine retypes precision too (probed: INTEGER ->
        // NUMERIC(12) sets 12; int -> int keeps 0)
        patch_field(&mut f_image, "RDB$FIELD_PRECISION", SysVal::I(p as i64))?;
    }
    if let Some(cl) = new_col.char_len {
        patch_field(&mut f_image, "RDB$CHARACTER_LENGTH", SysVal::I(cl as i64))?;
    }
    dml::update_records(file, page_size, 2, &[(fpage, fslot, f_image)], f_format_no)?;
    // every dependent table gets ONE new format version with all its
    // domain-typed fields retyped (probed: one bump per table per
    // statement, old rows read back promoted)
    for (t, fids) in &by_table {
        reformat_for_retype(file, page_size, t, fids, new_col)?;
    }
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <table> DROP <column>`: remove a column. Like ADD, this is
/// a new *format version* - existing records keep their old format (and
/// still carry the dropped field's bytes, now unreferenced); the new
/// format keeps the field-id indexing (the survivors are NOT renumbered -
/// probe: dropping the middle of A/B/C leaves A=id0, C=id2, a hole at 1)
/// but replaces the dropped field's descriptor with a zero-length
/// placeholder and repacks the rest. The column's `RDB$RELATION_FIELDS`
/// row and its auto-domain are deleted, `RDB$RUNTIME` is rebuilt without
/// it, and `RDB$RELATIONS.RDB$FORMAT` is bumped (the field-id high-water,
/// `RDB$FIELD_ID`, is left as-is - the engine does not reuse ids).
///
/// This first slice drops a plain nullable, unindexed column; a NOT NULL
/// column, an indexed/key column, or the table's only column each error
/// (they need constraint or index teardown first).
pub fn alter_table_drop_column(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let col_up = col_name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    let cols = relation_columns(file, page_size, &table);
    let target = cols
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&col_up))
        .ok_or_else(|| format!("column {} not found", col_name))?;
    let drop_fid = target.field_id as usize;
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let is_computed =
        |fid: usize| matches!(cur_descs.get(fid), Some(d) if d.offset == 0 && d.length != 0);
    // the engine refuses a drop that leaves no STORED column - "can't
    // have relation with only computed fields or constraints" (probed;
    // subsumes the old only-column check)
    let stored_left = cols
        .iter()
        .filter(|c| c.field_id as usize != drop_fid && !is_computed(c.field_id as usize))
        .count();
    if stored_left == 0 {
        return Err("cannot drop: a table cannot have only computed fields".into());
    }
    // a stored column some computed expression references cannot go -
    // the engine counts dependencies and refuses (probed). An expression
    // whose BLR this writer cannot read is assumed to reference anything.
    if !is_computed(drop_fid) {
        for (cname, deps) in computed_dependencies(file, page_size, &table) {
            let depends = match deps {
                None => true,
                Some(names) => names.iter().any(|n| n.eq_ignore_ascii_case(&col_up)),
            };
            if depends {
                return Err(format!(
                    "cannot drop {}: computed column {} depends on it",
                    col_name, cname
                ));
            }
        }
    }
    // an indexed/key column would leave a dangling index - reject it
    if let Some(irt) = find_index_root(file, page_size, rel) {
        for e in irt.live_entries() {
            let (segs, _) =
                btw::index_segments(file, page_size, rel, e.id, e.key_count as usize)
                    .ok_or("unreadable index segments")?;
            if segs.iter().any(|(field, _)| *field as usize == drop_fid) {
                return Err(format!("column {} is indexed; drop the index first", col_name));
            }
        }
    }

    // the column's RDB$RELATION_FIELDS row: its slot, domain, null flag
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rf_rel = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let rf_name = rf_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rf_src = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let rf_null = rf_fid("RDB$NULL_FLAG");
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let matches_col = |vals: &[Value]| {
        text(vals.get(rf_rel)).as_deref() == Some(table.as_str())
            && text(vals.get(rf_name)).as_deref() == Some(col_up.as_str())
    };
    // read the domain + null flag before deleting the row
    let mut domain: Option<String> = None;
    let mut not_null = false;
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if matches_col(vals) {
            domain = text(vals.get(rf_src));
            if let Some(nf) = rf_null {
                not_null = matches!(vals.get(nf), Some(Value::Int(1)));
            }
        }
    });
    if not_null {
        return Err(format!("column {} is NOT NULL; not supported", col_name));
    }

    // the new format version: existing descriptors, the dropped field
    // replaced by a zero-length placeholder, the rest repacked. A
    // surviving COMPUTED field keeps its offset-0 descriptor (the walk
    // skips it); dropping the computed field itself leaves the same
    // all-zero placeholder a stored field would.
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    fields[drop_fid] = (0, 0, 0, 0, false); // dropped-field placeholder
    let mut new_descs = compute_format_mixed(&fields);
    // the placeholder itself is all-zero at offset 0 (dfw.epp), matching
    // the engine's format blob for a dropped field
    new_descs[drop_fid] = Descriptor {
        dtype: 0,
        scale: 0,
        length: 0,
        sub_type: 0,
        flags: 0,
        offset: 0,
    };
    // ... except at the TAIL: the engine truncates trailing dropped
    // placeholders from the new format (probed: dropping the LAST field
    // shrinks the descriptor count; only a mid-table hole keeps its
    // placeholder). RDB$RELATIONS.RDB$FIELD_ID - the next-id counter -
    // stays where it was either way.
    while matches!(new_descs.last(), Some(d) if d.dtype == 0 && d.length == 0) {
        new_descs.pop();
    }

    // current format number, for the bump
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_vals = decode_record(&rel_image, rel_descs);
    let cur_format_no = match cur_vals.get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?) {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- new format blob + RDB$FORMATS row ----------------------------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- delete the column's RDB$RELATION_FIELDS row and its domain ---
    let rf_slot = find_sys_row_slot(file, page_size, "RDB$RELATION_FIELDS", 5, matches_col)
        .ok_or("RDB$RELATION_FIELDS row not found")?;
    dml::delete_records(file, page_size, 5, &[rf_slot])?;
    if let Some(dom) = &domain {
        let dom_pred = |vals: &[Value]| {
            let f_fid = relation_columns(file, page_size, "RDB$FIELDS")
                .iter()
                .find(|c| c.name == "RDB$FIELD_NAME")
                .map(|c| c.field_id as usize);
            f_fid.and_then(|f| text(vals.get(f))).as_deref() == Some(dom.as_str())
        };
        if let Some(slot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred) {
            dml::delete_records(file, page_size, 2, &[slot])?;
        }
    }

    // --- rebuild RDB$RUNTIME (now omits the dropped field) ------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT and RDB$RUNTIME (field-id high-
    // water is left as-is: the engine does not reuse dropped ids) ------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The storage width of an integer dtype, for the widening check.
fn int_width(dt: u8) -> Option<u16> {
    use crate::format::dtype;
    match dt {
        dtype::SHORT => Some(2),
        dtype::LONG => Some(4),
        dtype::INT64 => Some(8),
        dtype::INT128 => Some(16),
        _ => None,
    }
}

/// Whether changing a column from `old` to `new` is a conversion this
/// write path performs. Deliberately a SUBSET of what the engine allows -
/// only clearly loss-free widenings, so fire-crab never *succeeds* where
/// the engine would reject (narrowing). An integer widens to a wider
/// integer (scale 0), a CHAR/VARCHAR widens to a same-or-longer one of
/// the same kind. Everything else errors, as the engine does for an
/// unsupported conversion.
/// The indices of `table` that have `col` among their segments, each as
/// (index name, is-a-FOREIGN-KEY index - its RDB$FOREIGN_KEY names a
/// partner).
fn indices_containing(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    col: &str,
) -> Result<Vec<(String, bool)>, String> {
    let irel =
        crate::resolve_relation(file, page_size, "RDB$INDICES").ok_or("no RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let ix_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let rn_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
    let fk_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$FOREIGN_KEY")?;
    let mut names: Vec<(String, bool)> = Vec::new();
    walk_rows(file, page_size, irel, descs, |values| {
        if text_eq(values.get(rn_f), table) {
            if let Some(Value::Text(t)) = values.get(ix_f) {
                let fk = matches!(values.get(fk_f),
                    Some(Value::Text(p)) if !p.trim_end().is_empty());
                names.push((t.trim_end().to_string(), fk));
            }
        }
    });
    let mut out = Vec::new();
    for (n, fk) in names {
        if index_segment_columns(file, page_size, &n)?
            .iter()
            .any(|c| c.eq_ignore_ascii_case(col))
        {
            out.push((n, fk));
        }
    }
    Ok(out)
}

/// TRUE when `col` is a segment of an index that an
/// `RDB$RELATION_CONSTRAINTS` row names - a PRIMARY KEY / UNIQUE /
/// FOREIGN KEY enforcement index. The engine refuses retyping such a
/// column: "Cannot update index segment used by an Integrity
/// Constraint" (probed: PK, UNIQUE-constraint and FK-child segments all
/// refuse, ANY segment of a multi-column key included, while a plain
/// CREATE INDEX column retypes fine).
fn column_in_constraint_index(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    col: &str,
) -> Result<bool, String> {
    let mine: Vec<String> = indices_containing(file, page_size, table, col)?
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    if mine.is_empty() {
        return Ok(false);
    }
    // ...and whether any of those backs a constraint
    let crel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS")?;
    let cformats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS format")?;
    let (_, cdescs) = cformats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cix_f = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$INDEX_NAME")?;
    let mut hit = false;
    walk_rows(file, page_size, crel, cdescs, |values| {
        if let Some(Value::Text(t)) = values.get(cix_f) {
            let t = t.trim_end();
            if mine.iter().any(|m| m.eq_ignore_ascii_case(t)) {
                hit = true;
            }
        }
    });
    Ok(hit)
}

fn type_change_supported(old: &Descriptor, new: &ColumnDef) -> bool {
    use crate::format::dtype;
    // integer family: same or wider, both scale 0
    if let (Some(ow), Some(nw)) = (int_width(old.dtype), int_width(new.dtype)) {
        return old.scale == 0 && new.scale == 0 && nw >= ow;
    }
    // text: same kind (CHAR or VARCHAR), same or longer
    match (old.dtype, new.dtype) {
        (dtype::TEXT, dtype::TEXT) | (dtype::VARYING, dtype::VARYING) => new.length >= old.length,
        _ => false,
    }
}

/// `ALTER TABLE <table> ALTER <column> TYPE <newtype>`: change a column's
/// type. Like ADD and DROP, a new *format version* - existing records keep
/// their old format (and their old-width value, which reads back promoted:
/// an `INTEGER` stored 4 bytes reads as the new `BIGINT`); new records use
/// the new format. The column keeps its field id, position and domain
/// name; the domain's `RDB$FIELDS` row is retyped IN PLACE (the engine does
/// the same - probe: `RDB$1` changed from type 8/len 4 to type 16/len 8),
/// `RDB$RUNTIME` is rebuilt for the new length, and `RDB$RELATIONS.RDB$FORMAT`
/// is bumped. Only a widening conversion (see [type_change_supported]) is
/// performed; anything else errors.
pub fn alter_table_alter_column_type(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
    new_col: &ColumnDef,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let col_up = col_name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    let cols = relation_columns(file, page_size, &table);
    let target = cols
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&col_up))
        .ok_or_else(|| format!("column {} not found", col_name))?;
    let fid = target.field_id as usize;

    // the current descriptors, and the conversion check against the field's
    // existing descriptor
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let old_desc = cur_descs.get(fid).ok_or("field beyond format")?;
    if !type_change_supported(old_desc, new_col) {
        return Err(format!(
            "cannot change datatype for {}; conversion not supported",
            col_name
        ));
    }
    // a column whose index enforces a PRIMARY KEY / UNIQUE / FOREIGN KEY
    // cannot be retyped - the engine's own refusal, mirrored
    if column_in_constraint_index(file, page_size, &table, &col_up)? {
        return Err(format!(
            "Cannot update index segment used by an Integrity Constraint ({})",
            col_up
        ));
    }

    // a computed column's type is its expression's - "cannot add or
    // remove COMPUTED from column" (probed refusal). Retyping a STORED
    // column is allowed even when a computed expression references it:
    // the engine keeps the computed column's declared type UNCHANGED
    // (probed: A INTEGER -> BIGINT leaves C COMPUTED BY (A) a LONG).
    if matches!(cur_descs.get(fid), Some(d) if d.offset == 0 && d.length != 0) {
        return Err(format!("cannot change the type of computed column {}", col_up));
    }
    // the new format: the target field's descriptor replaced, all
    // repacked; a COMPUTED field keeps its offset-0 descriptor
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field(new_col.dtype, new_col.length, new_col.scale, new_col.sub_type);
    fields[fid] = (dt, l, s, st, false);
    let new_descs = compute_format_mixed(&fields);

    // the column's domain (RDB$FIELD_SOURCE) - retyped in place
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rf_rel = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let rf_name = rf_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rf_src = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let mut domain: Option<String> = None;
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rf_rel)).as_deref() == Some(table.as_str())
            && text(vals.get(rf_name)).as_deref() == Some(col_up.as_str())
        {
            domain = text(vals.get(rf_src));
        }
    });
    let domain = domain.ok_or("column domain not found")?;

    // current format number
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_format_no = match decode_record(&rel_image, rel_descs)
        .get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?)
    {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- new format blob + RDB$FORMATS row ----------------------------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- retype the domain's RDB$FIELDS row in place ------------------
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let f_fid = |n: &str| f_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let f_name_fid = f_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let dom_pred = {
        let dom = domain.clone();
        move |vals: &[Value]| text(vals.get(f_name_fid)).as_deref() == Some(dom.as_str())
    };
    let (fpage, fslot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred)
        .ok_or("RDB$FIELDS domain row not found")?;
    let f_formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (f_format_no, f_descs) = {
        let (n, d) = f_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let mut f_image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, fpage).ok_or("bad page")?)
            .ok_or("bad data page")?;
        // `image()`, NOT `assembled_image` - ON PURPOSE. This reads a
        // record it is about to REWRITE IN PLACE, and a fragmented one
        // cannot be rewritten in place: its bytes live on several pages
        // and the pieces would have to be re-split. `image()` answers
        // None for a fragmented record, so this errors out instead of
        // patching the head and leaving the tail describing the old
        // shape. Refusing is the boundary; the other patch sites in this
        // file are the same, and the roadmap names them.
        dp.record(fslot).and_then(|r| r.image()).ok_or("no field image")?
    };
    let patch_field = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = f_fid(name).ok_or_else(|| format!("no {} column", name))?;
        let d = f_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch_field(&mut f_image, "RDB$FIELD_TYPE", SysVal::I(new_col.field_type as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_LENGTH", SysVal::I(new_col.length as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SCALE", SysVal::I(new_col.scale as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SUB_TYPE", SysVal::I(new_col.sub_type as i64))?;
    if let Some(p) = new_col.precision {
        // the engine retypes precision too (probed: INTEGER ->
        // NUMERIC(12) sets 12; int -> int keeps 0)
        patch_field(&mut f_image, "RDB$FIELD_PRECISION", SysVal::I(p as i64))?;
    }
    if let Some(cl) = new_col.char_len {
        patch_field(&mut f_image, "RDB$CHARACTER_LENGTH", SysVal::I(cl as i64))?;
    }
    dml::update_records(file, page_size, 2, &[(fpage, fslot, f_image)], f_format_no)?;

    // --- rebuild RDB$RUNTIME (the field's length changed) -------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT and RDB$RUNTIME ----------------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> SET DEFAULT <lit>` / `DROP DEFAULT` -
/// set, replace, or clear a column's default. Two blobs on the column's
/// `RDB$RELATION_FIELDS` row (`RDB$DEFAULT_SOURCE`, subtype 1 charset 4;
/// `RDB$DEFAULT_VALUE`, the literal BLR, subtype 2), then the relation's
/// `RDB$RUNTIME` is rebuilt so the engine applies (or stops applying) it -
/// the default the engine reads lives in that summary, not in the catalog
/// column ([rebuild_runtime_blob] re-reads `RDB$DEFAULT_VALUE`). No new
/// format version (the probe shows `RDB$FORMAT` unchanged); the row layout
/// does not move.
pub fn alter_column_default(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    default: Option<&ColumnDefault>,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let column = column.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let col_fid = relation_columns(file, page_size, &table)
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&column))
        .map(|c| c.field_id)
        .ok_or_else(|| format!("column {} not found in table {}", column, table))?;
    // the engine refuses a default change on a column inside a FOREIGN
    // KEY index ("cannot modify index used by an integrity constraint",
    // probed - a SET DEFAULT referential action reads the default
    // through that index's constraint; PK, UNIQUE and plain-indexed
    // columns all accept the change)
    if let Some(irt) = find_index_root(file, page_size, rel) {
        for e in irt.live_entries() {
            if e.flags & btw::IRT_FOREIGN == 0 {
                continue;
            }
            let (segs, _) = btw::index_segments(file, page_size, rel, e.id, e.key_count as usize)
                .ok_or("unreadable index segments")?;
            if segs.iter().any(|(field, _)| *field == col_fid) {
                return Err(format!(
                    "column {} is part of a FOREIGN KEY - its default cannot change",
                    column
                ));
            }
        }
    }
    let (src_val, val_val) = match default {
        Some(def) => {
            let src =
                dml::insert_blob_cs(file, page_size, 5, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 5, &[def.value_blr.clone()], 2)?;
            (
                SysVal::B(blob_id_bytes(5, src)),
                SysVal::B(blob_id_bytes(5, val)),
            )
        }
        None => (SysVal::Null, SysVal::Null),
    };
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_eq(v.get(rel_fid), &t) && text_eq(v.get(name_fid), &c),
        &[
            ("RDB$DEFAULT_SOURCE", src_val),
            ("RDB$DEFAULT_VALUE", val_val),
        ],
    )?;
    // rebuild the runtime so the engine applies (or stops applying) the default
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// The identity generator backing a column - its `RDB$GENERATOR_NAME` when
/// `RDB$IDENTITY_TYPE` is set - or None if the column is not an identity column.
fn column_identity_generator(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rel_f, name_f, gen_f, idt_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$FIELD_NAME")?,
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$IDENTITY_TYPE")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(rel_f), table) && text_eq(v.get(name_f), column) {
            if matches!(v.get(idt_f), Some(Value::Int(_))) {
                if let Some(Value::Text(g)) = v.get(gen_f) {
                    out = Some(g.trim_end().to_string());
                }
            }
        }
    });
    out
}

/// A generator's `(RDB$GENERATOR_ID, RDB$GENERATOR_INCREMENT,
/// RDB$INITIAL_VALUE)`.
fn generator_incr_init(file: &crate::Image, page_size: usize, name: &str) -> Option<(i64, i64, i64)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, inc_f, init_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$GENERATOR_ID")?,
        fid("RDB$GENERATOR_INCREMENT")?,
        fid("RDB$INITIAL_VALUE")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), name) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            out = Some((geti(id_f), geti(inc_f), geti(init_f)));
        }
    });
    out
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> RESTART [WITH <n>]` - reposition an
/// identity column's generator. `RESTART WITH n` primes it to yield `n` next
/// (stored `n - increment`); a bare `RESTART` uses the generator's
/// `RDB$INITIAL_VALUE`. Neither changes the catalog (`RDB$INITIAL_VALUE` and
/// the increment stay); only the generator's stored value moves.
pub fn alter_column_restart(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    with_value: Option<i64>,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let column = column.trim().trim_matches('"').to_ascii_uppercase();
    let gen = column_identity_generator(file, page_size, &table, &column)
        .ok_or_else(|| format!("column {} is not an identity column", column))?;
    let (id, increment, initial) = generator_incr_init(file, page_size, &gen)
        .ok_or_else(|| format!("identity generator {} not found", gen))?;
    let target = with_value.unwrap_or(initial);
    gen::write(file, page_size, id, target.wrapping_sub(increment))?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> SET GENERATED { ALWAYS | BY DEFAULT }` -
/// change an identity column's `RDB$IDENTITY_TYPE` (0 ALWAYS / 1 BY DEFAULT).
/// The generator and its value are untouched; the relation's `RDB$RUNTIME` is
/// rebuilt so the runtime's identity-type segment (23) follows.
pub fn alter_column_set_generated(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    identity_type: i16,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let column = column.trim().trim_matches('"').to_ascii_uppercase();
    if column_identity_generator(file, page_size, &table, &column).is_none() {
        return Err(format!("column {} is not an identity column", column));
    }
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_eq(v.get(rel_fid), &t) && text_eq(v.get(name_fid), &c),
        &[("RDB$IDENTITY_TYPE", SysVal::I(identity_type as i64))],
    )?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> DROP IDENTITY` - make an identity
/// column an ordinary one. The column's `RDB$IDENTITY_TYPE` and
/// `RDB$GENERATOR_NAME` are cleared (its `RDB$NULL_FLAG` stays - the column
/// remains NOT NULL), the implicit generator and its security class and
/// privilege rows are dropped, and the runtime is rebuilt (which drops the
/// identity segments 22/23 but keeps the not-null, since the RF row still
/// carries the flag).
pub fn alter_column_drop_identity(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let column = column.trim().trim_matches('"').to_ascii_uppercase();
    let gen = column_identity_generator(file, page_size, &table, &column)
        .ok_or_else(|| format!("column {} is not an identity column", column))?;
    let class = find_generator(file, page_size, &gen).and_then(|(_, _, c)| c);
    // clear the column's identity metadata (leave RDB$NULL_FLAG as-is)
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_eq(v.get(rel_fid), &t) && text_eq(v.get(name_fid), &c),
        &[
            ("RDB$IDENTITY_TYPE", SysVal::Null),
            ("RDB$GENERATOR_NAME", SysVal::Null),
        ],
    )?;
    // drop the generator, its security class and its privilege rows
    let gname_f = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
    let g = gen.clone();
    delete_catalog_rows(file, page_size, "RDB$GENERATORS", move |v| {
        text_eq(v.get(gname_f), &g)
    })?;
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
    let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
    let g2 = gen.clone();
    delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
        text_eq(v.get(rn_f), &g2) && matches!(v.get(ot_f), Some(Value::Int(14)))
    })?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> POSITION <n>` - move a column to the
/// 1-based display position `n`. Only `RDB$FIELD_POSITION` moves (and the
/// runtime's positions follow); the field ids, the record format and the
/// stored bytes are untouched - reordering is a display change, not a storage
/// one.
pub fn alter_column_position(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    new_pos: i64,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let column = column.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let cols = relation_columns(file, page_size, &table);
    let ncols = cols.len();
    // the engine errors on a position below 1, but a position past the last
    // column is clamped to the last (the column moves to the end)
    if new_pos < 1 {
        return Err(format!("column position {} is out of range", new_pos));
    }
    let to = ((new_pos - 1) as usize).min(ncols - 1);
    // the current order, by position; move the target to `to`
    let mut order: Vec<(String, u16)> =
        cols.iter().map(|c| (c.name.clone(), c.position)).collect();
    order.sort_by_key(|(_, p)| *p);
    let from = order
        .iter()
        .position(|(n, _)| n.eq_ignore_ascii_case(&column))
        .ok_or_else(|| format!("column {} not found in table {}", column, table))?;
    if from == to {
        return advance_oldest_transactions(file, page_size);
    }
    let item = order.remove(from);
    order.insert(to, item);
    // patch the RDB$FIELD_POSITION of each column whose position moved
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    for (new_p, (name, old_p)) in order.iter().enumerate() {
        if new_p as u16 == *old_p {
            continue;
        }
        let (t, c) = (table.clone(), name.clone());
        patch_sys_row(
            file,
            page_size,
            "RDB$RELATION_FIELDS",
            5,
            move |v| text_eq(v.get(rel_fid), &t) && text_eq(v.get(name_fid), &c),
            &[("RDB$FIELD_POSITION", SysVal::I(new_p as i64))],
        )?;
    }
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// Whether any committed primary record of `rel` has a NULL in field
/// `fid` - the check `SET NOT NULL` makes before it can succeed.
fn column_has_nulls(file: &crate::Image, page_size: usize, rel: u16, fid: usize) -> bool {
    let formats = crate::relation_formats(file, page_size, rel);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let descs = formats
                .iter()
                .find(|(n, _)| *n == r.format)
                .or_else(|| formats.iter().max_by_key(|(n, _)| *n));
            let Some((_, descs)) = descs else { continue };
            let vals = decode_record(&image, descs);
            if matches!(vals.get(fid), Some(Value::Null) | None) {
                return true;
            }
        }
    }
    false
}

/// Set (or clear) the `RDB$NULL_FLAG` of a column's `RDB$RELATION_FIELDS`
/// row in place: `Some(1)` for NOT NULL, `None` to make it nullable again.
fn patch_rf_null_flag(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_up: &str,
    flag: Option<i64>,
) -> Result<(), String> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (rf_format_no, rf_descs) = {
        let (n, d) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rel_fid = fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let name_fid = fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let null_fid = fid("RDB$NULL_FLAG").ok_or("no RDB$NULL_FLAG")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let pred = |vals: &[Value]| {
        text(vals.get(rel_fid)).as_deref() == Some(table)
            && text(vals.get(name_fid)).as_deref() == Some(col_up)
    };
    let (page, slot) = find_sys_row_slot(file, page_size, "RDB$RELATION_FIELDS", 5, pred)
        .ok_or("RDB$RELATION_FIELDS row not found")?;
    let mut image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(slot).and_then(|r| r.image()).ok_or("no field image")?
    };
    let d = rf_descs.get(null_fid).ok_or("field beyond format")?;
    let at = d.offset as usize;
    match flag {
        Some(v) => {
            let bytes = encode_sys_value(d, &SysVal::I(v))?;
            image
                .get_mut(at..at + bytes.len())
                .ok_or("image shorter than format")?
                .copy_from_slice(&bytes);
            image[null_fid / 8] &= !(1 << (null_fid % 8)); // not NULL
        }
        None => {
            image[null_fid / 8] |= 1 << (null_fid % 8); // NULL
        }
    }
    dml::update_records(file, page_size, 5, &[(page, slot, image)], rf_format_no)?;
    Ok(())
}

/// Rebuild `RDB$RUNTIME` and repoint the `RDB$RELATIONS` row at it - after
/// a change to a field's not-null status, so the engine's DSQL metadata
/// carries the RSR_field_not_null marker. The format is NOT bumped (a
/// NOT NULL constraint changes no record layout).
fn refresh_runtime(file: &mut crate::Image, page_size: usize, table: &str) -> Result<(), String> {
    let formats = crate::relation_formats(
        file,
        page_size,
        crate::resolve_relation(file, page_size, table).ok_or("table not found")?,
    );
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let runtime = rebuild_runtime_blob(file, page_size, table, &descs)?;
    let (page, slot, mut image, rec_format) =
        find_relations_row(file, page_size, table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = cols
        .iter()
        .find(|c| c.name == "RDB$RUNTIME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$RUNTIME")?;
    let d = rel_descs.get(fid).ok_or("field beyond format")?;
    let bytes = encode_sys_value(d, &SysVal::B(blob_id_bytes(6, runtime)))?;
    let at = d.offset as usize;
    image
        .get_mut(at..at + bytes.len())
        .ok_or("image shorter than format")?
        .copy_from_slice(&bytes);
    image[fid / 8] &= !(1 << (fid % 8));
    dml::update_records(file, page_size, 6, &[(page, slot, image)], rec_format)?;
    Ok(())
}

/// `ALTER TABLE <table> ALTER <column> SET NOT NULL`: add a NOT NULL
/// constraint. No new format version (the layout is unchanged); the
/// column's `RDB$RELATION_FIELDS.RDB$NULL_FLAG` is set, an
/// `RDB$RELATION_CONSTRAINTS` "NOT NULL" row and its `RDB$CHECK_CONSTRAINTS`
/// link (trigger_name = the column) are written, and `RDB$RUNTIME` is
/// refreshed so the engine enforces it. Fails - as the engine does - if
/// the column already holds a NULL.
pub fn alter_table_set_not_null(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let col_up = col_name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let target = relation_columns(file, page_size, &table)
        .into_iter()
        .find(|c| c.name.eq_ignore_ascii_case(&col_up))
        .ok_or_else(|| format!("column {} not found", col_name))?;
    if column_has_nulls(file, page_size, rel, target.field_id as usize) {
        return Err(format!(
            "cannot make field {} NOT NULL because there are NULLs present",
            col_name
        ));
    }
    patch_rf_null_flag(file, page_size, &table, &col_up, Some(1))?;
    let integ = next_numeric_suffix(
        file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", "INTEG_",
    )?;
    let cname = format!("INTEG_{}", integ);
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("NOT NULL")),
        ("RDB$RELATION_NAME", SysVal::S(&table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$TRIGGER_NAME", SysVal::S(&col_up)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    refresh_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ALTER <column> DROP NOT NULL`: remove the NOT NULL
/// constraint - clear the column's `RDB$NULL_FLAG`, delete the
/// `RDB$RELATION_CONSTRAINTS`/`RDB$CHECK_CONSTRAINTS` rows, refresh runtime.
pub fn alter_table_drop_not_null(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let col_up = col_name.trim().trim_matches('"').to_ascii_uppercase();
    crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if !relation_columns(file, page_size, &table)
        .iter()
        .any(|c| c.name.eq_ignore_ascii_case(&col_up))
    {
        return Err(format!("column {} not found", col_name));
    }

    // the constraint name: the RDB$CHECK_CONSTRAINTS row whose
    // RDB$TRIGGER_NAME is this column (a NOT NULL links that way)
    let cc_formats = system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS")
        .ok_or("no RDB$CHECK_CONSTRAINTS format")?;
    let (_, cc_descs) = cc_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cc_cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let cc_fid = |n: &str| cc_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let cc_name = cc_fid("RDB$CONSTRAINT_NAME").ok_or("no RDB$CONSTRAINT_NAME")?;
    let cc_trig = cc_fid("RDB$TRIGGER_NAME").ok_or("no RDB$TRIGGER_NAME")?;
    let cc_rel = crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS")
        .ok_or("no RDB$CHECK_CONSTRAINTS")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let mut constraint: Option<String> = None;
    walk_rows(file, page_size, cc_rel, cc_descs, |vals| {
        if text(vals.get(cc_trig)).as_deref() == Some(col_up.as_str()) {
            constraint = text(vals.get(cc_name));
        }
    });
    let constraint = constraint
        .ok_or_else(|| format!("column {} has no NOT NULL constraint", col_name))?;

    patch_rf_null_flag(file, page_size, &table, &col_up, None)?;

    // delete the RDB$CHECK_CONSTRAINTS row (by trigger = column)
    let cc_pred = |vals: &[Value]| text(vals.get(cc_trig)).as_deref() == Some(col_up.as_str());
    if let Some(slot) = find_sys_row_slot(file, page_size, "RDB$CHECK_CONSTRAINTS", cc_rel, cc_pred) {
        dml::delete_records(file, page_size, cc_rel, &[slot])?;
    }
    // delete the RDB$RELATION_CONSTRAINTS row (by constraint name)
    let rc_rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS")?;
    let rc_cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let rc_name = rc_cols
        .iter()
        .find(|c| c.name == "RDB$CONSTRAINT_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$CONSTRAINT_NAME")?;
    let rc_pred = |vals: &[Value]| text(vals.get(rc_name)).as_deref() == Some(constraint.as_str());
    if let Some(slot) =
        find_sys_row_slot(file, page_size, "RDB$RELATION_CONSTRAINTS", rc_rel, rc_pred)
    {
        dml::delete_records(file, page_size, rc_rel, &[slot])?;
    }
    refresh_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// CREATE TABLE: the full engine sequence against the file image.
/// Errors leave the caller's copy to be discarded - the statement
/// failed, nothing half-created survives.
/// The `nonnull_validation_blr` bytes DdlNodes.epp stores in the
/// runtime blob's RSR_field_not_null segment (probe-copied verbatim).
const NONNULL_BLR: [u8; 8] = [5, 59, 61, 24, 0, 0, 0, 76];

/// A foreign key's referential action for `ON UPDATE` / `ON DELETE`.
/// `NO ACTION` and `RESTRICT` both store `RESTRICT` and generate no
/// trigger, so they collapse to [RefAction::Restrict]. `CASCADE` and
/// `SET NULL` each synthesise a trigger.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RefAction {
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

impl RefAction {
    /// The `RDB$UPDATE_RULE` / `RDB$DELETE_RULE` string the engine stores.
    fn rule(self) -> &'static str {
        match self {
            RefAction::Restrict => "RESTRICT",
            RefAction::Cascade => "CASCADE",
            RefAction::SetNull => "SET NULL",
            RefAction::SetDefault => "SET DEFAULT",
        }
    }
}

/// One `FOREIGN KEY (<columns>) REFERENCES <ref_table> [(<ref_columns>)]
/// [ON UPDATE <action>] [ON DELETE <action>]` clause of a CREATE TABLE.
/// `name` is the constraint name (also the FK index name, as the engine
/// names them the same).
#[derive(Clone)]
pub struct ForeignKeyDef {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_update: RefAction,
    pub on_delete: RefAction,
}

pub fn create_table(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    cols: &[ColumnDef],
    constraints: &[TableConstraint],
    fks: &[ForeignKeyDef],
    relation_type: i64,
) -> Result<(), String> {
    if cols.is_empty() {
        return Err("a table needs at least one column".into());
    }
    // a computed column has no storage to constrain, default or generate
    // into - the parser refuses these combinations; this is the writer's
    // own line of defence
    for c in cols {
        if c.computed.is_some()
            && (c.not_null || c.default.is_some() || c.identity.is_some() || c.domain.is_some())
        {
            return Err(format!("computed column {} cannot carry constraints", c.name));
        }
    }
    let name = name.trim().to_ascii_uppercase();

    // relation id: one past the highest in RDB$RELATIONS (user ids
    // start at 128; every real database's system rels reach far below)
    let rels = list_relations(file, page_size);
    if rels
        .iter()
        .any(|(_, n)| n.trim_end().eq_ignore_ascii_case(&name))
    {
        return Err(format!("table {} already exists", name));
    }
    let rel_id_u16 = rels.iter().map(|(id, _)| *id).max().unwrap_or(127).max(127) + 1;
    let rel_id = rel_id_u16 as i64;

    // resolve each column's source (its RDB$FIELD_SOURCE): a per-table
    // auto-domain RDB$<n> for a built-in type, or the user domain it names.
    // A domain column's type is filled from the domain's RDB$FIELDS row, and
    // it inherits the domain's DEFAULT and NOT NULL (both applied via the
    // runtime, not the column's own catalog row). The auto-domain counter
    // advances only for built-in columns, so with no domain columns the
    // source names are byte-identical to before.
    let domain_base = next_domain_number(file, page_size)?;
    // identity columns get an implicit RDB$<n> generator, named from a
    // separate counter (over RDB$GENERATORS); the generator itself is written
    // after the table's security classes, but its name is needed on the field
    // row now
    let gen_base = next_generator_number(file, page_size);
    let mut resolved: Vec<ColumnDef> = Vec::with_capacity(cols.len());
    // per column: (source name, is_domain, inherited default BLR, inherited not_null)
    let mut src_meta: Vec<(String, bool, Option<Vec<u8>>, bool)> = Vec::with_capacity(cols.len());
    // per column: the identity generator name and its definition, if any
    let mut identity_meta: Vec<Option<(String, IdentityDef)>> = Vec::with_capacity(cols.len());
    let mut auto_idx: u64 = 0;
    let mut gen_idx: u64 = 0;
    for c in cols {
        if let Some(dname) = &c.domain {
            let dname = dname.trim().trim_matches('"').to_ascii_uppercase();
            let dt = resolve_domain_type(file, page_size, &dname)
                .ok_or_else(|| format!("Domain {} is not defined", dname))?;
            let mut rc = c.clone();
            rc.field_type = dt.field_type;
            rc.dtype = dt.dtype;
            rc.length = dt.length;
            rc.scale = dt.scale;
            rc.sub_type = dt.sub_type;
            rc.char_len = dt.char_len;
            resolved.push(rc);
            src_meta.push((dname, true, dt.default_blr, dt.not_null));
            identity_meta.push(None);
        } else {
            resolved.push(c.clone());
            src_meta.push((format!("RDB${}", domain_base + auto_idx), false, None, false));
            auto_idx += 1;
            match &c.identity {
                Some(id) => {
                    identity_meta.push(Some((format!("RDB${}", gen_base + gen_idx), id.clone())));
                    gen_idx += 1;
                }
                None => identity_meta.push(None),
            }
        }
    }
    let cols: &[ColumnDef] = &resolved;

    // the physical format: field ids in declaration order (probe-pinned),
    // offsets by the ini.epp walk sysfmt already implements. A computed
    // column keeps its declaration-order field id but no storage - its
    // descriptor carries the result type at offset 0.
    let fields: Vec<(u8, u16, i8, i16, bool)> = cols
        .iter()
        .map(|c| {
            let (dt, l, s, st) = col_field(c.dtype, c.length, c.scale, c.sub_type);
            (dt, l, s, st, c.computed.is_some())
        })
        .collect();
    let descs = compute_format_mixed(&fields);
    if descs.len() != cols.len() {
        return Err("format computation failed".into());
    }

    // --- pages first (DPM_create_relation): pointer + index root ------
    let pointer_page = dml::allocate_page(file, page_size)?;
    let root_page = dml::allocate_page(file, page_size)?;
    {
        let page = crate::page_mut(file, page_size, pointer_page).expect("pointer page out of range");
        page.fill(0);
        page[0] = 4; // pag_pointer
        page[1] = 1; // pag_flags = ppg_eof (last pointer page)
        dml::put_u32(page, 12, pointer_page); // pag_pageno
        dml::put_u16(page, 26, rel_id_u16); // ppg_relation @26
    }
    {
        let page = crate::page_mut(file, page_size, root_page).expect("root page out of range");
        page.fill(0);
        page[0] = 6; // pag_root
        dml::put_u32(page, 12, root_page); // pag_pageno
        dml::put_u16(page, 16, rel_id_u16); // irt_relation @16
        dml::put_u16(page, 18, 0); // irt_count
    }

    // --- the format descriptor blob (makeFormat) ---------------------
    let fmt_blob = write_format_blob(file, page_size, &descs)?;

    // CHECK constraints: each takes a PAIR of CHECK_<n> triggers
    // (before-insert, before-update), numbered from the engine's
    // RDB$TRIGGER_NAME generator NOW so the runtime summary below can
    // name them - a trigger absent from RDB$RUNTIME never fires
    let mut check_names: Vec<(String, String)> = Vec::new();
    {
        let n_checks = constraints
            .iter()
            .filter(|c| matches!(c, TableConstraint::Check(_)))
            .count();
        if n_checks > 0 {
            let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
                .ok_or("no RDB$TRIGGER_NAME generator")?;
            for _ in 0..n_checks {
                let a = gen::bump(file, page_size, slot, 1)?;
                let b = gen::bump(file, page_size, slot, 1)?;
                check_names.push((format!("CHECK_{}", a), format!("CHECK_{}", b)));
            }
        }
    }

    // --- the RDB$RUNTIME field summary (make_version): per field the
    // probe-pinned tag sequence ------------------------------------------
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, dom_default, dom_not_null) = &src_meta[i];
        runtime.push(seg(0, &(i as u16).to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, c.name.as_bytes())); // RSR_field_name
        let src = format!("\"PUBLIC\".\"{}\"", source);
        runtime.push(seg(25, src.as_bytes())); // RSR_field_source
        // RSR_field_length is the byte (declared) length, not the storage
        // length a VARYING carries in the format descriptor
        runtime.push(seg(19, &(catalog_field_length(c) as u16).to_le_bytes()));
        if let Some(cl) = c.char_len {
            runtime.push(seg(26, &cl.to_le_bytes())); // RSR_character_length
        }
        // a computed field's expression BLR (RSR_computed_blr = 4) sits
        // between the length and position segments (probed byte order)
        if let Some(cp) = &c.computed {
            runtime.push(seg(4, &cp.blr));
        }
        runtime.push(seg(27, &(i as u16).to_le_bytes())); // RSR_field_pos
        // the field DEFAULT (RSR_default_value = 6): the engine reads a
        // field's default from this runtime entry, not from the catalog
        // column. A column-level default wins; a domain column with none
        // inherits the domain's.
        let default_blr: Option<&[u8]> = c
            .default
            .as_ref()
            .map(|d| d.value_blr.as_slice())
            .or(if *is_domain { dom_default.as_deref() } else { None });
        if let Some(blr) = default_blr {
            runtime.push(seg(6, blr));
        }
        // NOT NULL: a column-level NOT NULL, or (for a domain column) the
        // domain's own NOT NULL, or (implicitly) an identity column
        let identity = identity_meta[i].as_ref();
        let not_null = c.not_null || (*is_domain && *dom_not_null) || identity.is_some();
        if not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
        // an identity field names its generator (RSR_field_generator = 22)
        // and its identity type (RSR_field_identity_type = 23, a 2-byte type)
        if let Some((gen_name, id)) = identity {
            runtime.push(seg(22, gen_name.as_bytes()));
            runtime.push(seg(23, &(id.identity_type as u16).to_le_bytes()));
        }
    }
    // the CHECK triggers' names (RSR_trigger_name = 9) in the engine's
    // runtime order: (sequence, then name lexically) - check triggers
    // are all sequence 0, so lexically
    let mut tnames: Vec<&str> = check_names
        .iter()
        .flat_map(|(a, b)| [a.as_str(), b.as_str()])
        .collect();
    tnames.sort();
    for t in &tnames {
        runtime.push(seg(9, t.as_bytes()));
    }
    let runtime_blob = dml::insert_blob(file, page_size, 6, &runtime, 5)?;

    // --- catalog rows, each with its indexes maintained ---------------
    // the auto-domain RDB$FIELDS row - only for a built-in-typed column; a
    // domain column's RDB$FIELDS row already exists (the domain itself)
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, _, _) = &src_meta[i];
        if *is_domain {
            continue;
        }
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(source)),
            ("RDB$FIELD_TYPE", SysVal::I(c.field_type as i64)),
            ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(c))),
            ("RDB$FIELD_SCALE", SysVal::I(c.scale as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            // an auto-domain is owned by the table's owner (no security class)
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if subtype_carried(c.field_type) {
            vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(c.sub_type as i64)));
        }
        if let Some(cl) = c.char_len {
            vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0))); // NONE
            vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
        // a computed field: the verbatim `(expr)` source, the compiled
        // BLR, and the result type's precision (source before value, the
        // DEFAULT blob order). The blobs belong to RDB$FIELDS (rel 2)
        let computed_blobs = match &c.computed {
            Some(cp) => {
                let src = dml::insert_blob_cs(
                    file, page_size, 2, &[cp.source.as_bytes().to_vec()], 1, 4,
                )?;
                let blr = dml::insert_blob(file, page_size, 2, &[cp.blr.clone()], 2)?;
                Some((src, blr, cp.precision))
            }
            None => None,
        };
        if let Some((src, blr, precision)) = computed_blobs {
            vals.push(("RDB$COMPUTED_SOURCE", SysVal::B(blob_id_bytes(2, src))));
            vals.push(("RDB$COMPUTED_BLR", SysVal::B(blob_id_bytes(2, blr))));
            vals.push(("RDB$FIELD_PRECISION", SysVal::I(precision as i64)));
        } else if let Some(p) = c.precision {
            // a plain declared column's precision: 0 for the exact-int
            // family, the declared p for NUMERIC/DECIMAL (probed)
            vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
        }
        sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)?;
    }
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, _, _) = &src_meta[i];
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&c.name)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$FIELD_SOURCE", SysVal::S(source)),
            ("RDB$FIELD_POSITION", SysVal::I(i as i64)),
            // a computed column is read-only: RDB$UPDATE_FLAG 0 (probed)
            ("RDB$UPDATE_FLAG", SysVal::I(if c.computed.is_some() { 0 } else { 1 })),
            ("RDB$FIELD_ID", SysVal::I(i as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        // RDB$COLLATION_ID on the RELATION_FIELDS row: 0 for a built-in
        // column (its collation is the relation field's own), NULL for a
        // domain column (the collation is the domain's) - probe: an INTEGER
        // built-in column has 0 too, so this is not a text-only attribute
        if !is_domain {
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
        // a COLUMN-level NOT NULL / DEFAULT lands on the RDB$RELATION_FIELDS
        // row (for a built-in or a domain column alike); a domain column with
        // neither inherits them from the domain, so its row carries neither -
        // the engine keeps those on the domain's RDB$FIELDS row
        // an identity column is implicitly NOT NULL (no INTEG constraint row)
        if c.not_null || identity_meta[i].is_some() {
            vals.push(("RDB$NULL_FLAG", SysVal::I(1)));
        }
        if let Some(def) = &c.default {
            let src =
                dml::insert_blob_cs(file, page_size, 5, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 5, &[def.value_blr.clone()], 2)?;
            vals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(5, src))));
            vals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(5, val))));
        }
        // an identity column names its implicit generator and its type
        if let Some((gen_name, id)) = &identity_meta[i] {
            vals.push(("RDB$GENERATOR_NAME", SysVal::S(gen_name)));
            vals.push(("RDB$IDENTITY_TYPE", SysVal::I(id.identity_type as i64)));
        }
        sys_insert(file, page_size, "RDB$RELATION_FIELDS", 5, &vals)?;
    }
    // the security catalog: the relation's own class and the class its
    // fields default to, each with the owner's ACL, then the owner's
    // five privileges. Both class NAMES come from counters the engine
    // does not re-check, so they are taken by advancing them.
    let class = next_security_class(file, page_size, ACL_TABLE_OWNER)?;
    let default_class = next_default_class(file, page_size)?;
    sys_insert(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel_id)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime_blob))),
            ("RDB$DBKEY_LENGTH", SysVal::I(8)),
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$FIELD_ID", SysVal::I(cols.len() as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$FLAGS", SysVal::I(1)), // REL_sql
            // 0 persistent, 4 GTT ON COMMIT PRESERVE, 5 GTT ON COMMIT DELETE
            ("RDB$RELATION_TYPE", SysVal::I(relation_type)),
            ("RDB$OWNER_NAME", SysVal::S("SYSDBA")),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$DEFAULT_CLASS", SysVal::S(&default_class)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
    store_privileges(file, page_size, &name, 0, TABLE_OWNER_PRIVILEGES)?;
    // the implicit identity generators (system_flag 6), created after the
    // table's own security class so their SQL$<n> classes follow it, in
    // column order (RDB$1, RDB$2, ...)
    for (gen_name, id) in identity_meta.iter().flatten() {
        write_generator(file, page_size, gen_name, 6, id.start, id.increment)?;
    }
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel_id)),
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    for (page, ptype) in [(pointer_page, 4i64), (root_page, 6i64)] {
        sys_insert(
            file,
            page_size,
            "RDB$PAGES",
            0,
            &[
                ("RDB$RELATION_ID", SysVal::I(rel_id)),
                ("RDB$PAGE_NUMBER", SysVal::I(page as i64)),
                ("RDB$PAGE_SEQUENCE", SysVal::I(0)),
                ("RDB$PAGE_TYPE", SysVal::I(ptype)),
            ],
        )?;
    }
    // --- constraints: NOT NULL rows first (in column order), then the
    // key constraints in DECLARATION order - the order the engine's own
    // INTEG_<n> and index-name sequences follow (probe: a table whose
    // UNIQUE precedes its PRIMARY KEY numbers them in that order) ---------
    let mut integ = next_numeric_suffix(file, page_size, "RDB$RELATION_CONSTRAINTS",
        "RDB$CONSTRAINT_NAME", "INTEG_")?;
    for c in cols.iter().filter(|c| c.not_null_constraint) {
        let cname = format!("INTEG_{}", integ);
        integ += 1;
        sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
            ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
            ("RDB$CONSTRAINT_TYPE", SysVal::S("NOT NULL")),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$DEFERRABLE", SysVal::S("NO")),
            ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
        sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
            ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
            ("RDB$TRIGGER_NAME", SysVal::S(&c.name)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    let mut check_i = 0usize;
    for tc in constraints {
        match tc {
            TableConstraint::Key(key) => write_key(file, page_size, &name, key)?,
            TableConstraint::Check(ck) => {
                write_check(file, page_size, &name, ck, &check_names[check_i])?;
                check_i += 1;
            }
        }
    }
    // --- FOREIGN KEY constraints: a non-unique index on the referencing
    // columns (irt_foreign, naming the partner PK index), an RDB$RELATION_
    // CONSTRAINTS 'FOREIGN KEY' row, and an RDB$REF_CONSTRAINTS row linking
    // to the referenced table's PK constraint (MATCH FULL, RESTRICT rules)
    for fk in fks {
        // an unnamed FK is named INTEG_<n> - the same generated name for
        // both the constraint and its index, as the engine does. The
        // number comes from the catalog as it now stands (the key
        // constraints just written have already taken theirs)
        let fk_name = if fk.name.is_empty() {
            next_integ_name(file, page_size)?
        } else {
            fk.name.clone()
        };
        write_foreign_key_full(file, page_size, &name, &fk_name, fk, true)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// Write one PRIMARY KEY or UNIQUE constraint onto a table: the unique
/// index backing it (primary-flagged for a PRIMARY KEY) and the
/// RDB$RELATION_CONSTRAINTS row. A NAMED constraint names its index too;
/// an unnamed one draws INTEG_<n> and its index name from the engine's
/// generated sequences (probed: ONE index-number sequence feeds
/// RDB$PRIMARY<n> and RDB$<n> alike). Shared by create_table and
/// ALTER TABLE ADD CONSTRAINT; create_index backfills - and unique-
/// checks - the table's existing rows, so this works on a populated
/// table exactly as the engine's own does.
fn write_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    key: &KeyDef,
) -> Result<(), String> {
    let (cname, iname) = if key.name.is_empty() {
        let n = next_index_number(file, page_size)?;
        let iname = if key.primary {
            format!("RDB$PRIMARY{}", n)
        } else {
            format!("RDB${}", n)
        };
        (next_integ_name(file, page_size)?, iname)
    } else {
        (key.name.clone(), key.name.clone())
    };
    create_index(
        file, page_size, table, &iname, &key.columns, true, false, key.primary, None,
    )?;
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE",
            SysVal::S(if key.primary { "PRIMARY KEY" } else { "UNIQUE" })),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$INDEX_NAME", SysVal::S(&iname)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    Ok(())
}

/// Write one CHECK constraint onto a table: the PAIR of CHECK_<n>
/// triggers (before-insert type 1, before-update type 3 - both carrying
/// the SAME if-failed-raise BLR and the verbatim source, probed), their
/// per-referenced-field RDB$DEPENDENCIES rows, the
/// RDB$RELATION_CONSTRAINTS 'CHECK' row (no index), and the two
/// RDB$CHECK_CONSTRAINTS rows linking constraint to triggers. The
/// trigger names come pre-assigned from the RDB$TRIGGER_NAME generator
/// (create_table draws them before building the runtime summary, which
/// must already name them).
fn write_check(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    check: &CheckDef,
    tnames: &(String, String),
) -> Result<(), String> {
    let cname = if check.name.is_empty() {
        next_integ_name(file, page_size)?
    } else {
        check.name.clone()
    };
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    for (tname, ttype) in [(&tnames.0, 1i64), (&tnames.1, 3i64)] {
        let src =
            dml::insert_blob_cs(file, page_size, trel, &[check.source.as_bytes().to_vec()], 1, 4)?;
        let blr = dml::insert_blob(file, page_size, trel, &[check.trigger_blr.clone()], 2)?;
        sys_insert(
            file,
            page_size,
            "RDB$TRIGGERS",
            trel,
            &[
                ("RDB$TRIGGER_NAME", SysVal::S(tname)),
                ("RDB$RELATION_NAME", SysVal::S(table)),
                ("RDB$TRIGGER_SEQUENCE", SysVal::I(0)),
                ("RDB$TRIGGER_TYPE", SysVal::I(ttype)),
                ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
                ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
                ("RDB$TRIGGER_INACTIVE", SysVal::I(0)),
                // fb_sysflag_check_constraint
                ("RDB$SYSTEM_FLAG", SysVal::I(3)),
                ("RDB$FLAGS", SysVal::I(1)),
                ("RDB$VALID_BLR", SysVal::I(1)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
        // one dependency row per referenced field, first-seen order
        for f in &check.fields {
            let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
                .ok_or("no RDB$DEPENDENCIES relation")?;
            sys_insert(
                file,
                page_size,
                "RDB$DEPENDENCIES",
                drel,
                &[
                    ("RDB$DEPENDENT_NAME", SysVal::S(tname)),
                    ("RDB$DEPENDED_ON_NAME", SysVal::S(table)),
                    ("RDB$FIELD_NAME", SysVal::S(f)),
                    ("RDB$DEPENDENT_TYPE", SysVal::I(2)),   // obj_trigger
                    ("RDB$DEPENDED_ON_TYPE", SysVal::I(0)), // obj_relation
                    ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
                    ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
                ],
            )?;
        }
    }
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("CHECK")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    for tname in [&tnames.0, &tnames.1] {
        sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
            ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
            ("RDB$TRIGGER_NAME", SysVal::S(tname)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    Ok(())
}

/// One field of a restored VIEW, as the backup carries it.
pub struct RestoredViewField {
    pub name: String,
    /// its RDB$FIELD_SOURCE domain - shared with the base column
    pub source: String,
    pub base_field: String,
    pub view_context: i64,
    pub position: i64,
}

/// One FROM-context of a restored VIEW (an RDB$VIEW_RELATIONS row).
pub struct RestoredViewContext {
    pub relation: String,
    pub context: i64,
    pub context_name: String,
}

/// Store a VIEW as gbak's restore does: the RDB$RELATIONS row
/// (type 1) with the carried VIEW_BLR and VIEW_SOURCE blobs verbatim,
/// one format row derived from the fields' domains, the
/// RDB$RELATION_FIELDS rows with their base-field and context links,
/// and the RDB$VIEW_RELATIONS context rows. A view owns no pages -
/// its rows are a query - so nothing else is allocated.
pub fn restore_view(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &[u8],
    fields: &[RestoredViewField],
    contexts: &[RestoredViewContext],
) -> Result<(), String> {
    let name = name.trim().to_ascii_uppercase();
    let rels = list_relations(file, page_size);
    if rels.iter().any(|(_, n)| n.trim_end().eq_ignore_ascii_case(&name)) {
        return Err(format!("relation {} already exists", name));
    }
    let rel_id = (rels.iter().map(|(id, _)| *id).max().unwrap_or(127).max(127) + 1) as i64;
    // the format: each field's descriptor from its (already restored)
    // domain, offsets laid out the way the row would be
    let mut descs: Vec<Descriptor> = Vec::new();
    let mut off = 4u16; // the null bitmap slot, as create_table lays out
    for f in fields {
        let (ft, len, sc, st) = domain_type_info(file, page_size, &f.source)
            .ok_or_else(|| format!("view {}: domain {} not found", name, f.source))?;
        let dt = field_type_to_dtype(ft)
            .ok_or_else(|| format!("view {}: field type {} unsupported", name, ft))?;
        descs.push(Descriptor {
            dtype: dt,
            scale: sc,
            length: len,
            sub_type: st,
            flags: 0,
            offset: off as u32,
        });
        off += len;
    }
    let fmt_blob = write_format_blob(file, page_size, &descs)?;
    let formats_rel = crate::resolve_relation(file, page_size, "RDB$FORMATS")
        .ok_or("no RDB$FORMATS relation")?;
    let relations_rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS relation")?;
    let relfields_rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS relation")?;
    let viewrels_rel = crate::resolve_relation(file, page_size, "RDB$VIEW_RELATIONS")
        .ok_or("no RDB$VIEW_RELATIONS relation")?;
    sys_insert(file, page_size, "RDB$FORMATS", formats_rel, &[
        ("RDB$RELATION_ID", SysVal::I(rel_id)),
        ("RDB$FORMAT", SysVal::I(1)),
        ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(formats_rel, fmt_blob))),
    ])?;
    let src = dml::insert_blob_cs(file, page_size, relations_rel, &[view_source.to_vec()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, relations_rel, &[view_blr.to_vec()], 2)?;
    sys_insert(file, page_size, "RDB$RELATIONS", relations_rel, &[
        ("RDB$RELATION_NAME", SysVal::S(&name)),
        ("RDB$RELATION_ID", SysVal::I(rel_id)),
        ("RDB$RELATION_TYPE", SysVal::I(1)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        // a VIEW's dbkey length is 0 and its FLAGS bit 1 marks the
        // view (both diffed off the engine's own restore - and the
        // missing schema qualifier on the field-source was exactly
        // what made the engine answer "Column unknown" over an
        // otherwise perfect catalog, the FK-blocker lesson again)
        ("RDB$FLAGS", SysVal::I(1)),
        ("RDB$DBKEY_LENGTH", SysVal::I(0)),
        ("RDB$FORMAT", SysVal::I(1)),
        ("RDB$FIELD_ID", SysVal::I(fields.len() as i64)),
        ("RDB$VIEW_BLR", SysVal::B(blob_id_bytes(relations_rel, blr))),
        ("RDB$VIEW_SOURCE", SysVal::B(blob_id_bytes(relations_rel, src))),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    for (i, f) in fields.iter().enumerate() {
        sys_insert(file, page_size, "RDB$RELATION_FIELDS", relfields_rel, &[
            ("RDB$FIELD_NAME", SysVal::S(&f.name)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$FIELD_SOURCE", SysVal::S(&f.source)),
            ("RDB$FIELD_POSITION", SysVal::I(f.position)),
            ("RDB$FIELD_ID", SysVal::I(i as i64)),
            ("RDB$BASE_FIELD", SysVal::S(&f.base_field)),
            ("RDB$VIEW_CONTEXT", SysVal::I(f.view_context)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$UPDATE_FLAG", SysVal::I(1)),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    for c in contexts {
        sys_insert(file, page_size, "RDB$VIEW_RELATIONS", viewrels_rel, &[
            ("RDB$VIEW_NAME", SysVal::S(&name)),
            ("RDB$RELATION_NAME", SysVal::S(&c.relation)),
            ("RDB$VIEW_CONTEXT", SysVal::I(c.context)),
            ("RDB$CONTEXT_NAME", SysVal::S(&c.context_name)),
            ("RDB$CONTEXT_TYPE", SysVal::I(0)),
            ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    // THE RUNTIME SUMMARY IS THE FIELD LIST: the engine's relation
    // loader reads its fields from the RDB$RUNTIME blob, not from the
    // RDB$RELATION_FIELDS rows (met.epp "Pick up field specific
    // stuff", blb::open(&REL.RDB$RUNTIME)) - a view restored with a
    // perfect catalog and no runtime answered "Column unknown" to
    // every column while COUNT(*) ran fine, measured
    update_relation_runtime(file, page_size, &name)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// One trigger row as a BACKUP carries it - a CHECK constraint's or a
/// referential action's, stored VERBATIM: the BLR and source are the
/// engine's own bytes off the file, not compiled here.
pub struct CarriedTrigger {
    /// the PSQL debug map, stored sub_type 9 like CREATE TRIGGER's
    pub debug: Option<Vec<u8>>,
    pub name: String,
    pub relation: String,
    pub sequence: i64,
    pub ttype: i64,
    pub blr: Vec<u8>,
    pub source: Vec<u8>,
    pub system_flag: i64,
    pub inactive: i64,
    pub flags: Option<i64>,
    pub valid_blr: Option<i64>,
}

/// Store one carried trigger row (gbak restore). The caller refreshes
/// the relation runtime once per table when its triggers are in.
pub fn restore_carried_trigger(
    file: &mut crate::Image,
    page_size: usize,
    t: &CarriedTrigger,
) -> Result<(), String> {
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let src = dml::insert_blob_cs(file, page_size, trel, &[t.source.clone()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, trel, &[t.blr.clone()], 2)?;
    let dbg = match &t.debug {
        Some(d) => Some(dml::insert_blob(file, page_size, trel, &[d.clone()], 9)?),
        None => None,
    };
    let mut vals: Vec<(&str, SysVal)> = vec![
        ("RDB$TRIGGER_NAME", SysVal::S(&t.name)),
        ("RDB$RELATION_NAME", SysVal::S(&t.relation)),
        ("RDB$TRIGGER_SEQUENCE", SysVal::I(t.sequence)),
        ("RDB$TRIGGER_TYPE", SysVal::I(t.ttype)),
        ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
        ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
        ("RDB$TRIGGER_INACTIVE", SysVal::I(t.inactive)),
        ("RDB$SYSTEM_FLAG", SysVal::I(t.system_flag)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if let Some(fl) = t.flags {
        vals.push(("RDB$FLAGS", SysVal::I(fl)));
    }
    if let Some(v) = t.valid_blr {
        vals.push(("RDB$VALID_BLR", SysVal::I(v)));
    }
    let dbg_bytes = dbg.map(|d| blob_id_bytes(trel, d));
    if let Some(b) = &dbg_bytes {
        vals.push(("RDB$DEBUG_INFO", SysVal::B(*b)));
    }
    sys_insert(file, page_size, "RDB$TRIGGERS", trel, &vals)?;
    Ok(())
}

/// Store a CHECK constraint's RDB$RELATION_CONSTRAINTS row (gbak
/// restore; the chk rows and the triggers arrive separately, verbatim).
pub fn restore_check_constraint_row(
    file: &mut crate::Image,
    page_size: usize,
    cname: &str,
    table: &str,
) -> Result<(), String> {
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("CHECK")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])
}

/// Store one RDB$CHECK_CONSTRAINTS row verbatim (gbak restore).
pub fn restore_chk_row(
    file: &mut crate::Image,
    page_size: usize,
    cname: &str,
    tname: &str,
) -> Result<(), String> {
    sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(cname)),
        ("RDB$TRIGGER_NAME", SysVal::S(tname)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])
}

/// Refresh a relation's runtime summary - public for the gbak restore,
/// which stores carried triggers and must make them FIRE.
pub fn refresh_relation_runtime(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
) -> Result<(), String> {
    update_relation_runtime(file, page_size, &table.trim().to_ascii_uppercase())
}

/// A user `CREATE TRIGGER`, compiled: the catalog values plus the three
/// blobs (verbatim source from `AS` on, the body BLR, and the
/// `RDB$DEBUG_INFO` source-to-BLR map the engine writes for PSQL).
#[derive(Clone)]
pub struct UserTriggerDef {
    pub name: String,
    /// 1 = BEFORE INSERT, 3 = BEFORE UPDATE (the slice this writer
    /// compiles; AFTER/DELETE bodies have nothing our surface can say)
    pub trigger_type: i64,
    /// POSITION <n> - RDB$TRIGGER_SEQUENCE, the firing order
    pub sequence: i64,
    pub source: String,
    pub blr: Vec<u8>,
    pub debug: Vec<u8>,
    /// referenced fields (reads and assignment targets, deduplicated,
    /// sorted) - one RDB$DEPENDENCIES row each
    pub fields: Vec<String>,
    /// INSERT-INTO (blr_store) target relations: one relation-level
    /// dependency row (no field) plus one per stored column - what the
    /// engine records for a store inside a trigger body (probed)
    pub store_deps: Vec<(String, Vec<String>)>,
    /// raised EXCEPTIONs: one dependency row each, object type 7
    pub exceptions: Vec<String>,
}

/// `CREATE TRIGGER <name> FOR <table> ...`: the RDB$TRIGGERS row (user
/// trigger: system_flag 0, flags 1), its source / BLR / debug-info blobs
/// (the last with the declared sub_type 9), one RDB$DEPENDENCIES row per
/// referenced field, and a refresh of the relation's RDB$RUNTIME - a
/// trigger absent from the summary never fires.
pub fn create_user_trigger(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    def: &UserTriggerDef,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    if relation_trigger_names(file, page_size, &table)
        .iter()
        .any(|t| t.eq_ignore_ascii_case(&def.name))
    {
        return Err(format!("trigger {} already exists", def.name));
    }
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let src = dml::insert_blob_cs(file, page_size, trel, &[def.source.as_bytes().to_vec()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, trel, &[def.blr.clone()], 2)?;
    let dbg = dml::insert_blob(file, page_size, trel, &[def.debug.clone()], 9)?;
    sys_insert(
        file,
        page_size,
        "RDB$TRIGGERS",
        trel,
        &[
            ("RDB$TRIGGER_NAME", SysVal::S(&def.name)),
            ("RDB$RELATION_NAME", SysVal::S(&table)),
            ("RDB$TRIGGER_SEQUENCE", SysVal::I(def.sequence)),
            ("RDB$TRIGGER_TYPE", SysVal::I(def.trigger_type)),
            ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
            ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
            ("RDB$DEBUG_INFO", SysVal::B(blob_id_bytes(trel, dbg))),
            ("RDB$TRIGGER_INACTIVE", SysVal::I(0)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$FLAGS", SysVal::I(1)),
            ("RDB$VALID_BLR", SysVal::I(1)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
    let dep = |file: &mut crate::Image, on: &str, field: Option<&str>, otype: i64| -> Result<(), String> {
        let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES relation")?;
        let mut row = vec![
            ("RDB$DEPENDENT_NAME", SysVal::S(&def.name)),
            ("RDB$DEPENDED_ON_NAME", SysVal::S(on)),
            ("RDB$DEPENDENT_TYPE", SysVal::I(2)), // obj_trigger
            ("RDB$DEPENDED_ON_TYPE", SysVal::I(otype)),
            ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if let Some(f) = field {
            row.push(("RDB$FIELD_NAME", SysVal::S(f)));
        }
        sys_insert(file, page_size, "RDB$DEPENDENCIES", drel, &row)
    };
    for f in &def.fields {
        dep(file, &table, Some(f), 0)?;
    }
    // a blr_store's target: the relation itself plus each stored column
    for (srel_name, scols) in &def.store_deps {
        dep(file, srel_name, None, 0)?;
        for c in scols {
            dep(file, srel_name, Some(c), 0)?;
        }
    }
    // a raised exception: object type 7 (probed)
    for e in &def.exceptions {
        dep(file, e, None, 7)?;
    }
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] CHECK (<condition>)`:
/// the same trigger pair and catalog rows a CREATE-time CHECK writes
/// ([write_check]), plus a refresh of the relation's RDB$RUNTIME so the
/// new triggers load. The engine does NOT validate existing rows
/// (probed: a violating row survives the ALTER untouched; only future
/// DML is checked) - so neither does this.
pub fn alter_table_add_check(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    check: &CheckDef,
) -> Result<(), String> {
    let table = table.trim().to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
        .ok_or("no RDB$TRIGGER_NAME generator")?;
    let a = gen::bump(file, page_size, slot, 1)?;
    let b = gen::bump(file, page_size, slot, 1)?;
    write_check(
        file,
        page_size,
        &table,
        check,
        &(format!("CHECK_{}", a), format!("CHECK_{}", b)),
    )?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] PRIMARY KEY|UNIQUE
/// (<cols>)`: add a key constraint to an EXISTING table. The index is
/// built over the table's committed rows, so duplicate data fails the
/// statement the way the engine's own index build does. A PRIMARY KEY
/// requires its columns to be NOT NULL ALREADY - the engine refuses to
/// add one over a nullable column rather than making it not-null
/// (probed), and so does this.
pub fn alter_table_add_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    key: &KeyDef,
) -> Result<(), String> {
    let name = table.trim().to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let columns = relation_columns(file, page_size, &name);
    for c in &key.columns {
        if !columns.iter().any(|rc| rc.name.eq_ignore_ascii_case(c)) {
            return Err(format!("unknown column {}", c));
        }
    }
    if key.primary {
        if find_partner_key(file, page_size, &name, &[]).is_some() {
            return Err(format!("table {} already has a primary key", name));
        }
        for c in &key.columns {
            if !column_is_not_null(file, page_size, &name, &c.to_ascii_uppercase()) {
                return Err(format!(
                    "Column: {} not defined as NOT NULL - cannot be used in PRIMARY KEY constraint definition",
                    c
                ));
            }
        }
    }
    write_key(file, page_size, &name, key)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> DROP CONSTRAINT <name>`: remove a NOT NULL,
/// PRIMARY KEY, UNIQUE or FOREIGN KEY constraint.
///
/// The key constraints take their index with them, and the engine does
/// that in a DEFERRED way worth reproducing exactly (DdlNodes.epp:
/// `DropIndexNode::drop`, ods.h's index-state lifecycle): the
/// `RDB$INDICES` row is not erased but RENAMED to
/// `RDB$TEMP_DEPEND_<relation id>_<index id>` with `RDB$INDEX_INACTIVE
/// = MET_index_deferred_drop (4)`, its `RDB$INDEX_SEGMENTS` rows are
/// deleted, and the index-root slot goes to state `irt_drop` (6) -
/// "index to be removed when OAT > irt_transaction" - keeping its
/// pages until then. gbak skips such indices (backup.epp:1676), so a
/// restored copy carries no trace of them.
///
/// A PRIMARY KEY or UNIQUE that a foreign key references is refused,
/// as the engine refuses it ("Cannot delete PRIMARY KEY being used in
/// FOREIGN KEY definition").
pub fn alter_table_drop_constraint(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    constraint: &str,
) -> Result<(), String> {
    let name = table.trim().to_ascii_uppercase();
    let cname = constraint.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (ctype, index_name) = find_constraint(file, page_size, &name, &cname).ok_or_else(|| {
        format!("constraint {} on table {} not found", cname, name)
    })?;
    match ctype.as_str() {
        "NOT NULL" => {
            // the column it guards is named by its RDB$CHECK_CONSTRAINTS
            // link; clearing NULL_FLAG and refreshing RDB$RUNTIME is what
            // ALTER COLUMN DROP NOT NULL already does
            let column = check_constraint_column(file, page_size, &cname)
                .ok_or_else(|| format!("constraint {} has no column", cname))?;
            patch_rf_null_flag(file, page_size, &name, &column, None)?;
            let cn_fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS", |v| {
                text_eq(v.get(cn_fid), &cname)
            })?;
            refresh_runtime(file, page_size, &name)?;
        }
        "PRIMARY KEY" | "UNIQUE" => {
            if let Some(fk) = foreign_key_referencing(file, page_size, &cname) {
                return Err(format!(
                    "Cannot delete {} being used in FOREIGN KEY definition (constraint {})",
                    ctype, fk
                ));
            }
            let index_name = index_name.ok_or("key constraint without an index")?;
            deferred_drop_index(file, page_size, rel, &index_name)?;
        }
        "FOREIGN KEY" => {
            let cn_fid = sys_fid(file, page_size, "RDB$REF_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$REF_CONSTRAINTS", |v| {
                text_eq(v.get(cn_fid), &cname)
            })?;
            let index_name = index_name.ok_or("foreign key without an index")?;
            deferred_drop_index(file, page_size, rel, &index_name)?;
        }
        "CHECK" => {
            // the pair of CHECK_<n> triggers, their dependency rows and
            // the link rows all go, and the runtime refresh drops the
            // trigger names - the engine leaves nothing and the
            // condition stops enforcing (probed)
            let tnames = check_constraint_trigger_names(file, page_size, &cname);
            let cn_fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS", |v| {
                text_eq(v.get(cn_fid), &cname)
            })?;
            let tn_fid = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
            let dn_fid = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
            for t in &tnames {
                let t = t.clone();
                delete_catalog_rows(file, page_size, "RDB$TRIGGERS", {
                    let t = t.clone();
                    move |v| text_eq(v.get(tn_fid), &t)
                })?;
                delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| {
                    text_eq(v.get(dn_fid), &t)
                })?;
            }
            refresh_runtime(file, page_size, &name)?;
        }
        other => return Err(format!("cannot drop a {} constraint", other)),
    }
    let rc_name = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
    delete_catalog_rows(file, page_size, "RDB$RELATION_CONSTRAINTS", |v| {
        text_eq(v.get(rc_name), &cname)
    })?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `DROP INDEX <name>`: remove a standalone index - the mirror of
/// [create_index]. An index that BACKS a constraint cannot be dropped
/// this way; the engine posts isc_integ_index_del ("Cannot delete index
/// used by an Integrity Constraint", DdlNodes.epp:14643) and refers the
/// user to ALTER TABLE DROP CONSTRAINT. The removal itself is the
/// engine's deferred one - see [deferred_drop_index].
pub fn drop_index(file: &mut crate::Image, page_size: usize, index_name: &str) -> Result<(), String> {
    let want = index_name.trim().trim_matches('"').to_ascii_uppercase();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("index {} not found", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    if let Some(constraint) = constraint_using_index(file, page_size, &want) {
        return Err(format!(
            "Cannot delete index used by an Integrity Constraint (constraint {})",
            constraint
        ));
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    deferred_drop_index(file, page_size, rel, &want)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// What a `COMMENT ON` targets - the object whose `RDB$DESCRIPTION`
/// column is written.
#[derive(Clone)]
pub enum CommentTarget {
    /// `COMMENT ON TABLE <name>` - the `RDB$RELATIONS` row
    Table(String),
    /// `COMMENT ON COLUMN <table>.<column>` - the `RDB$RELATION_FIELDS` row
    Column(String, String),
    /// `COMMENT ON INDEX <name>` - the `RDB$INDICES` row
    Index(String),
    /// `COMMENT ON SEQUENCE|GENERATOR <name>` - the `RDB$GENERATORS` row
    Sequence(String),
    /// `COMMENT ON EXCEPTION <name>` - the `RDB$EXCEPTIONS` row
    Exception(String),
    /// `COMMENT ON ROLE <name>` - the `RDB$ROLES` row
    Role(String),
    /// `COMMENT ON DOMAIN <name>` - the `RDB$FIELDS` row
    Domain(String),
    /// `COMMENT ON DATABASE` - the single `RDB$DATABASE` row (no name)
    Database,
}

/// A `RDB$DESCRIPTION` cell value from comment text: a text blob written
/// into `owner_rel`'s own data pages (charset 4, UTF8 - the metadata
/// charset, not the 1 the binary metadata blobs carry), or NULL when the
/// comment is being cleared.
fn description_blob(
    file: &mut crate::Image,
    page_size: usize,
    owner_rel: u16,
    text: Option<&str>,
) -> Result<SysVal<'static>, String> {
    match text {
        Some(t) => {
            let id = dml::insert_blob_cs(file, page_size, owner_rel, &[t.as_bytes().to_vec()], 1, 4)?;
            Ok(SysVal::B(blob_id_bytes(owner_rel, id)))
        }
        None => Ok(SysVal::Null),
    }
}

/// `COMMENT ON <kind> <name> IS <text>` - `CommentOnNode` against the
/// file image, for a table, a column, an index or a sequence. The comment
/// is a text blob written into the owning catalog relation's data pages
/// (`RDB$RELATIONS` for a table, `RDB$RELATION_FIELDS` for a column,
/// `RDB$INDICES` for an index, `RDB$GENERATORS` for a sequence) and its id
/// stored in the target row's `RDB$DESCRIPTION`; `IS NULL` (and, the
/// engine's probe shows, `IS ''`) clears the column to NULL, leaving the
/// old blob orphaned exactly as the engine does.
///
/// The one on-disk detail that matters: a `RDB$DESCRIPTION` text blob
/// carries `blh_charset` = 4 (UTF8, the metadata charset), not the 1 the
/// binary metadata blobs use - `CAST(RDB$DESCRIPTION AS VARCHAR)` decodes
/// through the blob's own charset, so it must match (see
/// [crate::dml::insert_blob_cs]).
pub fn comment_on(
    file: &mut crate::Image,
    page_size: usize,
    target: &CommentTarget,
    text: Option<&str>,
) -> Result<(), String> {
    // an empty comment is a NULL comment (engine probe: IS '' clears it)
    let text = text.filter(|t| !t.is_empty());
    match target {
        CommentTarget::Table(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            let rel = crate::resolve_relation(file, page_size, &name)
                .ok_or_else(|| format!("Table \"{}\" not found", name))?;
            if rel < 128 {
                return Err("system relations are read-only".into());
            }
            let value = description_blob(file, page_size, 6, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$RELATIONS", 6,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Column(table, column) => {
            let table = table.trim().trim_matches('"').to_ascii_uppercase();
            let column = column.trim().trim_matches('"').to_ascii_uppercase();
            let rel = crate::resolve_relation(file, page_size, &table)
                .ok_or_else(|| format!("Table \"{}\" not found", table))?;
            if rel < 128 {
                return Err("system relations are read-only".into());
            }
            if !relation_columns(file, page_size, &table)
                .iter()
                .any(|c| c.name.eq_ignore_ascii_case(&column))
            {
                return Err(format!(
                    "column {} does not exist in table/view \"{}\"",
                    column, table
                ));
            }
            let value = description_blob(file, page_size, 5, text)?;
            let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
            let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
            let (t, c) = (table.clone(), column.clone());
            patch_sys_row(file, page_size, "RDB$RELATION_FIELDS", 5,
                move |v| text_eq(v.get(rel_fid), &t) && text_eq(v.get(name_fid), &c),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Index(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            let (_table, system) = find_index_relation(file, page_size, &name)
                .ok_or_else(|| format!("index {} not found", name))?;
            if system != 0 {
                return Err("system indices are read-only".into());
            }
            let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
                .ok_or("RDB$INDICES not found")?;
            let value = description_blob(file, page_size, irel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$INDICES", irel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Sequence(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            let (_, system, _) = find_generator(file, page_size, &name)
                .ok_or_else(|| format!("generator {} not found", name))?;
            if system != 0 {
                return Err("system generators are read-only".into());
            }
            let grel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")
                .ok_or("RDB$GENERATORS not found")?;
            let value = description_blob(file, page_size, grel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$GENERATORS", grel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Exception(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            if find_exception(file, page_size, &name).is_none() {
                return Err(format!("Exception {} not found", name));
            }
            let erel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
                .ok_or("RDB$EXCEPTIONS not found")?;
            let value = description_blob(file, page_size, erel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$EXCEPTIONS", erel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Role(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            if find_role(file, page_size, &name).is_none() {
                return Err(format!("Role {} not found", name));
            }
            let rrel = crate::resolve_relation(file, page_size, "RDB$ROLES")
                .ok_or("RDB$ROLES not found")?;
            let value = description_blob(file, page_size, rrel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$ROLES", "RDB$ROLE_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$ROLES", rrel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Domain(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            // a domain is a user RDB$FIELDS row; the built-in RDB$/SQL$
            // fields the engine synthesises are read-only
            if name.starts_with("RDB$") || name.starts_with("SQL$") {
                return Err("system domains are read-only".into());
            }
            if !domain_exists(file, page_size, &name) {
                return Err(format!("Domain {} not found", name));
            }
            let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
                .ok_or("RDB$FIELDS not found")?;
            let value = description_blob(file, page_size, frel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$FIELDS", frel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Database => {
            // the singleton RDB$DATABASE row - the description blob is owned
            // by RDB$DATABASE itself, and the one row is patched in place
            let drel = crate::resolve_relation(file, page_size, "RDB$DATABASE")
                .ok_or("RDB$DATABASE not found")?;
            let value = description_blob(file, page_size, drel, text)?;
            patch_sys_row(file, page_size, "RDB$DATABASE", drel,
                |_| true,
                &[("RDB$DESCRIPTION", value)])?;
        }
    }
    advance_oldest_transactions(file, page_size)
}

/// `SET STATISTICS INDEX <name>` - `SetStatisticsNode` (DdlNodes.epp:14475)
/// against the file image.
///
/// The engine's statement is two steps: at execute it writes
/// `RDB$STATISTICS = -1.0` as a "recalculate me" marker, and at commit a
/// deferred work (`set_statistics`, dfw.epp:3575) walks the index tree
/// (`IDX_statistics`) and `DFW_update_index` writes the fresh selectivity
/// into the two catalog columns and the index root descriptor. Only the
/// committed end state is observable, and it is exactly what a build
/// produces: `1 / distinct` per key prefix over the rows as they now
/// stand. fire-crab, an offline writer that computes from the committed
/// rows rather than by scanning the tree, produces that end state
/// directly - which is why the machinery is the same
/// [index_selectivity]/[write_index_statistics] every build already uses.
///
/// Any index qualifies - a `PRIMARY KEY`'s and an inactive one included
/// (the engine recomputes both) - so the only failure is an index that
/// does not exist ("Index not found").
pub fn set_index_statistics(
    file: &mut crate::Image,
    page_size: usize,
    index_name: &str,
) -> Result<(), String> {
    let want = index_name.trim().trim_matches('"').to_ascii_uppercase();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("Index not found: {}", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (_, _unique, descending) = index_row_state(file, page_size, &want)?;
    let slot = index_id_of(file, page_size, &want)?.saturating_sub(1);
    let columns = relation_columns(file, page_size, &table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for n in index_segment_columns(file, page_size, &want)? {
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(&n))
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs.get(rc.field_id as usize).ok_or("field beyond format")?;
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err(format!("index {} has no segments", want));
    }
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, &want, &sel)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER INDEX <name> ACTIVE|INACTIVE` - `AlterIndexNode`
/// (DdlNodes.epp:14270) against the file image.
///
/// INACTIVE is the deferred index drop again, minus the catalog
/// teardown: the index-root slot goes to the drop states with its pages,
/// which (per the DROP INDEX slice) means the tree keeps being
/// MAINTAINED while `setDrop`'s cleared `irt_unique|irt_primary|
/// irt_foreign` stop it being ENFORCED - an inactive UNIQUE index
/// accepts duplicates, engine-probed. The `RDB$INDICES` row keeps its
/// name, its id and its segment rows; only `RDB$INDEX_INACTIVE` moves to
/// 1 (`MET_index_inactive`, Relation.h:449).
///
/// ACTIVE REBUILDS. `AlterIndexNode::step2` tries `IDX_activate_index`
/// first, but once the deactivating transaction has committed that undo
/// is refused and the index is built from scratch (engine probe: even in
/// the same isql session, `RDB$INDEX_ID` moves 1 -> 2, the old slot stays
/// in the drop state with its pages, the new slot is a fresh tree). So
/// this takes a NEW slot, backfills every committed row - a duplicate
/// under a unique index fails the statement, exactly as the engine's
/// rebuild does - and recomputes the selectivity.
///
/// An index backing a constraint cannot be deactivated at all
/// ("Cannot deactivate index used by a PRIMARY/UNIQUE constraint" /
/// "... by an integrity constraint").
pub fn alter_index_active(
    file: &mut crate::Image,
    page_size: usize,
    index_name: &str,
    active: bool,
) -> Result<(), String> {
    let want = index_name.trim().trim_matches('"').to_ascii_uppercase();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("Index not found: {}", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (inactive, unique, descending) = index_row_state(file, page_size, &want)?;
    if (inactive == 0) == active {
        return Ok(()); // already in the desired state: the engine does nothing
    }
    if !active {
        if let Some(constraint) = constraint_using_index(file, page_size, &want) {
            return Err(format!(
                "Cannot deactivate index used by an integrity constraint (constraint {})",
                constraint
            ));
        }
        let id = index_id_of(file, page_size, &want)?;
        mark_index_slot_dropped(file, page_size, rel, id.saturating_sub(1))?;
        let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
        patch_sys_row(
            file,
            page_size,
            "RDB$INDICES",
            4,
            |v| text_eq(v.get(ix_name), &want),
            &[("RDB$INDEX_INACTIVE", SysVal::I(1))], // MET_index_inactive
        )?;
        advance_oldest_transactions(file, page_size)?;
        return Ok(());
    }

    // ACTIVE: a rebuild into a new slot
    let columns = relation_columns(file, page_size, &table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for n in index_segment_columns(file, page_size, &want)? {
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(&n))
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs
            .get(rc.field_id as usize)
            .ok_or("field beyond format")?;
        // a COMPUTED column has no stored bytes to key on - the build
        // would index the null-flag area
        if d.offset == 0 && d.length != 0 {
            return Err(format!("column {} is computed - not indexable", n));
        }
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err(format!("index {} has no segments", want));
    }
    let mut iflags = 0u16;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;
    backfill_index(
        file, page_size, rel, slot, &segs, &descs, unique, descending, false,
    )?;
    let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$INDICES",
        4,
        |v| text_eq(v.get(ix_name), &want),
        &[
            ("RDB$INDEX_INACTIVE", SysVal::I(0)), // MET_index_active
            ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
        ],
    )?;
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, &want, &sel)?;
    advance_oldest_transactions(file, page_size)
}

/// An index's `(RDB$INDEX_INACTIVE, unique, descending)` from
/// RDB$INDICES. A NULL `RDB$INDEX_INACTIVE` counts as active (0), the
/// way `MetadataCache::getIndexStatus` reads it.
fn index_row_state(file: &crate::Image, page_size: usize, name: &str) -> Result<(i64, bool, bool), String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let inact_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_INACTIVE")?;
    let uniq_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$UNIQUE_FLAG")?;
    let type_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_TYPE")?;
    let mut found = None;
    walk_rows(file, page_size, 4, descs, |values| {
        if text_eq(values.get(name_f), name) {
            let int = |v: Option<&Value>| match v {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            found = Some((
                int(values.get(inact_f)),
                int(values.get(uniq_f)) == 1,
                int(values.get(type_f)) == 1,
            ));
        }
    });
    found.ok_or_else(|| format!("Index not found: {}", name))
}

/// An index's `RDB$INDEX_ID` (the index-root slot plus one).
fn index_id_of(file: &crate::Image, page_size: usize, name: &str) -> Result<usize, String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let id_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_ID")?;
    let mut found = None;
    walk_rows(file, page_size, 4, descs, |values| {
        if text_eq(values.get(name_f), name) {
            if let Some(Value::Int(i)) = values.get(id_f) {
                found = Some(*i as usize);
            }
        }
    });
    found.ok_or_else(|| format!("index {} has no id", name))
}

/// An index's column names, in key order, from RDB$INDEX_SEGMENTS.
fn index_segment_columns(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Result<Vec<String>, String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    let field_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_NAME")?;
    let pos_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_POSITION")?;
    let mut segs: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(name_f), name) {
            if let Some(Value::Text(t)) = values.get(field_f) {
                let pos = match values.get(pos_f) {
                    Some(Value::Int(i)) => *i,
                    _ => 0,
                };
                segs.push((pos, t.trim_end().to_string()));
            }
        }
    });
    segs.sort_by_key(|(p, _)| *p);
    Ok(segs.into_iter().map(|(_, n)| n).collect())
}

/// Move one index-root slot into the drop states with its pages kept -
/// `setDrop` (ods.h:613), which also clears
/// `irt_unique|irt_foreign|irt_primary`, so the tree is still maintained
/// but no longer enforces anything.
fn mark_index_slot_dropped(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
) -> Result<(), String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + slot * 24;
    if at + 24 > page.len() {
        return Err("index slot beyond the root page".into());
    }
    dml::put_u16(page, at + 18, 0); // irt_flags
    page[at + 20] = 6; // irt_drop (ods.h:456)
    Ok(())
}

/// An index's (relation name, RDB$SYSTEM_FLAG) from RDB$INDICES.
fn find_index_relation(file: &crate::Image, page_size: usize, index_name: &str) -> Option<(String, i64)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$INDICES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (ix_f, rn_f, sf_f) = (
        fid("RDB$INDEX_NAME")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$SYSTEM_FLAG")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(ix_f), index_name) {
            if let Some(Value::Text(t)) = values.get(rn_f) {
                let system = match values.get(sf_f) {
                    Some(Value::Int(i)) => *i,
                    _ => 0,
                };
                found = Some((t.trim_end().to_string(), system));
            }
        }
    });
    found
}

/// The constraint (if any) an index backs - a PRIMARY KEY, UNIQUE or
/// FOREIGN KEY row of RDB$RELATION_CONSTRAINTS naming it.
fn constraint_using_index(file: &crate::Image, page_size: usize, index_name: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ix_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$INDEX_NAME")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(ix_f), index_name) {
            if let Some(Value::Text(t)) = values.get(cn_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// A constraint's (type, index name) from RDB$RELATION_CONSTRAINTS.
fn find_constraint(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    cname: &str,
) -> Option<(String, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ct_f, rn_f, ix_f) = (
        fid("RDB$CONSTRAINT_NAME")?,
        fid("RDB$CONSTRAINT_TYPE")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$INDEX_NAME")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(cn_f), cname) && text_eq(values.get(rn_f), table) {
            let ctype = match values.get(ct_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            let index = match values.get(ix_f) {
                Some(Value::Text(t)) => Some(t.trim_end().to_string()),
                _ => None,
            };
            found = Some((ctype, index));
        }
    });
    found
}

/// The column a NOT NULL constraint guards (RDB$CHECK_CONSTRAINTS'
/// RDB$TRIGGER_NAME holds the column name for those rows).
fn check_constraint_column(file: &crate::Image, page_size: usize, cname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, tr_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$TRIGGER_NAME")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(cn_f), cname) {
            if let Some(Value::Text(t)) = values.get(tr_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// EVERY trigger name a check constraint's RDB$CHECK_CONSTRAINTS rows
/// link to - a CHECK has a pair, where a NOT NULL has its single column
/// name in the same place ([check_constraint_column]).
fn check_constraint_trigger_names(file: &crate::Image, page_size: usize, cname: &str) -> Vec<String> {
    let mut names = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS"),
        system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS"),
    ) else {
        return names;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return names;
    };
    let cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(cn_f), Some(tr_f)) = (fid("RDB$CONSTRAINT_NAME"), fid("RDB$TRIGGER_NAME")) else {
        return names;
    };
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(cn_f), cname) {
            if let Some(Value::Text(t)) = values.get(tr_f) {
                let t = t.trim_end().to_string();
                if !names.contains(&t) {
                    names.push(t);
                }
            }
        }
    });
    names
}

/// The foreign key (if any) whose RDB$REF_CONSTRAINTS row names this
/// unique/primary constraint as its partner.
fn foreign_key_referencing(file: &crate::Image, page_size: usize, cname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$REF_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$REF_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$REF_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, uq_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$CONST_NAME_UQ")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(uq_f), cname) {
            if let Some(Value::Text(t)) = values.get(cn_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// Remove an index the engine's deferred way: its RDB$INDICES row
/// renamed to RDB$TEMP_DEPEND_<rel>_<id> and marked
/// MET_index_deferred_drop (4), its segment rows deleted, and its
/// index-root slot moved to irt_drop (6) with its flags cleared - the
/// state fcstat reads back from an engine-dropped index, pages and all.
fn deferred_drop_index(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    index_name: &str,
) -> Result<(), String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (ix_format_no, ix_descs) = {
        let (n, d) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let id_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_ID")?;
    let inactive_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_INACTIVE")?;
    let want = index_name.trim().to_ascii_uppercase();
    let (page, slot) = find_sys_row_slot(file, page_size, "RDB$INDICES", 4, |vals| {
        text_eq(vals.get(name_fid), &want)
    })
    .ok_or_else(|| format!("index {} not found", index_name))?;
    let mut image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(slot).and_then(|r| r.image()).ok_or("no index image")?
    };
    // RDB$INDEX_ID is the irt slot + 1 (both here and in the engine)
    let index_id = {
        let d = ix_descs.get(id_fid).ok_or("field beyond format")?;
        let vals = decode_record(&image, &ix_descs);
        match vals.get(id_fid) {
            Some(Value::Int(i)) => *i as usize,
            _ => return Err(format!("index {} has no id (dsc {:?})", index_name, d.dtype)),
        }
    };
    let temp = format!("RDB$TEMP_DEPEND_{}_{}", rel, index_id.saturating_sub(1));
    for (fid, val) in [
        (name_fid, SysVal::S(&temp)),
        (inactive_fid, SysVal::I(4)), // MET_index_deferred_drop
    ] {
        let d = ix_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &val)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8)); // not NULL
    }
    dml::update_records(file, page_size, 4, &[(page, slot, image.clone())], ix_format_no)?;
    // the rename changed an INDEXED column of RDB$INDICES, so the new
    // key needs its own entries - the rewrite keeps the record's
    // position, so its record number is unchanged
    let seq = u32_at(
        crate::page_at(file, page_size, page).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + slot as u64;
    let values = decode_record(&image, &ix_descs);
    maintain_indexes(file, page_size, 4, recno, &values, &ix_descs)?;
    let seg_fid = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    delete_catalog_rows(file, page_size, "RDB$INDEX_SEGMENTS", |v| {
        text_eq(v.get(seg_fid), &want)
    })?;
    // the index-root slot: irt_drop, flags cleared, root page kept
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + index_id.saturating_sub(1) * 24;
    if at + 24 > page.len() {
        return Err("index slot beyond the root page".into());
    }
    // irt_drop (6) with the flags cleared: the SETTLED shape an
    // engine-dropped index reaches (fcstat reads exactly this back off
    // an engine file once the dropping transaction is old). The engine
    // passes through irt_commit (5) first because its DDL runs inside a
    // transaction that has yet to commit; this writer's statement is
    // already committed when it returns, so the settled state is the
    // honest one - and it is the one gfix validates as clean, since a
    // state-5 index is still scanned while its segment rows are gone
    dml::put_u16(page, at + 18, 0); // irt_flags
    page[at + 20] = 6; // irt_drop (ods.h:456)
    Ok(())
}

/// Whether a column's `RDB$RELATION_FIELDS.RDB$NULL_FLAG` is set.
fn column_is_not_null(file: &crate::Image, page_size: usize, table: &str, col_up: &str) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS") else {
        return false;
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS") else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rn_f), Some(fn_f), Some(nf_f)) = (
        fid("RDB$RELATION_NAME"),
        fid("RDB$FIELD_NAME"),
        fid("RDB$NULL_FLAG"),
    ) else {
        return false;
    };
    let mut not_null = false;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_eq(values.get(rn_f), table) && text_eq(values.get(fn_f), col_up) {
            not_null = int_eq(values.get(nf_f), 1);
        }
    });
    not_null
}

/// The next generated `INTEG_<n>` constraint name, read from the catalog
/// as it now stands (every writer takes its number this way, so the
/// sequence advances across mixed constraint kinds the way the engine's
/// does).
fn next_integ_name(file: &crate::Image, page_size: usize) -> Result<String, String> {
    let n = next_numeric_suffix(
        file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", "INTEG_",
    )?;
    Ok(format!("INTEG_{}", n))
}

/// Emit a `blr_field ctx <name>` operand (blr_field, context, len, name).
fn blr_field(b: &mut Vec<u8>, ctx: u8, name: &str) {
    b.push(23);
    b.push(ctx);
    b.push(name.len() as u8);
    b.extend_from_slice(name.as_bytes());
}

/// The BLR of a referential-action trigger the engine synthesises on the
/// referenced (parent) table, single or multi column, matched byte for
/// byte. The child (context 2) is scanned for rows keyed on the parent
/// row through OLD (context 0):
///
///   `FOR (child WHERE AND(child.fk_i = OLD.pk_i)) <action>`
///
/// wrapped, for the UPDATE event, in `IF OR(OLD.pk_i <> NEW.pk_i) THEN ...`.
/// The action is `ERASE` for a delete-cascade, or a `MODIFY` that assigns
/// each `child.fk_i` either `NEW.pk_i` (cascade) or `NULL` (set-null).
fn fk_trigger_blr(
    is_update: bool,
    action: RefAction,
    child_rel: &str,
    fk_cols: &[String],
    pk_cols: &[String],
) -> Vec<u8> {
    let set_null = action == RefAction::SetNull;
    let set_default = action == RefAction::SetDefault;
    let mut b = vec![5u8]; // blr_version5
    if set_default {
        // SET DEFAULT declares variables, so the whole trigger sits in a
        // begin..end; the default is fetched at RUNTIME, per column: a
        // PAIR of variables typed as the child column itself
        // (blr_column_name - flag 1 also carries the column's DEFAULT),
        // var2i := NULL, then a fault-swallowing block that initialises
        // var2i+1 (init_variable evaluates the declared default) and
        // copies it into var2i. A column with no default - or one whose
        // default fails to evaluate - leaves var2i NULL. Probed
        // byte-for-byte from the engine's own SET DEFAULT triggers.
        b.push(2); // blr_begin
        for (i, col) in fk_cols.iter().enumerate() {
            let v0 = (2 * i) as u16;
            let v1 = (2 * i + 1) as u16;
            for (v, flag) in [(v0, 0u8), (v1, 1u8)] {
                b.push(3); // blr_dcl_variable
                b.extend_from_slice(&v.to_le_bytes());
                b.push(21); // blr_column_name (dtype by column reference)
                b.push(flag);
                b.push(child_rel.len() as u8);
                b.extend_from_slice(child_rel.as_bytes());
                b.push(col.len() as u8);
                b.extend_from_slice(col.as_bytes());
            }
            b.push(1); // blr_assignment: NULL -> var2i
            b.push(45); // blr_null
            b.push(26); // blr_variable
            b.extend_from_slice(&v0.to_le_bytes());
            b.push(129); // blr_block
            b.push(2); // blr_begin
            b.push(184); // blr_init_variable var2i+1 (evaluates the default)
            b.extend_from_slice(&v1.to_le_bytes());
            b.push(1); // blr_assignment: var2i+1 -> var2i
            b.push(26);
            b.extend_from_slice(&v1.to_le_bytes());
            b.push(26);
            b.extend_from_slice(&v0.to_le_bytes());
            b.push(255); // blr_end (the block's begin)
            // blr_error_handler, 1 condition (any error), empty body
            b.extend_from_slice(&[130, 1, 0, 4, 2]);
            b.extend_from_slice(&[255, 255]); // end handler, end block
        }
    }
    if is_update {
        b.push(8); // blr_if
        // OR chain of OLD.pk_i <> NEW.pk_i
        for (i, pk) in pk_cols.iter().enumerate() {
            if i + 1 < pk_cols.len() {
                b.push(57); // blr_or
            }
            b.push(48); // blr_neq
            blr_field(&mut b, 0, pk);
            blr_field(&mut b, 1, pk);
        }
        b.push(2); // blr_begin (then branch)
        b.push(2); // blr_begin
    }
    b.push(7); // blr_for
    // the RSE: FOR (child WHERE AND(child.fk_i = OLD.pk_i))
    b.push(67); // blr_rse
    b.push(1); // stream count 1
    b.push(74); // blr_relation
    b.push(child_rel.len() as u8);
    b.extend_from_slice(child_rel.as_bytes());
    b.push(2); // context 2
    b.push(71); // blr_boolean
    for i in 0..fk_cols.len() {
        if i + 1 < fk_cols.len() {
            b.push(58); // blr_and
        }
        b.push(47); // blr_eql
        blr_field(&mut b, 2, &fk_cols[i]);
        blr_field(&mut b, 0, &pk_cols[i]);
    }
    b.push(255); // blr_end (rse)

    if !is_update && action == RefAction::Cascade {
        // delete cascade: ERASE the child row
        b.push(5); // blr_erase
        b.push(2); // context 2
    } else {
        // MODIFY: set each child.fk_i to NEW.pk_i (cascade), NULL
        // (set-null), or the runtime-fetched default in var2i
        b.push(10); // blr_modify
        b.push(2); // from context 2
        b.push(2); // to context 2
        b.push(2); // blr_begin
        for i in 0..fk_cols.len() {
            b.push(1); // blr_assignment
            if set_null {
                b.push(45); // blr_null
            } else if set_default {
                b.push(26); // blr_variable var2i
                b.extend_from_slice(&((2 * i) as u16).to_le_bytes());
            } else {
                blr_field(&mut b, 1, &pk_cols[i]); // NEW.pk_i
            }
            blr_field(&mut b, 2, &fk_cols[i]); // child.fk_i (target)
        }
        b.push(255); // blr_end (modify's begin)
        if is_update {
            b.extend_from_slice(&[255, 255, 255]); // for / begin / begin
        }
    }
    if set_default {
        b.push(255); // blr_end (the outer begin)
    }
    b.push(76); // blr_eoc
    b
}

/// Store one FK-cascade system trigger on the referenced (parent) table -
/// a `RDB$TRIGGERS` row named `CHECK_<n>` (number from the
/// `RDB$TRIGGER_NAME` generator) plus the three `RDB$DEPENDENCIES` rows the
/// engine records (on the child relation, the child FK column and the
/// parent key column). `trigger_type` is 4 for AFTER UPDATE, 6 for AFTER
/// DELETE. The caller must also refresh the parent's `RDB$RUNTIME` so the
/// trigger is loaded ([update_relation_runtime]).
#[allow(clippy::too_many_arguments)]
fn store_fk_trigger(
    file: &mut crate::Image,
    page_size: usize,
    parent: &str,
    child_rel: &str,
    fk_cols: &[String],
    pk_cols: &[String],
    trigger_type: i64,
    blr: &[u8],
) -> Result<(), String> {
    let n = {
        let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
            .ok_or("no RDB$TRIGGER_NAME generator")?;
        gen::bump(file, page_size, slot, 1)?
    };
    let tname = format!("CHECK_{}", n);
    let rel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let blob = dml::insert_blob(file, page_size, rel, &[blr.to_vec()], 2)?; // subtype 2 = BLR
    sys_insert(
        file,
        page_size,
        "RDB$TRIGGERS",
        rel,
        &[
            ("RDB$TRIGGER_NAME", SysVal::S(&tname)),
            ("RDB$RELATION_NAME", SysVal::S(parent)),
            ("RDB$TRIGGER_SEQUENCE", SysVal::I(0)),
            ("RDB$TRIGGER_TYPE", SysVal::I(trigger_type)),
            ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(rel, blob))),
            ("RDB$TRIGGER_INACTIVE", SysVal::I(0)),
            ("RDB$SYSTEM_FLAG", SysVal::I(4)),
            ("RDB$FLAGS", SysVal::I(3)),
            ("RDB$VALID_BLR", SysVal::I(1)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
    let dep = |file: &mut crate::Image, on: &str, field: Option<&str>| -> Result<(), String> {
        let mut row = vec![
            ("RDB$DEPENDENT_NAME", SysVal::S(&tname)),
            ("RDB$DEPENDED_ON_NAME", SysVal::S(on)),
            ("RDB$DEPENDENT_TYPE", SysVal::I(2)),   // obj_trigger
            ("RDB$DEPENDED_ON_TYPE", SysVal::I(0)), // obj_relation
            ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if let Some(f) = field {
            row.push(("RDB$FIELD_NAME", SysVal::S(f)));
        }
        let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES relation")?;
        sys_insert(file, page_size, "RDB$DEPENDENCIES", drel, &row)
    };
    for fk_col in fk_cols {
        dep(file, child_rel, Some(fk_col))?;
    }
    dep(file, child_rel, None)?;
    for pk_col in pk_cols {
        dep(file, parent, Some(pk_col))?;
    }
    Ok(())
}

/// Rebuild a relation's `RDB$RUNTIME` and patch it into the RDB$RELATIONS
/// row in place - the way to make a newly written trigger loadable, since
/// [rebuild_runtime_blob] now folds the relation's trigger names into the
/// summary the engine loads triggers from.
fn update_relation_runtime(file: &mut crate::Image, page_size: usize, table: &str) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let runtime = rebuild_runtime_blob(file, page_size, table, &descs)?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    let nm = table.to_string();
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        move |v| text_eq(v.get(name_fid), &nm),
        &[("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))],
    )
}

/// Write one FOREIGN KEY onto a table: the referencing index (irt_foreign,
/// naming the partner PK index, with the partner-schema column that makes
/// MET_lookup_partner find it - see [create_index]), the RDB$RELATION_
/// CONSTRAINTS 'FOREIGN KEY' row, the RDB$REF_CONSTRAINTS row linking to the
/// referenced table's PK constraint (MATCH FULL), and - for a CASCADE
/// action - the system trigger(s) the engine synthesises on the referenced
/// table (single column), refreshing that table's RDB$RUNTIME so they load.
/// Shared by create_table and ALTER TABLE ADD CONSTRAINT.
fn write_foreign_key_full(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk_name: &str,
    fk: &ForeignKeyDef,
    synth_triggers: bool,
) -> Result<(), String> {
    let (uq_constraint, partner_index) =
        find_partner_key(file, page_size, &fk.ref_table, &fk.ref_columns).ok_or_else(|| {
            if fk.ref_columns.is_empty() {
                format!("referenced table {} has no primary key", fk.ref_table)
            } else {
                format!(
                    "referenced table {} has no primary key or unique constraint on ({})",
                    fk.ref_table,
                    fk.ref_columns.join(", ")
                )
            }
        })?;
    create_index(
        file, page_size, table, fk_name, &fk.columns, false, false, false,
        Some(&partner_index),
    )?;
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(fk_name)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("FOREIGN KEY")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$INDEX_NAME", SysVal::S(fk_name)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    sys_row_by_name(file, page_size, "RDB$REF_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(fk_name)),
        ("RDB$CONST_NAME_UQ", SysVal::S(&uq_constraint)),
        ("RDB$MATCH_OPTION", SysVal::S("FULL")),
        ("RDB$UPDATE_RULE", SysVal::S(fk.on_update.rule())),
        ("RDB$DELETE_RULE", SysVal::S(fk.on_delete.rule())),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$CONST_SCHEMA_NAME_UQ", SysVal::S("PUBLIC")),
    ])?;

    // a CASCADE / SET NULL action synthesises a system trigger on the
    // referenced (parent) table - the update trigger first (the engine
    // numbers it CHECK_<lower>), then delete - and the parent's RDB$RUNTIME
    // is refreshed so the engine loads them
    if synth_triggers
        && (fk.on_update != RefAction::Restrict || fk.on_delete != RefAction::Restrict)
    {
        let parent = fk.ref_table.trim().to_ascii_uppercase();
        let pk_cols = if fk.ref_columns.is_empty() {
            index_segment_columns(file, page_size, &partner_index)?
        } else {
            fk.ref_columns.clone()
        };
        if fk.columns.len() != pk_cols.len() {
            return Err("foreign key column count does not match the referenced key".into());
        }
        let mut make = |is_update: bool, action: RefAction, ttype: i64| -> Result<(), String> {
            if action == RefAction::Restrict {
                return Ok(());
            }
            let blr = fk_trigger_blr(is_update, action, table, &fk.columns, &pk_cols);
            store_fk_trigger(file, page_size, &parent, table, &fk.columns, &pk_cols, ttype, &blr)
        };
        make(true, fk.on_update, 4)?;
        make(false, fk.on_delete, 6)?;
        update_relation_runtime(file, page_size, &parent)?;
    }
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] FOREIGN KEY (...)
/// REFERENCES ...`: add a foreign key to an EXISTING table. The FK index
/// is built and backfilled over the table's committed rows, then the
/// constraint catalog rows are written - the same shape create_table
/// produces, so the engine reads and gbak restores it identically.
pub fn alter_table_add_foreign_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk: &ForeignKeyDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let name = table.trim().to_ascii_uppercase();
    let fk_name = if fk.name.is_empty() {
        let integ = next_numeric_suffix(
            file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", "INTEG_",
        )?;
        format!("INTEG_{}", integ)
    } else {
        fk.name.clone()
    };
    write_foreign_key_full(file, page_size, &name, &fk_name, fk, true)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The gbak-restore variant: the referential-action TRIGGERS arrive
/// CARRIED in the file (the engine's own BLR, stored verbatim by the
/// caller), so this must not synthesise its own - two CHECK_<n>
/// triggers for one rule was the first restore's duplicate-key
/// failure, measured.
pub fn alter_table_add_foreign_key_carried(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk: &ForeignKeyDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let name = table.trim().to_ascii_uppercase();
    let fk_name = if fk.name.is_empty() {
        let integ = next_numeric_suffix(
            file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", "INTEG_",
        )?;
        format!("INTEG_{}", integ)
    } else {
        fk.name.clone()
    };
    write_foreign_key_full(file, page_size, &name, &fk_name, fk, false)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The referenced table's key a foreign key partners with: (constraint
/// name, index name), read from RDB$RELATION_CONSTRAINTS. An FK's
/// RDB$REF_CONSTRAINTS row names the unique CONSTRAINT (INTEG_n or the
/// name it was given), and its index is the partner MET_lookup_partner
/// links to. With no referenced columns named, that is the table's
/// PRIMARY KEY; with columns named, it is the PRIMARY KEY or UNIQUE
/// constraint whose index carries exactly those columns in that order
/// (probed: `REFERENCES A1 (Y)` onto a UNIQUE(Y) links the FK to the
/// UNIQUE constraint and its index, not the table's primary key).
/// A table's PRIMARY KEY column names in key order, from
/// `RDB$RELATION_CONSTRAINTS` + `RDB$INDEX_SEGMENTS` - `None` when the
/// table has no primary key. The wire server's UPDATE OR INSERT takes
/// this as its implicit MATCHING list, exactly as the engine does
/// (StmtNodes.cpp `UpdateOrInsertNode`).
pub fn primary_key_columns(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<Vec<String>> {
    let (_, index) = find_partner_key(file, page_size, table, &[])?;
    let cols = index_segment_names(file, page_size, &index);
    if cols.is_empty() { None } else { Some(cols) }
}

fn find_partner_key(
    file: &crate::Image,
    page_size: usize,
    ref_table: &str,
    ref_columns: &[String],
) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ct_f, rn_f, ix_f) = (
        fid("RDB$CONSTRAINT_NAME")?,
        fid("RDB$CONSTRAINT_TYPE")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$INDEX_NAME")?,
    );
    let want = ref_table.trim().to_ascii_uppercase();
    // every PRIMARY KEY / UNIQUE constraint of the referenced table,
    // primaries first (they win when both would fit)
    let mut candidates: Vec<(bool, String, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        let txt = |i: usize| match values.get(i) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        if txt(rn_f).as_deref().map(|s| s.eq_ignore_ascii_case(&want)) != Some(true) {
            return;
        }
        let primary = match txt(ct_f).as_deref() {
            Some("PRIMARY KEY") => true,
            Some("UNIQUE") => false,
            _ => return,
        };
        if let (Some(cn), Some(ix)) = (txt(cn_f), txt(ix_f)) {
            candidates.push((primary, cn, ix));
        }
    });
    candidates.sort_by_key(|(primary, _, _)| !*primary);
    if ref_columns.is_empty() {
        let (_, cn, ix) = candidates.into_iter().find(|(primary, _, _)| *primary)?;
        return Some((cn, ix));
    }
    candidates
        .into_iter()
        .find(|(_, _, ix)| {
            let segs = index_segment_names(file, page_size, ix);
            segs.len() == ref_columns.len()
                && segs
                    .iter()
                    .zip(ref_columns)
                    .all(|(a, b)| a.eq_ignore_ascii_case(b))
        })
        .map(|(_, cn, ix)| (cn, ix))
}

/// An index's columns in key order, from RDB$INDEX_SEGMENTS.
fn index_segment_names(file: &crate::Image, page_size: usize, index_name: &str) -> Vec<String> {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS") else {
        return Vec::new();
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS") else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(file, page_size, "RDB$INDEX_SEGMENTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(ix_f), Some(fn_f), Some(pos_f)) = (
        fid("RDB$INDEX_NAME"),
        fid("RDB$FIELD_NAME"),
        fid("RDB$FIELD_POSITION"),
    ) else {
        return Vec::new();
    };
    let mut segs: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        if !text_eq(values.get(ix_f), index_name) {
            return;
        }
        let pos = match values.get(pos_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        if let Some(Value::Text(t)) = values.get(fn_f) {
            segs.push((pos, t.trim_end().to_string()));
        }
    });
    segs.sort_by_key(|(pos, _)| *pos);
    segs.into_iter().map(|(_, n)| n).collect()
}

/// One past the highest numeric suffix of `<prefix><n>` names in a
/// catalog column - the INTEG_/RDB$PRIMARY sequences (the engine's own
/// name generators skip used names, so max+1 cannot collide later).
/// The next generated index number. The engine draws the `RDB$<n>` name
/// of an unnamed UNIQUE index and the `RDB$PRIMARY<n>` name of an
/// unnamed PRIMARY KEY index from ONE sequence (probed: a table
/// declaring UNIQUE then PRIMARY KEY got RDB$7 and RDB$PRIMARY8), so
/// both spellings are scanned and the higher successor wins.
fn next_index_number(file: &crate::Image, page_size: usize) -> Result<u64, String> {
    let plain = next_numeric_suffix(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME", "RDB$")?;
    let primary =
        next_numeric_suffix(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME", "RDB$PRIMARY")?;
    Ok(plain.max(primary))
}

fn next_numeric_suffix(
    file: &crate::Image,
    page_size: usize,
    rel_name: &str,
    col: &str,
    prefix: &str,
) -> Result<u64, String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    let formats = system_relation_formats(file, page_size, rel_name)
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let fid = relation_columns(file, page_size, rel_name)
        .iter()
        .find(|c| c.name == col)
        .map(|c| c.field_id as usize)
        .ok_or_else(|| format!("no {} column", col))?;
    let mut max = 0u64;
    walk_rows(file, page_size, rel, descs, |values| {
        if let Some(Value::Text(t)) = values.get(fid) {
            if let Some(num) = t.trim_end().strip_prefix(prefix)
                .and_then(|x| x.parse::<u64>().ok())
            {
                max = max.max(num);
            }
        }
    });
    Ok(max + 1)
}

/// [sys_insert] with the relation id resolved by name - for catalog
/// relations whose ids this module does not hardcode.
fn sys_row_by_name(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    sys_insert(file, page_size, rel_name, rel, values)
}

/// The index key type for a stored column (`DFW_assign_index_type`,
/// dfw.epp:1236) - None for a type this write path cannot key.
fn index_itype(d: &Descriptor) -> Option<u16> {
    use crate::format::dtype;
    Some(match d.dtype {
        dtype::SHORT | dtype::LONG | dtype::REAL | dtype::DOUBLE => btw::IDX_NUMERIC,
        dtype::INT64 => btw::IDX_NUMERIC2,
        dtype::INT128 => btw::IDX_BCD, // ODS >= 13.1 (dfw.epp)
        dtype::TEXT | dtype::VARYING => btw::IDX_STRING,
        dtype::SQL_DATE => 5,  // idx_sql_date
        dtype::SQL_TIME => 6,  // idx_sql_time
        dtype::TIMESTAMP => 7, // idx_timestamp
        dtype::BOOLEAN => 9,   // idx_boolean
        _ => return None,
    })
}

/// Whether an index of `index_name` already exists (any relation).
fn index_name_taken(file: &crate::Image, page_size: usize, index_name: &str) -> Result<bool, String> {
    let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_fid = relation_columns(file, page_size, "RDB$INDICES")
        .iter()
        .find(|c| c.name == "RDB$INDEX_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$INDEX_NAME column")?;
    let mut taken = false;
    walk_rows(file, page_size, irel, descs, |values| {
        if let Some(Value::Text(t)) = values.get(name_fid) {
            if t.trim_end().eq_ignore_ascii_case(index_name) {
                taken = true;
            }
        }
    });
    Ok(taken)
}

/// CREATE INDEX: a new irt slot (tx 0, state normal - the settled
/// shape every long-lived index shows; a freshly engine-created one
/// idles in state 2 until touched), the irtd segment array carved
/// downward from the irt page's tail (the engine's own allocation,
/// probe: slot0 at page_size-8, slot1 below it), an empty root
/// bucket, the RDB$PAGES + RDB$INDICES + RDB$INDEX_SEGMENTS rows, and
/// a BACKFILL: every existing committed row keyed and inserted, with
/// unique/primary enforcement - a duplicate fails the whole statement
/// exactly like the engine's index build does.
#[allow(clippy::too_many_arguments)]
pub fn create_index(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    index_name: &str,
    col_names: &[String],
    unique: bool,
    descending: bool,
    primary: bool,
    // Some(partner index) makes this a FOREIGN KEY index: the irt gets
    // irt_foreign and RDB$INDICES names the partner (referenced) PK/unique
    // index in RDB$FOREIGN_KEY (+ its schema). MET_lookup_partner links FK
    // to partner purely through these two columns (met.epp:2401-2412) - the
    // schema column is the ODS-14 field the older attempts missed.
    foreign_key: Option<&str>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    if index_name_taken(file, page_size, index_name)? {
        return Err(format!("index {} already exists", index_name));
    }
    let columns = relation_columns(file, page_size, table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;

    // segments: (field id, itype, scale) in key order
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for n in col_names {
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(n))
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs
            .get(rc.field_id as usize)
            .ok_or("field beyond format")?;
        // a COMPUTED column has no stored bytes to key on - the build
        // would index the null-flag area
        if d.offset == 0 && d.length != 0 {
            return Err(format!("column {} is computed - not indexable", n));
        }
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err("an index needs at least one column".into());
    }

    let mut iflags = 0u16;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    if primary {
        iflags |= btw::IRT_PRIMARY; // ods.h:462
    }
    if foreign_key.is_some() {
        iflags |= btw::IRT_FOREIGN; // ods.h:461
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;

    // catalog rows. NOTE: the bucket page is NOT registered in
    // RDB$PAGES - only pag_pointer/pag_root/pag_transactions/pag_ids
    // rows are legal there (DPM_scan_pages CORRUPTs on anything else,
    // engine-error 257 caught live); B-tree pages are reachable only
    // through the relation's index root slots
    let table_upper = table.to_ascii_uppercase();
    let mut ivals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$INDEX_NAME", SysVal::S(index_name)),
        ("RDB$RELATION_NAME", SysVal::S(&table_upper)),
        ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
        ("RDB$UNIQUE_FLAG", SysVal::I(if unique { 1 } else { 0 })),
        ("RDB$SEGMENT_COUNT", SysVal::I(segs.len() as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$INDEX_INACTIVE", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    // probe: a PK's RDB$INDEX_TYPE is NULL, a user index carries 0/1; a
    // FOREIGN KEY index also leaves RDB$INDEX_TYPE NULL (engine-probed)
    if !primary && foreign_key.is_none() {
        ivals.push(("RDB$INDEX_TYPE", SysVal::I(if descending { 1 } else { 0 })));
    }
    // a foreign-key index names its partner (referenced unique) index. Both
    // the name AND its schema are required: MET_lookup_partner's self-join
    // matches IND.RDB$SCHEMA_NAME EQ IDX.RDB$FOREIGN_KEY_SCHEMA_NAME
    // (met.epp:2408) - omitting the schema column leaves it NULL and the
    // partner lookup silently fails ("Partner index does not exist") at
    // gbak restore, which is what blocked the two earlier FK attempts.
    if let Some(partner) = foreign_key {
        ivals.push(("RDB$FOREIGN_KEY", SysVal::S(partner)));
        ivals.push(("RDB$FOREIGN_KEY_SCHEMA_NAME", SysVal::S("PUBLIC")));
    }
    sys_row_by_name(file, page_size, "RDB$INDICES", &ivals)?;
    for (pos, n) in col_names.iter().enumerate() {
        let upper = n.to_ascii_uppercase();
        sys_row_by_name(file, page_size, "RDB$INDEX_SEGMENTS", &[
            ("RDB$INDEX_NAME", SysVal::S(index_name)),
            ("RDB$FIELD_NAME", SysVal::S(&upper)),
            ("RDB$FIELD_POSITION", SysVal::I(pos as i64)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }

    backfill_index(
        file, page_size, rel, slot, &segs, descs, unique, descending, primary,
    )?;
    // the selectivity the engine computes at build time and keeps in
    // three places
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, index_name, &sel)
}

/// Take the first free index-root slot for a new index of `rel`: the
/// first repeat with no root page, its segment descriptors carved from
/// the page tail below the lowest in use, an empty root bucket
/// allocated, the repeat written `irt_normal`. Returns the slot -
/// `RDB$INDEX_ID - 1`.
fn allocate_index_slot(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    segs: &[(u16, u16, i8)],
    iflags: u16,
) -> Result<usize, String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    // find a free slot and the lowest descriptor offset, page-local on
    // the irt page; the borrow drops before allocate_page takes the file
    let (slot, lowest_desc) = {
        let page = crate::page_at(file, page_size, irt_page).ok_or("irt page out of range")?;
        let mut slot = None;
        let mut lowest_desc = page_size;
        for i in 0..((page_size - 24) / 24) {
            let at = 24 + i * 24;
            let root = u32_at(page, at + 8);
            if root == 0 {
                if slot.is_none() {
                    slot = Some(i);
                    break;
                }
            } else {
                lowest_desc = lowest_desc.min(u16_at(page, at + 16) as usize);
            }
        }
        (slot.ok_or("no free index slot")?, lowest_desc)
    };
    let desc_off = lowest_desc
        .checked_sub(8 * segs.len())
        .ok_or("irt page full")?;
    if 24 + (slot + 1) * 24 > desc_off {
        return Err("irt page full".into());
    }

    let root_page = dml::allocate_page(file, page_size)?;
    crate::page_mut(file, page_size, root_page)
        .expect("index root page out of range")
        .fill(0);
    btw::write_empty_root(file, page_size, root_page, rel, slot as u8)?;

    // the index-root entry, its segment descriptors and the count are all
    // on the irt page
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + slot * 24;
    page[at..at + 8].copy_from_slice(&0u64.to_le_bytes()); // irt_transaction
    dml::put_u32(page, at + 8, root_page);
    dml::put_u32(page, at + 12, 0); // page space
    dml::put_u16(page, at + 16, desc_off as u16);
    dml::put_u16(page, at + 18, iflags);
    page[at + 20] = 3; // irt_normal
    page[at + 21] = segs.len() as u8;
    page[at + 22] = 0;
    page[at + 23] = 0;
    for (i, (field, itype, _)) in segs.iter().enumerate() {
        let d = desc_off + i * 8;
        dml::put_u16(page, d, *field);
        dml::put_u16(page, d + 2, *itype);
        dml::put_u32(page, d + 4, 0); // selectivity, computed after the build
    }
    let count = u16_at(page, 18); // irt_count @18
    if (slot as u16) + 1 > count {
        dml::put_u16(page, 18, slot as u16 + 1);
    }
    Ok(slot)
}

/// Key every committed primary row of `rel` into the tree at `slot` -
/// what an index build (CREATE INDEX, ALTER INDEX ACTIVE, a key
/// constraint over existing rows) does. A duplicate under a unique or
/// primary index fails the whole statement, as the engine's build does.
#[allow(clippy::too_many_arguments)]
fn backfill_index(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
    segs: &[(u16, u16, i8)],
    descs: &[Descriptor],
    unique: bool,
    descending: bool,
    primary: bool,
) -> Result<(), String> {
    let recs = max_recs_per_dp(page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        let seq = dp.sequence as u64;
        let rows: Vec<(u16, Vec<Value>)> = dp
            .records()
            .filter(|r| r.is_primary_record())
            .filter_map(|r| {
                // ASSEMBLED, not `image()`. A fragmented row skipped here is
                // a row MISSING FROM THE INDEX THIS WRITES - and that index is
                // then read by the REAL engine, which returns nothing for a key
                // whose row plainly exists. Durable wrong state, not a bad plan.
                crate::data::assembled_image(file, page_size, &r)
                    .map(|img| (r.slot, decode_record(&img, descs)))
            })
            .collect();
        for (line, values) in rows {
            let recno = seq * recs + line as u64;
            let null = Value::Null;
            let key_segs: Vec<btw::KeySeg<'_>> = segs
                .iter()
                .map(|(field, itype, scale)| btw::KeySeg {
                    itype: *itype,
                    value: values.get(*field as usize).unwrap_or(&null),
                    scale: *scale,
                    charset: descs
                        .get(*field as usize)
                        .map_or(0, |d| crate::intl::charset_id(d.sub_type)),
                })
                .collect();
            let (key, all_null) = btw::build_index_key(&key_segs, descending)
                .ok_or("unsupported value for an index key")?;
            btw::insert_index_entry(
                file,
                page_size,
                rel,
                slot as u8,
                &key,
                recno,
                (unique && !all_null) || primary,
                descending,
            )?;
        }
    }
    Ok(())
}

/// Walk a system relation like [walk_rows], also yielding each row's
/// (data page, slot) - what [crate::dml::delete_records] targets.
fn walk_rows_at(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(u32, u16, &[Value]),
) {
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            cb(dp_no, r.slot, &decode_record(&image, descs));
        }
    }
}

/// Delete every row of a catalog relation the predicate accepts -
/// normal MVCC deletion (a stub over a version chain, the engine's
/// sweep collects both), which is also what keeps the catalog INDEX
/// entries valid: they point at deleted stubs, exactly as after an
/// engine-side DELETE.
fn delete_catalog_rows(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    pred: impl Fn(&[Value]) -> bool,
) -> Result<usize, String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    let formats = system_relation_formats(file, page_size, rel_name)
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let mut targets: Vec<(u32, u16)> = Vec::new();
    walk_rows_at(file, page_size, rel, descs, |page, slot, values| {
        if pred(values) {
            targets.push((page, slot));
        }
    });
    if targets.is_empty() {
        return Ok(0);
    }
    let out = dml::delete_records(file, page_size, rel, &targets)?;
    Ok(out.affected)
}

/// The field id of a named column in a system relation's computed
/// format.
fn sys_fid(file: &crate::Image, page_size: usize, rel_name: &str, col: &str) -> Result<usize, String> {
    relation_columns(file, page_size, rel_name)
        .iter()
        .find(|c| c.name == col)
        .map(|c| c.field_id as usize)
        .ok_or_else(|| format!("no {} column in {}", col, rel_name))
}

fn text_eq(v: Option<&Value>, want: &str) -> bool {
    matches!(v, Some(Value::Text(t)) if t.trim_end().eq_ignore_ascii_case(want))
}
fn int_eq(v: Option<&Value>, want: i64) -> bool {
    matches!(v, Some(Value::Int(i)) if *i == want)
}

/// DROP TABLE: the engine's `DPM_delete_relation` sequence against the
/// file image. Catalog rows in eight relations become normal deleted
/// stubs (the engine's own DROP does the same; its sweep collects the
/// chains AND the blobs their back versions still reference); the
/// RDB$PAGES rows are WIPED - they are system-transaction records with
/// no version chains, and the post-drop engine state has them
/// physically gone; every page the relation owned (data, pointer,
/// index root, every B-tree bucket, level-1 blob pages) is released
/// back to the PIP.
pub fn drop_table(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let name = name.trim().to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", name))?;
    if rel < 128 {
        return Err("system relations cannot be dropped".into());
    }

    // gather what the catalog says belongs to this table BEFORE
    // stubbing it: index names, constraint names, auto-domain names
    let mut index_names: Vec<String> = Vec::new();
    {
        let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
            .ok_or("no RDB$INDICES")?;
        let formats = system_relation_formats(file, page_size, "RDB$INDICES")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
        let rel_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, irel, descs, |values| {
            if text_eq(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(name_fid) {
                    index_names.push(t.trim_end().to_string());
                }
            }
        });
    }
    let mut constraint_names: Vec<String> = Vec::new();
    {
        let crel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
            .ok_or("no RDB$RELATION_CONSTRAINTS")?;
        let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let name_fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, crel, descs, |values| {
            if text_eq(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(name_fid) {
                    constraint_names.push(t.trim_end().to_string());
                }
            }
        });
    }
    let mut domain_names: Vec<String> = Vec::new();
    {
        let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let src_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_SOURCE")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, 5, descs, |values| {
            if text_eq(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(src_fid) {
                    let t = t.trim_end();
                    // only auto-domains die with the table
                    if t.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                        domain_names.push(t.to_string());
                    }
                }
            }
        });
    }

    // the relation's OWN security class, which dies with it. Its
    // RDB$DEFAULT_CLASS does NOT: the engine leaves the SQL$DEFAULT<n>
    // row behind (probe: after DROP TABLE only the SQL$<n> row is gone),
    // and so does this.
    let security_class = {
        let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let cls_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$SECURITY_CLASS")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let mut class = None;
        walk_rows(file, page_size, 6, descs, |values| {
            if text_eq(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(cls_fid) {
                    class = Some(t.trim_end().to_string());
                }
            }
        });
        class
    };

    // pages the relation owns - catalog-free page-type scans, plus the
    // page vectors of any level-1 blob slots on its data pages
    let mut pages: Vec<u32> = Vec::new();
    let data_pages = relation_data_pages(file, page_size, rel);
    for &dp_no in &data_pages {
        if let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) {
            for i in 0..dp.count {
                let Some(b) = dp.slot_bytes(i) else { continue };
                if b.len() >= 28 && u16_at(b, 10) & crate::data::flags::BLOB != 0 && b[27] == 1 {
                    let mut at = 28;
                    while at + 4 <= b.len() {
                        let pg = u32_at(b, at);
                        if pg == 0 {
                            break;
                        }
                        pages.push(pg);
                        at += 4;
                    }
                }
            }
        }
        pages.push(dp_no);
    }
    for (i, p) in file.pages().enumerate() {
        let owned = match p[0] {
            4 => u16_at(p, 26) == rel,  // pointer: ppg_relation
            6 => u16_at(p, 16) == rel,  // index root: irt_relation
            7 => u16_at(p, 28) == rel,  // B-tree bucket: btr_relation @28
            _ => false,
        };
        if owned {
            pages.push(i as u32);
        }
    }

    // catalog rows -> deleted stubs (version chains the engine sweeps)
    let idx_pred = |names: Vec<String>, fid: usize| {
        move |values: &[Value]| {
            names.iter().any(|n| text_eq(values.get(fid), n))
        }
    };
    {
        let fid = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$INDEX_SEGMENTS",
            idx_pred(index_names.clone(), fid))?;
    }
    let name2 = name.clone();
    {
        let fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$INDICES",
            move |values| text_eq(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS",
            idx_pred(constraint_names.clone(), fid))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATION_CONSTRAINTS",
            move |values| text_eq(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATION_FIELDS",
            move |values| text_eq(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$FIELDS",
            idx_pred(domain_names.clone(), fid))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FORMATS", "RDB$RELATION_ID")?;
        delete_catalog_rows(file, page_size, "RDB$FORMATS",
            move |values| int_eq(values.get(fid), rel as i64))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATIONS",
            move |values| text_eq(values.get(fid), &n))?;
    }
    // the security catalog: the relation's class row and every privilege
    // granted ON the relation (object type 0 - a sequence of the same
    // name keeps its own)
    if let Some(class) = security_class {
        let fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES",
            move |values| text_eq(values.get(fid), &class))?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES",
            move |values| text_eq(values.get(rel_f), &n) && int_eq(values.get(obj_f), 0))?;
    }

    // RDB$PAGES rows: system-transaction records with no chains - wipe
    // the slots (the post-sweep engine state); rel 0 has no indexes,
    // so no entries dangle
    {
        let formats = system_relation_formats(file, page_size, "RDB$PAGES")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let fid = sys_fid(file, page_size, "RDB$PAGES", "RDB$RELATION_ID")?;
        let mut targets: Vec<(u32, u16)> = Vec::new();
        walk_rows_at(file, page_size, 0, descs, |page, slot, values| {
            if int_eq(values.get(fid), rel as i64) {
                targets.push((page, slot));
            }
        });
        for (page, slot) in targets {
            let p = crate::page_mut(file, page_size, page).expect("RDB$PAGES page out of range");
            let dir = DPG_RPT_OFFSET + slot as usize * 4;
            dml::put_u16(p, dir, 0);
            dml::put_u16(p, dir + 2, 0);
        }
    }

    // release every owned page back to the PIP
    pages.sort_unstable();
    pages.dedup();
    for p in pages {
        dml::release_page(file, page_size, p)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}


/// Rewrite named columns of ONE system-relation row in place, at its
/// current format. The row keeps its position (so its record number,
/// and every index entry pointing at it, stay valid) - which is only
/// safe for columns no index of the relation keys; a keyed column needs
/// [maintain_indexes] afterwards, as the deferred index drop does.
fn patch_sys_row(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let formats =
        system_relation_formats(file, page_size, rel_name).ok_or("no computed system format")?;
    let (page, slot) = find_sys_row_slot(file, page_size, rel_name, rel, pred)
        .ok_or_else(|| format!("no matching {} row", rel_name))?;
    // THE ROW'S OWN FORMAT, NOT THE NEWEST ONE.
    //
    // This used to take `formats.iter().max_by_key(...)` - the relation's
    // LATEST format - and then poke the image at that format's field
    // OFFSETS and re-stamp the record with that format NUMBER. The image
    // itself was decoded at the record's own format, so on a row written
    // under an older format the poke landed on the wrong bytes AND the
    // row was relabelled as the newer shape, which makes every later read
    // decode the WHOLE row at offsets it was never written with.
    //
    // It leaves a file `gfix -v -full` calls clean, which is the worst
    // kind: the page structure is intact and only the values are wrong.
    // It needs a system relation carrying more than one format to fire,
    // so it has been latent rather than absent - and it is reachable on
    // ORDINARY rows, nothing to do with fragmentation.
    let (mut image, format_no, fragmented) = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        let r = dp.record(slot).ok_or("no row image")?;
        let frag = r.flags & crate::data::flags::INCOMPLETE != 0;
        // A FRAGMENTED ROW IS READ WHOLE and patched in its head. Reading
        // with `image()` answered None here, which is what refused 88
        // COMMENT ON and 92 DROP INDEX statements on an ordinary restored
        // database - see [dml::patch_head_in_place] for why the head is
        // enough and what happens when it is not.
        let img = crate::data::assembled_image(file, page_size, &r).ok_or("no row image")?;
        (img, r.format, frag)
    };
    let descs = formats
        .iter()
        .find(|(n, _)| *n == format_no)
        .map(|(_, d)| d.clone())
        .ok_or("the row's format is not among the relation's computed formats")?;
    let columns = relation_columns(file, page_size, rel_name);
    // which byte ranges the loop below actually changes, so a fragmented
    // row can be patched by range instead of rewritten whole
    let mut touched: Vec<(usize, usize)> = Vec::new();
    for (name, v) in values {
        let fid = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| format!("unknown catalog column {}", name))?
            .field_id as usize;
        if let SysVal::Null = v {
            image[fid / 8] |= 1 << (fid % 8); // NULL
            continue;
        }
        let d = descs.get(fid).ok_or("field beyond computed format")?;
        let bytes = encode_sys_value(d, v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than its format")?
            .copy_from_slice(&bytes);
        touched.push((at, bytes.len()));
        image[fid / 8] &= !(1 << (fid % 8)); // not NULL
    }
    if fragmented {
        // Only the bytes that actually changed, as offsets into the
        // assembled image - which for a fragmented record begins with the
        // head's own bytes, so an offset inside the head is the same
        // offset either way. `patch_head_in_place` re-checks that every
        // range lands in the head and refuses otherwise.
        let mut pokes: Vec<(usize, Vec<u8>)> = Vec::new();
        for (at, len) in touched {
            pokes.push((at, image[at..at + len].to_vec()));
        }
        // the null-flag bytes are at the very front, so they are always
        // in the head
        pokes.push((0, image[..crate::format::flag_bytes(descs.len())].to_vec()));
        dml::patch_head_in_place(file, page_size, page, slot, &pokes)?;
    } else {
        dml::update_records(file, page_size, rel, &[(page, slot, image)], format_no)?;
    }
    Ok(())
}

/// An index's selectivity, per key prefix: `1 / distinct` over the
/// relation's committed primary rows, counting a NULL key as a key
/// (engine probe: two all-NULL rows give 1.0). Prefix `i` covers
/// segments `0..=i`, so the last entry is the whole key's selectivity -
/// which is what `RDB$INDICES.RDB$STATISTICS` carries, while
/// `RDB$INDEX_SEGMENTS.RDB$STATISTICS` carries one per prefix. An empty
/// relation is 0.0, not 1/0.
///
/// The engine stores these as 4-byte floats both on the index root page
/// (`irtd_selectivity`) and in the catalog, so they are computed as f32.
fn index_selectivity(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    segs: &[(u16, u16, i8)],
    descending: bool,
) -> Result<Vec<f32>, String> {
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let mut distinct: Vec<std::collections::BTreeSet<Vec<u8>>> =
        vec![std::collections::BTreeSet::new(); segs.len()];
    let mut rows = 0usize;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = crate::data::assembled_image(file, page_size, &r) else { continue };
            let values = decode_record(&image, descs);
            rows += 1;
            let null = Value::Null;
            for prefix in 0..segs.len() {
                let key_segs: Vec<btw::KeySeg<'_>> = segs[..=prefix]
                    .iter()
                    .map(|(field, itype, scale)| btw::KeySeg {
                        itype: *itype,
                        value: values.get(*field as usize).unwrap_or(&null),
                        scale: *scale,
                        charset: descs
                            .get(*field as usize)
                            .map_or(0, |d| crate::intl::charset_id(d.sub_type)),
                    })
                    .collect();
                let (key, _) = btw::build_index_key(&key_segs, descending)
                    .ok_or("unsupported value for an index key")?;
                distinct[prefix].insert(key);
            }
        }
    }
    Ok(distinct
        .iter()
        .map(|d| {
            if rows == 0 || d.is_empty() {
                0.0
            } else {
                1.0 / d.len() as f32
            }
        })
        .collect())
}

/// Write an index's computed selectivity where the engine keeps it:
/// the `irtd_selectivity` float of each segment descriptor on the index
/// root page, `RDB$INDEX_SEGMENTS.RDB$STATISTICS` per segment, and
/// `RDB$INDICES.RDB$STATISTICS` (the whole key's, i.e. the last prefix).
fn write_index_statistics(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
    index_name: &str,
    selectivity: &[f32],
) -> Result<(), String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    {
        let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
        let at = 24 + slot * 24;
        let desc_off = u16_at(page, at + 16) as usize;
        for (i, sel) in selectivity.iter().enumerate() {
            let d = desc_off + i * 8 + 4;
            page.get_mut(d..d + 4)
                .ok_or("segment descriptor beyond the root page")?
                .copy_from_slice(&sel.to_le_bytes());
        }
    }
    let seg_name = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    let seg_pos = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_POSITION")?;
    let seg_rel = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS relation")?;
    for (i, sel) in selectivity.iter().enumerate() {
        patch_sys_row(
            file,
            page_size,
            "RDB$INDEX_SEGMENTS",
            seg_rel,
            |v| text_eq(v.get(seg_name), index_name) && int_eq(v.get(seg_pos), i as i64),
            &[("RDB$STATISTICS", SysVal::F(*sel as f64))],
        )?;
    }
    let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let whole = *selectivity.last().unwrap_or(&0.0);
    patch_sys_row(
        file,
        page_size,
        "RDB$INDICES",
        4,
        |v| text_eq(v.get(ix_name), index_name),
        &[("RDB$STATISTICS", SysVal::F(whole as f64))],
    )
}

/// A generator's `(RDB$GENERATOR_ID, RDB$SYSTEM_FLAG, RDB$SECURITY_CLASS)`
/// from `RDB$GENERATORS`, by name. None when there is no such generator.
fn find_generator(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<(i64, i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, sys_f, cls_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$GENERATOR_ID")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if found.is_some() || !text_eq(values.get(name_f), name) {
            return;
        }
        let id = match values.get(id_f) {
            Some(Value::Int(i)) => *i,
            _ => return,
        };
        let sys = match values.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match values.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((id, sys, class));
    });
    found
}

/// Whether a generator id is already spoken for - the condition the
/// engine's store loop discovers as a unique-key violation on
/// RDB$INDEX_46 and retries (DdlNodes.epp:6624).
fn generator_id_taken(file: &crate::Image, page_size: usize, id: i64) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$GENERATORS") else {
        return false;
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$GENERATORS") else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let Ok(id_f) = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_ID") else {
        return false;
    };
    let mut taken = false;
    walk_rows(file, page_size, rel, descs, |values| {
        if int_eq(values.get(id_f), id) {
            taken = true;
        }
    });
    taken
}

/// The privileges the owner of a SEQUENCE holds, in the order
/// `grant_privileges` emits them (acl.h): alter, control, drop, usage.
/// Differential probe of an engine-created sequence's `RDB$ACL`:
/// `02 01 03 06 SYSDBA 00 02 06 01 03 0c 00 00`.
const ACL_SEQUENCE_OWNER: &[u8] = &[6, 1, 3, 12];

/// The privileges the owner of a TABLE holds: the same three object
/// privileges - alter, control, drop - then insert, update, delete,
/// select and references. Probe of an engine-created table's `RDB$ACL`:
/// `02 01 03 06 SYSDBA 00 02 06 01 03 07 09 08 04 0a 00 00`.
const ACL_TABLE_OWNER: &[u8] = &[6, 1, 3, 7, 9, 8, 4, 10];

/// The privileges the owner of a ROLE holds: only the three object
/// privileges - alter, control, drop - with no usage (a role is not
/// something one holds a runtime privilege *on*). Probe of an
/// engine-created role's `RDB$ACL`: `02 01 03 06 SYSDBA 00 02 06 01 03 00 00`.
const ACL_ROLE_OWNER: &[u8] = &[6, 1, 3];

/// An owner's access control list for a newly created object, in the
/// engine's own encoding (acl.h): version 2, an id list naming the
/// owner as a person, then the privilege list for that kind of object.
fn owner_acl(owner: &str, privileges: &[u8]) -> Vec<u8> {
    let mut acl = vec![
        2u8, // ACL_version
        1,   // ACL_id_list
        3,   // id_person
        owner.len() as u8,
    ];
    acl.extend_from_slice(owner.as_bytes());
    acl.push(0); // id_end
    acl.push(2); // ACL_priv_list
    acl.extend_from_slice(privileges);
    acl.push(0); // priv_end
    acl.push(0); // ACL_end
    acl
}

/// Store one `RDB$SECURITY_CLASSES` row: the ACL blob (subtype 3) into
/// that relation's own data pages, then the row pointing at it. The
/// class name is the caller's `SQL$<n>`.
fn store_security_class(
    file: &mut crate::Image,
    page_size: usize,
    class: &str,
    owner: &str,
    privileges: &[u8],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let acl = dml::insert_blob(file, page_size, rel, &[owner_acl(owner, privileges)], 3)?;
    sys_insert(
        file,
        page_size,
        "RDB$SECURITY_CLASSES",
        rel,
        &[
            ("RDB$SECURITY_CLASS", SysVal::S(class)),
            ("RDB$ACL", SysVal::B(blob_id_bytes(rel, acl))),
        ],
    )
}

/// `CREATE SEQUENCE|GENERATOR <name> [START WITH <n>] [INCREMENT [BY]
/// <n>]` - the engine's `CreateAlterSequenceNode::executeCreate`
/// (DdlNodes.epp:6450) against the file image.
///
/// Three writes, in the engine's order. The id comes from the MASTER
/// generator - slot 0 of the generator vector, the counter every
/// metadata object id is drawn from (`DYN_UTIL_gen_unique_id(...,
/// MASTER_GENERATOR)`), taken modulo `MAX_SSHORT + 1` with zero skipped,
/// and retried while it collides with a live generator. Storing the row
/// makes `vio.cpp:4657` allocate a security class name from slot 1
/// (`RDB$SECURITY_CLASS`, the `SQL$<n>` counter), whose row carries the
/// owner's ACL, and `storePrivileges` records the owner's USAGE grant.
/// Finally the sequence's own slot is left holding `initial - step`, so
/// the first `GEN_ID`/`NEXT VALUE FOR` yields `initial` exactly.
///
/// Creating a sequence therefore *writes generator values* - two of
/// them - before it has a value of its own.
pub fn create_sequence(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    start: Option<i64>,
    increment: Option<i64>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a sequence needs a name".into());
    }
    if find_generator(file, page_size, &want).is_some() {
        return Err(format!("Sequence {} already exists", want));
    }
    let step = increment.unwrap_or(1);
    if step == 0 {
        return Err(format!(
            "INCREMENT BY 0 is an illegal option for sequence {}",
            want
        ));
    }
    let initial = start.unwrap_or(1);
    write_generator(file, page_size, &want, 0, initial, step)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// Write one `RDB$GENERATORS` row - a user sequence (`system_flag` 0) or an
/// implicit identity generator (`system_flag` 6). The id comes from the master
/// generator (modulo `MAX_SSHORT + 1`, never 0, never a live id); the row gets
/// an `SQL$<n>` security class with the owner's ACL and a USAGE privilege; and
/// the slot is primed to `initial - step` so the first draw yields `initial`.
/// Set a sequence's CURRENT value - what `gbak`'s restore does with
/// the value the backup carried (the engine's att_gen_value_int64):
/// the slot in the generator vector, not any catalog column.
pub fn set_sequence_value(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    value: i64,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (id, _, _) = find_generator(file, page_size, &want)
        .ok_or_else(|| format!("Sequence {} does not exist", want))?;
    gen::write(file, page_size, id, value)
}

fn write_generator(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    system_flag: i64,
    initial: i64,
    step: i64,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")
        .ok_or("no RDB$GENERATORS relation")?;
    let mut id = 0;
    for _ in 0..=u16::MAX {
        let next = gen::bump(file, page_size, gen::MASTER, 1)? % (i16::MAX as i64 + 1);
        if next != 0 && !generator_id_taken(file, page_size, next) {
            id = next;
            break;
        }
    }
    if id == 0 {
        return Err("no free generator id".into());
    }
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$GENERATORS",
        rel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$GENERATOR_NAME", SysVal::S(name)),
            ("RDB$GENERATOR_ID", SysVal::I(id)),
            ("RDB$SYSTEM_FLAG", SysVal::I(system_flag)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$INITIAL_VALUE", SysVal::I(initial)),
            ("RDB$GENERATOR_INCREMENT", SysVal::I(step)),
        ],
    )?;
    store_privileges(file, page_size, name, 14, &["G"])?;
    let stored = initial.wrapping_sub(step);
    if stored != 0 {
        gen::write(file, page_size, id, stored)?;
    }
    Ok(())
}

/// The next free system-generated `RDB$<n>` generator name (identity
/// generators): one past the highest numeric `RDB$<n>` in `RDB$GENERATORS`.
fn next_generator_number(file: &crate::Image, page_size: usize) -> u64 {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$GENERATORS"),
        system_relation_formats(file, page_size, "RDB$GENERATORS"),
    ) else {
        return 1;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return 1;
    };
    let name_f = match relation_columns(file, page_size, "RDB$GENERATORS")
        .iter()
        .find(|c| c.name == "RDB$GENERATOR_NAME")
    {
        Some(c) => c.field_id as usize,
        None => return 1,
    };
    let mut max = 0u64;
    walk_rows(file, page_size, rel, descs, |v| {
        if let Some(Value::Text(t)) = v.get(name_f) {
            if let Some(num) = t.trim_end().strip_prefix("RDB$") {
                if let Ok(n) = num.parse::<u64>() {
                    max = max.max(n);
                }
            }
        }
    });
    max + 1
}

/// The owner every fire-crab-written catalog object belongs to. The
/// server attaches as SYSDBA; the engine writes
/// `attachment->getEffectiveUserName()`.
const OWNER: &str = "SYSDBA";

/// The owner's `WITH GRANT OPTION` rows in `RDB$USER_PRIVILEGES` - one
/// per privilege letter, user type 8 (obj_user) and the object's own
/// type: 14 (obj_generator) for a sequence, 0 (obj_relation) for a
/// table. A sequence's owner gets 'G' (usaGe); a table's owner gets
/// S/I/U/D/R (select, insert, update, delete, references), the five
/// rows an engine-created table carries.
fn store_privileges(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    privileges: &[&str],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    for p in privileges {
        sys_insert(
            file,
            page_size,
            "RDB$USER_PRIVILEGES",
            rel,
            &[
                ("RDB$USER", SysVal::S(OWNER)),
                ("RDB$GRANTOR", SysVal::S(OWNER)),
                ("RDB$PRIVILEGE", SysVal::S(p)),
                ("RDB$GRANT_OPTION", SysVal::I(1)),
                ("RDB$RELATION_NAME", SysVal::S(name)),
                ("RDB$USER_TYPE", SysVal::I(8)),
                ("RDB$OBJECT_TYPE", SysVal::I(object_type)),
                ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
    }
    Ok(())
}

/// The privileges an engine-created table's owner holds, in the order
/// the engine stores them: select, insert, update, delete, references.
const TABLE_OWNER_PRIVILEGES: &[&str] = &["S", "I", "U", "D", "R"];

/// A relation's `(RDB$SECURITY_CLASS, RDB$OWNER_NAME, RDB$DEFAULT_CLASS)`
/// from RDB$RELATIONS.
fn relation_security(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<(String, String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, sc_f, own_f, dc_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$DEFAULT_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_none() && text_eq(v.get(name_f), table) {
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let dc = match v.get(dc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => String::new(),
            };
            found = Some((sc, own, dc));
        }
    });
    found
}

// --- the engine's ACL compiler (grant.epp / scl.epp), ported for the
//     relation + field privilege recompute ---

// SCL_* privilege flags (scl.h)
const SCL_SELECT: u32 = 1;
const SCL_DROP: u32 = 2;
const SCL_CONTROL: u32 = 4;
const SCL_ALTER: u32 = 16;
const SCL_INSERT: u32 = 64;
const SCL_DELETE: u32 = 128;
const SCL_UPDATE: u32 = 256;
const SCL_REFERENCES: u32 = 512;
const SCL_EXECUTE: u32 = 1024;
const SCL_USAGE: u32 = 2048;

/// A relation owner's privilege mask (grant.epp:121-128): control, drop,
/// alter, then the four DML and references.
const OWNER_RELATION_PRIVS: u32 = SCL_CONTROL
    | SCL_DROP
    | SCL_ALTER
    | SCL_REFERENCES
    | SCL_SELECT
    | SCL_INSERT
    | SCL_UPDATE
    | SCL_DELETE;

/// A procedure/function owner's privilege mask: alter, control, drop, execute
/// (probe: the owner ACE bytes are 6 1 3 11).
const OWNER_PROCEDURE_PRIVS: u32 = SCL_ALTER | SCL_CONTROL | SCL_DROP | SCL_EXECUTE;

/// A usage-object (sequence, exception) owner's privilege mask: alter,
/// control, drop, usage (probe: the owner ACE bytes are 6 1 3 12).
const OWNER_USAGE_PRIVS: u32 = SCL_ALTER | SCL_CONTROL | SCL_DROP | SCL_USAGE;

/// A SQL privilege letter to its SCL flag (grant.epp `trans_sql_priv`, the
/// letters a relation/field grant uses).
fn sql_priv_flag(letter: char) -> u32 {
    match letter.to_ascii_uppercase() {
        'S' => SCL_SELECT,
        'I' => SCL_INSERT,
        'U' => SCL_UPDATE,
        'D' => SCL_DELETE,
        'R' => SCL_REFERENCES,
        _ => 0,
    }
}

/// The ACL privilege bytes for a mask, in the `p_names` emission order
/// (scl.epp:94 - alter, control, drop, insert, update, delete, select,
/// references), which `SCL_move_priv` walks.
fn move_priv(mask: u32) -> Vec<u8> {
    const ORDER: &[(u32, u8)] = &[
        (SCL_ALTER, 6),
        (SCL_CONTROL, 1),
        (SCL_DROP, 3),
        (SCL_INSERT, 7),
        (SCL_UPDATE, 9),
        (SCL_DELETE, 8),
        (SCL_SELECT, 4),
        (SCL_REFERENCES, 10),
        (SCL_EXECUTE, 11),
        (SCL_USAGE, 12),
    ];
    ORDER
        .iter()
        .filter(|(f, _)| mask & f != 0)
        .map(|(_, c)| *c)
        .collect()
}

/// An ACL under construction: ordered (person, mask) entries; a `None`
/// person is the all-users wildcard.
type AclList = Vec<(Option<String>, u32)>;

/// grant_user (grant.epp:653): append a person's ACE, unless the mask is
/// empty (then nothing is added).
fn acl_grant_user(acl: &mut AclList, person: Option<String>, privs: u32) {
    if privs != 0 {
        acl.push((person, privs));
    }
}

/// squeeze_acl (grant.epp:1045): find a person's ACE, remove it, return
/// its privileges (0 if absent). The removal is what lets a re-grant move
/// the person to the end of the list.
fn acl_squeeze(acl: &mut AclList, person: &str) -> u32 {
    if let Some(i) = acl.iter().position(|(p, _)| p.as_deref() == Some(person)) {
        acl.remove(i).1
    } else {
        0
    }
}

/// Serialize an [AclList] to the engine's acl.h version-2 bytes.
fn acl_serialize(acl: &AclList) -> Vec<u8> {
    let mut out = vec![2u8]; // ACL_version
    for (person, privs) in acl {
        out.push(1); // ACL_id_list
        if let Some(name) = person {
            out.push(3); // id_person
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        out.push(0); // id_end
        out.push(2); // ACL_priv_list
        out.extend_from_slice(&move_priv(*privs));
        out.push(0); // priv_end
    }
    out.push(0); // ACL_end
    out
}

/// The recomputed security-class ACLs for a relation and its granted
/// fields.
struct RecomputedAcls {
    /// the relation's own class ACL bytes
    relation: Vec<u8>,
    /// (field name, that field's class ACL bytes), fields with grants
    fields: Vec<(String, Vec<u8>)>,
    /// the RDB$DEFAULT_CLASS ACL bytes, present only when field grants
    /// added relation-level ACEs (the engine's `restrct`)
    default: Option<Vec<u8>>,
}

/// Recompute a relation's ACLs from the privileges now in
/// `RDB$USER_PRIVILEGES`, a faithful port of the engine's
/// `GRANT_privileges` (grant.epp): the owner ACE, the relation-level
/// grantees alphabetically (each unioned with PUBLIC), then the field
/// grantees folded in with the squeeze-and-reappend that orders a person
/// by their last field. Each granted field gets its own class ACL (owner
/// + relation grantees + that field's grantees), and if field grants add
/// relation-level ACEs the default class is rebuilt without them.
fn recompute_acls(file: &crate::Image, page_size: usize, table: &str, owner: &str) -> RecomputedAcls {
    use std::collections::BTreeMap;
    let mut public_priv = 0u32;
    let mut rel_grantees: BTreeMap<String, u32> = BTreeMap::new();
    let mut field_rows: BTreeMap<(String, String), u32> = BTreeMap::new();

    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(p_f), Some(rn_f), Some(fn_f), Some(ot_f)) = (
                fid("RDB$USER"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$FIELD_NAME"),
                fid("RDB$OBJECT_TYPE"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if !text_eq(v.get(rn_f), table) || !int_eq(v.get(ot_f), 0) {
                        return;
                    }
                    let user = match v.get(u_f) {
                        Some(Value::Text(t)) => t.trim_end().to_string(),
                        _ => return,
                    };
                    if user.eq_ignore_ascii_case(owner) {
                        return; // the owner ACE is fixed, not read from rows
                    }
                    let flag = match v.get(p_f) {
                        Some(Value::Text(t)) => {
                            t.trim_end().chars().next().map_or(0, sql_priv_flag)
                        }
                        _ => 0,
                    };
                    if flag == 0 {
                        return;
                    }
                    match v.get(fn_f) {
                        Some(Value::Text(t)) => {
                            *field_rows.entry((t.trim_end().to_string(), user)).or_default() |= flag;
                        }
                        _ if user == "PUBLIC" => public_priv |= flag,
                        _ => *rel_grantees.entry(user).or_default() |= flag,
                    }
                });
            }
        }
    }

    // GRANT_privileges: owner, then relation-level grantees (get_user_privs)
    let mut acl: AclList = vec![(Some(owner.to_string()), OWNER_RELATION_PRIVS)];
    for (user, mask) in &rel_grantees {
        acl_grant_user(&mut acl, Some(user.clone()), public_priv | mask);
    }
    let base_len = acl.len();
    let acl_start = acl.clone();

    // save_field_privileges: fold field grantees into acl (squeeze+reappend)
    // and build each field's own class, walking (field, user) in order
    let mut aggregate_public = public_priv;
    let mut fields_out: Vec<(String, Vec<u8>)> = Vec::new();
    let mut cur_field: Option<String> = None;
    let mut field_acl = acl_start.clone();
    let mut field_public = 0u32;
    let finish_field =
        |name: String, mut fa: AclList, field_public: u32, public_priv: u32| -> (String, Vec<u8>) {
            if (field_public | public_priv) != 0 {
                fa.push((None, field_public | public_priv));
            }
            (name, acl_serialize(&fa))
        };
    for ((f, u), mask) in &field_rows {
        if cur_field.as_deref() != Some(f.as_str()) {
            if let Some(of) = cur_field.take() {
                aggregate_public |= field_public;
                fields_out.push(finish_field(of, field_acl.clone(), field_public, public_priv));
            }
            cur_field = Some(f.clone());
            field_public = 0;
            field_acl = acl_start.clone();
        }
        if u != "PUBLIC" {
            let fp = public_priv | mask | acl_squeeze(&mut field_acl, u);
            acl_grant_user(&mut field_acl, Some(u.clone()), fp);
            let rp = public_priv | mask | acl_squeeze(&mut acl, u);
            acl_grant_user(&mut acl, Some(u.clone()), rp);
        } else {
            field_public |= public_priv | mask;
        }
    }
    if let Some(of) = cur_field {
        aggregate_public |= field_public;
        fields_out.push(finish_field(of, field_acl, field_public, public_priv));
    }

    // finish the relation class (all-users wildcard) and, if field grants
    // added relation ACEs, the default class without them (restrct)
    let mut rel_final = acl.clone();
    if aggregate_public != 0 {
        rel_final.push((None, aggregate_public));
    }
    let default = if acl.len() != base_len {
        let mut da = acl_start;
        if public_priv != 0 {
            da.push((None, public_priv));
        }
        Some(acl_serialize(&da))
    } else {
        None
    };

    RecomputedAcls {
        relation: acl_serialize(&rel_final),
        fields: fields_out,
        default,
    }
}

/// Write (rewrite in place) a security class's `RDB$ACL` blob.
fn write_class_acl(
    file: &mut crate::Image,
    page_size: usize,
    class: &str,
    acl: &[u8],
) -> Result<(), String> {
    let screl = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let blob = dml::insert_blob(file, page_size, screl, &[acl.to_vec()], 3)?;
    let name_fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
    let cl = class.to_string();
    patch_sys_row(
        file,
        page_size,
        "RDB$SECURITY_CLASSES",
        screl,
        move |v| text_eq(v.get(name_fid), &cl),
        &[("RDB$ACL", SysVal::B(blob_id_bytes(screl, blob)))],
    )
}

/// A field's current `RDB$SECURITY_CLASS` (None if NULL/empty).
fn field_security_class(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    field: &str,
) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rn_f, fn_f, sc_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$FIELD_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(rn_f), table) && text_eq(v.get(fn_f), field) {
            if let Some(Value::Text(t)) = v.get(sc_f) {
                let t = t.trim_end();
                if !t.is_empty() {
                    out = Some(t.to_string());
                }
            }
        }
    });
    out
}

/// The fields of a relation that currently carry a `SQL$GRANT<n>` security
/// class (a column grant's class), as (field name, class name).
fn granted_field_classes(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS"),
        system_relation_formats(file, page_size, "RDB$RELATION_FIELDS"),
    ) else {
        return out;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return out;
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rn_f), Some(fn_f), Some(sc_f)) =
        (fid("RDB$RELATION_NAME"), fid("RDB$FIELD_NAME"), fid("RDB$SECURITY_CLASS"))
    else {
        return out;
    };
    walk_rows(file, page_size, rel, descs, |v| {
        if !text_eq(v.get(rn_f), table) {
            return;
        }
        if let (Some(Value::Text(fname)), Some(Value::Text(cls))) = (v.get(fn_f), v.get(sc_f)) {
            let cls = cls.trim_end();
            if cls.starts_with("SQL$GRANT") {
                out.push((fname.trim_end().to_string(), cls.to_string()));
            }
        }
    });
    out
}

/// Set (or clear, with `None`) a field's `RDB$RELATION_FIELDS.RDB$SECURITY_CLASS`.
fn set_field_security_class(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    field: &str,
    class: Option<&str>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS relation")?;
    let rn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let fn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, f) = (table.to_string(), field.to_string());
    let value = match class {
        Some(c) => SysVal::S(c),
        None => SysVal::Null,
    };
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        rel,
        move |v| text_eq(v.get(rn_f), &t) && text_eq(v.get(fn_f), &f),
        &[("RDB$SECURITY_CLASS", value)],
    )
}

/// Recompute and write a relation's own class ACL, every granted field's
/// class ACL (allocating a `SQL$GRANT<n>` class for a newly granted field,
/// dropping and clearing one whose last grant was revoked) and, when field
/// grants added relation-level ACEs, the default class.
fn recompute_relation_acl(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
) -> Result<(), String> {
    let (class, owner, default_class) = relation_security(file, page_size, table)
        .ok_or_else(|| format!("relation {} has no security class", table))?;
    let acls = recompute_acls(file, page_size, table, &owner);

    // the relation's own class
    write_class_acl(file, page_size, &class, &acls.relation)?;

    // each granted field's class (create SQL$GRANT<n> if the field has none)
    let granted: std::collections::BTreeSet<&str> =
        acls.fields.iter().map(|(f, _)| f.as_str()).collect();
    for (field, field_acl) in &acls.fields {
        let fclass = match field_security_class(file, page_size, table, field) {
            Some(c) => c,
            None => {
                let n = gen::bump(file, page_size, gen::SECURITY_CLASS, 1)?;
                let c = format!("SQL$GRANT{}", n);
                // the class row is stored with the field ACL itself
                let screl = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
                    .ok_or("no RDB$SECURITY_CLASSES relation")?;
                let blob = dml::insert_blob(file, page_size, screl, &[field_acl.clone()], 3)?;
                sys_insert(
                    file,
                    page_size,
                    "RDB$SECURITY_CLASSES",
                    screl,
                    &[
                        ("RDB$SECURITY_CLASS", SysVal::S(&c)),
                        ("RDB$ACL", SysVal::B(blob_id_bytes(screl, blob))),
                    ],
                )?;
                set_field_security_class(file, page_size, table, field, Some(&c))?;
                continue;
            }
        };
        write_class_acl(file, page_size, &fclass, field_acl)?;
    }

    // a field whose last grant was revoked: drop its class, clear the column
    for (field, fclass) in granted_field_classes(file, page_size, table) {
        if !granted.contains(field.as_str()) {
            let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
            let c = fclass.clone();
            delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
                text_eq(v.get(cls_f), &c)
            })?;
            set_field_security_class(file, page_size, table, &field, None)?;
        }
    }

    // the default class, only when field grants added relation-level ACEs
    if let Some(default_acl) = &acls.default {
        write_class_acl(file, page_size, &default_class, default_acl)?;
    }
    Ok(())
}


/// Whether a matching `RDB$USER_PRIVILEGES` row already exists - by
/// grantee, letter and field (`None` = the relation-level, NULL-field
/// row) - so a re-`GRANT` does not duplicate it.
fn priv_row_present(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    grantee: &str,
    letter: char,
    field: Option<&str>,
) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(u_f), Some(p_f), Some(rn_f), Some(fn_f)) = (
        fid("RDB$USER"),
        fid("RDB$PRIVILEGE"),
        fid("RDB$RELATION_NAME"),
        fid("RDB$FIELD_NAME"),
    ) else {
        return false;
    };
    let letter = letter.to_string();
    let mut present = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(rn_f), table)
            && text_eq(v.get(u_f), grantee)
            && text_eq(v.get(p_f), &letter)
            && match field {
                Some(f) => text_eq(v.get(fn_f), f),
                None => matches!(v.get(fn_f), None | Some(Value::Null)),
            }
        {
            present = true;
        }
    });
    present
}

/// `GRANT <privileges> [(<fields>)] ON [TABLE] <table> TO <grantees>
/// [WITH GRANT OPTION]` and its `REVOKE ... FROM` inverse - `GrantRevokeNode`
/// against the file image. Two effects, the engine's order: the
/// fine-grained rows of `RDB$USER_PRIVILEGES` (one per grantee per
/// privilege per field), and a recompute of the relation's security-class
/// ACLs ([recompute_relation_acl]).
///
/// With no `fields`, a relation-level grant, exactly as before. With
/// `fields`, a column grant: the same privilege letters carry a
/// `RDB$FIELD_NAME`, each granted column gets its own `SQL$GRANT<n>`
/// security class, and the recompute folds the field grantees into the
/// relation's own ACL too (see [recompute_acls]).
///
/// A grantee is any name (`PUBLIC` included, an ordinary `RDB$USER` row);
/// it need not exist. `GRANT` inserts a missing row (a re-grant is a
/// no-op); `REVOKE` deletes the matching rows, silently where there is
/// nothing to remove.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub fn grant_table(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    grantees: &[String],
    privileges: &[char],
    fields: &[String],
    grant_option: bool,
    revoke: bool,
    option_only: bool,
) -> Result<(), String> {
    let table = table.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("Table \"{}\" not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    // a column grant validates its fields exist
    let field_list: Vec<String> = fields
        .iter()
        .map(|f| f.trim().trim_matches('"').to_ascii_uppercase())
        .collect();
    if !field_list.is_empty() {
        let have = relation_columns(file, page_size, &table);
        for f in &field_list {
            if !have.iter().any(|c| c.name.eq_ignore_ascii_case(f)) {
                return Err(format!("column {} does not exist in table/view \"{}\"", f, table));
            }
        }
    }
    // the field slots to write: one None for a relation grant, or one per column
    let slots: Vec<Option<&str>> = if field_list.is_empty() {
        vec![None]
    } else {
        field_list.iter().map(|f| Some(f.as_str())).collect()
    };

    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        for &letter in privileges {
            for &field in &slots {
                if revoke {
                    let (g, t, l) = (grantee.clone(), table.clone(), letter.to_string());
                    let want_field = field.map(|f| f.to_string());
                    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
                    let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
                    let p_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
                    let fn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$FIELD_NAME")?;
                    let matches_row = move |v: &[Value]| {
                        text_eq(v.get(rn_f), &t)
                            && text_eq(v.get(u_f), &g)
                            && text_eq(v.get(p_f), &l)
                            && match &want_field {
                                Some(f) => text_eq(v.get(fn_f), f),
                                None => matches!(v.get(fn_f), None | Some(Value::Null)),
                            }
                    };
                    if option_only {
                        // REVOKE GRANT OPTION FOR: keep the privilege, clear
                        // its grant option (the ACL does not carry it, so it
                        // is not recomputed)
                        patch_sys_row(
                            file,
                            page_size,
                            "RDB$USER_PRIVILEGES",
                            upriv,
                            matches_row,
                            &[("RDB$GRANT_OPTION", SysVal::I(0))],
                        )?;
                    } else {
                        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", matches_row)?;
                    }
                } else if !priv_row_present(file, page_size, &table, &grantee, letter, field) {
                    let letter = letter.to_string();
                    let mut row = vec![
                        ("RDB$USER", SysVal::S(&grantee)),
                        ("RDB$GRANTOR", SysVal::S(OWNER)),
                        ("RDB$PRIVILEGE", SysVal::S(&letter)),
                        ("RDB$GRANT_OPTION", SysVal::I(if grant_option { 1 } else { 0 })),
                        ("RDB$RELATION_NAME", SysVal::S(&table)),
                        ("RDB$USER_TYPE", SysVal::I(8)),
                        ("RDB$OBJECT_TYPE", SysVal::I(0)),
                        ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
                    ];
                    if let Some(f) = field {
                        row.push(("RDB$FIELD_NAME", SysVal::S(f)));
                    }
                    sys_insert(file, page_size, "RDB$USER_PRIVILEGES", upriv, &row)?;
                }
            }
        }
    }
    // REVOKE GRANT OPTION FOR touches only RDB$GRANT_OPTION, which the ACL
    // does not encode - so the ACL is left as it stands
    if !option_only {
        recompute_relation_acl(file, page_size, &table)?;
    }
    advance_oldest_transactions(file, page_size)
}

/// A procedure's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$PROCEDURES`.
fn procedure_owner_class(file: &crate::Image, page_size: usize, proc: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$PROCEDURE_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), proc) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// A non-relation object's (procedure, function, sequence) security-class ACL
/// from the grants now in `RDB$USER_PRIVILEGES`: the owner ACE (`owner_mask`),
/// then every other grantee with `grantee_flag`, alphabetically, with `PUBLIC`
/// (the all-users wildcard) last - the relation ordering. `object_type` and
/// `priv_letter` select the object's rows (procedure 5/`X`, function 15/`X`,
/// sequence 14/`G`).
fn build_object_acl(
    file: &crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    priv_letter: &str,
    owner: &str,
    owner_mask: u32,
    grantee_flag: u32,
) -> Vec<u8> {
    use std::collections::BTreeSet;
    let mut named: BTreeSet<String> = BTreeSet::new();
    let mut has_public = false;
    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f)) = (
                fid("RDB$USER"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$OBJECT_TYPE"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if text_eq(v.get(rn_f), name)
                        && text_eq(v.get(p_f), priv_letter)
                        && matches!(v.get(ot_f), Some(Value::Int(t)) if *t == object_type)
                    {
                        if let Some(Value::Text(u)) = v.get(u_f) {
                            let u = u.trim_end();
                            if u.eq_ignore_ascii_case(owner) {
                                // the owner's implicit full-privilege ACE
                            } else if u.eq_ignore_ascii_case("PUBLIC") {
                                has_public = true;
                            } else {
                                named.insert(u.to_string());
                            }
                        }
                    }
                });
            }
        }
    }
    let mut acl: AclList = vec![(Some(owner.to_string()), owner_mask)];
    for u in named {
        acl_grant_user(&mut acl, Some(u), grantee_flag);
    }
    if has_public {
        acl_grant_user(&mut acl, None, grantee_flag);
    }
    acl_serialize(&acl)
}

/// A function's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$FUNCTIONS`
/// (the packaged-function rows carry a package name; a standalone function's
/// `RDB$PACKAGE_NAME` is NULL, which is the one this grants on).
fn function_owner_class(file: &crate::Image, page_size: usize, func: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$FUNCTION_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let pkg_f = fid("RDB$PACKAGE_NAME");
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        let standalone = pkg_f.map_or(true, |f| matches!(v.get(f), None | Some(Value::Null)));
        if out.is_none() && standalone && text_eq(v.get(name_f), func) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// The shared core of a `GRANT` on a non-relation object (procedure,
/// function, sequence): write (or delete) the `RDB$USER_PRIVILEGES` rows for
/// the object (`priv_letter`/`object_type`), then recompute its security-class
/// ACL from `owner_mask` and `grantee_flag`. The procedure/function/sequence
/// analogue of [grant_table].
#[allow(clippy::too_many_arguments)]
fn grant_object(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    priv_letter: &str,
    owner: &str,
    class: &str,
    owner_mask: u32,
    grantee_flag: u32,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    let letter = priv_letter.chars().next().unwrap_or('X');
    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        if revoke {
            let (g, p, pl) = (grantee.clone(), name.to_string(), priv_letter.to_string());
            let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
            let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
            let pr_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
            let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
            delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
                text_eq(v.get(u_f), &g)
                    && text_eq(v.get(rn_f), &p)
                    && text_eq(v.get(pr_f), &pl)
                    && matches!(v.get(ot_f), Some(Value::Int(t)) if *t == object_type)
            })?;
        } else if !priv_row_present(file, page_size, name, &grantee, letter, None) {
            let row = vec![
                ("RDB$USER", SysVal::S(&grantee)),
                ("RDB$GRANTOR", SysVal::S(owner)),
                ("RDB$PRIVILEGE", SysVal::S(priv_letter)),
                ("RDB$GRANT_OPTION", SysVal::I(if grant_option { 1 } else { 0 })),
                ("RDB$RELATION_NAME", SysVal::S(name)),
                ("RDB$USER_TYPE", SysVal::I(8)),
                ("RDB$OBJECT_TYPE", SysVal::I(object_type)),
                ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ];
            sys_insert(file, page_size, "RDB$USER_PRIVILEGES", upriv, &row)?;
        }
    }
    let acl = build_object_acl(
        file,
        page_size,
        name,
        object_type,
        priv_letter,
        owner,
        owner_mask,
        grantee_flag,
    );
    write_class_acl(file, page_size, class, &acl)?;
    advance_oldest_transactions(file, page_size)
}

/// `GRANT EXECUTE ON PROCEDURE <p> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 5, privilege `X`).
pub fn grant_procedure(
    file: &mut crate::Image,
    page_size: usize,
    proc: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let proc = proc.trim().trim_matches('"').to_ascii_uppercase();
    let (owner, class) = procedure_owner_class(file, page_size, &proc)
        .ok_or_else(|| format!("Procedure {} not found", proc))?;
    grant_object(
        file, page_size, &proc, 5, "X", &owner, &class, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE,
        grantees, grant_option, revoke,
    )
}

/// `GRANT EXECUTE ON FUNCTION <f> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 15, privilege `X`).
pub fn grant_function(
    file: &mut crate::Image,
    page_size: usize,
    func: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let func = func.trim().trim_matches('"').to_ascii_uppercase();
    let (owner, class) = function_owner_class(file, page_size, &func)
        .ok_or_else(|| format!("Function {} not found", func))?;
    grant_object(
        file, page_size, &func, 15, "X", &owner, &class, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE,
        grantees, grant_option, revoke,
    )
}

/// A sequence's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$GENERATORS`.
fn generator_owner_class(file: &crate::Image, page_size: usize, seq: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), seq) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// `GRANT USAGE ON SEQUENCE|GENERATOR <s> TO <grantees> [WITH GRANT OPTION]`
/// and its `REVOKE ... FROM` inverse (object type 14, privilege `G`). The
/// owner ACE is alter/control/drop/usage; a grantee gets usage.
pub fn grant_sequence(
    file: &mut crate::Image,
    page_size: usize,
    seq: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let seq = seq.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, _) = find_generator(file, page_size, &seq)
        .ok_or_else(|| format!("Sequence {} not found", seq))?;
    if system != 0 {
        return Err("system generators are read-only".into());
    }
    let (owner, class) = generator_owner_class(file, page_size, &seq)
        .ok_or_else(|| format!("Sequence {} has no security class", seq))?;
    grant_object(
        file, page_size, &seq, 14, "G", &owner, &class, OWNER_USAGE_PRIVS, SCL_USAGE,
        grantees, grant_option, revoke,
    )
}

/// An exception's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$EXCEPTIONS`.
fn exception_owner_class(file: &crate::Image, page_size: usize, exc: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$EXCEPTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$EXCEPTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$EXCEPTION_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), exc) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// `GRANT USAGE ON EXCEPTION <e> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 7, privilege `G`).
pub fn grant_exception(
    file: &mut crate::Image,
    page_size: usize,
    exc: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let exc = exc.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &exc).is_none() {
        return Err(format!("Exception {} not found", exc));
    }
    let (owner, class) = exception_owner_class(file, page_size, &exc)
        .ok_or_else(|| format!("Exception {} has no security class", exc))?;
    grant_object(
        file, page_size, &exc, 7, "G", &owner, &class, OWNER_USAGE_PRIVS, SCL_USAGE,
        grantees, grant_option, revoke,
    )
}

/// A role's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$ROLES`.
fn role_owner_class(file: &crate::Image, page_size: usize, role: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")?;
    let formats = system_relation_formats(file, page_size, "RDB$ROLES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$ROLES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$ROLE_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), role) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// Whether a user already holds membership of a role (an `M` /
/// object-type-13 row in `RDB$USER_PRIVILEGES`).
fn role_member_present(file: &crate::Image, page_size: usize, role: &str, grantee: &str) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f)) = (
        fid("RDB$USER"),
        fid("RDB$RELATION_NAME"),
        fid("RDB$PRIVILEGE"),
        fid("RDB$OBJECT_TYPE"),
    ) else {
        return false;
    };
    let mut present = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(rn_f), role)
            && text_eq(v.get(u_f), grantee)
            && text_eq(v.get(p_f), "M")
            && int_eq(v.get(ot_f), 13)
        {
            present = true;
        }
    });
    present
}

/// Recompute a role's own security-class ACL: the owner (alter, control,
/// drop), then each member holding the role `WITH ADMIN OPTION`
/// (grant_option = 2) alphabetically, with the `drop` privilege the engine
/// gives an admin member (grant.epp maps a role membership to `"O"` =
/// drop). A member without the admin option is not in the ACL.
fn recompute_role_acl(file: &mut crate::Image, page_size: usize, role: &str) -> Result<(), String> {
    use std::collections::BTreeSet;
    let (owner, class) = role_owner_class(file, page_size, role)
        .ok_or_else(|| format!("role {} has no security class", role))?;
    let mut admins: BTreeSet<String> = BTreeSet::new();
    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f), Some(go_f)) = (
                fid("RDB$USER"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$OBJECT_TYPE"),
                fid("RDB$GRANT_OPTION"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if text_eq(v.get(rn_f), role)
                        && text_eq(v.get(p_f), "M")
                        && int_eq(v.get(ot_f), 13)
                        && int_eq(v.get(go_f), 2)
                    {
                        if let Some(Value::Text(t)) = v.get(u_f) {
                            let u = t.trim_end().to_string();
                            if !u.eq_ignore_ascii_case(&owner) {
                                admins.insert(u);
                            }
                        }
                    }
                });
            }
        }
    }
    let mut acl: AclList = vec![(Some(owner), SCL_ALTER | SCL_CONTROL | SCL_DROP)];
    for user in &admins {
        acl.push((Some(user.clone()), SCL_DROP));
    }
    write_class_acl(file, page_size, &class, &acl_serialize(&acl))
}

/// `GRANT <role> TO <grantees> [WITH ADMIN OPTION]` and its `REVOKE ...
/// FROM` inverse - role membership, `GrantRevokeNode` for `obj_sql_role`.
/// A membership is a `RDB$USER_PRIVILEGES` row: privilege `M`, object type
/// 13 (`obj_sql_role`), the role in `RDB$RELATION_NAME`, no schema, and
/// `RDB$GRANT_OPTION` = 2 for `WITH ADMIN OPTION` (not 1). Granting a role
/// recomputes the role's ACL - every admin-option member gets a `drop`
/// ACE. Unlike a table grant, the role must exist.
pub fn grant_role(
    file: &mut crate::Image,
    page_size: usize,
    role: &str,
    grantees: &[String],
    admin_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let role = role.trim().trim_matches('"').to_ascii_uppercase();
    if find_role(file, page_size, &role).is_none() {
        return Err(format!("SQL role \"{}\" does not exist", role));
    }
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        if revoke {
            let (g, r) = (grantee.clone(), role.clone());
            let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
            let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
            let p_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
            let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
            delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
                text_eq(v.get(rn_f), &r)
                    && text_eq(v.get(u_f), &g)
                    && text_eq(v.get(p_f), "M")
                    && int_eq(v.get(ot_f), 13)
            })?;
        } else if !role_member_present(file, page_size, &role, &grantee) {
            sys_insert(
                file,
                page_size,
                "RDB$USER_PRIVILEGES",
                upriv,
                &[
                    ("RDB$USER", SysVal::S(&grantee)),
                    ("RDB$GRANTOR", SysVal::S(OWNER)),
                    ("RDB$PRIVILEGE", SysVal::S("M")),
                    ("RDB$GRANT_OPTION", SysVal::I(if admin_option { 2 } else { 0 })),
                    ("RDB$RELATION_NAME", SysVal::S(&role)),
                    ("RDB$USER_TYPE", SysVal::I(8)),
                    ("RDB$OBJECT_TYPE", SysVal::I(13)),
                ],
            )?;
        }
    }
    recompute_role_acl(file, page_size, &role)?;
    advance_oldest_transactions(file, page_size)
}

/// Take the next `SQL$<n>` security class name from generator slot 1
/// (`RDB$SECURITY_CLASS`) and store its row with the owner's ACL. The
/// engine draws this name from the counter WITHOUT checking whether it
/// is free - unlike the generated INTEG_/RDB$ names, which skip what is
/// taken - and `RDB$SECURITY_CLASSES` has a unique index on the column
/// (RDB$INDEX_7). A writer that invented a name here without advancing
/// the counter would hand the engine a duplicate-key error on its next
/// DDL.
fn next_security_class(
    file: &mut crate::Image,
    page_size: usize,
    privileges: &[u8],
) -> Result<String, String> {
    let class = format!(
        "SQL${}",
        gen::bump(file, page_size, gen::SECURITY_CLASS, 1)?
    );
    store_security_class(file, page_size, &class, OWNER, privileges)?;
    Ok(class)
}

/// The same for a relation's `RDB$DEFAULT_CLASS`, whose `SQL$DEFAULT<n>`
/// names come from their own counter - generator slot 2, the system
/// generator actually named `SQL$DEFAULT`. It carries the same ACL as
/// the relation's own class.
fn next_default_class(file: &mut crate::Image, page_size: usize) -> Result<String, String> {
    let id = generator_id_by_name(file, page_size, "SQL$DEFAULT")
        .ok_or("no SQL$DEFAULT generator")?;
    let class = format!("SQL$DEFAULT{}", gen::bump(file, page_size, id, 1)?);
    store_security_class(file, page_size, &class, OWNER, ACL_TABLE_OWNER)?;
    Ok(class)
}

/// A system generator's id by name - the counters the DDL draws names
/// from live in `RDB$GENERATORS` like any other.
fn generator_id_by_name(file: &crate::Image, page_size: usize, name: &str) -> Option<i64> {
    find_generator(file, page_size, name).map(|(id, _, _)| id)
}

/// `DROP SEQUENCE|GENERATOR <name>` - `DropSequenceNode::execute`
/// (DdlNodes.epp:6665). The catalog rows go: the `RDB$GENERATORS` row,
/// its security class, and the privileges granted on it. A system
/// generator is refused ("Cannot delete system generator").
///
/// What does NOT happen is as instructive: the generator's VALUE stays
/// in the vector. Nothing zeroes the slot and nothing reclaims the id -
/// `delete_generator` (dfw.epp:2173) only checks dependencies - so a
/// dropped sequence leaves its last value behind as garbage, and the
/// next `CREATE SEQUENCE` takes a fresh id from the master generator
/// rather than reusing the hole.
pub fn drop_sequence(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, class) = find_generator(file, page_size, &want)
        .ok_or_else(|| format!("generator {} is not defined", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system generator {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$GENERATORS", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        // by name AND object type: a table may share the name (the
        // generator namespace is its own)
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 14)
        })?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// An exception's `(RDB$EXCEPTION_NUMBER, RDB$SYSTEM_FLAG,
/// RDB$SECURITY_CLASS)` from `RDB$EXCEPTIONS`, by name. None when there is
/// no such exception.
fn find_exception(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<(i64, i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$EXCEPTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$EXCEPTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, num_f, sys_f, cls_f) = (
        fid("RDB$EXCEPTION_NAME")?,
        fid("RDB$EXCEPTION_NUMBER")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_some() || !text_eq(v.get(name_f), name) {
            return;
        }
        let number = match v.get(num_f) {
            Some(Value::Int(i)) => *i,
            _ => return,
        };
        let sys = match v.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match v.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((number, sys, class));
    });
    found
}

/// `DROP PROCEDURE <name>` - the inverse of [create_procedure]: the
/// RDB$PROCEDURES row, its RDB$PROCEDURE_PARAMETERS rows, each
/// parameter's invented RDB$n domain (RDB$FIELDS), the security class
/// and the owner's grant. Refuses a name that is not there, and - the
/// fail-closed part - a procedure any RDB$DEPENDENCIES row still names
/// as depended-on (the engine's "there are N dependencies"; fire-crab
/// only writes those rows for the dependencies it tracks, so a
/// body-to-body call it never recorded cannot be caught here, a
/// recorded boundary).
pub fn drop_procedure(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    // the row, and its parameter domains, gathered before anything is
    // deleted
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES format")?;
    let (_, pdescs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
    let prel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    let pcols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let pname_f = pcols
        .iter()
        .find(|c| c.name == "RDB$PROCEDURE_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$PROCEDURE_NAME")?;
    let pcls_f = pcols
        .iter()
        .find(|c| c.name == "RDB$SECURITY_CLASS")
        .map(|c| c.field_id as usize);
    let mut found = false;
    let mut class: Option<String> = None;
    {
        let want = want.clone();
        walk_rows(file, page_size, prel, pdescs, |v| {
            if text_eq(v.get(pname_f), &want) {
                found = true;
                if let Some(cf) = pcls_f {
                    if let Some(Value::Text(t)) = v.get(cf) {
                        class = Some(t.trim_end().to_string());
                    }
                }
            }
        });
    }
    if !found {
        return Err(format!("Procedure {} not found", want));
    }
    // depended-on? refuse, as the engine does - for the dependencies
    // this server records
    if let Some(drel) = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES") {
        let dfmts = system_relation_formats(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES format")?;
        let (_, ddescs) = dfmts.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
        let dcols = relation_columns(file, page_size, "RDB$DEPENDENCIES");
        let don_f = dcols
            .iter()
            .find(|c| c.name == "RDB$DEPENDED_ON_NAME")
            .map(|c| c.field_id as usize);
        if let Some(don_f) = don_f {
            let mut deps = 0usize;
            let want = want.clone();
            walk_rows(file, page_size, drel, ddescs, |v| {
                if text_eq(v.get(don_f), &want) {
                    deps += 1;
                }
            });
            if deps > 0 {
                return Err(format!(
                    "cannot delete PROCEDURE {} - there are {} dependencies",
                    want, deps
                ));
            }
        }
    }
    // the parameter domains, before the parameter rows go
    let mut domains: Vec<String> = Vec::new();
    {
        let pprel = crate::resolve_relation(file, page_size, "RDB$PROCEDURE_PARAMETERS")
            .ok_or("no RDB$PROCEDURE_PARAMETERS relation")?;
        let ppfmts = system_relation_formats(file, page_size, "RDB$PROCEDURE_PARAMETERS")
            .ok_or("no format")?;
        let (_, ppdescs) = ppfmts.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
        let ppcols = relation_columns(file, page_size, "RDB$PROCEDURE_PARAMETERS");
        let pp_name_f = ppcols
            .iter()
            .find(|c| c.name == "RDB$PROCEDURE_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$PROCEDURE_NAME")?;
        let pp_src_f = ppcols
            .iter()
            .find(|c| c.name == "RDB$FIELD_SOURCE")
            .map(|c| c.field_id as usize);
        let want = want.clone();
        walk_rows(file, page_size, pprel, ppdescs, |v| {
            if text_eq(v.get(pp_name_f), &want) {
                if let Some(sf) = pp_src_f {
                    if let Some(Value::Text(t)) = v.get(sf) {
                        domains.push(t.trim_end().to_string());
                    }
                }
            }
        });
    }
    // now delete: procedure row, parameter rows, each domain, class, grant
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$PROCEDURES", move |v| {
            text_eq(v.get(pname_f), &want)
        })?;
    }
    {
        let pp_name_f = sys_fid(file, page_size, "RDB$PROCEDURE_PARAMETERS", "RDB$PROCEDURE_NAME")?;
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$PROCEDURE_PARAMETERS", move |v| {
            text_eq(v.get(pp_name_f), &want)
        })?;
    }
    let fname_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    for dom in domains {
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| {
            text_eq(v.get(fname_f), &dom)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 5)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// One parameter of a CREATE PROCEDURE, in the catalog's own terms.
#[derive(Clone, Debug, PartialEq)]
pub struct ProcParamDef {
    pub name: String,
    pub field_type: i16,
    pub length: u16,
    pub scale: i16,
    pub sub_type: i16,
}

/// `CREATE PROCEDURE` - the catalog rows the engine writes, measured
/// off an engine-created pair (P0/P1): an RDB$PROCEDURES row whose id
/// comes from the RDB$PROCEDURES generator, whose SOURCE blob is the
/// body text from its first non-space byte and whose BLR blob is the
/// dsql crate's byte-for-byte compile; one invented RDB$n domain per
/// parameter (the same counter table columns draw from); and one
/// RDB$PROCEDURE_PARAMETERS row per parameter, FIELD_SOURCE naming the
/// domain, mechanism 0. PROCEDURE_TYPE is 1 when a SUSPEND makes it
/// selectable, 2 otherwise; VALID_BLR is 1 - the engine executes what
/// this stores.
#[allow(clippy::too_many_arguments)]
pub fn create_procedure(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    ins: &[ProcParamDef],
    outs: &[ProcParamDef],
    selectable: bool,
    source: &str,
    blr: &[u8],
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a procedure needs a name".into());
    }
    let prel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    // already exists? refuse before any row lands
    {
        let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
            .ok_or("no RDB$PROCEDURES format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("no RDB$PROCEDURES format")?;
        let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
        let name_f = cols
            .iter()
            .find(|c| c.name == "RDB$PROCEDURE_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$PROCEDURE_NAME column")?;
        let mut dup = false;
        walk_rows(file, page_size, prel, descs, |v| {
            if text_eq(v.get(name_f), &want) {
                dup = true;
            }
        });
        if dup {
            return Err(format!("Procedure {} already exists", want));
        }
    }
    let slot = generator_id_by_name(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES generator")?;
    let id = gen::bump(file, page_size, slot, 1)?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    let src_blob =
        dml::insert_blob_cs(file, page_size, prel, &[source.as_bytes().to_vec()], 1, 4)?;
    let blr_blob = dml::insert_blob(file, page_size, prel, &[blr.to_vec()], 2)?;
    sys_insert(
        file,
        page_size,
        "RDB$PROCEDURES",
        prel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$PROCEDURE_NAME", SysVal::S(&want)),
            ("RDB$PROCEDURE_ID", SysVal::I(id)),
            ("RDB$PROCEDURE_INPUTS", SysVal::I(ins.len() as i64)),
            ("RDB$PROCEDURE_OUTPUTS", SysVal::I(outs.len() as i64)),
            ("RDB$PROCEDURE_SOURCE", SysVal::B(blob_id_bytes(prel, src_blob))),
            ("RDB$PROCEDURE_BLR", SysVal::B(blob_id_bytes(prel, blr_blob))),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            (
                "RDB$PROCEDURE_TYPE",
                SysVal::I(if selectable { 1 } else { 2 }),
            ),
            ("RDB$VALID_BLR", SysVal::I(1)),
        ],
    )?;
    // parameters: an invented domain each, then the parameter row
    let pprel = crate::resolve_relation(file, page_size, "RDB$PROCEDURE_PARAMETERS")
        .ok_or("no RDB$PROCEDURE_PARAMETERS relation")?;
    for (ptype, list) in [(0i64, ins), (1i64, outs)] {
        for (num, p) in list.iter().enumerate() {
            let domain_num = next_domain_number(file, page_size)?;
            let dom = format!("RDB${}", domain_num);
            let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
                ("RDB$FIELD_NAME", SysVal::S(&dom)),
                ("RDB$FIELD_TYPE", SysVal::I(p.field_type as i64)),
                ("RDB$FIELD_LENGTH", SysVal::I(p.length as i64)),
                ("RDB$FIELD_SCALE", SysVal::I(p.scale as i64)),
                ("RDB$SYSTEM_FLAG", SysVal::I(0)),
                ("RDB$OWNER_NAME", SysVal::S(OWNER)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ];
            if subtype_carried(p.field_type) {
                field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(p.sub_type as i64)));
            }
            // an exact-numeric parameter domain carries PRECISION 0 (an
            // engine-created INTEGER param row measured 0, not the 9 a
            // computed column gets) - a NULL here is what crashed the
            // engine's executor reading an fc-authored procedure
            if matches!(p.field_type, 7 | 8 | 16 | 26) {
                field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(0)));
            }
            if matches!(p.field_type, 14 | 37) {
                field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
                field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(p.length as i64)));
            }
            let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
                .ok_or("no RDB$FIELDS relation")?;
            sys_insert(file, page_size, "RDB$FIELDS", frel, &field_vals)?;
            sys_insert(
                file,
                page_size,
                "RDB$PROCEDURE_PARAMETERS",
                pprel,
                &[
                    ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                    ("RDB$PARAMETER_NAME", SysVal::S(&p.name)),
                    ("RDB$PROCEDURE_NAME", SysVal::S(&want)),
                    ("RDB$PARAMETER_NUMBER", SysVal::I(num as i64)),
                    ("RDB$PARAMETER_TYPE", SysVal::I(ptype)),
                    ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
                    ("RDB$PARAMETER_MECHANISM", SysVal::I(0)),
                    ("RDB$SYSTEM_FLAG", SysVal::I(0)),
                ],
            )?;
        }
    }
    // the owner's EXECUTE grant, object type 5
    store_privileges(file, page_size, &want, 5, &["X"])?;
    advance_oldest_transactions(file, page_size)
}

/// `CREATE EXCEPTION <name> <message>` - `CreateAlterExceptionNode`
/// (DdlNodes.epp) against the file image. The mirror of CREATE SEQUENCE:
/// a `RDB$EXCEPTIONS` row whose number comes from the system generator
/// *named* `RDB$EXCEPTIONS` (exceptions have their own counter, not the
/// master generator), a `SQL$<n>` security class carrying the owner's ACL
/// - the same alter/control/drop/usage a sequence owner holds - and the
/// owner's USAGE grant (object type 7, `obj_exception`). Unlike a
/// sequence there is no value of its own to store.
pub fn create_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("an exception needs a name".into());
    }
    if find_exception(file, page_size, &want).is_some() {
        return Err(format!("Exception {} already exists", want));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS relation")?;
    // the number: the system generator named RDB$EXCEPTIONS, one per
    // exception (1, 2, ...); DROP does not give it back
    let slot = generator_id_by_name(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS generator")?;
    let number = gen::bump(file, page_size, slot, 1)?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$EXCEPTIONS",
        rel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$EXCEPTION_NAME", SysVal::S(&want)),
            ("RDB$EXCEPTION_NUMBER", SysVal::I(number)),
            ("RDB$MESSAGE", SysVal::S(message)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ],
    )?;
    store_privileges(file, page_size, &want, 7, &["G"])?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER EXCEPTION <name> <message>` - `CreateAlterExceptionNode` in its
/// alter arm: the message is rewritten in place, the number and security
/// class untouched. The exception must exist ("Exception not found").
pub fn alter_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &want).is_none() {
        return Err(format!("Exception {} not found", want));
    }
    let erel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS relation")?;
    let name_fid = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$EXCEPTIONS",
        erel,
        move |v| text_eq(v.get(name_fid), &nm),
        &[("RDB$MESSAGE", SysVal::S(message))],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `CREATE OR ALTER EXCEPTION <name> <message>`: alter it if it exists
/// (keeping its number and class), otherwise create it.
pub fn create_or_alter_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &want).is_some() {
        alter_exception(file, page_size, name, message)
    } else {
        create_exception(file, page_size, name, message)
    }
}

/// `DROP EXCEPTION <name>` - `DropExceptionNode`. The mirror of
/// DROP SEQUENCE, but cleaner: the row, its security class *and* the
/// owner's privilege all go (an engine probe: after the drop the
/// `SQL$<n>` class row is gone, no orphan). The number counter is not
/// rewound - the next exception takes the following number.
pub fn drop_exception(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, class) = find_exception(file, page_size, &want)
        .ok_or_else(|| format!("Exception {} not found", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system exception {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$EXCEPTIONS", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 7)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// A role's `(RDB$SYSTEM_FLAG, RDB$SECURITY_CLASS)` from `RDB$ROLES`, by
/// name. None when there is no such role.
fn find_role(file: &crate::Image, page_size: usize, name: &str) -> Option<(i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")?;
    let formats = system_relation_formats(file, page_size, "RDB$ROLES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$ROLES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, sys_f, cls_f) = (
        fid("RDB$ROLE_NAME")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_some() || !text_eq(v.get(name_f), name) {
            return;
        }
        let sys = match v.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match v.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((sys, class));
    });
    found
}

/// `CREATE ROLE <name>` - `CreateRoleNode` (DdlNodes.epp) against the file
/// image. The leanest of the security objects: a `RDB$ROLES` row and a
/// `SQL$<n>` security class, and nothing else - no number generator (a
/// role has no number), no `RDB$USER_PRIVILEGES` rows (a role is not
/// something one is granted a privilege *on* by creating it). The owner's
/// ACL is alter/control/drop only, no usage ([ACL_ROLE_OWNER]).
///
/// The one on-disk subtlety: `RDB$SYSTEM_PRIVILEGES` is a CHAR(8) OCTETS,
/// and CREATE ROLE writes it as eight ZERO bytes (an empty system-privilege
/// bitmask) - not NULL, and not the spaces a text CHAR would pad with, so
/// it needs [SysVal::O].
pub fn create_role(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a role needs a name".into());
    }
    if find_role(file, page_size, &want).is_some() {
        return Err(format!("SQL role {} already exists", want));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")
        .ok_or("no RDB$ROLES relation")?;
    let class = next_security_class(file, page_size, ACL_ROLE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$ROLES",
        rel,
        &[
            ("RDB$ROLE_NAME", SysVal::S(&want)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SYSTEM_PRIVILEGES", SysVal::O(&[])),
        ],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP ROLE <name>` - `DropRoleNode`. The row and its security class go
/// (an engine probe: after the drop the `SQL$<n>` class is gone, no
/// orphan); a role owns no privileges of its own to remove.
pub fn drop_role(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (system, class) = find_role(file, page_size, &want)
        .ok_or_else(|| format!("Role {} not found", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system role {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$ROLES", "RDB$ROLE_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$ROLES", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Advance the header's oldest-transaction markers past every
/// transaction this DDL burned, mirroring what a clean engine detach
/// leaves behind (probe: fresh db OIT/OAT/OST/next = 8/9/9/10,
/// post-CREATE 18/19/19/20 - OIT = next-2): two phantom committed
/// transactions, the markers pointing at them. Not what fixed the
/// attach hang (that was RDB$PAGES needing system-transaction
/// records; attach was re-verified fine without this) - but leaving
/// OIT a dozen transactions behind next would misrepresent a cleanly
/// closed database and make every attach start with catch-up work.
fn advance_oldest_transactions(file: &mut crate::Image, page_size: usize) -> Result<(), String> {
    let t1 = dml::allocate_committed_tx(file, page_size)?;
    let t2 = dml::allocate_committed_tx(file, page_size)?;
    let _ = t2;
    let put = |file: &mut crate::Image, at: usize, v: u64| {
        if let Some(hdr) = crate::page_mut(file, page_size, 0) {
            hdr[at..at + 8].copy_from_slice(&v.to_le_bytes());
        }
    };
    put(file, 48, t1); // hdr_oldest_transaction @48
    put(file, 56, t2); // hdr_oldest_active @56
    put(file, 64, t2); // hdr_oldest_snapshot @64
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blob_id_bytes_round_trip() {
        let b = blob_id_bytes(8, 5);
        assert_eq!(&b[0..2], &8u16.to_le_bytes());
        assert_eq!(&b[4..8], &5u32.to_le_bytes());
    }

    /// Golden bytes probed from the engine's own SET DEFAULT triggers
    /// (RDB$TRIGGER_BLR of `FOREIGN KEY (X) REFERENCES P (ID) ON DELETE
    /// SET DEFAULT` and friends): the variable preamble that fetches the
    /// child column's default at RUNTIME, then the SET NULL skeleton
    /// assigning the variables, all inside an outer begin.
    #[test]
    fn set_default_trigger_blr_matches_engine() {
        let one = |s: &str| vec![s.to_string()];
        // ON DELETE SET DEFAULT, single column (probe table C1)
        let del = fk_trigger_blr(false, RefAction::SetDefault, "C1", &one("X"), &one("ID"));
        let want_hex = "05020300001500024331015803010015010243310158012D1A00008102B80100011A01001A0000FF8201000402FFFF0743014A02433102472F170201581700024944FF0A020202011A000017020158FFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(del, want);
        // ON UPDATE SET DEFAULT, single column (probe table C2)
        let upd = fk_trigger_blr(true, RefAction::SetDefault, "C2", &one("X"), &one("ID"));
        let want_hex = "05020300001500024332015803010015010243320158012D1A00008102B80100011A01001A0000FF8201000402FFFF08301700024944170102494402020743014A02433202472F170201581700024944FF0A020202011A000017020158FFFFFFFFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(upd, want);
        // ON DELETE SET DEFAULT, TWO columns (probe table C3): per-column
        // variable pairs (0,1) and (2,3), AND-chained match, both assigned
        let del2 = fk_trigger_blr(
            false,
            RefAction::SetDefault,
            "C3",
            &["X".to_string(), "Y".to_string()],
            &["A".to_string(), "B".to_string()],
        );
        let want_hex = "05020300001500024333015803010015010243330158012D1A00008102B80100011A01001A0000FF8201000402FFFF0302001500024333015903030015010243330159012D1A02008102B80300011A03001A0200FF8201000402FFFF0743014A02433302473A2F17020158170001412F1702015917000142FF0A020202011A000017020158011A020017020159FFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(del2, want);
    }

    #[test]
    fn format_blob_payload_shape() {
        // the descriptor pack must byte-match the engine's probe blob:
        // INTEGER at offset 4 in a 4-col format packs as
        // 09 00 04 00 00 00 00 00 04 00 00 00
        let descs = compute_format(&[
            (crate::format::dtype::LONG, 4, 0, 0),
            (crate::format::dtype::VARYING, 22, 0, 0),
            (crate::format::dtype::INT64, 8, 0, 0),
            (crate::format::dtype::SHORT, 2, 0, 0),
        ]);
        assert_eq!(descs.len(), 4);
        assert_eq!(
            (descs[0].offset, descs[1].offset, descs[2].offset, descs[3].offset),
            (4, 8, 32, 40) // FLAG_BYTES(4)=4; int64 aligns to 8
        );
        assert_eq!(flag_bytes(4), 4);
        let _ = (u16_at(&[0, 0], 0), DPG_RPT_OFFSET, RHD_DATA_OFFSET); // linkage
    }
}



