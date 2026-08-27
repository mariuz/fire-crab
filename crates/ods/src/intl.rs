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
//! here now (`decode_text`/`encode_text` - WIN1252, ISO8859_1, WIN1250,
//! WIN1251 and ISO8859_2, each bijective on all 256 bytes, the last
//! three GENERATED from the live engine's own transliteration rather
//! than typed from a chart): a stored 0xE9 decodes to 'é' instead of
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
/// `CHARACTER SET ISO8859_2` - Latin-2 (Central European).
pub const CS_ISO8859_2: u8 = 22;
/// `CHARACTER SET WIN1250` - Central European (cp1250).
pub const CS_WIN1250: u8 = 51;
/// `CHARACTER SET WIN1251` - Cyrillic (cp1251).
pub const CS_WIN1251: u8 = 52;

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

/// The three tables below cover the FULL high half (0x80..0xFF, 128
/// entries) because unlike WIN1252 their letters diverge from Latin-1
/// above 0xA0 too. They were GENERATED from the live engine, not typed
/// from a codepage chart: 128 one-byte rows per set inserted as hex
/// literals through a NONE attachment, read back as `UNICODE_VAL(S)`
/// through a UTF8 one - the engine's own transliteration is the table.
///
/// The engine maps a codepage HOLE (a byte Microsoft never assigned:
/// WIN1250's 0x81/0x83/0x88/0x90/0x98, WIN1251's 0x98, WIN1252's five)
/// to U+0000 when TRANSLITERATING, and refuses the reverse direction
/// (storing U+0081 raises 22018) - both measured. Here a hole keeps its
/// C1 control point instead, the WIN1252 precedent: that keeps each
/// table a BIJECTION on 256 bytes, which the NONE-attachment read path
/// depends on (the engine passes raw bytes through unconverted there,
/// and so does the round trip). The cost is a divergence confined to
/// undefined bytes crossing charsets - recorded, not gated.
/// ISO8859_2 has NO holes: its 0x80..0x9F row is identity C1, measured.
const WIN1250_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0081}', '\u{201A}', '\u{0083}', '\u{201E}', '\u{2026}',
    '\u{2020}', '\u{2021}', '\u{0088}', '\u{2030}', '\u{0160}', '\u{2039}',
    '\u{015A}', '\u{0164}', '\u{017D}', '\u{0179}', '\u{0090}', '\u{2018}',
    '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0098}', '\u{2122}', '\u{0161}', '\u{203A}', '\u{015B}', '\u{0165}',
    '\u{017E}', '\u{017A}', '\u{00A0}', '\u{02C7}', '\u{02D8}', '\u{0141}',
    '\u{00A4}', '\u{0104}', '\u{00A6}', '\u{00A7}', '\u{00A8}', '\u{00A9}',
    '\u{015E}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{017B}',
    '\u{00B0}', '\u{00B1}', '\u{02DB}', '\u{0142}', '\u{00B4}', '\u{00B5}',
    '\u{00B6}', '\u{00B7}', '\u{00B8}', '\u{0105}', '\u{015F}', '\u{00BB}',
    '\u{013D}', '\u{02DD}', '\u{013E}', '\u{017C}', '\u{0154}', '\u{00C1}',
    '\u{00C2}', '\u{0102}', '\u{00C4}', '\u{0139}', '\u{0106}', '\u{00C7}',
    '\u{010C}', '\u{00C9}', '\u{0118}', '\u{00CB}', '\u{011A}', '\u{00CD}',
    '\u{00CE}', '\u{010E}', '\u{0110}', '\u{0143}', '\u{0147}', '\u{00D3}',
    '\u{00D4}', '\u{0150}', '\u{00D6}', '\u{00D7}', '\u{0158}', '\u{016E}',
    '\u{00DA}', '\u{0170}', '\u{00DC}', '\u{00DD}', '\u{0162}', '\u{00DF}',
    '\u{0155}', '\u{00E1}', '\u{00E2}', '\u{0103}', '\u{00E4}', '\u{013A}',
    '\u{0107}', '\u{00E7}', '\u{010D}', '\u{00E9}', '\u{0119}', '\u{00EB}',
    '\u{011B}', '\u{00ED}', '\u{00EE}', '\u{010F}', '\u{0111}', '\u{0144}',
    '\u{0148}', '\u{00F3}', '\u{00F4}', '\u{0151}', '\u{00F6}', '\u{00F7}',
    '\u{0159}', '\u{016F}', '\u{00FA}', '\u{0171}', '\u{00FC}', '\u{00FD}',
    '\u{0163}', '\u{02D9}',
];

