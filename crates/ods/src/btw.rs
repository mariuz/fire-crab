//! B-tree WRITE: index maintenance, converted from `BTR_insert`/
//! `insert_node`/`split_and_insert` (btr.cpp) and the key transform in
//! `compress` (btr.cpp:3444) with `make_int64_key` (btr.cpp:7056).
//!
//! Key encoding, byte-exact per itype (DFW_assign_index_type,
//! dfw.epp:1236 picks the itype from the field type):
//!   - NULL: zero-length key (ascending; compress: "ASC NULLs are
//!     stored with no data")
//!   - idx_string: the value's bytes with trailing pads (spaces)
//!     stripped, a fully-padded/empty value collapsing to ONE pad byte
//!   - idx_numeric (SMALLINT/INTEGER, incl. scaled): the value as a
//!     double, big-endian bytes, negatives complemented / positives
//!     sign-flipped, trailing zero bytes chopped (min 1)
//!   - idx_numeric2 (BIGINT/INT64 numerics): INT64_KEY - the scale-
//!     normalized (int64_scale_control, btr.cpp:137) quotient by 10^4
//!     as a double plus the remainder as a SHORT; 8 BE double bytes
//!     (complement/flip as above) + 2 BE short bytes with the short's
//!     sign bit flipped; zero-chop from the tail
//!   - idx_sql_date/time/timestamp/boolean: the raw integer big-endian
//!     with the top bit flipped (two's complement order trick)
//!
//! Page maintenance re-encodes WHOLE pages canonically: nodes carry
//! prefix compression against their predecessor (btn.h writeNode's
//! exact varint layout - flags<<5 | recno low bits, 7-bit continuation
//! at shifts 5/12/19/26/33, non-leaf varint page number, 14-bit prefix
//! and length with the 0/1-length flag shortcuts), `btr_prefix_total`
//! is the sum of prefixes, and the jump table is written EMPTY
//! (jump_count 0/jump_size 0 - legal, the engine adds jumpers as it
//! touches pages; readers position the first node at BTR_SIZE +
//! btr_jump_size).
//!
//! A full page splits exactly as `split_and_insert` does: the left
//! page keeps nodes below the midpoint and ends with an END_BUCKET
//! node that IS the midpoint node; the right page starts with the
//! midpoint node prefix-0/full-key and takes the rest plus the old
//! terminator; siblings re-linked; the parent gains (midpoint key,
//! midpoint recno, right page). A root split makes a new root one
//! level up whose first node is the degenerate zero-length key to the
//! old root - and the index root page's `irt_root` is repointed.
//!
//! DELETE never touches indexes (the engine's VIO_erase does not -
//! entries outlive their records until garbage collection removes
//! both), and UPDATE only ADDS entries for changed keys (IDX_modify).

use crate::btr::{find_index_root, read_node, BtreePage, BTR_NODES_OFFSET};
use crate::format::Value;
use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at};

// itypes, btr.h:123-136
pub const IDX_NUMERIC: u16 = 0;
pub const IDX_STRING: u16 = 1;
/// `idx_offset_intl_range` (btr.h:141, `0x7FFF + idx_first_intl_string`):
/// an on-disk irtd itype at or above this encodes a TTYPE -
/// `itype - 32831` is `(collation << 8) | charset` (a WIN1252 default
/// collation stores 32884 = 32831 + 53, read off a live file). The
/// DEFAULT (binary) collation of a tabled single-byte charset keys
/// exactly like [IDX_METADATA] in that charset's codepage - measured off
/// a live engine index over WIN1252: 'café' keys [63,61,66,E9], 'a '
/// keys [61] (trailing 0x20 stripped), '' keys [00], '€' keys [80].
pub const IDX_OFFSET_INTL: u16 = 0x7FFF + 64;

/// The CHARACTER SET of an INTL itype whose key this crate can build:
/// the DEFAULT (binary) collation of a TABLED single-byte set. A real
/// collation (PXW_INTL and kin) has its own weight tables and answers
/// None - fail-closed, exactly as the allowlists always were.
pub fn intl_binary_charset(itype: u16) -> Option<u8> {
    if itype < IDX_OFFSET_INTL {
        return None;
    }
    let ttype = itype - IDX_OFFSET_INTL;
    let (charset, collation) = ((ttype & 0xFF) as u8, ttype >> 8);
    if collation == 0 && crate::intl::tabled(charset) {
        Some(charset)
    } else {
        None
    }
}
pub const IDX_METADATA: u16 = 4;
pub const IDX_SQL_DATE: u16 = 5;
pub const IDX_SQL_TIME: u16 = 6;
pub const IDX_TIMESTAMP: u16 = 7;
pub const IDX_NUMERIC2: u16 = 8;
pub const IDX_BOOLEAN: u16 = 9;
/// 128-bit integer keys at ODS >= 13.1 (btr.h:136, dfw.epp picks it
/// for `dtype_int128`)
pub const IDX_BCD: u16 = 13;

// irt_flags, ods.h:459-464
pub const IRT_UNIQUE: u16 = 1;
pub const IRT_DESCENDING: u16 = 2;
pub const IRT_FOREIGN: u16 = 4;
pub const IRT_PRIMARY: u16 = 8;
pub const IRT_EXPRESSION: u16 = 16;
pub const IRT_CONDITION: u16 = 32;

/// `int64_scale_control` (btr.cpp:137): normalize a scaled int64 by
/// the largest safe power of ten so equal values with different
/// declared scales map to the same key. (limit, factor, scale_change)
const INT64_SCALE_CONTROL: &[(u64, i64, i16)] = &[
    (922337203685470000, 1, 0),
    (92233720368547000, 10, 1),
    (9223372036854700, 100, 2),
    (922337203685470, 1000, 3),
    (92233720368548, 10000, 4),
    (9223372036855, 100000, 5),
    (922337203686, 1000000, 6),
    (92233720369, 10000000, 7),
    (9223372035, 100000000, 8),
    (922337204, 1000000000, 9),
    (92233721, 10000000000, 10),
    (9223373, 100000000000, 11),
    (922338, 1000000000000, 12),
    (92234, 10000000000000, 13),
    (9224, 100000000000000, 14),
    (923, 1000000000000000, 15),
    (93, 10000000000000000, 16),
    (10, 100000000000000000, 17),
    (1, 1000000000000000000, 18),
    (0, 0, 0),
];

/// `powerof10` (btr.cpp:127): index <= 0 looks up 10^-index, else
/// divides.
fn power_of_10(index: i32) -> f64 {
    if index <= 0 {
        10f64.powi(-index)
    } else {
        1.0 / 10f64.powi(index)
    }
}

/// The double-key tail of `compress` (btr.cpp:3946-3971): big-endian
/// bytes, negatives complemented (the four-SSHORT -x-1 loop is a
/// byte-wise NOT), positives sign-flipped, trailing zeros chopped down
/// to at least one byte.
fn double_key(d: f64) -> Vec<u8> {
    let d = if d == 0.0 { 0.0 } else { d }; // -0 keys like +0 (CORE-3547)
    let mut k = d.to_be_bytes().to_vec();
    if d < 0.0 {
        for b in k.iter_mut() {
            *b = !*b;
        }
    } else {
        k[0] ^= 0x80;
    }
    while k.len() > 1 && *k.last().unwrap() == 0 {
        k.pop();
    }
    k
}

/// The integer keys (date/time/timestamp/boolean): big-endian with the
/// top bit flipped, zero-chopped.
fn flipped_int_key(be: &[u8]) -> Vec<u8> {
    let mut k = be.to_vec();
    k[0] ^= 0x80;
    while k.len() > 1 && *k.last().unwrap() == 0 {
        k.pop();
    }
    k
}

