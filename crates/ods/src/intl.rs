//! `intl` - the character-set half of a text descriptor.
//!
//! A text field's on-disk `Descriptor` carries its length in BYTES and
//! its character set in `sub_type`, and until this module existed
//! fire-crab read only the first of those. The comment it replaced said
//! so out loud - "byte length == character length here: charset NONE" -
//! and that assumption is false the moment a database is created
//! `DEFAULT CHARACTER SET UTF8`, which is the ordinary case.
//!
//! What it cost, measured against the live engine on a UTF8 database
//! (`CHAR(5)` = 20 bytes on disk):
//!
//!   * `SELECT C5` returned TWENTY characters where the engine returns
//!     five - `'abc'` came back as `"abc"` plus seventeen blanks. So did
//!     `OCTET_LENGTH` and `CHAR_LENGTH`, which answered 20 and 20 against
//!     the engine's 5 and 5. Every `CHAR` value in a UTF8 database was
//!     wrong on the wire, including values the ENGINE had written.
//!   * a `VARCHAR(10)` parameter of eleven characters was ACCEPTED,
//!     because eleven bytes fit in forty. The engine refuses it. The row
//!     fire-crab then wrote could not be read back by the engine at all:
//!     `SELECT` through isql failed with *string right truncation,
//!     expected length 10, actual 19*. That is the corruption direction,
//!     and it is why this module exists.
//!
//! The layout is `ttype`: the character set in the low byte, the
//! collation in the high byte. Probed, not assumed - a `CHAR(5)
//! CHARACTER SET UTF8 COLLATE UNICODE_CI` field's descriptor reads
//! `sub_type = 772 = 0x0304`, charset 4 and collation 3; a `WIN1252
//! COLLATE PXW_INTL` one reads `309 = 0x0135`, charset 53 collation 1.
//!
//! The bytes-per-character table below is the engine's own, read out of
//! `RDB$CHARACTER_SETS.RDB$BYTES_PER_CHARACTER` on a live Firebird 6
//! database. It is a CLAIM about the engine, so - like every other claim
//! here - a gate checks it: `qa/serve-real-charset.sh` compares this
//! table against that catalogue row by row, and fails if the engine ever
//! disagrees.
//!
//! ~~Deliberately NOT here: transliteration.~~ The codepage tables ARE
//! here now (`decode_text`/`encode_text`, WIN1252 and ISO8859_1,
//! bijective on all 256 bytes): a stored 0xE9 decodes to 'é' instead of
//! the lossy replacement character that DESTROYED the value, the store
//! path writes the codepage's bytes (the bytes the engine writes and
//! reads), index keys carry them (`KeySeg::charset`), and the wire
//! encode re-spells a value into a single-byte attachment's codepage.
//! An unmappable character refuses where the engine raises SQLSTATE
//! 22018. Gated by `qa/serve-real-xlit.sh` against live twins. Sets
//! with no table here (the DOS codepages, the CJK multibyte sets) keep
//! the pre-table lossy read - `decode_text` answers `None` and every
//! caller falls back - so adding one is one table, not a new seam.

/// The character set id from a text descriptor's `sub_type` (ttype).
pub fn charset_id(sub_type: i16) -> u8 {
    (sub_type as u16 & 0xFF) as u8
}

/// The collation id from a text descriptor's `sub_type` (ttype).
pub fn collation_id(sub_type: i16) -> u8 {
    ((sub_type as u16 >> 8) & 0xFF) as u8
}

/// `CHARACTER SET OCTETS` - binary bytes, never text. The engine
/// refuses to transliterate it and clients hand it back as a buffer.
pub const CS_OCTETS: u8 = 1;
/// `CHARACTER SET NONE` - bytes with no declared meaning, one per
/// character.
pub const CS_NONE: u8 = 0;
/// `CHARACTER SET UTF8`, four bytes per character.
pub const CS_UTF8: u8 = 4;

/// Maximum bytes per character, by character set id.
///
/// `RDB$CHARACTER_SETS.RDB$BYTES_PER_CHARACTER`, verbatim. An id the
/// engine does not ship - a reserved gap, or a user-defined set from an
/// external module - is taken as single-byte, which is what fire-crab
/// did for EVERY set before this module and so cannot be a regression.
pub fn bytes_per_char(charset: u8) -> u8 {
    match charset {
        3 => 3,              // UNICODE_FSS
        4 => 4,              // UTF8
        69 => 4,             // GB18030
        5 | 6 => 2,          // SJIS_0208, EUCJ_0208
        44 => 2,             // KSC_5601
        56 | 57 => 2,        // BIG_5, GB_2312
        67 | 68 => 2,        // GBK, CP943C
        _ => 1,
    }
}