const WIN1251_HIGH: [char; 128] = [
    '\u{0402}', '\u{0403}', '\u{201A}', '\u{0453}', '\u{201E}', '\u{2026}',
    '\u{2020}', '\u{2021}', '\u{20AC}', '\u{2030}', '\u{0409}', '\u{2039}',
    '\u{040A}', '\u{040C}', '\u{040B}', '\u{040F}', '\u{0452}', '\u{2018}',
    '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0098}', '\u{2122}', '\u{0459}', '\u{203A}', '\u{045A}', '\u{045C}',
    '\u{045B}', '\u{045F}', '\u{00A0}', '\u{040E}', '\u{045E}', '\u{0408}',
    '\u{00A4}', '\u{0490}', '\u{00A6}', '\u{00A7}', '\u{0401}', '\u{00A9}',
    '\u{0404}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{0407}',
    '\u{00B0}', '\u{00B1}', '\u{0406}', '\u{0456}', '\u{0491}', '\u{00B5}',
    '\u{00B6}', '\u{00B7}', '\u{0451}', '\u{2116}', '\u{0454}', '\u{00BB}',
    '\u{0458}', '\u{0405}', '\u{0455}', '\u{0457}', '\u{0410}', '\u{0411}',
    '\u{0412}', '\u{0413}', '\u{0414}', '\u{0415}', '\u{0416}', '\u{0417}',
    '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}',
    '\u{041E}', '\u{041F}', '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}',
    '\u{0424}', '\u{0425}', '\u{0426}', '\u{0427}', '\u{0428}', '\u{0429}',
    '\u{042A}', '\u{042B}', '\u{042C}', '\u{042D}', '\u{042E}', '\u{042F}',
    '\u{0430}', '\u{0431}', '\u{0432}', '\u{0433}', '\u{0434}', '\u{0435}',
    '\u{0436}', '\u{0437}', '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}',
    '\u{043C}', '\u{043D}', '\u{043E}', '\u{043F}', '\u{0440}', '\u{0441}',
    '\u{0442}', '\u{0443}', '\u{0444}', '\u{0445}', '\u{0446}', '\u{0447}',
    '\u{0448}', '\u{0449}', '\u{044A}', '\u{044B}', '\u{044C}', '\u{044D}',
    '\u{044E}', '\u{044F}',
];

const ISO8859_2_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}',
    '\u{0086}', '\u{0087}', '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}',
    '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}', '\u{0090}', '\u{0091}',
    '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}',
    '\u{009E}', '\u{009F}', '\u{00A0}', '\u{0104}', '\u{02D8}', '\u{0141}',
    '\u{00A4}', '\u{013D}', '\u{015A}', '\u{00A7}', '\u{00A8}', '\u{0160}',
    '\u{015E}', '\u{0164}', '\u{0179}', '\u{00AD}', '\u{017D}', '\u{017B}',
    '\u{00B0}', '\u{0105}', '\u{02DB}', '\u{0142}', '\u{00B4}', '\u{013E}',
    '\u{015B}', '\u{02C7}', '\u{00B8}', '\u{0161}', '\u{015F}', '\u{0165}',
    '\u{017A}', '\u{02DD}', '\u{017E}', '\u{017C}', '\u{0154}', '\u{00C1}',
    '\u{00C2}', '\u{0102}', '\u{00C4}', '\u{0139}', '\u{0106}', '\u{00C7}',
    '\u{010C}', '\u{00C9}', '\u{0118}', '\u{00CB}', '\u{011A}', '\u{00CD}',
    '\u{00CE}', '\u{010E}', '\u{0110}', '\u{0143}', '\u{0147}', '\u{00D3}',
    '\u{00D4}', '\u{0150}', '\u{00D6}', '\u{00D7}', '\u{0158}', '\u{016E}',
    '\u{00DA}', '\u{0170}', '\u{00DC}', '\u{00DD}', '\u{0162}', '\u{00DF}',
    '\u{0155}', '\u{00E1}', '\u{00E2}', '\u{0103}', '\u{00E4}', '\u{013A}',
    '\u{0107}', '\u{00E7}', '\u{010D}', '\u{00E9}', '\u{0119}', '\u{00EB}',
    '\u{011B}', '\u{00ED}', '\u{00EE}', '\u{010F}', '\u{0111}', '\u{0144}',
    '\u{0148}', '\u{00F3}', '\u{00F4}', '\u{0151}', '\u{00F6}', '\u{00F7}',
    '\u{0159}', '\u{016F}', '\u{00FA}', '\u{0171}', '\u{00FC}', '\u{00FD}',
    '\u{0163}', '\u{02D9}',
];

