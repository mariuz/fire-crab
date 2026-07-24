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
use crate::sysfmt::{compute_format, system_relation_formats};
use crate::{u16_at, u32_at, Descriptor};

/// One column of a CREATE TABLE: its name, the external catalog type
/// code (`RDB$FIELD_TYPE`), and the storage descriptor pieces.
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
}

/// One table-level key constraint of a CREATE TABLE: a `PRIMARY KEY` or
/// a `UNIQUE`, named or not. Both are backed by a unique index; the
/// engine names that index after the constraint when the constraint is
/// named, and generates `RDB$PRIMARY<n>` / `RDB$<n>` when it is not.
pub struct KeyDef {
    /// constraint name, empty when the statement did not name it
    pub name: String,
    /// key columns, in key order
    pub columns: Vec<String>,
    /// PRIMARY KEY (true) or UNIQUE (false)
    pub primary: bool,
}

/// Values a system-catalog row is built from, keyed by column name.
enum SysVal<'a> {
    I(i64),
    S(&'a str),
    /// the 8 on-disk blob-id bytes
    B([u8; 8]),
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
    file: &[u8],
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(&[Value]),
) {
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
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
        (SysVal::B(id), dtype::BLOB) => id.to_vec(),
        _ => return Err("catalog value/type mismatch".into()),
    })
}

/// Insert one row into a system relation - image built at the
/// relation's computed (ini.epp-walk) format, EVERY index of the
/// relation maintained. This is what makes the row real to the
/// engine: its metadata lookups go through these indexes.
fn sys_insert(
    file: &mut Vec<u8>,
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
            SysVal::B(_) => Value::Null, // no catalog index covers a blob
        };
    }

    // RDB$PAGES rows must be system-transaction (tx 0) records - the
    // engine's get_header refuses anything else with isc_wrong_page
    let out = if rel == 0 {
        dml::insert_record_system(file, page_size, rel, format_no, &image)?
    } else {
        dml::insert_record(file, page_size, rel, format_no, &image)?
    };
    let seq = u32_at(file, out.page_no as usize * page_size + 16) as u64;
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
    file: &mut Vec<u8>,
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
        )?;
    }
    Ok(())
}

/// The next free `RDB$<n>` auto-domain number: one past the highest in
/// RDB$FIELDS. The engine's own generator skips used names, so this
/// cannot break later engine-side DDL.
fn next_domain_number(file: &[u8], page_size: usize) -> Result<u64, String> {
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
    file: &mut Vec<u8>,
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

/// Locate a system relation's primary row whose decoded values satisfy
/// `pred`: its data page and slot. For an in-place catalog update or
/// delete (ALTER).
fn find_sys_row_slot(
    file: &[u8],
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
) -> Option<(u32, u16)> {
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let dp = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
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
    file: &[u8],
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
        let start = dp_no as usize * page_size;
        let dp = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
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
    file: &mut Vec<u8>,
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

    // collect (field_id, name, source, position, not_null), by field id
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let int = |v: Option<&Value>| match v {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    };
    let mut fields: Vec<(u16, String, String, u16, bool)> = Vec::new();
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
        fields.push((id as u16, name, src, pos as u16, not_null));
    });
    fields.sort_by_key(|f| f.0);

    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    for (id, name, src, pos, not_null) in &fields {
        let d = descs.get(*id as usize).ok_or("field beyond format")?;
        runtime.push(seg(0, &id.to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, name.as_bytes())); // RSR_field_name
        let qsrc = format!("\"PUBLIC\".\"{}\"", src);
        runtime.push(seg(25, qsrc.as_bytes())); // RSR_field_source
        runtime.push(seg(19, &d.length.to_le_bytes())); // RSR_field_length
        let char_len = match d.dtype {
            dtype::VARYING => Some(d.length.saturating_sub(2)),
            dtype::TEXT => Some(d.length),
            _ => None,
        };
        if let Some(cl) = char_len {
            runtime.push(seg(26, &cl.to_le_bytes())); // RSR_character_length
        }
        runtime.push(seg(27, &pos.to_le_bytes())); // RSR_field_pos
        if *not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
    }
    dml::insert_blob(file, page_size, 6, &runtime, 5)
}

