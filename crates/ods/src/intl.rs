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
        CS_DOS737 => Some(&DOS737_HIGH),
        CS_DOS437 => Some(&DOS437_HIGH),
        CS_DOS850 => Some(&DOS850_HIGH),
        CS_DOS865 => Some(&DOS865_HIGH),
        CS_DOS860 => Some(&DOS860_HIGH),
        CS_DOS863 => Some(&DOS863_HIGH),
        CS_DOS775 => Some(&DOS775_HIGH),
        CS_DOS858 => Some(&DOS858_HIGH),
        CS_DOS862 => Some(&DOS862_HIGH),
        CS_DOS864 => Some(&DOS864_HIGH),
        CS_NEXT => Some(&NEXT_HIGH),
        CS_ISO8859_3 => Some(&ISO8859_3_HIGH),
        CS_ISO8859_4 => Some(&ISO8859_4_HIGH),
        CS_ISO8859_5 => Some(&ISO8859_5_HIGH),
        CS_ISO8859_6 => Some(&ISO8859_6_HIGH),
        CS_ISO8859_7 => Some(&ISO8859_7_HIGH),
        CS_ISO8859_8 => Some(&ISO8859_8_HIGH),
        CS_ISO8859_9 => Some(&ISO8859_9_HIGH),
        CS_ISO8859_13 => Some(&ISO8859_13_HIGH),
        CS_DOS852 => Some(&DOS852_HIGH),
        CS_DOS857 => Some(&DOS857_HIGH),
        CS_DOS861 => Some(&DOS861_HIGH),
        CS_DOS866 => Some(&DOS866_HIGH),
        CS_DOS869 => Some(&DOS869_HIGH),
        CS_CYRL => Some(&CYRL_HIGH),
        CS_WIN1253 => Some(&WIN1253_HIGH),
        CS_WIN1254 => Some(&WIN1254_HIGH),
        CS_WIN1255 => Some(&WIN1255_HIGH),
        CS_WIN1256 => Some(&WIN1256_HIGH),
        CS_WIN1257 => Some(&WIN1257_HIGH),
        CS_KOI8R => Some(&KOI8R_HIGH),
        CS_KOI8U => Some(&KOI8U_HIGH),
        CS_WIN1258 => Some(&WIN1258_HIGH),
        CS_TIS620 => Some(&TIS620_HIGH),
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
    ) || high_table(charset).is_some()
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
        CS_DOS737 => Some(&DOS737_CASE),
        CS_DOS437 => Some(&DOS437_CASE),
        CS_DOS850 => Some(&DOS850_CASE),
        CS_DOS865 => Some(&DOS865_CASE),
        CS_DOS860 => Some(&DOS860_CASE),
        CS_DOS863 => Some(&DOS863_CASE),
        CS_DOS775 => Some(&DOS775_CASE),
        CS_DOS858 => Some(&DOS858_CASE),
        CS_DOS862 => Some(&DOS862_CASE),
        CS_DOS864 => Some(&DOS864_CASE),
        CS_NEXT => Some(&NEXT_CASE),
        CS_ISO8859_3 => Some(&ISO8859_3_CASE),
        CS_ISO8859_4 => Some(&ISO8859_4_CASE),
        CS_ISO8859_5 => Some(&ISO8859_5_CASE),
        CS_ISO8859_6 => Some(&ISO8859_6_CASE),
        CS_ISO8859_7 => Some(&ISO8859_7_CASE),
        CS_ISO8859_8 => Some(&ISO8859_8_CASE),
        CS_ISO8859_9 => Some(&ISO8859_9_CASE),
        CS_ISO8859_13 => Some(&ISO8859_13_CASE),
        CS_DOS852 => Some(&DOS852_CASE),
        CS_DOS857 => Some(&DOS857_CASE),
        CS_DOS861 => Some(&DOS861_CASE),
        CS_DOS866 => Some(&DOS866_CASE),
        CS_DOS869 => Some(&DOS869_CASE),
        CS_CYRL => Some(&CYRL_CASE),
        CS_WIN1253 => Some(&WIN1253_CASE),
        CS_WIN1254 => Some(&WIN1254_CASE),
        CS_WIN1255 => Some(&WIN1255_CASE),
        CS_WIN1256 => Some(&WIN1256_CASE),
        CS_WIN1257 => Some(&WIN1257_CASE),
        CS_KOI8R => Some(&KOI8R_CASE),
        CS_KOI8U => Some(&KOI8U_CASE),
        CS_WIN1258 => Some(&WIN1258_CASE),
        CS_TIS620 => Some(&TIS620_CASE),
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
        // The engine cases per character by the SIMPLE (single-char)
        // Unicode mapping, where Rust's to_lowercase/to_uppercase yield
        // the FULL (sometimes multi-char) mapping. The rule below keeps a
        // char whose full mapping is multi-char UNCHANGED (right for
        // 'ß' UPPER -> 'ß', a ligature -> itself), but that is WRONG for
        // the few whose SIMPLE mapping is a single DIFFERENT char.
        // U+0130 (LATIN CAPITAL LETTER I WITH DOT ABOVE) is the one that
        // matters: its simple lowercase is 'i' (U+0069) though its full
        // lowercase is 'i' + COMBINING DOT ABOVE - measured, the engine's
        // LOWER('İ') is 'i' (one octet) and `WHERE LOWER(nm)='istanbul'`
        // matches an 'İSTANBUL' row.
        if !upper && c == '\u{0130}' {
            out.push('\u{0069}');
            continue;
        }
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