/// The full-high-half table for a set that has one.
fn high_table(charset: u8) -> Option<&'static [char; 128]> {
    match charset {
        CS_WIN1250 => Some(&WIN1250_HIGH),
        CS_WIN1251 => Some(&WIN1251_HIGH),
        CS_ISO8859_2 => Some(&ISO8859_2_HIGH),
        _ => None,
    }
}

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
        _ => match high_table(charset) {
            Some(t) if b >= 0x80 => Some(t[(b - 0x80) as usize]),
            Some(_) => Some(b as char),
            None => None,
        },
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
        _ => match high_table(charset) {
            Some(t) => {
                if u32::from(c) < 0x80 {
                    Ok(Some(u32::from(c) as u8))
                } else {
                    match t.iter().position(|&h| h == c) {
                        Some(i) => Ok(Some(0x80 + i as u8)),
                        None => Err(()),
                    }
                }
            }
            None => Ok(None),
        },
    }
}

/// Is this character set one the codepage tables here can convert?
pub fn tabled(charset: u8) -> bool {
    matches!(
        charset,
        CS_ISO8859_1 | CS_WIN1252 | CS_ISO8859_2 | CS_WIN1250 | CS_WIN1251
    )
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
    fn the_generated_tables_round_trip_all_256_bytes() {
        for cs in [CS_WIN1250, CS_WIN1251, CS_ISO8859_2] {
            for b in 0..=255u8 {
                let c = single_byte_char(cs, b).unwrap();
                assert_eq!(single_byte_of(cs, c), Ok(Some(b)), "cs {cs} byte {b:#x}");
            }
        }
        // the marquee letters, each read off the live engine
        assert_eq!(single_byte_char(CS_WIN1250, 0xF8), Some('ř'));
        assert_eq!(single_byte_char(CS_WIN1250, 0xB9), Some('ą'));
        assert_eq!(single_byte_char(CS_WIN1251, 0xE9), Some('й'));
        assert_eq!(single_byte_char(CS_WIN1251, 0xB9), Some('№'));
        assert_eq!(single_byte_char(CS_WIN1251, 0x88), Some('€'));
        assert_eq!(single_byte_char(CS_ISO8859_2, 0xB9), Some('š'));
        assert_eq!(single_byte_of(CS_WIN1251, 'ш'), Ok(Some(0xF8)));
        assert_eq!(single_byte_of(CS_ISO8859_2, 'Ł'), Ok(Some(0xA3)));
        // no Cyrillic in Latin-2, no Latin-2 in cp1251: 22018 territory
        assert_eq!(single_byte_of(CS_ISO8859_2, 'ж'), Err(()));
        assert_eq!(single_byte_of(CS_WIN1251, 'ř'), Err(()));
        assert_eq!(encode_text(CS_WIN1250, "řeka"), Ok(Some(vec![0xF8, 0x65, 0x6B, 0x61])));
        assert_eq!(decode_text(CS_WIN1251, &[0xF0, 0xE5, 0xEA, 0xE0]), Some("река".into()));
    }

    #[test]
    fn untabled_sets_answer_none() {
        assert_eq!(decode_text(CS_UTF8, b"ab"), None);
        assert_eq!(decode_text(CS_NONE, b"ab"), None);
        assert_eq!(encode_text(CS_UTF8, "ab"), Ok(None));
    }
}

/// `CHARACTER SET ASCII`.
pub const CS_ASCII: u8 = 2;

