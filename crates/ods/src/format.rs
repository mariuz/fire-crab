//! Record formats: RDB$FORMATS descriptors and record-image decoding.
//!
//! A format is the array of `Ods::Descriptor`s (ods.h:1023, 12 bytes
//! each) describing one shape of a relation's records: dtype, scale,
//! length and the field's byte offset inside the unpacked record
//! image. User relations store their formats in RDB$FORMATS as a blob
//! (`u16 count` + descriptors — met.epp:1057-1064); system relations
//! do NOT (met.epp:1038), their formats are compiled into the engine
//! (relations.h/fields.h) — which is exactly the engine's own
//! bootstrap, mirrored here by [FORMATS_TABLE_FORMAT].
//!
//! The record image starts with the null bitmap — `FLAG_BYTES(count)`
//! bytes (val.h:42), bit N set = field N is NULL — and the stored
//! descriptor offsets already point past it.

use crate::data::{flags, RecordHeader};
use crate::pointer::relation_data_pages;
use crate::{u16_at, u32_at, u64_at, DataPage};

/// dtype constants, dsc_pub.h:45-67.
pub mod dtype {
    pub const TEXT: u8 = 1;
    pub const VARYING: u8 = 3;
    pub const SHORT: u8 = 8;
    pub const LONG: u8 = 9;
    pub const QUAD: u8 = 10;
    pub const REAL: u8 = 11;
    pub const DOUBLE: u8 = 12;
    pub const SQL_DATE: u8 = 14;
    pub const SQL_TIME: u8 = 15;
    pub const TIMESTAMP: u8 = 16;
    pub const BLOB: u8 = 17;
    pub const INT64: u8 = 19;
    pub const BOOLEAN: u8 = 21;
    pub const DEC64: u8 = 22;
    pub const DEC128: u8 = 23;
    pub const INT128: u8 = 24;
}

/// `Ods::Descriptor` (ods.h:1023): the on-disk field descriptor.
#[derive(Clone, Copy, Debug)]
pub struct Descriptor {
    pub dtype: u8,
    pub scale: i8,
    pub length: u16,
    pub sub_type: i16,
    pub flags: u16,
    pub offset: u32,
}

impl Descriptor {
    /// Decode one 12-byte descriptor (offsets pinned ods.h:1034-1039).
    pub fn decode(b: &[u8]) -> Option<Descriptor> {
        if b.len() < 12 {
            return None;
        }
        Some(Descriptor {
            dtype: b[0],
            scale: b[1] as i8,
            length: u16_at(b, 2),
            sub_type: u16_at(b, 4) as i16,
            flags: u16_at(b, 6),
            offset: u32_at(b, 8),
        })
    }
}

/// Parse an RDB$DESCRIPTOR format blob: `u16 count` then `count`
/// descriptors (met.epp:1057-1064; the trailing default-value section
/// is ignored, as are defaults by the engine's readers of old rows).
pub fn parse_format_blob(b: &[u8]) -> Option<Vec<Descriptor>> {
    if b.len() < 2 {
        return None;
    }
    let count = u16_at(b, 0) as usize;
    let mut descs = Vec::with_capacity(count);
    for i in 0..count {
        descs.push(Descriptor::decode(b.get(2 + i * 12..2 + i * 12 + 12)?)?);
    }
    Some(descs)
}

/// `FLAG_BYTES(n)` (val.h:42) with BITS_PER_LONG = 32: size of the
/// null bitmap at the start of the record image.
pub fn flag_bytes(count: usize) -> usize {
    ((count + 32) & !31) >> 3
}

/// The engine's hardcoded format for RDB$FORMATS itself (relation 8;
/// relations.h:180-184): RDB$RELATION_ID smallint, RDB$FORMAT
/// smallint, RDB$DESCRIPTOR blob. Offsets follow the engine's layout
/// rules: null bitmap (4 bytes for 3 fields), then aligned fields.
pub const REL_FORMATS: u16 = 8;
pub fn formats_table_format() -> Vec<Descriptor> {
    let d = |dtype, length, offset| Descriptor {
        dtype,
        scale: 0,
        length,
        sub_type: 0,
        flags: 0,
        offset,
    };
    vec![
        d(dtype::SHORT, 2, 4), // RDB$RELATION_ID
        d(dtype::SHORT, 2, 6), // RDB$FORMAT
        d(dtype::QUAD, 8, 8),  // RDB$DESCRIPTOR (blob id)
    ]
}

