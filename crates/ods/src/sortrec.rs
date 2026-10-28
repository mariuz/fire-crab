//! The engine's sort-record tiebreak: what an `ORDER BY` compares AFTER
//! the keys tie (sort.cpp, recsrc/SortedStream.cpp,
//! optimizer/Optimizer.cpp `generateSort`).
//!
//! A sort record is `memset` to zero, then filled with the diddled keys,
//! one null-flag byte per data field, the data fields in field-id order
//! per stream (raw `MOV_move` bytes, little-endian), the per-stream
//! dbkey (int64 recno) and transaction id (int64), per-stream validity
//! bytes, and - at the very end - the stashed lengths of varying keys.
//! `quick()` compares the whole record as unsigned 32-bit longs,
//! low address first (`DO_32_COMPARE`), INCLUDING the data past the
//! keys. There is no value-level "next column" comparison: a `SHORT`
//! shares its long with neighbouring flag bytes, a `DOUBLE` compares
//! its low mantissa word before its exponent, and a `VARCHAR` compares
//! its raw length prefix before its characters.
//!
//! Both executors compare the keys at the value level (which is exactly
//! the diddled-key order) and call into here for the tiebreak bytes, so
//! the layout lives in exactly one place.

use crate::format::{dtype, Descriptor, Value};

/// dtype_cstring (dsc_pub.h) - never a stored column, but an expression
/// value (and hence a sort key) can be one.
pub const CSTRING: u8 = 2;

/// `InlineSortThreshold`'s default (config.h): past this many data bytes
/// the engine refetches rows by dbkey instead of carrying the data, and
/// the tiebreak narrows to the dbkey. A database may configure another
/// value, which this port cannot see - see [refetch].
pub const INLINE_SORT_THRESHOLD: usize = 1000;

/// `MAX_SORT_RECORD / 2` (sort.h: 1MB records): the refetch ceiling.
pub const REFETCH_CEILING: usize = 512 * 1024;

/// `type_alignments` (align.h) for the dtypes a sort record can hold.
/// 0 means the field packs without alignment (text, cstring).
pub fn alignment(dt: u8) -> usize {
    match dt {
        dtype::VARYING | dtype::SHORT => 2,
        dtype::LONG | dtype::QUAD | dtype::REAL => 4,
        dtype::DOUBLE | dtype::INT64 => 8,
        dtype::SQL_DATE | dtype::SQL_TIME | dtype::TIMESTAMP => 4,
        dtype::BLOB | dtype::ARRAY => 4,
        dtype::BOOLEAN => 1,
        dtype::DEC64 | dtype::DEC128 | dtype::INT128 => 8,
        dtype::SQL_TIME_TZ | dtype::TIMESTAMP_TZ | dtype::EX_TIME_TZ | dtype::EX_TIMESTAMP_TZ => 4,
        _ => 0,
    }
}

/// A sort-key's `skd_length`: the descriptor length, except DECFLOAT
/// keys, whose diddled form is wider (sort.h `setSkdLength`).
pub fn key_len(dt: u8, dsc_len: usize) -> usize {
    match dt {
        dtype::DEC64 => 8 + 4,
        dtype::DEC128 => 16 + 4,
        _ => dsc_len,
    }
}

/// The record's key region length: per key a 1-byte null flag plus the
/// key proper, each key starting 4-aligned (sort.h `setSkdOffset`, the
/// little-endian branch), the whole region rounded up to a long.
/// `keys` is (dtype, dsc_length, is_intl) per `ORDER BY` expression, in
/// order; an INTL varying/cstring key is first turned into fixed text
/// of its collation key length (Optimizer.cpp `generateSort`).
pub fn key_region_len(keys: &[(u8, usize, usize)]) -> usize {
    let mut off = 0usize;
    for (i, &(_dt, len, _intl)) in keys.iter().enumerate() {
        // every key starts 4-aligned past the previous one
        if i > 0 {
            off = (off + 3) & !3;
        }
        // null-flag key
        off += 1;
        // key proper, 4-aligned
        off = (off + 3) & !3;
        off += len;
    }
    (off + 3) & !3
}

/// Whether the sort refetches: the data leaves the record when its
/// total length passes the configured threshold (Optimizer.cpp:1792).
/// `total` is the data fields' `dsc_length` sum after key-dedup.
/// The engine reads the threshold per database; this port answers with
/// the default, and a database that configures another value keeps the
/// engine's own order there (documented in the roadmap).
pub fn refetch(total: usize) -> bool {
    total > INLINE_SORT_THRESHOLD.min(REFETCH_CEILING)
}

