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
    /// dtype_unknown - never a stored column's dtype; used for the
    /// SQL_NULL bind slot a `? IS NULL` predicate describes
    pub const UNKNOWN: u8 = 0;
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
    /// an ARRAY column: the record holds the array blob's id (8 bytes,
    /// aligned like a long - align.h type_alignments[dtype_array]; dsc_pub.h dtype_array 18)
    pub const ARRAY: u8 = 18;
    pub const INT64: u8 = 19;
    pub const BOOLEAN: u8 = 21;
    pub const DEC64: u8 = 22;
    pub const DEC128: u8 = 23;
    pub const INT128: u8 = 24;
    pub const SQL_TIME_TZ: u8 = 25;
    pub const TIMESTAMP_TZ: u8 = 26;
    pub const EX_TIME_TZ: u8 = 27;
    pub const EX_TIMESTAMP_TZ: u8 = 28;
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
    /// FLOAT (4-byte REAL). Kept apart from `Double` because the two
    /// PRINT differently - the engine renders a single at 8 significant
    /// digits and a double at 16 - and the stored width is the only
    /// thing that says which (1.5 is exactly representable either way)
    Float(f32),
    Bool(bool),
    /// SQL_DATE: days since the Modified Julian Day epoch (1858-11-17)
    Date(i32),
    /// SQL_TIME: units of 1/10000 second since midnight
    Time(u32),
    /// SQL_TIMESTAMP: (date days, time units) as above
    Timestamp(i32, u32),
    /// blob/quad id: (relation, record number)
    Blob(u16, u64),
    /// 128-bit exact numeric (raw value, scale) - NUMERIC/DECIMAL(38)
    Int128(i128, i8),
    /// DECFLOAT(16): the raw IEEE 754-2008 decimal64 bits (LE-loaded)
    DecFloat16(u64),
    /// DECFLOAT(34): the raw decimal128 bits (LE-loaded)
    DecFloat34(u128),
    /// TIME WITH TIME ZONE: (UTC time units, zone id)
    TimeTz(u32, u16),
    /// TIMESTAMP WITH TIME ZONE: (UTC date days, UTC time units, zone id)
    TimestampTz(i32, u32, u16),
    /// present but not yet decodable (time-zone types)
    Unsupported(&'static str),
}

impl Value {
    pub fn render(&self) -> String {
        match self {
            Value::Null => "<null>".into(),
            Value::Text(s) => s.clone(),
            Value::Int(i) => i.to_string(),
            Value::Scaled(raw, scale) => render_scaled(*raw, *scale),
            Value::Double(d) => render_double(*d),
            Value::Float(f) => render_float(*f),
            Value::Bool(b) => if *b { "true" } else { "false" }.into(),
            Value::Date(d) => render_date(*d),
            Value::Time(t) => render_time(*t),
            Value::Timestamp(d, t) => format!("{} {}", render_date(*d), render_time(*t)),
            Value::Blob(rel, num) => format!("<blob {}:{}>", rel, num),
            Value::Int128(v, scale) => render_scaled_i128(*v, *scale),
            Value::DecFloat16(b) => crate::decfloat::to_string(&crate::decfloat::decode_dec64(*b)),
            Value::DecFloat34(b) => crate::decfloat::to_string(&crate::decfloat::decode_dec128(*b)),
            Value::TimeTz(t, zone) => render_time_tz(*t, *zone),
            Value::TimestampTz(d, t, zone) => render_timestamp_tz(*d, *t, *zone),
            Value::Unsupported(t) => format!("<{}>", t),
        }
    }
}

