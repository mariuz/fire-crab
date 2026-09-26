//! The decNumber transcendentals the engine's DECFLOAT math runs on:
//! `decExpOp`, `decLnOp`, `decNumberPower` and `decNumberLog10`
//! (extern/decNumber/decNumber.c), ported step for step - the working
//! precisions, the HALF-EVEN working contexts, the Newton loop's
//! termination test, the sticky final rounding - so a DECFLOAT(34) result
//! carries the engine's LAST DIGIT, not merely a correctly rounded one
//! (decNumber's own comment: "almost always correctly rounded, but may be
//! up to 1 ulp in error in rare cases"; the engine's EXP is `e ** x` over
//! a 34-digit e, which is NOT exp(x) - `EXP(100)` is
//! 2.688117141816135448412625551579964E+43 where the true value ends
//! ...580014, measured on 2182).
//!
//! The engine calls these through `Decimal128::pow / ln / log10`
//! (common/DecFloat.cpp) under its DecimalContext: 34 digits, the session
//! rounding HALF-UP, and the traps `Division_by_zero`,
//! `Invalid_operation` and `Overflow` (FB_DEC_Errors). Everything here is
//! digit-string arithmetic (a working precision reaches 88 digits in the
//! exp accumulator) over [crate::decfloat]'s helpers.

use crate::decfloat::{self as dfl, finite, parts, strip0, uadd, ucmp, udivmod, umul, usub, Dec};

/// The three decNumber statuses the engine traps (FB_DEC_Errors); every
/// other flag (Inexact, Rounded, Underflow, Subnormal) is ignored.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MathErr {
    /// DEC_Invalid_operation - `0 ** 0`, a negative base to a fractional
    /// power, `0 / 0`, ln of a negative: 22000
    Invalid,
    /// DEC_Division_by_zero - `LOG(1, x)` divides by ln(1) = 0: 22012
    DivByZero,
    /// DEC_Overflow - the adjusted exponent past 6144: 22003
    Overflow,
}

#[derive(Clone, Copy, PartialEq)]
enum Round {
    HalfEven,
    HalfUp,
    Down,
}

/// A decNumber context: the digits, the rounding and the exponent bounds
/// (DEC_MAX_MATH = 999999 for the internal contexts, 6144/-6143 for the
/// decimal128 one the caller supplies).
#[derive(Clone, Copy)]
struct Ctx {
    digits: i64,
    round: Round,
    emax: i64,
    emin: i64,
}

const DEC_MAX_MATH: i64 = 999_999;
const D128_EMAX: i64 = 6144;
const D128_EMIN: i64 = -6143;

/// A finite working decNumber: the sign, the coefficient as MSD-first
/// ASCII digits with no leading zeros (`b"0"` is zero, one digit, as
/// decNumber counts it), and the exponent of the last digit. Trailing
/// zeros are KEPT - `digits` (the coefficient's length) steers the
/// algorithms' termination tests exactly as decNumber's `dn->digits`.
#[derive(Clone, Debug, PartialEq)]
struct Num {
    neg: bool,
    mag: Vec<u8>,
    exp: i64,
}

impl Num {
    fn int(v: i64) -> Num {
        Num { neg: v < 0, mag: v.unsigned_abs().to_string().into_bytes(), exp: 0 }
    }
    fn digits(&self) -> i64 {
        self.mag.len() as i64
    }
    fn is_zero(&self) -> bool {
        self.mag == b"0"
    }
    fn adjusted(&self) -> i64 {
        self.exp + self.digits() - 1
    }
    fn from_dec(d: &Dec) -> Option<Num> {
        match d {
            Dec::Finite { .. } => {
                let (neg, mag, exp) = parts(d);
                Some(Num { neg: neg && mag != b"0", mag, exp })
            }
            _ => None,
        }
    }
}

/// Round `mag` (MSD-first digits) to at most `p` digits: the kept digits
/// and the number of places dropped (added to the exponent). `sticky`
/// is decNumber's incoming residue - "there are non-zero digits further
/// right", which turns an exact-half discard into more-than-half.
fn round_mag(mag: &[u8], p: i64, round: Round, sticky: bool) -> (Vec<u8>, i64, bool) {
    let p = p.max(1) as usize;
    if mag.len() <= p {
        return (mag.to_vec(), 0, false);
    }
    let mut drop = (mag.len() - p) as i64;
    let mut kept = mag[..p].to_vec();
    let discarded = &mag[p..];
    let first = discarded[0];
    let rest_nonzero = discarded[1..].iter().any(|&d| d != b'0') || sticky;
    let up = match round {
        Round::Down => false,
        Round::HalfUp => first >= b'5',
        Round::HalfEven => {
            first > b'5' || (first == b'5' && (rest_nonzero || (kept[p - 1] - b'0') % 2 == 1))
        }
    };
    if up {
        kept = uadd(&kept, b"1");
        if kept.len() > p {
            kept.truncate(p);
            drop += 1;
        }
    }
    (kept, drop, true)
}