/// Is this a BYTE-CARRIER set - NONE, OCTETS or ASCII? Their values
/// have no character semantics beyond the byte, the engine never
/// transliterates them (a stored 0xE9 travels 0xE9 to a UTF8 attachment,
/// measured), and CHAR_LENGTH counts their BYTES. Inside fire-crab such
/// a value is carried as one char per byte (U+0000..U+00FF - the
/// Latin-1 carrier), which round-trips every byte losslessly where the
/// old lossy-UTF8 read destroyed the high ones.
pub fn byte_carrier(charset: u8) -> bool {
    matches!(charset, CS_NONE | CS_OCTETS | CS_ASCII)
}

/// The character set's PAD BYTE - what a CHAR slot is filled to its
/// declared length with, and what a comparison pads the shorter side
/// with. Every set's is the blank except OCTETS, whose "space" is a
/// single ZERO byte (`CharSet::getSpace` over the binary charset): a
/// `CHAR(4) CHARACTER SET OCTETS` holding `x'6162'` reads back
/// `61620000`, and `x'4100' = 'A'` is TRUE where `x'4120' = 'A'` is
/// FALSE - both measured against the engine.
pub fn pad_byte(charset: u8) -> u8 {
    if charset == CS_OCTETS {
        0
    } else {
        b' '
    }
}

/// Decode a byte-carrier value: one char per byte.
pub fn carrier_decode(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

/// Re-spell text into a byte-carrier's bytes. `None` when a char is
/// past U+00FF - text that never came from a carrier decode; the caller
/// falls back to its UTF-8 bytes (the engine's own rule for a value
/// ARRIVING at a NONE column: the client's bytes are stored verbatim).
pub fn carrier_encode(s: &str) -> Option<Vec<u8>> {
    s.chars()
        .map(|c| u8::try_from(u32::from(c)).ok())
        .collect()
}

/// Lift REAL text (a literal, a parameter - UTF-8 semantics) into the
/// carrier: the char-per-byte spelling of its UTF-8 bytes. This is what
/// the engine does with a value arriving at a NONE column or compared
/// against one - the bytes are the value.
pub fn to_carrier(s: &str) -> String {
    carrier_decode(s.as_bytes())
}

#[cfg(test)]
mod carrier_tests {
    use super::*;

    #[test]
    fn the_carrier_round_trips_every_byte() {
        let all: Vec<u8> = (0..=255u8).collect();
        assert_eq!(carrier_encode(&carrier_decode(&all)).unwrap(), all);
        // ASCII is the identity in and out
        assert_eq!(carrier_decode(b"plain"), "plain");
        assert_eq!(to_carrier("plain"), "plain");
        // a real 'é' lifts to its two UTF-8 bytes
        assert_eq!(to_carrier("é"), "\u{c3}\u{a9}");
        // and a non-Latin-1 char refuses the byte spelling
        assert_eq!(carrier_encode("₹"), None);
    }
}

/// The engine raises 22018 for this case mapping: the cased character
/// has no image in the set. Exactly ONE cell across all five tables -
/// WIN1252 0x83 'ƒ' UPPER ('Ƒ' is not in cp1252; its LOWER is itself,
/// both probed live). U+FFFF is a noncharacter no codepage maps to.
const CASE_ERR: char = '\u{FFFF}';

const WIN1250_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'),
    ('\u{0000}', '\u{0000}'), ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'),
    ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'), ('\u{0000}', '\u{0000}'),
    ('\u{2030}', '\u{2030}'), ('\u{0160}', '\u{0161}'), ('\u{2039}', '\u{2039}'),
    ('\u{015A}', '\u{015B}'), ('\u{0164}', '\u{0165}'), ('\u{017D}', '\u{017E}'),
    ('\u{0179}', '\u{017A}'), ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'),
    ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'), ('\u{201D}', '\u{201D}'),
    ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0000}', '\u{0000}'), ('\u{2122}', '\u{2122}'), ('\u{0160}', '\u{0161}'),
    ('\u{203A}', '\u{203A}'), ('\u{015A}', '\u{015B}'), ('\u{0164}', '\u{0165}'),
    ('\u{017D}', '\u{017E}'), ('\u{0179}', '\u{017A}'), ('\u{00A0}', '\u{00A0}'),
    ('\u{02C7}', '\u{02C7}'), ('\u{02D8}', '\u{02D8}'), ('\u{0141}', '\u{0142}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0104}', '\u{0105}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00A7}', '\u{00A7}'), ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{015E}', '\u{015F}'), ('\u{00AB}', '\u{00AB}'), ('\u{00AC}', '\u{00AC}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{017B}', '\u{017C}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{02DB}', '\u{02DB}'),
    ('\u{0141}', '\u{0142}'), ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{0104}', '\u{0105}'), ('\u{015E}', '\u{015F}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{013D}', '\u{013E}'), ('\u{02DD}', '\u{02DD}'), ('\u{013D}', '\u{013E}'),
    ('\u{017B}', '\u{017C}'), ('\u{0154}', '\u{0155}'), ('\u{00C1}', '\u{00E1}'),
    ('\u{00C2}', '\u{00E2}'), ('\u{0102}', '\u{0103}'), ('\u{00C4}', '\u{00E4}'),
    ('\u{0139}', '\u{013A}'), ('\u{0106}', '\u{0107}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'),
    ('\u{00CB}', '\u{00EB}'), ('\u{011A}', '\u{011B}'), ('\u{00CD}', '\u{00ED}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{010E}', '\u{010F}'), ('\u{0110}', '\u{0111}'),
    ('\u{0143}', '\u{0144}'), ('\u{0147}', '\u{0148}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{0150}', '\u{0151}'), ('\u{00D6}', '\u{00F6}'),
    ('\u{00D7}', '\u{00D7}'), ('\u{0158}', '\u{0159}'), ('\u{016E}', '\u{016F}'),
    ('\u{00DA}', '\u{00FA}'), ('\u{0170}', '\u{0171}'), ('\u{00DC}', '\u{00FC}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{0162}', '\u{0163}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{0154}', '\u{0155}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{0102}', '\u{0103}'), ('\u{00C4}', '\u{00E4}'), ('\u{0139}', '\u{013A}'),
    ('\u{0106}', '\u{0107}'), ('\u{00C7}', '\u{00E7}'), ('\u{010C}', '\u{010D}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{011A}', '\u{011B}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{010E}', '\u{010F}'), ('\u{0110}', '\u{0111}'), ('\u{0143}', '\u{0144}'),
    ('\u{0147}', '\u{0148}'), ('\u{00D3}', '\u{00F3}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{0150}', '\u{0151}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{0158}', '\u{0159}'), ('\u{016E}', '\u{016F}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{0170}', '\u{0171}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{0162}', '\u{0163}'), ('\u{02D9}', '\u{02D9}'),
];

