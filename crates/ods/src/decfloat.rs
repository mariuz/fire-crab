//! DECFLOAT decode: IEEE 754-2008 decimal64/decimal128 in the densely
//! packed decimal (DPD) encoding, converted from the decNumber library
//! the engine embeds (extern/decNumber). One-way only - fire-crab reads
//! and renders these values, it does not write them - so only the
//! DPD -> binary declet table (decDPD.h:400, transcribed below) and the
//! field extraction (decimal64.c/decimal128.c decimal*ToNumber) are
//! needed. Rendering follows decNumberToString (decNumber.c): plain
//! notation while the exponent is <= 0 and the adjusted exponent >= -6,
//! scientific with an explicit sign otherwise - the exact shapes isql
//! prints, cohort (trailing zeros, stored exponent) preserved.
//!
//! Layouts (sign at the top of the little-endian-loaded word):
//!   decimal64  (u64):  1 sign | 5 combination | 8 exponent cont | 50 coeff (5 declets),  bias 398
//!   decimal128 (u128): 1 sign | 5 combination | 12 exponent cont | 110 coeff (11 declets), bias 6176
//!
//! Combination field g0..g4 (IEEE 754-2008 3.5.2): g0g1 < 11 means the
//! exponent's top two bits are g0g1 and the leading digit is g2g3g4;
//! g0g1 = 11 with g2g3 < 11 means top bits g2g3, leading digit 8+g4;
//! 11110 is infinity, 11111 NaN.

/// `DPD2BIN` (decDPD.h:400): 10-bit declet -> 3 decimal digits.
const DPD2BIN: [u16; 1024] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 80, 81, 800, 801, 880, 881,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 90, 91, 810, 811, 890, 891,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 82, 83, 820, 821, 808, 809,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 92, 93, 830, 831, 818, 819,
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 84, 85, 840, 841, 88, 89,
    50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 94, 95, 850, 851, 98, 99,
    60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 86, 87, 860, 861, 888, 889,
    70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 96, 97, 870, 871, 898, 899,
    100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 180, 181, 900, 901, 980, 981,
    110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 190, 191, 910, 911, 990, 991,
    120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 182, 183, 920, 921, 908, 909,
    130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 192, 193, 930, 931, 918, 919,
    140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 184, 185, 940, 941, 188, 189,
    150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 194, 195, 950, 951, 198, 199,
    160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 186, 187, 960, 961, 988, 989,
    170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 196, 197, 970, 971, 998, 999,
    200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 280, 281, 802, 803, 882, 883,
    210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 290, 291, 812, 813, 892, 893,
    220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 282, 283, 822, 823, 828, 829,
    230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 292, 293, 832, 833, 838, 839,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 284, 285, 842, 843, 288, 289,
    250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 294, 295, 852, 853, 298, 299,
    260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 286, 287, 862, 863, 888, 889,
    270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 296, 297, 872, 873, 898, 899,
    300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 380, 381, 902, 903, 982, 983,
    310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 390, 391, 912, 913, 992, 993,
    320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 382, 383, 922, 923, 928, 929,
    330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 392, 393, 932, 933, 938, 939,
    340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 384, 385, 942, 943, 388, 389,
    350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 394, 395, 952, 953, 398, 399,
    360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 386, 387, 962, 963, 988, 989,
    370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 396, 397, 972, 973, 998, 999,
    400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 480, 481, 804, 805, 884, 885,
    410, 411, 412, 413, 414, 415, 416, 417, 418, 419, 490, 491, 814, 815, 894, 895,
    420, 421, 422, 423, 424, 425, 426, 427, 428, 429, 482, 483, 824, 825, 848, 849,
    430, 431, 432, 433, 434, 435, 436, 437, 438, 439, 492, 493, 834, 835, 858, 859,
    440, 441, 442, 443, 444, 445, 446, 447, 448, 449, 484, 485, 844, 845, 488, 489,
    450, 451, 452, 453, 454, 455, 456, 457, 458, 459, 494, 495, 854, 855, 498, 499,
    460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 486, 487, 864, 865, 888, 889,
    470, 471, 472, 473, 474, 475, 476, 477, 478, 479, 496, 497, 874, 875, 898, 899,
    500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 580, 581, 904, 905, 984, 985,
    510, 511, 512, 513, 514, 515, 516, 517, 518, 519, 590, 591, 914, 915, 994, 995,
    520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 582, 583, 924, 925, 948, 949,
    530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 592, 593, 934, 935, 958, 959,
    540, 541, 542, 543, 544, 545, 546, 547, 548, 549, 584, 585, 944, 945, 588, 589,
    550, 551, 552, 553, 554, 555, 556, 557, 558, 559, 594, 595, 954, 955, 598, 599,
    560, 561, 562, 563, 564, 565, 566, 567, 568, 569, 586, 587, 964, 965, 988, 989,
    570, 571, 572, 573, 574, 575, 576, 577, 578, 579, 596, 597, 974, 975, 998, 999,
    600, 601, 602, 603, 604, 605, 606, 607, 608, 609, 680, 681, 806, 807, 886, 887,
    610, 611, 612, 613, 614, 615, 616, 617, 618, 619, 690, 691, 816, 817, 896, 897,
    620, 621, 622, 623, 624, 625, 626, 627, 628, 629, 682, 683, 826, 827, 868, 869,
    630, 631, 632, 633, 634, 635, 636, 637, 638, 639, 692, 693, 836, 837, 878, 879,
    640, 641, 642, 643, 644, 645, 646, 647, 648, 649, 684, 685, 846, 847, 688, 689,
    650, 651, 652, 653, 654, 655, 656, 657, 658, 659, 694, 695, 856, 857, 698, 699,
    660, 661, 662, 663, 664, 665, 666, 667, 668, 669, 686, 687, 866, 867, 888, 889,
    670, 671, 672, 673, 674, 675, 676, 677, 678, 679, 696, 697, 876, 877, 898, 899,
    700, 701, 702, 703, 704, 705, 706, 707, 708, 709, 780, 781, 906, 907, 986, 987,
    710, 711, 712, 713, 714, 715, 716, 717, 718, 719, 790, 791, 916, 917, 996, 997,
    720, 721, 722, 723, 724, 725, 726, 727, 728, 729, 782, 783, 926, 927, 968, 969,
    730, 731, 732, 733, 734, 735, 736, 737, 738, 739, 792, 793, 936, 937, 978, 979,
    740, 741, 742, 743, 744, 745, 746, 747, 748, 749, 784, 785, 946, 947, 788, 789,
    750, 751, 752, 753, 754, 755, 756, 757, 758, 759, 794, 795, 956, 957, 798, 799,
    760, 761, 762, 763, 764, 765, 766, 767, 768, 769, 786, 787, 966, 967, 988, 989,
    770, 771, 772, 773, 774, 775, 776, 777, 778, 779, 796, 797, 976, 977, 998, 999,];

/// A decoded DECFLOAT: finite (sign, coefficient, exponent of the last
/// digit - the cohort as stored), infinity, or NaN (sign, signaling,
/// payload - all three observable: `-NaN` renders, `sNaN` traps, and
/// payloads order numerically and propagate through arithmetic).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Dec {
    Finite { neg: bool, coeff: u128, exp: i32 },
    Infinity { neg: bool },
    Nan { neg: bool, signaling: bool, payload: u128 },
}

impl Dec {
    /// TRUE for a quiet NaN (which propagates through arithmetic).
    pub fn is_quiet_nan(&self) -> bool {
        matches!(self, Dec::Nan { signaling: false, .. })
    }
    /// TRUE for a signaling NaN (which traps: 22000, wherever a quiet
    /// NaN would propagate or a comparison would signal).
    pub fn is_signaling_nan(&self) -> bool {
        matches!(self, Dec::Nan { signaling: true, .. })
    }
    /// TRUE for either NaN.
    pub fn is_nan(&self) -> bool {
        matches!(self, Dec::Nan { .. })
    }
    /// The quiet NaN with no payload.
    pub fn quiet_nan() -> Dec {
        Dec::Nan { neg: false, signaling: false, payload: 0 }
    }
}

/// Split a combination field: (exponent top bits, leading digit), or a
/// special. `None` = infinity when `inf` else NaN.
fn combination(g: u32) -> Result<(u32, u128), bool> {
    if g >> 3 != 0b11 {
        Ok((g >> 3, (g & 7) as u128))
    } else if (g >> 1) & 3 != 0b11 {
        Ok(((g >> 1) & 3, (8 | (g & 1)) as u128))
    } else {
        Err(g & 1 == 0) // true = infinity, false = NaN
    }
}

/// Append `n` declets taken MSB-first from the low `10*n` bits of `raw`.
fn declets(mut coeff: u128, raw: u128, n: u32) -> u128 {
    for i in (0..n).rev() {
        let d = ((raw >> (10 * i)) & 0x3FF) as usize;
        coeff = coeff * 1000 + DPD2BIN[d] as u128;
    }
    coeff
}

/// TRUE for decNumber's special spellings (case-insensitive, an
/// optional sign): `inf`/`infinity`, `nan`/`snan` with an optional
/// payload of digits. The SINGLE gate on this shape: every consumer
/// reads this predicate rather than its own copy that could drift.
pub fn is_special_text(s: &str) -> bool {
    let t = s.strip_prefix(['+', '-']).unwrap_or(s).to_ascii_lowercase();
    if t == "inf" || t == "infinity" {
        return true;
    }
    match t.strip_prefix("snan").or_else(|| t.strip_prefix("nan")) {
        Some(payload) => payload.bytes().all(|c| c.is_ascii_digit()),
        None => false,
    }
}

/// Parse text by decNumber's grammar - the conversion an explicit CAST
/// (and a bound parameter) gets: an optional sign, digits with one dot,
/// an optional `e` exponent; the specials ([is_special_text]) with their
/// form. Surrounding BLANKS ARE NOT TRIMMED (`' 1.50 '` is a conversion
/// error - probed). Significant digits round to 34 HALF-UP; an exponent
/// outside decimal128's range refuses (None - the clamped assignment
/// and the overflow error live with the callers).
pub fn parse(s: &str) -> Option<Dec> {
    let b = s.as_bytes();
    let mut i = 0;
    let neg = match b.first() {
        Some(b'+') => {
            i = 1;
            false
        }
        Some(b'-') => {
            i = 1;
            true
        }
        _ => false,
    };
    if is_special_text(s) {
        let rest = s[i..].to_ascii_lowercase();
        if rest == "inf" || rest == "infinity" {
            return Some(Dec::Infinity { neg });
        }
        // `snan` before `nan` (it ends with it); a payload past 33
        // significant digits is a conversion error (22018, probed -
        // decNumber's 11 declets hold no more)
        let (signaling, digits) = match rest.strip_prefix("snan") {
            Some(d) => (true, d),
            None => (false, rest.strip_prefix("nan").unwrap_or("")),
        };
        let sig = digits.trim_start_matches('0');
        if sig.len() > 33 {
            return None;
        }
        let payload = sig.parse::<u128>().unwrap_or(0);
        return Some(Dec::Nan { neg, signaling, payload });
    }
    let mut digits: Vec<u8> = Vec::new();
    let mut seen_dot = false;
    let mut frac: i64 = 0;
    while i < b.len() {
        match b[i] {
            c @ b'0'..=b'9' => {
                digits.push(c);
                if seen_dot {
                    frac += 1;
                }
                i += 1;
            }
            b'.' => {
                if seen_dot {
                    return None;
                }
                seen_dot = true;
                i += 1;
            }
            b'e' | b'E' => break,
            _ => return None,
        }
    }
    if digits.is_empty() {
        return None;
    }
    let mut exp: i64 = -frac;
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        let esign: i64 = match b.get(i) {
            Some(b'+') => {
                i += 1;
                1
            }
            Some(b'-') => {
                i += 1;
                -1
            }
            _ => 1,
        };
        let estart = i;
        let mut ev: i64 = 0;
        while i < b.len() && b[i].is_ascii_digit() {
            ev = ev.checked_mul(10)?.checked_add((b[i] - b'0') as i64)?;
            i += 1;
        }
        if i == estart {
            return None;
        }
        exp += esign * ev;
    }
    if i != b.len() {
        return None; // trailing junk
    }
    // round the significant digits to 34, HALF-UP, the dropped places
    // moving into the exponent (the string can be longer than u128 holds,
    // so only the kept 34 are folded)
    let first = digits.iter().position(|&d| d != b'0').unwrap_or(digits.len() - 1);
    let sig = &digits[first..];
    let fold = |ds: &[u8]| ds.iter().fold(0u128, |m, &d| m * 10 + (d - b'0') as u128);
    let (coeff, drop) = if sig.len() <= 34 {
        (fold(sig), 0i64)
    } else {
        let mut c = fold(&sig[..34]);
        let rest = &sig[34..];
        let mut ea = rest.len() as i64;
        if rest[0] >= b'5' {
            c += 1;
            if c == 10u128.pow(34) {
                c /= 10;
                ea += 1;
            }
        }
        (c, ea)
    };
    let biased = exp + drop + 6176;
    if !(0..=12287).contains(&biased) {
        return None;
    }
    Some(Dec::Finite { neg, coeff, exp: (exp + drop) as i32 })
}

