//! System-relation record formats, computed the way the engine's own
//! bootstrap computes them. System relations' formats are NOT in
//! `RDB$FORMATS` - `ini.epp` builds them at database creation from the
//! compiled-in field tables (`relations.h` + `fields.h`) with a simple
//! offset walk (ini.epp:1053-1088):
//!
//!   fmt_length = FLAG_BYTES(field count)          (val.h:42)
//!   for each field, in field-id order:
//!       dsc_length = gfld_length  (+2 for VARYING - the count word)
//!       fmt_length = MET_align(desc, fmt_length)  (met.epp:530-557)
//!       offset     = fmt_length
//!       fmt_length += dsc_length
//!
//! `MET_align` aligns on min(dsc_length, FORMAT_ALIGNMENT=8)
//! (common.h:622), except text (no alignment) and VARYING (aligned on
//! the 2-byte count word).
//!
//! We do the same walk - but where ini.epp reads the compiled-in tables,
//! we read the DATABASE's own catalog: `RDB$RELATION_FIELDS` names every
//! system relation's fields (with their ids), `RDB$FIELDS` gives each
//! field's type/length/scale, and the external type codes map to
//! internal dtypes exactly as `DSC_make_descriptor` does
//! (dsc.cpp:1411-1523). The file describes itself; only the TWO
//! relations needed to start reading the catalog - `RDB$FIELDS` (2) and
//! `RDB$RELATION_FIELDS` (5) - are compiled in below, transcribed from
//! relations.h:47-79 and 115-141 at ODS 14 (the same pinning as the
//! hardcoded `RDB$FORMATS` format in `format.rs`).
//!
//! The computation is empirically anchored: the offsets it produces for
//! `RDB$RELATION_FIELDS` and `RDB$RELATIONS` must reproduce the values
//! found by differential testing in `catalog.rs` (4/256/1394/1410 and
//! 32/42) - asserted in the tests below and at every runtime bootstrap.

use crate::catalog::{REL_RELATION_FIELDS, RELATION_NAME_LEN};
use crate::data::DataPage;
use crate::format::{decode_record, dtype, flag_bytes, Descriptor, Value};
use crate::pointer::relation_data_pages;

/// `RDB$FIELDS` - the relation whose rows type every field.
pub const REL_FIELDS: u16 = 2;

/// One compiled-in bootstrap field: (dtype, gfld_length) - scale and
/// sub_type are 0/irrelevant for every bootstrap field we decode.
type Def = (u8, u16);

/// `RDB$FIELDS` (relation 2), relations.h:47-79, fields present at
/// ODS 14. Identifier CHARs are 252 bytes (63 chars x 4, UTF8 metadata,
/// constants.h:64-71); blob ids 8; RDB$EDIT_STRING is VARYING(127).
const FIELDS_DEF: &[Def] = &[
    (dtype::TEXT, 252),   // 0  RDB$FIELD_NAME
    (dtype::TEXT, 252),   // 1  RDB$QUERY_NAME
    (dtype::BLOB, 8),     // 2  RDB$VALIDATION_BLR
    (dtype::BLOB, 8),     // 3  RDB$VALIDATION_SOURCE
    (dtype::BLOB, 8),     // 4  RDB$COMPUTED_BLR
    (dtype::BLOB, 8),     // 5  RDB$COMPUTED_SOURCE
    (dtype::BLOB, 8),     // 6  RDB$DEFAULT_VALUE
    (dtype::BLOB, 8),     // 7  RDB$DEFAULT_SOURCE
    (dtype::SHORT, 2),    // 8  RDB$FIELD_LENGTH
    (dtype::SHORT, 2),    // 9  RDB$FIELD_SCALE
    (dtype::SHORT, 2),    // 10 RDB$FIELD_TYPE
    (dtype::SHORT, 2),    // 11 RDB$FIELD_SUB_TYPE
    (dtype::BLOB, 8),     // 12 RDB$MISSING_VALUE
    (dtype::BLOB, 8),     // 13 RDB$MISSING_SOURCE
    (dtype::BLOB, 8),     // 14 RDB$DESCRIPTION
    (dtype::SHORT, 2),    // 15 RDB$SYSTEM_FLAG
    (dtype::BLOB, 8),     // 16 RDB$QUERY_HEADER
    (dtype::SHORT, 2),    // 17 RDB$SEGMENT_LENGTH
    (dtype::VARYING, 127),// 18 RDB$EDIT_STRING
    (dtype::SHORT, 2),    // 19 RDB$EXTERNAL_LENGTH
    (dtype::SHORT, 2),    // 20 RDB$EXTERNAL_SCALE
    (dtype::SHORT, 2),    // 21 RDB$EXTERNAL_TYPE
    (dtype::SHORT, 2),    // 22 RDB$DIMENSIONS
    (dtype::SHORT, 2),    // 23 RDB$NULL_FLAG
    (dtype::SHORT, 2),    // 24 RDB$CHARACTER_LENGTH
    (dtype::SHORT, 2),    // 25 RDB$COLLATION_ID
    (dtype::SHORT, 2),    // 26 RDB$CHARACTER_SET_ID
    (dtype::SHORT, 2),    // 27 RDB$FIELD_PRECISION
    (dtype::TEXT, 252),   // 28 RDB$SECURITY_CLASS
    (dtype::TEXT, 252),   // 29 RDB$OWNER_NAME
    (dtype::TEXT, 252),   // 30 RDB$SCHEMA_NAME
];
// the RDB$FIELDS field ids this module decodes
const F_NAME: usize = 0;
const F_LENGTH: usize = 8;
const F_SCALE: usize = 9;
const F_TYPE: usize = 10;
const F_SUB_TYPE: usize = 11;