/// decSetCoeff + decApplyRound over a working number: round to
/// `ctx.digits`, keeping the cohort otherwise. Returns (rounded, inexact).
fn fit(n: &Num, ctx: &Ctx, sticky: bool) -> (Num, bool) {
    let (mag, drop, inexact) = round_mag(&n.mag, ctx.digits, ctx.round, sticky);
    let mag = strip0(mag);
    (Num { neg: n.neg && mag != b"0", mag, exp: n.exp + drop }, inexact || (sticky && n.mag.len() as i64 <= ctx.digits))
}

/// decAddOp: the exact sum (`negate` flips the right operand), rounded to
/// the context. A zero result takes the smaller exponent and a positive
/// sign, as decNumber's does.
fn add(a: &Num, b: &Num, negate: bool, ctx: &Ctx) -> Num {
    let bneg = b.neg != negate;
    let e = a.exp.min(b.exp);
    let mut da = a.mag.clone();
    da.extend(std::iter::repeat(b'0').take((a.exp - e) as usize));
    let mut db = b.mag.clone();
    db.extend(std::iter::repeat(b'0').take((b.exp - e) as usize));
    let (da, db) = (strip0(da), strip0(db));
    let (sign, mag) = if a.neg == bneg {
        (a.neg, uadd(&da, &db))
    } else {
        match ucmp(&da, &db) {
            std::cmp::Ordering::Greater => (a.neg, usub(&da, &db)),
            std::cmp::Ordering::Less => (bneg, usub(&db, &da)),
            std::cmp::Ordering::Equal => (false, vec![b'0']),
        }
    };
    let n = Num { neg: sign && mag != b"0", mag, exp: e };
    fit(&n, ctx, false).0
}

/// decMultiplyOp: the exact product rounded to the context; `Err(true)`
/// is an OVERFLOW (the adjusted exponent past `emax`), `Err(false)` a
/// terminal UNDERFLOW (the value rounded away to zero below `emin`).
fn mul(a: &Num, b: &Num, ctx: &Ctx) -> Result<Num, bool> {
    let n = Num { neg: a.neg != b.neg, mag: umul(&a.mag, &b.mag), exp: a.exp + b.exp };
    let (r, _) = fit(&n, ctx, false);
    range_check(r, ctx)
}

/// decFinalize's exponent checks for a working context: an adjusted
/// exponent past `emax` is Overflow; below `emin` the value is SUBNORMAL
/// and rounds (context rounding) at the tiniest exponent
/// `emin - (digits - 1)`, possibly to zero.
fn range_check(r: Num, ctx: &Ctx) -> Result<Num, bool> {
    if r.is_zero() {
        return Ok(r);
    }
    if r.adjusted() > ctx.emax {
        return Err(true);
    }
    if r.adjusted() < ctx.emin {
        let etiny = ctx.emin - (ctx.digits - 1);
        if r.exp < etiny {
            let drop = (etiny - r.exp) as usize;
            let (mag, dropped) = if drop >= r.mag.len() {
                // all digits fall below etiny: round on the leading one
                let up = drop == r.mag.len()
                    && match ctx.round {
                        Round::Down => false,
                        Round::HalfUp => r.mag[0] >= b'5',
                        Round::HalfEven => {
                            r.mag[0] > b'5'
                                || (r.mag[0] == b'5' && r.mag[1..].iter().any(|&d| d != b'0'))
                        }
                    };
                (if up { vec![b'1'] } else { vec![b'0'] }, drop as i64)
            } else {
                let keep = (r.mag.len() - drop) as i64;
                let (kept, extra, _) = round_mag(&r.mag, keep, ctx.round, false);
                (strip0(kept), drop as i64 + extra)
            };
            let z = mag == b"0";
            let n = Num { neg: r.neg && !z, mag, exp: r.exp + dropped };
            if z {
                return Err(false);
            }
            return Ok(n);
        }
    }
    Ok(r)
}