/// CVT_get_double's range test on a decimal text: the scale - the
/// fraction digits less the signed exponent - past DBL_MAX_10_EXP (308)
/// either way, or an exponent magnitude of 3276 or more, is 22003 *numeric
/// value is out of range* BEFORE any value is computed. So a zero or a
/// value a double could hold refuses too (measured on 2182: '1e-307'
/// answers, '2.3e-308', '0e-400', '0.00001e-305' and '1e-400' raise;
/// SIGN('-1.5e-400'), SQRT('1e-400'), SIGN('1e400') alike). The SINGLE
/// gate on this shape: both executors read this predicate rather than
/// their own copies that could drift.
pub fn cvt_double_scale_out_of_range(s: &str) -> bool {
    let t = s.trim_matches(' ');
    let (mant, exp) = match t.find(['e', 'E']) {
        Some(i) => (&t[..i], Some(&t[i + 1..])),
        None => (t, None),
    };
    let frac = mant.split_once('.').map_or(0, |(_, f)| f.chars().filter(|c| c.is_ascii_digit()).count()) as i64;
    let exp = match exp {
        Some(e) => {
            let e = e.trim_matches(' ');
            let (neg, digits) = match e.strip_prefix('-') {
                Some(d) => (true, d),
                None => (false, e.strip_prefix('+').unwrap_or(e)),
            };
            let mut n: i64 = 0;
            for c in digits.chars().filter(|c| c.is_ascii_digit()) {
                n = n * 10 + i64::from(c as u8 - b'0');
                // cvt.cpp's SHORT_LIMIT, (1 << 14) / 5
                if n >= 3276 {
                    return true;
                }
            }
            if neg { -n } else { n }
        }
        None => 0,
    };
    (frac - exp).abs() > 308
}

/// Decode a decimal64 from its little-endian-loaded 64 bits
/// (decimal64.c decimal64ToNumber): bit 57 is the signaling flag and
/// the low 50 bits (5 declets) the payload - `sourhi &= 0x0003ffff`.
pub fn decode_dec64(v: u64) -> Dec {
    let neg = v >> 63 != 0;
    match combination((v >> 58) as u32 & 0x1F) {
        Err(true) => Dec::Infinity { neg },
        Err(false) => Dec::Nan {
            neg,
            signaling: v >> 57 & 1 == 1,
            payload: declets(0, v as u128 & ((1 << 50) - 1), 5),
        },
        Ok((exp_top, msd)) => {
            let exp = ((exp_top << 8) | ((v >> 50) as u32 & 0xFF)) as i32 - 398;
            Dec::Finite { neg, coeff: declets(msd, v as u128, 5), exp }
        }
    }
}

/// Decode a decimal128 from its little-endian-loaded 128 bits
/// (decimal128.c decimal128ToNumber): bit 121 is the signaling flag
/// and the low 110 bits (11 declets) the payload.
pub fn decode_dec128(v: u128) -> Dec {
    let neg = v >> 127 != 0;
    match combination((v >> 122) as u32 & 0x1F) {
        Err(true) => Dec::Infinity { neg },
        Err(false) => Dec::Nan {
            neg,
            signaling: v >> 121 & 1 == 1,
            payload: declets(0, v & ((1 << 110) - 1), 11),
        },
        Ok((exp_top, msd)) => {
            let exp = ((exp_top << 12) | ((v >> 110) as u32 & 0xFFF)) as i32 - 6176;
            Dec::Finite { neg, coeff: declets(msd, v, 11), exp }
        }
    }
}

/// decNumberToString (decNumber.c): the one textual form isql prints.
pub fn to_string(d: &Dec) -> String {
    match d {
        Dec::Infinity { neg: false } => "Infinity".into(),
        Dec::Infinity { neg: true } => "-Infinity".into(),
        // decToString's NaN branch: the sign first, `s` for a
        // signaling NaN, then the payload when it is not a clean
        // zero (`NaN123`, `sNaN789`, `-NaN` - all probed)
        Dec::Nan { neg, signaling, payload } => {
            let mut s = String::new();
            if *neg {
                s.push('-');
            }
            if *signaling {
                s.push('s');
            }
            s.push_str("NaN");
            if *payload != 0 {
                s.push_str(&payload.to_string());
            }
            s
        }
        Dec::Finite { neg, coeff, exp } => {
            let digits = coeff.to_string();
            let len = digits.len() as i32;
            let adjusted = exp + len - 1;
            let body = if *exp <= 0 && adjusted >= -6 {
                if *exp == 0 {
                    digits
                } else if adjusted >= 0 {
                    let split = (adjusted + 1) as usize;
                    format!("{}.{}", &digits[..split], &digits[split..])
                } else {
                    format!("0.{}{}", "0".repeat((-adjusted - 1) as usize), digits)
                }
            } else {
                let mantissa = if len > 1 {
                    format!("{}.{}", &digits[..1], &digits[1..])
                } else {
                    digits
                };
                format!("{}E{}{}", mantissa, if adjusted < 0 { "-" } else { "+" }, adjusted.abs())
            };
            if *neg { format!("-{}", body) } else { body }
        }
    }
}

/// Order two decoded values by VALUE the way the engine compares
/// DECFLOAT: sign first, then magnitude by adjusted exponent and digit
/// comparison; every zero cohort is equal, as is every cohort
/// (`1.5 == 1.50`); infinities beyond all finites. A NaN operand ranks
/// past +Infinity here - the engine's `=`/`<`/MIN/MAX TRAP on one
/// (22000), they never order by it, so callers that implement those
/// check [Dec::is_nan] first ([cmp_value] does it for them).
pub fn cmp(a: &Dec, b: &Dec) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    let rank = |d: &Dec| match d {
        Dec::Nan { .. } => 2,
        Dec::Infinity { neg: false } => 1,
        Dec::Infinity { neg: true } => -1,
        Dec::Finite { .. } => 0,
    };
    let (ra, rb) = (rank(a), rank(b));
    if ra != 0 || rb != 0 {
        return ra.cmp(&rb);
    }
    let (Dec::Finite { neg: na, coeff: ca, exp: ea }, Dec::Finite { neg: nb, coeff: cb, exp: eb }) =
        (a, b)
    else {
        unreachable!()
    };
    match (*ca == 0, *cb == 0) {
        (true, true) => return Equal,
        (true, false) => return if *nb { Greater } else { Less },
        (false, true) => return if *na { Less } else { Greater },
        _ => {}
    }
    if na != nb {
        return if *na { Less } else { Greater };
    }
    let da = ca.to_string();
    let db = cb.to_string();
    let adj = |d: &str, e: i32| e + d.len() as i32 - 1;
    let mag = match adj(&da, *ea).cmp(&adj(&db, *eb)) {
        Equal => {
            // same magnitude class: compare digits zero-padded to equal length
            let width = da.len().max(db.len());
            let pa = format!("{:0<width$}", da);
            let pb = format!("{:0<width$}", db);
            pa.cmp(&pb)
        }
        o => o,
    };
    if *na { mag.reverse() } else { mag }
}

/// A VALUE comparison that traps like the engine's: `Err(())` when
/// either side is a NaN (quiet or signaling - the engine's 22000),
/// else [cmp]. For `=`/`<`/MIN/MAX/fold comparisons.
pub fn cmp_value(a: &Dec, b: &Dec) -> Result<std::cmp::Ordering, ()> {
    if a.is_nan() || b.is_nan() {
        return Err(());
    }
    Ok(cmp(a, b))
}

/// The sort record past the keys, the way sort.cpp's `DO_32_COMPARE`
/// compares it: the record's ULONGs in address order, each numeric
/// ascending (on x86 a little-endian load, so within one ULONG the
/// HIGH byte is major - four big-endian groups in address order).
/// Two decimal128 records: all four words.
pub fn rec_cmp_128(a: u128, b: u128) -> std::cmp::Ordering {
    let (aw, bw) = (a.to_le_bytes(), b.to_le_bytes());
    (0..4)
        .map(|i| {
            let s = 4 * i;
            u32::from_le_bytes([aw[s], aw[s + 1], aw[s + 2], aw[s + 3]])
                .cmp(&u32::from_le_bytes([bw[s], bw[s + 1], bw[s + 2], bw[s + 3]]))
        })
        .find(|o| *o != std::cmp::Ordering::Equal)
        .unwrap_or(std::cmp::Ordering::Equal)
}

/// Two decimal64 records: the same law over two ULONGs (a native
/// dec16 sort's 8-byte records: the exponent rides ULONG[1], so a
/// dec128 re-encode can order an exotic middle-declet tie
/// differently - the 64-bit entry points below keep the width).
pub fn rec_cmp_64(a: u64, b: u64) -> std::cmp::Ordering {
    let (aw, bw) = (a.to_le_bytes(), b.to_le_bytes());
    (0..2)
        .map(|i| {
            let s = 4 * i;
            u32::from_le_bytes([aw[s], aw[s + 1], aw[s + 2], aw[s + 3]])
                .cmp(&u32::from_le_bytes([bw[s], bw[s + 1], bw[s + 2], bw[s + 3]]))
        })
        .find(|o| *o != std::cmp::Ordering::Equal)
        .unwrap_or(std::cmp::Ordering::Equal)
}

/// Order two decoded values the way the engine's ORDER BY does: the
/// sort-key order of DecFloat.cpp `make` (specials by class, finites
/// by value - `make` normalizes every cohort, zero and payload group
/// to ONE key), then the sort record past the keys (sort.cpp compares
/// the whole record in memory: `m_longs - 1` ULONGs), all probed.
/// Ascending:
///
/// `-NaN < -sNaN < -Inf < negative < zero < positive < +Inf < +sNaN <
/// +NaN`; value ties break by the canonical record bytes
/// ([rec_cmp_128]): `88.0 < 88 < 88.00` (ULONG[0] 14 < 78 < 8204),
/// `1.5 < 1.50 < 1.500`, `0.00 < 0 < 0E+5 < -0E-3 < -0`, the
/// full-width cohort member first; NaNs of one (sign, class) likewise
/// (`NaN < NaN123 < NaN999 < NaN456 < NaN1000`: ULONG[0] 0 < 163 <
/// 255 < 598 < 1024). Descending reverses the ranks and the finite
/// values but keeps EVERY tiebreak ascending (`desc`).
///
/// The tiebreak re-encodes both sides at dec128 width (a union widens
/// dec16 to dec34 before the sort, so mixed widths meet here); a
/// NATIVE dec16 sort wants [cmp_total_64], a native dec34 one
/// [cmp_total_128], both of which compare the caller's record bytes.
pub fn cmp_total(a: &Dec, b: &Dec, desc: bool) -> std::cmp::Ordering {
    cmp_total_with(a, b, desc, || rec_cmp_128(dec_to_bits(a), dec_to_bits(b)))
}

/// [cmp_total] over two native decimal128 records: the ranks and the
/// value from the decoded pair, the tiebreak from the caller's record
/// bytes (the exact bytes the sort compared - no re-encode).
pub fn cmp_total_128(a: &Dec, abits: u128, b: &Dec, bbits: u128, desc: bool) -> std::cmp::Ordering {
    cmp_total_with(a, b, desc, || rec_cmp_128(abits, bbits))
}

/// [cmp_total] over two native decimal64 records: same ranks and
/// value, the tiebreak over the 8-byte records ([rec_cmp_64]).
pub fn cmp_total_64(a: &Dec, abits: u64, b: &Dec, bbits: u64, desc: bool) -> std::cmp::Ordering {
    cmp_total_with(a, b, desc, || rec_cmp_64(abits, bbits))
}

/// Order two decoded values by the engine's SORT KEY alone
/// (DecFloat.cpp `make`): the class ranks, then the value - cohorts,
/// zeros and payloads compare EQUAL here, the record past the keys
/// deciding them in the sort. Descending reverses ranks and values.
/// This is what a sort's KEY comparison is; [cmp_total] folds the
/// record tiebreak in for sorts without record bytes (the
/// interpreter's in-memory order, DISTINCT survivors).
/// The sort-key class rank: `make()`'s key order (OFF_inf = 3,
/// OFF_snan = 2, OFF_nan = 1, signs negated) with finites split by
/// sign: `-NaN < -sNaN < -Inf < negative < zero < positive < +Inf <
/// +sNaN < +NaN`.
fn class_rank(d: &Dec) -> u8 {
    match d {
        Dec::Nan { neg: true, signaling: false, .. } => 0,
        Dec::Nan { neg: true, signaling: true, .. } => 1,
        Dec::Infinity { neg: true } => 2,
        Dec::Finite { coeff: 0, .. } => 4,
        Dec::Finite { neg: false, .. } => 5,
        Dec::Finite { neg: true, .. } => 3,
        Dec::Infinity { neg: false } => 6,
        Dec::Nan { neg: false, signaling: true, .. } => 7,
        Dec::Nan { neg: false, signaling: false, .. } => 8,
        Dec::Nan { .. } => unreachable!("signs covered"),
    }
}

pub fn cmp_key(a: &Dec, b: &Dec, desc: bool) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    let (ra, rb) = (class_rank(a), class_rank(b));
    if ra != rb {
        let o = ra.cmp(&rb);
        return if desc { o.reverse() } else { o };
    }
    match (a, b) {
        (Dec::Nan { .. }, Dec::Nan { .. }) => Equal,
        (Dec::Finite { .. }, Dec::Finite { .. }) => match cmp(a, b) {
            Equal => Equal,
            o => {
                if desc {
                    o.reverse()
                } else {
                    o
                }
            }
        },
        _ => Equal,
    }
}

/// The integral-rounding direction for [to_integral].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum IntegralMode {
    Ceil,
    Floor,
    Trunc,
    Round,
}

/// `decQuadToIntegralValue` (Decimal128::floor / ceil / evlTrunc /
/// evlRound): toward +inf, -inf, zero, or HALF-UP-away-from-zero.
/// Non-finite values pass through (the caller traps sNaN first);
/// the cohort keeps its sign, the exponent lands on 0.
pub fn to_integral(d: &Dec, mode: IntegralMode) -> Dec {
    let Dec::Finite { neg, coeff, exp } = d else { return d.clone() };
    if *exp >= 0 {
        return d.clone();
    }
    let (q, rem) = match 10u128.checked_pow((-exp) as u32) {
        Some(p) => (coeff / p, coeff % p),
        None => (0, *coeff),
    };
    let up = match mode {
        IntegralMode::Trunc => false,
        IntegralMode::Floor => *neg && rem != 0,
        IntegralMode::Ceil => !*neg && rem != 0,
        IntegralMode::Round => 10u128.checked_pow((-exp - 1) as u32).is_some_and(|h| rem >= 5 * h),
    };
    Dec::Finite { neg: *neg, coeff: q + up as u128, exp: 0 }
}