/// `RDB$RELATION_FIELDS` (relation 5), relations.h:115-141 at ODS 14.
const RFR_DEF: &[Def] = &[
    (dtype::TEXT, 252),   // 0  RDB$FIELD_NAME
    (dtype::TEXT, 252),   // 1  RDB$RELATION_NAME
    (dtype::TEXT, 252),   // 2  RDB$FIELD_SOURCE
    (dtype::TEXT, 252),   // 3  RDB$QUERY_NAME
    (dtype::TEXT, 252),   // 4  RDB$BASE_FIELD
    (dtype::VARYING, 127),// 5  RDB$EDIT_STRING
    (dtype::SHORT, 2),    // 6  RDB$FIELD_POSITION
    (dtype::BLOB, 8),     // 7  RDB$QUERY_HEADER
    (dtype::SHORT, 2),    // 8  RDB$UPDATE_FLAG
    (dtype::SHORT, 2),    // 9  RDB$FIELD_ID
    (dtype::SHORT, 2),    // 10 RDB$VIEW_CONTEXT
    (dtype::BLOB, 8),     // 11 RDB$DESCRIPTION
    (dtype::BLOB, 8),     // 12 RDB$DEFAULT_VALUE
    (dtype::SHORT, 2),    // 13 RDB$SYSTEM_FLAG
    (dtype::TEXT, 252),   // 14 RDB$SECURITY_CLASS
    (dtype::TEXT, 252),   // 15 RDB$COMPLEX_NAME
    (dtype::SHORT, 2),    // 16 RDB$NULL_FLAG
    (dtype::BLOB, 8),     // 17 RDB$DEFAULT_SOURCE
    (dtype::SHORT, 2),    // 18 RDB$COLLATION_ID
    (dtype::TEXT, 252),   // 19 RDB$GENERATOR_NAME
    (dtype::SHORT, 2),    // 20 RDB$IDENTITY_TYPE
    (dtype::TEXT, 252),   // 21 RDB$SCHEMA_NAME
    (dtype::TEXT, 252),   // 22 RDB$FIELD_SOURCE_SCHEMA_NAME
    (dtype::TEXT, 252),   // 23 RDB$PACKAGE_NAME
];
const RF_NAME: usize = 0;
const RF_RELATION: usize = 1;
const RF_SOURCE: usize = 2;
const RF_ID: usize = 9;

/// `MET_align` (met.epp:530-557): alignment is the descriptor length,
/// except text (none) and VARYING (the 2-byte count word), capped at
/// FORMAT_ALIGNMENT = 8 (common.h:622).
fn met_align(dt: u8, dsc_length: u16, offset: u32) -> u32 {
    let alignment: u32 = match dt {
        dtype::TEXT => return offset, // and cstring, which never occurs stored
        dtype::VARYING => 2,
        _ => (dsc_length as u32).min(8),
    };
    if alignment == 0 {
        return offset;
    }
    offset.div_ceil(alignment) * alignment
}

