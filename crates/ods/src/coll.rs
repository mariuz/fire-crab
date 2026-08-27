//! `coll` - the narrow collation driver, converted from the engine's
//! own `src/intl/lc_narrow.cpp` with the PXW_INTL tables transcribed
//! (by script, not by hand) from `src/intl/collations/pw1252intl.h`.
//!
//! A COLLATION is not an ordering hint: it is a KEY FUNCTION and a
//! COMPARE FUNCTION, and both live here exactly as the engine runs
//! them. `string_to_key` flattens a string into weight bytes that
//! collate bytewise - all the PRIMARY weights first (case and accents
//! erased: 'a', 'A' and 'á' share primary 80), then the SECONDARY
//! weights (lowercase 2 before uppercase 7, each accent its own), then
//! - after a 0x00 marker - any SPECIALS as (position, weight) pairs.
//! `compare` is the streaming form with the engine's tiebreak chain:
//! first primary difference decides; else the FIRST secondary
//! difference, saved while the scan continues; else the expansion
//! quandary ('ß' against "ss": both spell primaries s,s - the side
//! whose 's' came out of an expansion loses, LDRV_TIEBREAK); else the
//! positional special scan. PXW_INTL itself: pad-space (trailing 0x20
//! stripped), 9 live expansions (ä Ä ö Ö ß þ Þ ü Ü), NO compressions,
//! no tertiary weights - and NO specials: its punctuation carries a
//! plain primary in place (probed live: 'a-b' < 'ab' because the
//! dash's 60 sorts before 'b''s 81 at position two, and the two are
//! NOT equal), so the special machinery here is the driver's, kept
//! faithful for the PXW tables that do use it.
//!
//! Every constant below is the engine's: FIRST_PRIMARY = 15 (1 tertiary
//! slot + 12 secondaries + gaps), and the table rows are (primary,
//! secondary, tertiary, is_expand, is_compress) per byte.