fn cmp_total_with(
    a: &Dec,
    b: &Dec,
    desc: bool,
    tie: impl FnOnce() -> std::cmp::Ordering,
) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    let (ra, rb) = (class_rank(a), class_rank(b));
    if ra != rb {
        let o = ra.cmp(&rb);
        return if desc { o.reverse() } else { o };
    }
    match (a, b) {
        // one (sign, class): make() drops the payload from the key,
        // so the record past the keys decides, either direction
        (Dec::Nan { .. }, Dec::Nan { .. }) => tie(),
        (Dec::Finite { .. }, Dec::Finite { .. }) => match cmp(a, b) {
            // one value: make() normalized every cohort to one key,
            // so the record past the keys decides, either direction
            Equal => tie(),
            o => {
                if desc {
                    o.reverse()
                } else {
                    o
                }
            }
        },
        _ => Equal,
    }
}

/// TRUE when two decoded values share a DISTINCT / UNION / deduplication
/// group on the engine: finites of one value and (past zero) one sign,
/// infinities of one sign, quiet NaNs of one sign across payloads, an
/// sNaN only with its identical twin. Never traps (dedup answers over
/// NaN where `=` signals). The surviving representative is the
/// [cmp_total]-greatest (ascending) of the group.
pub fn dedup_eq(a: &Dec, b: &Dec) -> bool {
    match (a, b) {
        (
            Dec::Finite { neg: na, coeff: ca, .. },
            Dec::Finite { neg: nb, coeff: cb, .. },
        ) => cmp(a, b) == std::cmp::Ordering::Equal && (ca == &0 || cb == &0 || na == nb),
        (Dec::Infinity { neg: x }, Dec::Infinity { neg: y }) => x == y,
        (
            Dec::Nan { neg: x, signaling: false, .. },
            Dec::Nan { neg: y, signaling: false, .. },
        ) => x == y,
        (
            Dec::Nan { neg: x, signaling: true, payload: px },
            Dec::Nan { neg: y, signaling: true, payload: py },
        ) => x == y && px == py,
        _ => false,
    }
}

/// IEEE 754 totalOrder of two decoded DECFLOATs (decQuadCompareTotal):
/// numeric order first; among equal values a -0 before a +0, then the
/// cohorts - the smaller exponent first for a positive value, the larger
/// for a negative one (`1.00 < 1.0 < 1`, `-1 < -1.0`); a NaN beyond
/// +Infinity, signed NaNs below -Infinity, signaling before quiet on the
/// positive side and after it on the negative one (negation symmetry),
/// payloads smaller-first (reversed for negatives, by the same symmetry).
/// This is TOTALORDER/COMPARE_DECFLOAT's order - NOT ORDER BY's (whose
/// zeros and cohorts sort the other way: [cmp_total]).
pub fn totalorder_cmp(a: &Dec, b: &Dec) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    // the NaN ranks: -qNaN < -sNaN < everything < +sNaN < +qNaN
    let nan_rank = |d: &Dec| match d {
        Dec::Nan { neg: true, signaling: false, .. } => Some(0),
        Dec::Nan { neg: true, signaling: true, .. } => Some(1),
        Dec::Nan { neg: false, signaling: true, .. } => Some(3),
        Dec::Nan { neg: false, signaling: false, .. } => Some(4),
        _ => None,
    };
    match (nan_rank(a), nan_rank(b)) {
        (Some(x), Some(y)) if x != y => return x.cmp(&y),
        (Some(_), Some(_)) => {
            // one (sign, class): payloads smaller-first, reversed for
            // negatives (totalOrder(-x, -y) is totalOrder(y, x))
            let (Dec::Nan { neg: na, payload: pa, .. }, Dec::Nan { neg: nb, payload: pb, .. }) = (a, b)
            else {
                unreachable!()
            };
            debug_assert_eq!(na, nb);
            return if *na { pb.cmp(pa) } else { pa.cmp(pb) };
        }
        (Some(r), None) => return if r < 2 { Less } else { Greater },
        (None, Some(r)) => return if r < 2 { Greater } else { Less },
        (None, None) => {}
    }
    match cmp(a, b) {
        Equal => {}
        o => return o,
    }
    match (a, b) {
        (Dec::Finite { neg: na, exp: ea, .. }, Dec::Finite { neg: nb, exp: eb, .. }) => {
            if na != nb {
                return if *na { Less } else { Greater };
            }
            if *na { eb.cmp(ea) } else { ea.cmp(eb) }
        }
        _ => Equal,
    }
}

/// `BIN2DPD` (decDPD.h:317): 3 decimal digits (0..=999) -> the 10-bit
/// declet decNumber emits, the CANONICAL inverse of [DPD2BIN]. Kept as a
/// separate table (not derived from DPD2BIN, which is many-to-one over
/// the 24 non-canonical declets) so an ENCODED value is byte-identical to
/// the engine's, not merely decode-equal.
const BIN2DPD: [u16; 1000] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 48, 49,
    50, 51, 52, 53, 54, 55, 56, 57, 64, 65, 66, 67, 68, 69, 70, 71,
    72, 73, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 96, 97, 98, 99,
    100, 101, 102, 103, 104, 105, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
    10, 11, 42, 43, 74, 75, 106, 107, 78, 79, 26, 27, 58, 59, 90, 91,
    122, 123, 94, 95, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 144, 145,
    146, 147, 148, 149, 150, 151, 152, 153, 160, 161, 162, 163, 164, 165, 166, 167,
    168, 169, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 192, 193, 194, 195,
    196, 197, 198, 199, 200, 201, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217,
    224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 240, 241, 242, 243, 244, 245,
    246, 247, 248, 249, 138, 139, 170, 171, 202, 203, 234, 235, 206, 207, 154, 155,
    186, 187, 218, 219, 250, 251, 222, 223, 256, 257, 258, 259, 260, 261, 262, 263,
    264, 265, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 288, 289, 290, 291,
    292, 293, 294, 295, 296, 297, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313,
    320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 336, 337, 338, 339, 340, 341,
    342, 343, 344, 345, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 368, 369,
    370, 371, 372, 373, 374, 375, 376, 377, 266, 267, 298, 299, 330, 331, 362, 363,
    334, 335, 282, 283, 314, 315, 346, 347, 378, 379, 350, 351, 384, 385, 386, 387,
    388, 389, 390, 391, 392, 393, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409,
    416, 417, 418, 419, 420, 421, 422, 423, 424, 425, 432, 433, 434, 435, 436, 437,
    438, 439, 440, 441, 448, 449, 450, 451, 452, 453, 454, 455, 456, 457, 464, 465,
    466, 467, 468, 469, 470, 471, 472, 473, 480, 481, 482, 483, 484, 485, 486, 487,
    488, 489, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 394, 395, 426, 427,
    458, 459, 490, 491, 462, 463, 410, 411, 442, 443, 474, 475, 506, 507, 478, 479,
    512, 513, 514, 515, 516, 517, 518, 519, 520, 521, 528, 529, 530, 531, 532, 533,
    534, 535, 536, 537, 544, 545, 546, 547, 548, 549, 550, 551, 552, 553, 560, 561,
    562, 563, 564, 565, 566, 567, 568, 569, 576, 577, 578, 579, 580, 581, 582, 583,
    584, 585, 592, 593, 594, 595, 596, 597, 598, 599, 600, 601, 608, 609, 610, 611,
    612, 613, 614, 615, 616, 617, 624, 625, 626, 627, 628, 629, 630, 631, 632, 633,
    522, 523, 554, 555, 586, 587, 618, 619, 590, 591, 538, 539, 570, 571, 602, 603,
    634, 635, 606, 607, 640, 641, 642, 643, 644, 645, 646, 647, 648, 649, 656, 657,
    658, 659, 660, 661, 662, 663, 664, 665, 672, 673, 674, 675, 676, 677, 678, 679,
    680, 681, 688, 689, 690, 691, 692, 693, 694, 695, 696, 697, 704, 705, 706, 707,
    708, 709, 710, 711, 712, 713, 720, 721, 722, 723, 724, 725, 726, 727, 728, 729,
    736, 737, 738, 739, 740, 741, 742, 743, 744, 745, 752, 753, 754, 755, 756, 757,
    758, 759, 760, 761, 650, 651, 682, 683, 714, 715, 746, 747, 718, 719, 666, 667,
    698, 699, 730, 731, 762, 763, 734, 735, 768, 769, 770, 771, 772, 773, 774, 775,
    776, 777, 784, 785, 786, 787, 788, 789, 790, 791, 792, 793, 800, 801, 802, 803,
    804, 805, 806, 807, 808, 809, 816, 817, 818, 819, 820, 821, 822, 823, 824, 825,
    832, 833, 834, 835, 836, 837, 838, 839, 840, 841, 848, 849, 850, 851, 852, 853,
    854, 855, 856, 857, 864, 865, 866, 867, 868, 869, 870, 871, 872, 873, 880, 881,
    882, 883, 884, 885, 886, 887, 888, 889, 778, 779, 810, 811, 842, 843, 874, 875,
    846, 847, 794, 795, 826, 827, 858, 859, 890, 891, 862, 863, 896, 897, 898, 899,
    900, 901, 902, 903, 904, 905, 912, 913, 914, 915, 916, 917, 918, 919, 920, 921,
    928, 929, 930, 931, 932, 933, 934, 935, 936, 937, 944, 945, 946, 947, 948, 949,
    950, 951, 952, 953, 960, 961, 962, 963, 964, 965, 966, 967, 968, 969, 976, 977,
    978, 979, 980, 981, 982, 983, 984, 985, 992, 993, 994, 995, 996, 997, 998, 999,
    1000, 1001, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 906, 907, 938, 939,
    970, 971, 1002, 1003, 974, 975, 922, 923, 954, 955, 986, 987, 1018, 1019, 990, 991,
    12, 13, 268, 269, 524, 525, 780, 781, 46, 47, 28, 29, 284, 285, 540, 541,
    796, 797, 62, 63, 44, 45, 300, 301, 556, 557, 812, 813, 302, 303, 60, 61,
    316, 317, 572, 573, 828, 829, 318, 319, 76, 77, 332, 333, 588, 589, 844, 845,
    558, 559, 92, 93, 348, 349, 604, 605, 860, 861, 574, 575, 108, 109, 364, 365,
    620, 621, 876, 877, 814, 815, 124, 125, 380, 381, 636, 637, 892, 893, 830, 831,
    14, 15, 270, 271, 526, 527, 782, 783, 110, 111, 30, 31, 286, 287, 542, 543,
    798, 799, 126, 127, 140, 141, 396, 397, 652, 653, 908, 909, 174, 175, 156, 157,
    412, 413, 668, 669, 924, 925, 190, 191, 172, 173, 428, 429, 684, 685, 940, 941,
    430, 431, 188, 189, 444, 445, 700, 701, 956, 957, 446, 447, 204, 205, 460, 461,
    716, 717, 972, 973, 686, 687, 220, 221, 476, 477, 732, 733, 988, 989, 702, 703,
    236, 237, 492, 493, 748, 749, 1004, 1005, 942, 943, 252, 253, 508, 509, 764, 765,
    1020, 1021, 958, 959, 142, 143, 398, 399, 654, 655, 910, 911, 238, 239, 158, 159,
    414, 415, 670, 671, 926, 927, 254, 255,
];

/// Encode a FINITE decimal128 from (sign, coefficient, exponent-of-the-
/// last-digit), the exact inverse of [decode_dec128]. `coeff` carries up
/// to 34 decimal digits; `exp` is unbiased (the engine's `qe`), in
/// [-6176, 6111]. The exponent's top two bits are always < 0b11 for a
/// valid decimal128 (biased qe <= 12287 < 3*4096), which is exactly the
/// slot the combination field reserves for them, so the split below never
/// collides with the large-digit (8/9) or special encodings.
pub fn encode_dec128(neg: bool, coeff: u128, exp: i32) -> u128 {
    let biased = (exp + 6176) as u32;
    // 34 digits, MSD first (zero-padded); the MSD rides the combination
    // field, the remaining 33 ride 11 declets of 3 digits each
    let digits = format!("{coeff:0>34}");
    let db = digits.as_bytes();
    let msd = (db[0] - b'0') as u128;
    let exp_top = ((biased >> 12) & 0x3) as u128; // 0b00/0b01/0b10 only
    let comb = if msd <= 7 {
        (exp_top << 3) | msd
    } else {
        0b11000 | (exp_top << 1) | (msd & 1)
    };
    let mut v: u128 = ((neg as u128) << 127) | (comb << 122) | (((biased & 0xFFF) as u128) << 110);
    // group j=0 is the MOST significant declet (digits right after the
    // MSD); it lands in declet slot 10, matching decode's MSB-first read
    for j in 0..11 {
        let s = 1 + 3 * j;
        let three =
            (db[s] - b'0') as usize * 100 + (db[s + 1] - b'0') as usize * 10 + (db[s + 2] - b'0') as usize;
        v |= (BIN2DPD[three] as u128) << (10 * (10 - j));
    }
    v
}