/// The ini.epp:1053-1088 walk: descriptors (indexed by field id) from
/// (dtype, gfld_length, scale, sub_type) tuples in field-id order.
/// VARYING lengths grow by the 2-byte count word here, exactly where
/// ini.epp does it.
pub fn compute_format(fields: &[(u8, u16, i8, i16)]) -> Vec<Descriptor> {
    let mixed: Vec<(u8, u16, i8, i16, bool)> =
        fields.iter().map(|&(d, l, s, st)| (d, l, s, st, false)).collect();
    compute_format_mixed(&mixed)
}

/// [compute_format] for a field list that may contain COMPUTED fields
/// (the trailing bool). A computed field gets a full descriptor - its
/// expression's result type - but no storage: its offset is 0 and the
/// walk does not advance past it. It still counts toward the null-flag
/// bytes (probed: a 2-stored + 1-computed table starts its first stored
/// field at offset 4, the flag bytes of THREE fields, and the computed
/// descriptor reads `dtype 19, length 8, offset 0`).
pub fn compute_format_mixed(fields: &[(u8, u16, i8, i16, bool)]) -> Vec<Descriptor> {
    let mut offset = flag_bytes(fields.len()) as u32;
    let mut out = Vec::with_capacity(fields.len());
    for &(dt, gfld_length, scale, sub_type, computed) in fields {
        let dsc_length = if dt == dtype::VARYING {
            gfld_length + 2
        } else {
            gfld_length
        };
        if computed {
            out.push(Descriptor {
                dtype: dt,
                scale,
                length: dsc_length,
                sub_type,
                flags: 0,
                offset: 0,
            });
            continue;
        }
        offset = met_align(dt, dsc_length, offset);
        out.push(Descriptor {
            dtype: dt,
            scale,
            length: dsc_length,
            sub_type,
            flags: 0,
            offset,
        });
        offset += dsc_length as u32;
    }
    out
}

fn bootstrap(def: &[Def]) -> Vec<Descriptor> {
    let fields: Vec<(u8, u16, i8, i16)> = def.iter().map(|&(d, l)| (d, l, 0, 0)).collect();
    compute_format(&fields)
}

/// Map an `RDB$FIELD_TYPE` external type code to (internal dtype,
/// dsc_length), as `DSC_make_descriptor` does (dsc.cpp:1411-1523).
/// The stored length is authoritative only for text; VARYING gains the
/// count word; every other type has its own fixed size. None = a type
/// this conversion does not map (the relation is then not answerable).
fn external_type_to_desc(ftype: i64, flength: i64) -> Option<(u8, u16)> {
    Some(match ftype {
        14 => (dtype::TEXT, u16::try_from(flength).ok()?), // blr_text
        37 => (dtype::VARYING, u16::try_from(flength).ok()? + 2), // blr_varying
        7 => (dtype::SHORT, 2),      // blr_short
        8 => (dtype::LONG, 4),       // blr_long
        16 => (dtype::INT64, 8),     // blr_int64
        9 => (dtype::QUAD, 8),       // blr_quad
        10 => (dtype::REAL, 4),      // blr_float
        27 | 11 => (dtype::DOUBLE, 8), // blr_double, blr_d_float
        35 => (dtype::TIMESTAMP, 8), // blr_timestamp
        12 => (dtype::SQL_DATE, 4),  // blr_sql_date
        13 => (dtype::SQL_TIME, 4),  // blr_sql_time
        23 => (dtype::BOOLEAN, 1),   // blr_bool
        261 => (dtype::BLOB, 8),     // blr_blob
        _ => return None,
    })
}

/// Decode every committed primary record of `rel` with `descs`.
fn each_row<F: FnMut(Vec<Value>)>(file: &[u8], page_size: usize, rel: u16, descs: &[Descriptor], mut f: F) {
    for dp_no in relation_data_pages(file, page_size, rel) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file.get(start..start + page_size).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            if let Some(image) = r.image() {
                f(decode_record(&image, descs));
            }
        }
    }
}

fn as_text(v: &Value) -> Option<&str> {
    match v {
        Value::Text(s) => Some(s.trim_end_matches([' ', '\0'])),
        _ => None,
    }
}
fn as_int(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => Some(*i),
        _ => None,
    }
}