// ---- GENERATED from the live engine (6.0.0.2196), 2026-10-05: every single-byte
// set it carries, byte 0x80..0xFF decoded to UTF8 (a byte the codepage leaves
// undefined decodes to U+0000 - the engine's own answer), and UPPER / LOWER of
// each byte read back in the set (CASE_ERR where the engine raises 22018).
// Regenerate with the extraction recorded in qa/serve-real-codepages.sh.
pub const CS_DOS737: u8 = 9;
pub const CS_DOS437: u8 = 10;
pub const CS_DOS850: u8 = 11;
pub const CS_DOS865: u8 = 12;
pub const CS_DOS860: u8 = 13;
pub const CS_DOS863: u8 = 14;
pub const CS_DOS775: u8 = 15;
pub const CS_DOS858: u8 = 16;
pub const CS_DOS862: u8 = 17;
pub const CS_DOS864: u8 = 18;
pub const CS_NEXT: u8 = 19;
pub const CS_ISO8859_3: u8 = 23;
pub const CS_ISO8859_4: u8 = 34;
pub const CS_ISO8859_5: u8 = 35;
pub const CS_ISO8859_6: u8 = 36;
pub const CS_ISO8859_7: u8 = 37;
pub const CS_ISO8859_8: u8 = 38;
pub const CS_ISO8859_9: u8 = 39;
pub const CS_ISO8859_13: u8 = 40;
pub const CS_DOS852: u8 = 45;
pub const CS_DOS857: u8 = 46;
pub const CS_DOS861: u8 = 47;
pub const CS_DOS866: u8 = 48;
pub const CS_DOS869: u8 = 49;
pub const CS_CYRL: u8 = 50;
pub const CS_WIN1253: u8 = 54;
pub const CS_WIN1254: u8 = 55;
pub const CS_WIN1255: u8 = 58;
pub const CS_WIN1256: u8 = 59;
pub const CS_WIN1257: u8 = 60;
pub const CS_KOI8R: u8 = 63;
pub const CS_KOI8U: u8 = 64;
pub const CS_WIN1258: u8 = 65;
pub const CS_TIS620: u8 = 66;
const DOS737_HIGH: [char; 128] = [
    '\u{0391}', '\u{0392}', '\u{0393}', '\u{0394}', '\u{0395}', '\u{0396}', '\u{0397}', '\u{0398}',
    '\u{0399}', '\u{039A}', '\u{039B}', '\u{039C}', '\u{039D}', '\u{039E}', '\u{039F}', '\u{03A0}',
    '\u{03A1}', '\u{03A3}', '\u{03A4}', '\u{03A5}', '\u{03A6}', '\u{03A7}', '\u{03A8}', '\u{03A9}',
    '\u{03B1}', '\u{03B2}', '\u{03B3}', '\u{03B4}', '\u{03B5}', '\u{03B6}', '\u{03B7}', '\u{03B8}',
    '\u{03B9}', '\u{03BA}', '\u{03BB}', '\u{03BC}', '\u{03BD}', '\u{03BE}', '\u{03BF}', '\u{03C0}',
    '\u{03C1}', '\u{03C3}', '\u{03C2}', '\u{03C4}', '\u{03C5}', '\u{03C6}', '\u{03C7}', '\u{03C8}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03C9}', '\u{03AC}', '\u{03AD}', '\u{03AE}', '\u{03CA}', '\u{03AF}', '\u{03CC}', '\u{03CD}',
    '\u{03CB}', '\u{03CE}', '\u{0386}', '\u{0388}', '\u{0389}', '\u{038A}', '\u{038C}', '\u{038E}',
    '\u{038F}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{03AA}', '\u{03AB}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS737_CASE: [(char, char); 128] = [
    ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'), ('\u{0394}', '\u{03B4}'),
    ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'), ('\u{0398}', '\u{03B8}'),
    ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'), ('\u{039C}', '\u{03BC}'),
    ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'), ('\u{03A0}', '\u{03C0}'),
    ('\u{03A1}', '\u{03C1}'), ('\u{03A3}', '\u{03C3}'), ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'), ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'),
    ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'), ('\u{0394}', '\u{03B4}'),
    ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'), ('\u{0398}', '\u{03B8}'),
    ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'), ('\u{039C}', '\u{03BC}'),
    ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'), ('\u{03A0}', '\u{03C0}'),
    ('\u{03A1}', '\u{03C1}'), ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C2}'), ('\u{03A4}', '\u{03C4}'),
    ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'), ('\u{03A8}', '\u{03C8}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    ('\u{03A9}', '\u{03C9}'), ('\u{0386}', '\u{03AC}'), ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'),
    ('\u{03AA}', '\u{03CA}'), ('\u{038A}', '\u{03AF}'), ('\u{038C}', '\u{03CC}'), ('\u{038E}', '\u{03CD}'),
    ('\u{03AB}', '\u{03CB}'), ('\u{038F}', '\u{03CE}'), ('\u{0386}', '\u{03AC}'), ('\u{0388}', '\u{03AD}'),
    ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'), ('\u{038C}', '\u{03CC}'), ('\u{038E}', '\u{03CD}'),
    ('\u{038F}', '\u{03CE}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{03AA}', '\u{03CA}'), ('\u{03AB}', '\u{03CB}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS437_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{00EC}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00F2}', '\u{00FB}', '\u{00F9}',
    '\u{00FF}', '\u{00D6}', '\u{00DC}', '\u{00A2}', '\u{00A3}', '\u{00A5}', '\u{20A7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{2310}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS437_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), (CASE_ERR, '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), (CASE_ERR, '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    (CASE_ERR, '\u{00EA}'), (CASE_ERR, '\u{00EB}'), (CASE_ERR, '\u{00E8}'), (CASE_ERR, '\u{00EF}'),
    (CASE_ERR, '\u{00EE}'), (CASE_ERR, '\u{00EC}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), (CASE_ERR, '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), (CASE_ERR, '\u{00F2}'), (CASE_ERR, '\u{00FB}'), (CASE_ERR, '\u{00F9}'),
    ('\u{00FF}', '\u{00FF}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00A2}', '\u{00A2}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00A5}', '\u{00A5}'), ('\u{20A7}', '\u{20A7}'), (CASE_ERR, '\u{0192}'),
    (CASE_ERR, '\u{00E1}'), (CASE_ERR, '\u{00ED}'), (CASE_ERR, '\u{00F3}'), (CASE_ERR, '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{2310}', '\u{2310}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS850_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{00EC}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00F2}', '\u{00FB}', '\u{00F9}',
    '\u{00FF}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{00D7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{00AE}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{00C1}', '\u{00C2}', '\u{00C0}',
    '\u{00A9}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{00A2}', '\u{00A5}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{00E3}', '\u{00C3}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{00A4}',
    '\u{00F0}', '\u{00D0}', '\u{00CA}', '\u{00CB}', '\u{00C8}', '\u{0131}', '\u{00CD}', '\u{00CE}',
    '\u{00CF}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{00A6}', '\u{00CC}', '\u{2580}',
    '\u{00D3}', '\u{00DF}', '\u{00D4}', '\u{00D2}', '\u{00F5}', '\u{00D5}', '\u{00B5}', '\u{00FE}',
    '\u{00DE}', '\u{00DA}', '\u{00DB}', '\u{00D9}', '\u{00FD}', '\u{00DD}', '\u{00AF}', '\u{00B4}',
    '\u{00AD}', '\u{00B1}', '\u{2017}', '\u{00BE}', '\u{00B6}', '\u{00A7}', '\u{00F7}', '\u{00B8}',
    '\u{00B0}', '\u{00A8}', '\u{00B7}', '\u{00B9}', '\u{00B3}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS850_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{00CC}', '\u{00EC}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{00D2}', '\u{00F2}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00FF}', '\u{00FF}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{00D7}', '\u{00D7}'), (CASE_ERR, '\u{0192}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C0}', '\u{00E0}'),
    ('\u{00A9}', '\u{00A9}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A5}', '\u{00A5}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{00D0}', '\u{00F0}'), ('\u{00D0}', '\u{00F0}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{0049}', '\u{0131}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{00CF}', '\u{00EF}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{00A6}', '\u{00A6}'), ('\u{00CC}', '\u{00EC}'), ('\u{2580}', '\u{2580}'),
    ('\u{00D3}', '\u{00F3}'), ('\u{00DF}', '\u{00DF}'), ('\u{00D4}', '\u{00F4}'), ('\u{00D2}', '\u{00F2}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D5}', '\u{00F5}'), ('\u{00B5}', '\u{00B5}'), ('\u{00DE}', '\u{00FE}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00DD}', '\u{00FD}'), ('\u{00AF}', '\u{00AF}'), ('\u{00B4}', '\u{00B4}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00B1}', '\u{00B1}'), ('\u{2017}', '\u{2017}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00A7}', '\u{00A7}'), ('\u{00F7}', '\u{00F7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00A8}', '\u{00A8}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B9}', '\u{00B9}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS865_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{00EC}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00F2}', '\u{00FB}', '\u{00F9}',
    '\u{00FF}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{20A7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{2310}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00A4}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS865_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), (CASE_ERR, '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), (CASE_ERR, '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    (CASE_ERR, '\u{00EA}'), (CASE_ERR, '\u{00EB}'), (CASE_ERR, '\u{00E8}'), (CASE_ERR, '\u{00EF}'),
    (CASE_ERR, '\u{00EE}'), (CASE_ERR, '\u{00EC}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), (CASE_ERR, '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), (CASE_ERR, '\u{00F2}'), (CASE_ERR, '\u{00FB}'), (CASE_ERR, '\u{00F9}'),
    ('\u{00FF}', '\u{00FF}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{20A7}', '\u{20A7}'), (CASE_ERR, '\u{0192}'),
    (CASE_ERR, '\u{00E1}'), (CASE_ERR, '\u{00ED}'), (CASE_ERR, '\u{00F3}'), (CASE_ERR, '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{2310}', '\u{2310}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS860_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E3}', '\u{00E0}', '\u{00C1}', '\u{00E7}',
    '\u{00EA}', '\u{00CA}', '\u{00E8}', '\u{00CD}', '\u{00D4}', '\u{00EC}', '\u{00C3}', '\u{00C2}',
    '\u{00C9}', '\u{00C0}', '\u{00C8}', '\u{00F4}', '\u{00F5}', '\u{00F2}', '\u{00DA}', '\u{00F9}',
    '\u{00CC}', '\u{00D5}', '\u{00DC}', '\u{00A2}', '\u{00A3}', '\u{00D9}', '\u{20A7}', '\u{00D3}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{00D2}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS860_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C3}', '\u{00E3}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00CA}', '\u{00EA}'), ('\u{00CA}', '\u{00EA}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CD}', '\u{00ED}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00CC}', '\u{00EC}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C8}', '\u{00E8}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D2}', '\u{00F2}'), ('\u{00DA}', '\u{00FA}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00D5}', '\u{00F5}'), ('\u{00DC}', '\u{00FC}'), ('\u{00A2}', '\u{00A2}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D9}', '\u{00F9}'), ('\u{20A7}', '\u{20A7}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00D2}', '\u{00F2}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS863_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00C2}', '\u{00E0}', '\u{00B6}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{2017}', '\u{00C0}', '\u{00A7}',
    '\u{00C9}', '\u{00C8}', '\u{00CA}', '\u{00F4}', '\u{00CB}', '\u{00CF}', '\u{00FB}', '\u{00F9}',
    '\u{00A4}', '\u{00D4}', '\u{00DC}', '\u{00A2}', '\u{00A3}', '\u{00D9}', '\u{00DB}', '\u{0192}',
    '\u{00A6}', '\u{00B4}', '\u{00F3}', '\u{00FA}', '\u{00A8}', '\u{00B8}', '\u{00B3}', '\u{00AF}',
    '\u{00CE}', '\u{2310}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00BE}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS863_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C2}', '\u{00E2}'), ('\u{00C0}', '\u{00E0}'), ('\u{00B6}', '\u{00B6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{2017}', '\u{2017}'), ('\u{00C0}', '\u{00E0}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CA}', '\u{00EA}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00CB}', '\u{00EB}'), ('\u{00CF}', '\u{00EF}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00D4}', '\u{00F4}'), ('\u{00DC}', '\u{00FC}'), ('\u{00A2}', '\u{00A2}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DB}', '\u{00FB}'), (CASE_ERR, '\u{0192}'),
    ('\u{00A6}', '\u{00A6}'), ('\u{00B4}', '\u{00B4}'), (CASE_ERR, '\u{00F3}'), (CASE_ERR, '\u{00FA}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00B8}', '\u{00B8}'), ('\u{00B3}', '\u{00B3}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{2310}', '\u{2310}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BE}', '\u{00BE}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS775_HIGH: [char; 128] = [
    '\u{0106}', '\u{00FC}', '\u{00E9}', '\u{0101}', '\u{00E4}', '\u{0123}', '\u{00E5}', '\u{0107}',
    '\u{0142}', '\u{0113}', '\u{0156}', '\u{0157}', '\u{012B}', '\u{0179}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{014D}', '\u{00F6}', '\u{0122}', '\u{00A2}', '\u{015A}',
    '\u{015B}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{00D7}', '\u{00A4}',
    '\u{0100}', '\u{012A}', '\u{00F3}', '\u{017B}', '\u{017C}', '\u{017A}', '\u{201D}', '\u{00A6}',
    '\u{00A9}', '\u{00AE}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{0141}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{0104}', '\u{010C}', '\u{0118}',
    '\u{0116}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{012E}', '\u{0160}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{0172}', '\u{016A}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{017D}',
    '\u{0105}', '\u{010D}', '\u{0119}', '\u{0117}', '\u{012F}', '\u{0161}', '\u{0173}', '\u{016B}',
    '\u{017E}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{00D3}', '\u{00DF}', '\u{014C}', '\u{0143}', '\u{00F5}', '\u{00D5}', '\u{00B5}', '\u{0144}',
    '\u{0136}', '\u{0137}', '\u{013B}', '\u{013C}', '\u{0146}', '\u{0112}', '\u{0145}', '\u{2019}',
    '\u{00AD}', '\u{00B1}', '\u{201C}', '\u{00BE}', '\u{00B6}', '\u{00A7}', '\u{00F7}', '\u{201E}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{00B9}', '\u{00B3}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS775_CASE: [(char, char); 128] = [
    ('\u{0106}', '\u{0107}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{0100}', '\u{0101}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{0122}', '\u{0123}'), ('\u{00C5}', '\u{00E5}'), ('\u{0106}', '\u{0107}'),
    ('\u{0141}', '\u{0142}'), ('\u{0112}', '\u{0113}'), ('\u{0156}', '\u{0157}'), ('\u{0156}', '\u{0157}'),
    ('\u{012A}', '\u{012B}'), ('\u{0179}', '\u{017A}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), ('\u{014C}', '\u{014D}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{0122}', '\u{0123}'), ('\u{00A2}', '\u{00A2}'), ('\u{015A}', '\u{015B}'),
    ('\u{015A}', '\u{015B}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{00D7}', '\u{00D7}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{0100}', '\u{0101}'), ('\u{012A}', '\u{012B}'), ('\u{00D3}', '\u{00F3}'), ('\u{017B}', '\u{017C}'),
    ('\u{017B}', '\u{017C}'), ('\u{0179}', '\u{017A}'), ('\u{201D}', '\u{201D}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00A9}', '\u{00A9}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{0141}', '\u{0142}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{0104}', '\u{0105}'), ('\u{010C}', '\u{010D}'), ('\u{0118}', '\u{0119}'),
    ('\u{0116}', '\u{0117}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{012E}', '\u{012F}'), ('\u{0160}', '\u{0161}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{0172}', '\u{0173}'), ('\u{016A}', '\u{016B}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{017D}', '\u{017E}'),
    ('\u{0104}', '\u{0105}'), ('\u{010C}', '\u{010D}'), ('\u{0118}', '\u{0119}'), ('\u{0116}', '\u{0117}'),
    ('\u{012E}', '\u{012F}'), ('\u{0160}', '\u{0161}'), ('\u{0172}', '\u{0173}'), ('\u{016A}', '\u{016B}'),
    ('\u{017D}', '\u{017E}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    ('\u{00D3}', '\u{00F3}'), ('\u{00DF}', '\u{00DF}'), ('\u{014C}', '\u{014D}'), ('\u{0143}', '\u{0144}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D5}', '\u{00F5}'), ('\u{00B5}', '\u{00B5}'), ('\u{0143}', '\u{0144}'),
    ('\u{0136}', '\u{0137}'), ('\u{0136}', '\u{0137}'), ('\u{013B}', '\u{013C}'), ('\u{013B}', '\u{013C}'),
    ('\u{0145}', '\u{0146}'), ('\u{0112}', '\u{0113}'), ('\u{0145}', '\u{0146}'), ('\u{2019}', '\u{2019}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00B1}', '\u{00B1}'), ('\u{201C}', '\u{201C}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00A7}', '\u{00A7}'), ('\u{00F7}', '\u{00F7}'), ('\u{201E}', '\u{201E}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B9}', '\u{00B9}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS858_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{00EC}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00F2}', '\u{00FB}', '\u{00F9}',
    '\u{00FF}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{00D7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{00AE}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{00C1}', '\u{00C2}', '\u{00C0}',
    '\u{00A9}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{00A2}', '\u{00A5}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{00E3}', '\u{00C3}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{00A4}',
    '\u{00F0}', '\u{00D0}', '\u{00CA}', '\u{00CB}', '\u{00C8}', '\u{20AC}', '\u{00CD}', '\u{00CE}',
    '\u{00CF}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{00A6}', '\u{00CC}', '\u{2580}',
    '\u{00D3}', '\u{00DF}', '\u{00D4}', '\u{00D2}', '\u{00F5}', '\u{00D5}', '\u{00B5}', '\u{00FE}',
    '\u{00DE}', '\u{00DA}', '\u{00DB}', '\u{00D9}', '\u{00FD}', '\u{00DD}', '\u{00AF}', '\u{00B4}',
    '\u{00AD}', '\u{00B1}', '\u{2017}', '\u{00BE}', '\u{00B6}', '\u{00A7}', '\u{00F7}', '\u{00B8}',
    '\u{00B0}', '\u{00A8}', '\u{00B7}', '\u{00B9}', '\u{00B3}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS858_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{00CC}', '\u{00EC}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{00D2}', '\u{00F2}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00FF}', '\u{00FF}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{00D7}', '\u{00D7}'), (CASE_ERR, '\u{0192}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C0}', '\u{00E0}'),
    ('\u{00A9}', '\u{00A9}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A5}', '\u{00A5}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{00D0}', '\u{00F0}'), ('\u{00D0}', '\u{00F0}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{20AC}', '\u{20AC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{00CF}', '\u{00EF}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{00A6}', '\u{00A6}'), ('\u{00CC}', '\u{00EC}'), ('\u{2580}', '\u{2580}'),
    ('\u{00D3}', '\u{00F3}'), ('\u{00DF}', '\u{00DF}'), ('\u{00D4}', '\u{00F4}'), ('\u{00D2}', '\u{00F2}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D5}', '\u{00F5}'), ('\u{00B5}', '\u{00B5}'), ('\u{00DE}', '\u{00FE}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00DD}', '\u{00FD}'), ('\u{00AF}', '\u{00AF}'), ('\u{00B4}', '\u{00B4}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00B1}', '\u{00B1}'), ('\u{2017}', '\u{2017}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00A7}', '\u{00A7}'), ('\u{00F7}', '\u{00F7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00A8}', '\u{00A8}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B9}', '\u{00B9}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS862_HIGH: [char; 128] = [
    '\u{05D0}', '\u{05D1}', '\u{05D2}', '\u{05D3}', '\u{05D4}', '\u{05D5}', '\u{05D6}', '\u{05D7}',
    '\u{05D8}', '\u{05D9}', '\u{05DA}', '\u{05DB}', '\u{05DC}', '\u{05DD}', '\u{05DE}', '\u{05DF}',
    '\u{05E0}', '\u{05E1}', '\u{05E2}', '\u{05E3}', '\u{05E4}', '\u{05E5}', '\u{05E6}', '\u{05E7}',
    '\u{05E8}', '\u{05E9}', '\u{05EA}', '\u{00A2}', '\u{00A3}', '\u{00A5}', '\u{20A7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{00AA}', '\u{00BA}',
    '\u{00BF}', '\u{2310}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS862_CASE: [(char, char); 128] = [
    ('\u{05D0}', '\u{05D0}'), ('\u{05D1}', '\u{05D1}'), ('\u{05D2}', '\u{05D2}'), ('\u{05D3}', '\u{05D3}'),
    ('\u{05D4}', '\u{05D4}'), ('\u{05D5}', '\u{05D5}'), ('\u{05D6}', '\u{05D6}'), ('\u{05D7}', '\u{05D7}'),
    ('\u{05D8}', '\u{05D8}'), ('\u{05D9}', '\u{05D9}'), ('\u{05DA}', '\u{05DA}'), ('\u{05DB}', '\u{05DB}'),
    ('\u{05DC}', '\u{05DC}'), ('\u{05DD}', '\u{05DD}'), ('\u{05DE}', '\u{05DE}'), ('\u{05DF}', '\u{05DF}'),
    ('\u{05E0}', '\u{05E0}'), ('\u{05E1}', '\u{05E1}'), ('\u{05E2}', '\u{05E2}'), ('\u{05E3}', '\u{05E3}'),
    ('\u{05E4}', '\u{05E4}'), ('\u{05E5}', '\u{05E5}'), ('\u{05E6}', '\u{05E6}'), ('\u{05E7}', '\u{05E7}'),
    ('\u{05E8}', '\u{05E8}'), ('\u{05E9}', '\u{05E9}'), ('\u{05EA}', '\u{05EA}'), ('\u{00A2}', '\u{00A2}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00A5}', '\u{00A5}'), ('\u{20A7}', '\u{20A7}'), (CASE_ERR, '\u{0192}'),
    (CASE_ERR, '\u{00E1}'), (CASE_ERR, '\u{00ED}'), (CASE_ERR, '\u{00F3}'), (CASE_ERR, '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{00AA}', '\u{00AA}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{2310}', '\u{2310}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS864_HIGH: [char; 128] = [
    '\u{00B0}', '\u{00B7}', '\u{2219}', '\u{221A}', '\u{2592}', '\u{2500}', '\u{2502}', '\u{253C}',
    '\u{2524}', '\u{252C}', '\u{251C}', '\u{2534}', '\u{2510}', '\u{250C}', '\u{2514}', '\u{2518}',
    '\u{03B2}', '\u{221E}', '\u{03C6}', '\u{00B1}', '\u{00BD}', '\u{00BC}', '\u{2248}', '\u{00AB}',
    '\u{00BB}', '\u{FEF7}', '\u{FEF8}', '\u{0000}', '\u{0000}', '\u{FEFB}', '\u{FEFC}', '\u{0000}',
    '\u{00A0}', '\u{00AD}', '\u{FE82}', '\u{00A3}', '\u{00A4}', '\u{FE84}', '\u{0000}', '\u{0000}',
    '\u{FE8E}', '\u{FE8F}', '\u{FE95}', '\u{FE99}', '\u{060C}', '\u{FE9D}', '\u{FEA1}', '\u{FEA5}',
    '\u{0660}', '\u{0661}', '\u{0662}', '\u{0663}', '\u{0664}', '\u{0665}', '\u{0666}', '\u{0667}',
    '\u{0668}', '\u{0669}', '\u{FED1}', '\u{061B}', '\u{FEB1}', '\u{FEB5}', '\u{FEB9}', '\u{061F}',
    '\u{00A2}', '\u{FE80}', '\u{FE81}', '\u{FE83}', '\u{FE85}', '\u{FECA}', '\u{FE8B}', '\u{FE8D}',
    '\u{FE91}', '\u{FE93}', '\u{FE97}', '\u{FE9B}', '\u{FE9F}', '\u{FEA3}', '\u{FEA7}', '\u{FEA9}',
    '\u{FEAB}', '\u{FEAD}', '\u{FEAF}', '\u{FEB3}', '\u{FEB7}', '\u{FEBB}', '\u{FEBF}', '\u{FEC1}',
    '\u{FEC5}', '\u{FECB}', '\u{FECF}', '\u{00A6}', '\u{00AC}', '\u{00F7}', '\u{00D7}', '\u{FEC9}',
    '\u{0640}', '\u{FED3}', '\u{FED7}', '\u{FEDB}', '\u{FEDF}', '\u{FEE3}', '\u{FEE7}', '\u{FEEB}',
    '\u{FEED}', '\u{FEEF}', '\u{FEF3}', '\u{FEBD}', '\u{FECC}', '\u{FECE}', '\u{FECD}', '\u{FEE1}',
    '\u{FE7D}', '\u{0651}', '\u{FEE5}', '\u{FEE9}', '\u{FEEC}', '\u{FEF0}', '\u{FEF2}', '\u{FED0}',
    '\u{FED5}', '\u{FEF5}', '\u{FEF6}', '\u{FEDD}', '\u{FED9}', '\u{FEF1}', '\u{25A0}', '\u{0000}',
];
const DOS864_CASE: [(char, char); 128] = [
    ('\u{00B0}', '\u{00B0}'), ('\u{00B7}', '\u{00B7}'), ('\u{2219}', '\u{2219}'), ('\u{221A}', '\u{221A}'),
    ('\u{2592}', '\u{2592}'), ('\u{2500}', '\u{2500}'), ('\u{2502}', '\u{2502}'), ('\u{253C}', '\u{253C}'),
    ('\u{2524}', '\u{2524}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'), ('\u{2534}', '\u{2534}'),
    ('\u{2510}', '\u{2510}'), ('\u{250C}', '\u{250C}'), ('\u{2514}', '\u{2514}'), ('\u{2518}', '\u{2518}'),
    (CASE_ERR, '\u{03B2}'), ('\u{221E}', '\u{221E}'), (CASE_ERR, '\u{03C6}'), ('\u{00B1}', '\u{00B1}'),
    ('\u{00BD}', '\u{00BD}'), ('\u{00BC}', '\u{00BC}'), ('\u{2248}', '\u{2248}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00BB}', '\u{00BB}'), ('\u{FEF7}', '\u{FEF7}'), ('\u{FEF8}', '\u{FEF8}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{FEFB}', '\u{FEFB}'), ('\u{FEFC}', '\u{FEFC}'), ('\u{0000}', '\u{0000}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{00AD}', '\u{00AD}'), ('\u{FE82}', '\u{FE82}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{FE84}', '\u{FE84}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{FE8E}', '\u{FE8E}'), ('\u{FE8F}', '\u{FE8F}'), ('\u{FE95}', '\u{FE95}'), ('\u{FE99}', '\u{FE99}'),
    ('\u{060C}', '\u{060C}'), ('\u{FE9D}', '\u{FE9D}'), ('\u{FEA1}', '\u{FEA1}'), ('\u{FEA5}', '\u{FEA5}'),
    ('\u{0660}', '\u{0660}'), ('\u{0661}', '\u{0661}'), ('\u{0662}', '\u{0662}'), ('\u{0663}', '\u{0663}'),
    ('\u{0664}', '\u{0664}'), ('\u{0665}', '\u{0665}'), ('\u{0666}', '\u{0666}'), ('\u{0667}', '\u{0667}'),
    ('\u{0668}', '\u{0668}'), ('\u{0669}', '\u{0669}'), ('\u{FED1}', '\u{FED1}'), ('\u{061B}', '\u{061B}'),
    ('\u{FEB1}', '\u{FEB1}'), ('\u{FEB5}', '\u{FEB5}'), ('\u{FEB9}', '\u{FEB9}'), ('\u{061F}', '\u{061F}'),
    ('\u{00A2}', '\u{00A2}'), ('\u{FE80}', '\u{FE80}'), ('\u{FE81}', '\u{FE81}'), ('\u{FE83}', '\u{FE83}'),
    ('\u{FE85}', '\u{FE85}'), ('\u{FECA}', '\u{FECA}'), ('\u{FE8B}', '\u{FE8B}'), ('\u{FE8D}', '\u{FE8D}'),
    ('\u{FE91}', '\u{FE91}'), ('\u{FE93}', '\u{FE93}'), ('\u{FE97}', '\u{FE97}'), ('\u{FE9B}', '\u{FE9B}'),
    ('\u{FE9F}', '\u{FE9F}'), ('\u{FEA3}', '\u{FEA3}'), ('\u{FEA7}', '\u{FEA7}'), ('\u{FEA9}', '\u{FEA9}'),
    ('\u{FEAB}', '\u{FEAB}'), ('\u{FEAD}', '\u{FEAD}'), ('\u{FEAF}', '\u{FEAF}'), ('\u{FEB3}', '\u{FEB3}'),
    ('\u{FEB7}', '\u{FEB7}'), ('\u{FEBB}', '\u{FEBB}'), ('\u{FEBF}', '\u{FEBF}'), ('\u{FEC1}', '\u{FEC1}'),
    ('\u{FEC5}', '\u{FEC5}'), ('\u{FECB}', '\u{FECB}'), ('\u{FECF}', '\u{FECF}'), ('\u{00A6}', '\u{00A6}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00F7}', '\u{00F7}'), ('\u{00D7}', '\u{00D7}'), ('\u{FEC9}', '\u{FEC9}'),
    ('\u{0640}', '\u{0640}'), ('\u{FED3}', '\u{FED3}'), ('\u{FED7}', '\u{FED7}'), ('\u{FEDB}', '\u{FEDB}'),
    ('\u{FEDF}', '\u{FEDF}'), ('\u{FEE3}', '\u{FEE3}'), ('\u{FEE7}', '\u{FEE7}'), ('\u{FEEB}', '\u{FEEB}'),
    ('\u{FEED}', '\u{FEED}'), ('\u{FEEF}', '\u{FEEF}'), ('\u{FEF3}', '\u{FEF3}'), ('\u{FEBD}', '\u{FEBD}'),
    ('\u{FECC}', '\u{FECC}'), ('\u{FECE}', '\u{FECE}'), ('\u{FECD}', '\u{FECD}'), ('\u{FEE1}', '\u{FEE1}'),
    ('\u{FE7D}', '\u{FE7D}'), ('\u{0651}', '\u{0651}'), ('\u{FEE5}', '\u{FEE5}'), ('\u{FEE9}', '\u{FEE9}'),
    ('\u{FEEC}', '\u{FEEC}'), ('\u{FEF0}', '\u{FEF0}'), ('\u{FEF2}', '\u{FEF2}'), ('\u{FED0}', '\u{FED0}'),
    ('\u{FED5}', '\u{FED5}'), ('\u{FEF5}', '\u{FEF5}'), ('\u{FEF6}', '\u{FEF6}'), ('\u{FEDD}', '\u{FEDD}'),
    ('\u{FED9}', '\u{FED9}'), ('\u{FEF1}', '\u{FEF1}'), ('\u{25A0}', '\u{25A0}'), ('\u{0000}', '\u{0000}'),
];
const NEXT_HIGH: [char; 128] = [
    '\u{00A0}', '\u{00C0}', '\u{00C1}', '\u{00C2}', '\u{00C3}', '\u{00C4}', '\u{00C5}', '\u{00C7}',
    '\u{00C8}', '\u{00C9}', '\u{00CA}', '\u{00CB}', '\u{00CC}', '\u{00CD}', '\u{00CE}', '\u{00CF}',
    '\u{00D0}', '\u{00D1}', '\u{00D2}', '\u{00D3}', '\u{00D4}', '\u{00D5}', '\u{00D6}', '\u{00D9}',
    '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{00DD}', '\u{00DE}', '\u{00B5}', '\u{00D7}', '\u{00F7}',
    '\u{00A9}', '\u{00A1}', '\u{00A2}', '\u{00A3}', '\u{2044}', '\u{00A5}', '\u{0192}', '\u{00A7}',
    '\u{00A4}', '\u{2019}', '\u{201C}', '\u{00AB}', '\u{2039}', '\u{203A}', '\u{FB01}', '\u{FB02}',
    '\u{00AE}', '\u{2013}', '\u{2020}', '\u{2021}', '\u{00B7}', '\u{00A6}', '\u{00B6}', '\u{2022}',
    '\u{201A}', '\u{201E}', '\u{201D}', '\u{00BB}', '\u{2026}', '\u{2030}', '\u{00AC}', '\u{00BF}',
    '\u{00B9}', '\u{02CB}', '\u{00B4}', '\u{02C6}', '\u{02DC}', '\u{00AF}', '\u{02D8}', '\u{02D9}',
    '\u{00A8}', '\u{00B2}', '\u{02DA}', '\u{00B8}', '\u{00B3}', '\u{02DD}', '\u{02DB}', '\u{02C7}',
    '\u{2014}', '\u{00B1}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00E0}', '\u{00E1}', '\u{00E2}',
    '\u{00E3}', '\u{00E4}', '\u{00E5}', '\u{00E7}', '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}',
    '\u{00EC}', '\u{00C6}', '\u{00ED}', '\u{00AA}', '\u{00EE}', '\u{00EF}', '\u{00F0}', '\u{00F1}',
    '\u{0141}', '\u{00D8}', '\u{0152}', '\u{00BA}', '\u{00F2}', '\u{00F3}', '\u{00F4}', '\u{00F5}',
    '\u{00F6}', '\u{00E6}', '\u{00F9}', '\u{00FA}', '\u{00FB}', '\u{0131}', '\u{00FC}', '\u{00FD}',
    '\u{0142}', '\u{00F8}', '\u{0153}', '\u{00DF}', '\u{00FE}', '\u{00FF}', '\u{FFFD}', '\u{FFFD}',
];
const NEXT_CASE: [(char, char); 128] = [
    ('\u{00A0}', '\u{00A0}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{00D0}', '\u{00F0}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{00B5}', '\u{00B5}'), ('\u{00D7}', '\u{00D7}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00A9}', '\u{00A9}'), ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{2044}', '\u{2044}'), ('\u{00A5}', '\u{00A5}'), (CASE_ERR, '\u{0192}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{2039}', '\u{2039}'), ('\u{203A}', '\u{203A}'), ('\u{FB01}', '\u{FB01}'), ('\u{FB02}', '\u{FB02}'),
    ('\u{00AE}', '\u{00AE}'), ('\u{2013}', '\u{2013}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{00B7}', '\u{00B7}'), ('\u{00A6}', '\u{00A6}'), ('\u{00B6}', '\u{00B6}'), ('\u{2022}', '\u{2022}'),
    ('\u{201A}', '\u{201A}'), ('\u{201E}', '\u{201E}'), ('\u{201D}', '\u{201D}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2026}', '\u{2026}'), ('\u{2030}', '\u{2030}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BF}', '\u{00BF}'),
    ('\u{00B9}', '\u{00B9}'), ('\u{02CB}', '\u{02CB}'), ('\u{00B4}', '\u{00B4}'), ('\u{02C6}', '\u{02C6}'),
    ('\u{02DC}', '\u{02DC}'), ('\u{00AF}', '\u{00AF}'), ('\u{02D8}', '\u{02D8}'), ('\u{02D9}', '\u{02D9}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00B2}', '\u{00B2}'), ('\u{02DA}', '\u{02DA}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{02DD}', '\u{02DD}'), ('\u{02DB}', '\u{02DB}'), ('\u{02C7}', '\u{02C7}'),
    ('\u{2014}', '\u{2014}'), ('\u{00B1}', '\u{00B1}'), ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BE}', '\u{00BE}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C3}', '\u{00E3}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00C6}', '\u{00E6}'), ('\u{00CD}', '\u{00ED}'), ('\u{00AA}', '\u{00AA}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'), ('\u{00D0}', '\u{00F0}'), ('\u{00D1}', '\u{00F1}'),
    ('\u{0141}', '\u{0142}'), ('\u{00D8}', '\u{00F8}'), ('\u{0152}', '\u{0153}'), ('\u{00BA}', '\u{00BA}'),
    ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'), ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{00C6}', '\u{00E6}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00DB}', '\u{00FB}'), ('\u{0049}', '\u{0131}'), ('\u{00DC}', '\u{00FC}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{0141}', '\u{0142}'), ('\u{00D8}', '\u{00F8}'), ('\u{0152}', '\u{0153}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00DE}', '\u{00FE}'), ('\u{00FF}', '\u{00FF}'), ('\u{FFFD}', '\u{FFFD}'), ('\u{FFFD}', '\u{FFFD}'),
];
const ISO8859_3_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0126}', '\u{02D8}', '\u{00A3}', '\u{00A4}', '\u{0000}', '\u{0124}', '\u{00A7}',
    '\u{00A8}', '\u{0130}', '\u{015E}', '\u{011E}', '\u{0134}', '\u{00AD}', '\u{0000}', '\u{017B}',
    '\u{00B0}', '\u{0127}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{0125}', '\u{00B7}',
    '\u{00B8}', '\u{0131}', '\u{015F}', '\u{011F}', '\u{0135}', '\u{00BD}', '\u{0000}', '\u{017C}',
    '\u{00C0}', '\u{00C1}', '\u{00C2}', '\u{0000}', '\u{00C4}', '\u{010A}', '\u{0108}', '\u{00C7}',
    '\u{00C8}', '\u{00C9}', '\u{00CA}', '\u{00CB}', '\u{00CC}', '\u{00CD}', '\u{00CE}', '\u{00CF}',
    '\u{0000}', '\u{00D1}', '\u{00D2}', '\u{00D3}', '\u{00D4}', '\u{0120}', '\u{00D6}', '\u{00D7}',
    '\u{011C}', '\u{00D9}', '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{016C}', '\u{015C}', '\u{00DF}',
    '\u{00E0}', '\u{00E1}', '\u{00E2}', '\u{0000}', '\u{00E4}', '\u{010B}', '\u{0109}', '\u{00E7}',
    '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}', '\u{00EC}', '\u{00ED}', '\u{00EE}', '\u{00EF}',
    '\u{0000}', '\u{00F1}', '\u{00F2}', '\u{00F3}', '\u{00F4}', '\u{0121}', '\u{00F6}', '\u{00F7}',
    '\u{011D}', '\u{00F9}', '\u{00FA}', '\u{00FB}', '\u{00FC}', '\u{016D}', '\u{015D}', '\u{02D9}',
];
const ISO8859_3_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0126}', '\u{0127}'), ('\u{02D8}', '\u{02D8}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0000}', '\u{0000}'), ('\u{0124}', '\u{0125}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{0130}', '\u{0069}'), ('\u{015E}', '\u{015F}'), ('\u{011E}', '\u{011F}'),
    ('\u{0134}', '\u{0135}'), ('\u{00AD}', '\u{00AD}'), ('\u{0000}', '\u{0000}'), ('\u{017B}', '\u{017C}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{0126}', '\u{0127}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{0124}', '\u{0125}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{0049}', '\u{0131}'), ('\u{015E}', '\u{015F}'), ('\u{011E}', '\u{011F}'),
    ('\u{0134}', '\u{0135}'), ('\u{00BD}', '\u{00BD}'), ('\u{0000}', '\u{0000}'), ('\u{017B}', '\u{017C}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{0000}', '\u{0000}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{010A}', '\u{010B}'), ('\u{0108}', '\u{0109}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{0000}', '\u{0000}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{0120}', '\u{0121}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{011C}', '\u{011D}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{016C}', '\u{016D}'), ('\u{015C}', '\u{015D}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{0000}', '\u{0000}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{010A}', '\u{010B}'), ('\u{0108}', '\u{0109}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{0000}', '\u{0000}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{0120}', '\u{0121}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{011C}', '\u{011D}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{016C}', '\u{016D}'), ('\u{015C}', '\u{015D}'), ('\u{02D9}', '\u{02D9}'),
];
const ISO8859_4_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0104}', '\u{0138}', '\u{0156}', '\u{00A4}', '\u{0128}', '\u{013B}', '\u{00A7}',
    '\u{00A8}', '\u{0160}', '\u{0112}', '\u{0122}', '\u{0166}', '\u{00AD}', '\u{017D}', '\u{00AF}',
    '\u{00B0}', '\u{0105}', '\u{02DB}', '\u{0157}', '\u{00B4}', '\u{0129}', '\u{013C}', '\u{02C7}',
    '\u{00B8}', '\u{0161}', '\u{0113}', '\u{0123}', '\u{0167}', '\u{014A}', '\u{017E}', '\u{014B}',
    '\u{0100}', '\u{00C1}', '\u{00C2}', '\u{00C3}', '\u{00C4}', '\u{00C5}', '\u{00C6}', '\u{012E}',
    '\u{010C}', '\u{00C9}', '\u{0118}', '\u{00CB}', '\u{0116}', '\u{00CD}', '\u{00CE}', '\u{012A}',
    '\u{0110}', '\u{0145}', '\u{014C}', '\u{0136}', '\u{00D4}', '\u{00D5}', '\u{00D6}', '\u{00D7}',
    '\u{00D8}', '\u{0172}', '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{0168}', '\u{016A}', '\u{00DF}',
    '\u{0101}', '\u{00E1}', '\u{00E2}', '\u{00E3}', '\u{00E4}', '\u{00E5}', '\u{00E6}', '\u{012F}',
    '\u{010D}', '\u{00E9}', '\u{0119}', '\u{00EB}', '\u{0117}', '\u{00ED}', '\u{00EE}', '\u{012B}',
    '\u{0111}', '\u{0146}', '\u{014D}', '\u{0137}', '\u{00F4}', '\u{00F5}', '\u{00F6}', '\u{00F7}',
    '\u{00F8}', '\u{0173}', '\u{00FA}', '\u{00FB}', '\u{00FC}', '\u{0169}', '\u{016B}', '\u{02D9}',
];
const ISO8859_4_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0104}', '\u{0105}'), ('\u{0138}', '\u{0138}'), ('\u{0156}', '\u{0157}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0128}', '\u{0129}'), ('\u{013B}', '\u{013C}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{0160}', '\u{0161}'), ('\u{0112}', '\u{0113}'), ('\u{0122}', '\u{0123}'),
    ('\u{0166}', '\u{0167}'), ('\u{00AD}', '\u{00AD}'), ('\u{017D}', '\u{017E}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{0104}', '\u{0105}'), ('\u{02DB}', '\u{02DB}'), ('\u{0156}', '\u{0157}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{0128}', '\u{0129}'), ('\u{013B}', '\u{013C}'), ('\u{02C7}', '\u{02C7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{0160}', '\u{0161}'), ('\u{0112}', '\u{0113}'), ('\u{0122}', '\u{0123}'),
    ('\u{0166}', '\u{0167}'), ('\u{014A}', '\u{014B}'), ('\u{017D}', '\u{017E}'), ('\u{014A}', '\u{014B}'),
    ('\u{0100}', '\u{0101}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{012E}', '\u{012F}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{0116}', '\u{0117}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{012A}', '\u{012B}'),
    ('\u{0110}', '\u{0111}'), ('\u{0145}', '\u{0146}'), ('\u{014C}', '\u{014D}'), ('\u{0136}', '\u{0137}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{0172}', '\u{0173}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0168}', '\u{0169}'), ('\u{016A}', '\u{016B}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{0100}', '\u{0101}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{012E}', '\u{012F}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0118}', '\u{0119}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{0116}', '\u{0117}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{012A}', '\u{012B}'),
    ('\u{0110}', '\u{0111}'), ('\u{0145}', '\u{0146}'), ('\u{014C}', '\u{014D}'), ('\u{0136}', '\u{0137}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{0172}', '\u{0173}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0168}', '\u{0169}'), ('\u{016A}', '\u{016B}'), ('\u{02D9}', '\u{02D9}'),
];
const ISO8859_5_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0401}', '\u{0402}', '\u{0403}', '\u{0404}', '\u{0405}', '\u{0406}', '\u{0407}',
    '\u{0408}', '\u{0409}', '\u{040A}', '\u{040B}', '\u{040C}', '\u{00AD}', '\u{040E}', '\u{040F}',
    '\u{0410}', '\u{0411}', '\u{0412}', '\u{0413}', '\u{0414}', '\u{0415}', '\u{0416}', '\u{0417}',
    '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}', '\u{041E}', '\u{041F}',
    '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}', '\u{0424}', '\u{0425}', '\u{0426}', '\u{0427}',
    '\u{0428}', '\u{0429}', '\u{042A}', '\u{042B}', '\u{042C}', '\u{042D}', '\u{042E}', '\u{042F}',
    '\u{0430}', '\u{0431}', '\u{0432}', '\u{0433}', '\u{0434}', '\u{0435}', '\u{0436}', '\u{0437}',
    '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}', '\u{043C}', '\u{043D}', '\u{043E}', '\u{043F}',
    '\u{0440}', '\u{0441}', '\u{0442}', '\u{0443}', '\u{0444}', '\u{0445}', '\u{0446}', '\u{0447}',
    '\u{0448}', '\u{0449}', '\u{044A}', '\u{044B}', '\u{044C}', '\u{044D}', '\u{044E}', '\u{044F}',
    '\u{2116}', '\u{0451}', '\u{0452}', '\u{0453}', '\u{0454}', '\u{0455}', '\u{0456}', '\u{0457}',
    '\u{0458}', '\u{0459}', '\u{045A}', '\u{045B}', '\u{045C}', '\u{00A7}', '\u{045E}', '\u{045F}',
];
const ISO8859_5_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0401}', '\u{0451}'), ('\u{0402}', '\u{0452}'), ('\u{0403}', '\u{0453}'),
    ('\u{0404}', '\u{0454}'), ('\u{0405}', '\u{0455}'), ('\u{0406}', '\u{0456}'), ('\u{0407}', '\u{0457}'),
    ('\u{0408}', '\u{0458}'), ('\u{0409}', '\u{0459}'), ('\u{040A}', '\u{045A}'), ('\u{040B}', '\u{045B}'),
    ('\u{040C}', '\u{045C}'), ('\u{00AD}', '\u{00AD}'), ('\u{040E}', '\u{045E}'), ('\u{040F}', '\u{045F}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{2116}', '\u{2116}'), ('\u{0401}', '\u{0451}'), ('\u{0402}', '\u{0452}'), ('\u{0403}', '\u{0453}'),
    ('\u{0404}', '\u{0454}'), ('\u{0405}', '\u{0455}'), ('\u{0406}', '\u{0456}'), ('\u{0407}', '\u{0457}'),
    ('\u{0408}', '\u{0458}'), ('\u{0409}', '\u{0459}'), ('\u{040A}', '\u{045A}'), ('\u{040B}', '\u{045B}'),
    ('\u{040C}', '\u{045C}'), ('\u{00A7}', '\u{00A7}'), ('\u{040E}', '\u{045E}'), ('\u{040F}', '\u{045F}'),
];
const ISO8859_6_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{00A4}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{060C}', '\u{00AD}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{061B}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{061F}',
    '\u{0000}', '\u{0621}', '\u{0622}', '\u{0623}', '\u{0624}', '\u{0625}', '\u{0626}', '\u{0627}',
    '\u{0628}', '\u{0629}', '\u{062A}', '\u{062B}', '\u{062C}', '\u{062D}', '\u{062E}', '\u{062F}',
    '\u{0630}', '\u{0631}', '\u{0632}', '\u{0633}', '\u{0634}', '\u{0635}', '\u{0636}', '\u{0637}',
    '\u{0638}', '\u{0639}', '\u{063A}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0640}', '\u{0641}', '\u{0642}', '\u{0643}', '\u{0644}', '\u{0645}', '\u{0646}', '\u{0647}',
    '\u{0648}', '\u{0649}', '\u{064A}', '\u{064B}', '\u{064C}', '\u{064D}', '\u{064E}', '\u{064F}',
    '\u{0650}', '\u{0651}', '\u{0652}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
];
const ISO8859_6_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{060C}', '\u{060C}'), ('\u{00AD}', '\u{00AD}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{061B}', '\u{061B}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{061F}', '\u{061F}'),
    ('\u{0000}', '\u{0000}'), ('\u{0621}', '\u{0621}'), ('\u{0622}', '\u{0622}'), ('\u{0623}', '\u{0623}'),
    ('\u{0624}', '\u{0624}'), ('\u{0625}', '\u{0625}'), ('\u{0626}', '\u{0626}'), ('\u{0627}', '\u{0627}'),
    ('\u{0628}', '\u{0628}'), ('\u{0629}', '\u{0629}'), ('\u{062A}', '\u{062A}'), ('\u{062B}', '\u{062B}'),
    ('\u{062C}', '\u{062C}'), ('\u{062D}', '\u{062D}'), ('\u{062E}', '\u{062E}'), ('\u{062F}', '\u{062F}'),
    ('\u{0630}', '\u{0630}'), ('\u{0631}', '\u{0631}'), ('\u{0632}', '\u{0632}'), ('\u{0633}', '\u{0633}'),
    ('\u{0634}', '\u{0634}'), ('\u{0635}', '\u{0635}'), ('\u{0636}', '\u{0636}'), ('\u{0637}', '\u{0637}'),
    ('\u{0638}', '\u{0638}'), ('\u{0639}', '\u{0639}'), ('\u{063A}', '\u{063A}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0640}', '\u{0640}'), ('\u{0641}', '\u{0641}'), ('\u{0642}', '\u{0642}'), ('\u{0643}', '\u{0643}'),
    ('\u{0644}', '\u{0644}'), ('\u{0645}', '\u{0645}'), ('\u{0646}', '\u{0646}'), ('\u{0647}', '\u{0647}'),
    ('\u{0648}', '\u{0648}'), ('\u{0649}', '\u{0649}'), ('\u{064A}', '\u{064A}'), ('\u{064B}', '\u{064B}'),
    ('\u{064C}', '\u{064C}'), ('\u{064D}', '\u{064D}'), ('\u{064E}', '\u{064E}'), ('\u{064F}', '\u{064F}'),
    ('\u{0650}', '\u{0650}'), ('\u{0651}', '\u{0651}'), ('\u{0652}', '\u{0652}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
];
const ISO8859_7_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{02BD}', '\u{02BC}', '\u{00A3}', '\u{0000}', '\u{0000}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{0000}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{0000}', '\u{2015}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{0384}', '\u{0385}', '\u{0386}', '\u{00B7}',
    '\u{0388}', '\u{0389}', '\u{038A}', '\u{00BB}', '\u{038C}', '\u{00BD}', '\u{038E}', '\u{038F}',
    '\u{0390}', '\u{0391}', '\u{0392}', '\u{0393}', '\u{0394}', '\u{0395}', '\u{0396}', '\u{0397}',
    '\u{0398}', '\u{0399}', '\u{039A}', '\u{039B}', '\u{039C}', '\u{039D}', '\u{039E}', '\u{039F}',
    '\u{03A0}', '\u{03A1}', '\u{0000}', '\u{03A3}', '\u{03A4}', '\u{03A5}', '\u{03A6}', '\u{03A7}',
    '\u{03A8}', '\u{03A9}', '\u{03AA}', '\u{03AB}', '\u{03AC}', '\u{03AD}', '\u{03AE}', '\u{03AF}',
    '\u{03B0}', '\u{03B1}', '\u{03B2}', '\u{03B3}', '\u{03B4}', '\u{03B5}', '\u{03B6}', '\u{03B7}',
    '\u{03B8}', '\u{03B9}', '\u{03BA}', '\u{03BB}', '\u{03BC}', '\u{03BD}', '\u{03BE}', '\u{03BF}',
    '\u{03C0}', '\u{03C1}', '\u{03C2}', '\u{03C3}', '\u{03C4}', '\u{03C5}', '\u{03C6}', '\u{03C7}',
    '\u{03C8}', '\u{03C9}', '\u{03CA}', '\u{03CB}', '\u{03CC}', '\u{03CD}', '\u{03CE}', '\u{0000}',
];
const ISO8859_7_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{02BD}', '\u{02BD}'), ('\u{02BC}', '\u{02BC}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{0000}', '\u{0000}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{0000}', '\u{0000}'), ('\u{2015}', '\u{2015}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{0384}', '\u{0384}'), ('\u{0385}', '\u{0385}'), ('\u{0386}', '\u{03AC}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{038C}', '\u{03CC}'), ('\u{00BD}', '\u{00BD}'), ('\u{038E}', '\u{03CD}'), ('\u{038F}', '\u{03CE}'),
    ('\u{0390}', '\u{0390}'), ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'),
    ('\u{0394}', '\u{03B4}'), ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'),
    ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'),
    ('\u{039C}', '\u{03BC}'), ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'),
    ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'), ('\u{0000}', '\u{0000}'), ('\u{03A3}', '\u{03C3}'),
    ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'),
    ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'), ('\u{03AA}', '\u{03CA}'), ('\u{03AB}', '\u{03CB}'),
    ('\u{0386}', '\u{03AC}'), ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'),
    ('\u{03B0}', '\u{03B0}'), ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'),
    ('\u{0394}', '\u{03B4}'), ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'),
    ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'),
    ('\u{039C}', '\u{03BC}'), ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'),
    ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'), ('\u{03A3}', '\u{03C2}'), ('\u{03A3}', '\u{03C3}'),
    ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'),
    ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'), ('\u{03AA}', '\u{03CA}'), ('\u{03AB}', '\u{03CB}'),
    ('\u{038C}', '\u{03CC}'), ('\u{038E}', '\u{03CD}'), ('\u{038F}', '\u{03CE}'), ('\u{0000}', '\u{0000}'),
];
const ISO8859_8_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0000}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{00D7}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{203E}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{00F7}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{2017}',
    '\u{05D0}', '\u{05D1}', '\u{05D2}', '\u{05D3}', '\u{05D4}', '\u{05D5}', '\u{05D6}', '\u{05D7}',
    '\u{05D8}', '\u{05D9}', '\u{05DA}', '\u{05DB}', '\u{05DC}', '\u{05DD}', '\u{05DE}', '\u{05DF}',
    '\u{05E0}', '\u{05E1}', '\u{05E2}', '\u{05E3}', '\u{05E4}', '\u{05E5}', '\u{05E6}', '\u{05E7}',
    '\u{05E8}', '\u{05E9}', '\u{05EA}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
];
const ISO8859_8_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0000}', '\u{0000}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{00D7}', '\u{00D7}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{203E}', '\u{203E}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{00F7}', '\u{00F7}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{2017}', '\u{2017}'),
    ('\u{05D0}', '\u{05D0}'), ('\u{05D1}', '\u{05D1}'), ('\u{05D2}', '\u{05D2}'), ('\u{05D3}', '\u{05D3}'),
    ('\u{05D4}', '\u{05D4}'), ('\u{05D5}', '\u{05D5}'), ('\u{05D6}', '\u{05D6}'), ('\u{05D7}', '\u{05D7}'),
    ('\u{05D8}', '\u{05D8}'), ('\u{05D9}', '\u{05D9}'), ('\u{05DA}', '\u{05DA}'), ('\u{05DB}', '\u{05DB}'),
    ('\u{05DC}', '\u{05DC}'), ('\u{05DD}', '\u{05DD}'), ('\u{05DE}', '\u{05DE}'), ('\u{05DF}', '\u{05DF}'),
    ('\u{05E0}', '\u{05E0}'), ('\u{05E1}', '\u{05E1}'), ('\u{05E2}', '\u{05E2}'), ('\u{05E3}', '\u{05E3}'),
    ('\u{05E4}', '\u{05E4}'), ('\u{05E5}', '\u{05E5}'), ('\u{05E6}', '\u{05E6}'), ('\u{05E7}', '\u{05E7}'),
    ('\u{05E8}', '\u{05E8}'), ('\u{05E9}', '\u{05E9}'), ('\u{05EA}', '\u{05EA}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
];
const ISO8859_9_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{00A1}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{00AA}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00AF}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{00BA}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00BF}',
    '\u{00C0}', '\u{00C1}', '\u{00C2}', '\u{00C3}', '\u{00C4}', '\u{00C5}', '\u{00C6}', '\u{00C7}',
    '\u{00C8}', '\u{00C9}', '\u{00CA}', '\u{00CB}', '\u{00CC}', '\u{00CD}', '\u{00CE}', '\u{00CF}',
    '\u{011E}', '\u{00D1}', '\u{00D2}', '\u{00D3}', '\u{00D4}', '\u{00D5}', '\u{00D6}', '\u{00D7}',
    '\u{00D8}', '\u{00D9}', '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{0130}', '\u{015E}', '\u{00DF}',
    '\u{00E0}', '\u{00E1}', '\u{00E2}', '\u{00E3}', '\u{00E4}', '\u{00E5}', '\u{00E6}', '\u{00E7}',
    '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}', '\u{00EC}', '\u{00ED}', '\u{00EE}', '\u{00EF}',
    '\u{011F}', '\u{00F1}', '\u{00F2}', '\u{00F3}', '\u{00F4}', '\u{00F5}', '\u{00F6}', '\u{00F7}',
    '\u{00F8}', '\u{00F9}', '\u{00FA}', '\u{00FB}', '\u{00FC}', '\u{0131}', '\u{015F}', '\u{00FF}',
];
const ISO8859_9_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{00AA}', '\u{00AA}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{00BA}', '\u{00BA}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00BF}', '\u{00BF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{011E}', '\u{011F}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0130}', '\u{0069}'), ('\u{015E}', '\u{015F}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{011E}', '\u{011F}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0049}', '\u{0131}'), ('\u{015E}', '\u{015F}'), ('\u{00FF}', '\u{00FF}'),
];
const ISO8859_13_HIGH: [char; 128] = [
    '\u{0080}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{0085}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{0091}', '\u{0092}', '\u{0093}', '\u{0094}', '\u{0095}', '\u{0096}', '\u{0097}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{201D}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{201E}', '\u{00A6}', '\u{00A7}',
    '\u{00D8}', '\u{00A9}', '\u{0156}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00C6}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{201C}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00F8}', '\u{00B9}', '\u{0157}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00E6}',
    '\u{0104}', '\u{012E}', '\u{0100}', '\u{0106}', '\u{00C4}', '\u{00C5}', '\u{0118}', '\u{0112}',
    '\u{010C}', '\u{00C9}', '\u{0179}', '\u{0116}', '\u{0122}', '\u{0136}', '\u{012A}', '\u{013B}',
    '\u{0160}', '\u{0143}', '\u{0145}', '\u{00D3}', '\u{014C}', '\u{00D5}', '\u{00D6}', '\u{00D7}',
    '\u{0172}', '\u{0141}', '\u{015A}', '\u{016A}', '\u{00DC}', '\u{017B}', '\u{017D}', '\u{00DF}',
    '\u{0105}', '\u{012F}', '\u{0101}', '\u{0107}', '\u{00E4}', '\u{00E5}', '\u{0119}', '\u{0113}',
    '\u{010D}', '\u{00E9}', '\u{017A}', '\u{0117}', '\u{0123}', '\u{0137}', '\u{012B}', '\u{013C}',
    '\u{0161}', '\u{0144}', '\u{0146}', '\u{00F3}', '\u{014D}', '\u{00F5}', '\u{00F6}', '\u{00F7}',
    '\u{0173}', '\u{0142}', '\u{015B}', '\u{016B}', '\u{00FC}', '\u{017C}', '\u{017E}', '\u{2019}',
];
const ISO8859_13_CASE: [(char, char); 128] = [
    ('\u{0080}', '\u{0080}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{0085}', '\u{0085}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{0091}', '\u{0091}'), ('\u{0092}', '\u{0092}'), ('\u{0093}', '\u{0093}'),
    ('\u{0094}', '\u{0094}'), ('\u{0095}', '\u{0095}'), ('\u{0096}', '\u{0096}'), ('\u{0097}', '\u{0097}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{201D}', '\u{201D}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{201E}', '\u{201E}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00A9}', '\u{00A9}'), ('\u{0156}', '\u{0157}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00C6}', '\u{00E6}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{201C}', '\u{201C}'), (CASE_ERR, '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00B9}', '\u{00B9}'), ('\u{0156}', '\u{0157}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00C6}', '\u{00E6}'),
    ('\u{0104}', '\u{0105}'), ('\u{012E}', '\u{012F}'), ('\u{0100}', '\u{0101}'), ('\u{0106}', '\u{0107}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{0118}', '\u{0119}'), ('\u{0112}', '\u{0113}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0179}', '\u{017A}'), ('\u{0116}', '\u{0117}'),
    ('\u{0122}', '\u{0123}'), ('\u{0136}', '\u{0137}'), ('\u{012A}', '\u{012B}'), ('\u{013B}', '\u{013C}'),
    ('\u{0160}', '\u{0161}'), ('\u{0143}', '\u{0144}'), ('\u{0145}', '\u{0146}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{014C}', '\u{014D}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{0172}', '\u{0173}'), ('\u{0141}', '\u{0142}'), ('\u{015A}', '\u{015B}'), ('\u{016A}', '\u{016B}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{017B}', '\u{017C}'), ('\u{017D}', '\u{017E}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{0104}', '\u{0105}'), ('\u{012E}', '\u{012F}'), ('\u{0100}', '\u{0101}'), ('\u{0106}', '\u{0107}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{0118}', '\u{0119}'), ('\u{0112}', '\u{0113}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0179}', '\u{017A}'), ('\u{0116}', '\u{0117}'),
    ('\u{0122}', '\u{0123}'), ('\u{0136}', '\u{0137}'), ('\u{012A}', '\u{012B}'), ('\u{013B}', '\u{013C}'),
    ('\u{0160}', '\u{0161}'), ('\u{0143}', '\u{0144}'), ('\u{0145}', '\u{0146}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{014C}', '\u{014D}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{0172}', '\u{0173}'), ('\u{0141}', '\u{0142}'), ('\u{015A}', '\u{015B}'), ('\u{016A}', '\u{016B}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{017B}', '\u{017C}'), ('\u{017D}', '\u{017E}'), ('\u{2019}', '\u{2019}'),
];
const DOS852_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{016F}', '\u{0107}', '\u{00E7}',
    '\u{0142}', '\u{00EB}', '\u{0150}', '\u{0151}', '\u{00EE}', '\u{0179}', '\u{00C4}', '\u{0106}',
    '\u{00C9}', '\u{0139}', '\u{013A}', '\u{00F4}', '\u{00F6}', '\u{013D}', '\u{013E}', '\u{015A}',
    '\u{015B}', '\u{00D6}', '\u{00DC}', '\u{0164}', '\u{0165}', '\u{0141}', '\u{00D7}', '\u{010D}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{0104}', '\u{0105}', '\u{017D}', '\u{017E}',
    '\u{0118}', '\u{0119}', '\u{00AC}', '\u{017A}', '\u{010C}', '\u{015F}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{00C1}', '\u{00C2}', '\u{011A}',
    '\u{015E}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{017B}', '\u{017C}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{0102}', '\u{0103}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{00A4}',
    '\u{0111}', '\u{0110}', '\u{010E}', '\u{00CB}', '\u{010F}', '\u{0147}', '\u{00CD}', '\u{00CE}',
    '\u{011B}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{0162}', '\u{016E}', '\u{2580}',
    '\u{00D3}', '\u{00DF}', '\u{00D4}', '\u{0143}', '\u{0144}', '\u{0148}', '\u{0160}', '\u{0161}',
    '\u{0154}', '\u{00DA}', '\u{0155}', '\u{0170}', '\u{00FD}', '\u{00DD}', '\u{0163}', '\u{00B4}',
    '\u{00AD}', '\u{02DD}', '\u{02DB}', '\u{02C7}', '\u{02D8}', '\u{00A7}', '\u{00F7}', '\u{00B8}',
    '\u{00B0}', '\u{00A8}', '\u{02D9}', '\u{0171}', '\u{0158}', '\u{0159}', '\u{25A0}', '\u{00A0}',
];
const DOS852_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{016E}', '\u{016F}'), ('\u{0106}', '\u{0107}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{0141}', '\u{0142}'), ('\u{00CB}', '\u{00EB}'), ('\u{0150}', '\u{0151}'), ('\u{0150}', '\u{0151}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{0179}', '\u{017A}'), ('\u{00C4}', '\u{00E4}'), ('\u{0106}', '\u{0107}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{0139}', '\u{013A}'), ('\u{0139}', '\u{013A}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{013D}', '\u{013E}'), ('\u{013D}', '\u{013E}'), ('\u{015A}', '\u{015B}'),
    ('\u{015A}', '\u{015B}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{0164}', '\u{0165}'),
    ('\u{0164}', '\u{0165}'), ('\u{0141}', '\u{0142}'), ('\u{00D7}', '\u{00D7}'), ('\u{010C}', '\u{010D}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{0104}', '\u{0105}'), ('\u{0104}', '\u{0105}'), ('\u{017D}', '\u{017E}'), ('\u{017D}', '\u{017E}'),
    ('\u{0118}', '\u{0119}'), ('\u{0118}', '\u{0119}'), ('\u{00AC}', '\u{00AC}'), ('\u{0179}', '\u{017A}'),
    ('\u{010C}', '\u{010D}'), ('\u{015E}', '\u{015F}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{011A}', '\u{011B}'),
    ('\u{015E}', '\u{015F}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{017B}', '\u{017C}'), ('\u{017B}', '\u{017C}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{0102}', '\u{0103}'), ('\u{0102}', '\u{0103}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{0110}', '\u{0111}'), ('\u{0110}', '\u{0111}'), ('\u{010E}', '\u{010F}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{010E}', '\u{010F}'), ('\u{0147}', '\u{0148}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{011A}', '\u{011B}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{0162}', '\u{0163}'), ('\u{016E}', '\u{016F}'), ('\u{2580}', '\u{2580}'),
    ('\u{00D3}', '\u{00F3}'), ('\u{00DF}', '\u{00DF}'), ('\u{00D4}', '\u{00F4}'), ('\u{0143}', '\u{0144}'),
    ('\u{0143}', '\u{0144}'), ('\u{0147}', '\u{0148}'), ('\u{0160}', '\u{0161}'), ('\u{0160}', '\u{0161}'),
    ('\u{0154}', '\u{0155}'), ('\u{00DA}', '\u{00FA}'), ('\u{0154}', '\u{0155}'), ('\u{0170}', '\u{0171}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00DD}', '\u{00FD}'), ('\u{0162}', '\u{0163}'), ('\u{00B4}', '\u{00B4}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{02DD}', '\u{02DD}'), ('\u{02DB}', '\u{02DB}'), ('\u{02C7}', '\u{02C7}'),
    ('\u{02D8}', '\u{02D8}'), ('\u{00A7}', '\u{00A7}'), ('\u{00F7}', '\u{00F7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00A8}', '\u{00A8}'), ('\u{02D9}', '\u{02D9}'), ('\u{0170}', '\u{0171}'),
    ('\u{0158}', '\u{0159}'), ('\u{0158}', '\u{0159}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS857_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00EF}', '\u{00EE}', '\u{0131}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00F2}', '\u{00FB}', '\u{00F9}',
    '\u{0130}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{015E}', '\u{015F}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00F1}', '\u{00D1}', '\u{011E}', '\u{011F}',
    '\u{00BF}', '\u{00AE}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{00C1}', '\u{00C2}', '\u{00C0}',
    '\u{00A9}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{00A2}', '\u{00A5}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{00E3}', '\u{00C3}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{00A4}',
    '\u{00BA}', '\u{00AA}', '\u{00CA}', '\u{00CB}', '\u{00C8}', '\u{0000}', '\u{00CD}', '\u{00CE}',
    '\u{00CF}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{00A6}', '\u{00CC}', '\u{2580}',
    '\u{00D3}', '\u{00DF}', '\u{00D4}', '\u{00D2}', '\u{00F5}', '\u{00D5}', '\u{00B5}', '\u{0000}',
    '\u{00D7}', '\u{00DA}', '\u{00DB}', '\u{00D9}', '\u{00EC}', '\u{00FF}', '\u{00AF}', '\u{00B4}',
    '\u{00AD}', '\u{00B1}', '\u{0000}', '\u{00BE}', '\u{00B6}', '\u{00A7}', '\u{00F7}', '\u{00B8}',
    '\u{00B0}', '\u{00A8}', '\u{00B7}', '\u{00B9}', '\u{00B3}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS857_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), ('\u{00C2}', '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C0}', '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'), ('\u{00C8}', '\u{00E8}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{00CE}', '\u{00EE}'), ('\u{0049}', '\u{0131}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), ('\u{00D4}', '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{00D2}', '\u{00F2}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{0130}', '\u{0069}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{015E}', '\u{015F}'), ('\u{015E}', '\u{015F}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00D1}', '\u{00F1}'), ('\u{00D1}', '\u{00F1}'), ('\u{011E}', '\u{011F}'), ('\u{011E}', '\u{011F}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C0}', '\u{00E0}'),
    ('\u{00A9}', '\u{00A9}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A5}', '\u{00A5}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{00C3}', '\u{00E3}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{00A4}', '\u{00A4}'),
    ('\u{00BA}', '\u{00BA}'), ('\u{00AA}', '\u{00AA}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{0000}', '\u{0000}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'),
    ('\u{00CF}', '\u{00EF}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{00A6}', '\u{00A6}'), ('\u{00CC}', '\u{00EC}'), ('\u{2580}', '\u{2580}'),
    ('\u{00D3}', '\u{00F3}'), ('\u{00DF}', '\u{00DF}'), ('\u{00D4}', '\u{00F4}'), ('\u{00D2}', '\u{00F2}'),
    ('\u{00D5}', '\u{00F5}'), ('\u{00D5}', '\u{00F5}'), ('\u{00B5}', '\u{00B5}'), ('\u{0000}', '\u{0000}'),
    ('\u{00D7}', '\u{00D7}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'), ('\u{00D9}', '\u{00F9}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00FF}', '\u{00FF}'), ('\u{00AF}', '\u{00AF}'), ('\u{00B4}', '\u{00B4}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00B1}', '\u{00B1}'), ('\u{0000}', '\u{0000}'), ('\u{00BE}', '\u{00BE}'),
    ('\u{00B6}', '\u{00B6}'), ('\u{00A7}', '\u{00A7}'), ('\u{00F7}', '\u{00F7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00A8}', '\u{00A8}'), ('\u{00B7}', '\u{00B7}'), ('\u{00B9}', '\u{00B9}'),
    ('\u{00B3}', '\u{00B3}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS861_HIGH: [char; 128] = [
    '\u{00C7}', '\u{00FC}', '\u{00E9}', '\u{00E2}', '\u{00E4}', '\u{00E0}', '\u{00E5}', '\u{00E7}',
    '\u{00EA}', '\u{00EB}', '\u{00E8}', '\u{00D0}', '\u{00F0}', '\u{00DE}', '\u{00C4}', '\u{00C5}',
    '\u{00C9}', '\u{00E6}', '\u{00C6}', '\u{00F4}', '\u{00F6}', '\u{00FE}', '\u{00FB}', '\u{00DD}',
    '\u{00FD}', '\u{00D6}', '\u{00DC}', '\u{00F8}', '\u{00A3}', '\u{00D8}', '\u{20A7}', '\u{0192}',
    '\u{00E1}', '\u{00ED}', '\u{00F3}', '\u{00FA}', '\u{00C1}', '\u{00CD}', '\u{00D3}', '\u{00DA}',
    '\u{00BF}', '\u{2310}', '\u{00AC}', '\u{00BD}', '\u{00BC}', '\u{00A1}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{03B1}', '\u{00DF}', '\u{0393}', '\u{03C0}', '\u{03A3}', '\u{03C3}', '\u{00B5}', '\u{03C4}',
    '\u{03A6}', '\u{0398}', '\u{03A9}', '\u{03B4}', '\u{221E}', '\u{03C6}', '\u{03B5}', '\u{2229}',
    '\u{2261}', '\u{00B1}', '\u{2265}', '\u{2264}', '\u{2320}', '\u{2321}', '\u{00F7}', '\u{2248}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{207F}', '\u{00B2}', '\u{25A0}', '\u{00A0}',
];
const DOS861_CASE: [(char, char); 128] = [
    ('\u{00C7}', '\u{00E7}'), ('\u{00DC}', '\u{00FC}'), ('\u{00C9}', '\u{00E9}'), (CASE_ERR, '\u{00E2}'),
    ('\u{00C4}', '\u{00E4}'), (CASE_ERR, '\u{00E0}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C7}', '\u{00E7}'),
    (CASE_ERR, '\u{00EA}'), (CASE_ERR, '\u{00EB}'), (CASE_ERR, '\u{00E8}'), ('\u{00D0}', '\u{00F0}'),
    ('\u{00D0}', '\u{00F0}'), ('\u{00DE}', '\u{00FE}'), ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'),
    ('\u{00C9}', '\u{00E9}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C6}', '\u{00E6}'), (CASE_ERR, '\u{00F4}'),
    ('\u{00D6}', '\u{00F6}'), ('\u{00DE}', '\u{00FE}'), (CASE_ERR, '\u{00FB}'), ('\u{00DD}', '\u{00FD}'),
    ('\u{00DD}', '\u{00FD}'), ('\u{00D6}', '\u{00F6}'), ('\u{00DC}', '\u{00FC}'), ('\u{00D8}', '\u{00F8}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{00D8}', '\u{00F8}'), ('\u{20A7}', '\u{20A7}'), (CASE_ERR, '\u{0192}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00C1}', '\u{00E1}'), ('\u{00CD}', '\u{00ED}'), ('\u{00D3}', '\u{00F3}'), ('\u{00DA}', '\u{00FA}'),
    ('\u{00BF}', '\u{00BF}'), ('\u{2310}', '\u{2310}'), ('\u{00AC}', '\u{00AC}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00A1}', '\u{00A1}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    (CASE_ERR, '\u{03B1}'), ('\u{00DF}', '\u{00DF}'), ('\u{0393}', CASE_ERR), (CASE_ERR, '\u{03C0}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C3}'), ('\u{00B5}', '\u{00B5}'), (CASE_ERR, '\u{03C4}'),
    ('\u{03A6}', '\u{03C6}'), ('\u{0398}', CASE_ERR), ('\u{03A9}', CASE_ERR), (CASE_ERR, '\u{03B4}'),
    ('\u{221E}', '\u{221E}'), ('\u{03A6}', '\u{03C6}'), (CASE_ERR, '\u{03B5}'), ('\u{2229}', '\u{2229}'),
    ('\u{2261}', '\u{2261}'), ('\u{00B1}', '\u{00B1}'), ('\u{2265}', '\u{2265}'), ('\u{2264}', '\u{2264}'),
    ('\u{2320}', '\u{2320}'), ('\u{2321}', '\u{2321}'), ('\u{00F7}', '\u{00F7}'), ('\u{2248}', '\u{2248}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{207F}', '\u{207F}'), ('\u{00B2}', '\u{00B2}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS866_HIGH: [char; 128] = [
    '\u{0410}', '\u{0411}', '\u{0412}', '\u{0413}', '\u{0414}', '\u{0415}', '\u{0416}', '\u{0417}',
    '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}', '\u{041E}', '\u{041F}',
    '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}', '\u{0424}', '\u{0425}', '\u{0426}', '\u{0427}',
    '\u{0428}', '\u{0429}', '\u{042A}', '\u{042B}', '\u{042C}', '\u{042D}', '\u{042E}', '\u{042F}',
    '\u{0430}', '\u{0431}', '\u{0432}', '\u{0433}', '\u{0434}', '\u{0435}', '\u{0436}', '\u{0437}',
    '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}', '\u{043C}', '\u{043D}', '\u{043E}', '\u{043F}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{2561}', '\u{2562}', '\u{2556}',
    '\u{2555}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{255C}', '\u{255B}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{255E}', '\u{255F}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{2567}',
    '\u{2568}', '\u{2564}', '\u{2565}', '\u{2559}', '\u{2558}', '\u{2552}', '\u{2553}', '\u{256B}',
    '\u{256A}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{258C}', '\u{2590}', '\u{2580}',
    '\u{0440}', '\u{0441}', '\u{0442}', '\u{0443}', '\u{0444}', '\u{0445}', '\u{0446}', '\u{0447}',
    '\u{0448}', '\u{0449}', '\u{044A}', '\u{044B}', '\u{044C}', '\u{044D}', '\u{044E}', '\u{044F}',
    '\u{0401}', '\u{0451}', '\u{0404}', '\u{0454}', '\u{0407}', '\u{0457}', '\u{040E}', '\u{045E}',
    '\u{00B0}', '\u{2219}', '\u{00B7}', '\u{221A}', '\u{2116}', '\u{00A4}', '\u{25A0}', '\u{00A0}',
];
const DOS866_CASE: [(char, char); 128] = [
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{2561}', '\u{2561}'), ('\u{2562}', '\u{2562}'), ('\u{2556}', '\u{2556}'),
    ('\u{2555}', '\u{2555}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{255C}', '\u{255C}'), ('\u{255B}', '\u{255B}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{255E}', '\u{255E}'), ('\u{255F}', '\u{255F}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{2567}', '\u{2567}'),
    ('\u{2568}', '\u{2568}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'), ('\u{2559}', '\u{2559}'),
    ('\u{2558}', '\u{2558}'), ('\u{2552}', '\u{2552}'), ('\u{2553}', '\u{2553}'), ('\u{256B}', '\u{256B}'),
    ('\u{256A}', '\u{256A}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'), ('\u{2580}', '\u{2580}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{0401}', '\u{0451}'), ('\u{0401}', '\u{0451}'), ('\u{0404}', '\u{0454}'), ('\u{0404}', '\u{0454}'),
    ('\u{0407}', '\u{0457}'), ('\u{0407}', '\u{0457}'), ('\u{040E}', '\u{045E}'), ('\u{040E}', '\u{045E}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{2219}', '\u{2219}'), ('\u{00B7}', '\u{00B7}'), ('\u{221A}', '\u{221A}'),
    ('\u{2116}', '\u{2116}'), ('\u{00A4}', '\u{00A4}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const DOS869_HIGH: [char; 128] = [
    '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0386}', '\u{0000}',
    '\u{00B7}', '\u{00AC}', '\u{00A6}', '\u{2018}', '\u{2019}', '\u{0388}', '\u{2015}', '\u{0389}',
    '\u{038A}', '\u{03AA}', '\u{038C}', '\u{0000}', '\u{0000}', '\u{038E}', '\u{03AB}', '\u{00A9}',
    '\u{038F}', '\u{00B2}', '\u{00B3}', '\u{03AC}', '\u{00A3}', '\u{03AD}', '\u{03AE}', '\u{03AF}',
    '\u{03CA}', '\u{0390}', '\u{03CC}', '\u{03CD}', '\u{0391}', '\u{0392}', '\u{0393}', '\u{0394}',
    '\u{0395}', '\u{0396}', '\u{0397}', '\u{00BD}', '\u{0398}', '\u{0399}', '\u{00AB}', '\u{00BB}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2502}', '\u{2524}', '\u{039A}', '\u{039B}', '\u{039C}',
    '\u{039D}', '\u{2563}', '\u{2551}', '\u{2557}', '\u{255D}', '\u{039E}', '\u{039F}', '\u{2510}',
    '\u{2514}', '\u{2534}', '\u{252C}', '\u{251C}', '\u{2500}', '\u{253C}', '\u{03A0}', '\u{03A1}',
    '\u{255A}', '\u{2554}', '\u{2569}', '\u{2566}', '\u{2560}', '\u{2550}', '\u{256C}', '\u{03A3}',
    '\u{03A4}', '\u{03A5}', '\u{03A6}', '\u{03A7}', '\u{03A8}', '\u{03A9}', '\u{03B1}', '\u{03B2}',
    '\u{03B3}', '\u{2518}', '\u{250C}', '\u{2588}', '\u{2584}', '\u{03B4}', '\u{03B5}', '\u{2580}',
    '\u{03B6}', '\u{03B7}', '\u{03B8}', '\u{03B9}', '\u{03BA}', '\u{03BB}', '\u{03BC}', '\u{03BD}',
    '\u{03BE}', '\u{03BF}', '\u{03C0}', '\u{03C1}', '\u{03C3}', '\u{03C2}', '\u{03C4}', '\u{0384}',
    '\u{00AD}', '\u{00B1}', '\u{03C5}', '\u{03C6}', '\u{03C7}', '\u{00A7}', '\u{03C8}', '\u{0385}',
    '\u{00B0}', '\u{00A8}', '\u{03C9}', '\u{03CB}', '\u{03B0}', '\u{03CE}', '\u{25A0}', '\u{00A0}',
];
const DOS869_CASE: [(char, char); 128] = [
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0386}', '\u{03AC}'), ('\u{0000}', '\u{0000}'),
    ('\u{00B7}', '\u{00B7}'), ('\u{00AC}', '\u{00AC}'), ('\u{00A6}', '\u{00A6}'), ('\u{2018}', '\u{2018}'),
    ('\u{2019}', '\u{2019}'), ('\u{0388}', '\u{03AD}'), ('\u{2015}', '\u{2015}'), ('\u{0389}', '\u{03AE}'),
    ('\u{038A}', '\u{03AF}'), ('\u{03AA}', '\u{03CA}'), ('\u{038C}', '\u{03CC}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{038E}', '\u{03CD}'), ('\u{03AB}', '\u{03CB}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{038F}', '\u{03CE}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'), ('\u{0386}', '\u{03AC}'),
    ('\u{00A3}', '\u{00A3}'), ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'),
    ('\u{03AA}', '\u{03CA}'), ('\u{0390}', '\u{0390}'), ('\u{038C}', '\u{03CC}'), ('\u{038E}', '\u{03CD}'),
    ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'), ('\u{0394}', '\u{03B4}'),
    ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'), ('\u{00BD}', '\u{00BD}'),
    ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'), ('\u{00AB}', '\u{00AB}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2502}', '\u{2502}'),
    ('\u{2524}', '\u{2524}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'), ('\u{039C}', '\u{03BC}'),
    ('\u{039D}', '\u{03BD}'), ('\u{2563}', '\u{2563}'), ('\u{2551}', '\u{2551}'), ('\u{2557}', '\u{2557}'),
    ('\u{255D}', '\u{255D}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2534}', '\u{2534}'), ('\u{252C}', '\u{252C}'), ('\u{251C}', '\u{251C}'),
    ('\u{2500}', '\u{2500}'), ('\u{253C}', '\u{253C}'), ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'),
    ('\u{255A}', '\u{255A}'), ('\u{2554}', '\u{2554}'), ('\u{2569}', '\u{2569}'), ('\u{2566}', '\u{2566}'),
    ('\u{2560}', '\u{2560}'), ('\u{2550}', '\u{2550}'), ('\u{256C}', '\u{256C}'), ('\u{03A3}', '\u{03C3}'),
    ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'),
    ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'), ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'),
    ('\u{0393}', '\u{03B3}'), ('\u{2518}', '\u{2518}'), ('\u{250C}', '\u{250C}'), ('\u{2588}', '\u{2588}'),
    ('\u{2584}', '\u{2584}'), ('\u{0394}', '\u{03B4}'), ('\u{0395}', '\u{03B5}'), ('\u{2580}', '\u{2580}'),
    ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'), ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'),
    ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'), ('\u{039C}', '\u{03BC}'), ('\u{039D}', '\u{03BD}'),
    ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'), ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'),
    ('\u{03A3}', '\u{03C3}'), ('\u{03A3}', '\u{03C2}'), ('\u{03A4}', '\u{03C4}'), ('\u{0384}', '\u{0384}'),
    ('\u{00AD}', '\u{00AD}'), ('\u{00B1}', '\u{00B1}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'),
    ('\u{03A7}', '\u{03C7}'), ('\u{00A7}', '\u{00A7}'), ('\u{03A8}', '\u{03C8}'), ('\u{0385}', '\u{0385}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00A8}', '\u{00A8}'), ('\u{03A9}', '\u{03C9}'), ('\u{03AB}', '\u{03CB}'),
    ('\u{03B0}', '\u{03B0}'), ('\u{038F}', '\u{03CE}'), ('\u{25A0}', '\u{25A0}'), ('\u{00A0}', '\u{00A0}'),
];
const CYRL_HIGH: [char; 128] = [
    '\u{0402}', '\u{0403}', '\u{201A}', '\u{0453}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{20AC}', '\u{2030}', '\u{0409}', '\u{2039}', '\u{040A}', '\u{040C}', '\u{040B}', '\u{040F}',
    '\u{0452}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0000}', '\u{2122}', '\u{0459}', '\u{203A}', '\u{045A}', '\u{045C}', '\u{045B}', '\u{045F}',
    '\u{00A0}', '\u{040E}', '\u{045E}', '\u{0408}', '\u{00A4}', '\u{0490}', '\u{00A6}', '\u{00A7}',
    '\u{0401}', '\u{00A9}', '\u{0404}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{0407}',
    '\u{00B0}', '\u{00B1}', '\u{0406}', '\u{0456}', '\u{0491}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{0451}', '\u{2116}', '\u{0454}', '\u{00BB}', '\u{0458}', '\u{0405}', '\u{0455}', '\u{0457}',
    '\u{0410}', '\u{0411}', '\u{0412}', '\u{0413}', '\u{0414}', '\u{0415}', '\u{0416}', '\u{0417}',
    '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}', '\u{041E}', '\u{041F}',
    '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}', '\u{0424}', '\u{0425}', '\u{0426}', '\u{0427}',
    '\u{0428}', '\u{0429}', '\u{042A}', '\u{042B}', '\u{042C}', '\u{042D}', '\u{042E}', '\u{042F}',
    '\u{0430}', '\u{0431}', '\u{0432}', '\u{0433}', '\u{0434}', '\u{0435}', '\u{0436}', '\u{0437}',
    '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}', '\u{043C}', '\u{043D}', '\u{043E}', '\u{043F}',
    '\u{0440}', '\u{0441}', '\u{0442}', '\u{0443}', '\u{0444}', '\u{0445}', '\u{0446}', '\u{0447}',
    '\u{0448}', '\u{0449}', '\u{044A}', '\u{044B}', '\u{044C}', '\u{044D}', '\u{044E}', '\u{044F}',
];
const CYRL_CASE: [(char, char); 128] = [
    ('\u{0402}', '\u{0452}'), ('\u{0403}', '\u{0453}'), ('\u{201A}', '\u{201A}'), ('\u{0403}', '\u{0453}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{20AC}', '\u{20AC}'), ('\u{2030}', '\u{2030}'), ('\u{0409}', '\u{0459}'), ('\u{2039}', '\u{2039}'),
    ('\u{040A}', '\u{045A}'), ('\u{040C}', '\u{045C}'), ('\u{040B}', '\u{045B}'), ('\u{040F}', '\u{045F}'),
    ('\u{0402}', '\u{0452}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0000}', '\u{0000}'), ('\u{2122}', '\u{2122}'), ('\u{0409}', '\u{0459}'), ('\u{203A}', '\u{203A}'),
    ('\u{040A}', '\u{045A}'), ('\u{040C}', '\u{045C}'), ('\u{040B}', '\u{045B}'), ('\u{040F}', '\u{045F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{040E}', '\u{045E}'), ('\u{040E}', '\u{045E}'), ('\u{0408}', '\u{0458}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0490}', '\u{0491}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{0401}', '\u{0451}'), ('\u{00A9}', '\u{00A9}'), ('\u{0404}', '\u{0454}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{0407}', '\u{0457}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{0406}', '\u{0456}'), ('\u{0406}', '\u{0456}'),
    ('\u{0490}', '\u{0491}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{0401}', '\u{0451}'), ('\u{2116}', '\u{2116}'), ('\u{0404}', '\u{0454}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{0408}', '\u{0458}'), ('\u{0405}', '\u{0455}'), ('\u{0405}', '\u{0455}'), ('\u{0407}', '\u{0457}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
    ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0412}', '\u{0432}'), ('\u{0413}', '\u{0433}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0416}', '\u{0436}'), ('\u{0417}', '\u{0437}'),
    ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'), ('\u{041B}', '\u{043B}'),
    ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'), ('\u{041F}', '\u{043F}'),
    ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'), ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'),
    ('\u{0424}', '\u{0444}'), ('\u{0425}', '\u{0445}'), ('\u{0426}', '\u{0446}'), ('\u{0427}', '\u{0447}'),
    ('\u{0428}', '\u{0448}'), ('\u{0429}', '\u{0449}'), ('\u{042A}', '\u{044A}'), ('\u{042B}', '\u{044B}'),
    ('\u{042C}', '\u{044C}'), ('\u{042D}', '\u{044D}'), ('\u{042E}', '\u{044E}'), ('\u{042F}', '\u{044F}'),
];
const WIN1253_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0000}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{0000}', '\u{2030}', '\u{0000}', '\u{2039}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0000}', '\u{2122}', '\u{0000}', '\u{203A}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{00A0}', '\u{0385}', '\u{0386}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{0000}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{2015}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{0384}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{0388}', '\u{0389}', '\u{038A}', '\u{00BB}', '\u{038C}', '\u{00BD}', '\u{038E}', '\u{038F}',
    '\u{0390}', '\u{0391}', '\u{0392}', '\u{0393}', '\u{0394}', '\u{0395}', '\u{0396}', '\u{0397}',
    '\u{0398}', '\u{0399}', '\u{039A}', '\u{039B}', '\u{039C}', '\u{039D}', '\u{039E}', '\u{039F}',
    '\u{03A0}', '\u{03A1}', '\u{0000}', '\u{03A3}', '\u{03A4}', '\u{03A5}', '\u{03A6}', '\u{03A7}',
    '\u{03A8}', '\u{03A9}', '\u{03AA}', '\u{03AB}', '\u{03AC}', '\u{03AD}', '\u{03AE}', '\u{03AF}',
    '\u{03B0}', '\u{03B1}', '\u{03B2}', '\u{03B3}', '\u{03B4}', '\u{03B5}', '\u{03B6}', '\u{03B7}',
    '\u{03B8}', '\u{03B9}', '\u{03BA}', '\u{03BB}', '\u{03BC}', '\u{03BD}', '\u{03BE}', '\u{03BF}',
    '\u{03C0}', '\u{03C1}', '\u{03C2}', '\u{03C3}', '\u{03C4}', '\u{03C5}', '\u{03C6}', '\u{03C7}',
    '\u{03C8}', '\u{03C9}', '\u{03CA}', '\u{03CB}', '\u{03CC}', '\u{03CD}', '\u{03CE}', '\u{0000}',
];
const WIN1253_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'), (CASE_ERR, '\u{0192}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{0000}', '\u{0000}'), ('\u{2030}', '\u{2030}'), ('\u{0000}', '\u{0000}'), ('\u{2039}', '\u{2039}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0000}', '\u{0000}'), ('\u{2122}', '\u{2122}'), ('\u{0000}', '\u{0000}'), ('\u{203A}', '\u{203A}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0385}', '\u{0385}'), ('\u{0386}', '\u{03AC}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{0000}', '\u{0000}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{2015}', '\u{2015}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{0384}', '\u{0384}'), ('\u{039C}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{038C}', '\u{03CC}'), ('\u{00BD}', '\u{00BD}'), ('\u{038E}', '\u{03CD}'), ('\u{038F}', '\u{03CE}'),
    ('\u{0390}', '\u{0390}'), ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'),
    ('\u{0394}', '\u{03B4}'), ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'),
    ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'),
    ('\u{039C}', '\u{03BC}'), ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'),
    ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'), ('\u{0000}', '\u{0000}'), ('\u{03A3}', '\u{03C3}'),
    ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'),
    ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'), ('\u{03AA}', '\u{03CA}'), ('\u{03AB}', '\u{03CB}'),
    ('\u{0386}', '\u{03AC}'), ('\u{0388}', '\u{03AD}'), ('\u{0389}', '\u{03AE}'), ('\u{038A}', '\u{03AF}'),
    ('\u{03B0}', '\u{03B0}'), ('\u{0391}', '\u{03B1}'), ('\u{0392}', '\u{03B2}'), ('\u{0393}', '\u{03B3}'),
    ('\u{0394}', '\u{03B4}'), ('\u{0395}', '\u{03B5}'), ('\u{0396}', '\u{03B6}'), ('\u{0397}', '\u{03B7}'),
    ('\u{0398}', '\u{03B8}'), ('\u{0399}', '\u{03B9}'), ('\u{039A}', '\u{03BA}'), ('\u{039B}', '\u{03BB}'),
    ('\u{039C}', '\u{03BC}'), ('\u{039D}', '\u{03BD}'), ('\u{039E}', '\u{03BE}'), ('\u{039F}', '\u{03BF}'),
    ('\u{03A0}', '\u{03C0}'), ('\u{03A1}', '\u{03C1}'), ('\u{03A3}', '\u{03C2}'), ('\u{03A3}', '\u{03C3}'),
    ('\u{03A4}', '\u{03C4}'), ('\u{03A5}', '\u{03C5}'), ('\u{03A6}', '\u{03C6}'), ('\u{03A7}', '\u{03C7}'),
    ('\u{03A8}', '\u{03C8}'), ('\u{03A9}', '\u{03C9}'), ('\u{03AA}', '\u{03CA}'), ('\u{03AB}', '\u{03CB}'),
    ('\u{038C}', '\u{03CC}'), ('\u{038E}', '\u{03CD}'), ('\u{038F}', '\u{03CE}'), ('\u{0000}', '\u{0000}'),
];
const WIN1254_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0000}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{02C6}', '\u{2030}', '\u{0160}', '\u{2039}', '\u{0152}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{02DC}', '\u{2122}', '\u{0161}', '\u{203A}', '\u{0153}', '\u{0000}', '\u{0000}', '\u{0178}',
    '\u{00A0}', '\u{00A1}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{00AA}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00AF}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{00BA}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00BF}',
    '\u{00C0}', '\u{00C1}', '\u{00C2}', '\u{00C3}', '\u{00C4}', '\u{00C5}', '\u{00C6}', '\u{00C7}',
    '\u{00C8}', '\u{00C9}', '\u{00CA}', '\u{00CB}', '\u{00CC}', '\u{00CD}', '\u{00CE}', '\u{00CF}',
    '\u{011E}', '\u{00D1}', '\u{00D2}', '\u{00D3}', '\u{00D4}', '\u{00D5}', '\u{00D6}', '\u{00D7}',
    '\u{00D8}', '\u{00D9}', '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{0130}', '\u{015E}', '\u{00DF}',
    '\u{00E0}', '\u{00E1}', '\u{00E2}', '\u{00E3}', '\u{00E4}', '\u{00E5}', '\u{00E6}', '\u{00E7}',
    '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}', '\u{00EC}', '\u{00ED}', '\u{00EE}', '\u{00EF}',
    '\u{011F}', '\u{00F1}', '\u{00F2}', '\u{00F3}', '\u{00F4}', '\u{00F5}', '\u{00F6}', '\u{00F7}',
    '\u{00F8}', '\u{00F9}', '\u{00FA}', '\u{00FB}', '\u{00FC}', '\u{0131}', '\u{015F}', '\u{00FF}',
];
const WIN1254_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'), (CASE_ERR, '\u{0192}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{02C6}', '\u{02C6}'), ('\u{2030}', '\u{2030}'), ('\u{0160}', '\u{0161}'), ('\u{2039}', '\u{2039}'),
    ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{02DC}', '\u{02DC}'), ('\u{2122}', '\u{2122}'), ('\u{0160}', '\u{0161}'), ('\u{203A}', '\u{203A}'),
    ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0178}', '\u{00FF}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{00AA}', '\u{00AA}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{00BA}', '\u{00BA}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00BF}', '\u{00BF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{011E}', '\u{011F}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0130}', '\u{0069}'), ('\u{015E}', '\u{015F}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{00C3}', '\u{00E3}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{00CC}', '\u{00EC}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{011E}', '\u{011F}'), ('\u{00D1}', '\u{00F1}'), ('\u{00D2}', '\u{00F2}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{0049}', '\u{0131}'), ('\u{015E}', '\u{015F}'), ('\u{0178}', '\u{00FF}'),
];
const WIN1255_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0000}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{02C6}', '\u{2030}', '\u{0000}', '\u{2039}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{02DC}', '\u{2122}', '\u{0000}', '\u{203A}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{00A0}', '\u{00A1}', '\u{00A2}', '\u{00A3}', '\u{20AA}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{00D7}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00AF}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{00F7}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00BF}',
    '\u{05B0}', '\u{05B1}', '\u{05B2}', '\u{05B3}', '\u{05B4}', '\u{05B5}', '\u{05B6}', '\u{05B7}',
    '\u{05B8}', '\u{05B9}', '\u{0000}', '\u{05BB}', '\u{05BC}', '\u{05BD}', '\u{05BE}', '\u{05BF}',
    '\u{05C0}', '\u{05C1}', '\u{05C2}', '\u{05C3}', '\u{05F0}', '\u{05F1}', '\u{05F2}', '\u{05F3}',
    '\u{05F4}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{05D0}', '\u{05D1}', '\u{05D2}', '\u{05D3}', '\u{05D4}', '\u{05D5}', '\u{05D6}', '\u{05D7}',
    '\u{05D8}', '\u{05D9}', '\u{05DA}', '\u{05DB}', '\u{05DC}', '\u{05DD}', '\u{05DE}', '\u{05DF}',
    '\u{05E0}', '\u{05E1}', '\u{05E2}', '\u{05E3}', '\u{05E4}', '\u{05E5}', '\u{05E6}', '\u{05E7}',
    '\u{05E8}', '\u{05E9}', '\u{05EA}', '\u{0000}', '\u{0000}', '\u{200E}', '\u{200F}', '\u{0000}',
];
const WIN1255_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'), (CASE_ERR, '\u{0192}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{02C6}', '\u{02C6}'), ('\u{2030}', '\u{2030}'), ('\u{0000}', '\u{0000}'), ('\u{2039}', '\u{2039}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{02DC}', '\u{02DC}'), ('\u{2122}', '\u{2122}'), ('\u{0000}', '\u{0000}'), ('\u{203A}', '\u{203A}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{20AA}', '\u{20AA}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{00D7}', '\u{00D7}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{00F7}', '\u{00F7}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00BF}', '\u{00BF}'),
    ('\u{05B0}', '\u{05B0}'), ('\u{05B1}', '\u{05B1}'), ('\u{05B2}', '\u{05B2}'), ('\u{05B3}', '\u{05B3}'),
    ('\u{05B4}', '\u{05B4}'), ('\u{05B5}', '\u{05B5}'), ('\u{05B6}', '\u{05B6}'), ('\u{05B7}', '\u{05B7}'),
    ('\u{05B8}', '\u{05B8}'), ('\u{05B9}', '\u{05B9}'), ('\u{0000}', '\u{0000}'), ('\u{05BB}', '\u{05BB}'),
    ('\u{05BC}', '\u{05BC}'), ('\u{05BD}', '\u{05BD}'), ('\u{05BE}', '\u{05BE}'), ('\u{05BF}', '\u{05BF}'),
    ('\u{05C0}', '\u{05C0}'), ('\u{05C1}', '\u{05C1}'), ('\u{05C2}', '\u{05C2}'), ('\u{05C3}', '\u{05C3}'),
    ('\u{05F0}', '\u{05F0}'), ('\u{05F1}', '\u{05F1}'), ('\u{05F2}', '\u{05F2}'), ('\u{05F3}', '\u{05F3}'),
    ('\u{05F4}', '\u{05F4}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{05D0}', '\u{05D0}'), ('\u{05D1}', '\u{05D1}'), ('\u{05D2}', '\u{05D2}'), ('\u{05D3}', '\u{05D3}'),
    ('\u{05D4}', '\u{05D4}'), ('\u{05D5}', '\u{05D5}'), ('\u{05D6}', '\u{05D6}'), ('\u{05D7}', '\u{05D7}'),
    ('\u{05D8}', '\u{05D8}'), ('\u{05D9}', '\u{05D9}'), ('\u{05DA}', '\u{05DA}'), ('\u{05DB}', '\u{05DB}'),
    ('\u{05DC}', '\u{05DC}'), ('\u{05DD}', '\u{05DD}'), ('\u{05DE}', '\u{05DE}'), ('\u{05DF}', '\u{05DF}'),
    ('\u{05E0}', '\u{05E0}'), ('\u{05E1}', '\u{05E1}'), ('\u{05E2}', '\u{05E2}'), ('\u{05E3}', '\u{05E3}'),
    ('\u{05E4}', '\u{05E4}'), ('\u{05E5}', '\u{05E5}'), ('\u{05E6}', '\u{05E6}'), ('\u{05E7}', '\u{05E7}'),
    ('\u{05E8}', '\u{05E8}'), ('\u{05E9}', '\u{05E9}'), ('\u{05EA}', '\u{05EA}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), ('\u{200E}', '\u{200E}'), ('\u{200F}', '\u{200F}'), ('\u{0000}', '\u{0000}'),
];
const WIN1256_HIGH: [char; 128] = [
    '\u{20AC}', '\u{067E}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{02C6}', '\u{2030}', '\u{0679}', '\u{2039}', '\u{0152}', '\u{0686}', '\u{0698}', '\u{0688}',
    '\u{06AF}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{06A9}', '\u{2122}', '\u{0691}', '\u{203A}', '\u{0153}', '\u{200C}', '\u{200D}', '\u{06BA}',
    '\u{00A0}', '\u{060C}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{06BE}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00AF}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{061B}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{061F}',
    '\u{06C1}', '\u{0621}', '\u{0622}', '\u{0623}', '\u{0624}', '\u{0625}', '\u{0626}', '\u{0627}',
    '\u{0628}', '\u{0629}', '\u{062A}', '\u{062B}', '\u{062C}', '\u{062D}', '\u{062E}', '\u{062F}',
    '\u{0630}', '\u{0631}', '\u{0632}', '\u{0633}', '\u{0634}', '\u{0635}', '\u{0636}', '\u{00D7}',
    '\u{0637}', '\u{0638}', '\u{0639}', '\u{063A}', '\u{0640}', '\u{0641}', '\u{0642}', '\u{0643}',
    '\u{00E0}', '\u{0644}', '\u{00E2}', '\u{0645}', '\u{0646}', '\u{0647}', '\u{0648}', '\u{00E7}',
    '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}', '\u{0649}', '\u{064A}', '\u{00EE}', '\u{00EF}',
    '\u{064B}', '\u{064C}', '\u{064D}', '\u{064E}', '\u{00F4}', '\u{064F}', '\u{0650}', '\u{00F7}',
    '\u{0651}', '\u{00F9}', '\u{0652}', '\u{00FB}', '\u{00FC}', '\u{200E}', '\u{200F}', '\u{06D2}',
];
const WIN1256_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{067E}', '\u{067E}'), ('\u{201A}', '\u{201A}'), (CASE_ERR, '\u{0192}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{02C6}', '\u{02C6}'), ('\u{2030}', '\u{2030}'), ('\u{0679}', '\u{0679}'), ('\u{2039}', '\u{2039}'),
    ('\u{0152}', '\u{0153}'), ('\u{0686}', '\u{0686}'), ('\u{0698}', '\u{0698}'), ('\u{0688}', '\u{0688}'),
    ('\u{06AF}', '\u{06AF}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{06A9}', '\u{06A9}'), ('\u{2122}', '\u{2122}'), ('\u{0691}', '\u{0691}'), ('\u{203A}', '\u{203A}'),
    ('\u{0152}', '\u{0153}'), ('\u{200C}', '\u{200C}'), ('\u{200D}', '\u{200D}'), ('\u{06BA}', '\u{06BA}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{060C}', '\u{060C}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{06BE}', '\u{06BE}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{061B}', '\u{061B}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{061F}', '\u{061F}'),
    ('\u{06C1}', '\u{06C1}'), ('\u{0621}', '\u{0621}'), ('\u{0622}', '\u{0622}'), ('\u{0623}', '\u{0623}'),
    ('\u{0624}', '\u{0624}'), ('\u{0625}', '\u{0625}'), ('\u{0626}', '\u{0626}'), ('\u{0627}', '\u{0627}'),
    ('\u{0628}', '\u{0628}'), ('\u{0629}', '\u{0629}'), ('\u{062A}', '\u{062A}'), ('\u{062B}', '\u{062B}'),
    ('\u{062C}', '\u{062C}'), ('\u{062D}', '\u{062D}'), ('\u{062E}', '\u{062E}'), ('\u{062F}', '\u{062F}'),
    ('\u{0630}', '\u{0630}'), ('\u{0631}', '\u{0631}'), ('\u{0632}', '\u{0632}'), ('\u{0633}', '\u{0633}'),
    ('\u{0634}', '\u{0634}'), ('\u{0635}', '\u{0635}'), ('\u{0636}', '\u{0636}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{0637}', '\u{0637}'), ('\u{0638}', '\u{0638}'), ('\u{0639}', '\u{0639}'), ('\u{063A}', '\u{063A}'),
    ('\u{0640}', '\u{0640}'), ('\u{0641}', '\u{0641}'), ('\u{0642}', '\u{0642}'), ('\u{0643}', '\u{0643}'),
    (CASE_ERR, '\u{00E0}'), ('\u{0644}', '\u{0644}'), (CASE_ERR, '\u{00E2}'), ('\u{0645}', '\u{0645}'),
    ('\u{0646}', '\u{0646}'), ('\u{0647}', '\u{0647}'), ('\u{0648}', '\u{0648}'), (CASE_ERR, '\u{00E7}'),
    (CASE_ERR, '\u{00E8}'), (CASE_ERR, '\u{00E9}'), (CASE_ERR, '\u{00EA}'), (CASE_ERR, '\u{00EB}'),
    ('\u{0649}', '\u{0649}'), ('\u{064A}', '\u{064A}'), (CASE_ERR, '\u{00EE}'), (CASE_ERR, '\u{00EF}'),
    ('\u{064B}', '\u{064B}'), ('\u{064C}', '\u{064C}'), ('\u{064D}', '\u{064D}'), ('\u{064E}', '\u{064E}'),
    (CASE_ERR, '\u{00F4}'), ('\u{064F}', '\u{064F}'), ('\u{0650}', '\u{0650}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{0651}', '\u{0651}'), (CASE_ERR, '\u{00F9}'), ('\u{0652}', '\u{0652}'), (CASE_ERR, '\u{00FB}'),
    (CASE_ERR, '\u{00FC}'), ('\u{200E}', '\u{200E}'), ('\u{200F}', '\u{200F}'), ('\u{06D2}', '\u{06D2}'),
];
const WIN1257_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0000}', '\u{201A}', '\u{0000}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{0000}', '\u{2030}', '\u{0000}', '\u{2039}', '\u{0000}', '\u{00A8}', '\u{02C7}', '\u{00B8}',
    '\u{0000}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0000}', '\u{2122}', '\u{0000}', '\u{203A}', '\u{0000}', '\u{00AF}', '\u{02DB}', '\u{0000}',
    '\u{00A0}', '\u{0000}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{0000}', '\u{00A6}', '\u{00A7}',
    '\u{00D8}', '\u{00A9}', '\u{0156}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00C6}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00F8}', '\u{00B9}', '\u{0157}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00E6}',
    '\u{0104}', '\u{012E}', '\u{0100}', '\u{0106}', '\u{00C4}', '\u{00C5}', '\u{0118}', '\u{0112}',
    '\u{010C}', '\u{00C9}', '\u{0179}', '\u{0116}', '\u{0122}', '\u{0136}', '\u{012A}', '\u{013B}',
    '\u{0160}', '\u{0143}', '\u{0145}', '\u{00D3}', '\u{014C}', '\u{00D5}', '\u{00D6}', '\u{00D7}',
    '\u{0172}', '\u{0141}', '\u{015A}', '\u{016A}', '\u{00DC}', '\u{017B}', '\u{017D}', '\u{00DF}',
    '\u{0105}', '\u{012F}', '\u{0101}', '\u{0107}', '\u{00E4}', '\u{00E5}', '\u{0119}', '\u{0113}',
    '\u{010D}', '\u{00E9}', '\u{017A}', '\u{0117}', '\u{0123}', '\u{0137}', '\u{012B}', '\u{013C}',
    '\u{0161}', '\u{0144}', '\u{0146}', '\u{00F3}', '\u{014D}', '\u{00F5}', '\u{00F6}', '\u{00F7}',
    '\u{0173}', '\u{0142}', '\u{015B}', '\u{016B}', '\u{00FC}', '\u{017C}', '\u{017E}', '\u{02D9}',
];
const WIN1257_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0000}', '\u{0000}'), ('\u{201A}', '\u{201A}'), ('\u{0000}', '\u{0000}'),
    ('\u{201E}', '\u{201E}'), ('\u{2026}', '\u{2026}'), ('\u{2020}', '\u{2020}'), ('\u{2021}', '\u{2021}'),
    ('\u{0000}', '\u{0000}'), ('\u{2030}', '\u{2030}'), ('\u{0000}', '\u{0000}'), ('\u{2039}', '\u{2039}'),
    ('\u{0000}', '\u{0000}'), ('\u{00A8}', '\u{00A8}'), ('\u{02C7}', '\u{02C7}'), ('\u{00B8}', '\u{00B8}'),
    ('\u{0000}', '\u{0000}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0000}', '\u{0000}'), ('\u{2122}', '\u{2122}'), ('\u{0000}', '\u{0000}'), ('\u{203A}', '\u{203A}'),
    ('\u{0000}', '\u{0000}'), ('\u{00AF}', '\u{00AF}'), ('\u{02DB}', '\u{02DB}'), ('\u{0000}', '\u{0000}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0000}', '\u{0000}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{0000}', '\u{0000}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00A9}', '\u{00A9}'), ('\u{0156}', '\u{0157}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00C6}', '\u{00E6}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00B9}', '\u{00B9}'), ('\u{0156}', '\u{0157}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00C6}', '\u{00E6}'),
    ('\u{0104}', '\u{0105}'), ('\u{012E}', '\u{012F}'), ('\u{0100}', '\u{0101}'), ('\u{0106}', '\u{0107}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{0118}', '\u{0119}'), ('\u{0112}', '\u{0113}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0179}', '\u{017A}'), ('\u{0116}', '\u{0117}'),
    ('\u{0122}', '\u{0123}'), ('\u{0136}', '\u{0137}'), ('\u{012A}', '\u{012B}'), ('\u{013B}', '\u{013C}'),
    ('\u{0160}', '\u{0161}'), ('\u{0143}', '\u{0144}'), ('\u{0145}', '\u{0146}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{014C}', '\u{014D}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{0172}', '\u{0173}'), ('\u{0141}', '\u{0142}'), ('\u{015A}', '\u{015B}'), ('\u{016A}', '\u{016B}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{017B}', '\u{017C}'), ('\u{017D}', '\u{017E}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{0104}', '\u{0105}'), ('\u{012E}', '\u{012F}'), ('\u{0100}', '\u{0101}'), ('\u{0106}', '\u{0107}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{0118}', '\u{0119}'), ('\u{0112}', '\u{0113}'),
    ('\u{010C}', '\u{010D}'), ('\u{00C9}', '\u{00E9}'), ('\u{0179}', '\u{017A}'), ('\u{0116}', '\u{0117}'),
    ('\u{0122}', '\u{0123}'), ('\u{0136}', '\u{0137}'), ('\u{012A}', '\u{012B}'), ('\u{013B}', '\u{013C}'),
    ('\u{0160}', '\u{0161}'), ('\u{0143}', '\u{0144}'), ('\u{0145}', '\u{0146}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{014C}', '\u{014D}'), ('\u{00D5}', '\u{00F5}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{0172}', '\u{0173}'), ('\u{0141}', '\u{0142}'), ('\u{015A}', '\u{015B}'), ('\u{016A}', '\u{016B}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{017B}', '\u{017C}'), ('\u{017D}', '\u{017E}'), ('\u{02D9}', '\u{02D9}'),
];
const KOI8R_HIGH: [char; 128] = [
    '\u{2500}', '\u{2502}', '\u{250C}', '\u{2510}', '\u{2514}', '\u{2518}', '\u{251C}', '\u{2524}',
    '\u{252C}', '\u{2534}', '\u{253C}', '\u{2580}', '\u{2584}', '\u{2588}', '\u{258C}', '\u{2590}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2320}', '\u{25A0}', '\u{2219}', '\u{221A}', '\u{2248}',
    '\u{2264}', '\u{2265}', '\u{00A0}', '\u{2321}', '\u{00B0}', '\u{00B2}', '\u{00B7}', '\u{00F7}',
    '\u{2550}', '\u{2551}', '\u{2552}', '\u{0451}', '\u{2553}', '\u{2554}', '\u{2555}', '\u{2556}',
    '\u{2557}', '\u{2558}', '\u{2559}', '\u{255A}', '\u{255B}', '\u{255C}', '\u{255D}', '\u{255E}',
    '\u{255F}', '\u{2560}', '\u{2561}', '\u{0401}', '\u{2562}', '\u{2563}', '\u{2564}', '\u{2565}',
    '\u{2566}', '\u{2567}', '\u{2568}', '\u{2569}', '\u{256A}', '\u{256B}', '\u{256C}', '\u{00A9}',
    '\u{044E}', '\u{0430}', '\u{0431}', '\u{0446}', '\u{0434}', '\u{0435}', '\u{0444}', '\u{0433}',
    '\u{0445}', '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}', '\u{043C}', '\u{043D}', '\u{043E}',
    '\u{043F}', '\u{044F}', '\u{0440}', '\u{0441}', '\u{0442}', '\u{0443}', '\u{0436}', '\u{0432}',
    '\u{044C}', '\u{044B}', '\u{0437}', '\u{0448}', '\u{044D}', '\u{0449}', '\u{0447}', '\u{044A}',
    '\u{042E}', '\u{0410}', '\u{0411}', '\u{0426}', '\u{0414}', '\u{0415}', '\u{0424}', '\u{0413}',
    '\u{0425}', '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}', '\u{041E}',
    '\u{041F}', '\u{042F}', '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}', '\u{0416}', '\u{0412}',
    '\u{042C}', '\u{042B}', '\u{0417}', '\u{0428}', '\u{042D}', '\u{0429}', '\u{0427}', '\u{042A}',
];
const KOI8R_CASE: [(char, char); 128] = [
    ('\u{2500}', '\u{2500}'), ('\u{2502}', '\u{2502}'), ('\u{250C}', '\u{250C}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2518}', '\u{2518}'), ('\u{251C}', '\u{251C}'), ('\u{2524}', '\u{2524}'),
    ('\u{252C}', '\u{252C}'), ('\u{2534}', '\u{2534}'), ('\u{253C}', '\u{253C}'), ('\u{2580}', '\u{2580}'),
    ('\u{2584}', '\u{2584}'), ('\u{2588}', '\u{2588}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2320}', '\u{2320}'),
    ('\u{25A0}', '\u{25A0}'), ('\u{2219}', '\u{2219}'), ('\u{221A}', '\u{221A}'), ('\u{2248}', '\u{2248}'),
    ('\u{2264}', '\u{2264}'), ('\u{2265}', '\u{2265}'), ('\u{00A0}', '\u{00A0}'), ('\u{2321}', '\u{2321}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B7}', '\u{00B7}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{2550}', '\u{2550}'), ('\u{2551}', '\u{2551}'), ('\u{2552}', '\u{2552}'), ('\u{0401}', '\u{0451}'),
    ('\u{2553}', '\u{2553}'), ('\u{2554}', '\u{2554}'), ('\u{2555}', '\u{2555}'), ('\u{2556}', '\u{2556}'),
    ('\u{2557}', '\u{2557}'), ('\u{2558}', '\u{2558}'), ('\u{2559}', '\u{2559}'), ('\u{255A}', '\u{255A}'),
    ('\u{255B}', '\u{255B}'), ('\u{255C}', '\u{255C}'), ('\u{255D}', '\u{255D}'), ('\u{255E}', '\u{255E}'),
    ('\u{255F}', '\u{255F}'), ('\u{2560}', '\u{2560}'), ('\u{2561}', '\u{2561}'), ('\u{0401}', '\u{0451}'),
    ('\u{2562}', '\u{2562}'), ('\u{2563}', '\u{2563}'), ('\u{2564}', '\u{2564}'), ('\u{2565}', '\u{2565}'),
    ('\u{2566}', '\u{2566}'), ('\u{2567}', '\u{2567}'), ('\u{2568}', '\u{2568}'), ('\u{2569}', '\u{2569}'),
    ('\u{256A}', '\u{256A}'), ('\u{256B}', '\u{256B}'), ('\u{256C}', '\u{256C}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{042E}', '\u{044E}'), ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0426}', '\u{0446}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0424}', '\u{0444}'), ('\u{0413}', '\u{0433}'),
    ('\u{0425}', '\u{0445}'), ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'),
    ('\u{041B}', '\u{043B}'), ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'),
    ('\u{041F}', '\u{043F}'), ('\u{042F}', '\u{044F}'), ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'),
    ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'), ('\u{0416}', '\u{0436}'), ('\u{0412}', '\u{0432}'),
    ('\u{042C}', '\u{044C}'), ('\u{042B}', '\u{044B}'), ('\u{0417}', '\u{0437}'), ('\u{0428}', '\u{0448}'),
    ('\u{042D}', '\u{044D}'), ('\u{0429}', '\u{0449}'), ('\u{0427}', '\u{0447}'), ('\u{042A}', '\u{044A}'),
    ('\u{042E}', '\u{044E}'), ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0426}', '\u{0446}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0424}', '\u{0444}'), ('\u{0413}', '\u{0433}'),
    ('\u{0425}', '\u{0445}'), ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'),
    ('\u{041B}', '\u{043B}'), ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'),
    ('\u{041F}', '\u{043F}'), ('\u{042F}', '\u{044F}'), ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'),
    ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'), ('\u{0416}', '\u{0436}'), ('\u{0412}', '\u{0432}'),
    ('\u{042C}', '\u{044C}'), ('\u{042B}', '\u{044B}'), ('\u{0417}', '\u{0437}'), ('\u{0428}', '\u{0448}'),
    ('\u{042D}', '\u{044D}'), ('\u{0429}', '\u{0449}'), ('\u{0427}', '\u{0447}'), ('\u{042A}', '\u{044A}'),
];
const KOI8U_HIGH: [char; 128] = [
    '\u{2500}', '\u{2502}', '\u{250C}', '\u{2510}', '\u{2514}', '\u{2518}', '\u{251C}', '\u{2524}',
    '\u{252C}', '\u{2534}', '\u{253C}', '\u{2580}', '\u{2584}', '\u{2588}', '\u{258C}', '\u{2590}',
    '\u{2591}', '\u{2592}', '\u{2593}', '\u{2320}', '\u{25A0}', '\u{2219}', '\u{221A}', '\u{2248}',
    '\u{2264}', '\u{2265}', '\u{00A0}', '\u{2321}', '\u{00B0}', '\u{00B2}', '\u{00B7}', '\u{00F7}',
    '\u{2550}', '\u{2551}', '\u{2552}', '\u{0451}', '\u{0454}', '\u{2554}', '\u{0456}', '\u{0457}',
    '\u{2557}', '\u{2558}', '\u{2559}', '\u{255A}', '\u{255B}', '\u{0491}', '\u{045E}', '\u{255E}',
    '\u{255F}', '\u{2560}', '\u{2561}', '\u{0401}', '\u{0404}', '\u{2563}', '\u{0406}', '\u{0407}',
    '\u{2566}', '\u{2567}', '\u{2568}', '\u{2569}', '\u{256A}', '\u{0490}', '\u{040E}', '\u{00A9}',
    '\u{044E}', '\u{0430}', '\u{0431}', '\u{0446}', '\u{0434}', '\u{0435}', '\u{0444}', '\u{0433}',
    '\u{0445}', '\u{0438}', '\u{0439}', '\u{043A}', '\u{043B}', '\u{043C}', '\u{043D}', '\u{043E}',
    '\u{043F}', '\u{044F}', '\u{0440}', '\u{0441}', '\u{0442}', '\u{0443}', '\u{0436}', '\u{0432}',
    '\u{044C}', '\u{044B}', '\u{0437}', '\u{0448}', '\u{044D}', '\u{0449}', '\u{0447}', '\u{044A}',
    '\u{042E}', '\u{0410}', '\u{0411}', '\u{0426}', '\u{0414}', '\u{0415}', '\u{0424}', '\u{0413}',
    '\u{0425}', '\u{0418}', '\u{0419}', '\u{041A}', '\u{041B}', '\u{041C}', '\u{041D}', '\u{041E}',
    '\u{041F}', '\u{042F}', '\u{0420}', '\u{0421}', '\u{0422}', '\u{0423}', '\u{0416}', '\u{0412}',
    '\u{042C}', '\u{042B}', '\u{0417}', '\u{0428}', '\u{042D}', '\u{0429}', '\u{0427}', '\u{042A}',
];
const KOI8U_CASE: [(char, char); 128] = [
    ('\u{2500}', '\u{2500}'), ('\u{2502}', '\u{2502}'), ('\u{250C}', '\u{250C}'), ('\u{2510}', '\u{2510}'),
    ('\u{2514}', '\u{2514}'), ('\u{2518}', '\u{2518}'), ('\u{251C}', '\u{251C}'), ('\u{2524}', '\u{2524}'),
    ('\u{252C}', '\u{252C}'), ('\u{2534}', '\u{2534}'), ('\u{253C}', '\u{253C}'), ('\u{2580}', '\u{2580}'),
    ('\u{2584}', '\u{2584}'), ('\u{2588}', '\u{2588}'), ('\u{258C}', '\u{258C}'), ('\u{2590}', '\u{2590}'),
    ('\u{2591}', '\u{2591}'), ('\u{2592}', '\u{2592}'), ('\u{2593}', '\u{2593}'), ('\u{2320}', '\u{2320}'),
    ('\u{25A0}', '\u{25A0}'), ('\u{2219}', '\u{2219}'), ('\u{221A}', '\u{221A}'), ('\u{2248}', '\u{2248}'),
    ('\u{2264}', '\u{2264}'), ('\u{2265}', '\u{2265}'), ('\u{00A0}', '\u{00A0}'), ('\u{2321}', '\u{2321}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B7}', '\u{00B7}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{2550}', '\u{2550}'), ('\u{2551}', '\u{2551}'), ('\u{2552}', '\u{2552}'), ('\u{0401}', '\u{0451}'),
    ('\u{0404}', '\u{0454}'), ('\u{2554}', '\u{2554}'), ('\u{0406}', '\u{0456}'), ('\u{0407}', '\u{0457}'),
    ('\u{2557}', '\u{2557}'), ('\u{2558}', '\u{2558}'), ('\u{2559}', '\u{2559}'), ('\u{255A}', '\u{255A}'),
    ('\u{255B}', '\u{255B}'), ('\u{0490}', '\u{0491}'), ('\u{040E}', '\u{045E}'), ('\u{255E}', '\u{255E}'),
    ('\u{255F}', '\u{255F}'), ('\u{2560}', '\u{2560}'), ('\u{2561}', '\u{2561}'), ('\u{0401}', '\u{0451}'),
    ('\u{0404}', '\u{0454}'), ('\u{2563}', '\u{2563}'), ('\u{0406}', '\u{0456}'), ('\u{0407}', '\u{0457}'),
    ('\u{2566}', '\u{2566}'), ('\u{2567}', '\u{2567}'), ('\u{2568}', '\u{2568}'), ('\u{2569}', '\u{2569}'),
    ('\u{256A}', '\u{256A}'), ('\u{0490}', '\u{0491}'), ('\u{040E}', '\u{045E}'), ('\u{00A9}', '\u{00A9}'),
    ('\u{042E}', '\u{044E}'), ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0426}', '\u{0446}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0424}', '\u{0444}'), ('\u{0413}', '\u{0433}'),
    ('\u{0425}', '\u{0445}'), ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'),
    ('\u{041B}', '\u{043B}'), ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'),
    ('\u{041F}', '\u{043F}'), ('\u{042F}', '\u{044F}'), ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'),
    ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'), ('\u{0416}', '\u{0436}'), ('\u{0412}', '\u{0432}'),
    ('\u{042C}', '\u{044C}'), ('\u{042B}', '\u{044B}'), ('\u{0417}', '\u{0437}'), ('\u{0428}', '\u{0448}'),
    ('\u{042D}', '\u{044D}'), ('\u{0429}', '\u{0449}'), ('\u{0427}', '\u{0447}'), ('\u{042A}', '\u{044A}'),
    ('\u{042E}', '\u{044E}'), ('\u{0410}', '\u{0430}'), ('\u{0411}', '\u{0431}'), ('\u{0426}', '\u{0446}'),
    ('\u{0414}', '\u{0434}'), ('\u{0415}', '\u{0435}'), ('\u{0424}', '\u{0444}'), ('\u{0413}', '\u{0433}'),
    ('\u{0425}', '\u{0445}'), ('\u{0418}', '\u{0438}'), ('\u{0419}', '\u{0439}'), ('\u{041A}', '\u{043A}'),
    ('\u{041B}', '\u{043B}'), ('\u{041C}', '\u{043C}'), ('\u{041D}', '\u{043D}'), ('\u{041E}', '\u{043E}'),
    ('\u{041F}', '\u{043F}'), ('\u{042F}', '\u{044F}'), ('\u{0420}', '\u{0440}'), ('\u{0421}', '\u{0441}'),
    ('\u{0422}', '\u{0442}'), ('\u{0423}', '\u{0443}'), ('\u{0416}', '\u{0436}'), ('\u{0412}', '\u{0432}'),
    ('\u{042C}', '\u{044C}'), ('\u{042B}', '\u{044B}'), ('\u{0417}', '\u{0437}'), ('\u{0428}', '\u{0448}'),
    ('\u{042D}', '\u{044D}'), ('\u{0429}', '\u{0449}'), ('\u{0427}', '\u{0447}'), ('\u{042A}', '\u{044A}'),
];
const WIN1258_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0000}', '\u{201A}', '\u{0192}', '\u{201E}', '\u{2026}', '\u{2020}', '\u{2021}',
    '\u{02C6}', '\u{2030}', '\u{0000}', '\u{2039}', '\u{0152}', '\u{0000}', '\u{0000}', '\u{0000}',
    '\u{0000}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{02DC}', '\u{2122}', '\u{0000}', '\u{203A}', '\u{0153}', '\u{0000}', '\u{0000}', '\u{0178}',
    '\u{00A0}', '\u{00A1}', '\u{00A2}', '\u{00A3}', '\u{00A4}', '\u{00A5}', '\u{00A6}', '\u{00A7}',
    '\u{00A8}', '\u{00A9}', '\u{00AA}', '\u{00AB}', '\u{00AC}', '\u{00AD}', '\u{00AE}', '\u{00AF}',
    '\u{00B0}', '\u{00B1}', '\u{00B2}', '\u{00B3}', '\u{00B4}', '\u{00B5}', '\u{00B6}', '\u{00B7}',
    '\u{00B8}', '\u{00B9}', '\u{00BA}', '\u{00BB}', '\u{00BC}', '\u{00BD}', '\u{00BE}', '\u{00BF}',
    '\u{00C0}', '\u{00C1}', '\u{00C2}', '\u{0102}', '\u{00C4}', '\u{00C5}', '\u{00C6}', '\u{00C7}',
    '\u{00C8}', '\u{00C9}', '\u{00CA}', '\u{00CB}', '\u{0300}', '\u{00CD}', '\u{00CE}', '\u{00CF}',
    '\u{0110}', '\u{00D1}', '\u{0309}', '\u{00D3}', '\u{00D4}', '\u{01A0}', '\u{00D6}', '\u{00D7}',
    '\u{00D8}', '\u{00D9}', '\u{00DA}', '\u{00DB}', '\u{00DC}', '\u{01AF}', '\u{0303}', '\u{00DF}',
    '\u{00E0}', '\u{00E1}', '\u{00E2}', '\u{0103}', '\u{00E4}', '\u{00E5}', '\u{00E6}', '\u{00E7}',
    '\u{00E8}', '\u{00E9}', '\u{00EA}', '\u{00EB}', '\u{0301}', '\u{00ED}', '\u{00EE}', '\u{00EF}',
    '\u{0111}', '\u{00F1}', '\u{0323}', '\u{00F3}', '\u{00F4}', '\u{01A1}', '\u{00F6}', '\u{00F7}',
    '\u{00F8}', '\u{00F9}', '\u{00FA}', '\u{00FB}', '\u{00FC}', '\u{01B0}', '\u{20AB}', '\u{00FF}',
];
const WIN1258_CASE: [(char, char); 128] = [
    (CASE_ERR, CASE_ERR), ('\u{0000}', '\u{0000}'), (CASE_ERR, CASE_ERR), (CASE_ERR, '\u{0192}'),
    (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR),
    ('\u{02C6}', '\u{02C6}'), (CASE_ERR, CASE_ERR), ('\u{0000}', '\u{0000}'), (CASE_ERR, CASE_ERR),
    ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'),
    ('\u{0000}', '\u{0000}'), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR),
    (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR), (CASE_ERR, CASE_ERR),
    ('\u{02DC}', '\u{02DC}'), ('\u{2022}', '\u{2022}'), ('\u{0000}', '\u{0000}'), (CASE_ERR, CASE_ERR),
    ('\u{0152}', '\u{0153}'), ('\u{0000}', '\u{0000}'), ('\u{0000}', '\u{0000}'), ('\u{0178}', '\u{00FF}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{00A1}', '\u{00A1}'), ('\u{00A2}', '\u{00A2}'), ('\u{00A3}', '\u{00A3}'),
    ('\u{00A4}', '\u{00A4}'), ('\u{00A5}', '\u{00A5}'), ('\u{00A6}', '\u{00A6}'), ('\u{00A7}', '\u{00A7}'),
    ('\u{00A8}', '\u{00A8}'), ('\u{00A9}', '\u{00A9}'), ('\u{00AA}', '\u{00AA}'), ('\u{00AB}', '\u{00AB}'),
    ('\u{00AC}', '\u{00AC}'), ('\u{00AD}', '\u{00AD}'), ('\u{00AE}', '\u{00AE}'), ('\u{00AF}', '\u{00AF}'),
    ('\u{00B0}', '\u{00B0}'), ('\u{00B1}', '\u{00B1}'), ('\u{00B2}', '\u{00B2}'), ('\u{00B3}', '\u{00B3}'),
    ('\u{00B4}', '\u{00B4}'), ('\u{00B5}', '\u{00B5}'), ('\u{00B6}', '\u{00B6}'), ('\u{00B7}', '\u{00B7}'),
    ('\u{00B8}', '\u{00B8}'), ('\u{00B9}', '\u{00B9}'), ('\u{00BA}', '\u{00BA}'), ('\u{00BB}', '\u{00BB}'),
    ('\u{00BC}', '\u{00BC}'), ('\u{00BD}', '\u{00BD}'), ('\u{00BE}', '\u{00BE}'), ('\u{00BF}', '\u{00BF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{0102}', '\u{0103}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{0300}', '\u{0300}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{0110}', '\u{0111}'), ('\u{00D1}', '\u{00F1}'), ('\u{0309}', '\u{0309}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{01A0}', '\u{01A1}'), ('\u{00D6}', '\u{00F6}'), ('\u{00D7}', '\u{00D7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{01AF}', '\u{01B0}'), ('\u{0303}', '\u{0303}'), ('\u{00DF}', '\u{00DF}'),
    ('\u{00C0}', '\u{00E0}'), ('\u{00C1}', '\u{00E1}'), ('\u{00C2}', '\u{00E2}'), ('\u{0102}', '\u{0103}'),
    ('\u{00C4}', '\u{00E4}'), ('\u{00C5}', '\u{00E5}'), ('\u{00C6}', '\u{00E6}'), ('\u{00C7}', '\u{00E7}'),
    ('\u{00C8}', '\u{00E8}'), ('\u{00C9}', '\u{00E9}'), ('\u{00CA}', '\u{00EA}'), ('\u{00CB}', '\u{00EB}'),
    ('\u{0301}', '\u{0301}'), ('\u{00CD}', '\u{00ED}'), ('\u{00CE}', '\u{00EE}'), ('\u{00CF}', '\u{00EF}'),
    ('\u{0110}', '\u{0111}'), ('\u{00D1}', '\u{00F1}'), ('\u{0323}', '\u{0323}'), ('\u{00D3}', '\u{00F3}'),
    ('\u{00D4}', '\u{00F4}'), ('\u{01A0}', '\u{01A1}'), ('\u{00D6}', '\u{00F6}'), ('\u{00F7}', '\u{00F7}'),
    ('\u{00D8}', '\u{00F8}'), ('\u{00D9}', '\u{00F9}'), ('\u{00DA}', '\u{00FA}'), ('\u{00DB}', '\u{00FB}'),
    ('\u{00DC}', '\u{00FC}'), ('\u{01AF}', '\u{01B0}'), (CASE_ERR, CASE_ERR), ('\u{0178}', '\u{00FF}'),
];
const TIS620_HIGH: [char; 128] = [
    '\u{20AC}', '\u{0081}', '\u{0082}', '\u{0083}', '\u{0084}', '\u{2026}', '\u{0086}', '\u{0087}',
    '\u{0088}', '\u{0089}', '\u{008A}', '\u{008B}', '\u{008C}', '\u{008D}', '\u{008E}', '\u{008F}',
    '\u{0090}', '\u{2018}', '\u{2019}', '\u{201C}', '\u{201D}', '\u{2022}', '\u{2013}', '\u{2014}',
    '\u{0098}', '\u{0099}', '\u{009A}', '\u{009B}', '\u{009C}', '\u{009D}', '\u{009E}', '\u{009F}',
    '\u{00A0}', '\u{0E01}', '\u{0E02}', '\u{0E03}', '\u{0E04}', '\u{0E05}', '\u{0E06}', '\u{0E07}',
    '\u{0E08}', '\u{0E09}', '\u{0E0A}', '\u{0E0B}', '\u{0E0C}', '\u{0E0D}', '\u{0E0E}', '\u{0E0F}',
    '\u{0E10}', '\u{0E11}', '\u{0E12}', '\u{0E13}', '\u{0E14}', '\u{0E15}', '\u{0E16}', '\u{0E17}',
    '\u{0E18}', '\u{0E19}', '\u{0E1A}', '\u{0E1B}', '\u{0E1C}', '\u{0E1D}', '\u{0E1E}', '\u{0E1F}',
    '\u{0E20}', '\u{0E21}', '\u{0E22}', '\u{0E23}', '\u{0E24}', '\u{0E25}', '\u{0E26}', '\u{0E27}',
    '\u{0E28}', '\u{0E29}', '\u{0E2A}', '\u{0E2B}', '\u{0E2C}', '\u{0E2D}', '\u{0E2E}', '\u{0E2F}',
    '\u{0E30}', '\u{0E31}', '\u{0E32}', '\u{0E33}', '\u{0E34}', '\u{0E35}', '\u{0E36}', '\u{0E37}',
    '\u{0E38}', '\u{0E39}', '\u{0E3A}', '\u{F8C1}', '\u{F8C2}', '\u{F8C3}', '\u{F8C4}', '\u{0E3F}',
    '\u{0E40}', '\u{0E41}', '\u{0E42}', '\u{0E43}', '\u{0E44}', '\u{0E45}', '\u{0E46}', '\u{0E47}',
    '\u{0E48}', '\u{0E49}', '\u{0E4A}', '\u{0E4B}', '\u{0E4C}', '\u{0E4D}', '\u{0E4E}', '\u{0E4F}',
    '\u{0E50}', '\u{0E51}', '\u{0E52}', '\u{0E53}', '\u{0E54}', '\u{0E55}', '\u{0E56}', '\u{0E57}',
    '\u{0E58}', '\u{0E59}', '\u{0E5A}', '\u{0E5B}', '\u{F8C5}', '\u{F8C6}', '\u{F8C7}', '\u{F8C8}',
];
const TIS620_CASE: [(char, char); 128] = [
    ('\u{20AC}', '\u{20AC}'), ('\u{0081}', '\u{0081}'), ('\u{0082}', '\u{0082}'), ('\u{0083}', '\u{0083}'),
    ('\u{0084}', '\u{0084}'), ('\u{2026}', '\u{2026}'), ('\u{0086}', '\u{0086}'), ('\u{0087}', '\u{0087}'),
    ('\u{0088}', '\u{0088}'), ('\u{0089}', '\u{0089}'), ('\u{008A}', '\u{008A}'), ('\u{008B}', '\u{008B}'),
    ('\u{008C}', '\u{008C}'), ('\u{008D}', '\u{008D}'), ('\u{008E}', '\u{008E}'), ('\u{008F}', '\u{008F}'),
    ('\u{0090}', '\u{0090}'), ('\u{2018}', '\u{2018}'), ('\u{2019}', '\u{2019}'), ('\u{201C}', '\u{201C}'),
    ('\u{201D}', '\u{201D}'), ('\u{2022}', '\u{2022}'), ('\u{2013}', '\u{2013}'), ('\u{2014}', '\u{2014}'),
    ('\u{0098}', '\u{0098}'), ('\u{0099}', '\u{0099}'), ('\u{009A}', '\u{009A}'), ('\u{009B}', '\u{009B}'),
    ('\u{009C}', '\u{009C}'), ('\u{009D}', '\u{009D}'), ('\u{009E}', '\u{009E}'), ('\u{009F}', '\u{009F}'),
    ('\u{00A0}', '\u{00A0}'), ('\u{0E01}', '\u{0E01}'), ('\u{0E02}', '\u{0E02}'), ('\u{0E03}', '\u{0E03}'),
    ('\u{0E04}', '\u{0E04}'), ('\u{0E05}', '\u{0E05}'), ('\u{0E06}', '\u{0E06}'), ('\u{0E07}', '\u{0E07}'),
    ('\u{0E08}', '\u{0E08}'), ('\u{0E09}', '\u{0E09}'), ('\u{0E0A}', '\u{0E0A}'), ('\u{0E0B}', '\u{0E0B}'),
    ('\u{0E0C}', '\u{0E0C}'), ('\u{0E0D}', '\u{0E0D}'), ('\u{0E0E}', '\u{0E0E}'), ('\u{0E0F}', '\u{0E0F}'),
    ('\u{0E10}', '\u{0E10}'), ('\u{0E11}', '\u{0E11}'), ('\u{0E12}', '\u{0E12}'), ('\u{0E13}', '\u{0E13}'),
    ('\u{0E14}', '\u{0E14}'), ('\u{0E15}', '\u{0E15}'), ('\u{0E16}', '\u{0E16}'), ('\u{0E17}', '\u{0E17}'),
    ('\u{0E18}', '\u{0E18}'), ('\u{0E19}', '\u{0E19}'), ('\u{0E1A}', '\u{0E1A}'), ('\u{0E1B}', '\u{0E1B}'),
    ('\u{0E1C}', '\u{0E1C}'), ('\u{0E1D}', '\u{0E1D}'), ('\u{0E1E}', '\u{0E1E}'), ('\u{0E1F}', '\u{0E1F}'),
    ('\u{0E20}', '\u{0E20}'), ('\u{0E21}', '\u{0E21}'), ('\u{0E22}', '\u{0E22}'), ('\u{0E23}', '\u{0E23}'),
    ('\u{0E24}', '\u{0E24}'), ('\u{0E25}', '\u{0E25}'), ('\u{0E26}', '\u{0E26}'), ('\u{0E27}', '\u{0E27}'),
    ('\u{0E28}', '\u{0E28}'), ('\u{0E29}', '\u{0E29}'), ('\u{0E2A}', '\u{0E2A}'), ('\u{0E2B}', '\u{0E2B}'),
    ('\u{0E2C}', '\u{0E2C}'), ('\u{0E2D}', '\u{0E2D}'), ('\u{0E2E}', '\u{0E2E}'), ('\u{0E2F}', '\u{0E2F}'),
    ('\u{0E30}', '\u{0E30}'), ('\u{0E31}', '\u{0E31}'), ('\u{0E32}', '\u{0E32}'), ('\u{0E33}', '\u{0E33}'),
    ('\u{0E34}', '\u{0E34}'), ('\u{0E35}', '\u{0E35}'), ('\u{0E36}', '\u{0E36}'), ('\u{0E37}', '\u{0E37}'),
    ('\u{0E38}', '\u{0E38}'), ('\u{0E39}', '\u{0E39}'), ('\u{0E3A}', '\u{0E3A}'), ('\u{F8C1}', '\u{F8C1}'),
    ('\u{F8C2}', '\u{F8C2}'), ('\u{F8C3}', '\u{F8C3}'), ('\u{F8C4}', '\u{F8C4}'), ('\u{0E3F}', '\u{0E3F}'),
    ('\u{0E40}', '\u{0E40}'), ('\u{0E41}', '\u{0E41}'), ('\u{0E42}', '\u{0E42}'), ('\u{0E43}', '\u{0E43}'),
    ('\u{0E44}', '\u{0E44}'), ('\u{0E45}', '\u{0E45}'), ('\u{0E46}', '\u{0E46}'), ('\u{0E47}', '\u{0E47}'),
    ('\u{0E48}', '\u{0E48}'), ('\u{0E49}', '\u{0E49}'), ('\u{0E4A}', '\u{0E4A}'), ('\u{0E4B}', '\u{0E4B}'),
    ('\u{0E4C}', '\u{0E4C}'), ('\u{0E4D}', '\u{0E4D}'), ('\u{0E4E}', '\u{0E4E}'), ('\u{0E4F}', '\u{0E4F}'),
    ('\u{0E50}', '\u{0E50}'), ('\u{0E51}', '\u{0E51}'), ('\u{0E52}', '\u{0E52}'), ('\u{0E53}', '\u{0E53}'),
    ('\u{0E54}', '\u{0E54}'), ('\u{0E55}', '\u{0E55}'), ('\u{0E56}', '\u{0E56}'), ('\u{0E57}', '\u{0E57}'),
    ('\u{0E58}', '\u{0E58}'), ('\u{0E59}', '\u{0E59}'), ('\u{0E5A}', '\u{0E5A}'), ('\u{0E5B}', '\u{0E5B}'),
    ('\u{F8C5}', '\u{F8C5}'), ('\u{F8C6}', '\u{F8C6}'), ('\u{F8C7}', '\u{F8C7}'), ('\u{F8C8}', '\u{F8C8}'),
];