/// Encode a FINITE decimal64 from (sign, coefficient, exponent-of-the-
/// last-digit), the exact inverse of [decode_dec64]. `coeff` carries up to
/// 16 decimal digits; `exp` is unbiased (the engine's `qe`), in
/// [-398, 369]. The exponent's top two bits are always < 0b11 for a valid
/// decimal64 (biased qe <= 767 < 3*256), the same combination-field
/// guarantee decimal128 has.
pub fn encode_dec64(neg: bool, mut coeff: u64, mut exp: i32) -> u64 {
    // BRING THE VALUE INTO CANONICAL RANGE: the stored exponent qe must
    // be <= 369, or `biased` overflows its two combination-field bits and
    // garbles the whole word. A value handed in with a higher exponent
    // and a short coefficient - a cast of `1E+384` arrives as coeff 1,
    // exp 384 - is padded with trailing zeros: qe drops toward 369 while
    // the coefficient stays within 16 digits (each x10 keeps it <= 10^16
    // - 1). A value whose exponent still exceeds 369 after padding is a
    // decimal64 overflow the caller must reject up front ([fit_dec64]);
    // reaching here with one only keeps the encoding well-formed.
    while exp > 369 && coeff <= 999_999_999_999_999 {
        coeff *= 10;
        exp -= 1;
    }
    let biased = (exp + 398) as u32;
    // 16 digits, MSD first; the MSD rides the combination field, the
    // remaining 15 ride 5 declets of 3 digits each
    let digits = format!("{coeff:0>16}");
    let db = digits.as_bytes();
    let msd = (db[0] - b'0') as u64;
    let exp_top = ((biased >> 8) & 0x3) as u64; // 0b00/0b01/0b10 only
    let comb = if msd <= 7 {
        (exp_top << 3) | msd
    } else {
        0b11000 | (exp_top << 1) | (msd & 1)
    };
    let mut v: u64 = ((neg as u64) << 63) | (comb << 58) | (((biased & 0xFF) as u64) << 50);
    // group j=0 is the MOST significant declet; it lands in declet slot 4,
    // matching decode's MSB-first read
    for j in 0..5 {
        let s = 1 + 3 * j;
        let three =
            (db[s] - b'0') as usize * 100 + (db[s + 1] - b'0') as usize * 10 + (db[s + 2] - b'0') as usize;
        v |= (BIN2DPD[three] as u64) << (10 * (4 - j));
    }
    v
}

/// THE CONTEXT'S ROUNDING MODE - `SET DECFLOAT ROUND <mode>`, decNumber's
/// rounding names. It decides every rounding the decimal context makes: an
/// operation's result to 34 digits, a narrowing to 16, a text or an exact
/// numeric converted in, a CAST out to an exact numeric, ROUND and
/// QUANTIZE (measured on 2196: `2/3` is ..667 under HALF_UP / UP /
/// CEILING and ..666 under DOWN / FLOOR / REROUND, `QUANTIZE(-2.5, 1)` -2
/// under CEILING and -3 under FLOOR); TRUNC / CEILING / FLOOR keep their
/// own direction and a square root its own HALF-EVEN.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rounding {
    Ceiling,
    Up,
    HalfUp,
    HalfEven,
    HalfDown,
    Down,
    Floor,
    /// decNumber's DEC_ROUND_05UP: away from zero only when the kept last
    /// digit is 0 or 5 (and something non-zero was dropped)
    ReRound,
}

thread_local! {
    /// the session's mode ([Rounding]); HALF_UP is the engine's default
    static ROUNDING: std::cell::Cell<Rounding> = const { std::cell::Cell::new(Rounding::HalfUp) };
}

/// The session's rounding mode.
pub fn rounding() -> Rounding {
    ROUNDING.with(|r| r.get())
}

/// Set the session's rounding mode (`SET DECFLOAT ROUND`).
pub fn set_rounding(mode: Rounding) {
    ROUNDING.with(|r| r.set(mode));
}

/// Does dropping digits round the KEPT MAGNITUDE up (away from zero), under
/// the session's mode? `last` is the last kept digit, `first` the first
/// dropped one and `rest` whether any later dropped digit is non-zero.
pub fn rounds_up(neg: bool, last: u8, first: u8, rest: bool) -> bool {
    let dropped = first != 0 || rest;
    match rounding() {
        Rounding::HalfUp => first >= 5,
        Rounding::HalfEven => first > 5 || (first == 5 && (rest || last % 2 == 1)),
        Rounding::HalfDown => first > 5 || (first == 5 && rest),
        Rounding::Up => dropped,
        Rounding::Down => false,
        Rounding::Ceiling => dropped && !neg,
        Rounding::Floor => dropped && neg,
        Rounding::ReRound => dropped && (last == 0 || last == 5),
    }
}

/// [rounds_up] over ASCII digit strings: the kept digits' last, and the
/// dropped run.
fn rounds_up_ascii(neg: bool, kept: &[u8], dropped: &[u8]) -> bool {
    let last = kept.last().map_or(0, |d| d - b'0');
    let first = dropped.first().map_or(0, |d| d - b'0');
    let rest = dropped.iter().skip(1).any(|d| *d != b'0');
    !dropped.is_empty() && rounds_up(neg, last, first, rest)
}

/// [rounds_up] for an integer `q` kept after dividing by `p = 10^n` with
/// remainder `r`.
fn rounds_up_rem(neg: bool, q: u128, r: u128, p: u128) -> bool {
    if p <= 1 {
        return false;
    }
    let tenth = p / 10;
    let first = (r / tenth) as u8;
    let rest = r % tenth != 0;
    rounds_up(neg, (q % 10) as u8, first, rest)
}

/// [dec128_from_int_digits] for a DECFLOAT(16): rounds to 16 significant
/// digits (HALF-UP) and encodes as decimal64. Used when a wide integer
/// literal targets a DECFLOAT(16) column.
pub fn dec64_from_int_digits(neg: bool, digits: &[u8]) -> u64 {
    let first = digits.iter().position(|&d| d != b'0').unwrap_or(digits.len() - 1);
    let sig = &digits[first..];
    let fold = |ds: &[u8]| ds.iter().fold(0u64, |m, &d| m * 10 + (d - b'0') as u64);
    if sig.len() <= 16 {
        return encode_dec64(neg, fold(sig), 0);
    }
    let mut coeff = fold(&sig[..16]);
    let rest = &sig[16..];
    let mut exp = rest.len() as i32;
    if rounds_up_ascii(neg, &sig[..16], rest) {
        coeff += 1;
        if coeff == 10u64.pow(16) {
            coeff /= 10;
            exp += 1;
        }
    }
    encode_dec64(neg, coeff, exp)
}

/// [round_to_dec34] to 16 significant digits, for a value already in [Dec]
/// form that must fit a decimal64. NOTE: rounding a value that was ALREADY
/// rounded to 34 digits is a DOUBLE ROUNDING - faithful for every value
/// but the vanishingly rare one whose digits 17..34 hide a carry the
/// original digits 17..N would not have made.
pub fn round_to_dec16(neg: bool, coeff: u128, exp: i32) -> Dec {
    let digits = coeff.to_string();
    if digits.len() <= 16 {
        return Dec::Finite { neg, coeff, exp };
    }
    let drop = digits.len() - 16;
    let mut c: u128 = digits[..16].parse().unwrap();
    let mut e = exp + drop as i32;
    if rounds_up_ascii(neg, &digits.as_bytes()[..16], &digits.as_bytes()[16..]) {
        c += 1;
        if c == 10u128.pow(16) {
            c /= 10;
            e += 1;
        }
    }
    Dec::Finite { neg, coeff: c, exp: e }
}

// --- decimal arithmetic on decoded values -------------------------------
// Digit-string big-decimal (MSD-first ASCII, no leading zeros, "0" = zero):
// exact, then rounded to 34 significant digits HALF-UP - the engine's
// DecimalContext rounding (probed). A 34x34 multiply overflows every fixed
// integer, so the coefficients are carried as digit strings.

pub(crate) fn strip0(mut d: Vec<u8>) -> Vec<u8> {
    let nz = d.iter().position(|&c| c != b'0').unwrap_or(d.len() - 1);
    d.drain(..nz);
    d
}
pub(crate) fn ucmp(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}
pub(crate) fn uadd(a: &[u8], b: &[u8]) -> Vec<u8> {
    let mut r = Vec::new();
    let mut carry = 0u8;
    let (mut i, mut j) = (a.len(), b.len());
    while i > 0 || j > 0 || carry > 0 {
        let x = if i > 0 { i -= 1; a[i] - b'0' } else { 0 };
        let y = if j > 0 { j -= 1; b[j] - b'0' } else { 0 };
        let s = x + y + carry;
        r.push(b'0' + s % 10);
        carry = s / 10;
    }
    r.reverse();
    strip0(r)
}
pub(crate) fn usub(a: &[u8], b: &[u8]) -> Vec<u8> {
    // requires a >= b
    let mut r = Vec::new();
    let mut borrow = 0i8;
    let (mut i, mut j) = (a.len(), b.len());
    while i > 0 {
        i -= 1;
        let x = (a[i] - b'0') as i8;
        let y = if j > 0 { j -= 1; (b[j] - b'0') as i8 } else { 0 };
        let mut d = x - y - borrow;
        if d < 0 { d += 10; borrow = 1; } else { borrow = 0; }
        r.push(b'0' + d as u8);
    }
    r.reverse();
    strip0(r)
}
pub(crate) fn umul(a: &[u8], b: &[u8]) -> Vec<u8> {
    if a == b"0" || b == b"0" {
        return vec![b'0'];
    }
    let mut acc = vec![0u32; a.len() + b.len()];
    for (i, &x) in a.iter().rev().enumerate() {
        for (j, &y) in b.iter().rev().enumerate() {
            acc[i + j] += (x - b'0') as u32 * (y - b'0') as u32;
        }
    }
    let mut out = Vec::new();
    let mut carry = 0u32;
    for v in &acc {
        let s = v + carry;
        out.push(b'0' + (s % 10) as u8);
        carry = s / 10;
    }
    while carry > 0 {
        out.push(b'0' + (carry % 10) as u8);
        carry /= 10;
    }
    out.reverse();
    strip0(out)
}
/// Round MSD-first digits to at most 34 significant, HALF-UP; returns the
/// kept digits and how many places were dropped (added to the exponent).
fn round34(d: &[u8], neg: bool) -> (Vec<u8>, i64) {
    if d.len() <= 34 {
        return (d.to_vec(), 0);
    }
    let mut drop = (d.len() - 34) as i64;
    let mut kept = d[..34].to_vec();
    if rounds_up_ascii(neg, &d[..34], &d[34..]) {
        kept = uadd(&kept, b"1");
        if kept.len() > 34 {
            // carried to 35 digits (all-nines): renormalise
            let extra = kept.len() - 34;
            kept.truncate(34);
            drop += extra as i64;
        }
    }
    (kept, drop)
}
fn digits_u128(d: &[u8]) -> u128 {
    d.iter().fold(0u128, |m, &c| m * 10 + (c - b'0') as u128)
}
/// (sign, coefficient digits MSD-first, exponent) of a finite value.
pub(crate) fn parts(d: &Dec) -> (bool, Vec<u8>, i64) {
    if let Dec::Finite { neg, coeff, exp } = d {
        (*neg, coeff.to_string().into_bytes(), *exp as i64)
    } else {
        unreachable!("parts on a non-finite Dec")
    }
}
/// The result of a decimal128 operation, brought into the format's range
/// the way decNumber's context does it (measured against the engine):
///
/// * an adjusted exponent past emax 6144 is an OVERFLOW - returned as
///   `Infinity` of the result's sign, which a FINITE operation cannot
///   otherwise produce, so the caller traps it as the engine's *Decimal
///   float overflow* (22003). It used to be encoded with the out-of-range
///   exponent, and `9.99..E+6144 + 9.99..E+6144` answered 8.0E-2047;
/// * a stored exponent above 6111 pads the coefficient (`1E+6144` is
///   `1000..0E+6111`, 34 digits), a zero clamping to `0E+6111`;
/// * a stored exponent below -6176 is SUBNORMAL: the digits the format
///   cannot carry round away HALF-UP and the exponent clamps to -6176
///   (`1E-6000 / 1E+200` is `0E-6176`, `5E-6176 * 0.1` is `1E-6176`), where
///   the out-of-range exponent answered garbage (`8.0E-2071`).
/// [finite] for a PRODUCT or a QUOTIENT, whose zero keeps the operands'
/// combined sign (decNumber, IEEE 754): `0 / -2.5` is -0E+1 and `0 * -3`
/// -0 on the engine (measured on 2196). A SUM's exact zero is +0, which
/// is why [finite] itself normalises.
pub(crate) fn finite_signed(neg: bool, digits: Vec<u8>, exp: i64) -> Dec {
    match finite(neg, digits, exp) {
        Dec::Finite { coeff: 0, exp, .. } => Dec::Finite { neg, coeff: 0, exp },
        other => other,
    }
}

pub(crate) fn finite(neg: bool, digits: Vec<u8>, exp: i64) -> Dec {
    let mut d = strip0(digits);
    let mut exp = exp;
    if d != b"0" && exp < -6176 {
        let drop = (-6176 - exp) as usize;
        exp = -6176;
        if drop > d.len() {
            d = vec![b'0'];
        } else {
            let keep = d.len() - drop;
            let up = rounds_up_ascii(neg, &d[..keep], &d[keep..]);
            d.truncate(keep);
            if d.is_empty() {
                d.push(b'0');
            }
            if up {
                d = uadd(&d, b"1");
            }
            d = strip0(d);
        }
    }
    let coeff0 = d == b"0";
    // a zero result normalises to +0 at the working exponent
    let neg = if coeff0 { false } else { neg };
    if coeff0 {
        return Dec::Finite { neg, coeff: 0, exp: exp.clamp(-6176, 6111) as i32 };
    }
    if exp + d.len() as i64 - 1 > 6144 {
        return Dec::Infinity { neg };
    }
    if exp > 6111 {
        d.extend(std::iter::repeat(b'0').take((exp - 6111) as usize));
        exp = 6111;
    }
    Dec::Finite { neg, coeff: digits_u128(&d), exp: exp as i32 }
}