/// `make_int64_key` (btr.cpp:7056) + the int64 emission and munging in
/// `compress`.
fn int64_key(raw: i64, scale: i16) -> Option<Vec<u8>> {
    // i64::MIN IS KEYED AS ZERO, and that is READ OFF THE ENGINE'S OWN
    // INDEX rather than derived. This used to abstain, on the reasoning
    // that `make_int64_key` NEGATES before choosing a scale factor and
    // negating i64::MIN overflows, so its choice "is not the
    // arithmetically correct one" - true, and it stopped one step too
    // early. What the engine actually WRITES was never looked at.
    //
    // Written by the engine, one value per database, dumped with
    // `fcstat index-walk`:
    //
    //     -9223372036854775808 -> 800000000000000080
    //                        0 -> 800000000000000080
    //     -9223372036854775807 -> 3cf5c91d14e3bcd76951
    //                        1 -> bf1a36e2eb1c432d80
    //                       -1 -> 40e5c91d14e3bcd280
    //
    // THE ENGINE FILES i64::MIN UNDER ZERO'S KEY. The overflow does not
    // merely perturb the scale choice - it sends the loop one bucket
    // further, and `q *= 10` on i64::MIN wraps to exactly 0 (10 * 2^63
    // is a multiple of 2^64), so both the double and the short part come
    // out zero. `0 / powerof10(scale)` is zero at every scale, which is
    // why this needs no scale of its own.
    //
    // It is a DEFECT and it is observable in the engine ALONE: equality
    // finds the row (both sides compute the same wrong key) while every
    // RANGE misses it, because the entry sits at zero's position. On the
    // engine, `A < -9223372036854775807` answers nothing though the row
    // exists, and `A+0 < -9223372036854775807` - the same predicate, no
    // index - returns it.
    //
    // Matching it is not endorsing it: a key is an ADDRESS in a shared
    // file. A row fire-crab writes under a different address is a row
    // the engine's own lookups cannot find, which is a lost record
    // rather than a slower one.
    if raw == i64::MIN {
        return int64_key(0, scale);
    }
    let mut n = 0;
    let uq = raw.unsigned_abs();
    while uq < INT64_SCALE_CONTROL[n].0 {
        n += 1;
    }
    let q = raw.wrapping_mul(INT64_SCALE_CONTROL[n].1);
    let scale = scale - INT64_SCALE_CONTROL[n].2;
    let d_part = ((q / 10000) as f64) / power_of_10(scale as i32);
    let s_part = (q % 10000) as i16;

    let mut k = Vec::with_capacity(10);
    k.extend_from_slice(&d_part.to_be_bytes());
    k.extend_from_slice(&s_part.to_be_bytes());
    if d_part < 0.0 {
        for b in k[0..8].iter_mut() {
            *b = !*b;
        }
    } else {
        k[0] ^= 0x80;
    }
    k[8] ^= 0x80; // the short part's sign flip (btr.cpp:3961)
    while k.len() > 1 && *k.last().unwrap() == 0 {
        k.pop();
    }
    Some(k)
}

/// Encode one column value as an index key for `itype` (ascending,
/// single segment). None = a value/itype pairing this conversion does
/// not cover - the caller must refuse the statement, never guess.
pub fn index_key(itype: u16, value: &Value, scale: i8, charset: u8) -> Option<Vec<u8>> {
    if matches!(value, Value::Null) {
        return Some(Vec::new()); // ASC NULL: no data
    }
    match itype {
        IDX_STRING => {
            let Value::Text(s) = value else { return None };
            // a TABLED single-byte column (WIN1252, ISO8859_1) keys its
            // CODEPAGE bytes - the bytes the write path stored, the bytes
            // the engine's own keys hold. A character with no image in
            // the set has no key: answering None SCANS, where a UTF-8
            // key would land elsewhere in the tree and silently MISS the
            // row (the LEFT-join law: a missed inner is a wrong answer).
            // A BYTE-CARRIER column (NONE/OCTETS/ASCII) keys its carrier
            // bytes - the raw stored bytes, measured off a live engine
            // index ([72,61,74,E9] for a raw-byte 'rat\u{e9}').
            let owned: Vec<u8>;
            let bytes: &[u8] = if crate::intl::byte_carrier(charset) {
                match crate::intl::carrier_encode(s) {
                    Some(v) => {
                        owned = v;
                        &owned
                    }
                    None => return None,
                }
            } else {
                match crate::intl::encode_text(charset, s) {
                    Err(_) => return None,
                    Ok(Some(v)) => {
                        owned = v;
                        &owned
                    }
                    Ok(None) => s.as_bytes(),
                }
            };
            let trimmed = bytes.trim_ascii_end_matches();
            Some(if trimmed.is_empty() { vec![b' '] } else { trimmed.to_vec() })
        }
        IDX_METADATA => {
            // INTL_string_to_key ttype_metadata (intl.cpp:949): plain
            // bytes, trailing spaces stripped (metadata text is UTF8
            // already); compress's empty-value pad for a non-idx_string
            // itype is 0x00, not the blank (btr.cpp:3593)
            let Value::Text(s) = value else { return None };
            let trimmed = s.as_bytes().trim_ascii_end_matches();
            Some(if trimmed.is_empty() { vec![0] } else { trimmed.to_vec() })
        }
        // a REAL collation's itype: the collation driver's SORT key -
        // primary weights, then secondaries, then the special trailer
        // (ods::coll, converted from the engine's lc_narrow driver;
        // PXW_INTL is the one driven). Trailing blanks are stripped by
        // the driver's pad option; the empty value keys [00] like its
        // binary siblings. Proven the differential way: the ENGINE's
        // own index scan finds the rows fire-crab keys.
        it if it == IDX_OFFSET_INTL + crate::coll::TTYPE_PXW_INTL => {
            let Value::Text(s) = value else { return None };
            let bytes = match crate::intl::encode_text(crate::intl::CS_WIN1252, s) {
                Ok(Some(v)) => v,
                _ => return None,
            };
            let key = crate::coll::pxw_intl_key(&bytes, false);
            Some(if key.is_empty() { vec![0] } else { key })
        }
        // an INTL itype with the DEFAULT (binary) collation: the
        // codepage's bytes, trailing 0x20 stripped, empty keyed [00] -
        // IDX_METADATA's shape in the column's own character set
        // (measured off a live engine index, see IDX_FIRST_INTL)
        it if intl_binary_charset(it).is_some() => {
            let cs = intl_binary_charset(it).unwrap();
            let Value::Text(s) = value else { return None };
            let owned = match crate::intl::encode_text(cs, s) {
                Ok(Some(v)) => v,
                // an unmappable (or untabled) search key has no image in
                // the tree: None SCANS, where a UTF-8 key would MISS
                _ => return None,
            };
            let trimmed = owned.trim_ascii_end_matches();
            Some(if trimmed.is_empty() { vec![0] } else { trimmed.to_vec() })
        }
        IDX_NUMERIC => {
            // MOV_get_double of a scaled exact numeric. It DIVIDES by
            // the power of ten; multiplying by 10^-n is a DIFFERENT
            // DOUBLE in the last ulp for most raws, and a key that
            // differs in one bit is a key the engine never wrote. At
            // scale 1 the raws that disagreed were 3, 6, 7, 12, 14, 17,
            // ... - so a DECIMAL(9,1) column lost about a third of its
            // values from every index that held it, in both directions:
            // retrieval could not find them and the ENGINE could not
            // find what fire-crab wrote.
            let d = match value {
                Value::Int(v) => *v as f64,
                Value::Scaled(raw, s) if *s < 0 => {
                    *raw as f64 / 10f64.powi(-(*s as i32))
                }
                Value::Scaled(raw, s) => *raw as f64 * 10f64.powi(*s as i32),
                Value::Double(d) => *d,
                // a FLOAT column decodes to its own value form (kept
                // apart from Double for printing), and rejecting it here
                // meant every candidate from an index holding one failed
                // verification - the index returned the EMPTY SET
                Value::Float(f) => *f as f64,
                _ => return None,
            };
            Some(double_key(d))
        }
        IDX_NUMERIC2 => {
            let (raw, s) = match value {
                Value::Int(v) => (*v, scale as i16),
                Value::Scaled(raw, s) => (*raw, *s as i16),
                _ => return None,
            };
            int64_key(raw, s)
        }
        IDX_SQL_DATE => {
            let Value::Date(d) = value else { return None };
            Some(flipped_int_key(&d.to_be_bytes()))
        }
        IDX_SQL_TIME => {
            let Value::Time(t) = value else { return None };
            Some(flipped_int_key(&t.to_be_bytes()))
        }
        IDX_TIMESTAMP => {
            let Value::Timestamp(d, t) = value else { return None };
            let v = *d as i64 * 86_400 * 10_000 + *t as i64;
            Some(flipped_int_key(&v.to_be_bytes()))
        }
        IDX_BOOLEAN => {
            let Value::Bool(b) = value else { return None };
            Some(vec![if *b { 0x81 } else { 0x80 }])
        }
        IDX_BCD => {
            let (raw, s) = match value {
                Value::Int(v) => (*v as i128, scale),
                Value::Scaled(raw, s) => (*raw as i128, *s),
                Value::Int128(raw, s) => (*raw, *s),
                _ => return None,
            };
            Some(int128_bcd_key(raw, s as i32))
        }
        _ => None,
    }
}