/// Compute the record format of a system relation by reading the
/// database's own catalog with the bootstrap formats: the relation's
/// fields (with ids) from `RDB$RELATION_FIELDS`, their types from
/// `RDB$FIELDS`, offsets by the ini.epp walk. Returns the same shape as
/// `relation_formats` - a single entry whose descriptors are indexed by
/// field id - or None when a field's type is unmapped or the id list has
/// gaps (never the wrong offsets). Valid for ODS 14 databases (the
/// bootstrap defs' pinning); the runtime sanity check below refuses a
/// file whose bootstrap disagrees with `catalog.rs`'s differential-
/// tested offsets.
pub fn system_relation_formats(
    file: &[u8],
    page_size: usize,
    rel_name: &str,
) -> Option<Vec<(u8, Vec<Descriptor>)>> {
    let rfr_descs = bootstrap(RFR_DEF);
    let fields_descs = bootstrap(FIELDS_DEF);
    // the bootstrap must reproduce the offsets catalog.rs established
    // by differential testing - a mismatch means an ODS this pinning
    // does not cover, and answering would be silently wrong
    if rfr_descs[RF_NAME].offset != 4
        || rfr_descs[RF_RELATION].offset != 256
        || rfr_descs[6].offset != 1394 // RDB$FIELD_POSITION
        || rfr_descs[RF_ID].offset != 1410
        || rfr_descs[RF_NAME].length as usize != RELATION_NAME_LEN
    {
        return None;
    }

    let want = rel_name.trim();
    // the relation's fields: (field id, field source)
    let mut members: Vec<(usize, String)> = Vec::new();
    each_row(file, page_size, REL_RELATION_FIELDS, &rfr_descs, |values| {
        let (Some(rel), Some(src), Some(id)) = (
            as_text(&values[RF_RELATION]),
            as_text(&values[RF_SOURCE]),
            as_int(&values[RF_ID]),
        ) else {
            return;
        };
        if rel.eq_ignore_ascii_case(want) {
            if let Ok(id) = usize::try_from(id) {
                members.push((id, src.to_string()));
            }
        }
    });
    if members.is_empty() {
        return None;
    }
    members.sort();
    // field ids must be dense 0..n-1 - the walk is positional
    if members.iter().enumerate().any(|(i, (id, _))| i != *id) {
        return None;
    }

    // the types of exactly the sources this relation uses
    let mut types: Vec<Option<(u8, u16, i8, i16)>> = vec![None; members.len()];
    each_row(file, page_size, REL_FIELDS, &fields_descs, |values| {
        let Some(name) = as_text(&values[F_NAME]) else { return };
        for (id, src) in &members {
            if !src.eq_ignore_ascii_case(name) {
                continue;
            }
            let (Some(ftype), Some(flength)) =
                (as_int(&values[F_TYPE]), as_int(&values[F_LENGTH]))
            else {
                continue;
            };
            let Some((dt, dsc_length)) = external_type_to_desc(ftype, flength) else {
                continue;
            };
            let scale = as_int(&values[F_SCALE]).unwrap_or(0) as i8;
            let sub_type = as_int(&values[F_SUB_TYPE]).unwrap_or(0) as i16;
            // dsc_length is final here; compute_format must not add the
            // VARYING count word again, so pass it as a raw length
            let raw = if dt == dtype::VARYING { dsc_length - 2 } else { dsc_length };
            types[*id] = Some((dt, raw, scale, sub_type));
        }
    });
    let fields: Option<Vec<(u8, u16, i8, i16)>> = types.into_iter().collect();
    Some(vec![(0, compute_format(&fields?))])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The computed bootstrap formats must reproduce every offset
    /// catalog.rs established empirically by differential testing
    /// against the live engine (RDB$RELATION_FIELDS: FIELD_NAME @4,
    /// RELATION_NAME @256, FIELD_POSITION @1394, FIELD_ID @1410).
    #[test]
    fn bootstrap_reproduces_the_differential_tested_offsets() {
        let rfr = bootstrap(RFR_DEF);
        assert_eq!(rfr[RF_NAME].offset, 4); // FLAG_BYTES(24) = 4
        assert_eq!(rfr[RF_RELATION].offset, 256);
        assert_eq!(rfr[RF_SOURCE].offset, 508);
        assert_eq!(rfr[6].offset, 1394); // RDB$FIELD_POSITION
        assert_eq!(rfr[RF_ID].offset, 1410); // RDB$FIELD_ID
        // RDB$FIELDS: the ids this module reads
        let f = bootstrap(FIELDS_DEF);
        assert_eq!(f[F_NAME].offset, 4); // FLAG_BYTES(31) = 4
        assert_eq!(f[F_LENGTH].offset, 560);
        assert_eq!(f[F_SCALE].offset, 562);
        assert_eq!(f[F_TYPE].offset, 564);
        assert_eq!(f[F_SUB_TYPE].offset, 566);
    }

    /// The same walk over RDB$RELATIONS' field list (relations.h:143-166)
    /// must land RDB$RELATION_ID at 32 and RDB$RELATION_NAME at 42 - the
    /// two offsets catalog.rs reads (found empirically, inc. 13).
    #[test]
    fn relations_walk_matches_catalog_offsets() {
        // view_blr, view_source, description: blobs; then 5 SHORTs
        // (id, system_flag, dbkey_length, format, field_id), then the name
        let fields: Vec<(u8, u16, i8, i16)> = [
            (dtype::BLOB, 8u16),
            (dtype::BLOB, 8),
            (dtype::BLOB, 8),
            (dtype::SHORT, 2), // RDB$RELATION_ID
            (dtype::SHORT, 2),
            (dtype::SHORT, 2),
            (dtype::SHORT, 2),
            (dtype::SHORT, 2),
            (dtype::TEXT, 252), // RDB$RELATION_NAME
        ]
        .iter()
        .map(|&(d, l)| (d, l, 0, 0))
        .collect();
        let descs = compute_format(&fields);
        assert_eq!(descs[3].offset, 32);
        assert_eq!(descs[8].offset, 42);
    }

    /// Golden offsets from engine-created tables with computed columns
    /// (probed via RDB$FORMATS.RDB$DESCRIPTOR): `(A INTEGER, B INTEGER,
    /// C COMPUTED BY (A+B))` lays out LONG@4, LONG@8, INT64@0; a computed
    /// column in the MIDDLE - `(A INTEGER, C COMPUTED BY (A+1), B BIGINT)`
    /// - does not disturb the stored walk: LONG@4, INT64@0, INT64@8.
    #[test]
    fn computed_fields_get_descriptors_but_no_storage() {
        let tc = compute_format_mixed(&[
            (dtype::LONG, 4, 0, 0, false),
            (dtype::LONG, 4, 0, 0, false),
            (dtype::INT64, 8, 0, 0, true),
        ]);
        assert_eq!(
            tc.iter().map(|d| (d.dtype, d.length, d.offset)).collect::<Vec<_>>(),
            vec![(dtype::LONG, 4, 4), (dtype::LONG, 4, 8), (dtype::INT64, 8, 0)]
        );
        let tf = compute_format_mixed(&[
            (dtype::LONG, 4, 0, 0, false),
            (dtype::INT64, 8, 0, 0, true),
            (dtype::INT64, 8, 0, 0, false),
        ]);
        assert_eq!(
            tf.iter().map(|d| (d.dtype, d.length, d.offset)).collect::<Vec<_>>(),
            vec![(dtype::LONG, 4, 4), (dtype::INT64, 8, 0), (dtype::INT64, 8, 8)]
        );
        // a computed SMALLINT passthrough: descriptor SHORT/2 at offset 0
        let td = compute_format_mixed(&[
            (dtype::SHORT, 2, 0, 0, false),
            (dtype::SHORT, 2, 0, 0, true),
        ]);
        assert_eq!(
            td.iter().map(|d| (d.dtype, d.length, d.offset)).collect::<Vec<_>>(),
            vec![(dtype::SHORT, 2, 4), (dtype::SHORT, 2, 0)]
        );
    }

    #[test]
    fn met_align_matches_met_epp() {
        assert_eq!(met_align(dtype::TEXT, 252, 5), 5); // text: never aligned
        assert_eq!(met_align(dtype::VARYING, 129, 5), 6); // count word: 2
        assert_eq!(met_align(dtype::SHORT, 2, 5), 6);
        assert_eq!(met_align(dtype::LONG, 4, 5), 8);
        assert_eq!(met_align(dtype::BLOB, 8, 5), 8);
        assert_eq!(met_align(dtype::DOUBLE, 8, 9), 16); // capped at 8
        assert_eq!(met_align(dtype::BOOLEAN, 1, 5), 5); // align 1
    }
}