/// One data field of the tiebreak: its descriptor class, length, and
/// where to read the value from. Built per sort by the executor.
#[derive(Clone, Copy, Debug)]
pub struct TieField {
    pub dtype: u8,
    pub len: usize,
    /// text/varchar character set id for encoding, 0 (NONE) when the
    /// value's bytes are already the record bytes.
    pub charset: u32,
    /// true for (VAR)CHAR CHARACTER SET OCTETS: pad with 0x00, else
    /// with the space character (diddleKey's `SKD_binary` rule, which
    /// MOV_move's blank-padding follows for data too).
    pub binary: bool,
}

impl TieField {
    pub fn of(dtype: u8, len: usize) -> TieField {
        TieField { dtype, len, charset: 0, binary: false }
    }
}

/// The tiebreak half of a sort record: null flags, data, dbkeys,
/// validity bytes and key-varying stashes, laid out exactly as
/// `generateSort` lays them past `keyLength`. The key region itself is
/// all ties (the caller compared the keys already), so the bytes start
/// at the flags with the key region's length carried only for the
/// absolute alignment of what follows.
#[derive(Clone, Debug)]
pub struct TieLayout {
    /// absolute offsets of each field's flag byte
    pub flags: Vec<usize>,
    /// absolute offsets of each field's data
    pub data: Vec<usize>,
    /// absolute offsets of each stream's (dbkey, trans) int64 pair
    pub ids: Vec<(usize, usize)>,
    /// absolute offsets of each stream's validity byte
    pub valids: Vec<usize>,
    /// absolute offsets of each varying-key stash (u16, at the end)
    pub stashes: Vec<usize>,
    /// total record length past the keys (before the key region)
    pub len: usize,
    /// the key region length this layout hangs past
    pub key_len: usize,
}

impl TieLayout {
    /// Lay out `fields` (field-id order per stream, key-deduped) past a
    /// key region of `key_len` bytes, for `streams` streams each with a
    /// dbkey, and `stash_count` varying-key stashes. `carry_data` is
    /// false in refetch mode: no flags, no data, dbkeys only.
    pub fn build(
        key_len: usize,
        fields: &[TieField],
        streams: usize,
        stash_count: usize,
        carry_data: bool,
    ) -> TieLayout {
        let mut flags = Vec::new();
        let mut data = Vec::new();
        let mut map_len = key_len;
        if carry_data {
            for f in fields {
                flags.push(map_len);
                map_len += 1;
            }
            for f in fields {
                let a = alignment(f.dtype);
                if a > 1 {
                    map_len = (map_len + a - 1) & !(a - 1);
                }
                data.push(map_len);
                map_len += f.len;
            }
        }
        map_len = (map_len + 7) & !7;
        let mut ids = Vec::new();
        for _ in 0..streams {
            let db = map_len;
            map_len += 8;
            let tr = map_len;
            map_len += 8;
            ids.push((db, tr));
        }
        let mut valids = Vec::new();
        for _ in 0..streams {
            valids.push(map_len);
            map_len += 1;
        }
        map_len = (map_len + 3) & !3;
        let mut stashes = Vec::new();
        for _ in 0..stash_count {
            stashes.push(map_len);
            map_len += 2;
        }
        TieLayout { flags, data, ids, valids, stashes, len: map_len - key_len, key_len }
    }

    /// A zeroed tiebreak record. The engine memsets the whole record
    /// (SortedStream.cpp `init`: "Zero out the sort key. This solves a
    /// multitude of problems."); the caller only writes flags, data,
    /// ids and stashes.
    pub fn zero(&self) -> Vec<u8> {
        vec![0u8; self.len]
    }
}

/// Compare two tiebreak records the way `DO_32_COMPARE` compares the
/// record past the keys: unsigned 32-bit longs, low address first,
/// then any trailing 1-3 bytes (a varying-key stash can leave the
/// length 2 past a long).
pub fn cmp_tie(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    debug_assert_eq!(a.len(), b.len());
    let longs = a.len() / 4;
    for i in 0..longs {
        let x = u32::from_le_bytes([a[4 * i], a[4 * i + 1], a[4 * i + 2], a[4 * i + 3]]);
        let y = u32::from_le_bytes([b[4 * i], b[4 * i + 1], b[4 * i + 2], b[4 * i + 3]]);
        if x != y {
            return x.cmp(&y);
        }
    }
    for i in (longs * 4)..a.len() {
        if a[i] != b[i] {
            return a[i].cmp(&b[i]);
        }
    }
    Ordering::Equal
}

