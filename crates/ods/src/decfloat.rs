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
/// digit - the cohort as stored), infinity, or NaN.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Dec {
    Finite { neg: bool, coeff: u128, exp: i32 },
    Infinity { neg: bool },
    Nan,
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

/// Decode a decimal64 from its little-endian-loaded 64 bits
/// (decimal64.c decimal64ToNumber).
pub fn decode_dec64(v: u64) -> Dec {
    let neg = v >> 63 != 0;
    match combination((v >> 58) as u32 & 0x1F) {
        Err(true) => Dec::Infinity { neg },
        Err(false) => Dec::Nan,
        Ok((exp_top, msd)) => {
            let exp = ((exp_top << 8) | ((v >> 50) as u32 & 0xFF)) as i32 - 398;
            Dec::Finite { neg, coeff: declets(msd, v as u128, 5), exp }
        }
    }
}

/// Decode a decimal128 from its little-endian-loaded 128 bits
/// (decimal128.c decimal128ToNumber).
pub fn decode_dec128(v: u128) -> Dec {
    let neg = v >> 127 != 0;
    match combination((v >> 122) as u32 & 0x1F) {
        Err(true) => Dec::Infinity { neg },
        Err(false) => Dec::Nan,
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
        Dec::Nan => "NaN".into(),
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

/// Order two decoded values the way the engine sorts DECFLOAT: sign
/// first, then magnitude by adjusted exponent and digit comparison;
/// every zero cohort is equal; infinities beyond all finites, NaN
/// beyond everything (the engine's NaN-last total order).
pub fn cmp(a: &Dec, b: &Dec) -> std::cmp::Ordering {
    use std::cmp::Ordering::*;
    let rank = |d: &Dec| match d {
        Dec::Nan => 2,
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
        assert!(matches!(decode_dec64(0x7C00000000000000), Dec::Nan));
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
        assert_eq!(cmp(&Dec::Nan, &Dec::Infinity { neg: false }), Greater);
    }
}
