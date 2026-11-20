//! Slice 5b: the `RDB$RUNTIME` blobs (`RelationNode::storeRuntime`,
//! DdlNodes.epp:8626-8920).
//!
//! WHY THEY EXIST: `jrd_rel::scan` (met.epp:3349-3556) loads a relation's
//! field list ONLY from `RDB$RUNTIME` - a NULL runtime leaves the `dsql_rel`
//! chain empty and the first field touch fails with -206 "Column unknown".
//! Proven by nulling just `RDB$ROLES`' runtime on a pristine oracle copy:
//! the attach then fails with the exact production error (`RDB$ROLE_NAME`,
//! line 1 column 328 - the `findGrantedRoles` query, scl.epp:1034).
//!
//! WHAT THIS STORES: for each of the 25 relations the engine's ini leaves
//! runtime blobs on (list pinned off the fresh 2182 file), the RSR segment
//! list over its `RDB$RELATION_FIELDS` x `RDB$FIELDS` rows in `RDB$FIELD_ID`
//! order, as a level-0 segmented blob (sub_type 5, charset 1) on the
//! relation's own data pages (`dml::insert_blob`); then the 25
//! `RDB$RELATIONS` rows are repointed at the new bids with a slot-stable
//! rewrite (same page, same slot - record numbers unchanged, so no index
//! maintenance: no system index covers `RDB$RUNTIME`).
//!
//! Every payload byte is pinned against the fresh 2182 file in
//! `tests/catalog_runtime.rs`.

use crate::catalog_format::descriptors_for;
use crate::catalog_init::SYS_RELATIONS;
use crate::catalog_rows::read_all_rows;
use crate::data::DataPage;
use crate::format::{decode_record, read_blob_content, Value};
use crate::pointer::relation_data_pages;
use crate::Image;

// `rsr_t` (met.h:47-75).
const RSR_FIELD_ID: u8 = 0;
const RSR_FIELD_NAME: u8 = 1;
const RSR_MISSING_VALUE: u8 = 5;
const RSR_DEFAULT_VALUE: u8 = 6;
const RSR_VALIDATION_BLR: u8 = 7;
const RSR_SECURITY_CLASS: u8 = 8;
const RSR_FIELD_LENGTH: u8 = 19;
const RSR_FIELD_NOT_NULL: u8 = 21;
const RSR_FIELD_GENERATOR_NAME: u8 = 22;
const RSR_FIELD_IDENTITY_TYPE: u8 = 23;
const RSR_SEGMENT_LENGTH: u8 = 24;
const RSR_FIELD_SOURCE: u8 = 25;
const RSR_CHARACTER_LENGTH: u8 = 26;
const RSR_FIELD_POS: u8 = 27;

/// `nonnull_validation_blr` (DdlNodes.epp:96-102): version5, not, missing,
/// fid 0 0 0, eoc (blr.h:105,168,170,132,107).
const NONNULL_VALIDATION_BLR: &[u8] = &[5, 59, 61, 24, 0, 0, 0, 76];

/// `RDB$FIELD_TYPE` for blobs (261 - the `RDB$DESCRIPTION` domain).
const FIELD_TYPE_BLOB: i64 = 261;

/// The relations carrying `RDB$RUNTIME` on a fresh engine create, in
/// `RDB$RELATION_ID` order (fresh 2182 file, 25 rows).
pub const RUNTIME_RELATIONS: &[u16] = &[
    2, 4, 5, 6, 11, 12, 14, 15, 16, 20, 22, 23, 26, 27, 28, 29, 30, 31, 32, 42, 45, 47, 51, 52, 56,
];

fn rel_name(rel_id: u16) -> &'static str {
    SYS_RELATIONS.iter().find(|r| r.id == rel_id).expect("system relation").name
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

fn text_of(v: &Value) -> Option<String> {
    match v {
        Value::Text(s) => Some(s.trim_end().to_string()),
        Value::Null => None,
        v => panic!("expected text, got {v:?}"),
    }
}

fn int_of(v: &Value) -> Option<i64> {
    match v {
        Value::Int(n) => Some(*n),
        Value::Null => None,
        v => panic!("expected int, got {v:?}"),
    }
}

fn blob_of(v: &Value) -> Option<(u16, u64)> {
    match v {
        Value::Blob(rel, num) => Some((*rel, *num)),
        Value::Null => None,
        v => panic!("expected blob, got {v:?}"),
    }
}

fn seg(record_type: u8, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + data.len());
    out.push(record_type);
    out.extend_from_slice(data);
    out
}

fn seg_u16(record_type: u8, n: i64) -> Vec<u8> {
    seg(record_type, &(n as u16).to_le_bytes())
}