/// `Int128::makeIndexKey` (Int128.cpp:656) + `Decimal128::makeBcdKey`
/// (DecFloat.cpp:1068), ported byte for byte: the value's decimal
/// digits, normalized (leading zeros shifted out with the exponent
/// compensated, trailing zeros trimmed), behind a 2-byte biased
/// sign-folded exponent; a negative value nine's-complements its
/// digits (last digit pre-decremented) and negates the exponent so
/// the whole key stays order-preserving under unsigned byte compare;
/// the digits pack 3-per-10-bits, the trailing partial byte kept only
/// when nonzero. BIAS 128 and PMAX 39 - Int128.h declares TWO Int128
/// classes and the built one uses 39 (an i128's 39 digits fill the
/// coefficient exactly; the PMAX-38 twin would not survive the live
/// engine's own 39-digit inserts, which it does). At most 19 bytes.
pub fn int128_bcd_key(v: i128, mut exp: i32) -> Vec<u8> {
    const PMAX: usize = 39;
    const BIAS: i32 = 128;
    let mut coeff = [0u8; PMAX + 2];
    let mut u = v.unsigned_abs();
    let mut c = PMAX;
    while u > 0 {
        c -= 1;
        coeff[c] = (u % 10) as u8;
        u /= 10;
    }
    // digits(): shift out leading zeros (exponent compensated by the
    // implied trailing zeros the shift creates), trim trailing zeros
    let mut dig = 0usize;
    for i in 0..PMAX {
        if coeff[i] != 0 {
            if i > 0 {
                coeff.copy_within(i..PMAX, 0);
                for z in &mut coeff[PMAX - i..PMAX] {
                    *z = 0;
                }
                exp -= i as i32;
            }
            let mut n = PMAX - i;
            while coeff[n - 1] == 0 {
                n -= 1;
            }
            dig = n;
            break;
        }
    }
    let neg = v < 0;
    let mut e = exp + (BIAS + 1);
    if dig == 0 {
        e = 0;
    }
    if neg {
        e = -e;
    }
    e += 2 * (BIAS + 1); // make it positive
    let mut out = vec![(e >> 8) as u8, (e & 0xff) as u8];
    if neg && dig > 0 {
        coeff[dig - 1] -= 1;
        for d in &mut coeff[..dig] {
            *d = 9 - *d;
        }
    }
    coeff[dig] = 0;
    coeff[dig + 1] = 0;
    // compress: 3 decimal digits (999) per 10 bits, via the shift table
    let table: [(u32, u32); 4] = [(2, 6), (4, 4), (6, 2), (8, 0)];
    let mut cur = 0u8;
    let mut t = 0usize;
    let mut p = 0usize;
    while p < dig {
        let val =
            (coeff[p] as u16) * 100 + (coeff[p + 1] as u16) * 10 + (coeff[p + 2] as u16);
        cur |= (val >> table[t].0) as u8;
        out.push(cur);
        cur = ((val as u32) << table[t].1) as u8;
        if table[t].1 == 0 {
            // The 4th group of the cycle completes a byte. Push it only
            // when it CARRIES something or when more digits follow: a
            // trailing zero byte here is one the engine's makeBcdKey
            // does not write, and a key one byte longer than the engine's
            // is a key that matches nothing. It needed a value whose last
            // 3-digit group lands at t == 3 AND is a multiple of 256 -
            // about 2 in 3000 random NUMERIC(38,6) values.
            if cur != 0 || p + 3 < dig {
                out.push(cur);
            }
            cur = 0;
            t = 0;
        } else {
            t += 1;
        }
        p += 3;
    }
    if cur != 0 {
        out.push(cur);
    }
    out
}

/// How many data bytes each compound-key group carries between the
/// segment-marker bytes (ods.h:631).
pub const STUFF_COUNT: usize = 4;

/// One segment of an index key: the value to encode, its itype, and
/// the column scale (INT64_KEY normalization needs it).
pub struct KeySeg<'a> {
    pub itype: u16,
    pub value: &'a Value,
    pub scale: i8,
    /// the column's character set (a text segment keys its CODEPAGE
    /// bytes for a tabled single-byte set; 0 = NONE keeps raw bytes)
    pub charset: u8,
}

/// Compress one segment the way `compress` (btr.cpp:3444) does for a
/// full-key build, pre-complement. Ascending NULL is zero bytes;
/// DESCENDING NULL is one 0x00 byte (btr.cpp:3463-3479 - so that the
/// post-complement 0xFF sorts NULLs apart from values). A descending
/// value whose first byte is 0x00 or 0x01 gets a 0x01 prepended
/// (btr.cpp:3603/3978: the pre-complement image of the 0xFE
/// end-value guard, which keeps values distinguishable from the NULL
/// marker after complement).
fn compress_seg(
    itype: u16,
    value: &Value,
    scale: i8,
    charset: u8,
    descending: bool,
) -> Option<Vec<u8>> {
    if matches!(value, Value::Null) {
        return Some(if descending { vec![0] } else { Vec::new() });
    }
    let mut k = index_key(itype, value, scale, charset)?;
    if descending && matches!(k.first(), Some(0) | Some(1)) {
        k.insert(0, 1);
    }
    Some(k)
}