fn sig_len(d: &[u8]) -> usize {
    let s = strip0(d.to_vec());
    if s == b"0" { 0 } else { s.len() }
}
/// (quotient, remainder) of `a / b` as digit strings, schoolbook long
/// division. `b` must be non-zero.
pub(crate) fn udivmod(a: &[u8], b: &[u8]) -> (Vec<u8>, Vec<u8>) {
    if ucmp(a, b) == std::cmp::Ordering::Less {
        return (vec![b'0'], a.to_vec());
    }
    let mut q = Vec::new();
    let mut rem: Vec<u8> = vec![b'0'];
    for &ch in a {
        if rem == b"0" {
            rem = vec![ch];
        } else {
            rem.push(ch);
        }
        rem = strip0(rem);
        // the largest digit d with b*d <= rem
        let mut d = 0u8;
        while d < 9 && ucmp(&umul(b, &[b'0' + d + 1]), &rem) != std::cmp::Ordering::Greater {
            d += 1;
        }
        q.push(b'0' + d);
        rem = usub(&rem, &umul(b, &[b'0' + d]));
    }
    (strip0(q), rem)
}

/// TRUE for a finite zero (any cohort).
pub fn is_zero(d: &Dec) -> bool {
    matches!(d, Dec::Finite { coeff: 0, .. })
}

/// `a / b`, to 34 significant digits HALF-UP. The result exponent falls out
/// of long division over the operands' OWN cohort coefficients - the ideal
/// exponent `e1 - e2` when the quotient is exact there, else as many places
/// as the exact value needs (up to 34 sig): `12.0 / 3` is `4.0`, `1 / 2` is
/// `0.5`, `1 / 3` is 34 threes. A ZERO divisor is the caller's to trap
/// (22012, or 22000 for `0/0`); the specials propagate as decNumber does
/// (`Infinity / Infinity` is NaN, `finite / Infinity` is 0).
pub fn div(a: &Dec, b: &Dec) -> Dec {
    match (a, b) {
        // the LEFT NaN wins, carried whole (sign and payload - the
        // caller traps a signaling one, as for every arithmetic verb)
        (x @ Dec::Nan { .. }, _) => return *x,
        (_, y @ Dec::Nan { .. }) => return *y,
        (Dec::Infinity { .. }, Dec::Infinity { .. }) => return Dec::quiet_nan(),
        (Dec::Infinity { neg: x }, Dec::Finite { neg: f, .. }) => {
            return Dec::Infinity { neg: x != f };
        }
        // the zero lands at the format's least exponent: `5 / -Infinity`
        // is -0E-6176 on the engine (-0E-398 once fitted to DECFLOAT(16))
        (Dec::Finite { neg: f, .. }, Dec::Infinity { neg: x }) => {
            return Dec::Finite { neg: f != x, coeff: 0, exp: -6176 };
        }
        _ => {}
    }
    let (na, ca, ea) = parts(a);
    let (nb, cb, eb) = parts(b);
    if cb == b"0" {
        return if ca == b"0" { Dec::quiet_nan() } else { Dec::Infinity { neg: na != nb } };
    }
    let ideal = ea - eb;
    let (mut q, mut rem) = udivmod(&ca, &cb);
    let mut exp = ideal;
    while rem != b"0" && sig_len(&q) < 35 {
        rem.push(b'0'); // rem *= 10
        rem = strip0(rem);
        let (d, r) = udivmod(&rem, &cb);
        q.extend(d); // a single digit (rem < 10*cb)
        rem = r;
        exp -= 1;
    }
    let (kept, drop) = round34(&strip0(q), na != nb);
    finite_signed(na != nb, kept, exp + drop)
}

/// Encode a computed [Dec] back to its decimal128 bits.
pub fn dec_to_bits(d: &Dec) -> u128 {
    match d {
        Dec::Finite { neg, coeff, exp } => encode_dec128(*neg, *coeff, *exp),
        Dec::Infinity { neg } => encode_dec128_special(*neg, false),
        Dec::Nan { neg, signaling, payload } => encode_dec128_nan(*neg, *signaling, *payload),
    }
}

/// Negate: flips the sign of a finite value - a ZERO too, `-CAST(0 AS
/// DECFLOAT(16))` is -0 on the engine - or an Infinity, or a NaN
/// (`-NaN123` renders so).
pub fn negate(d: &Dec) -> Dec {
    match d {
        Dec::Finite { neg, coeff, exp } => Dec::Finite { neg: !*neg, coeff: *coeff, exp: *exp },
        Dec::Infinity { neg } => Dec::Infinity { neg: !*neg },
        Dec::Nan { neg, signaling, payload } => {
            Dec::Nan { neg: !*neg, signaling: *signaling, payload: *payload }
        }
    }
}

/// `a + b`, to 34 significant digits HALF-UP. `Infinity + -Infinity` is NaN
/// (an invalid operation, which the caller traps); every other special
/// propagates as decNumber does.
pub fn add(a: &Dec, b: &Dec) -> Dec {
    match (a, b) {
        // the RIGHT NaN wins, carried whole - measured on the engine
        // both constant-folded and table-driven (`NaN123 + NaN456` is
        // NaN456, and the reverse is NaN123)
        (_, y @ Dec::Nan { .. }) => return *y,
        (x @ Dec::Nan { .. }, _) => return *x,
        (Dec::Infinity { neg: x }, Dec::Infinity { neg: y }) => {
            return if x == y { Dec::Infinity { neg: *x } } else { Dec::quiet_nan() };
        }
        (Dec::Infinity { neg }, _) | (_, Dec::Infinity { neg }) => return Dec::Infinity { neg: *neg },
        _ => {}
    }
    let (na, ca, ea) = parts(a);
    let (nb, cb, eb) = parts(b);
    let e = ea.min(eb);
    let mut da = ca;
    da.extend(std::iter::repeat(b'0').take((ea - e) as usize));
    let mut db = cb;
    db.extend(std::iter::repeat(b'0').take((eb - e) as usize));
    // the aligned strings must carry NO leading zeros: a zero operand
    // padded to "0000" beside "5" compared LONGER, so the length-first
    // ucmp called it the larger magnitude and the subtraction ran
    // backwards - `-0.5 + 0` answered 9.5 (and SUM of a lone -0.5, which
    // starts from a zero accumulator, likewise)
    let da = strip0(da);
    let db = strip0(db);
    let (sign, mag) = if na == nb {
        (na, uadd(&da, &db))
    } else {
        match ucmp(&da, &db) {
            std::cmp::Ordering::Greater => (na, usub(&da, &db)),
            std::cmp::Ordering::Less => (nb, usub(&db, &da)),
            std::cmp::Ordering::Equal => (false, vec![b'0']),
        }
    };
    // two zeros of ONE sign sum to that sign (`-0 + -0` and `-0 - 0` are -0,
    // IEEE 754); opposite signs cancel to +0 above
    let (kept, drop) = round34(&mag, sign);
    finite_signed(sign, kept, e + drop)
}

/// `a - b`: the LEFT NaN wins, carried whole and UNNEGATED
/// (`1 - NaN456` is NaN456 on the engine), so the NaN arms sit ahead
/// of the negate-then-add finite path.
pub fn sub(a: &Dec, b: &Dec) -> Dec {
    match (a, b) {
        (x @ Dec::Nan { .. }, _) => return *x,
        (_, y @ Dec::Nan { .. }) => return *y,
        _ => {}
    }
    add(a, &negate(b))
}

/// `a * b`, to 34 significant digits HALF-UP.
pub fn mul(a: &Dec, b: &Dec) -> Dec {
    let zero = |d: &Dec| matches!(d, Dec::Finite { coeff: 0, .. });
    match (a, b) {
        // the RIGHT NaN wins, as for [+](`NaN123 * NaN456` is NaN456)
        (_, y @ Dec::Nan { .. }) => return *y,
        (x @ Dec::Nan { .. }, _) => return *x,
        // Infinity * 0 is an invalid operation (NaN)
        (Dec::Infinity { .. }, x) | (x, Dec::Infinity { .. }) if zero(x) => return Dec::quiet_nan(),
        (Dec::Infinity { neg: x }, Dec::Infinity { neg: y }) => {
            return Dec::Infinity { neg: x != y };
        }
        (Dec::Infinity { neg }, Dec::Finite { neg: f, .. })
        | (Dec::Finite { neg: f, .. }, Dec::Infinity { neg }) => {
            return Dec::Infinity { neg: neg != f };
        }
        _ => {}
    }
    let (na, ca, ea) = parts(a);
    let (nb, cb, eb) = parts(b);
    let (kept, drop) = round34(&umul(&ca, &cb), na != nb);
    finite_signed(na != nb, kept, ea + eb + drop)
}

/// `a * b + c` ROUNDED ONCE, to 34 significant digits HALF-UP - the
/// engine's `Decimal128::fma` (decQuadFMA), which its STDDEV / VAR fold
/// uses for the running sum of squares. The exact product joins the
/// addend before any rounding, so it can differ from `add(mul(a, b), c)`
/// in the last digit. A special operand takes the two-step route, whose
/// NaN / Infinity propagation is the same.
pub fn fma(a: &Dec, b: &Dec, c: &Dec) -> Dec {
    let fin = |d: &Dec| matches!(d, Dec::Finite { .. });
    if !(fin(a) && fin(b) && fin(c)) {
        return add(&mul(a, b), c);
    }
    let (na, ca, ea) = parts(a);
    let (nb, cb, eb) = parts(b);
    let (nc, cc, ec) = parts(c);
    let p = umul(&ca, &cb);
    let e = (ea + eb).min(ec);
    let mut dp = p;
    dp.extend(std::iter::repeat(b'0').take((ea + eb - e) as usize));
    let mut dc = cc;
    dc.extend(std::iter::repeat(b'0').take((ec - e) as usize));
    let (dp, dc) = (strip0(dp), strip0(dc));
    let np = na != nb;
    let (sign, mag) = if np == nc {
        (np, uadd(&dp, &dc))
    } else {
        match ucmp(&dp, &dc) {
            std::cmp::Ordering::Greater => (np, usub(&dp, &dc)),
            std::cmp::Ordering::Less => (nc, usub(&dc, &dp)),
            std::cmp::Ordering::Equal => (false, vec![b'0']),
        }
    };
    // two zeros of ONE sign sum to that sign (`-0 + -0` and `-0 - 0` are -0,
    // IEEE 754); opposite signs cancel to +0 above
    let (kept, drop) = round34(&mag, sign);
    finite_signed(sign, kept, e + drop)
}

/// The integer square root (floor) of MSD-first digits, digit pair by
/// digit pair.
fn uisqrt(n: &[u8]) -> Vec<u8> {
    let mut digs = n.to_vec();
    if digs.len() % 2 == 1 {
        digs.insert(0, b'0');
    }
    let mut rem: Vec<u8> = vec![b'0'];
    let mut p: Vec<u8> = vec![b'0'];
    for pair in digs.chunks(2) {
        let mut r = rem;
        r.extend_from_slice(pair);
        let r = strip0(r);
        let p20 = umul(&p, b"20");
        let (mut d, mut take) = (0u8, vec![b'0']);
        for cand in (1..=9u8).rev() {
            let t = umul(&uadd(&p20, &[b'0' + cand]), &[b'0' + cand]);
            if ucmp(&t, &r) != std::cmp::Ordering::Greater {
                d = cand;
                take = t;
                break;
            }
        }
        rem = usub(&r, &take);
        p.push(b'0' + d);
        p = strip0(p);
    }
    p
}

/// The square root, as decNumberSquareRoot answers it at 34 digits: the
/// CORRECTLY ROUNDED root, HALF-EVEN whatever the context's rounding (the
/// routine rounds its approximation under its own DEC_ROUND_HALF_EVEN
/// context), a full 34 digits when inexact. An EXACT root drops trailing
/// zeros down to the ideal exponent floor(e/2) - but only when the trimmed
/// root is short enough that its square fits the working precision
/// (2 * digits - 1 <= max(35, operand digits)); a longer exact root keeps
/// all 34 digits, as decNumber's exactness test never runs for it. A zero
/// keeps its sign at the ideal exponent; a negative operand (and
/// -Infinity) is the invalid operation, answered as NaN for the caller to
/// trap; +Infinity and NaN propagate.
pub fn sqrt(a: &Dec) -> Dec {
    match a {
        // a NaN propagates whole (the caller traps a signaling one)
        x @ Dec::Nan { .. } => return *x,
        Dec::Infinity { neg: false } => return *a,
        Dec::Infinity { neg: true } => return Dec::quiet_nan(),
        Dec::Finite { .. } => {}
    }
    let (neg, c, e) = parts(a);
    let ideal = e.div_euclid(2);
    if c == b"0" {
        return Dec::Finite { neg, coeff: 0, exp: ideal.clamp(-6176, 6111) as i32 };
    }
    if neg {
        return Dec::quiet_nan();
    }
    let l = c.len() as i64;
    // widen to at least 70 digits (a root of at least 35) at an even
    // exponent, so the root carries a rounding digit
    let mut t = (70 - l).max(0);
    if (e - t).rem_euclid(2) != 0 {
        t += 1;
    }
    let mut n = c.clone();
    n.extend(std::iter::repeat(b'0').take(t as usize));
    let s = uisqrt(&n);
    let exact_root = umul(&s, &s) == n;
    let mut exp = (e - t) / 2;
    let drop = s.len() - 34;
    let mut kept = s[..34].to_vec();
    let dropped = &s[34..];
    let first = dropped[0];
    let sticky = dropped[1..].iter().any(|&d| d != b'0') || !exact_root;
    let odd = (kept[33] - b'0') % 2 == 1;
    if first > b'5' || (first == b'5' && (sticky || odd)) {
        kept = uadd(&kept, b"1");
        if kept.len() > 34 {
            kept.truncate(34);
            exp += 1;
        }
    }
    exp += drop as i64;
    let exact = exact_root && dropped.iter().all(|&d| d == b'0');
    if exact {
        let tz = kept.iter().rev().take_while(|&&d| d == b'0').count() as i64;
        let trimmed = 34 - tz;
        let workp = 35.max(l);
        if trimmed * 2 - 1 <= workp {
            let todrop = (ideal - exp).min(tz);
            if todrop > 0 {
                kept.truncate((34 - todrop) as usize);
                exp += todrop;
            }
        }
    }
    finite(false, kept, exp)
}

