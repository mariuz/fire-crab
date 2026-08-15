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
pub fn encode_dec64(neg: bool, coeff: u64, exp: i32) -> u64 {
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
    if rest[0] >= b'5' {
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
    if digits.as_bytes()[16] >= b'5' {
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

fn strip0(mut d: Vec<u8>) -> Vec<u8> {
    let nz = d.iter().position(|&c| c != b'0').unwrap_or(d.len() - 1);
    d.drain(..nz);
    d
}
fn ucmp(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}
fn uadd(a: &[u8], b: &[u8]) -> Vec<u8> {
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
fn usub(a: &[u8], b: &[u8]) -> Vec<u8> {
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
fn umul(a: &[u8], b: &[u8]) -> Vec<u8> {
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
fn round34(d: &[u8]) -> (Vec<u8>, i64) {
    if d.len() <= 34 {
        return (d.to_vec(), 0);
    }
    let mut drop = (d.len() - 34) as i64;
    let mut kept = d[..34].to_vec();
    if d[34] >= b'5' {
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
fn parts(d: &Dec) -> (bool, Vec<u8>, i64) {
    if let Dec::Finite { neg, coeff, exp } = d {
        (*neg, coeff.to_string().into_bytes(), *exp as i64)
    } else {
        unreachable!("parts on a non-finite Dec")
    }
}
fn finite(neg: bool, digits: Vec<u8>, exp: i64) -> Dec {
    let d = strip0(digits);
    let coeff = digits_u128(&d);
    // a zero result normalises to +0 at the working exponent
    let neg = if coeff == 0 { false } else { neg };
    Dec::Finite { neg, coeff, exp: exp.clamp(i32::MIN as i64, i32::MAX as i64) as i32 }
}

fn sig_len(d: &[u8]) -> usize {
    let s = strip0(d.to_vec());
    if s == b"0" { 0 } else { s.len() }
}
/// (quotient, remainder) of `a / b` as digit strings, schoolbook long
/// division. `b` must be non-zero.
fn udivmod(a: &[u8], b: &[u8]) -> (Vec<u8>, Vec<u8>) {
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
        (Dec::Nan, _) | (_, Dec::Nan) => return Dec::Nan,
        (Dec::Infinity { .. }, Dec::Infinity { .. }) => return Dec::Nan,
        (Dec::Infinity { neg: x }, Dec::Finite { neg: f, .. }) => {
            return Dec::Infinity { neg: x != f };
        }
        (Dec::Finite { .. }, Dec::Infinity { .. }) => {
            return Dec::Finite { neg: false, coeff: 0, exp: 0 };
        }
        _ => {}
    }
    let (na, ca, ea) = parts(a);
    let (nb, cb, eb) = parts(b);
    if cb == b"0" {
        return if ca == b"0" { Dec::Nan } else { Dec::Infinity { neg: na != nb } };
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
    let (kept, drop) = round34(&strip0(q));
    finite(na != nb, kept, exp + drop)
}

/// Encode a computed [Dec] back to its decimal128 bits.
pub fn dec_to_bits(d: &Dec) -> u128 {
    match d {
        Dec::Finite { neg, coeff, exp } => encode_dec128(*neg, *coeff, *exp),
        Dec::Infinity { neg } => encode_dec128_special(*neg, false),
        Dec::Nan => encode_dec128_special(false, true),
    }
}

/// Negate: flips the sign of a finite value or an Infinity (NaN stays NaN).
pub fn negate(d: &Dec) -> Dec {
    match d {
        Dec::Finite { neg, coeff, exp } => Dec::Finite { neg: *coeff != 0 && !*neg, coeff: *coeff, exp: *exp },
        Dec::Infinity { neg } => Dec::Infinity { neg: !*neg },
        Dec::Nan => Dec::Nan,
    }
}

/// `a + b`, to 34 significant digits HALF-UP. `Infinity + -Infinity` is NaN
/// (an invalid operation, which the caller traps); every other special
/// propagates as decNumber does.
pub fn add(a: &Dec, b: &Dec) -> Dec {
    match (a, b) {
        (Dec::Nan, _) | (_, Dec::Nan) => return Dec::Nan,
        (Dec::Infinity { neg: x }, Dec::Infinity { neg: y }) => {
            return if x == y { Dec::Infinity { neg: *x } } else { Dec::Nan };
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
    let (sign, mag) = if na == nb {
        (na, uadd(&da, &db))
    } else {
        match ucmp(&da, &db) {
            std::cmp::Ordering::Greater => (na, usub(&da, &db)),
            std::cmp::Ordering::Less => (nb, usub(&db, &da)),
            std::cmp::Ordering::Equal => (false, vec![b'0']),
        }
    };
    let (kept, drop) = round34(&mag);
    finite(sign, kept, e + drop)
}

/// `a - b`.
pub fn sub(a: &Dec, b: &Dec) -> Dec {
    add(a, &negate(b))
}

/// `a * b`, to 34 significant digits HALF-UP.
pub fn mul(a: &Dec, b: &Dec) -> Dec {
    let zero = |d: &Dec| matches!(d, Dec::Finite { coeff: 0, .. });
    match (a, b) {
        (Dec::Nan, _) | (_, Dec::Nan) => return Dec::Nan,
        // Infinity * 0 is an invalid operation (NaN)
        (Dec::Infinity { .. }, x) | (x, Dec::Infinity { .. }) if zero(x) => return Dec::Nan,
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
    let (kept, drop) = round34(&umul(&ca, &cb));
    finite(na != nb, kept, ea + eb + drop)
}

/// The decimal128 bits of a SPECIAL value: `±Infinity` or `NaN`, the
/// forms decNumber's string grammar accepts as `inf`/`infinity`/`nan`/
/// `snan`. The combination field alone carries them - `11110` is infinity,
/// `11111` NaN ([combination]/[decode_dec128]); the coefficient and
/// exponent are unread. (sNaN vs NaN is not distinguished: [decode_dec128]
/// collapses both to [Dec::Nan], and either traps a comparison the same.)
pub fn encode_dec128_special(neg: bool, nan: bool) -> u128 {
    let comb: u128 = if nan { 0b11111 } else { 0b11110 };
    ((neg as u128) << 127) | (comb << 122)
}

/// The decimal64 bits of a SPECIAL value (`±Infinity` / `NaN`), the dec64
/// analog of [encode_dec128_special] (combination field at bits 58..63).
pub fn encode_dec64_special(neg: bool, nan: bool) -> u64 {
    let comb: u64 = if nan { 0b11111 } else { 0b11110 };
    ((neg as u64) << 63) | (comb << 58)
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
        Dec::Nan => encode_dec64_special(false, true),
    }
}

/// Re-express a DECFLOAT(34) value (its decimal128 bits) as a DECFLOAT(16)
/// (decimal64 bits), rounding to 16 significant digits HALF-UP. `None` for
/// a non-finite value (Infinity/NaN) - a literal is never one, so this only
/// declines the shapes an INSERT of a plain literal cannot reach.
pub fn round_to_dec16_of(bits128: u128) -> Option<u64> {
    match decode_dec128(bits128) {
        Dec::Finite { neg, coeff, exp } => match round_to_dec16(neg, coeff, exp) {
            Dec::Finite { neg, coeff, exp } => Some(encode_dec64(neg, coeff as u64, exp)),
            _ => None,
        },
        _ => None,
    }
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
    // HALF-UP: the first dropped digit alone decides (>= 5 rounds up),
    // because 5000.. and 5001.. both round away from zero
    if rest[0] >= b'5' {
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
pub fn round_to_dec34(neg: bool, coeff: u128, exp: i32) -> Dec {
    let digits = coeff.to_string();
    if digits.len() <= 34 {
        return Dec::Finite { neg, coeff, exp };
    }
    let drop = digits.len() - 34;
    let mut c: u128 = digits[..34].parse().unwrap();
    let mut e = exp + drop as i32;
    if digits.as_bytes()[34] >= b'5' {
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
        assert!(matches!(add(&Dec::Infinity { neg: false }, &Dec::Infinity { neg: true }), Dec::Nan));
        assert!(matches!(mul(&Dec::Infinity { neg: false }, &d(false, 0, 0)), Dec::Nan));
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
        assert!(matches!(decode_dec64(dec_to_dec64_bits(&Dec::Nan)), Dec::Nan));
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
        assert!(matches!(decode_dec128(encode_dec128_special(false, true)), Dec::Nan));
        assert!(matches!(decode_dec128(encode_dec128_special(true, true)), Dec::Nan));
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
}