/// Write one field's `MOV_move` bytes at its data offset; NULL leaves
/// the zeros and the caller sets the flag. Returns false for a value
/// the port cannot render (the caller declines the sort).
/// `encode` renders text values to the field charset's bytes.
pub fn write_field(
    rec: &mut [u8],
    field: &TieField,
    off: usize,
    v: &Value,
    encode: &dyn Fn(&str, u32) -> Option<Vec<u8>>,
) -> bool {
    let put = |rec: &mut [u8], off: usize, bytes: &[u8]| {
        let end = (off + bytes.len()).min(rec.len());
        rec[off..end].copy_from_slice(&bytes[..end - off]);
    };
    match v {
        Value::Null => true,
        Value::Int(x) => {
            let b = match field.dtype {
                dtype::SHORT => (*x as i16).to_le_bytes().to_vec(),
                dtype::LONG => (*x as i32).to_le_bytes().to_vec(),
                _ => x.to_le_bytes().to_vec(),
            };
            put(rec, off, &b);
            true
        }
        Value::Rounded(x, _) | Value::Scaled(x, _) => {
            let b = match field.dtype {
                dtype::SHORT => (*x as i16).to_le_bytes().to_vec(),
                dtype::LONG => (*x as i32).to_le_bytes().to_vec(),
                _ => x.to_le_bytes().to_vec(),
            };
            put(rec, off, &b);
            true
        }
        Value::Int128(x, _) => {
            put(rec, off, &x.to_le_bytes());
            true
        }
        Value::Float(x) => {
            put(rec, off, &x.to_le_bytes());
            true
        }
        Value::Double(x) => {
            put(rec, off, &x.to_le_bytes());
            true
        }
        Value::Bool(b) => {
            if off < rec.len() {
                rec[off] = u8::from(*b);
            }
            true
        }
        Value::Date(d) => {
            put(rec, off, &d.to_le_bytes());
            true
        }
        Value::Time(t) => {
            put(rec, off, &t.to_le_bytes());
            true
        }
        Value::Timestamp(d, t) => {
            put(rec, off, &d.to_le_bytes());
            put(rec, off + 4, &t.to_le_bytes());
            true
        }
        Value::TimeTz(t, z) => {
            put(rec, off, &t.to_le_bytes());
            put(rec, off + 4, &z.to_le_bytes());
            true
        }
        Value::TimestampTz(d, t, z) => {
            put(rec, off, &d.to_le_bytes());
            put(rec, off + 4, &t.to_le_bytes());
            put(rec, off + 8, &z.to_le_bytes());
            true
        }
        Value::DecFloat16(x) => {
            put(rec, off, &x.to_le_bytes());
            true
        }
        Value::DecFloat34(x) => {
            put(rec, off, &x.to_le_bytes());
            true
        }
        Value::Blob(rel, num) => {
            // RecordNumber.h: relation, reserved (always 0: both bid
            // constructors clear first), number-up, number.
            put(rec, off, &rel.to_le_bytes());
            if off + 3 < rec.len() {
                rec[off + 3] = (num >> 32) as u8;
            }
            put(rec, off + 4, &(*num as u32).to_le_bytes());
            true
        }
        Value::Text(s) => {
            let bytes = match encode(s, field.charset) {
                Some(b) => b,
                None => return false,
            };
            match field.dtype {
                dtype::VARYING => {
                    // raw vlen (BYTES, probed on UTF8) + chars, no
                    // padding: data varying is never diddled.
                    let n = bytes.len().min(field.len.saturating_sub(2));
                    put(rec, off, &(n as u16).to_le_bytes());
                    put(rec, off + 2, &bytes[..n]);
                    true
                }
                _ => {
                    // TEXT: blank-padded (0x00 for OCTETS); overlong
                    // values cannot occur (MOV_move would have errored).
                    let n = bytes.len().min(field.len);
                    put(rec, off, &bytes[..n]);
                    let pad = if field.binary { 0u8 } else { 0x20u8 };
                    for i in off + n..(off + field.len).min(rec.len()) {
                        rec[i] = pad;
                    }
                    true
                }
            }
        }
        _ => false,
    }
}