/// The catalogue name of a set tabled by the generated block above.
pub fn tabled_name(charset: u8) -> Option<&'static str> {
    Some(match charset {
        CS_DOS737 => "DOS737",
        CS_DOS437 => "DOS437",
        CS_DOS850 => "DOS850",
        CS_DOS865 => "DOS865",
        CS_DOS860 => "DOS860",
        CS_DOS863 => "DOS863",
        CS_DOS775 => "DOS775",
        CS_DOS858 => "DOS858",
        CS_DOS862 => "DOS862",
        CS_DOS864 => "DOS864",
        CS_NEXT => "NEXT",
        CS_ISO8859_3 => "ISO8859_3",
        CS_ISO8859_4 => "ISO8859_4",
        CS_ISO8859_5 => "ISO8859_5",
        CS_ISO8859_6 => "ISO8859_6",
        CS_ISO8859_7 => "ISO8859_7",
        CS_ISO8859_8 => "ISO8859_8",
        CS_ISO8859_9 => "ISO8859_9",
        CS_ISO8859_13 => "ISO8859_13",
        CS_DOS852 => "DOS852",
        CS_DOS857 => "DOS857",
        CS_DOS861 => "DOS861",
        CS_DOS866 => "DOS866",
        CS_DOS869 => "DOS869",
        CS_CYRL => "CYRL",
        CS_WIN1253 => "WIN1253",
        CS_WIN1254 => "WIN1254",
        CS_WIN1255 => "WIN1255",
        CS_WIN1256 => "WIN1256",
        CS_WIN1257 => "WIN1257",
        CS_KOI8R => "KOI8R",
        CS_KOI8U => "KOI8U",
        CS_WIN1258 => "WIN1258",
        CS_TIS620 => "TIS620",
        _ => return None,
    })
}
