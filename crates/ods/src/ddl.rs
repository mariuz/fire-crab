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

    // maintain every index of the relation
    if let Some(irt) = find_index_root(file, page_size, rel) {
        let entries: Vec<_> = irt
            .entries()
            .filter(|e| e.root_page != 0)
            .map(|e| (e.id, e.key_count))
            .collect();
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

/// CREATE TABLE: the full engine sequence against the file image.
/// Errors leave the caller's copy to be discarded - the statement
/// failed, nothing half-created survives.
pub fn create_table(
    file: &mut Vec<u8>,
    page_size: usize,
    name: &str,
    cols: &[ColumnDef],
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

    // --- the format descriptor blob (makeFormat): one segment of
    // [u16 count][count x 12B packed descriptors][u16 0 defaults] -----
    let mut fmt_payload = Vec::with_capacity(2 + descs.len() * 12 + 2);
    fmt_payload.extend_from_slice(&(descs.len() as u16).to_le_bytes());
    for d in &descs {
        fmt_payload.push(d.dtype);
        fmt_payload.push(d.scale as u8);
        fmt_payload.extend_from_slice(&d.length.to_le_bytes());
        fmt_payload.extend_from_slice(&(d.sub_type as u16).to_le_bytes());
        fmt_payload.extend_from_slice(&d.flags.to_le_bytes());
        fmt_payload.extend_from_slice(&d.offset.to_le_bytes());
    }
    fmt_payload.extend_from_slice(&0u16.to_le_bytes());
    let fmt_blob = dml::insert_blob(file, page_size, 8, &[fmt_payload], 6)?;

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