/// Fill one row's tiebreak record: flags (TRUE == NULL), data, ids.
/// `fields` parallels the layout's fields; `row` the row's values in
/// the same order; `ids` the per-stream (dbkey, trans, valid).
pub fn fill_row(
    layout: &TieLayout,
    rec: &mut [u8],
    fields: &[TieField],
    row: &[Value],
    ids: &[(u64, i64, bool)],
    stashes: &[u16],
    encode: &dyn Fn(&str, u32) -> Option<Vec<u8>>,
) -> bool {
    for (i, f) in fields.iter().enumerate() {
        let v = row.get(i).unwrap_or(&Value::Null);
        let flag = matches!(v, Value::Null);
        if let Some(&fo) = layout.flags.get(i) {
            if fo - layout.key_len < rec.len() {
                rec[fo - layout.key_len] = u8::from(flag);
            }
        }
        if !flag {
            if let Some(&doff) = layout.data.get(i) {
                if !write_field(rec, f, doff - layout.key_len, v, encode) {
                    return false;
                }
            }
        }
    }
    for (i, &(db, tr, valid)) in ids.iter().enumerate() {
        if let Some(&(dbo, tro)) = layout.ids.get(i) {
            let o = dbo - layout.key_len;
            if o + 8 <= rec.len() {
                rec[o..o + 8].copy_from_slice(&db.to_le_bytes());
            }
            let o = tro - layout.key_len;
            if o + 8 <= rec.len() {
                rec[o..o + 8].copy_from_slice(&tr.to_le_bytes());
            }
        }
        if let Some(&vo) = layout.valids.get(i) {
            let o = vo - layout.key_len;
            if o < rec.len() {
                rec[o] = u8::from(valid);
            }
        }
    }
    for (i, s) in stashes.iter().enumerate() {
        if let Some(&so) = layout.stashes.get(i) {
            let o = so - layout.key_len;
            if o + 2 <= rec.len() {
                rec[o..o + 2].copy_from_slice(&s.to_le_bytes());
            }
        }
    }
    true
}

/// True when the descriptor reads a varying or cstring key that keeps
/// a stash: non-INTL varying/cstring (an INTL key becomes SKD_bytes).
pub fn varying_key(dt: u8, is_intl: bool) -> bool {
    !is_intl && (dt == dtype::VARYING || dt == CSTRING)
}

pub fn desc_to_field(d: &Descriptor) -> TieField {
    TieField::of(d.dtype, d.length as usize)
}

/// A slot-indexed frame's stamped descriptor (union/aggregate output):
/// the dtype, dsc_length, charset and collation a sort derives. The
/// collation rides along because fid KEYS need it (an INTL key takes
/// the collation-key path, not the stash path); data bytes never do.
#[derive(Clone, Copy, Debug)]
pub struct SlotDesc {
    pub dtype: u8,
    pub len: usize,
    pub charset: u8,
    pub coll: u8,
}

impl SlotDesc {
    /// The text type word (charset + collation), as sub_type carries it.
    pub fn ttype(self) -> u16 {
        self.charset as u16 | ((self.coll as u16) << 8)
    }

    pub fn tie_field(self) -> TieField {
        TieField {
            dtype: self.dtype,
            len: self.len,
            charset: self.charset as u32,
            binary: self.charset == crate::intl::CS_OCTETS,
        }
    }
}