/// An approximate value as the engine prints it: 8 SIGNIFICANT digits for
/// a FLOAT and 16 for a DOUBLE (`render_double`),
/// trailing zeros kept, scientific outside the range where a fixed form
/// stays that precise - C's `%#.16g` (`dsc.cpp`'s double conversion),
/// probed against isql:
///
/// | value | text |
/// |---|---|
/// | 1.5 | `1.500000000000000` |
/// | 0 | `0.000000000000000` |
/// | 123456789.25 | `123456789.2500000` |
/// | 1e20 | `1.000000000000000e+20` |
/// | 1e-7 | `1.000000000000000e-07` |
///
/// Rust's `{}` prints the shortest round-tripping form (`1.5`), which is
/// a different string for the same number - and this text is what a CAST
/// to VARCHAR and a `||` concatenation both produce.
pub fn render_float(f: f32) -> String {
    render_approx(f as f64, 8)
}

/// See [render_float] - a DOUBLE carries 16.
pub fn render_double(d: f64) -> String {
    render_approx(d, 16)
}

fn render_approx(d: f64, p: i32) -> String {
    let P = p; // significant digits
    if d.is_nan() {
        return "NaN".into();
    }
    if d.is_infinite() {
        return if d < 0.0 { "-Infinity".into() } else { "Infinity".into() };
    }
    if d == 0.0 {
        return format!("{:.*}", (P - 1) as usize, 0.0);
    }
    // the decimal exponent %g decides the form with - taken from the
    // ROUNDED value, so 9.9999...e-5 does not straddle the boundary
    let sci = format!("{:.*e}", (P - 1) as usize, d);
    let exp: i32 = sci.rsplit('e').next().and_then(|e| e.parse().ok()).unwrap_or(0);
    if exp < -4 || exp >= P {
        // Rust writes `1.5e20`; C writes `1.5e+20` with at least two
        // exponent digits
        let (mantissa, _) = sci.split_once('e').unwrap_or((sci.as_str(), "0"));
        let sign = if exp < 0 { '-' } else { '+' };
        return format!("{}e{}{:02}", mantissa, sign, exp.abs());
    }
    format!("{:.*}", (P - 1 - exp).max(0) as usize, d)
}

fn render_scaled(raw: i64, scale: i8) -> String {
    render_scaled_i128(raw as i128, scale)
}