/// decDivideOp (DIVIDE): the quotient to `ctx.digits` digits with the
/// remainder deciding the rounding; an exact quotient drops trailing
/// zeros back toward the ideal exponent `a.exp - b.exp`.
fn div(a: &Num, b: &Num, ctx: &Ctx) -> Result<Num, MathErr> {
    if b.is_zero() {
        return Err(if a.is_zero() { MathErr::Invalid } else { MathErr::DivByZero });
    }
    let neg = a.neg != b.neg;
    let ideal = a.exp - b.exp;
    if a.is_zero() {
        return Ok(Num { neg: false, mag: vec![b'0'], exp: ideal });
    }
    let p = ctx.digits.max(1) as usize;
    let (mut q, mut rem) = udivmod(&a.mag, &b.mag);
    let mut exp = ideal;
    let sig = |q: &[u8]| if q == b"0" { 0 } else { q.len() };
    while rem != b"0" && sig(&q) < p {
        rem.push(b'0');
        rem = strip0(rem);
        let (d, r) = udivmod(&rem, &b.mag);
        if q == b"0" {
            q = d;
        } else {
            q.extend(d);
        }
        rem = r;
        exp -= 1;
    }
    let mut q = strip0(q);
    if rem != b"0" {
        // the residue from the remainder: > half, = half, < half
        let twice = umul(&rem, b"2");
        let up = match ucmp(&twice, &b.mag) {
            std::cmp::Ordering::Greater => true,
            std::cmp::Ordering::Equal => match ctx.round {
                Round::Down => false,
                Round::HalfUp => true,
                Round::HalfEven => (q[q.len() - 1] - b'0') % 2 == 1,
            },
            std::cmp::Ordering::Less => false,
        };
        if up {
            q = uadd(&q, b"1");
            if q.len() > p {
                q.truncate(p);
                exp += 1;
            }
        }
    } else {
        // exact: trailing zeros go back toward the ideal exponent
        while exp < ideal && q.len() > 1 && q[q.len() - 1] == b'0' {
            q.pop();
            exp += 1;
        }
    }
    Ok(Num { neg: neg && q != b"0", mag: q, exp })
}

/// decCompare, signless: the magnitude order of two working numbers.
fn cmp_mag(a: &Num, b: &Num) -> std::cmp::Ordering {
    if a.is_zero() || b.is_zero() {
        return (!a.is_zero()).cmp(&!b.is_zero());
    }
    match a.adjusted().cmp(&b.adjusted()) {
        std::cmp::Ordering::Equal => {
            let w = a.mag.len().max(b.mag.len());
            let pa = format!("{:0<w$}", std::str::from_utf8(&a.mag).unwrap_or("0"));
            let pb = format!("{:0<w$}", std::str::from_utf8(&b.mag).unwrap_or("0"));
            pa.cmp(&pb)
        }
        o => o,
    }
}

/// The final `decCopyFit + decFinish` into the CALLER's context: round to
/// its digits (with the sticky residue the math routines pass), then the
/// decimal128 range - Overflow past emax, subnormal rounding and the
/// exponent clamp through [crate::decfloat::finite].
fn finish(n: &Num, round: Round, sticky: bool, set: &Ctx) -> Result<Dec, MathErr> {
    let ctx = Ctx { digits: set.digits, round, emax: set.emax, emin: set.emin };
    let (r, _) = fit(n, &ctx, sticky && !n.is_zero());
    if !r.is_zero() && r.adjusted() > set.emax {
        return Err(MathErr::Overflow);
    }
    Ok(finite(r.neg, r.mag, r.exp))
}

fn one() -> Num {
    Num::int(1)
}

/// A fully padded 1.000...0 at `digits` digits - decNumber's inexact 1
/// (`decShiftToMost`), the answer for `exp(tiny)` and `1 ** x`.
fn padded_one(digits: i64) -> Num {
    let mut mag = vec![b'1'];
    mag.extend(std::iter::repeat(b'0').take((digits - 1).max(0) as usize));
    Num { neg: false, mag, exp: -(digits - 1).max(0) }
}