/// The decimal128 bits of a SPECIAL value: `±Infinity` or `NaN`, the
/// forms decNumber's string grammar accepts as `inf`/`infinity`/`nan`/
/// `snan`. The combination field alone carries them - `11110` is infinity,
/// `11111` NaN ([combination]/[decode_dec128]); the coefficient and
/// exponent are unread. A bare NaN (no payload, quiet); [encode_dec128_nan]
/// carries the signaling flag and the payload.
pub fn encode_dec128_special(neg: bool, nan: bool) -> u128 {
    let comb: u128 = if nan { 0b11111 } else { 0b11110 };
    ((neg as u128) << 127) | (comb << 122)
}

/// The decimal128 bits of a NaN with its form: bit 121 signals, the low
/// 110 bits carry the payload in 11 canonical declets (the exact inverse
/// of [decode_dec128]'s NaN arm).
pub fn encode_dec128_nan(neg: bool, signaling: bool, payload: u128) -> u128 {
    let mut v: u128 = ((neg as u128) << 127) | (0b11111 << 122) | ((signaling as u128) << 121);
    let digits = format!("{payload:0>33}");
    let db = digits.as_bytes();
    for j in 0..11 {
        let s = 3 * j;
        let three =
            (db[s] - b'0') as usize * 100 + (db[s + 1] - b'0') as usize * 10 + (db[s + 2] - b'0') as usize;
        v |= (BIN2DPD[three] as u128) << (10 * (10 - j));
    }
    v
}

/// The decimal64 bits of a SPECIAL value (`±Infinity` / `NaN`), the dec64
/// analog of [encode_dec128_special] (combination field at bits 58..63).
pub fn encode_dec64_special(neg: bool, nan: bool) -> u64 {
    let comb: u64 = if nan { 0b11111 } else { 0b11110 };
    ((neg as u64) << 63) | (comb << 58)
}

/// The decimal64 bits of a NaN with its form: bit 57 signals, the low 50
/// bits carry the payload in 5 canonical declets (the exact inverse of
/// [decode_dec64]'s NaN arm). A payload past 15 digits keeps its LOW 15
/// (the engine's 34-to-16 narrowing, probed).
pub fn encode_dec64_nan(neg: bool, signaling: bool, payload: u128) -> u64 {
    let mut v: u64 = ((neg as u64) << 63) | (0b11111 << 58) | ((signaling as u64) << 57);
    let digits = format!("{:0>15}", payload % 1_000_000_000_000_000);
    let db = digits.as_bytes();
    for j in 0..5 {
        let s = 3 * j;
        let three =
            (db[s] - b'0') as usize * 100 + (db[s + 1] - b'0') as usize * 10 + (db[s + 2] - b'0') as usize;
        v |= (BIN2DPD[three] as u64) << (10 * (4 - j));
    }
    v
}

/// Encode a computed [Dec] as DECFLOAT(16) (decimal64) bits, rounding a
/// finite value to 16 significant digits HALF-UP.
pub fn dec_to_dec64_bits(d: &Dec) -> u64 {
    match d {
        Dec::Finite { neg, coeff, exp } => match round_to_dec16(*neg, *coeff, *exp) {
            Dec::Finite { neg, coeff, exp } => encode_dec64(neg, coeff as u64, exp),
            _ => encode_dec64_special(false, true),
        },
        Dec::Infinity { neg } => encode_dec64_special(*neg, false),
        Dec::Nan { neg, signaling, payload } => encode_dec64_nan(*neg, *signaling, *payload),
    }
}

/// Re-express a DECFLOAT(34) value (its decimal128 bits) as a DECFLOAT(16)
/// (decimal64 bits), rounding to 16 significant digits HALF-UP. `None` for
/// a non-finite value (Infinity/NaN) - a literal is never one, so this only
/// declines the shapes an INSERT of a plain literal cannot reach.
pub fn round_to_dec16_of(bits128: u128) -> Option<u64> {
    match decode_dec128(bits128) {
        Dec::Finite { neg, coeff, exp } => fit_dec64(neg, coeff, exp),
        _ => None,
    }
}

/// Fit a decimal value into decimal64: round to 16 significant digits,
/// normalise the exponent into the storable range, and REFUSE (None) a
/// magnitude the format cannot hold - the engine's 22003 "Decimal float
/// overflow". `coeff`/`exp` are the unrounded value; the returned bits
/// are canonical. Padding brings the stored exponent down to 369 while
/// the coefficient stays within 16 digits; when even a 16-digit
/// coefficient leaves the exponent above 369 (adjusted exponent past
/// emax 384, e.g. `1E+385`), the value overflows and this returns None.
pub fn fit_dec64(neg: bool, coeff: u128, exp: i32) -> Option<u64> {
    // ONE rounding, at the digit position the format can carry: 16
    // significant digits, OR fewer when the exponent would fall below
    // decimal64's minimum -398 (emin -383 minus 15) and the value is
    // SUBNORMAL - the coefficient loses the digits the exponent cannot
    // carry and the exponent clamps to -398. HALF-UP, from the ORIGINAL
    // digits: rounding to 16 first and then to the subnormal position
    // rounded twice ('1.234567894999999999E-390' -> 1.2345678950E-390 ->
    // 1.23456790E-390 where the engine's single decNumber rounding gives
    // 1.23456789E-390). The engine does not trap underflow: '1.5E-398'
    // stores 2E-398, '1e-400' and '0E-500' store 0E-398. Encoding a lower
    // exponent garbled the combination field (8.000000000000001E-129).
    let ndigits = coeff.to_string().len() as i32;
    let e16 = exp + (ndigits - 16).max(0);
    let target = e16.max(-398);
    let (mut c, mut e) = (coeff, exp);
    if target > exp {
        let drop = (target - exp) as u32;
        c = match 10u128.checked_pow(drop) {
            Some(p) => {
                let (q, r) = (c / p, c % p);
                if rounds_up_rem(neg, q, r, p) { q + 1 } else { q }
            }
            None => 0,
        };
        e = target;
        // a carry past 16 digits (9999999999999999|5 -> 10^16) renormalises
        if c == 10u128.pow(16) {
            c /= 10;
            e += 1;
        }
    } else if e < -398 {
        // a zero (or short) coefficient below the floor just clamps
        e = -398;
    }
    while e > 369 && c <= 999_999_999_999_999 {
        c *= 10;
        e -= 1;
    }
    if e > 369 {
        return None; // overflows decimal64 (adjusted exponent > emax 384)
    }
    Some(encode_dec64(neg, c as u64, e))
}

/// Encode a base-10 INTEGER literal (a string of ASCII digits, no sign,
/// leading zeros allowed) as a DECFLOAT(34), rounding to 34 significant
/// digits the way the engine's literal conversion does: HALF-UP (round
/// half AWAY from zero - probed against the live engine, distinct from
/// the HALF-EVEN the text-compare grammar uses). The dropped places move
/// into the exponent; a coefficient that carries to 10^34 renormalises.
pub fn dec128_from_int_digits(neg: bool, digits: &[u8]) -> u128 {
    let first = digits.iter().position(|&d| d != b'0').unwrap_or(digits.len() - 1);
    let sig = &digits[first..];
    let fold = |ds: &[u8]| ds.iter().fold(0u128, |m, &d| m * 10 + (d - b'0') as u128);
    if sig.len() <= 34 {
        return encode_dec128(neg, fold(sig), 0);
    }
    let mut coeff = fold(&sig[..34]);
    let rest = &sig[34..];
    let mut exp = rest.len() as i32;
    // the session's mode decides ([rounds_up]); under HALF-UP the first
    // dropped digit alone (5000.. and 5001.. both round away from zero)
    if rounds_up_ascii(neg, &sig[..34], rest) {
        coeff += 1;
        if coeff == 10u128.pow(34) {
            coeff /= 10;
            exp += 1;
        }
    }
    encode_dec128(neg, coeff, exp)
}

/// Round a decimal (sign, coefficient, exponent-of-the-last-digit) to a
/// finite [Dec] of at most 34 significant digits, HALF-UP (away from
/// zero) - the promotion the engine applies to an EXACT numeric value
/// before comparing it to a DECFLOAT(34). A coefficient already within 34
/// digits is exact; a wider one (an INT128 up to 39 digits) drops its low
/// places into the exponent, carrying to 10^33 when an all-nines run
/// rounds up.
/// Round a decoded DECFLOAT to the fixed-point value `raw * 10^target_exp`
/// and return the signed `raw` - the engine's CAST-out-of-DECFLOAT
/// rounding, HALF-UP (half AWAY FROM ZERO: 2.5 -> 3, -2.5 -> -3). Used by
/// CAST(<decfloat> AS INTEGER) (target_exp 0) and AS NUMERIC(p,s)
/// (target_exp = the declared scale). `None` for a non-finite value
/// (Infinity/NaN) or one that overflows i128 - the caller raises the
/// engine's "decimal float invalid operation" (SQLSTATE 22000).
pub fn round_to_exp(d: &Dec, target_exp: i32) -> Option<i128> {
    let (neg, coeff, exp) = match d {
        Dec::Finite { neg, coeff, exp } => (*neg, *coeff, *exp),
        _ => return None, // Infinity / NaN: no fixed-point value
    };
    let mag: u128 = if exp >= target_exp {
        // scale UP: coeff * 10^(exp - target_exp), exact
        coeff.checked_mul(10u128.checked_pow((exp - target_exp) as u32)?)?
    } else {
        // scale DOWN by (target_exp - exp) digits, rounding the dropped
        // part by the session's mode ([rounds_up]; HALF-UP by default)
        let pow = 10u128.checked_pow((target_exp - exp) as u32)?;
        let q = coeff / pow;
        let r = coeff % pow;
        if rounds_up_rem(neg, q, r, pow) {
            q.checked_add(1)?
        } else {
            q
        }
    };
    let signed = i128::try_from(mag).ok()?;
    Some(if neg { -signed } else { signed })
}