/// `ALTER TABLE <table> ADD <column>`: append one column to an existing
/// table. The engine models this as a new *format version* - existing
/// records keep their old format (and read the new column as NULL), new
/// records use the new one. The sequence mirrors the tail of
/// [create_table] for the single new field, plus a version rewrite of the
/// `RDB$RELATIONS` row to bump its `RDB$FORMAT` and field count.
pub fn alter_table_add_column(
    file: &mut Vec<u8>,
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
    let mut fields = descs_to_fields(cur_descs);
    fields.push((col.dtype, col.length, col.scale, col.sub_type));
    let new_descs = compute_format(&fields);
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
        ("RDB$FIELD_LENGTH", SysVal::I(col.length as i64)),
        ("RDB$FIELD_SCALE", SysVal::I(col.scale as i64)),
        ("RDB$FIELD_SUB_TYPE", SysVal::I(col.sub_type as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if let Some(cl) = col.char_len {
        field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
        field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        field_vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &field_vals)?;

    let mut rf_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&col.name)),
        ("RDB$RELATION_NAME", SysVal::S(&table)),
        ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
        ("RDB$FIELD_POSITION", SysVal::I(new_fid as i64)),
        ("RDB$UPDATE_FLAG", SysVal::I(1)),
        ("RDB$FIELD_ID", SysVal::I(new_fid as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if col.char_len.is_some() {
        rf_vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
    }
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
    file: &mut Vec<u8>,
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
    if cols.len() <= 1 {
        return Err("cannot drop the only column of a table".into());
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
    // replaced by a zero-length placeholder, the rest repacked
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let mut fields = descs_to_fields(cur_descs);
    fields[drop_fid] = (0, 0, 0, 0); // dropped-field placeholder
    let mut new_descs = compute_format(&fields);
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
    file: &mut Vec<u8>,
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

    // the new format: the target field's descriptor replaced, all repacked
    let mut fields = descs_to_fields(cur_descs);
    fields[fid] = (new_col.dtype, new_col.length, new_col.scale, new_col.sub_type);
    let new_descs = compute_format(&fields);

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
        let start = fpage as usize * page_size;
        let dp = DataPage::decode(file.get(start..start + page_size).ok_or("bad page")?)
            .ok_or("bad data page")?;
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

/// Whether any committed primary record of `rel` has a NULL in field
/// `fid` - the check `SET NOT NULL` makes before it can succeed.
fn column_has_nulls(file: &[u8], page_size: usize, rel: u16, fid: usize) -> bool {
    let formats = crate::relation_formats(file, page_size, rel);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
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
    file: &mut Vec<u8>,
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
        let start = page as usize * page_size;
        let dp = DataPage::decode(file.get(start..start + page_size).ok_or("bad page")?)
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
fn refresh_runtime(file: &mut Vec<u8>, page_size: usize, table: &str) -> Result<(), String> {
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
    file: &mut Vec<u8>,
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
    file: &mut Vec<u8>,
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

/// One `FOREIGN KEY (<columns>) REFERENCES <ref_table> [(<ref_columns>)]`
/// clause of a CREATE TABLE. `name` is the constraint name (also the FK
/// index name, as the engine names them the same).
pub struct ForeignKeyDef {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
}

pub fn create_table(
    file: &mut Vec<u8>,
    page_size: usize,
    name: &str,
    cols: &[ColumnDef],
    keys: &[KeyDef],
    fks: &[ForeignKeyDef],
) -> Result<(), String> {
    if cols.is_empty() {
        return Err("a table needs at least one column".into());
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

    // the physical format: field ids in declaration order (probe-pinned),
    // offsets by the ini.epp walk sysfmt already implements
    let fields: Vec<(u8, u16, i8, i16)> = cols
        .iter()
        .map(|c| (c.dtype, c.length, c.scale, c.sub_type))
        .collect();
    let descs = compute_format(&fields);
    if descs.len() != cols.len() {
        return Err("format computation failed".into());
    }

    // --- pages first (DPM_create_relation): pointer + index root ------
    let pointer_page = dml::allocate_page(file, page_size)?;
    let root_page = dml::allocate_page(file, page_size)?;
    {
        let base = pointer_page as usize * page_size;
        file[base..base + page_size].fill(0);
        file[base] = 4; // pag_pointer
        file[base + 1] = 1; // pag_flags = ppg_eof (last pointer page)
        dml::put_u32(file, base + 12, pointer_page); // pag_pageno
        dml::put_u16(file, base + 26, rel_id_u16); // ppg_relation @26
    }
    {
        let base = root_page as usize * page_size;
        file[base..base + page_size].fill(0);
        file[base] = 6; // pag_root
        dml::put_u32(file, base + 12, root_page); // pag_pageno
        dml::put_u16(file, base + 16, rel_id_u16); // irt_relation @16
        dml::put_u16(file, base + 18, 0); // irt_count
    }

    // --- the format descriptor blob (makeFormat) ---------------------
    let fmt_blob = write_format_blob(file, page_size, &descs)?;

    // --- the RDB$RUNTIME field summary (make_version): per field the
    // probe-pinned tag sequence ------------------------------------------
    let domain_base = next_domain_number(file, page_size)?;
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    for (i, c) in cols.iter().enumerate() {
        let dom = format!("RDB${}", domain_base + i as u64);
        runtime.push(seg(0, &(i as u16).to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, c.name.as_bytes())); // RSR_field_name
        let src = format!("\"PUBLIC\".\"{}\"", dom);
        runtime.push(seg(25, src.as_bytes())); // RSR_field_source
        runtime.push(seg(19, &c.length.to_le_bytes())); // RSR_field_length
        if let Some(cl) = c.char_len {
            runtime.push(seg(26, &cl.to_le_bytes())); // RSR_character_length
        }
        runtime.push(seg(27, &(i as u16).to_le_bytes())); // RSR_field_pos
        if c.not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
    }
    let runtime_blob = dml::insert_blob(file, page_size, 6, &runtime, 5)?;

    // --- catalog rows, each with its indexes maintained ---------------
    for (i, c) in cols.iter().enumerate() {
        let dom = format!("RDB${}", domain_base + i as u64);
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&dom)),
            ("RDB$FIELD_TYPE", SysVal::I(c.field_type as i64)),
            ("RDB$FIELD_LENGTH", SysVal::I(c.length as i64)),
            ("RDB$FIELD_SCALE", SysVal::I(c.scale as i64)),
            ("RDB$FIELD_SUB_TYPE", SysVal::I(c.sub_type as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if let Some(cl) = c.char_len {
            vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0))); // NONE
            vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
        sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)?;
    }
    for (i, c) in cols.iter().enumerate() {
        let dom = format!("RDB${}", domain_base + i as u64);
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&c.name)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
            ("RDB$FIELD_POSITION", SysVal::I(i as i64)),
            ("RDB$UPDATE_FLAG", SysVal::I(1)),
            ("RDB$FIELD_ID", SysVal::I(i as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if c.char_len.is_some() {
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
        if c.not_null {
            vals.push(("RDB$NULL_FLAG", SysVal::I(1)));
        }
        sys_insert(file, page_size, "RDB$RELATION_FIELDS", 5, &vals)?;
    }
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
            ("RDB$RELATION_TYPE", SysVal::I(0)), // persistent
            ("RDB$OWNER_NAME", SysVal::S("SYSDBA")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
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
    for key in keys {
        write_key(file, page_size, &name, key)?;
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
        write_foreign_key(file, page_size, &name, &fk_name, fk)?;
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
    file: &mut Vec<u8>,
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

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] PRIMARY KEY|UNIQUE
/// (<cols>)`: add a key constraint to an EXISTING table. The index is
/// built over the table's committed rows, so duplicate data fails the
/// statement the way the engine's own index build does. A PRIMARY KEY
/// requires its columns to be NOT NULL ALREADY - the engine refuses to
/// add one over a nullable column rather than making it not-null
/// (probed), and so does this.
pub fn alter_table_add_key(
    file: &mut Vec<u8>,
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
    file: &mut Vec<u8>,
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
pub fn drop_index(file: &mut Vec<u8>, page_size: usize, index_name: &str) -> Result<(), String> {
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

/// An index's (relation name, RDB$SYSTEM_FLAG) from RDB$INDICES.
fn find_index_relation(file: &[u8], page_size: usize, index_name: &str) -> Option<(String, i64)> {
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
fn constraint_using_index(file: &[u8], page_size: usize, index_name: &str) -> Option<String> {
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
    file: &[u8],
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
fn check_constraint_column(file: &[u8], page_size: usize, cname: &str) -> Option<String> {
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

/// The foreign key (if any) whose RDB$REF_CONSTRAINTS row names this
/// unique/primary constraint as its partner.
fn foreign_key_referencing(file: &[u8], page_size: usize, cname: &str) -> Option<String> {
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
    file: &mut Vec<u8>,
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
        let start = page as usize * page_size;
        let dp = DataPage::decode(file.get(start..start + page_size).ok_or("bad page")?)
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
    let seq = u32_at(file, page as usize * page_size + 16) as u64;
    let recno = seq * max_recs_per_dp(page_size) + slot as u64;
    let values = decode_record(&image, &ix_descs);
    maintain_indexes(file, page_size, 4, recno, &values, &ix_descs)?;
    let seg_fid = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    delete_catalog_rows(file, page_size, "RDB$INDEX_SEGMENTS", |v| {
        text_eq(v.get(seg_fid), &want)
    })?;
    // the index-root slot: irt_drop, flags cleared, root page kept
    let irt_page = file
        .chunks_exact(page_size)
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")?;
    let at = irt_page * page_size + 24 + index_id.saturating_sub(1) * 24;
    if at + 24 > file.len() {
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
    dml::put_u16(file, at + 18, 0); // irt_flags
    file[at + 20] = 6; // irt_drop (ods.h:456)
    Ok(())
}

/// Whether a column's `RDB$RELATION_FIELDS.RDB$NULL_FLAG` is set.
fn column_is_not_null(file: &[u8], page_size: usize, table: &str, col_up: &str) -> bool {
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
fn next_integ_name(file: &[u8], page_size: usize) -> Result<String, String> {
    let n = next_numeric_suffix(
        file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", "INTEG_",
    )?;
    Ok(format!("INTEG_{}", n))
}

/// Write one FOREIGN KEY onto a table: the referencing index (irt_foreign,
/// naming the partner PK index, with the partner-schema column that makes
/// MET_lookup_partner find it - see [create_index]), the RDB$RELATION_
/// CONSTRAINTS 'FOREIGN KEY' row, and the RDB$REF_CONSTRAINTS row linking
/// to the referenced table's PK constraint (MATCH FULL, RESTRICT rules -
/// referential ACTIONS like CASCADE need engine-generated BLR triggers,
/// which this writer does not synthesise). Shared by create_table and
/// ALTER TABLE ADD CONSTRAINT; create_index backfills existing rows, so
/// this works on a populated table too.
fn write_foreign_key(
    file: &mut Vec<u8>,
    page_size: usize,
    table: &str,
    fk_name: &str,
    fk: &ForeignKeyDef,
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
        ("RDB$UPDATE_RULE", SysVal::S("RESTRICT")),
        ("RDB$DELETE_RULE", SysVal::S("RESTRICT")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$CONST_SCHEMA_NAME_UQ", SysVal::S("PUBLIC")),
    ])?;
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] FOREIGN KEY (...)
/// REFERENCES ...`: add a foreign key to an EXISTING table. The FK index
/// is built and backfilled over the table's committed rows, then the
/// constraint catalog rows are written - the same shape create_table
/// produces, so the engine reads and gbak restores it identically.
pub fn alter_table_add_foreign_key(
    file: &mut Vec<u8>,
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
    write_foreign_key(file, page_size, &name, &fk_name, fk)?;
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
fn find_partner_key(
    file: &[u8],
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
fn index_segment_names(file: &[u8], page_size: usize, index_name: &str) -> Vec<String> {
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
fn next_index_number(file: &[u8], page_size: usize) -> Result<u64, String> {
    let plain = next_numeric_suffix(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME", "RDB$")?;
    let primary =
        next_numeric_suffix(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME", "RDB$PRIMARY")?;
    Ok(plain.max(primary))
}

fn next_numeric_suffix(
    file: &[u8],
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
    file: &mut Vec<u8>,
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
        dtype::TEXT | dtype::VARYING => btw::IDX_STRING,
        dtype::SQL_DATE => 5,  // idx_sql_date
        dtype::SQL_TIME => 6,  // idx_sql_time
        dtype::TIMESTAMP => 7, // idx_timestamp
        dtype::BOOLEAN => 9,   // idx_boolean
        _ => return None,
    })
}

/// Whether an index of `index_name` already exists (any relation).
fn index_name_taken(file: &[u8], page_size: usize, index_name: &str) -> Result<bool, String> {
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
    file: &mut Vec<u8>,
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
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err("an index needs at least one column".into());
    }

    // the irt slot: first empty repeat on the relation's root page,
    // descriptor space carved from the tail below the lowest in use
    let irt_page = file
        .chunks_exact(page_size)
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    let base = irt_page as usize * page_size;
    let mut slot = None;
    let mut lowest_desc = page_size;
    for i in 0..((page_size - 24) / 24) {
        let at = base + 24 + i * 24;
        let root = u32_at(file, at + 8);
        if root == 0 {
            if slot.is_none() {
                slot = Some(i);
                break;
            }
        } else {
            lowest_desc = lowest_desc.min(u16_at(file, at + 16) as usize);
        }
    }
    let slot = slot.ok_or("no free index slot")?;
    let desc_off = lowest_desc
        .checked_sub(8 * segs.len())
        .ok_or("irt page full")?;
    if 24 + (slot + 1) * 24 > desc_off {
        return Err("irt page full".into());
    }

    let root_page = dml::allocate_page(file, page_size)?;
    {
        let start = root_page as usize * page_size;
        file[start..start + page_size].fill(0);
    }
    btw::write_empty_root(file, page_size, root_page, rel, slot as u8)?;

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
    let at = base + 24 + slot * 24;
    file[at..at + 8].copy_from_slice(&0u64.to_le_bytes()); // irt_transaction
    dml::put_u32(file, at + 8, root_page);
    dml::put_u32(file, at + 12, 0); // page space
    dml::put_u16(file, at + 16, desc_off as u16);
    dml::put_u16(file, at + 18, iflags);
    file[at + 20] = 3; // irt_normal
    file[at + 21] = segs.len() as u8;
    file[at + 22] = 0;
    file[at + 23] = 0;
    for (i, (field, itype, _)) in segs.iter().enumerate() {
        let d = base + desc_off + i * 8;
        dml::put_u16(file, d, *field);
        dml::put_u16(file, d + 2, *itype);
        dml::put_u32(file, d + 4, 0); // selectivity
    }
    let count_at = base + 18; // irt_count @18
    let count = u16_at(file, count_at);
    if (slot as u16) + 1 > count {
        dml::put_u16(file, count_at, slot as u16 + 1);
    }

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

    // BACKFILL: key every committed primary row into the new tree
    let recs = max_recs_per_dp(page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        let seq = u32_at(file, start + 16) as u64;
        let rows: Vec<(u16, Vec<Value>)> = dp
            .records()
            .filter(|r| r.is_primary_record())
            .filter_map(|r| r.image().map(|img| (r.slot, decode_record(&img, descs))))
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
            )?;
        }
    }
    Ok(())
}

/// Walk a system relation like [walk_rows], also yielding each row's
/// (data page, slot) - what [crate::dml::delete_records] targets.
fn walk_rows_at(
    file: &[u8],
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(u32, u16, &[Value]),
) {
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else { continue };
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
    file: &mut Vec<u8>,
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
fn sys_fid(file: &[u8], page_size: usize, rel_name: &str, col: &str) -> Result<usize, String> {
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
pub fn drop_table(file: &mut Vec<u8>, page_size: usize, name: &str) -> Result<(), String> {
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

    // pages the relation owns - catalog-free page-type scans, plus the
    // page vectors of any level-1 blob slots on its data pages
    let mut pages: Vec<u32> = Vec::new();
    let data_pages = relation_data_pages(file, page_size, rel);
    for &dp_no in &data_pages {
        let start = dp_no as usize * page_size;
        if let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) {
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
    for (i, p) in file.chunks_exact(page_size).enumerate() {
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
            let dir = page as usize * page_size + DPG_RPT_OFFSET + slot as usize * 4;
            dml::put_u16(file, dir, 0);
            dml::put_u16(file, dir + 2, 0);
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


/// A generator's `(RDB$GENERATOR_ID, RDB$SYSTEM_FLAG, RDB$SECURITY_CLASS)`
/// from `RDB$GENERATORS`, by name. None when there is no such generator.
fn find_generator(
    file: &[u8],
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
fn generator_id_taken(file: &[u8], page_size: usize, id: i64) -> bool {
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

/// The owner's access control list for a newly created object, in the
/// engine's own encoding (acl.h): version 2, an id list naming the
/// owner as a person, then the privilege list the owner of a sequence
/// gets - alter, control, drop, usage - in the order `grant_privileges`
/// emits them (differential probe of an engine-created sequence's
/// `RDB$ACL`: `02 01 03 06 SYSDBA 00 02 06 01 03 0c 00 00`).
fn owner_acl(owner: &str) -> Vec<u8> {
    let mut acl = vec![
        2u8, // ACL_version
        1,   // ACL_id_list
        3,   // id_person
        owner.len() as u8,
    ];
    acl.extend_from_slice(owner.as_bytes());
    acl.extend_from_slice(&[
        0,  // id_end
        2,  // ACL_priv_list
        6,  // priv_alter
        1,  // priv_control
        3,  // priv_drop
        12, // priv_usage
        0,  // priv_end
        0,  // ACL_end
    ]);
    acl
}

/// Store one `RDB$SECURITY_CLASSES` row: the ACL blob (subtype 3) into
/// that relation's own data pages, then the row pointing at it. The
/// class name is the caller's `SQL$<n>`.
fn store_security_class(
    file: &mut Vec<u8>,
    page_size: usize,
    class: &str,
    owner: &str,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let acl = dml::insert_blob(file, page_size, rel, &[owner_acl(owner)], 3)?;
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
    file: &mut Vec<u8>,
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
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")
        .ok_or("no RDB$GENERATORS relation")?;

    // the id: the master generator, modulo MAX_SSHORT + 1, never 0,
    // never one already in use
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

    let class = format!(
        "SQL${}",
        gen::bump(file, page_size, gen::SECURITY_CLASS, 1)?
    );
    store_security_class(file, page_size, &class, OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$GENERATORS",
        rel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$GENERATOR_NAME", SysVal::S(&want)),
            ("RDB$GENERATOR_ID", SysVal::I(id)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$INITIAL_VALUE", SysVal::I(initial)),
            ("RDB$GENERATOR_INCREMENT", SysVal::I(step)),
        ],
    )?;
    store_usage_privilege(file, page_size, &want)?;

    // the stored value is initial - step, so the FIRST GEN_ID yields
    // initial (the engine's genIdCache put of `val - step`). A slot that
    // would hold zero needs no write: an unwritten slot already reads 0.
    let stored = initial.wrapping_sub(step);
    if stored != 0 {
        gen::write(file, page_size, id, stored)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The owner every fire-crab-written catalog object belongs to. The
/// server attaches as SYSDBA; the engine writes
/// `attachment->getEffectiveUserName()`.
const OWNER: &str = "SYSDBA";

/// The owner's `USAGE WITH GRANT OPTION` row in `RDB$USER_PRIVILEGES`
/// for a sequence: privilege 'G' (usaGe), user type 8 (obj_user),
/// object type 14 (obj_generator).
fn store_usage_privilege(file: &mut Vec<u8>, page_size: usize, name: &str) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    sys_insert(
        file,
        page_size,
        "RDB$USER_PRIVILEGES",
        rel,
        &[
            ("RDB$USER", SysVal::S(OWNER)),
            ("RDB$GRANTOR", SysVal::S(OWNER)),
            ("RDB$PRIVILEGE", SysVal::S("G")),
            ("RDB$GRANT_OPTION", SysVal::I(1)),
            ("RDB$RELATION_NAME", SysVal::S(name)),
            ("RDB$USER_TYPE", SysVal::I(8)),
            ("RDB$OBJECT_TYPE", SysVal::I(14)),
            ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )
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
pub fn drop_sequence(file: &mut Vec<u8>, page_size: usize, name: &str) -> Result<(), String> {
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

/// Advance the header's oldest-transaction markers past every
/// transaction this DDL burned, mirroring what a clean engine detach
/// leaves behind (probe: fresh db OIT/OAT/OST/next = 8/9/9/10,
/// post-CREATE 18/19/19/20 - OIT = next-2): two phantom committed
/// transactions, the markers pointing at them. Not what fixed the
/// attach hang (that was RDB$PAGES needing system-transaction
/// records; attach was re-verified fine without this) - but leaving
/// OIT a dozen transactions behind next would misrepresent a cleanly
/// closed database and make every attach start with catch-up work.
fn advance_oldest_transactions(file: &mut Vec<u8>, page_size: usize) -> Result<(), String> {
    let t1 = dml::allocate_committed_tx(file, page_size)?;
    let t2 = dml::allocate_committed_tx(file, page_size)?;
    let _ = t2;
    let put = |file: &mut Vec<u8>, at: usize, v: u64| {
        file[at..at + 8].copy_from_slice(&v.to_le_bytes());
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