/// A decoded field value, rendered close to the engine's own text
/// conventions where that is cheap and exact.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Text(String),
    Int(i64),
    /// scaled exact numeric rendered with its decimals (raw, scale)
    Scaled(i64, i8),
    Double(f64),
    Bool(bool),
    Date(String),
    Time(String),
    Timestamp(String),
    /// blob/quad id: (relation, record number)
    Blob(u16, u64),
    /// present but not yet decodable (INT128, DECFLOAT...)
    Unsupported(&'static str),
}

impl Value {
    pub fn render(&self) -> String {
        match self {
            Value::Null => "<null>".into(),
            Value::Text(s) => s.clone(),
            Value::Int(i) => i.to_string(),
            Value::Scaled(raw, scale) => render_scaled(*raw, *scale),
            Value::Double(d) => format!("{}", d),
            Value::Bool(b) => if *b { "true" } else { "false" }.into(),
            Value::Date(s) | Value::Time(s) | Value::Timestamp(s) => s.clone(),
            Value::Blob(rel, num) => format!("<blob {}:{}>", rel, num),
            Value::Unsupported(t) => format!("<{}>", t),
        }
    }
}

fn render_scaled(raw: i64, scale: i8) -> String {
    if scale >= 0 {
        // positive scale multiplies (rare); render plainly
        return (raw as i128 * 10i128.pow(scale as u32)).to_string();
    }
    let digits = (-scale) as usize;
    let sign = if raw < 0 { "-" } else { "" };
    let abs = (raw as i128).unsigned_abs();
    let pow = 10u128.pow(digits as u32);
    format!(
        "{}{}.{:0width$}",
        sign,
        abs / pow,
        abs % pow,
        width = digits
    )
}

/// Modified Julian Day epoch used by SQL_DATE: day 0 = 1858-11-17.
fn render_date(days: i32) -> String {
    // civil-from-days (Howard Hinnant's algorithm), shifted to the
    // Firebird epoch: 1858-11-17 is 40587 days before 1970-01-01.
    let z = days as i64 - 40587 + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02}", y, m, d)
}

/// SQL_TIME is in units of 1/10000 second.
fn render_time(t: u32) -> String {
    let s = t / 10_000;
    format!(
        "{:02}:{:02}:{:02}.{:04}",
        s / 3600,
        (s / 60) % 60,
        s % 60,
        t % 10_000
    )
}

/// Decode one field from an unpacked record image.
pub fn decode_field(image: &[u8], desc: &Descriptor, index: usize) -> Value {
    // null bitmap: bit `index`, set = NULL
    if image
        .get(index / 8)
        .map(|b| b & (1 << (index % 8)) != 0)
        .unwrap_or(true)
    {
        return Value::Null;
    }
    let at = desc.offset as usize;
    let len = desc.length as usize;
    let Some(f) = image.get(at..at + len) else {
        return Value::Unsupported("truncated");
    };
    match desc.dtype {
        dtype::TEXT => Value::Text(String::from_utf8_lossy(f).into_owned()),
        dtype::VARYING => {
            let n = (u16_at(f, 0) as usize).min(len.saturating_sub(2));
            Value::Text(String::from_utf8_lossy(&f[2..2 + n]).into_owned())
        }
        dtype::SHORT => scaled_or_int(u16_at(f, 0) as i16 as i64, desc.scale),
        dtype::LONG => scaled_or_int(u32_at(f, 0) as i32 as i64, desc.scale),
        dtype::INT64 => scaled_or_int(u64_at(f, 0) as i64, desc.scale),
        dtype::REAL => Value::Double(f32::from_le_bytes([f[0], f[1], f[2], f[3]]) as f64),
        dtype::DOUBLE => Value::Double(f64::from_le_bytes(f[0..8].try_into().unwrap())),
        dtype::BOOLEAN => Value::Bool(f[0] != 0),
        dtype::SQL_DATE => Value::Date(render_date(u32_at(f, 0) as i32)),
        dtype::SQL_TIME => Value::Time(render_time(u32_at(f, 0))),
        dtype::TIMESTAMP => Value::Timestamp(format!(
            "{} {}",
            render_date(u32_at(f, 0) as i32),
            render_time(u32_at(f, 4))
        )),
        dtype::BLOB | dtype::QUAD => {
            // bid (RecordNumber.h:63-71, little-endian branch):
            // u16 relation, u8 reserved, u8 number_up, u32 number
            let rel = u16_at(f, 0);
            let num = ((f[3] as u64) << 32) | u32_at(f, 4) as u64;
            Value::Blob(rel, num)
        }
        dtype::INT128 => Value::Unsupported("int128"),
        dtype::DEC64 => Value::Unsupported("decfloat16"),
        dtype::DEC128 => Value::Unsupported("decfloat34"),
        _ => Value::Unsupported("dtype?"),
    }
}