pub fn round_to_dec34(neg: bool, coeff: u128, exp: i32) -> Dec {
    let digits = coeff.to_string();
    if digits.len() <= 34 {
        return Dec::Finite { neg, coeff, exp };
    }
    let drop = digits.len() - 34;
    let mut c: u128 = digits[..34].parse().unwrap();
    let mut e = exp + drop as i32;
    if rounds_up_ascii(neg, &digits.as_bytes()[..34], &digits.as_bytes()[34..]) {
        c += 1;
        if c == 10u128.pow(34) {
            c /= 10;
            e += 1;
        }
    }
    Dec::Finite { neg, coeff: c, exp: e }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_vectors_decode() {
        // +1 in DPD decimal64/128 - the canonical interchange examples
        assert_eq!(
            decode_dec64(0x2238000000000001),
            Dec::Finite { neg: false, coeff: 1, exp: 0 }
        );
        assert_eq!(
            decode_dec128(0x22080000000000000000000000000001),
            Dec::Finite { neg: false, coeff: 1, exp: 0 }
        );
        // sign bit
        assert_eq!(
            decode_dec64(0xA238000000000001),
            Dec::Finite { neg: true, coeff: 1, exp: 0 }
        );
        // specials
        assert!(matches!(decode_dec64(0x7800000000000000), Dec::Infinity { neg: false }));
        assert!(matches!(decode_dec64(0x7C00000000000000), Dec::Nan { .. }));
    }

    #[test]
    fn sqrt_and_fma_as_the_engine_answers() {
        let fin = |coeff: u128, exp| Dec::Finite { neg: false, coeff, exp };
        let s = |d: Dec| to_string(&sqrt(&d));
        // engine STDDEV_SAMP values (measured on 2182)
        assert_eq!(s(fin(5, -1)), "0.7071067811865475244008443621048490");
        assert_eq!(
            s(fin(1266666666666666666666666666666666, -32)),
            "3.559026084010437070270507988531903"
        );
        // exact roots trim to the ideal exponent floor(e/2)
        assert_eq!(s(fin(25, -2)), "0.5");
        assert_eq!(s(fin(2500, -4)), "0.50");
        assert_eq!(s(fin(4, 0)), "2");
        assert_eq!(s(fin(0, -3)), "0.00");
        assert!(matches!(sqrt(&Dec::Finite { neg: true, coeff: 4, exp: 0 }), Dec::Nan { .. }));
        // one rounding: 1.000..01 (34 digits) squared + -1 keeps the tail
        let a = fin(1000000000000000000000000000000001, -33);
        let m1 = Dec::Finite { neg: true, coeff: 1, exp: 0 };
        assert_eq!(to_string(&fma(&a, &a, &m1)), "2.000000000000000000000000000000001E-33");
        assert_eq!(to_string(&add(&mul(&a, &a), &m1)), "2E-33");
    }

    #[test]
    fn renders_like_dec_number_to_string() {
        let f = |neg, coeff, exp| to_string(&Dec::Finite { neg, coeff, exp });
        assert_eq!(f(false, 1, 0), "1");
        assert_eq!(f(false, 15, -1), "1.5"); // cohort preserved
        assert_eq!(f(false, 10000, -2), "100.00"); // trailing zeros survive
        assert_eq!(f(true, 25, -1), "-2.5");
        assert_eq!(f(false, 1, -6), "0.000001"); // adjusted -6: still plain
        assert_eq!(f(false, 1, -7), "1E-7"); // adjusted -7: scientific
        assert_eq!(f(false, 1, 3), "1E+3"); // positive exponent: scientific
        assert_eq!(f(false, 123, 1), "1.23E+3");
        assert_eq!(f(false, 0, -2), "0.00");
        assert_eq!(f(false, 0, 0), "0");
    }

    #[test]
    fn orders_numerically() {
        use std::cmp::Ordering::*;
        let fin = |neg, coeff: u128, exp| Dec::Finite { neg, coeff, exp };
        assert_eq!(cmp(&fin(false, 95, -1), &fin(false, 123, -1)), Less); // 9.5 < 12.3
        assert_eq!(cmp(&fin(false, 15, -1), &fin(false, 150, -2)), Equal); // 1.5 == 1.50
        assert_eq!(cmp(&fin(true, 25, -1), &fin(false, 1, -7)), Less); // -2.5 < 1E-7
        assert_eq!(cmp(&fin(false, 0, -2), &fin(false, 0, 5)), Equal); // zeros equal
        assert_eq!(cmp(&fin(true, 1, 0), &fin(false, 0, 0)), Less); // -1 < 0
        assert_eq!(cmp(&Dec::Infinity { neg: true }, &fin(true, 999, 30)), Less);
        assert_eq!(cmp(&Dec::quiet_nan(), &Dec::Infinity { neg: false }), Greater);
    }

    #[test]
    fn encode_is_the_inverse_of_decode() {
        // the canonical +1 vector round-trips to the same bits
        assert_eq!(encode_dec128(false, 1, 0), 0x22080000000000000000000000000001);
        // encode->decode identity across signs, exponents, and every
        // declet (a 34-digit coefficient exercises all 11 groups + MSD)
        for &(neg, coeff, exp) in &[
            (false, 1u128, 0i32),
            (true, 1, 0),
            (false, 15, -1),
            (false, 1234567890123456789012345678901234, 5),
            (true, 9999999999999999999999999999999999, -6176),
        ] {
            assert_eq!(
                decode_dec128(encode_dec128(neg, coeff, exp)),
                Dec::Finite { neg, coeff, exp }
            );
        }
    }

    #[test]
    fn int_literal_rounds_half_up_to_34_digits() {
        // helper: encode a decimal string, decode, render - the shape isql prints
        let r = |neg, s: &str| to_string(&decode_dec128(dec128_from_int_digits(neg, s.as_bytes())));
        // i128::MAX + 1: first dropped digit 0 -> down (probed)
        assert_eq!(
            r(false, "170141183460469231731687303715884105728"),
            "1.701411834604692317316873037158841E+38"
        );
        // exact-half at the 35th significant digit rounds UP even off an
        // EVEN digit - HALF-UP, not HALF-EVEN (probed)
        assert_eq!(
            r(false, "222222222222222222222222222222222250000"),
            "2.222222222222222222222222222222223E+38"
        );
        // just below half rounds down (rules out round-ceiling)
        assert_eq!(
            r(false, "222222222222222222222222222222222249999"),
            "2.222222222222222222222222222222222E+38"
        );
        // the sign is carried; magnitude still rounds away from zero
        assert_eq!(
            r(true, "222222222222222222222222222222222250000"),
            "-2.222222222222222222222222222222223E+38"
        );
        // all-nines carry: 35 nines -> 34-digit coefficient 10^33, exp +1
        assert_eq!(
            r(false, "99999999999999999999999999999999999999999"),
            "1.000000000000000000000000000000000E+41"
        );
    }

    #[test]
    fn decimal_arithmetic_matches_the_engine() {
        // render helpers over the decoded/computed values
        let d = |neg, coeff, exp| Dec::Finite { neg, coeff, exp };
        let s = |x: &Dec| to_string(x);
        // 1.5 + 1 = 2.5 (cohort: result exp -1)
        assert_eq!(s(&add(&d(false, 15, -1), &d(false, 1, 0))), "2.5");
        // 1.5 * 2 = 3.0 (exp -1, trailing zero kept)
        assert_eq!(s(&mul(&d(false, 15, -1), &d(false, 2, 0))), "3.0");
        // 1.5 + 2.5 = 4.0
        assert_eq!(s(&add(&d(false, 15, -1), &d(false, 25, -1))), "4.0");
        // 1.5 - 2.5 = -1.0
        assert_eq!(s(&sub(&d(false, 15, -1), &d(false, 25, -1))), "-1.0");
        // -1.5
        assert_eq!(s(&negate(&d(false, 15, -1))), "-1.5");
        // opposite-sign add that cancels to zero
        assert_eq!(s(&add(&d(false, 5, 0), &d(true, 5, 0))), "0");
        // the signed zero (measured on 2196): minus flips it, one sign sums
        // to that sign, opposite signs to +0, x / -Inf at the least exponent
        assert_eq!(s(&negate(&d(false, 0, 0))), "-0");
        assert_eq!(s(&add(&d(true, 0, 0), &d(true, 0, -1))), "-0.0");
        assert_eq!(s(&sub(&d(true, 0, 0), &d(false, 0, 0))), "-0");
        assert_eq!(s(&add(&d(true, 0, 0), &d(false, 0, 0))), "0");
        assert_eq!(s(&div(&d(false, 5, 0), &Dec::Infinity { neg: true })), "-0E-6176");
        // HALF-UP at the 34-sig boundary: 34 twos + 0.5 -> ...2223 (probed)
        let twos: u128 = "2222222222222222222222222222222222".parse().unwrap();
        assert_eq!(s(&add(&d(false, twos, 0), &d(false, 5, -1))), "2222222222222222222222222222222223");
        // a 34x34 multiply that overflows any integer, rounded to 34 sig
        let big: u128 = "9999999999999999999999999999999999".parse().unwrap(); // 34 nines
        // 34-nines squared = 10^68 - 2e34 + 1 -> 34 sig ...998 (probed engine)
        assert_eq!(s(&mul(&d(false, big, 0), &d(false, big, 0))), "9.999999999999999999999999999999998E+67");
        // division - the exponent/cohort rules probed against the engine
        assert_eq!(s(&div(&d(false, 1, 0), &d(false, 3, 0))), "0.3333333333333333333333333333333333"); // 34 threes
        assert_eq!(s(&div(&d(false, 6, 0), &d(false, 2, 0))), "3");
        assert_eq!(s(&div(&d(false, 1, 0), &d(false, 2, 0))), "0.5");
        assert_eq!(s(&div(&d(false, 10, 0), &d(false, 4, 0))), "2.5");
        assert_eq!(s(&div(&d(false, 15, -1), &d(false, 4, 0))), "0.375"); // 1.5 / 4
        assert_eq!(s(&div(&d(false, 120, -1), &d(false, 3, 0))), "4.0"); // 12.0 / 3, cohort kept
        assert_eq!(s(&div(&d(false, 10, -1), &d(false, 4, 0))), "0.25"); // 1.0 / 4
        assert_eq!(s(&div(&d(false, 2, 0), &d(false, 3, 0))), "0.6666666666666666666666666666666667");
        assert_eq!(s(&div(&d(false, 5, 0), &d(false, 1000, 0))), "0.005");
        assert_eq!(s(&div(&d(true, 6, 0), &d(false, 2, 0))), "-3"); // sign
        // Infinity arithmetic
        assert!(matches!(add(&Dec::Infinity { neg: false }, &d(false, 1, 0)), Dec::Infinity { neg: false }));
        assert!(matches!(add(&Dec::Infinity { neg: false }, &Dec::Infinity { neg: true }), Dec::Nan { .. }));
        assert!(matches!(mul(&Dec::Infinity { neg: false }, &d(false, 0, 0)), Dec::Nan { .. }));
    }

    #[test]
    fn dec_to_dec64_bits_rounds_and_encodes() {
        let d = |neg, coeff, exp| Dec::Finite { neg, coeff, exp };
        let r = |x: &Dec| to_string(&decode_dec64(dec_to_dec64_bits(x)));
        assert_eq!(r(&d(false, 15, -1)), "1.5"); // 1.5 exact
        assert_eq!(r(&d(false, 100, 0)), "100");
        // a value past 16 sig digits rounds to 16 (HALF-UP)
        let wide: u128 = "12345678901234567".parse().unwrap(); // 17 digits
        assert_eq!(r(&d(false, wide, 0)), "1.234567890123457E+16");
        // specials carry through
        assert!(matches!(decode_dec64(dec_to_dec64_bits(&Dec::Infinity { neg: true })), Dec::Infinity { neg: true }));
        assert!(matches!(decode_dec64(dec_to_dec64_bits(&Dec::quiet_nan())), Dec::Nan { .. }));
    }

    #[test]
    fn encode_dec128_special_decodes_back() {
        assert!(matches!(
            decode_dec128(encode_dec128_special(false, false)),
            Dec::Infinity { neg: false }
        ));
        assert!(matches!(
            decode_dec128(encode_dec128_special(true, false)),
            Dec::Infinity { neg: true }
        ));
        assert!(matches!(decode_dec128(encode_dec128_special(false, true)), Dec::Nan { .. }));
        assert!(matches!(decode_dec128(encode_dec128_special(true, true)), Dec::Nan { .. }));
    }

    #[test]
    fn encode_dec64_is_the_inverse_of_decode() {
        // the canonical +1 decimal64 vector round-trips to the same bits
        assert_eq!(encode_dec64(false, 1, 0), 0x2238000000000001);
        assert_eq!(encode_dec64(true, 1, 0), 0xA238000000000001);
        // encode->decode identity across signs, exponents and every declet
        for &(neg, coeff, exp) in &[
            (false, 1u64, 0i32),
            (false, 15, -1),
            (false, 1234567890123456, 5), // 16 digits, all 5 declets + MSD
            (true, 9999999999999999, -398),
        ] {
            assert_eq!(
                decode_dec64(encode_dec64(neg, coeff, exp)),
                Dec::Finite { neg, coeff: coeff as u128, exp }
            );
        }
    }

    #[test]
    fn dec64_int_literal_rounds_half_up_to_16_digits() {
        let r = |neg, s: &str| to_string(&decode_dec64(dec64_from_int_digits(neg, s.as_bytes())));
        // u128::MAX rounds to 16 sig - the engine's DECFLOAT(16) form (probed)
        assert_eq!(r(false, "340282366920938463463374607431768211455"), "3.402823669209385E+38");
        // 16 digits exactly: no rounding
        assert_eq!(r(false, "1234567890123456"), "1234567890123456");
        // 17th digit >= 5 rounds up; all-nines carry to 10^15
        assert_eq!(r(false, "99999999999999999"), "1.000000000000000E+17");
    }

    #[test]
    fn round_to_dec34_promotes_an_exact_value() {
        use std::cmp::Ordering::*;
        // <= 34 digits is exact (no rounding), any exponent kept
        assert_eq!(round_to_dec34(false, 12345, -2), Dec::Finite { neg: false, coeff: 12345, exp: -2 });
        // i128::MAX (39 digits) rounds to 34 sig, first dropped 0 -> down
        let imax = 170141183460469231731687303715884105727u128;
        assert_eq!(
            round_to_dec34(false, imax, 0),
            Dec::Finite { neg: false, coeff: 1701411834604692317316873037158841, exp: 5 }
        );
        // two INT128 magnitudes differing only past the 34th digit round
        // EQUAL - the promotion that makes both match one DECFLOAT literal
        let a = round_to_dec34(false, 170141183460469231731687303715884100000, 0);
        let b = round_to_dec34(false, 170141183460469231731687303715884105727, 0);
        assert_eq!(cmp(&a, &b), Equal);
        // all-nines carry to 10^33 with exp bumped
        assert_eq!(
            round_to_dec34(false, 99999999999999999999999999999999999u128, 0), // 35 nines
            Dec::Finite { neg: false, coeff: 1000000000000000000000000000000000, exp: 2 }
        );
    }

    #[test]
    fn nan_keeps_signaling_and_payload() {
        let n = |neg, signaling, payload| Dec::Nan { neg, signaling, payload };
        // decode bit 121/57 + the payload declets (vectors from the C probe)
        assert_eq!(
            decode_dec128(0x7c0000000000000000000000000000a3),
            n(false, false, 123)
        );
        assert_eq!(
            decode_dec128(0x7e0000000000000000000000000003cf),
            n(false, true, 789)
        );
        assert_eq!(
            decode_dec128(0xfc000000000000000000000000000000),
            n(true, false, 0)
        );
        assert_eq!(decode_dec64(0x7e00000000000000), n(false, true, 0));
        // encode is the inverse, canonical declets
        for d in [
            n(false, false, 0),
            n(false, false, 123456),
            n(false, true, 789),
            n(true, false, 0),
            n(true, true, 7),
        ] {
            assert_eq!(decode_dec128(dec_to_bits(&d)), d);
        }
        assert_eq!(decode_dec64(dec_to_dec64_bits(&n(false, true, 42))), n(false, true, 42));
        // renders like decToString
        assert_eq!(to_string(&n(false, false, 0)), "NaN");
        assert_eq!(to_string(&n(false, false, 123)), "NaN123");
        assert_eq!(to_string(&n(false, true, 0)), "sNaN");
        assert_eq!(to_string(&n(false, true, 789)), "sNaN789");
        assert_eq!(to_string(&n(true, false, 0)), "-NaN");
        assert_eq!(to_string(&negate(&n(false, false, 123))), "-NaN123");
    }

    #[test]
    fn nan_arithmetic_priority_and_traps() {
        let n = |neg, signaling, payload| Dec::Nan { neg, signaling, payload };
        let one = Dec::Finite { neg: false, coeff: 1, exp: 0 };
        let s = |x: &Dec| to_string(x);
        // add/mul: the RIGHT NaN wins; sub/div: the LEFT (probed)
        assert_eq!(s(&add(&n(false, false, 123), &n(false, false, 456))), "NaN456");
        assert_eq!(s(&mul(&n(false, false, 123), &n(false, false, 456))), "NaN456");
        assert_eq!(s(&sub(&n(false, false, 123), &n(false, false, 456))), "NaN123");
        assert_eq!(s(&div(&n(false, false, 123), &n(false, false, 456))), "NaN123");
        // a lone NaN propagates whole and unnegated
        assert_eq!(s(&sub(&one, &n(false, false, 456))), "NaN456");
        assert_eq!(s(&mul(&one, &n(false, false, 456))), "NaN456");
        assert_eq!(s(&div(&n(false, false, 123), &one)), "NaN123");
        // a signaling operand survives for the caller to trap
        assert!(add(&n(false, true, 0), &one).is_signaling_nan());
        assert!(mul(&one, &n(false, true, 9)).is_signaling_nan());
        // invalid operations answer the bare quiet NaN
        assert_eq!(div(&one, &Dec::Finite { neg: false, coeff: 0, exp: 0 }), Dec::Infinity { neg: false });
        assert_eq!(div(&Dec::Finite { neg: false, coeff: 0, exp: 0 }, &Dec::Finite { neg: false, coeff: 0, exp: 0 }), Dec::quiet_nan());
        assert!(cmp_value(&n(false, false, 0), &one).is_err());
        assert!(cmp_value(&one, &n(false, true, 0)).is_err());
    }

    #[test]
    fn total_order_and_dedup_follow_the_engine() {
        use std::cmp::Ordering::*;
        let fin = |neg, coeff: u128, exp| Dec::Finite { neg, coeff, exp };
        let n = |neg, signaling, payload| Dec::Nan { neg, signaling, payload };
        let t = |a: &Dec, b: &Dec| cmp_total(a, b, false);
        // class ranks ascending
        let chain = [
            n(true, false, 0),
            n(true, true, 0),
            Dec::Infinity { neg: true },
            fin(true, 35, -1),
            fin(false, 0, 0),
            fin(false, 15, -1),
            Dec::Infinity { neg: false },
            n(false, true, 0),
            n(false, false, 0),
        ];
        for w in chain.windows(2) {
            assert_eq!(t(&w[0], &w[1]), Less, "{:?} vs {:?}", w[0], w[1]);
        }
        // value ties: the record past the keys (ULONGs ascending)
        assert_eq!(t(&fin(false, 0, 0), &fin(true, 0, 0)), Less); // +0 < -0
        assert_eq!(t(&fin(false, 15, -1), &fin(false, 150, -2)), Less); // 1.5 < 1.50
        assert_eq!(t(&fin(false, 150, -2), &fin(false, 1500, -3)), Less);
        assert_eq!(t(&fin(false, 0, -100), &fin(false, 0, 5)), Less); // 0E-100 < 0E+5
        // payloads by the record bytes (ULONG[0] 255 < 1024 here)
        assert_eq!(t(&n(false, false, 999), &n(false, false, 1000)), Less);
        assert_eq!(t(&n(false, true, 0), &n(false, true, 789)), Less);
        // descending reverses ranks and values, never the tiebreaks
        let td = |a: &Dec, b: &Dec| cmp_total(a, b, true);
        assert_eq!(td(&n(false, false, 0), &Dec::Infinity { neg: false }), Less);
        assert_eq!(td(&fin(false, 15, -1), &fin(false, 150, -2)), Less); // 1.5 still first
        assert_eq!(td(&fin(false, 0, 0), &fin(true, 0, 0)), Less); // +0 still first
        assert_eq!(td(&n(false, false, 0), &n(false, false, 456)), Less);
        assert_eq!(td(&fin(false, 2, 0), &fin(false, 1, 0)), Less); // values reverse
        // dedup groups
        assert!(dedup_eq(&fin(false, 15, -1), &fin(false, 1500, -3))); // cohorts merge
        assert!(dedup_eq(&fin(false, 0, 0), &fin(true, 0, -3))); // zeros merge
        assert!(!dedup_eq(&fin(false, 15, -1), &fin(true, 15, -1))); // signs apart
        assert!(dedup_eq(&n(false, false, 123), &n(false, false, 456))); // payloads merge
        assert!(!dedup_eq(&n(false, false, 0), &n(true, false, 0))); // signed apart
        assert!(dedup_eq(&n(false, true, 0), &n(false, true, 0))); // identical twins merge
        assert!(!dedup_eq(&n(false, true, 0), &n(false, true, 789))); // payloads apart
        assert!(!dedup_eq(&n(false, false, 0), &n(false, true, 0))); // classes apart
        // the representative is the ascending-greatest
        assert_eq!(t(&fin(false, 15, -1), &fin(false, 1500, -3)), Less); // 1.500 wins
        assert_eq!(t(&fin(false, 0, 0), &fin(true, 0, 0)), Less); // -0 wins
        assert_eq!(t(&n(false, false, 123), &n(false, false, 456)), Less); // NaN456 wins
    }

    #[test]
    fn parse_reads_the_decnumber_grammar() {
        // cohorts kept, specials with form, blanks rejected
        assert_eq!(parse("1.50"), Some(Dec::Finite { neg: false, coeff: 150, exp: -2 }));
        assert_eq!(parse("-0"), Some(Dec::Finite { neg: true, coeff: 0, exp: 0 }));
        assert_eq!(parse("1E30"), Some(Dec::Finite { neg: false, coeff: 1, exp: 30 }));
        assert_eq!(parse("0E5"), Some(Dec::Finite { neg: false, coeff: 0, exp: 5 }));
        assert_eq!(parse("inf"), Some(Dec::Infinity { neg: false }));
        assert_eq!(parse("-Infinity"), Some(Dec::Infinity { neg: true }));
        assert_eq!(parse("sNaN789"), Some(Dec::Nan { neg: false, signaling: true, payload: 789 }));
        assert_eq!(parse("-nan123"), Some(Dec::Nan { neg: true, signaling: false, payload: 123 }));
        assert_eq!(parse(" 1.50 "), None);
        assert_eq!(parse("zzz"), None);
        assert_eq!(parse("Infinityx"), None);
        assert_eq!(parse("nan12345678901234567890123456789012345"), None); // 35 payload digits
        assert_eq!(parse("nan1234567890123456789012345678901234"), None); // 34: 22018
        assert_eq!(
            parse("nan123456789012345678901234567890123"),
            Some(Dec::Nan { neg: false, signaling: false, payload: 123456789012345678901234567890123 })
        ); // 33: the declets hold it
        assert_eq!(parse("1E99999"), None); // exponent past decimal128
        // 35 significant digits round HALF-UP to 34
        assert_eq!(
            parse("9.9999999999999999999999999999999999"),
            Some(Dec::Finite { neg: false, coeff: 1000000000000000000000000000000000, exp: -32 })
        );
    }

    #[test]
    fn record_tiebreak_orders_cohorts_zeros_and_payloads() {
        use std::cmp::Ordering::*;
        let fin = |neg, coeff: u128, exp| Dec::Finite { neg, coeff, exp };
        let n = |neg, signaling, payload| Dec::Nan { neg, signaling, payload };
        let t = |a: &Dec, b: &Dec| cmp_total(a, b, false);
        let td = |a: &Dec, b: &Dec| cmp_total(a, b, true);
        let chain = |cs: &[Dec]| {
            for w in cs.windows(2) {
                assert_eq!(t(&w[0], &w[1]), Less, "{:?} vs {:?}", w[0], w[1]);
                assert_eq!(td(&w[0], &w[1]), Less, "DESC keeps {:?}", w[0]);
            }
        };
        // the mechanism, pinned: ULONG[0] of the canonical record
        let u0 = |d: &Dec| u32::from_le_bytes(dec_to_bits(d).to_le_bytes()[0..4].try_into().unwrap());
        assert_eq!(u0(&fin(false, 880, -1)), 14); // DPD(880)
        assert_eq!(u0(&fin(false, 88, 0)), 78); // DPD(088)
        assert_eq!(u0(&fin(false, 8800, -2)), 8204); // DPD(800) | DPD(008) << 10
        assert_eq!(u0(&n(false, false, 0)), 0);
        assert_eq!(u0(&n(false, false, 123)), 163);
        assert_eq!(u0(&n(false, false, 999)), 255);
        assert_eq!(u0(&n(false, false, 456)), 598);
        assert_eq!(u0(&n(false, false, 1000)), 1024);
        // T5/T8/T9: the 88-cohort is NOT coefficient order, either sign
        chain(&[fin(false, 880, -1), fin(false, 88, 0), fin(false, 8800, -2)]);
        chain(&[fin(true, 880, -1), fin(true, 88, 0)]);
        // T3/T4: payloads by the record bytes (999's DPD(999) = 255
        // sits between 123 and 456; 1000's second declet puts it last)
        chain(&[
            n(false, false, 0),
            n(false, false, 123),
            n(false, false, 999),
            n(false, false, 456),
            n(false, false, 1000),
        ]);
        // T1/T2: the DFC zeros (+0s by biased exponent, then -0s)
        chain(&[
            fin(false, 0, -2),
            fin(false, 0, 0),
            fin(false, 0, 5),
            fin(true, 0, -3),
            fin(true, 0, 0),
        ]);
        // C3: the full-width (MSD 9) cohort member sorts first - its
        // low declets are all zero
        let wide: u128 = 999_000_000_000_000_000_000_000_000_000_000_0;
        chain(&[fin(false, wide, 0), fin(false, 999, 31), fin(false, 9990, 30)]);
        // G1/G2: the combination field never decides (880-form first
        // across the E13E12 straddle, both directions)
        chain(&[fin(false, 880, -2081), fin(false, 88, -2080)]);
        // sNaN payloads ride the same record law (make() drops the
        // payload for OFF_snan too)
        assert_eq!(t(&n(false, true, 123), &n(false, true, 456)), Less);
        // mixed widths meet at dec128 (the union's widening)
        assert_eq!(t(&fin(false, 88, 0), &fin(false, 880, -1)), Greater);
        // the native 64-bit entries agree on a dec16 88-cohort
        let e64 = |c: u64, e: i32| encode_dec64(false, c, e);
        let d64 = |c: u64, e: i32| decode_dec64(e64(c, e));
        let t64 = |a: u64, b: u64| cmp_total_64(&d64(a, 0), e64(a, 0), &d64(b, -1), e64(b, -1), false);
        assert_eq!(t64(88, 880), Greater); // 88.0 first
        assert_eq!(rec_cmp_64(e64(88, 0), e64(880, -1)), Greater);
        // ...and the native 128-bit entries read the caller's bytes
        let e128 = |c: u128, e: i32| encode_dec128(false, c, e);
        let d128 = |c: u128, e: i32| decode_dec128(e128(c, e));
        assert_eq!(
            cmp_total_128(&d128(88, 0), e128(88, 0), &d128(880, -1), e128(880, -1), false),
            Greater
        );
    }

    #[test]
    fn sort_key_order_ties_cohorts_zeros_and_payloads() {
        use std::cmp::Ordering::*;
        let fin = |neg, coeff: u128, exp| Dec::Finite { neg, coeff, exp };
        let n = |neg, signaling, payload| Dec::Nan { neg, signaling, payload };
        let k = |a: &Dec, b: &Dec| cmp_key(a, b, false);
        let kd = |a: &Dec, b: &Dec| cmp_key(a, b, true);
        // make() normalizes every cohort, zero and payload group
        assert_eq!(k(&fin(false, 88, 0), &fin(false, 880, -1)), Equal);
        assert_eq!(k(&fin(false, 0, 5), &fin(true, 0, -3)), Equal);
        assert_eq!(k(&n(false, false, 123), &n(false, false, 456)), Equal);
        assert_eq!(kd(&fin(false, 88, 0), &fin(false, 880, -1)), Equal);
        // ...while ranks and values order, reversed when descending
        assert_eq!(k(&fin(false, 2, 0), &fin(false, 1, 0)), Greater);
        assert_eq!(kd(&fin(false, 2, 0), &fin(false, 1, 0)), Less);
        assert_eq!(k(&n(false, false, 0), &Dec::Infinity { neg: false }), Greater);
        assert_eq!(kd(&n(false, false, 0), &Dec::Infinity { neg: false }), Less);
        assert_eq!(k(&fin(true, 35, -1), &fin(false, 0, 0)), Less);
    }

    #[test]
    fn integral_rounding_matches_decquad() {
        let fin = |neg, coeff: u128, exp| Dec::Finite { neg, coeff, exp };
        let f = |c: u128, e: i32| fin(false, c, e);
        assert_eq!(to_integral(&f(25, -1), IntegralMode::Ceil), fin(false, 3, 0));
        assert_eq!(to_integral(&f(25, -1), IntegralMode::Floor), fin(false, 2, 0));
        assert_eq!(to_integral(&f(25, -1), IntegralMode::Trunc), fin(false, 2, 0));
        assert_eq!(to_integral(&f(25, -1), IntegralMode::Round), fin(false, 3, 0));
        assert_eq!(
            to_integral(&fin(true, 25, -1), IntegralMode::Ceil),
            fin(true, 2, 0)
        );
        assert_eq!(
            to_integral(&fin(true, 25, -1), IntegralMode::Floor),
            fin(true, 3, 0)
        );
        assert_eq!(to_integral(&f(20, -1), IntegralMode::Ceil), fin(false, 2, 0));
        assert_eq!(to_integral(&f(7, 0), IntegralMode::Floor), f(7, 0));
        assert_eq!(
            to_integral(&Dec::Infinity { neg: true }, IntegralMode::Ceil),
            Dec::Infinity { neg: true }
        );
        assert_eq!(
            to_integral(
                &Dec::Nan { neg: false, signaling: false, payload: 456 },
                IntegralMode::Floor
            ),
            Dec::Nan { neg: false, signaling: false, payload: 456 }
        );
    }

    #[test]
    fn double_scale_range_matches_cvt() {
        // the measured vectors the predicate moved with (builtins 14)
        assert!(!cvt_double_scale_out_of_range("1e-307"));
        assert!(!cvt_double_scale_out_of_range("1e308"));
        assert!(!cvt_double_scale_out_of_range("-2.5e-300"));
        assert!(!cvt_double_scale_out_of_range("4e-306"));
        assert!(!cvt_double_scale_out_of_range("0e308"));
        assert!(cvt_double_scale_out_of_range("2.3e-308"));
        assert!(cvt_double_scale_out_of_range("0e-400"));
        assert!(cvt_double_scale_out_of_range("0.00001e-305"));
        assert!(cvt_double_scale_out_of_range("1e-400"));
        assert!(cvt_double_scale_out_of_range("1e400"));
        assert!(cvt_double_scale_out_of_range("-1.5e-400"));
        assert!(cvt_double_scale_out_of_range("1e3276"));
        assert!(!cvt_double_scale_out_of_range("1.5"));
    }
}