const WIN1251_CASE: [(char, char); 128] = [
    ('\u{0402}', '\u{0452}'), ('\u{0403}', '\u{0453}'), ('\u{201A}', '\u{201A}'),
    ('\u{0403}', '\u{0453}'), ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'),
    ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'), ('\u{20AC}', '\u{20AC}'),
    ('\u{2030}', '\u{2030}'), ('\u{0409}', '\u{0459}'), ('\u{2039}', '\u{2039}'),
    ('\u{040A}', '\u{045A}'), ('\u{040C}', '\u{045C}'), ('\u{040B}', '\u{045B}'),
    ('\u{040F}', '\u{045F}'), ('\u{0402}', '\u{0452}'), ('\u{2018}', '\u{2018}'),
    ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'), ('\u{201D}', '\u{201D}'),
    ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0000}', '\u{0000}'), ('\u{2122}', '\u{2122}'), ('\u{0409}', '\u{0459}'),
    ('\u{203A}', '\u{203A}'), ('\u{040A}', '\u{045A}'), ('\u{040C}', '\u{045C}'),
    ('\u{040B}', '\u{045B}'), ('\u{040F}', '\u{045F}'), ('\u{00A0}', '\u{00A0}'),
    ('\u{040E}', '\u{045E}'), ('\u{040E}', '\u{045E}'), ('\u{0408}', '\u{0458}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0490}', '\u{0491}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00A7}', '\u{00A7}'), ('\u{0401}', '\u{0451}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{0404}', '\u{0454}'), ('\u{00AB}', '\u{00AB}'), ('\u{00AC}', '\u{00AC}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{0407}', '\u{0457}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{0406}', '\u{0456}'),
    ('\u{0406}', '\u{0456}'), ('\u{0490}', '\u{0491}'), ('\u{00B5}', '\u{00B5}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'), ('\u{0401}', '\u{0451}'),
    ('\u{2116}', '\u{2116}'), ('\u{0404}', '\u{0454}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{0408}', '\u{0458}'), ('\u{0405}', '\u{0455}'), ('\u{0405}', '\u{0455}'),
    ('\u{0407}', '\u{0457}'), ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'),
    ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'), ('\u{0414}', '\u{0434}'),
    ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'),
    ('\u{041B}', '\u{043B}'), ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'),
    ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'), ('\u{0420}', '\u{0440}'),
    ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'),
    ('\u{0427}', '\u{0447}'), ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'),
    ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'), ('\u{042C}', '\u{044C}'),
    ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'),
    ('\u{0413}', '\u{0433}'), ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'),
    ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'), ('\u{0418}', '\u{0438}'),
    ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'),
    ('\u{041F}', '\u{043F}'), ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'),
    ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'), ('\u{0424}', '\u{0444}'),
    ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'),
    ('\u{042B}', '\u{044B}'), ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'),
    ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
];