/// The RSR segment list for one relation - the `FOR RFR x FLD` walk at
/// DdlNodes.epp:8628-8839. `file` supplies the joined rows and the
/// `putSummaryBlob` sources (default/validation/missing/computed blobs).
pub fn build_runtime_segments(
    file: &Image,
    page_size: usize,
    rel_id: u16,
) -> Result<Vec<Vec<u8>>, String> {
    let rfr = read_all_rows(file, page_size, 5);
    let (c_schema, c_rel, c_field, c_source, c_source_schema, c_pos, c_id, c_null, c_sec, c_gen, c_ident, c_dfl) = (
        col(5, "RDB$SCHEMA_NAME"),
        col(5, "RDB$RELATION_NAME"),
        col(5, "RDB$FIELD_NAME"),
        col(5, "RDB$FIELD_SOURCE"),
        col(5, "RDB$FIELD_SOURCE_SCHEMA_NAME"),
        col(5, "RDB$FIELD_POSITION"),
        col(5, "RDB$FIELD_ID"),
        col(5, "RDB$NULL_FLAG"),
        col(5, "RDB$SECURITY_CLASS"),
        col(5, "RDB$GENERATOR_NAME"),
        col(5, "RDB$IDENTITY_TYPE"),
        col(5, "RDB$DEFAULT_VALUE"),
    );
    let (f_name, f_schema, f_type, f_len, f_clen, f_seg, f_null, f_comp, f_miss, f_dfl, f_val) = (
        col(2, "RDB$FIELD_NAME"),
        col(2, "RDB$SCHEMA_NAME"),
        col(2, "RDB$FIELD_TYPE"),
        col(2, "RDB$FIELD_LENGTH"),
        col(2, "RDB$CHARACTER_LENGTH"),
        col(2, "RDB$SEGMENT_LENGTH"),
        col(2, "RDB$NULL_FLAG"),
        col(2, "RDB$COMPUTED_BLR"),
        col(2, "RDB$MISSING_VALUE"),
        col(2, "RDB$DEFAULT_VALUE"),
        col(2, "RDB$VALIDATION_BLR"),
    );
    let want = rel_name(rel_id);
    let mut fields: Vec<&Vec<Value>> = rfr
        .iter()
        .filter(|r| text_of(&r[c_schema]).as_deref() == Some("SYSTEM") && text_of(&r[c_rel]).as_deref() == Some(want))
        .collect();
    fields.sort_by_key(|r| int_of(&r[c_id]).unwrap_or(-1));

    let fld = read_all_rows(file, page_size, 2);
    let mut domains: std::collections::HashMap<(String, String), &Vec<Value>> = std::collections::HashMap::new();
    for row in &fld {
        if let (Some(s), Some(n)) = (text_of(&row[f_schema]), text_of(&row[f_name])) {
            domains.insert((s, n), row);
        }
    }

    let summary_blob = |segments: &mut Vec<Vec<u8>>, record_type: u8, bid: Option<(u16, u64)>| -> Result<(), String> {
        // `putSummaryBlob`: empty source blobs are skipped, otherwise the
        // source's whole content rides one segment (DdlNodes.epp:9315-9347).
        if let Some((br, bn)) = bid {
            let content = read_blob_content(file, page_size, br, bn)
                .ok_or_else(|| format!("unreadable summary-blob source ({br},{bn})"))?;
            segments.push(seg(record_type, &content));
        }
        Ok(())
    };

    let mut segments = Vec::new();
    for r in fields {
        let source = text_of(&r[c_source]).ok_or("RFR without FIELD_SOURCE")?;
        let source_schema = text_of(&r[c_source_schema]).ok_or("RFR without source schema")?;
        let f = domains
            .get(&(source_schema.clone(), source.clone()))
            .ok_or_else(|| format!("no RDB$FIELDS row for {source_schema}.{source}"))?;

        segments.push(seg_u16(RSR_FIELD_ID, int_of(&r[c_id]).ok_or("RFR without FIELD_ID")?));
        segments.push(seg(RSR_FIELD_NAME, text_of(&r[c_field]).ok_or("RFR without FIELD_NAME")?.as_bytes()));
        // `fldsrc.toQuotedString()`: always double-quoted, schema.object
        // (QualifiedMetaString.h:343, MetaString.h:43).
        let quoted = format!("\"{source_schema}\".\"{source}\"");
        segments.push(seg(RSR_FIELD_SOURCE, quoted.as_bytes()));
        if let Some(n) = int_of(&f[f_len]) {
            segments.push(seg_u16(RSR_FIELD_LENGTH, n));
        }
        if let Some(n) = int_of(&f[f_clen]) {
            segments.push(seg_u16(RSR_CHARACTER_LENGTH, n));
        }
        // Computed columns and views: none of the 25 has either (a
        // VIEW_CONTEXT or COMPUTED segment in the pins fails loudly).
        if blob_of(&f[f_comp]).is_some() {
            return Err(format!("unexpected COMPUTED_BLR on {want}"));
        }
        summary_blob(&mut segments, RSR_MISSING_VALUE, blob_of(&f[f_miss]))?;
        segments.push(seg_u16(RSR_FIELD_POS, int_of(&r[c_pos]).ok_or("RFR without FIELD_POSITION")?));
        let default = blob_of(&r[c_dfl]).or_else(|| blob_of(&f[f_dfl]));
        summary_blob(&mut segments, RSR_DEFAULT_VALUE, default)?;
        summary_blob(&mut segments, RSR_VALIDATION_BLR, blob_of(&f[f_val]))?;
        let not_null = int_of(&r[c_null]).or_else(|| int_of(&f[f_null])).unwrap_or(0) != 0;
        if not_null {
            segments.push(seg(RSR_FIELD_NOT_NULL, NONNULL_VALIDATION_BLR));
        }
        if let Some(s) = text_of(&r[c_sec]) {
            if !s.is_empty() {
                segments.push(seg(RSR_SECURITY_CLASS, s.as_bytes()));
            }
        }
        if let Some(s) = text_of(&r[c_gen]) {
            if !s.is_empty() {
                segments.push(seg(RSR_FIELD_GENERATOR_NAME, s.as_bytes()));
            }
        }
        if let Some(n) = int_of(&r[c_ident]) {
            segments.push(seg_u16(RSR_FIELD_IDENTITY_TYPE, n));
        }
        if int_of(&f[f_type]) == Some(FIELD_TYPE_BLOB) {
            segments.push(seg_u16(RSR_SEGMENT_LENGTH, int_of(&f[f_seg]).unwrap_or(0)));
        }
    }
    Ok(segments)
}