const PXW_INTL_ORDER: [(u8, u8, u8, u8, u8); 256] = [
    (15, 0, 0, 0, 0), (16, 0, 0, 0, 0), (17, 0, 0, 0, 0), (18, 0, 0, 0, 0),
    (19, 0, 0, 0, 0), (20, 0, 0, 0, 0), (21, 0, 0, 0, 0), (22, 0, 0, 0, 0),
    (23, 0, 0, 0, 0), (24, 0, 0, 0, 0), (25, 0, 0, 0, 0), (26, 0, 0, 0, 0),
    (27, 0, 0, 0, 0), (28, 0, 0, 0, 0), (29, 0, 0, 0, 0), (30, 0, 0, 0, 0),
    (31, 0, 0, 0, 0), (32, 0, 0, 0, 0), (33, 0, 0, 0, 0), (34, 0, 0, 0, 0),
    (35, 0, 0, 0, 0), (36, 0, 0, 0, 0), (37, 0, 0, 0, 0), (38, 0, 0, 0, 0),
    (39, 0, 0, 0, 0), (40, 0, 0, 0, 0), (41, 0, 0, 0, 0), (42, 0, 0, 0, 0),
    (43, 0, 0, 0, 0), (44, 0, 0, 0, 0), (45, 0, 0, 0, 0), (46, 0, 0, 0, 0),
    (47, 0, 0, 0, 0), (48, 0, 0, 0, 0), (49, 0, 0, 0, 0), (50, 0, 0, 0, 0),
    (51, 0, 0, 0, 0), (52, 0, 0, 0, 0), (53, 0, 0, 0, 0), (54, 0, 0, 0, 0),
    (55, 0, 0, 0, 0), (56, 0, 0, 0, 0), (57, 0, 0, 0, 0), (58, 0, 0, 0, 0),
    (59, 0, 0, 0, 0), (60, 0, 0, 0, 0), (61, 0, 0, 0, 0), (62, 0, 0, 0, 0),
    (63, 0, 0, 0, 0), (64, 0, 0, 0, 0), (65, 0, 0, 0, 0), (66, 0, 0, 0, 0),
    (67, 0, 0, 0, 0), (68, 0, 0, 0, 0), (69, 0, 0, 0, 0), (70, 0, 0, 0, 0),
    (71, 0, 0, 0, 0), (72, 0, 0, 0, 0), (73, 0, 0, 0, 0), (74, 0, 0, 0, 0),
    (75, 0, 0, 0, 0), (76, 0, 0, 0, 0), (77, 0, 0, 0, 0), (78, 0, 0, 0, 0),
    (79, 0, 0, 0, 0), (80, 7, 0, 0, 0), (81, 3, 0, 0, 0), (82, 4, 0, 0, 0),
    (83, 4, 0, 0, 0), (84, 7, 0, 0, 0), (85, 3, 0, 0, 0), (86, 3, 0, 0, 0),
    (87, 3, 0, 0, 0), (88, 7, 0, 0, 0), (89, 3, 0, 0, 0), (90, 3, 0, 0, 0),
    (91, 3, 0, 0, 0), (92, 3, 0, 0, 0), (93, 4, 0, 0, 0), (94, 8, 0, 0, 0),
    (95, 3, 0, 0, 0), (96, 3, 0, 0, 0), (97, 3, 0, 0, 0), (98, 3, 0, 0, 0),
    (99, 3, 0, 0, 0), (100, 6, 0, 0, 0), (101, 3, 0, 0, 0), (102, 3, 0, 0, 0),
    (103, 3, 0, 0, 0), (104, 5, 0, 0, 0), (105, 3, 0, 0, 0), (108, 0, 0, 0, 0),
    (109, 0, 0, 0, 0), (110, 0, 0, 0, 0), (111, 0, 0, 0, 0), (112, 0, 0, 0, 0),
    (113, 0, 0, 0, 0), (80, 2, 0, 0, 0), (81, 2, 0, 0, 0), (82, 2, 0, 0, 0),
    (83, 2, 0, 0, 0), (84, 2, 0, 0, 0), (85, 2, 0, 0, 0), (86, 2, 0, 0, 0),
    (87, 2, 0, 0, 0), (88, 2, 0, 0, 0), (89, 2, 0, 0, 0), (90, 2, 0, 0, 0),
    (91, 2, 0, 0, 0), (92, 2, 0, 0, 0), (93, 2, 0, 0, 0), (94, 2, 0, 0, 0),
    (95, 2, 0, 0, 0), (96, 2, 0, 0, 0), (97, 2, 0, 0, 0), (98, 2, 0, 0, 0),
    (99, 2, 0, 0, 0), (100, 2, 0, 0, 0), (101, 2, 0, 0, 0), (102, 2, 0, 0, 0),
    (103, 2, 0, 0, 0), (104, 2, 0, 0, 0), (105, 2, 0, 0, 0), (114, 0, 0, 0, 0),
    (115, 0, 0, 0, 0), (116, 0, 0, 0, 0), (117, 0, 0, 0, 0), (118, 0, 0, 0, 0),
    (121, 0, 0, 0, 0), (122, 0, 0, 0, 0), (123, 0, 0, 0, 0), (124, 0, 0, 0, 0),
    (125, 0, 0, 0, 0), (126, 0, 0, 0, 0), (127, 0, 0, 0, 0), (128, 0, 0, 0, 0),
    (129, 0, 0, 0, 0), (130, 0, 0, 0, 0), (131, 0, 0, 0, 0), (132, 0, 0, 0, 0),
    (133, 0, 0, 0, 0), (134, 0, 0, 0, 0), (135, 0, 0, 0, 0), (136, 0, 0, 0, 0),
    (137, 0, 0, 0, 0), (138, 0, 0, 0, 0), (139, 0, 0, 0, 0), (140, 0, 0, 0, 0),
    (141, 0, 0, 0, 0), (142, 0, 0, 0, 0), (143, 0, 0, 0, 0), (144, 0, 0, 0, 0),
    (145, 0, 0, 0, 0), (146, 0, 0, 0, 0), (147, 0, 0, 0, 0), (148, 0, 0, 0, 0),
    (149, 0, 0, 0, 0), (150, 0, 0, 0, 0), (151, 0, 0, 0, 0), (152, 0, 0, 0, 0),
    (153, 0, 0, 0, 0), (154, 0, 0, 0, 0), (155, 0, 0, 0, 0), (156, 0, 0, 0, 0),
    (157, 0, 0, 0, 0), (158, 0, 0, 0, 0), (159, 0, 0, 0, 0), (160, 0, 0, 0, 0),
    (161, 0, 0, 0, 0), (162, 0, 0, 0, 0), (163, 0, 0, 0, 0), (164, 0, 0, 0, 0),
    (165, 0, 0, 0, 0), (166, 0, 0, 0, 0), (167, 0, 0, 0, 0), (168, 0, 0, 0, 0),
    (169, 0, 0, 0, 0), (170, 0, 0, 0, 0), (171, 0, 0, 0, 0), (172, 0, 0, 0, 0),
    (173, 0, 0, 0, 0), (174, 0, 0, 0, 0), (175, 0, 0, 0, 0), (176, 0, 0, 0, 0),
    (177, 0, 0, 0, 0), (178, 0, 0, 0, 0), (179, 0, 0, 0, 0), (180, 0, 0, 0, 0),
    (181, 0, 0, 0, 0), (182, 0, 0, 0, 0), (183, 0, 0, 0, 0), (184, 0, 0, 0, 0),
    (80, 9, 0, 0, 0), (80, 8, 0, 0, 0), (80, 10, 0, 0, 0), (80, 11, 0, 0, 0),
    (80, 12, 0, 1, 0), (107, 0, 0, 0, 0), (120, 0, 0, 0, 0), (82, 5, 0, 0, 0),
    (84, 10, 0, 0, 0), (84, 9, 0, 0, 0), (84, 11, 0, 0, 0), (84, 8, 0, 0, 0),
    (88, 10, 0, 0, 0), (88, 9, 0, 0, 0), (88, 11, 0, 0, 0), (88, 8, 0, 0, 0),
    (83, 5, 0, 0, 0), (93, 5, 0, 0, 0), (94, 10, 0, 0, 0), (94, 9, 0, 0, 0),
    (94, 11, 0, 0, 0), (94, 12, 0, 0, 0), (94, 14, 0, 1, 0), (185, 0, 0, 0, 0),
    (94, 13, 0, 0, 0), (100, 8, 0, 0, 0), (100, 7, 0, 0, 0), (100, 9, 0, 0, 0),
    (100, 10, 0, 1, 0), (104, 6, 0, 0, 0), (99, 4, 0, 1, 0), (98, 4, 0, 1, 0),
    (80, 4, 0, 0, 0), (80, 3, 0, 0, 0), (80, 5, 0, 0, 0), (80, 6, 0, 0, 0),
    (80, 12, 0, 1, 0), (106, 0, 0, 0, 0), (119, 0, 0, 0, 0), (82, 3, 0, 0, 0),
    (84, 5, 0, 0, 0), (84, 4, 0, 0, 0), (84, 6, 0, 0, 0), (84, 3, 0, 0, 0),
    (88, 5, 0, 0, 0), (88, 4, 0, 0, 0), (88, 6, 0, 0, 0), (88, 3, 0, 0, 0),
    (83, 3, 0, 0, 0), (93, 3, 0, 0, 0), (94, 4, 0, 0, 0), (94, 3, 0, 0, 0),
    (94, 5, 0, 0, 0), (94, 6, 0, 0, 0), (94, 14, 0, 1, 0), (186, 0, 0, 0, 0),
    (94, 7, 0, 0, 0), (100, 4, 0, 0, 0), (100, 3, 0, 0, 0), (100, 5, 0, 0, 0),
    (100, 10, 0, 1, 0), (104, 4, 0, 0, 0), (99, 4, 0, 1, 0), (104, 3, 0, 0, 0),
];