/// decExpOp: e ** x by the Hull & Abrham power series at working
/// precision p (= max(x.digits, set.digits) + h + 2 after normalising x
/// below 1), then a ** (10 ** h) by repeated squaring at p + 2, and the
/// final rounding under the routine's OWN HALF-EVEN context with the
/// sticky residue. `Err(true)` is overflow, `Err(false)` underflow to 0.
fn exp_op(rhs: &Num, set: &Ctx) -> Result<(Num, bool), bool> {
    if rhs.is_zero() {
        return Ok((one(), false));
    }
    // the tiny fast path: |x| <= 4E-digits (one more place for x < 0)
    let mut d = Num { neg: false, mag: vec![b'4'], exp: -set.digits };
    if rhs.neg {
        d.exp -= 1;
    }
    if cmp_mag(&d, rhs) != std::cmp::Ordering::Less {
        return Ok((padded_one(set.digits), true));
    }
    let mut aset = Ctx { digits: 0, round: Round::HalfEven, emax: set.emax, emin: set.emin };
    let mut h = rhs.exp + rhs.digits();
    let (a, p) = if h > 8 {
        // overflow or underflow is certain: 2 ** (10 ** 8) or 0.02 ** ..
        let a = Num { neg: false, mag: vec![b'2'], exp: if rhs.neg { -2 } else { 0 } };
        h = 8;
        (a, 9)
    } else {
        let maxlever = if rhs.digits() > 8 { 1 } else { 0 };
        let lever = (8 - h).min(maxlever);
        let mut use_exp = -rhs.digits() - lever;
        h += lever;
        if h < 0 {
            use_exp += h;
            h = 0;
        }
        let x = Num { neg: rhs.neg, mag: rhs.mag.clone(), exp: use_exp };
        let p = x.digits().max(set.digits) + h + 2;
        let mut t = x.clone();
        let mut a = one();
        let mut dv = Num::int(2);
        let numone = one();
        aset.digits = p * 2;
        let tset = Ctx { digits: p, round: Round::HalfEven, emax: DEC_MAX_MATH * 2, emin: -DEC_MAX_MATH * 2 };
        let dset = Ctx { digits: 16, round: Round::HalfEven, emax: DEC_MAX_MATH * 2, emin: -DEC_MAX_MATH * 2 };
        loop {
            a = add(&a, &t, false, &aset);
            t = match mul(&t, &x, &tset) {
                Ok(v) => v,
                Err(_) => Num { neg: false, mag: vec![b'0'], exp: t.exp },
            };
            t = div(&t, &dv, &tset).unwrap_or(Num { neg: false, mag: vec![b'0'], exp: 0 });
            if (a.digits() + a.exp) >= (t.digits() + t.exp + p + 1) && a.digits() >= p {
                break;
            }
            if t.is_zero() {
                break;
            }
            dv = add(&dv, &numone, false, &dset);
        }
        (a, p)
    };
    let mut a = a;
    if h > 0 {
        aset.digits = p + 2;
        let mut n: i32 = 10i32.pow(h as u32);
        let mut t = one();
        let mut seenbit = false;
        let mut overflow = false;
        let mut underflow = false;
        for i in 1..=31 {
            if overflow || (underflow && t.is_zero()) {
                break;
            }
            n = n.wrapping_shl(1);
            if n < 0 {
                seenbit = true;
                match mul(&t, &a, &aset) {
                    Ok(v) => t = v,
                    Err(true) => {
                        overflow = true;
                        continue;
                    }
                    Err(false) => {
                        underflow = true;
                        t = Num { neg: false, mag: vec![b'0'], exp: 0 };
                        continue;
                    }
                }
            }
            if i == 31 {
                break;
            }
            if !seenbit {
                continue;
            }
            match mul(&t, &t, &aset) {
                Ok(v) => t = v,
                Err(true) => overflow = true,
                Err(false) => {
                    underflow = true;
                    t = Num { neg: false, mag: vec![b'0'], exp: 0 };
                }
            }
        }
        if overflow {
            return Err(true);
        }
        a = t;
    }
    let sticky = !a.is_zero();
    let fctx = Ctx { digits: set.digits, round: Round::HalfEven, emax: set.emax, emin: set.emin };
    let (r, _) = fit(&a, &fctx, sticky);
    Ok((r, sticky))
}

/// LNnn (decNumber.c): the 4-digit initial ln estimate for the two
/// leading digits 10..99 of the fraction, `v = -c * 10 ** (-e - 3)` with
/// c = entry >> 2 and e = entry & 3.
const LNNN: [u16; 90] = [
    9016, 8652, 8316, 8008, 7724, 7456, 7208, 6972, 6748, 6540, 6340, 6148, 5968, 5792, 5628, 5464, 5312,
    5164, 5020, 4884, 4748, 4620, 4496, 4376, 4256, 4144, 4032, 39233, 38181, 37157, 36157, 35181, 34229,
    33297, 32389, 31501, 30629, 29777, 28945, 28129, 27329, 26545, 25777, 25021, 24281, 23553, 22837,
    22137, 21445, 20769, 20101, 19445, 18801, 18165, 17541, 16925, 16321, 15721, 15133, 14553, 13985,
    13421, 12865, 12317, 11777, 11241, 10717, 10197, 9685, 9177, 8677, 8185, 7697, 7213, 6737, 6269, 5801,
    5341, 4889, 4437, 39930, 35534, 31186, 26886, 22630, 18418, 14254, 10130, 6046, 20055,
];

const LN10: &str = "2302585092994045684017991454684364207601";
const LN2: &str = "6931471805599453094172321214581765680755";