/// `BTR_key` (btr.cpp:2245) for a full key - the shape every insertion
/// builds. A single segment is the plain compressed value. A compound
/// key interleaves each segment's bytes with marker bytes: every group
/// is one marker byte - the number of segments REMAINING including the
/// current one (`idx_count - n`) - followed by up to [STUFF_COUNT]
/// data bytes, and the group left unfinished when a segment ends is
/// zero-padded to its full width before the next segment starts its
/// own group. A descending index complements the WHOLE assembled key
/// (markers and padding included - `BTR_complement_key` runs after
/// assembly). Returns the key and whether EVERY segment was NULL - the
/// engine exempts a key from unique enforcement only when it is
/// all-NULL (btr.cpp:5629 `key_all_nulls`); a partial-NULL compound
/// key still validates duplicates, as the multiseg differential
/// proved against the live engine.
pub fn build_index_key(segs: &[KeySeg<'_>], descending: bool) -> Option<(Vec<u8>, bool)> {
    let all_null = segs.iter().all(|s| matches!(s.value, Value::Null));
    let mut out;
    if segs.len() == 1 {
        out = compress_seg(segs[0].itype, segs[0].value, segs[0].scale, segs[0].charset, descending)?;
    } else {
        out = Vec::new();
        let total = segs.len();
        let mut stuff = 0usize;
        for (n, seg) in segs.iter().enumerate() {
            // complete the previous segment's group with zeros
            while stuff > 0 {
                out.push(0);
                stuff -= 1;
            }
            let temp = compress_seg(seg.itype, seg.value, seg.scale, seg.charset, descending)?;
            for &b in &temp {
                if stuff == 0 {
                    out.push((total - n) as u8);
                    stuff = STUFF_COUNT;
                }
                out.push(b);
                stuff -= 1;
            }
        }
    }
    if descending {
        for b in out.iter_mut() {
            *b = !*b;
        }
    }
    Some((out, all_null))
}

trait TrimAsciiEnd {
    fn trim_ascii_end_matches(&self) -> &[u8];
}
impl TrimAsciiEnd for [u8] {
    fn trim_ascii_end_matches(&self) -> &[u8] {
        let mut end = self.len();
        while end > 0 && self[end - 1] == b' ' {
            end -= 1;
        }
        &self[..end]
    }
}

/// One decoded node of a page, key fully reconstructed.
#[derive(Clone, Debug)]
struct BtNode {
    key: Vec<u8>,
    recno: u64,
    page: u32,
}

enum Terminator {
    /// rightmost page of its level
    Level,
    /// non-rightmost: the node that continues on the sibling
    Bucket(BtNode),
}

struct PageContent {
    level: u8,
    sibling: u32,
    left_sibling: u32,
    nodes: Vec<BtNode>,
    term: Terminator,
}

fn load_page(file: &crate::Image, page_size: usize, no: u32) -> Option<BtreePage<'_>> {
    crate::page_at(file, page_size, no).and_then(BtreePage::decode)
}

/// Decode a page's full node list (keys prefix-decompressed).
fn decode_content(bp: &BtreePage) -> Option<PageContent> {
    let leaf = bp.level == 0;
    let bytes = bp.bytes();
    let mut at = bp.first_node();
    let mut key: Vec<u8> = Vec::new();
    let mut nodes = Vec::new();
    let term = loop {
        let n = read_node(bytes, at, leaf)?;
        if n.is_end_level {
            break Terminator::Level;
        }
        key.truncate(n.prefix as usize);
        key.extend_from_slice(bytes.get(n.data_at..n.data_at + n.length as usize)?);
        if n.is_end_bucket {
            break Terminator::Bucket(BtNode {
                key: key.clone(),
                recno: n.record_number,
                page: n.page_number,
            });
        }
        nodes.push(BtNode { key: key.clone(), recno: n.record_number, page: n.page_number });
        at = n.next_at;
    };
    Some(PageContent {
        level: bp.level,
        sibling: bp.sibling,
        left_sibling: bp.left_sibling,
        nodes,
        term,
    })
}

/// `IndexNode::writeNode` (btn.cpp:396): emit one node. `flags` 0 for
/// an ordinary node, 2 for END_BUCKET.
fn write_node(out: &mut Vec<u8>, leaf: bool, end_bucket: bool, prefix: usize, suffix: &[u8], recno: u64, page: u32) {
    let length = suffix.len();
    let internal: u8 = if end_bucket {
        2 // BTN_END_BUCKET_FLAG
    } else if length == 0 {
        if prefix == 0 { 3 } else { 4 } // ZERO_PREFIX_ZERO_LENGTH / ZERO_LENGTH
    } else if length == 1 {
        5 // ONE_LENGTH
    } else {
        0
    };
    out.push((internal << 5) | (recno & 0x1F) as u8);
    // varint recno continuation, shifts 5/12/19/26/33
    let mut number = recno >> 5;
    loop {
        let mut b = (number & 0x7F) as u8;
        number >>= 7;
        if number != 0 {
            b |= 0x80;
        }
        out.push(b);
        if number == 0 {
            break;
        }
    }
    if !leaf {
        let mut n = page as u64;
        loop {
            let mut b = (n & 0x7F) as u8;
            n >>= 7;
            if n != 0 {
                b |= 0x80;
            }
            out.push(b);
            if n == 0 {
                break;
            }
        }
    }
    if internal != 3 {
        // prefix, max 14 bits
        let mut n = prefix;
        let mut b = (n & 0x7F) as u8;
        n >>= 7;
        if n > 0 {
            b |= 0x80;
        }
        out.push(b);
        if n > 0 {
            out.push((n & 0x7F) as u8);
        }
    }
    if internal != 3 && internal != 4 && internal != 5 {
        let mut n = length;
        let mut b = (n & 0x7F) as u8;
        n >>= 7;
        if n > 0 {
            b |= 0x80;
        }
        out.push(b);
        if n > 0 {
            out.push((n & 0x7F) as u8);
        }
    }
    out.extend_from_slice(suffix);
}

fn common_prefix(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}

/// Re-encode a page canonically: prefix compression against each
/// predecessor, END_BUCKET/END_LEVEL terminator, `btr_prefix_total`,
/// `btr_length`, empty jump table. Err = does not fit.
fn encode_page(
    file: &mut crate::Image,
    page_size: usize,
    page_no: u32,
    relation: u16,
    index_id: u8,
    c: &PageContent,
) -> Result<(), ()> {
    let leaf = c.level == 0;
    let mut body: Vec<u8> = Vec::with_capacity(page_size);
    let mut prev: &[u8] = &[];
    let mut prefix_total: u64 = 0;
    for n in &c.nodes {
        let p = common_prefix(prev, &n.key);
        prefix_total += p as u64;
        write_node(&mut body, leaf, false, p, &n.key[p..], n.recno, n.page);
        prev = &n.key;
    }
    match &c.term {
        Terminator::Level => {
            // END_LEVEL: writeNode emits only the first byte
            body.push(1u8 << 5);
        }
        Terminator::Bucket(n) => {
            let p = common_prefix(prev, &n.key);
            prefix_total += p as u64;
            write_node(&mut body, leaf, true, p, &n.key[p..], n.recno, n.page);
        }
    }
    let total = BTR_NODES_OFFSET + body.len();
    if total > page_size {
        return Err(());
    }
    let page = crate::page_mut(file, page_size, page_no).expect("encode_page: page out of range");
    page.fill(0);
    page[0] = PageType::Index as u8;
    page[12..16].copy_from_slice(&page_no.to_le_bytes()); // pag_pageno
    page[16..20].copy_from_slice(&c.sibling.to_le_bytes());
    page[20..24].copy_from_slice(&c.left_sibling.to_le_bytes());
    page[24..28].copy_from_slice(&(prefix_total as u32).to_le_bytes());
    page[28..30].copy_from_slice(&relation.to_le_bytes());
    page[30..32].copy_from_slice(&(total as u16).to_le_bytes());
    page[32] = index_id;
    page[33] = c.level;
    // btr_jump_interval kept as the engine writes fresh pages; an
    // EMPTY jump table (size 0, count 0) - readers start nodes at
    // BTR_SIZE + jump_size and the engine re-jumps pages it touches
    page[34..36].copy_from_slice(&0u16.to_le_bytes());
    page[36..38].copy_from_slice(&0u16.to_le_bytes());
    page[38] = 0;
    page[BTR_NODES_OFFSET..total].copy_from_slice(&body);
    Ok(())
}

/// The (key, recno) node order: keys memcmp, duplicates by record
/// number.
fn node_cmp(key: &[u8], recno: u64, n: &BtNode) -> std::cmp::Ordering {
    key.cmp(&n.key).then(recno.cmp(&n.recno))
}