const PXW_INTL_EXPAND: [(u8, u8, u8); 11] = [(228, 97, 101), (196, 65, 69), (246, 111, 101), (214, 79, 69), (223, 115, 115), (254, 116, 104), (222, 84, 72), (252, 117, 101), (220, 85, 69), (198, 65, 69), (230, 97, 101)];


/// The on-wire ttype for `WIN1252 COLLATE PXW_INTL`: collation 1 in the
/// high byte, charset 53 in the low (probed off a live descriptor).
pub const TTYPE_PXW_INTL: u16 = 0x0135;

/// Can this server reproduce the ORDER and the EQUALITY the collation
/// in this ttype defines?
///
/// A charset's DEFAULT collation (id 0 - `UCS_BASIC` for UTF8,
/// `WIN1252` for WIN1252, and so on) orders by the stored bytes, which
/// is what every plain comparison here already does. `PXW_INTL` is the
/// one real collation converted (the key builder above). Everything
/// else is ICU-backed in the engine - `UNICODE`, `UNICODE_CI`,
/// `UNICODE_CI_AI`, the language-specific WIN1252/ISO8859 collations -
/// and its order is the Unicode Collation Algorithm's, which this
/// server has no table for: `'apple' < 'Ápple' < 'banana'` under
/// UNICODE where the bytes say otherwise, and `'apple' = 'APPLE'` under
/// UNICODE_CI where the bytes say they differ.
///
/// A caller that ORDERS, GROUPS, DEDUPLICATES or COMPARES text asks
/// this first and REFUSES when the answer is false. Answering by bytes
/// would be a wrong answer with no sign of it - the rows come back in
/// the wrong order, or a row is missing from a filter - and this file's
/// rule is that a refusal is better than a guess.
pub fn keyable_ttype(ttype: u16) -> bool {
    crate::intl::collation_id(ttype as i16) == 0 || ttype == TTYPE_PXW_INTL
}

