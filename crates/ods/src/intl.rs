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
//! Deliberately NOT here: transliteration. The engine converts a
//! WIN1252 column's bytes into the connection's character set on the way
//! out; fire-crab passes the stored bytes through. For ASCII content
//! - which is what every fixture and every gate uses - the two are
//! identical, and for a high byte they are not. That is a codepage-table
//! job, it is recorded in the roadmap, and this module does not pretend
//! to do it.

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
    let mut out: String = text.chars().take(char_len).collect();
    let have = out.chars().count();
    if have < char_len {
        out.extend(std::iter::repeat(' ').take(char_len - have));
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