const WIN1252_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'),
    (CASE_ERR, '\u{0192}'), ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'),
    ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'), ('\u{02C6}', '\u{02C6}'),
    ('\u{2030}', '\u{2030}'), ('\u{0160}', '\u{0161}'), ('\u{2039}', '\u{2039}'),
    ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'), ('\u{017D}', '\u{017E}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'),
    ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'), ('\u{201D}', '\u{201D}'),
    ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{02DC}', '\u{02DC}'), ('\u{2122}', '\u{2122}'), ('\u{0160}', '\u{0161}'),
    ('\u{203A}', '\u{203A}'), ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'),
    ('\u{017D}', '\u{017E}'), ('\u{0178}', '\u{00FF}'), ('\u{00A0}', '\u{00A0}'),
    ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00A7}', '\u{00A7}'), ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{00AA}', '\u{00AA}'), ('\u{00AB}', '\u{00AB}'), ('\u{00AC}', '\u{00AC}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B9}', '\u{00B9}'), ('\u{00BA}', '\u{00BA}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'),
    ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'),
    ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'),
    ('\u{00CB}', '\u{00EB}'), ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'), ('\u{00D0}', '\u{00F0}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'),
    ('\u{00D7}', '\u{00D7}'), ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00DC}', '\u{00FC}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00DE}', '\u{00FE}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'), ('\u{00C8}', '\u{00E8}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{00CF}', '\u{00EF}'), ('\u{00D0}', '\u{00F0}'), ('\u{00D1}', '\u{00F1}'),
    ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00DB}', '\u{00FB}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{0178}', '\u{00FF}'),
];

const ISO8859_1_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'),
    ('\u{0083}', '\u{0083}'), ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'),
    ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'), ('\u{0088}', '\u{0088}'),
    ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'),
    ('\u{008F}', '\u{008F}'), ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'),
    ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'), ('\u{0094}', '\u{0094}'),
    ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'),
    ('\u{009B}', '\u{009B}'), ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'),
    ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'), ('\u{00A0}', '\u{00A0}'),
    ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00A7}', '\u{00A7}'), ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{00AA}', '\u{00AA}'), ('\u{00AB}', '\u{00AB}'), ('\u{00AC}', '\u{00AC}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B9}', '\u{00B9}'), ('\u{00BA}', '\u{00BA}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'),
    ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'),
    ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'),
    ('\u{00CB}', '\u{00EB}'), ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'), ('\u{00D0}', '\u{00F0}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'),
    ('\u{00D7}', '\u{00D7}'), ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00DC}', '\u{00FC}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00DE}', '\u{00FE}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'), ('\u{00C8}', '\u{00E8}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{00CF}', '\u{00EF}'), ('\u{00D0}', '\u{00F0}'), ('\u{00D1}', '\u{00F1}'),
    ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00DB}', '\u{00FB}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{00FF}', '\u{00FF}'),
];