fn expand_of(b: u8) -> (u8, u8) {
    for &(c, e1, e2) in PXW_INTL_EXPAND.iter() {
        if c == b {
            return (e1, e2);
        }
    }
    (b, 0)
}

/// `LC_NARROW_string_to_key` for PXW_INTL. `partial` is the engine's
/// INTL_KEY_PARTIAL - primaries only, what a STARTING WITH range and an
/// index prefix probe use; the full key (INTL_KEY_SORT/UNIQUE - the
/// same bytes for this family) appends secondaries and the special
/// trailer.
pub fn pxw_intl_key(bytes: &[u8], partial: bool) -> Vec<u8> {
    let mut end = bytes.len();
    while end > 0 && bytes[end - 1] == 0x20 {
        end -= 1; // texttype_pad_option: trailing blanks are not keyed
    }
    let inp = &bytes[..end];
    let mut prim = Vec::with_capacity(inp.len());
    let mut sec: Vec<u8> = Vec::new();
    let mut spec: Vec<u8> = Vec::new();
    for (i, &b) in inp.iter().enumerate() {
        let (p, s, _t, ex, co) = PXW_INTL_ORDER[b as usize];
        if ex == 1 && co == 1 {
            // a SPECIAL: no weight in place - position and weight in
            // the trailer (specials_first is off for PXW_INTL)
            spec.push((i + 1) as u8);
            spec.push(p);
        } else if ex == 1 {
            // an expansion emits TWO entries: the char's own (an 's'
            // with the expansion's secondary) then ExpCh2's
            let (_e1, e2) = expand_of(b);
            if p != 0 {
                prim.push(p);
            }
            if s != 0 {
                sec.push(s);
            }
            let (p2, s2, _, _, _) = PXW_INTL_ORDER[e2 as usize];
            if p2 != 0 {
                prim.push(p2);
            }
            if s2 != 0 {
                sec.push(s2);
            }
        } else {
            // plain (PXW_INTL has no compressions; a lone IsCompress
            // would fall through to its own entry exactly like this)
            if p != 0 {
                prim.push(p);
            }
            if s != 0 {
                sec.push(s);
            }
        }
    }
    if partial {
        return prim;
    }
    let mut out = prim;
    out.extend_from_slice(&sec);
    if !spec.is_empty() {
        out.push(0);
        out.extend_from_slice(&spec);
    }
    out
}

/// One collation element from the stream - `get_coltab_entry`.
/// Advances past specials (flagging them), holds an expansion's second
/// element as `waiting`, and reports whether THIS element came with a
/// waiting one (the quandary flag).
struct ColStream<'a> {
    inp: &'a [u8],
    pos: usize,
    waiting: Option<u8>,
    have_special: bool,
}

impl<'a> ColStream<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        let mut end = bytes.len();
        while end > 0 && bytes[end - 1] == 0x20 {
            end -= 1;
        }
        ColStream { inp: &bytes[..end], pos: 0, waiting: None, have_special: false }
    }

    /// (primary, secondary, this-side-has-waiting) or None at end.
    fn next(&mut self) -> Option<(u8, u8, bool)> {
        if let Some(w) = self.waiting.take() {
            self.pos += 1; // now step past the expansion char itself
            let (p, s, _, _, _) = PXW_INTL_ORDER[w as usize];
            return Some((p, s, false));
        }
        while self.pos < self.inp.len() {
            let b = self.inp[self.pos];
            let (p, s, _t, ex, co) = PXW_INTL_ORDER[b as usize];
            if ex == 1 && co == 1 {
                self.pos += 1;
                self.have_special = true;
                continue;
            }
            if ex == 1 {
                let (_e1, e2) = expand_of(b);
                // the char's own entry now, ExpCh2's next call; the
                // position advances when the waiting one is served
                self.waiting = Some(e2);
                return Some((p, s, true));
            }
            self.pos += 1;
            return Some((p, s, false));
        }
        None
    }
}