/// A decNumber string constant (its digits and the exponent of the last)
/// rounded to `digits` HALF-EVEN - the ln(10) / ln(2) fast paths.
fn constant(digits_str: &str, exp_of_last: i64, digits: i64) -> Num {
    let n = Num { neg: false, mag: digits_str.as_bytes().to_vec(), exp: exp_of_last };
    let ctx = Ctx { digits, round: Round::HalfEven, emax: DEC_MAX_MATH, emin: -DEC_MAX_MATH };
    fit(&n, &ctx, false).0
}

/// decLnOp: ln(x) by Newton's iteration a' = a + x * exp(-a) - 1 from a
/// table estimate, the precision doubling 9 -> 18 -> 36 -> p. The caller
/// has excluded zero and negatives. Returns (result, inexact).
fn ln_op(rhs: &Num, set: &Ctx) -> Result<(Num, bool), MathErr> {
    // the fast paths: ln(10) and ln(2) at 40 digits or fewer, for the
    // exact integers 10 and 2 only (exponent 0 - `2.0` takes the loop)
    if rhs.exp == 0 && set.digits <= 40 {
        if rhs.mag == b"10" {
            return Ok((constant(LN10, -39, set.digits), true));
        }
        if rhs.mag == b"2" {
            return Ok((constant(LN2, -40, set.digits), true));
        }
    }
    let p = rhs.digits().max(set.digits.max(7)) + 2;
    // the initial estimate: ln(f) + ln(10) * r for rhs = f * 10 ** r
    let mut aset = Ctx { digits: 16, round: Round::HalfEven, emax: DEC_MAX_MATH, emin: -DEC_MAX_MATH };
    let r = rhs.exp + rhs.digits();
    let mut a = Num::int(r);
    let b = Num { neg: false, mag: b"2302585".to_vec(), exp: -6 };
    a = mul(&a, &b, &aset).unwrap_or(a);
    // the top two digits of rhs, truncated
    let (two, _, _) = round_mag(&rhs.mag, 2, Round::Down, false);
    let mut t: i64 = std::str::from_utf8(&two).ok().and_then(|s| s.parse().ok()).unwrap_or(10);
    if t < 10 {
        t *= 10;
    }
    let entry = LNNN[(t - 10) as usize] as i64;
    let b = Num { neg: true, mag: (entry >> 2).to_string().into_bytes(), exp: -(entry & 3) - 3 };
    a = add(&a, &b, false, &aset);
    let numone = one();
    aset.emax = set.emax;
    aset.emin = set.emin;
    let mut bset = aset;
    bset.emax = DEC_MAX_MATH * 2;
    bset.emin = -DEC_MAX_MATH * 2;
    let mut pp = 9;
    aset.digits = pp;
    bset.digits = pp + rhs.digits();
    let mut inexact = true;
    let mut exact_zero = false;
    loop {
        a.neg = !a.neg;
        let mut b = match exp_op(&a, &bset) {
            Ok((v, _)) => v,
            Err(_) => Num { neg: false, mag: vec![b'0'], exp: 0 },
        };
        a.neg = !a.neg;
        b = mul(&b, rhs, &bset).unwrap_or(b);
        b = add(&b, &numone, true, &bset);
        if b.is_zero() || (a.digits() + a.exp) >= (b.digits() + b.exp + set.digits + 1) {
            if a.digits() == p {
                break;
            }
            if a.is_zero() {
                if cmp_mag(rhs, &numone) == std::cmp::Ordering::Equal && !rhs.neg {
                    a.exp = 0;
                    exact_zero = true;
                    inexact = false;
                }
                break;
            }
            if b.is_zero() {
                b.exp = a.exp - p;
            }
        }
        a = add(&a, &b, false, &aset);
        if pp == p {
            continue;
        }
        pp = (pp * 2).min(p);
        aset.digits = pp;
        bset.digits = pp + rhs.digits();
    }
    let sticky = !a.is_zero() && !exact_zero;
    let fctx = Ctx { digits: set.digits, round: Round::HalfEven, emax: set.emax, emin: set.emin };
    let (r, _) = fit(&a, &fctx, sticky);
    Ok((r, inexact))
}