/// The declared CHARACTER length of a text field: what `CHAR(5)` and
/// `VARCHAR(10)` mean, as opposed to the twenty and forty bytes they
/// occupy in UTF8.
///
/// `dtype::VARYING`'s on-disk length includes the two-byte count word,
/// which is not part of the text and is not divided.
pub fn char_length(dtype: u8, length: u16, sub_type: i16) -> usize {
    let bytes = match dtype {
        crate::format::dtype::VARYING => (length as usize).saturating_sub(2),
        _ => length as usize,
    };
    bytes / bytes_per_char(charset_id(sub_type)) as usize
}

/// Cut a decoded `CHAR` value down to its declared character count, and
/// blank-pad it back up if the image was short.
///
/// A `CHAR` is stored blank-padded to its full BYTE length, so a
/// three-character value in a UTF8 `CHAR(5)` occupies twenty bytes and
/// decodes to twenty characters. The engine hands back five. Taking the
/// first `char_len` characters gives exactly that, for narrow content
/// and wide alike: `'abc'` -> `"abc  "`, `'ä'` -> `"ä    "`, `'äbcde'`
/// -> `"äbcde"` - each five characters, each what the engine returned
/// when asked.
pub fn fit_char(text: &str, char_len: usize) -> String {
    // ONE pass, not two. The old form collected the first `char_len`
    // characters and then walked the result AGAIN to count them; the
    // count is known as we take. `char_len` bytes is the right capacity
    // for single-byte content (the common case) and a lower bound for
    // wide, which reallocates at most a handful of times.
    let mut out = String::with_capacity(char_len);
    let mut have = 0;
    for c in text.chars() {
        if have == char_len {
            break;
        }
        out.push(c);
        have += 1;
    }
    for _ in have..char_len {
        out.push(' ');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::dtype;

    #[test]
    fn ttype_splits_into_charset_and_collation() {
        // probed on a live database, CHAR(5) CHARACTER SET UTF8
        // COLLATE UNICODE_CI and CHAR(5) WIN1252 COLLATE PXW_INTL
        assert_eq!(charset_id(772), 4);
        assert_eq!(collation_id(772), 3);
        assert_eq!(charset_id(309), 53);
        assert_eq!(collation_id(309), 1);
        // the plain cases: no collation, so the high byte is clear
        assert_eq!(charset_id(4), CS_UTF8);
        assert_eq!(collation_id(4), 0);
        assert_eq!(charset_id(0), CS_NONE);
        assert_eq!(charset_id(1), CS_OCTETS);
    }

    #[test]
    fn char_length_divides_by_the_set_s_width() {
        // the descriptors read off the probe database, field by field
        assert_eq!(char_length(dtype::TEXT, 20, 4), 5); // CHAR(5) UTF8
        assert_eq!(char_length(dtype::VARYING, 42, 4), 10); // VARCHAR(10) UTF8
        assert_eq!(char_length(dtype::TEXT, 5, 0), 5); // CHAR(5) NONE
        assert_eq!(char_length(dtype::TEXT, 5, 53), 5); // CHAR(5) WIN1252
        assert_eq!(char_length(dtype::TEXT, 5, 1), 5); // CHAR(5) OCTETS
        assert_eq!(char_length(dtype::TEXT, 15, 3), 5); // CHAR(5) UNICODE_FSS
        // a collation in the high byte must not change the width
        assert_eq!(char_length(dtype::TEXT, 20, 772), 5);
        assert_eq!(char_length(dtype::TEXT, 5, 309), 5);
    }

    #[test]
    fn fit_char_matches_what_the_engine_returned() {
        assert_eq!(fit_char("abc                 ", 5), "abc  ");
        assert_eq!(fit_char("ä                  ", 5), "ä    ");
        assert_eq!(fit_char("äbcde              ", 5), "äbcde");
        assert_eq!(fit_char("äääää          ", 5), "äääää");
        // a short image is padded rather than shortened
        assert_eq!(fit_char("ab", 5), "ab   ");
        assert_eq!(fit_char("", 5), "     ");
    }

    #[test]
    fn unknown_ids_stay_single_byte() {
        // a reserved gap, and a plausible user-defined id
        assert_eq!(bytes_per_char(7), 1);
        assert_eq!(bytes_per_char(200), 1);
        // ... while the wide ones the engine ships are known
        assert_eq!(bytes_per_char(4), 4);
        assert_eq!(bytes_per_char(69), 4);
        assert_eq!(bytes_per_char(3), 3);
        assert_eq!(bytes_per_char(56), 2);
    }
}

/// `CHARACTER SET ISO8859_1` - Latin-1, identity to U+00..U+FF.
pub const CS_ISO8859_1: u8 = 21;
/// `CHARACTER SET WIN1252` - Latin-1 with the 0x80..0x9F row remapped.
pub const CS_WIN1252: u8 = 53;

/// The WIN1252 0x80..0x9F row: Microsoft's cp1252 assignments, with the
/// five unassigned bytes (0x81, 0x8D, 0x8F, 0x90, 0x9D) kept at their
/// C1 control points - which is what makes the mapping a BIJECTION on
/// all 256 bytes, so a decode/encode round trip reproduces the stored
/// bytes exactly (the NONE-attachment read path depends on that).
const WIN1252_HIGH: [char; 32] = [
    '\u{20AC}', '\u{0081}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}',
    '\u{2020}', '\u{2021}', '\u{02C6}', '\u{2030}', '\u{0160}', '\u{2039}',
    '\u{0152}', '\u{008D}', '\u{017D}', '\u{008F}', '\u{0090}', '\u{2018}',
    '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{02DC}', '\u{2122}', '\u{0161}', '\u{203A}', '\u{0153}', '\u{009D}',
    '\u{017E}', '\u{0178}',
];

/// Decode one byte of a TABLED single-byte character set, or `None` when
/// the set is not tabled here (multibyte, NONE/OCTETS/ASCII, or a set no
/// table was written for - the caller keeps its previous behaviour).
fn single_byte_char(charset: u8, b: u8) -> Option<char> {
    match charset {
        CS_ISO8859_1 => Some(b as char),
        CS_WIN1252 => Some(if (0x80..=0x9F).contains(&b) {
            WIN1252_HIGH[(b - 0x80) as usize]
        } else {
            b as char
        }),
        _ => None,
    }
}

/// Encode one character into a TABLED single-byte character set.
/// `Ok(None)` = the set is not tabled; `Err(())` = the character has no
/// image there (the engine's *Cannot transliterate character between
/// character sets*, SQLSTATE 22018).
fn single_byte_of(charset: u8, c: char) -> Result<Option<u8>, ()> {
    match charset {
        CS_ISO8859_1 => match u32::from(c) {
            v @ 0..=0xFF => Ok(Some(v as u8)),
            _ => Err(()),
        },
        CS_WIN1252 => {
            let v = u32::from(c);
            if (0x80..=0x9F).contains(&v) || v > 0xFF {
                match WIN1252_HIGH.iter().position(|&h| h == c) {
                    Some(i) => Ok(Some(0x80 + i as u8)),
                    None => Err(()),
                }
            } else {
                Ok(Some(v as u8))
            }
        }
        _ => Ok(None),
    }
}

/// Is this character set one the codepage tables here can convert?
pub fn tabled(charset: u8) -> bool {
    matches!(charset, CS_ISO8859_1 | CS_WIN1252)
}

/// Decode a TABLED single-byte column's stored bytes into text, or
/// `None` when the set is not tabled (the caller keeps its lossy-UTF8
/// reading, the pre-table behaviour).
pub fn decode_text(charset: u8, bytes: &[u8]) -> Option<String> {
    if !tabled(charset) {
        return None;
    }
    Some(bytes.iter().map(|&b| single_byte_char(charset, b).unwrap()).collect())
}

/// Encode text into a TABLED single-byte character set. `Ok(None)` = the
/// set is not tabled (caller stores UTF-8 bytes as before); `Err(c)` =
/// `c` has no image in the set - the engine raises SQLSTATE 22018,
/// *Cannot transliterate character between character sets*.
pub fn encode_text(charset: u8, s: &str) -> Result<Option<Vec<u8>>, char> {
    if !tabled(charset) {
        return Ok(None);
    }
    let mut out = Vec::with_capacity(s.len());
    for c in s.chars() {
        match single_byte_of(charset, c) {
            Ok(Some(b)) => out.push(b),
            Ok(None) => unreachable!("tabled() gated"),
            Err(()) => return Err(c),
        }
    }
    Ok(Some(out))
}

#[cfg(test)]
mod xlit_tests {
    use super::*;

    #[test]
    fn win1252_round_trips_all_256_bytes() {
        for b in 0..=255u8 {
            let c = single_byte_char(CS_WIN1252, b).unwrap();
            assert_eq!(single_byte_of(CS_WIN1252, c), Ok(Some(b)), "byte {b:#x}");
        }
        // the marquee mappings, spot-checked against cp1252
        assert_eq!(single_byte_char(CS_WIN1252, 0x80), Some('\u{20AC}')); // euro
        assert_eq!(single_byte_char(CS_WIN1252, 0xE9), Some('é'));
        assert_eq!(single_byte_of(CS_WIN1252, '€'), Ok(Some(0x80)));
        assert_eq!(single_byte_of(CS_WIN1252, '₹'), Err(())); // unmappable
    }

    #[test]
    fn iso8859_1_is_the_identity() {
        assert_eq!(decode_text(CS_ISO8859_1, &[0x61, 0xE9]), Some("aé".into()));
        assert_eq!(encode_text(CS_ISO8859_1, "aé"), Ok(Some(vec![0x61, 0xE9])));
        assert_eq!(encode_text(CS_ISO8859_1, "€"), Err('€'));
    }

    #[test]
    fn untabled_sets_answer_none() {
        assert_eq!(decode_text(CS_UTF8, b"ab"), None);
        assert_eq!(decode_text(CS_NONE, b"ab"), None);
        assert_eq!(encode_text(CS_UTF8, "ab"), Ok(None));
    }
}