/// Node order in a DESCENDING index.
///
/// A descending key is stored COMPLEMENTED, so plain byte order almost
/// works - except where one key is a byte PREFIX of another. Ordinary
/// lexicographic comparison pads the shorter key with 0x00, which puts
/// it FIRST; the engine pads it with 0xFF, which puts it LAST. Writing
/// entries in the wrong order produced an index the engine's own
/// retrieval could not read (`WHERE D = 3` found nothing on a table
/// that held it, `ORDER BY D DESC` came back out of order) and that
/// `gfix -v -full` reported as index page errors.
fn node_cmp_desc(key: &[u8], recno: u64, n: &BtNode) -> std::cmp::Ordering {
    key_cmp_desc(key, &n.key).then(recno.cmp(&n.recno))
}

/// Two DESCENDING keys in stored order - the rule above, stated ONCE
/// because the RETRIEVAL needs it as much as the write does. A band on a
/// descending index that compares its bounds with plain `memcmp` walks
/// past the rows it wants exactly where this differs: `btr::lookup_range`
/// takes it as `desc`.
pub fn key_cmp_desc(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    let len = a.len().max(b.len());
    for i in 0..len {
        // the missing bytes of the shorter key are 0xFF here, not 0x00
        let x = a.get(i).copied().unwrap_or(0xFF);
        let y = b.get(i).copied().unwrap_or(0xFF);
        if x != y {
            return x.cmp(&y);
        }
    }
    std::cmp::Ordering::Equal
}

/// Insert one (key, recno) into index `index_id` of `rel` -
/// `BTR_insert`: descend to the leaf, insert in order, split full
/// pages upward, grow a new root when the root itself splits (the
/// index root page repointed). `unique` refuses an existing equal
/// non-NULL key (isc_no_dup semantics).
#[allow(clippy::too_many_arguments)]

/// Whether the record a conflicting index entry names is still a LIVE
/// row - a primary version that is not a deleted stub. A unique-index
/// insert refuses only against a live conflict; an entry left behind
/// by a deleted (dropped, or key-changed) record is a ghost the GC has
/// not swept yet, and re-using its key is legal. Absent record, absent
/// page, a back-version or a deleted stub all read as NOT live.
fn recno_is_live(file: &crate::Image, page_size: usize, rel: u16, recno: u64) -> bool {
    let recs = crate::format::max_recs_per_dp(page_size);
    if recs == 0 {
        return false;
    }
    let seq = (recno / recs) as u32;
    let slot = (recno % recs) as u16;
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in crate::pointer::relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no)
            .and_then(crate::data::DataPage::decode)
        else {
            continue;
        };
        if dp.sequence != seq {
            continue;
        }
        // "a live row at this slot" is the MVCC question, not the flag
        // one: a version whose transaction is DEAD is no row (a
        // rolled-back DDL's catalog row, a rolled-back INSERT's key),
        // and a deleted stub over a live back version IS one. The
        // catalog walk answers both - committed and active count
        // ALWAYS THE WIDE WALK: a key is taken by any row that counts for
        // anybody - committed, or any ACTIVE transaction's (the writer's
        // own included, whatever view the request set: an autonomous
        // block's id is younger than the request's reader view)
        return dp.record(slot).is_some_and(|r| {
            if r.flags & (crate::data::flags::CHAIN | crate::data::flags::FRAGMENT | crate::data::flags::BLOB) != 0 {
                return false;
            }
            match tips.as_ref() {
                Some(t) => crate::tra::visible_version(file, page_size, &r, t, &crate::tra::OwnTx::catalog()).is_some(),
                None => r.is_primary_record(),
            }
        });
    }
    false
}

pub fn insert_index_entry(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    index_id: u8,
    key: &[u8],
    recno: u64,
    unique: bool,
    descending: bool,
) -> Result<(), String> {
    // a DESCENDING index orders its (complemented) keys by a different
    // rule where one is a prefix of another - see `node_cmp_desc`
    let cmp = |k: &[u8], r: u64, n: &BtNode| {
        if descending {
            node_cmp_desc(k, r, n)
        } else {
            node_cmp(k, r, n)
        }
    };
    let root_page = {
        let irt = find_index_root(file, page_size, rel).ok_or("no index root")?;
        let e = irt.entry(index_id).ok_or("no such index")?;
        if e.root_page == 0 {
            return Err("index has no root page".into());
        }
        e.root_page
    };

    // descend, remembering the path of interior pages
    let mut path: Vec<u32> = Vec::new();
    let mut cur = root_page;
    loop {
        let bp = load_page(file, page_size, cur).ok_or("bad btree page")?;
        let c = decode_content(&bp).ok_or("undecodable btree page")?;
        // an equal-or-greater END_BUCKET key continues on the sibling
        if let Terminator::Bucket(t) = &c.term {
            if cmp(key, recno, t) != std::cmp::Ordering::Less {
                cur = c.sibling;
                continue;
            }
        }
        if c.level == 0 {
            break;
        }
        // interior: the LAST node whose (key, recno) <= ours; the
        // first node (degenerate) when everything is greater. THE
        // DEGENERATE NODE IS NOT COMPARED: its empty key is -infinity
        // by position, and under the DESCENDING rule an empty key
        // compares GREATEST (0xFF padding) - comparing it sent every
        // key of a descending index down the leftmost child once the
        // root had split, and put the split keys before the degenerate
        // node in the parent (gfix: "inconsistent left sibling
        // pointer", a lookup that missed rows; 300k-row probe).
        let mut child = c.nodes.first().ok_or("empty interior page")?.page;
        for n in c.nodes.iter().skip(1) {
            if cmp(key, recno, n) == std::cmp::Ordering::Less {
                break;
            }
            child = n.page;
        }
        path.push(cur);
        cur = child;
    }

    // the leaf: unique check, ordered insert
    let bp = load_page(file, page_size, cur).ok_or("bad leaf page")?;
    let mut content = decode_content(&bp).ok_or("undecodable leaf")?;
    // an identical (key, recno) is already ours - an entry left behind
    // by an earlier version of the same record (entries outlive record
    // versions); nothing to do
    if content.nodes.iter().any(|n| n.key == key && n.recno == recno) {
        return Ok(());
    }
    // unique violation = the same non-NULL key under a DIFFERENT,
    // STILL-LIVE record. Our own stale entries do not count, and
    // neither do a DELETED record's: an index entry outlives the
    // record version that wrote it (GC clears it later), so a dropped
    // catalog row - or an UPDATE that freed a key - leaves an entry
    // whose record is gone, and re-inserting the key must not collide
    // with that ghost. The engine checks the conflicting record's
    // state the same way (idx.cpp's duplicate scan skips deleted
    // versions); without this, no object could be dropped and created
    // again under the same name.
    if unique
        && !key.is_empty()
        && content
            .nodes
            .iter()
            .any(|n| n.key == key && n.recno != recno && recno_is_live(file, page_size, rel, n.recno))
    {
        // the EXACT string is load-bearing: the server matches on it to
        // build the typed 23000 vector (gdscode 335544665 with the
        // constraint and key params) - a debugging enrichment of this
        // message degraded seven gates' vectors to the generic code
        return Err("duplicate key in unique index".into());
    }
    let pos = content
        .nodes
        .iter()
        .position(|n| cmp(key, recno, n) == std::cmp::Ordering::Less)
        .unwrap_or(content.nodes.len());
    content.nodes.insert(pos, BtNode { key: key.to_vec(), recno, page: 0 });

    // write, splitting up the path as needed
    let mut level_page = cur;
    let mut level_content = content;
    loop {
        if encode_page(file, page_size, level_page, rel, index_id, &level_content).is_ok() {
            return Ok(());
        }
        // split_and_insert: midpoint node goes right (full key) AND
        // terminates the left page as its END_BUCKET
        let m = level_content.nodes.len() / 2;
        if m == 0 || m >= level_content.nodes.len() {
            return Err("btree node too large to split".into());
        }
        let right_nodes: Vec<BtNode> = level_content.nodes.split_off(m);
        let mid = right_nodes[0].clone();

        let new_page = crate::dml::allocate_page(file, page_size)?;
        let right = PageContent {
            level: level_content.level,
            sibling: level_content.sibling,
            left_sibling: level_page,
            nodes: right_nodes,
            term: std::mem::replace(&mut level_content.term, Terminator::Bucket(mid.clone())),
        };
        encode_page(file, page_size, new_page, rel, index_id, &right)
            .map_err(|_| "split right half does not fit".to_string())?;
        // old right neighbor's left link
        if right.sibling != 0 {
            crate::page_mut(file, page_size, right.sibling)
                .expect("sibling page out of range")[20..24]
                .copy_from_slice(&new_page.to_le_bytes());
        }
        level_content.sibling = new_page;
        encode_page(file, page_size, level_page, rel, index_id, &level_content)
            .map_err(|_| "split left half does not fit".to_string())?;

        // propagate (mid key, mid recno, new page) into the parent
        let parent_node = BtNode { key: mid.key, recno: mid.recno, page: new_page };
        match path.pop() {
            Some(parent) => {
                let pb = load_page(file, page_size, parent).ok_or("bad parent page")?;
                let mut pc = decode_content(&pb).ok_or("undecodable parent")?;
                // the degenerate first node stays first (see the descent)
                let pos = pc
                    .nodes
                    .iter()
                    .skip(1)
                    .position(|n| {
                        cmp(&parent_node.key, parent_node.recno, n)
                            == std::cmp::Ordering::Less
                    })
                    .map_or(pc.nodes.len(), |i| i + 1);
                pc.nodes.insert(pos, parent_node);
                level_page = parent;
                level_content = pc;
            }
            None => {
                // root split: a new root one level up - degenerate
                // zero-key first node to the old (left) root
                let new_root = crate::dml::allocate_page(file, page_size)?;
                let rc = PageContent {
                    level: level_content.level + 1,
                    sibling: 0,
                    left_sibling: 0,
                    nodes: vec![
                        BtNode { key: Vec::new(), recno: 0, page: level_page },
                        parent_node,
                    ],
                    term: Terminator::Level,
                };
                encode_page(file, page_size, new_root, rel, index_id, &rc)
                    .map_err(|_| "new root does not fit".to_string())?;
                // repoint irt_root (irt_rpt entry offset 24 + id*24, root @8).
                // The index root page is looked up HERE, on the root split
                // alone - a whole-file scan per insert had been the cost of
                // every index write (a 300k-row CREATE INDEX: 41 s)
                let irt_page = file
                    .pages()
                    .position(|p| p[0] == PageType::IndexRoot as u8 && u16_at(p, 16) == rel)
                    .ok_or("no index root page")? as u32;
                let at = 24 + index_id as usize * 24 + 8; // page-local
                crate::page_mut(file, page_size, irt_page)
                    .ok_or("irt page out of range")?[at..at + 4]
                    .copy_from_slice(&new_root.to_le_bytes());
                return Ok(());
            }
        }
    }
}