/// Store all 25 runtime blobs and repoint the `RDB$RELATIONS` rows at
/// them. Runs after the slice-5 index builds: blob slots are fresh
/// record numbers (no index covers blob nodes) and the row rewrite keeps
/// every slot number (no index covers `RDB$RUNTIME` either).
pub fn store_runtime_blobs(file: &mut Image, page_size: usize) -> Result<(), String> {
    // Blobs past the last row page: the row rewrites below need their
    // pages' free gaps untouched.
    let last_row_page = relation_data_pages(file, page_size, 6).into_iter().max().unwrap_or(0);
    let mut bids = Vec::new();
    for &rel_id in RUNTIME_RELATIONS {
        let segments = build_runtime_segments(file, page_size, rel_id)?;
        let blh = crate::dml::build_level0_blh(&segments, 5, 1)?;
        let num = crate::dml::insert_blob_slot_after(file, page_size, 6, &blh, last_row_page)?;
        bids.push((rel_id, num));
    }
    let rel = SYS_RELATIONS.iter().find(|r| r.id == 6).unwrap();
    let descs = descriptors_for(rel);
    let id_pos = rel.fields.iter().position(|f| f.name == "RDB$RELATION_ID").unwrap();
    let rt_fid = rel.fields.iter().position(|f| f.name == "RDB$RUNTIME").unwrap();
    let rt_off = descs[rt_fid].offset as usize;
    // (page, slot) per relation id, blob slots skipped.
    let mut locs: std::collections::HashMap<i64, (u32, u16)> = std::collections::HashMap::new();
    for dp_no in relation_data_pages(file, page_size, 6) {
        let dp = DataPage::decode(crate::page_at(file, page_size, dp_no).ok_or("relations page range")?)
            .ok_or("relations page decode")?;
        for r in dp.records() {
            let raw = dp.slot_bytes(r.slot).ok_or("slot range")?;
            if raw.len() < 13 || u16::from_le_bytes([raw[10], raw[11]]) & 16 != 0 {
                continue;
            }
            let img = crate::data::catalog_image(file, page_size, &r, None).ok_or("row image")?;
            let values = decode_record(&img, &descs);
            if let Value::Int(id) = values[id_pos] {
                locs.insert(id, (dp_no, r.slot));
            }
        }
    }
    for (rel_id, num) in bids {
        let (dp_no, slot) = locs.get(&(rel_id as i64)).copied().ok_or_else(|| format!("no RDB$RELATIONS row for {rel_id}"))?;
        let page = crate::page_at(file, page_size, dp_no).ok_or("row page range")?;
        let dp = DataPage::decode(page).ok_or("row page decode")?;
        let raw = dp.slot_bytes(slot).ok_or("row slot range")?.to_vec();
        let r = dp.record(slot).ok_or("row record")?;
        let mut img = crate::data::catalog_image(file, page_size, &r, None).ok_or("row image")?;
        // Byte-poke, not re-encode: the bid bytes plus the cleared null
        // bit, everything else bitwise preserved.
        img[rt_off..rt_off + 2].copy_from_slice(&6u16.to_le_bytes());
        img[rt_off + 2] = 0;
        img[rt_off + 3] = (num >> 32) as u8;
        img[rt_off + 4..rt_off + 8].copy_from_slice(&(num as u32).to_le_bytes());
        img[rt_fid / 8] &= !(1 << (rt_fid % 8));
        let packed = crate::sqz::pack(&img);
        let mut new_rec = Vec::with_capacity(13 + packed.len());
        new_rec.extend_from_slice(&raw[..13]);
        new_rec.extend_from_slice(&packed);
        crate::dml::rewrite_slot_same_page(file, page_size, dp_no, slot, &new_rec)?;
    }
    Ok(())
}