/// decGetInt: `Some(n)` for an integer that fits (the 32-bit magnitude
/// thresholds decNumber uses), `None` for a non-integer, or the BIG marker
/// (the integer is too big: its parity only) as `Err(is_odd)`.
fn get_int(n: &Num) -> Result<Option<i64>, bool> {
    if n.is_zero() {
        return Ok(Some(0));
    }
    if n.exp < 0 {
        let frac = (-n.exp) as usize;
        if frac >= n.mag.len() || n.mag[n.mag.len() - frac..].iter().any(|&d| d != b'0') {
            if frac >= n.mag.len() && n.mag.iter().all(|&d| d == b'0') {
                return Ok(Some(0));
            }
            return Ok(None);
        }
    }
    let ilength = n.digits() + n.exp;
    if ilength > 10 {
        let last = n.mag[n.mag.len() - 1 - (-n.exp).max(0) as usize];
        return Err(if n.exp > 0 { false } else { (last - b'0') % 2 == 1 });
    }
    let mut v: i64 = 0;
    let int_digits = &n.mag[..n.mag.len() - (-n.exp).max(0) as usize];
    for &d in int_digits {
        v = v * 10 + (d - b'0') as i64;
    }
    for _ in 0..n.exp.max(0) {
        v *= 10;
    }
    let big = if n.neg { v > 1_999_999_997 } else { v > 999_999_999 };
    if big {
        return Err(v % 2 == 1);
    }
    Ok(Some(if n.neg { -v } else { v }))
}

/// The decimal128 context the engine hands decNumber: 34 digits, HALF-UP.
fn d128() -> Ctx {
    Ctx { digits: 34, round: Round::HalfUp, emax: D128_EMAX, emin: D128_EMIN }
}

/// `Decimal128::pow` - decNumberPower. An integer exponent goes by
/// repeated squaring at 34 + (its integer digits) + 2 digits HALF-EVEN
/// (a negative one inverts the base first), a fractional one by
/// exp(ln(x) * y) at max(x.digits, 34) + 10; the final rounding is the
/// context's HALF-UP. Specials: `0 ** 0` and a negative base to a
/// fractional power are Invalid, `0 ** -n` is Infinity (untrapped),
/// `x ** 0` is 1, `1 ** y` is a padded 1.000...
pub fn pow(lhs: &Dec, rhs: &Dec) -> Result<Dec, MathErr> {
    let set = d128();
    let (l, r) = match (lhs, rhs) {
        (Dec::Nan, _) | (_, Dec::Nan) => return Ok(Dec::Nan),
        (Dec::Infinity { .. }, _) | (_, Dec::Infinity { .. }) => return Err(MathErr::Invalid),
        _ => (Num::from_dec(lhs).ok_or(MathErr::Invalid)?, Num::from_dec(rhs).ok_or(MathErr::Invalid)?),
    };
    let n = get_int(&r);
    let (rhsint, useint, isodd, nval) = match n {
        Ok(Some(v)) => (true, true, v & 1 == 1, v),
        Ok(None) => (false, false, false, 0),
        Err(odd) => (true, false, odd, 0),
    };
    let bits_neg = l.neg && isodd;
    if l.is_zero() {
        if rhsint && useint && nval == 0 {
            return Err(MathErr::Invalid);
        }
        if r.neg {
            return Ok(Dec::Infinity { neg: bits_neg });
        }
        return Ok(Dec::Finite { neg: bits_neg, coeff: 0, exp: 0 });
    }
    let mut aset;
    let dac: Num;
    if !useint {
        if l.neg {
            return Err(MathErr::Invalid);
        }
        aset = Ctx { digits: 0, round: Round::HalfEven, emax: DEC_MAX_MATH, emin: -DEC_MAX_MATH };
        aset.digits = l.digits().max(set.digits) + 6 + 4;
        let (lnx, _) = ln_op(&l, &aset)?;
        if lnx.is_zero() {
            // x == 1: a padded 1.000... for a fractional exponent
            let d = if !rhsint { padded_one(set.digits) } else { one() };
            return finish(&d, set.round, false, &set);
        }
        let m = mul(&lnx, &r, &aset).map_err(|_| MathErr::Overflow)?;
        dac = match exp_op(&m, &aset) {
            Ok((v, _)) => v,
            Err(true) => return Err(MathErr::Overflow),
            Err(false) => Num { neg: false, mag: vec![b'0'], exp: 0 },
        };
    } else {
        if nval == 0 {
            return finish(&one(), set.round, false, &set);
        }
        let mut n = nval.unsigned_abs() as i32;
        aset = set;
        aset.round = Round::HalfEven;
        aset.digits = set.digits + (r.digits() + r.exp) + 2;
        let mut base = l.clone();
        let mut acc = one();
        if r.neg {
            base = div(&one(), &l, &aset)?;
        }
        let mut seenbit = false;
        let mut overflow = false;
        let mut underflow = false;
        for i in 1..=31 {
            if overflow || (underflow && acc.is_zero()) {
                break;
            }
            n = n.wrapping_shl(1);
            if n < 0 {
                seenbit = true;
                match mul(&acc, &base, &aset) {
                    Ok(v) => acc = v,
                    Err(true) => {
                        overflow = true;
                        continue;
                    }
                    Err(false) => {
                        underflow = true;
                        acc = Num { neg: false, mag: vec![b'0'], exp: 0 };
                        continue;
                    }
                }
            }
            if i == 31 {
                break;
            }
            if !seenbit {
                continue;
            }
            match mul(&acc, &acc, &aset) {
                Ok(v) => acc = v,
                Err(true) => overflow = true,
                Err(false) => {
                    underflow = true;
                    acc = Num { neg: false, mag: vec![b'0'], exp: 0 };
                }
            }
        }
        if overflow {
            return Err(MathErr::Overflow);
        }
        acc.neg = bits_neg && !acc.is_zero();
        dac = acc;
    }
    let mut d = dac;
    d.neg = bits_neg && !d.is_zero();
    finish(&d, set.round, false, &set)
}