/// Render text to a charset's bytes for the sort record: carriers
/// round-trip, tabled sets transliterate, UTF-8 (and the untabled)
/// store the value's own bytes. None = untransliterable (the engine
/// raises 22018 there; the caller declines the sort).
pub fn encode_text_value(s: &str, charset: u8) -> Option<Vec<u8>> {
    use crate::intl;
    if intl::byte_carrier(charset) {
        if let Some(b) = intl::carrier_encode(s) {
            return Some(b);
        }
        // text that never came from a carrier decode: the engine
        // stores the client's bytes verbatim
        return Some(s.as_bytes().to_vec());
    }
    match intl::encode_text(charset, s) {
        Ok(Some(b)) => Some(b),
        Ok(None) => Some(s.as_bytes().to_vec()),
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lay(fields: &[TieField], streams: usize, stashes: usize, key_len: usize) -> TieLayout {
        TieLayout::build(key_len, fields, streams, stashes, true)
    }

    fn row1(layout: &TieLayout, fields: &[TieField], vals: &[Value]) -> Vec<u8> {
        let mut r = layout.zero();
        let ids = vec![(0u64, 0i64, true); layout.ids.len()];
        assert!(fill_row(layout, &mut r, fields, vals, &ids, &[], &|s, _| Some(s.as_bytes().to_vec())));
        r
    }

    #[test]
    fn int_data_is_raw_unsigned() {
        // probed: ORDER BY G over {200, 1} answers [1, 200] - data
        // ints are NOT sign-diddled, negatives sort last.
        let f = [TieField::of(dtype::LONG, 4)];
        let l = lay(&f, 1, 0, 8);
        let a = row1(&l, &f, &[Value::Int(1)]);
        let b = row1(&l, &f, &[Value::Int(200)]);
        let c = row1(&l, &f, &[Value::Int(-5)]);
        assert_eq!(cmp_tie(&a, &b), std::cmp::Ordering::Less);
        assert_eq!(cmp_tie(&b, &c), std::cmp::Ordering::Less);
    }

    #[test]
    fn bigint_low_word_first() {
        // probed: {2^32-1, -2, 2^32, -1} answers
        // [2^32, -2, 2^32-1, -1].
        let f = [TieField::of(dtype::INT64, 8)];
        let l = lay(&f, 1, 0, 8);
        let mut rows = [
            (4294967295i64, row1(&l, &f, &[Value::Int(4294967295)])),
            (-2, row1(&l, &f, &[Value::Int(-2)])),
            (4294967296i64, row1(&l, &f, &[Value::Int(4294967296)])),
            (-1, row1(&l, &f, &[Value::Int(-1)])),
        ];
        rows.sort_by(|a, b| cmp_tie(&a.1, &b.1));
        let order: Vec<i64> = rows.iter().map(|r| r.0).collect();
        assert_eq!(order, vec![4294967296, -2, 4294967295, -1]);
    }

    #[test]
    fn double_low_mantissa_first() {
        // probed: {1.1, 2.0} answers [2.0, 1.1].
        let f = [TieField::of(dtype::DOUBLE, 8)];
        let l = lay(&f, 1, 0, 8);
        let a = row1(&l, &f, &[Value::Double(1.1)]);
        let b = row1(&l, &f, &[Value::Double(2.0)]);
        assert_eq!(cmp_tie(&b, &a), std::cmp::Ordering::Less);
    }

    #[test]
    fn varchar_length_then_bytes() {
        // probed: {'b', 'a ', 'aa'} answers ['b', 'a ', 'aa'] -
        // the raw vlen decides before the characters.
        let f = [TieField::of(dtype::VARYING, 12)];
        let l = lay(&f, 1, 0, 8);
        let b = row1(&l, &f, &[Value::Text("b".into())]);
        let a2 = row1(&l, &f, &[Value::Text("a ".into())]);
        let aa = row1(&l, &f, &[Value::Text("aa".into())]);
        assert_eq!(cmp_tie(&b, &a2), std::cmp::Ordering::Less);
        assert_eq!(cmp_tie(&a2, &aa), std::cmp::Ordering::Less);
    }

    #[test]
    fn null_between_empty_and_a() {
        // probed: {NULL, '', 'a'} answers ['', NULL, 'a'].
        let f = [TieField::of(dtype::VARYING, 12)];
        let l = lay(&f, 1, 0, 8);
        let n = row1(&l, &f, &[Value::Null]);
        let e = row1(&l, &f, &[Value::Text("".into())]);
        let a = row1(&l, &f, &[Value::Text("a".into())]);
        assert_eq!(cmp_tie(&e, &n), std::cmp::Ordering::Less);
        assert_eq!(cmp_tie(&n, &a), std::cmp::Ordering::Less);
    }

    #[test]
    fn short_shares_long_with_flags() {
        // probed (D5): (S1, S2) = (1, 2) vs (2, 1) answers S1
        // order - S1 sits high in the flag long.
        let f = [TieField::of(dtype::SHORT, 2), TieField::of(dtype::SHORT, 2)];
        let l = lay(&f, 1, 0, 8);
        let a = row1(&l, &f, &[Value::Int(1), Value::Int(2)]);
        let b = row1(&l, &f, &[Value::Int(2), Value::Int(1)]);
        assert_eq!(cmp_tie(&a, &b), std::cmp::Ordering::Less);
    }

    #[test]
    fn key_region_two_ints() {
        // nullflag + int, twice: 1, (4..8), 9, (12..16) -> 16.
        assert_eq!(key_region_len(&[(dtype::LONG, 4, 0), (dtype::LONG, 4, 0)]), 16);
        assert_eq!(key_region_len(&[(dtype::LONG, 4, 0)]), 8);
    }
}