fn render_scaled_i128(raw: i128, scale: i8) -> String {
    if scale >= 0 {
        // positive scale multiplies (rare); render plainly
        return (raw * 10i128.pow(scale as u32)).to_string();
    }
    let digits = (-scale) as usize;
    let sign = if raw < 0 { "-" } else { "" };
    let abs = raw.unsigned_abs();
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

/// One day in SQL_TIME units (1/10000 s).
const DAY_UNITS: i64 = 24 * 60 * 60 * 10_000;

/// TIME WITH TIME ZONE, as the engine prints it: the LOCAL time in the
/// value's zone, then the zone text. Convertible zones (offsets, GMT)
/// are exact; a named zone without tzdata rules is rendered VISIBLY
/// unconverted - never a silently wrong local time.
fn render_time_tz(utc: u32, zone: u16) -> String {
    match crate::tz::displacement(zone) {
        Some(disp) => {
            let local = (utc as i64 + disp as i64 * 600_000).rem_euclid(DAY_UNITS);
            format!("{} {}", render_time(local as u32), crate::tz::zone_text(zone))
        }
        None => format!("<tz {} {}>", render_time(utc), crate::tz::zone_text(zone)),
    }
}

/// TIMESTAMP WITH TIME ZONE: local date and time (day carry applied),
/// then the zone text - same conversion policy as [render_time_tz].
fn render_timestamp_tz(date: i32, utc: u32, zone: u16) -> String {
    match crate::tz::displacement(zone) {
        Some(disp) => {
            let t = utc as i64 + disp as i64 * 600_000;
            let local_date = date as i64 + t.div_euclid(DAY_UNITS);
            let local_time = t.rem_euclid(DAY_UNITS);
            format!(
                "{} {} {}",
                render_date(local_date as i32),
                render_time(local_time as u32),
                crate::tz::zone_text(zone)
            )
        }
        None => format!(
            "<tz {} {} {}>",
            render_date(date),
            render_time(utc),
            crate::tz::zone_text(zone)
        ),
    }
}

/// Decode one field from an unpacked record image.
/// The RAW bytes of a character field - what `decode_field` would turn
/// into a `Value::Text`, before any UTF-8 interpretation. Needed for
/// `CHARACTER SET OCTETS` columns, whose bytes are not text at all: the
/// security database's `PLG$VERIFIER` and `PLG$SALT` are binary, and
/// reading them as a lossy string silently replaces every byte above
/// 0x7F. Returns None for NULL, for a truncated image, or for a
/// non-character dtype.
pub fn field_bytes(image: &[u8], desc: &Descriptor, index: usize) -> Option<Vec<u8>> {
    if image
        .get(index / 8)
        .map(|b| b & (1 << (index % 8)) != 0)
        .unwrap_or(true)
    {
        return None; // NULL
    }
    let at = desc.offset as usize;
    let len = desc.length as usize;
    let f = image.get(at..at + len)?;
    match desc.dtype {
        dtype::TEXT => Some(f.to_vec()),
        dtype::VARYING => {
            let n = (u16_at(f, 0) as usize).min(len.saturating_sub(2));
            Some(f[2..2 + n].to_vec())
        }
        _ => None,
    }
}

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
        // A CHAR is stored blank-padded to its full BYTE length, and its
        // DECLARED width is in characters - twenty bytes for a UTF8
        // CHAR(5). Handing back all twenty is what made every CHAR value
        // in a UTF8 database wrong on the wire, on rows the ENGINE had
        // written; [crate::intl::fit_char] cuts it to the five the
        // engine returns. In a single-byte set the two are the same
        // number and this is the identity it always was.
        dtype::TEXT => {
            // A CHAR is blank-padded (0x20) to its full byte length, and
            // only the first char_len CHARACTERS are the value. Trim the
            // padding as BYTES before decoding, so a wide CHAR does not
            // UTF8-validate hundreds of trailing spaces: 0x20 is a
            // one-byte character that never appears inside a multibyte
            // sequence, so dropping trailing 0x20 bytes drops exactly the
            // trailing space characters, and `fit_char` pads back to
            // char_len - the engine's own output is padded too, so the
            // trim-then-pad is an identity on what it returns.
            let end = f.iter().rposition(|&b| b != b' ').map_or(0, |i| i + 1);
            // a TABLED single-byte set (WIN1252, ISO8859_1) decodes by
            // its codepage - a 0xE9 is 'é', not an invalid-UTF8 byte the
            // lossy read replaced (which destroyed the stored value:
            // OCTET_LENGTH counted the replacement's three bytes)
            let cs = crate::intl::charset_id(desc.sub_type);
            // a BYTE-CARRIER set (NONE/OCTETS/ASCII) decodes one char per
            // byte - lossless, where the lossy-UTF8 read destroyed the
            // high bytes of engine-written rows
            let text = if crate::intl::byte_carrier(cs) {
                crate::intl::carrier_decode(&f[..end])
            } else {
                crate::intl::decode_text(cs, &f[..end])
                    .unwrap_or_else(|| String::from_utf8_lossy(&f[..end]).into_owned())
            };
            Value::Text(crate::intl::fit_char(
                &text,
                crate::intl::char_length(desc.dtype, desc.length, desc.sub_type),
            ))
        }
        dtype::VARYING => {
            let n = (u16_at(f, 0) as usize).min(len.saturating_sub(2));
            let cs = crate::intl::charset_id(desc.sub_type);
            Value::Text(if crate::intl::byte_carrier(cs) {
                crate::intl::carrier_decode(&f[2..2 + n])
            } else {
                crate::intl::decode_text(cs, &f[2..2 + n])
                    .unwrap_or_else(|| String::from_utf8_lossy(&f[2..2 + n]).into_owned())
            })
        }
        dtype::SHORT => scaled_or_int(u16_at(f, 0) as i16 as i64, desc.scale),
        dtype::LONG => scaled_or_int(u32_at(f, 0) as i32 as i64, desc.scale),
        dtype::INT64 => scaled_or_int(u64_at(f, 0) as i64, desc.scale),
        dtype::REAL => Value::Float(f32::from_le_bytes([f[0], f[1], f[2], f[3]])),
        dtype::DOUBLE => Value::Double(f64::from_le_bytes(f[0..8].try_into().unwrap())),
        dtype::BOOLEAN => Value::Bool(f[0] != 0),
        dtype::SQL_DATE => Value::Date(u32_at(f, 0) as i32),
        dtype::SQL_TIME => Value::Time(u32_at(f, 0)),
        dtype::TIMESTAMP => Value::Timestamp(u32_at(f, 0) as i32, u32_at(f, 4)),
        dtype::BLOB | dtype::QUAD | dtype::ARRAY => {
            // bid (RecordNumber.h:63-71, little-endian branch):
            // u16 relation, u8 reserved, u8 number_up, u32 number
            let rel = u16_at(f, 0);
            let num = ((f[3] as u64) << 32) | u32_at(f, 4) as u64;
            Value::Blob(rel, num)
        }
        // TZ types store UTC + zone id (ISC_TIME_TZ/ISC_TIMESTAMP_TZ);
        // the EX variants append an offset the engine computes at bind
        // time - never stored, but decoded the same if ever seen
        dtype::SQL_TIME_TZ | dtype::EX_TIME_TZ => Value::TimeTz(u32_at(f, 0), u16_at(f, 4)),
        dtype::TIMESTAMP_TZ | dtype::EX_TIMESTAMP_TZ => {
            Value::TimestampTz(u32_at(f, 0) as i32, u32_at(f, 4), u16_at(f, 8))
        }
        dtype::INT128 => {
            Value::Int128(i128::from_le_bytes(f[0..16].try_into().unwrap()), desc.scale)
        }
        dtype::DEC64 => Value::DecFloat16(u64::from_le_bytes(f[0..8].try_into().unwrap())),
        dtype::DEC128 => Value::DecFloat34(u128::from_le_bytes(f[0..16].try_into().unwrap())),
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
    file: &'a crate::Image,
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Option<RecordHeader<'a>> {
    let recs = max_recs_per_dp(page_size);
    let dp_index = (recno / recs) as usize;
    let line = (recno % recs) as u16;
    let dp_no = *relation_data_pages(file, page_size, relation).get(dp_index)?;
    let dp = DataPage::decode(crate::page_at(file, page_size, dp_no)?)?;
    dp.record(line)
}