const ISO8859_2_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'),
    ('\u{0083}', '\u{0083}'), ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'),
    ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'), ('\u{0088}', '\u{0088}'),
    ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'),
    ('\u{008F}', '\u{008F}'), ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'),
    ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'), ('\u{0094}', '\u{0094}'),
    ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'),
    ('\u{009B}', '\u{009B}'), ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'),
    ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'), ('\u{00A0}', '\u{00A0}'),
    ('\u{0104}', '\u{0105}'), ('\u{02D8}', '\u{02D8}'), ('\u{0141}', '\u{0142}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{013D}', '\u{013E}'), ('\u{015A}', '\u{015B}'),
    ('\u{00A7}', '\u{00A7}'), ('\u{00A8}', '\u{00A8}'), ('\u{0160}', '\u{0161}'),
    ('\u{015E}', '\u{015F}'), ('\u{0164}', '\u{0165}'), ('\u{0179}', '\u{017A}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{017D}', '\u{017E}'), ('\u{017B}', '\u{017C}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{0104}', '\u{0105}'), ('\u{02DB}', '\u{02DB}'),
    ('\u{0141}', '\u{0142}'), ('\u{00B4}', '\u{00B4}'), ('\u{013D}', '\u{013E}'),
    ('\u{015A}', '\u{015B}'), ('\u{02C7}', '\u{02C7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{0160}', '\u{0161}'), ('\u{015E}', '\u{015F}'), ('\u{0164}', '\u{0165}'),
    ('\u{0179}', '\u{017A}'), ('\u{02DD}', '\u{02DD}'), ('\u{017D}', '\u{017E}'),
    ('\u{017B}', '\u{017C}'), ('\u{0154}', '\u{0155}'), ('\u{00C1}', '\u{00E1}'),
    ('\u{00C2}', '\u{00E2}'), ('\u{0102}', '\u{0103}'), ('\u{00C4}', '\u{00E4}'),
    ('\u{0139}', '\u{013A}'), ('\u{0106}', '\u{0107}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'),
    ('\u{00CB}', '\u{00EB}'), ('\u{011A}', '\u{011B}'), ('\u{00CD}', '\u{00ED}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{010E}', '\u{010F}'), ('\u{0110}', '\u{0111}'),
    ('\u{0143}', '\u{0144}'), ('\u{0147}', '\u{0148}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{0150}', '\u{0151}'), ('\u{00D6}', '\u{00F6}'),
    ('\u{00D7}', '\u{00D7}'), ('\u{0158}', '\u{0159}'), ('\u{016E}', '\u{016F}'),
    ('\u{00DA}', '\u{00FA}'), ('\u{0170}', '\u{0171}'), ('\u{00DC}', '\u{00FC}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{0162}', '\u{0163}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{0154}', '\u{0155}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{0102}', '\u{0103}'), ('\u{00C4}', '\u{00E4}'), ('\u{0139}', '\u{013A}'),
    ('\u{0106}', '\u{0107}'), ('\u{00C7}', '\u{00E7}'), ('\u{010C}', '\u{010D}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{011A}', '\u{011B}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{010E}', '\u{010F}'), ('\u{0110}', '\u{0111}'), ('\u{0143}', '\u{0144}'),
    ('\u{0147}', '\u{0148}'), ('\u{00D3}', '\u{00F3}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{0150}', '\u{0151}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{0158}', '\u{0159}'), ('\u{016E}', '\u{016F}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{0170}', '\u{0171}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{0162}', '\u{0163}'), ('\u{02D9}', '\u{02D9}'),
];

/// The (UPPER, LOWER) pair for a tabled set's high byte, GENERATED
/// from the live engine (`UNICODE_VAL(UPPER(S))`/`LOWER` over one-byte
/// rows, the codepage-table technique). The engine's case law is the
/// CHARSET's own: WIN1252 'ß' upcases to itself (not "SS"), its 'ÿ'
/// to 'Ÿ' (0x9F is in cp1252) while ISO8859_1's 'ÿ' stays (no 0xFF
/// uppercase there), and Cyrillic/Latin-2 pairs map within their sets.
/// The low half is plain ASCII case in every set (asserted during
/// generation, 0x20..0x7F row by row).
fn case_table(charset: u8) -> Option<&'static [(char, char); 128]> {
    match charset {
        CS_WIN1250 => Some(&WIN1250_CASE),
        CS_WIN1251 => Some(&WIN1251_CASE),
        CS_WIN1252 => Some(&WIN1252_CASE),
        CS_ISO8859_1 => Some(&ISO8859_1_CASE),
        CS_ISO8859_2 => Some(&ISO8859_2_CASE),
        _ => None,
    }
}