/// `Decimal128::ln` - decNumberLn. The caller has already refused a
/// non-positive argument (the engine's "Argument for LN must be
/// positive" comes first); zero here is -Infinity and a negative Invalid.
pub fn ln(x: &Dec) -> Result<Dec, MathErr> {
    let set = d128();
    let n = match x {
        Dec::Nan => return Ok(Dec::Nan),
        Dec::Infinity { neg: false } => return Ok(*x),
        Dec::Infinity { neg: true } => return Err(MathErr::Invalid),
        _ => Num::from_dec(x).ok_or(MathErr::Invalid)?,
    };
    if n.is_zero() {
        return Ok(Dec::Infinity { neg: true });
    }
    if n.neg {
        return Err(MathErr::Invalid);
    }
    let (r, inexact) = ln_op(&n, &set)?;
    finish(&r, Round::HalfEven, inexact, &set)
}

/// `Decimal128::log10` - decNumberLog10: an exact power of ten answers
/// its exponent exactly; otherwise ln(x) at max(x.digits + 6, 34) + 3
/// digits over ln(10) at 37, divided at 34 HALF-EVEN (the routine's own
/// working context, not the session's HALF-UP).
pub fn log10(x: &Dec) -> Result<Dec, MathErr> {
    let set = d128();
    let n = match x {
        Dec::Nan => return Ok(Dec::Nan),
        Dec::Infinity { neg: false } => return Ok(*x),
        Dec::Infinity { neg: true } => return Err(MathErr::Invalid),
        _ => Num::from_dec(x).ok_or(MathErr::Invalid)?,
    };
    if n.is_zero() {
        return Ok(Dec::Infinity { neg: true });
    }
    if n.neg {
        return Err(MathErr::Invalid);
    }
    // an exact power of ten: round to one digit, exact and that digit 1
    let (w, drop, _) = round_mag(&n.mag, 1, Round::HalfEven, false);
    if w == b"1" && n.mag[1..].iter().all(|&d| d == b'0') {
        let e = n.exp + drop;
        return finish(&Num::int(e), set.round, false, &set);
    }
    let mut aset = Ctx { digits: 0, round: Round::HalfEven, emax: DEC_MAX_MATH, emin: -DEC_MAX_MATH };
    aset.digits = (n.digits() + 6).max(set.digits) + 3;
    let (a, _) = ln_op(&n, &aset)?;
    if a.is_zero() {
        return finish(&a, set.round, false, &set);
    }
    aset.digits = set.digits + 3;
    let (b, _) = ln_op(&Num::int(10), &aset)?;
    aset.digits = set.digits;
    let q = div(&a, &b, &aset)?;
    finish(&q, Round::HalfEven, false, &set)
}

/// The engine's EXP: `e.pow(x)` over its 34-digit e
/// (SysFunction.cpp evlExp: "2.718281828459045235360287471352662497757"
/// rounded HALF-UP to 34 digits), which is [pow] with that base.
pub fn exp(x: &Dec) -> Result<Dec, MathErr> {
    let e = Dec::Finite { neg: false, coeff: 2718281828459045235360287471352662, exp: -33 };
    pow(&e, x)
}