/// Build index `index_id` of `rel` WHOLE from `sorted` (key, recno) pairs
/// already in the tree's order - the engine's `fast_load` (btr.cpp): the
/// leaves are filled in sequence, each closed with the next page's first
/// node as its END_BUCKET and linked to it, then every level above from
/// the (first key, recno, page) of the pages below - the leftmost page of
/// each upper level opening with the degenerate empty-key node - until
/// one page remains, which is written INTO the index's existing root page
/// (`irt_root` untouched). The tree is what a sequence of
/// [insert_index_entry] calls would have grown, without each insert
/// decoding and re-encoding a page (a 300k-row CREATE INDEX: 41 s as
/// inserts, ~1 s here).
///
/// `unique` refuses two consecutive equal keys (the rows are all live -
/// a build keys committed primary rows); a NULL key (`all_null`) is
/// exempt unless the index is a primary key, the rule [insert_index_entry]
/// is given per key.
pub fn build_index_bulk(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    index_id: u8,
    sorted: &[(Vec<u8>, u64, bool)],
    unique: bool,
    primary: bool,
) -> Result<(), String> {
    let root_page = {
        let irt = find_index_root(file, page_size, rel).ok_or("no index root")?;
        let e = irt.entry(index_id).ok_or("no such index")?;
        if e.root_page == 0 {
            return Err("index has no root page".into());
        }
        e.root_page
    };
    // nothing to key: the empty root the index was created with stands
    if sorted.is_empty() {
        return Ok(());
    }
    if unique || primary {
        for w in sorted.windows(2) {
            let (a, b) = (&w[0], &w[1]);
            let dup_counts = (unique && !a.0.is_empty() && !a.2 && !b.2) || primary;
            if dup_counts && a.0 == b.0 && a.1 != b.1 {
                return Err("duplicate key in unique index".into());
            }
        }
    }
    // one level: the pages written, each remembered by its first node
    // (key, recno) and number, for the level above
    fn write_level(
        file: &mut crate::Image,
        page_size: usize,
        rel: u16,
        index_id: u8,
        level: u8,
        nodes: &[BtNode],
        root_page: u32,
    ) -> Result<Vec<BtNode>, String> {
        let leaf = level == 0;
        let cap = page_size - BTR_NODES_OFFSET - 1; // the END_LEVEL byte
        let mut pages: Vec<(u32, PageContent)> = Vec::new();
        let mut cur: Vec<BtNode> = Vec::new();
        let mut body = 0usize;
        let mut prev: &[u8] = &[];
        let mut scratch = Vec::new();
        for n in nodes {
            let p = common_prefix(prev, &n.key);
            scratch.clear();
            write_node(&mut scratch, leaf, false, p, &n.key[p..], n.recno, n.page);
            // the node, and room for it again as the END_BUCKET it would
            // become (its own prefix against the last key)
            if !cur.is_empty() && body + 2 * scratch.len() + 2 > cap {
                let page_no = crate::dml::allocate_page(file, page_size)?;
                pages.push((
                    page_no,
                    PageContent { level, sibling: 0, left_sibling: 0, nodes: std::mem::take(&mut cur), term: Terminator::Bucket(n.clone()) },
                ));
                body = 0;
                prev = &[];
                let p = common_prefix(prev, &n.key);
                scratch.clear();
                write_node(&mut scratch, leaf, false, p, &n.key[p..], n.recno, n.page);
            }
            body += scratch.len();
            cur.push(n.clone());
            prev = &n.key;
        }
        // the rightmost page of the level: the root page when it is alone
        let last_no = if pages.is_empty() { root_page } else { crate::dml::allocate_page(file, page_size)? };
        pages.push((last_no, PageContent { level, sibling: 0, left_sibling: 0, nodes: cur, term: Terminator::Level }));
        // link and write
        let numbers: Vec<u32> = pages.iter().map(|(no, _)| *no).collect();
        let mut firsts = Vec::with_capacity(pages.len());
        for (i, (no, mut c)) in pages.into_iter().enumerate() {
            c.sibling = numbers.get(i + 1).copied().unwrap_or(0);
            c.left_sibling = if i == 0 { 0 } else { numbers[i - 1] };
            let first = c.nodes.first().ok_or("empty index page in a bulk build")?;
            // a level's leftmost page above the leaves opens with the
            // degenerate node: its pointer key is -infinity by position
            let key = if i == 0 && level > 0 { Vec::new() } else { first.key.clone() };
            firsts.push(BtNode { key, recno: if i == 0 && level > 0 { 0 } else { first.recno }, page: no });
            encode_page(file, page_size, no, rel, index_id, &c).map_err(|_| "bulk-built index page does not fit".to_string())?;
        }
        Ok(firsts)
    }
    let mut level_nodes: Vec<BtNode> = sorted.iter().map(|(k, r, _)| BtNode { key: k.clone(), recno: *r, page: 0 }).collect();
    let mut level = 0u8;
    loop {
        let firsts = write_level(file, page_size, rel, index_id, level, &level_nodes, root_page)?;
        if firsts.len() == 1 {
            return Ok(());
        }
        // the degenerate node of a level's first page keeps the empty key;
        // every other pointer is the page's first (key, recno)
        let mut up = firsts;
        if let Some(first) = up.first_mut() {
            first.key.clear();
            first.recno = 0;
        }
        level_nodes = up;
        level += 1;
    }
}