/// Case-map one character by a TABLED set's own law. `None` = the set
/// is not tabled (the caller keeps its own rule); `Some(Err(()))` = the
/// engine raises 22018 for this mapping (the CASE_ERR cell).
/// Unicode SIMPLE case mapping: a character whose FULL mapping is more
/// than one character (`ß` -> "SS", the ligatures) has no simple pair
/// and stays itself.
///
/// This is the engine's rule, not a shortcut: `UnicodeUtil::
/// utf16UpperCase` maps code point by code point through ICU's
/// `u_toupper` (common/unicode_util.cpp:691), with the full
/// `Any-Upper` transliterator commented out beside it - "this is more
/// correct but we don't support completely yet". So `UPPER('ß')`
/// answers 'ß' on a UTF8 value (probed live), and so does the UPPER
/// step inside a collation's canonical form.
pub fn simple_case(t: &str, upper: bool) -> String {
    let mut out = String::with_capacity(t.len());
    for c in t.chars() {
        // a character with no ONE-character mapping keeps itself
        if upper {
            let mut it = c.to_uppercase();
            let first = it.next().unwrap_or(c);
            out.push(if it.next().is_some() { c } else { first });
        } else {
            let mut it = c.to_lowercase();
            let first = it.next().unwrap_or(c);
            out.push(if it.next().is_some() { c } else { first });
        }
    }
    out
}

pub fn case_char(charset: u8, c: char, upper: bool) -> Option<Result<char, ()>> {
    let t = case_table(charset)?;
    if u32::from(c) < 0x80 {
        return Some(Ok(if upper {
            c.to_ascii_uppercase()
        } else {
            c.to_ascii_lowercase()
        }));
    }
    let b = match single_byte_of(charset, c) {
        Ok(Some(b)) if b >= 0x80 => b,
        // a character not of this set (defensive - a decoded value's
        // chars always are): unchanged
        _ => return Some(Ok(c)),
    };
    let (u, l) = t[(b - 0x80) as usize];
    let m = if upper { u } else { l };
    Some(if m == CASE_ERR { Err(()) } else { Ok(m) })
}

#[cfg(test)]
mod case_tests {
    use super::*;

    #[test]
    fn the_engine_s_case_law_not_rusts() {
        // WIN1252 'ß' upcases to ITSELF - Rust's to_uppercase says "SS"
        assert_eq!(case_char(CS_WIN1252, 'ß', true), Some(Ok('ß')));
        // 'ÿ' upcases in WIN1252 (0x9F holds 'Ÿ') ...
        assert_eq!(case_char(CS_WIN1252, 'ÿ', true), Some(Ok('Ÿ')));
        // ... and stays itself in ISO8859_1, which has no 'Ÿ'
        assert_eq!(case_char(CS_ISO8859_1, 'ÿ', true), Some(Ok('ÿ')));
        // the ONE erroring cell: 'ƒ' UPPER in WIN1252 (probed 22018)
        assert_eq!(case_char(CS_WIN1252, 'ƒ', true), Some(Err(())));
        assert_eq!(case_char(CS_WIN1252, 'ƒ', false), Some(Ok('ƒ')));
        // Cyrillic and Latin-2 pairs, engine-read
        assert_eq!(case_char(CS_WIN1251, 'й', true), Some(Ok('Й')));
        assert_eq!(case_char(CS_WIN1250, 'ř', true), Some(Ok('Ř')));
        assert_eq!(case_char(CS_ISO8859_2, 'Š', false), Some(Ok('š')));
        // ASCII is plain case everywhere
        assert_eq!(case_char(CS_WIN1251, 'a', true), Some(Ok('A')));
        // untabled sets answer None
        assert_eq!(case_char(CS_UTF8, 'a', true), None);
        assert_eq!(case_char(CS_NONE, 'a', true), None);
    }
}