/// Read a materialized blob's full data by its id. Handles level 0
/// (data inline in the blob record after the blh header, ods.h:969)
/// and level 1 (blh_page vector of blob pages). Segmented blobs store
/// `u16 length` prefixes inside the data stream; `segmented = true`
/// strips them, concatenating segment payloads like BLB_get_data.
pub fn read_blob(
    file: &crate::Image,
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
    let dp = DataPage::decode(crate::page_at(file, page_size, dp_no)?)?;
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
                let page = crate::page_at(file, page_size, pageno)?;
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

/// Read a blob's CONTENT with the right framing, decided by the blob
/// itself: segmented blobs carry `[u16 length]` prefixes to strip,
/// stream-mode blobs (`rhd_stream_blob`, ods.h:1012 - `blh_flags`
/// aliases the record flags word) are raw bytes.
pub fn read_blob_content(
    file: &crate::Image,
    page_size: usize,
    relation: u16,
    recno: u64,
) -> Option<Vec<u8>> {
    let recs = max_recs_per_dp(page_size);
    let dp_no = *relation_data_pages(file, page_size, relation).get((recno / recs) as usize)?;
    let dp = DataPage::decode(crate::page_at(file, page_size, dp_no)?)?;
    let b = dp.slot_bytes((recno % recs) as u16)?;
    if b.len() < 12 || u16_at(b, 10) & flags::BLOB == 0 {
        return None;
    }
    let stream = u16_at(b, 10) & flags::STREAM_BLOB != 0;
    read_blob(file, page_size, relation, recno, !stream)
}

/// Bootstrap: read every (relation_id, format#, descriptors) row from
/// RDB$FORMATS using its hardcoded system format, then parse each
/// descriptor blob. Returns matches for `relation`.
pub fn relation_formats(
    file: &crate::Image,
    page_size: usize,
    relation: u16,
) -> Vec<(u8, Vec<Descriptor>)> {
    let sys = formats_table_format();
    let mut found = Vec::new();
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, REL_FORMATS) {
        let Some(dp) = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else {
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

    #[test]
    fn renders_doubles_the_way_the_engine_prints_them() {
        // 16 SIGNIFICANT digits, trailing zeros kept, scientific outside
        // the fixed range - C's `%#.16g`. Every line probed against isql.
        let r = super::render_double;
        assert_eq!(r(1.5), "1.500000000000000");
        assert_eq!(r(0.1), "0.1000000000000000");
        assert_eq!(r(-0.5), "-0.5000000000000000");
        assert_eq!(r(0.0), "0.000000000000000");
        assert_eq!(r(123456789.25), "123456789.2500000");
        assert_eq!(r(1e20), "1.000000000000000e+20");
        assert_eq!(r(1e-7), "1.000000000000000e-07");
        // Rust's own `{}` would print "1.5" and "0" here - the shortest
        // round-tripping form, which is a DIFFERENT STRING for the same
        // number, and this text is what CAST AS VARCHAR and `||` produce
        assert_ne!(r(1.5), format!("{}", 1.5));
        // a FLOAT is the same rule at 8 significant digits, and that
        // difference is the only reason the two Value variants exist -
        // 1.5 is exactly representable either way, so nothing about the
        // NUMBER says which width stored it
        let f = super::render_float;
        assert_eq!(f(1.5), "1.5000000");
        assert_eq!(f(-1.5), "-1.5000000");
        assert_eq!(f(4.0), "4.0000000");
        assert_eq!(f(0.0), "0.0000000");
        assert_ne!(f(1.5), r(1.5));
    }
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
    fn char_decode_trims_padding_and_refits() {
        // A CHAR is blank-padded (0x20) to its full byte length; decode
        // trims the padding as bytes before UTF8-decoding and pads back to
        // char_len, which must equal taking the first char_len characters
        // of the whole padded image. Field @4 so the flag byte is @0.
        let field = |dtype, length, sub_type, bytes: &[u8]| {
            let d = Descriptor { dtype, scale: 0, length, sub_type, flags: 0, offset: 4 };
            let mut image = vec![0u8; 4 + length as usize];
            image[4..4 + bytes.len()].copy_from_slice(bytes);
            // pad the remainder with 0x20, as the engine stores a CHAR
            for b in image[4 + bytes.len()..].iter_mut() {
                *b = b' ';
            }
            decode_field(&image, &d, 0)
        };
        // UTF8 CHAR(5) = 20 bytes: narrow content pads to five chars
        assert_eq!(field(dtype::TEXT, 20, 4, b"ab"), Value::Text("ab   ".into()));
        // UTF8 CHAR(5): five-char wide content fills exactly, no padding
        assert_eq!(
            field(dtype::TEXT, 20, 4, "\u{e4}bcde".as_bytes()),
            Value::Text("\u{e4}bcde".into())
        );
        // NONE CHAR(5) = 5 bytes: same rule, single-byte set
        assert_eq!(field(dtype::TEXT, 5, 0, b"ab"), Value::Text("ab   ".into()));
        // an all-blank field is five spaces, not empty
        assert_eq!(field(dtype::TEXT, 5, 0, b""), Value::Text("     ".into()));
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