/// Write an EMPTY leaf bucket - what a freshly created index's root
/// looks like (probe: 40 bytes of content = BTR_SIZE 39 + the single
/// END_LEVEL marker byte). The engine reads and fills it like any
/// bucket of its own.
pub fn write_empty_root(
    file: &mut crate::Image,
    page_size: usize,
    page_no: u32,
    relation: u16,
    index_id: u8,
) -> Result<(), String> {
    let c = PageContent {
        level: 0,
        sibling: 0,
        left_sibling: 0,
        nodes: Vec::new(),
        term: Terminator::Level,
    };
    encode_page(file, page_size, page_no, relation, index_id, &c)
        .map_err(|_| "empty root does not fit".to_string())
}

/// The single-segment descriptor of an index: (field id, itype), read
/// from the irtd array the root entry points at (ods.h:437-447).
pub fn index_segment(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    index_id: u8,
) -> Option<(u16, u16, u16)> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == PageType::IndexRoot as u8 && u16_at(p, 16) == rel)? as u32;
    let page = crate::page_at(file, page_size, irt_page)?;
    PageHeader::decode(page)?;
    let entry_at = 24 + index_id as usize * 24;
    let desc_off = u16_at(page, entry_at + 16) as usize; // irt_desc @16
    let flags = u16_at(page, entry_at + 18);
    let field = u16_at(page, desc_off); // irtd_field @0
    let itype = u16_at(page, desc_off + 2); // irtd_itype @2
    let _ = u32_at(page, desc_off + 4); // selectivity, unused
    Some((field, itype, flags))
}