fn scaled_or_int(raw: i64, scale: i8) -> Value {
    if scale == 0 {
        Value::Int(raw)
    } else {
        Value::Scaled(raw, scale)
    }
}

/// Decode a whole record image against a format.
pub fn decode_record(image: &[u8], descs: &[Descriptor]) -> Vec<Value> {
    descs
        .iter()
        .enumerate()
        .map(|(i, d)| decode_field(image, d, i))
        .collect()
}

// ---- record location and blob assembly (ods.cpp formulas) ----------

/// `Ods::dataPagesPerPP` (ods.cpp:87): slots per pointer page — each
/// data page needs a 32-bit pointer plus 8 control bits, rounded down
/// to a multiple of 8.
pub fn data_pages_per_pp(page_size: usize) -> u64 {
    (((page_size - 32) * 8 / (32 + 8)) & !7) as u64
}

/// `Ods::maxRecsPerDP` (ods.cpp:98): the record-number density.
pub fn max_recs_per_dp(page_size: usize) -> u64 {
    ((page_size - 28) / (4 + 13)) as u64
}

/// Locate a record by its 40-bit record number: number -> (data page
/// sequence, line) -> page via the relation's pointer pages.
pub fn locate_record<'a>(
    file: &'a [u8],
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Option<RecordHeader<'a>> {
    let recs = max_recs_per_dp(page_size);
    let dp_index = (recno / recs) as usize;
    let line = (recno % recs) as u16;
    let dp_no = *relation_data_pages(file, page_size, relation).get(dp_index)?;
    let start = dp_no as usize * page_size;
    let dp = DataPage::decode(file.get(start..start + page_size)?)?;
    dp.record(line)
}

/// Read a materialized blob's full data by its id. Handles level 0
/// (data inline in the blob record after the blh header, ods.h:969)
/// and level 1 (blh_page vector of blob pages). Segmented blobs store
/// `u16 length` prefixes inside the data stream; `segmented = true`
/// strips them, concatenating segment payloads like BLB_get_data.
pub fn read_blob(
    file: &[u8],
    page_size: usize,
    relation: u16,
    recno: u64,
    segmented: bool,
) -> Option<Vec<u8>> {
    // A blob slot IS the blh struct (dpm.epp:2491 lays it down in
    // place of a record header), so fetch the raw slot bytes.
    let recs = max_recs_per_dp(page_size);
    let dp_index = (recno / recs) as usize;
    let line = (recno % recs) as u16;
    let dp_no = *relation_data_pages(file, page_size, relation).get(dp_index)?;
    let start = dp_no as usize * page_size;
    let dp = DataPage::decode(file.get(start..start + page_size)?)?;
    let b = dp.slot_bytes(line)?;
    if b.len() < 28 || u16_at(b, 10) & flags::BLOB == 0 {
        return None;
    }
    let level = b[27]; // blh_level @27
    let length = u64_at(b, 16) as usize; // blh_length @16 (incl. the
                                         // segment prefixes for
                                         // segmented blobs)

    let raw = match level {
        0 => b.get(28..)?.to_vec(),
        1 => {
            // blh_page vector of blob data pages (blob_page, ods.h:271:
            // 16-byte pag + lead 4 + sequence 4 + blp_length u16 + pad)
            let mut out = Vec::with_capacity(length + 64);
            let mut at = 28;
            while at + 4 <= b.len() {
                let pageno = u32_at(b, at);
                at += 4;
                if pageno == 0 {
                    break;
                }
                let start = pageno as usize * page_size;
                let page = file.get(start..start + page_size)?;
                let blp_length = u16_at(page, 24) as usize;
                out.extend_from_slice(page.get(28..28 + blp_length)?);
            }
            out
        }
        _ => return None, // level 2 not needed yet — say so, don't guess
    };

    if !segmented {
        return Some(raw[..length.min(raw.len())].to_vec());
    }
    // strip [u16 len][payload] segment framing
    let mut out = Vec::with_capacity(length);
    let mut at = 0usize;
    while at + 2 <= raw.len() && out.len() < length {
        let seg = u16_at(&raw, at) as usize;
        at += 2;
        out.extend_from_slice(raw.get(at..at + seg)?);
        at += seg;
    }
    Some(out)
}