/// `LC_NARROW_compare` for PXW_INTL: the engine's tiebreak chain.
pub fn pxw_intl_compare(a: &[u8], b: &[u8]) -> core::cmp::Ordering {
    use core::cmp::Ordering;
    let mut sa = ColStream::new(a);
    let mut sb = ColStream::new(b);
    let mut save_secondary = 0i32;
    let mut save_quandary = 0i32;
    loop {
        let ea = sa.next();
        let eb = sb.next();
        match (ea, eb) {
            (Some((pa, seca, wa)), Some((pb, secb, wb))) => {
                if pa != pb {
                    return (pa as i32).cmp(&(pb as i32));
                }
                if seca != secb {
                    if save_secondary == 0 {
                        save_secondary = seca as i32 - secb as i32;
                    }
                } else if wa != wb && save_quandary == 0 {
                    // expand_before is NOT set for LDRV_TIEBREAK: the
                    // side still owing an expansion element sorts AFTER
                    save_quandary = if wa { 1 } else { -1 };
                }
            }
            (Some(_), None) => return Ordering::Greater,
            (None, Some(_)) => return Ordering::Less,
            (None, None) => {
                if save_secondary != 0 {
                    return save_secondary.cmp(&0);
                }
                if save_quandary != 0 {
                    return save_quandary.cmp(&0);
                }
                if sa.have_special || sb.have_special {
                    return special_scan(a, b);
                }
                return Ordering::Equal;
            }
        }
    }
}

/// The positional special compare: strings whose weights tie entirely
/// are ordered by WHERE their specials sit, then by the specials'
/// weights; a special beats its absence, an EARLIER special sorts
/// FIRST (`special_scan`, converted line for line).
fn special_scan(a: &[u8], b: &[u8]) -> core::cmp::Ordering {
    use core::cmp::Ordering;
    let trim = |x: &[u8]| {
        let mut end = x.len();
        while end > 0 && x[end - 1] == 0x20 {
            end -= 1;
        }
        end
    };
    let (mut i1, mut i2) = (0usize, 0usize);
    let (l1, l2) = (trim(a), trim(b));
    let (mut x1, mut x2) = (0usize, 0usize); // index1/index2
    loop {
        while i1 < l1 {
            let (_, _, _, ex, co) = PXW_INTL_ORDER[a[i1] as usize];
            if ex == 1 && co == 1 {
                break;
            }
            i1 += 1;
            x1 += 1;
        }
        while i2 < l2 {
            let (_, _, _, ex, co) = PXW_INTL_ORDER[b[i2] as usize];
            if ex == 1 && co == 1 {
                break;
            }
            i2 += 1;
            x2 += 1;
        }
        match (i1 < l1, i2 < l2) {
            (false, false) => return Ordering::Equal,
            (true, false) => return Ordering::Greater,
            (false, true) => return Ordering::Less,
            (true, true) => {}
        }
        if x1 != x2 {
            // the string whose special sits EARLIER sorts first
            return x1.cmp(&x2);
        }
        let p1 = PXW_INTL_ORDER[a[i1] as usize].0;
        let p2 = PXW_INTL_ORDER[b[i2] as usize].0;
        if p1 != p2 {
            return p1.cmp(&p2);
        }
        i1 += 1;
        i2 += 1;
        x1 += 1;
        x2 += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::cmp::Ordering;

    // WIN1252 spellings of the probe strings
    const A_ACUTE: &[u8] = &[0xE1]; // á
    const E_ACUTE: &[u8] = &[0xE9]; // é
    const SHARP_S: &[u8] = &[0xDF]; // ß

    #[test]
    fn the_engines_order_probed_live() {
        // SELECT S FROM K ORDER BY S on the live engine answered:
        // a á A a-b ab aB Ab ab- aé b e é ss ß st z
        let want: Vec<&[u8]> = vec![
            b"a", A_ACUTE, b"A", b"a-b", b"ab", b"aB", b"Ab", b"ab-",
            &[0x61, 0xE9], b"b", b"e", E_ACUTE, b"ss", SHARP_S, b"st", b"z",
        ];
        let mut got = want.clone();
        got.sort_by(|x, y| pxw_intl_compare(x, y));
        assert_eq!(got, want, "compare disagrees with the engine's ORDER BY");
        // and the KEYS collate bytewise to the SAME order
        let mut by_key = want.clone();
        by_key.sort_by_key(|x| pxw_intl_key(x, false));
        assert_eq!(by_key, want, "keys disagree with the engine's ORDER BY");
    }

    #[test]
    fn pad_case_and_expansion_probes() {
        // 'a ' = 'a' (pad space), 'a' <> 'A' (secondary), probed
        assert_eq!(pxw_intl_compare(b"a ", b"a"), Ordering::Equal);
        assert_ne!(pxw_intl_compare(b"a", b"A"), Ordering::Equal);
        assert_eq!(pxw_intl_compare(b"a", b"A"), Ordering::Less);
        // ss < ß (the expansion quandary; probed), ß < st (primary)
        assert_eq!(pxw_intl_compare(b"ss", SHARP_S), Ordering::Less);
        assert_eq!(pxw_intl_compare(SHARP_S, b"st"), Ordering::Less);
        // 'a-b' <> 'ab': the dash is a WEIGHTED character in PXW_INTL
        // (no specials in this table at all), probed 'ne'
        assert_ne!(pxw_intl_compare(b"a-b", b"ab"), Ordering::Equal);
        assert_eq!(pxw_intl_compare(b"a-b", b"ab"), Ordering::Less);
    }

    #[test]
    fn keys_have_the_engines_shape() {
        // primaries first, then secondaries: 'a' and 'A' share the
        // primary and differ in the trailing secondary byte
        let ka = pxw_intl_key(b"a", false);
        let ku = pxw_intl_key(b"A", false);
        assert_eq!(ka.len(), 2);
        assert_eq!(ka[0], ku[0]);
        assert_ne!(ka[1], ku[1]);
        // the PARTIAL key is the primaries alone - what a STARTING
        // range probes - so 'ab' extends 'a' byte-for-byte
        let pa = pxw_intl_key(b"a", true);
        let pab = pxw_intl_key(b"ab", true);
        assert_eq!(pa.len(), 1);
        assert!(pab.starts_with(&pa));
        // 'ß' expands: two primaries from one byte
        assert_eq!(pxw_intl_key(SHARP_S, true).len(), 2);
        // trailing blanks are not keyed
        assert_eq!(pxw_intl_key(b"a  ", false), pxw_intl_key(b"a", false));
    }
}


const PXW_INTL_UPPER: [u8; 256] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
    96, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 123, 124, 125, 126, 127,
    128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
    65, 65, 65, 195, 196, 197, 198, 199, 69, 69, 69, 69, 73, 73, 73, 73,
    208, 209, 79, 79, 79, 213, 214, 247, 216, 85, 85, 85, 220, 89, 222, 89,
];