/// Every segment descriptor of an index: (field id, itype) per segment
/// in key order, plus the irt_flags. `count` is the root entry's
/// irt_keys; the irtd array (8 bytes per entry - field u16, itype u16,
/// selectivity f32; ods.h:437-447) sits at the entry's irt_desc offset,
/// page-relative.
pub fn index_segments(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    index_id: u8,
    count: usize,
) -> Option<(Vec<(u16, u16)>, u16)> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == PageType::IndexRoot as u8 && u16_at(p, 16) == rel)? as u32;
    let page = crate::page_at(file, page_size, irt_page)?;
    PageHeader::decode(page)?;
    let entry_at = 24 + index_id as usize * 24;
    let desc_off = u16_at(page, entry_at + 16) as usize; // irt_desc @16
    let flags = u16_at(page, entry_at + 18);
    let mut segs = Vec::with_capacity(count);
    for i in 0..count {
        let at = desc_off + i * 8;
        if at + 8 > page.len() {
            return None;
        }
        segs.push((u16_at(page, at), u16_at(page, at + 2)));
    }
    Some((segs, flags))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The DESCENDING order rule, which decides where an entry is
    /// WRITTEN. A descending key is stored complemented, so plain byte
    /// order almost works - and fails on exactly one shape: where one
    /// key is a byte PREFIX of another. Ordinary comparison pads the
    /// shorter with 0x00 and puts it FIRST; the engine pads it with
    /// 0xFF and puts it LAST. Getting it wrong wrote entries into the
    /// wrong place, which fire-crab could still read back (it reads
    /// what it wrote) and the ENGINE could not - gfix called it index
    /// page errors.
    #[test]
    fn a_descending_prefix_sorts_after_the_key_it_prefixes() {
        let node = |k: &[u8]| BtNode { key: k.to_vec(), recno: 0, page: 0 };
        use std::cmp::Ordering;
        // the prefix is GREATER under the descending rule ...
        assert_eq!(node_cmp_desc(&[0xC0], 0, &node(&[0xC0, 0x10])), Ordering::Greater);
        // ... and LESS under the ordinary one, which is the whole bug
        assert_eq!(node_cmp(&[0xC0], 0, &node(&[0xC0, 0x10])), Ordering::Less);
        // where neither is a prefix the two agree
        assert_eq!(node_cmp_desc(&[0xC0, 0x10], 0, &node(&[0xC0, 0x20])), Ordering::Less);
        assert_eq!(node_cmp(&[0xC0, 0x10], 0, &node(&[0xC0, 0x20])), Ordering::Less);
        // equal keys fall through to the record number, both ways
        assert_eq!(node_cmp_desc(&[0xC0], 5, &node(&[0xC0])), Ordering::Greater);
        assert_eq!(node_cmp_desc(&[0xC0], 0, &node(&[0xC0])), Ordering::Equal);
        // an empty key (a NULL) is the extreme case of a prefix
        assert_eq!(node_cmp_desc(&[], 0, &node(&[0xC0])), Ordering::Greater);
    }

    /// THE ENGINE'S OWN BYTES, read back off indexes it wrote itself -
    /// one value per database, `fcstat index-walk`. i64::MIN is filed
    /// under ZERO'S KEY, which is a defect in the engine (equality finds
    /// such a row, every RANGE misses it) and is nonetheless the address
    /// a shared file agrees on. Writing our own bytes there would make
    /// the row invisible to the engine's lookups.
    #[test]
    fn i64_min_is_keyed_where_the_engine_files_it() {
        let hex = |v: &[u8]| v.iter().map(|b| format!("{:02x}", b)).collect::<String>();
        let key = |n: i64| int64_key(n, 0).expect("every int64 has a key");
        assert_eq!(hex(&key(i64::MIN)), "800000000000000080");
        assert_eq!(hex(&key(0)), "800000000000000080");
        // its neighbour is NOT special - the collision is i64::MIN alone
        assert_eq!(hex(&key(-9223372036854775807)), "3cf5c91d14e3bcd76951");
        assert_eq!(hex(&key(1)), "bf1a36e2eb1c432d80");
        assert_eq!(hex(&key(-1)), "40e5c91d14e3bcd280");
        // zero's key carries no scale, so neither does this one
        assert_eq!(int64_key(i64::MIN, -2), int64_key(0, -2));
    }

    #[test]
    fn compound_keys_stuff_like_btr_key() {
        let seg = |itype, value, scale| KeySeg { itype, value, scale, charset: 0 };
        let ab = Value::Text("AB".into());
        let abcde = Value::Text("ABCDE".into());
        let one = Value::Int(1);
        // two short segments: marker(=segments remaining incl. current),
        // data, zero-pad to the group width, next marker, data
        let (k, n) = build_index_key(
            &[seg(IDX_STRING, &ab, 0), seg(IDX_NUMERIC, &one, 0)],
            false,
        )
        .unwrap();
        assert_eq!(k, vec![2, b'A', b'B', 0, 0, 1, 0xBF, 0xF0]);
        assert!(!n);
        // a segment longer than STUFF_COUNT repeats its marker per group
        let (k, _) = build_index_key(
            &[seg(IDX_STRING, &abcde, 0), seg(IDX_NUMERIC, &one, 0)],
            false,
        )
        .unwrap();
        assert_eq!(
            k,
            vec![2, b'A', b'B', b'C', b'D', 2, b'E', 0, 0, 0, 1, 0xBF, 0xF0]
        );
        // an ascending NULL segment contributes nothing - not even its
        // marker - and a PARTIAL-null key is NOT unique-exempt (the
        // engine only exempts all-NULL keys, btr.cpp:5629; the live
        // engine refused a duplicate (NULL,2) into UNIQUE(X,Y))
        let (k, n) = build_index_key(
            &[seg(IDX_STRING, &Value::Null, 0), seg(IDX_NUMERIC, &one, 0)],
            false,
        )
        .unwrap();
        assert_eq!(k, vec![1, 0xBF, 0xF0]);
        assert!(!n);
        // only every-segment-NULL flags the exemption
        let (k, n) = build_index_key(
            &[seg(IDX_STRING, &Value::Null, 0), seg(IDX_NUMERIC, &Value::Null, 0)],
            false,
        )
        .unwrap();
        assert_eq!(k, Vec::<u8>::new());
        assert!(n);
        // single segment: no stuffing at all
        let (k, _) = build_index_key(&[seg(IDX_STRING, &ab, 0)], false).unwrap();
        assert_eq!(k, b"AB".to_vec());
    }

    #[test]
    fn descending_keys_complement_like_btr() {
        let seg = |itype, value, scale| KeySeg { itype, value, scale, charset: 0 };
        let ab = Value::Text("AB".into());
        // single descending segment = complemented ascending bytes
        let (k, _) = build_index_key(&[seg(IDX_STRING, &ab, 0)], true).unwrap();
        assert_eq!(k, vec![!b'A', !b'B']);
        // descending NULL is one pre-complement 0x00 byte -> 0xFF
        let (k, n) = build_index_key(&[seg(IDX_STRING, &Value::Null, 0)], true).unwrap();
        assert_eq!(k, vec![0xFF]);
        assert!(n);
        // a value whose pre-complement image starts with 0x00/0x01 gets
        // the 0x01 end-value guard prepended before the complement
        // (btr.cpp:3978): a near-minimum double's munged bytes start 0x00
        let neg = Value::Double(-1.7e308);
        let asc = index_key(IDX_NUMERIC, &neg, 0, 0).unwrap();
        assert_eq!(asc[0], 0x00);
        let (k, _) = build_index_key(&[seg(IDX_NUMERIC, &neg, 0)], true).unwrap();
        assert_eq!(k[0], !0x01u8); // the guard byte, complemented
        assert_eq!(k[1..], asc.iter().map(|b| !b).collect::<Vec<u8>>()[..]);
        // compound descending: markers and pad complement too
        let one = Value::Int(1);
        let (k, _) = build_index_key(
            &[seg(IDX_STRING, &ab, 0), seg(IDX_NUMERIC, &one, 0)],
            true,
        )
        .unwrap();
        assert_eq!(
            k,
            vec![!2u8, !b'A', !b'B', !0u8, !0u8, !1u8, !0xBFu8, !0xF0u8]
        );
    }

    #[test]
    fn keys_encode_like_compress() {
        // NULL: no data
        assert_eq!(index_key(IDX_STRING, &Value::Null, 0, 0), Some(vec![]));
        // strings: trailing pads stripped, empty collapses to one pad
        assert_eq!(
            index_key(IDX_STRING, &Value::Text("abc  ".into()), 0, 0),
            Some(b"abc".to_vec())
        );
        assert_eq!(index_key(IDX_STRING, &Value::Text("".into()), 0, 0), Some(vec![b' ']));
        assert_eq!(index_key(IDX_STRING, &Value::Text("   ".into()), 0, 0), Some(vec![b' ']));
        // idx_numeric doubles: 1.0 -> BE 3FF0.. -> flip sign bit, chop
        assert_eq!(index_key(IDX_NUMERIC, &Value::Int(1), 0, 0), Some(vec![0xBF, 0xF0]));
        assert_eq!(index_key(IDX_NUMERIC, &Value::Int(0), 0, 0), Some(vec![0x80]));
        // negative: complement of BE(-1.0 = BFF0..) = 400F FF..FF chopped? no -
        // complement keeps FFs: ~BF=0x40, ~F0=0x0F, ~00=FF x6 -> no zero chop
        assert_eq!(
            index_key(IDX_NUMERIC, &Value::Int(-1), 0, 0),
            Some(vec![0x40, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        );
        // scaled: NUMERIC(9,2) raw 150 scale -2 = 1.5
        assert_eq!(
            index_key(IDX_NUMERIC, &Value::Scaled(150, -2), 0, 0),
            index_key(IDX_NUMERIC, &Value::Double(1.5), 0, 0)
        );
        // ordering sanity across the encoding
        let k = |v: i64| index_key(IDX_NUMERIC, &Value::Int(v), 0, 0).unwrap();
        assert!(k(-5) < k(-1));
        assert!(k(-1) < k(0));
        assert!(k(0) < k(1));
        assert!(k(1) < k(2));
        assert!(k(2) < k(100));
        // int64 keys order too, incl. the short part
        let k64 = |v: i64| index_key(IDX_NUMERIC2, &Value::Int(v), 0, 0).unwrap();
        assert!(k64(-2) < k64(-1));
        assert!(k64(-1) < k64(0));
        assert!(k64(0) < k64(1));
        assert!(k64(9999) < k64(10000));
        assert!(k64(10000) < k64(10001));
        // booleans
        assert_eq!(index_key(IDX_BOOLEAN, &Value::Bool(false), 0, 0), Some(vec![0x80]));
        assert_eq!(index_key(IDX_BOOLEAN, &Value::Bool(true), 0, 0), Some(vec![0x81]));
    }

    #[test]
    fn node_roundtrip_through_read_node() {
        // write_node's bytes must decode through the btn.h readNode port
        let mut out = Vec::new();
        write_node(&mut out, true, false, 3, b"suffix", 0x12345, 0);
        let n = read_node(&out, 0, true).unwrap();
        assert_eq!(n.prefix, 3);
        assert_eq!(n.length, 6);
        assert_eq!(n.record_number, 0x12345);
        assert!(!n.is_end_bucket && !n.is_end_level);
        assert_eq!(&out[n.data_at..n.next_at], b"suffix");
        // non-leaf with page number and the 0/1-length shortcuts
        let mut out = Vec::new();
        write_node(&mut out, false, false, 0, b"", 7, 0xABCD);
        let n = read_node(&out, 0, false).unwrap();
        assert_eq!((n.prefix, n.length, n.record_number, n.page_number), (0, 0, 7, 0xABCD));
        let mut out = Vec::new();
        write_node(&mut out, true, true, 2, b"x", 99, 0);
        let n = read_node(&out, 0, true).unwrap();
        assert!(n.is_end_bucket);
        assert_eq!((n.prefix, n.length, n.record_number), (2, 1, 99));
    }

    #[test]
    fn int128_bcd_keys_are_order_preserving() {
        // zero: no digits, just the folded exponent 2*(BIAS+1) = 258
        assert_eq!(int128_bcd_key(0, 0), vec![1, 2]);
        // equal VALUES at different declared scales share one key -
        // the normalization makeIndexKey performs (5 = 5.0 = 5.00)
        assert_eq!(int128_bcd_key(5, 0), int128_bcd_key(50, -1));
        assert_eq!(int128_bcd_key(5, 0), int128_bcd_key(500, -2));
        // strictly increasing values give strictly increasing keys
        // under the tree's unsigned byte compare - negatives (nine's
        // complement + negated exponent), scale boundaries, extremes
        let samples: [i128; 15] = [
            i128::MIN,
            -1_000_000_000_000_000_000_000_000_000_000,
            -5_000_000_000,
            -11,
            -10,
            -3,
            -1,
            0,
            1,
            2,
            9,
            10,
            5_000_000_000,
            1_000_000_000_000_000_000_000_000_000_000,
            i128::MAX,
        ];
        let keys: Vec<Vec<u8>> = samples.iter().map(|v| int128_bcd_key(*v, 0)).collect();
        for w in keys.windows(2) {
            assert!(w[0] < w[1], "{:?} !< {:?}", w[0], w[1]);
        }
        // never past the engine's 19-byte cap (getIndexKeyLength)
        for k in &keys {
            assert!(k.len() <= 19, "key too long: {}", k.len());
        }
    }
}