/// `Decimal128::sqrt` - decNumberSquareRoot, already in
/// [crate::decfloat::sqrt]; a negative operand is Invalid.
pub fn sqrt(x: &Dec) -> Result<Dec, MathErr> {
    match dfl::sqrt(x) {
        Dec::Nan if !matches!(x, Dec::Nan) => Err(MathErr::Invalid),
        r => Ok(r),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(coeff: u128, exp: i32) -> Dec {
        Dec::Finite { neg: false, coeff, exp }
    }
    fn s(r: Result<Dec, MathErr>) -> String {
        match r {
            Ok(v) => dfl::to_string(&v),
            Err(e) => format!("{:?}", e),
        }
    }

    #[test]
    fn exp_as_the_engine_answers() {
        // measured on 2182: EXP over INT128 / NUMERIC(38) / DECFLOAT
        assert_eq!(s(exp(&d(1, 0))), "2.718281828459045235360287471352662");
        assert_eq!(s(exp(&d(100, 0))), "2.688117141816135448412625551579964E+43");
        assert_eq!(s(exp(&Dec::Finite { neg: true, coeff: 1, exp: 0 })), "0.3678794411714423215955237701614609");
        assert_eq!(s(exp(&d(20, -1))), "7.389056098930650227230427460575005");
        assert_eq!(s(exp(&d(0, 0))), "1");
        assert_eq!(s(exp(&d(16, 0))), "8886110.520507872636763023740781424");
        assert_eq!(s(exp(&d(7, 0))), "1096.633158428458599263720238288120");
        assert_eq!(s(exp(&d(10000, 0))), "8.806818225662921587261496007628434E+4342");
        assert_eq!(s(exp(&Dec::Finite { neg: true, coeff: 10000, exp: 0 })), "1.135483865314736098540938875068328E-4343");
    }

    #[test]
    fn ln_and_log10_as_the_engine_answers() {
        assert_eq!(s(ln(&d(10, 0))), "2.302585092994045684017991454684364");
        assert_eq!(s(ln(&d(2, 0))), "0.6931471805599453094172321214581766");
        assert_eq!(s(ln(&d(200, -2))), "0.6931471805599453094172321214581766");
        assert_eq!(s(ln(&d(1, 0))), "0");
        assert_eq!(s(ln(&d(123456789012345678901234567890, 0))), "66.98568871914297739757675389633419");
        assert_eq!(s(log10(&d(1000, 0))), "3");
        assert_eq!(s(log10(&d(100000, -2))), "3");
        assert_eq!(s(log10(&d(1, 0))), "0");
        assert_eq!(s(log10(&d(7, 0))), "0.8450980400142568307122162585926362");
    }

    #[test]
    fn pow_as_the_engine_answers() {
        assert_eq!(s(pow(&d(10, 0), &d(30, 0))), "1000000000000000000000000000000");
        assert_eq!(s(pow(&d(2, 0), &d(100, 0))), "1267650600228229401496703205376");
        assert_eq!(s(pow(&d(2, 0), &d(120, 0))), "1.329227995784915872903807060280345E+36");
        assert_eq!(s(pow(&d(1000, -2), &d(3, 0))), "1000.000000");
        assert_eq!(s(pow(&d(5, 0), &d(7, 0))), "78125");
        assert_eq!(s(pow(&d(25, -1), &d(3, 0))), "15.625");
        assert_eq!(s(pow(&d(7, 0), &d(25, -1))), "129.6418142421649389345791719283238");
        assert_eq!(s(pow(&d(11, -1), &d(100, 0))), "13780.61233982227018411833717208964");
        assert_eq!(s(pow(&d(20, -1), &d(5, -1))), "1.414213562373095048801688724209698");
        assert_eq!(s(pow(&d(16, 0), &d(5, -1))), "4.000000000000000000000000000000000");
        assert_eq!(s(pow(&d(10, 0), &d(6144, 0))), "1.000000000000000000000000000000000E+6144");
        assert_eq!(s(pow(&d(10, 0), &d(6145, 0))), "Overflow");
        assert_eq!(s(pow(&d(10, 0), &d(33, 0))), "1000000000000000000000000000000000");
        assert_eq!(s(pow(&d(10, 0), &d(34, 0))), "1.000000000000000000000000000000000E+34");
        assert_eq!(s(pow(&d(3, 0), &d(80, 0))), "1.478088294143459233160832102063833E+38");
        assert_eq!(s(pow(&d(0, 0), &Dec::Finite { neg: true, coeff: 1, exp: 0 })), "Infinity");
        assert_eq!(s(pow(&d(0, 0), &d(0, 0))), "Invalid");
        assert_eq!(s(pow(&Dec::Finite { neg: true, coeff: 2, exp: 0 }, &d(5, -1))), "Invalid");
        assert_eq!(s(pow(&Dec::Finite { neg: true, coeff: 2, exp: 0 }, &d(3, 0))), "-8");
        assert_eq!(s(pow(&d(55, -1), &d(2, 0))), "30.25");
    }

    #[test]
    fn sqrt_as_the_engine_answers() {
        assert_eq!(s(sqrt(&d(5, 0))), "2.236067977499789696409173668731276");
        assert_eq!(s(sqrt(&d(7, 0))), "2.645751311064590590501615753639260");
        assert_eq!(s(sqrt(&d(10000, -2))), "10.0");
        assert_eq!(s(sqrt(&Dec::Finite { neg: true, coeff: 1, exp: 0 })), "Invalid");
    }
}