const PXW_INTL_LOWER: [u8; 256] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    64, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 91, 92, 93, 94, 95,
    96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
    128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
    224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 215, 248, 249, 250, 251, 252, 253, 254, 223,
    224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255,
];

/// PXW_INTL's OWN case mapping - the collation's ToUpper/ToLower
/// conversion tables, transcribed by script from pw1252intl.h and
/// validated byte-for-byte against the live engine (UNICODE_VAL over
/// one-byte collated rows). This is the Paradox ACCENT-STRIPPING
/// convention: UPPER('é') is 'E' and UPPER('ÿ') is 'Y' where the
/// default collation answers 'É' and 'Ÿ'; 'ß' and 'ƒ' are untouched
/// (and unlike the default collation, NOTHING raises - the tables are
/// total). Byte in, byte out, in the WIN1252 codepage.
pub fn pxw_intl_case(b: u8, upper: bool) -> u8 {
    if upper {
        PXW_INTL_UPPER[b as usize]
    } else {
        PXW_INTL_LOWER[b as usize]
    }
}

#[cfg(test)]
mod case_tests {
    use super::*;

    #[test]
    fn the_paradox_accent_stripping_convention() {
        // probed live: UPPER strips the accent, LOWER keeps it
        assert_eq!(pxw_intl_case(0xE9, true), b'E'); // é -> E
        assert_eq!(pxw_intl_case(0xE9, false), 0xE9); // lower(é) = é
        assert_eq!(pxw_intl_case(0xC9, false), 0xE9); // lower(É) = é - only UPPER strips
        assert_eq!(pxw_intl_case(0xFF, true), b'Y'); // ÿ -> Y
        // ß and ƒ have no pairs here, and nothing raises
        assert_eq!(pxw_intl_case(0xDF, true), 0xDF);
        assert_eq!(pxw_intl_case(0x83, true), 0x83);
        // plain ASCII is plain case
        assert_eq!(pxw_intl_case(b'a', true), b'A');
        assert_eq!(pxw_intl_case(b'Z', false), b'z');
    }
}