/// Bootstrap: read every (relation_id, format#, descriptors) row from
/// RDB$FORMATS using its hardcoded system format, then parse each
/// descriptor blob. Returns matches for `relation`.
pub fn relation_formats(
    file: &[u8],
    page_size: usize,
    relation: u16,
) -> Vec<(u8, Vec<Descriptor>)> {
    let sys = formats_table_format();
    let mut found = Vec::new();
    for dp_no in relation_data_pages(file, page_size, REL_FORMATS) {
        let start = dp_no as usize * page_size;
        let Some(dp) = file
            .get(start..start + page_size)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(image) = r.image() else {
                continue;
            };
            let row = decode_record(&image, &sys);
            let (Value::Int(rel_id), Value::Int(fmt_no), Value::Blob(_, blob_recno)) =
                (&row[0], &row[1], &row[2])
            else {
                continue;
            };
            if *rel_id as u16 != relation {
                continue;
            }
            if let Some(blob) = read_blob(file, page_size, REL_FORMATS, *blob_recno, true) {
                if let Some(descs) = parse_format_blob(&blob) {
                    found.push((*fmt_no as u8, descs));
                }
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_layout_matches_ods_h() {
        // distinct value at every offset pinned by ods.h:1034-1039
        let b = [9u8, 0xFE, 4, 0, 1, 0, 0x34, 0x12, 8, 0, 0, 0];
        let d = Descriptor::decode(&b).unwrap();
        assert_eq!(d.dtype, 9);
        assert_eq!(d.scale, -2);
        assert_eq!(d.length, 4);
        assert_eq!(d.sub_type, 1);
        assert_eq!(d.flags, 0x1234);
        assert_eq!(d.offset, 8);
    }

    #[test]
    fn flag_bytes_matches_val_h() {
        // FLAG_BYTES(n) = ((n + 32) & ~31) >> 3
        assert_eq!(flag_bytes(1), 4);
        assert_eq!(flag_bytes(3), 4);
        assert_eq!(flag_bytes(31), 4);
        assert_eq!(flag_bytes(32), 8);
        assert_eq!(flag_bytes(33), 8);
    }

    #[test]
    fn record_image_decode_with_nulls() {
        // 2 fields: LONG @4, VARYING(6) @8; field 1 NULL
        let descs = vec![
            Descriptor {
                dtype: dtype::LONG,
                scale: 0,
                length: 4,
                sub_type: 0,
                flags: 0,
                offset: 4,
            },
            Descriptor {
                dtype: dtype::VARYING,
                scale: 0,
                length: 8,
                sub_type: 0,
                flags: 0,
                offset: 8,
            },
        ];
        let mut image = vec![0u8; 16];
        image[0] = 0b10; // field 1 null
        image[4..8].copy_from_slice(&42u32.to_le_bytes());
        let row = decode_record(&image, &descs);
        assert_eq!(row[0], Value::Int(42));
        assert_eq!(row[1], Value::Null);
    }

    #[test]
    fn scaled_dates_times_render() {
        assert_eq!(render_scaled(123456789, -4), "12345.6789");
        assert_eq!(render_scaled(-101, -2), "-1.01");
        assert_eq!(render_date(0), "1858-11-17"); // the MJD epoch
        assert_eq!(render_date(40587), "1970-01-01");
        assert_eq!(
            render_time(36_000_000 + 600_000 + 10_000 + 42),
            "01:01:01.0042"
        );
    }

    #[test]
    fn per_page_formulas_match_ods_cpp() {
        // 8K pages: ((8192-32)*8/40) & ~7 = 1632; (8192-28)/17 = 480
        assert_eq!(data_pages_per_pp(8192), 1632);
        assert_eq!(max_recs_per_dp(8192), 480);
    }
}
