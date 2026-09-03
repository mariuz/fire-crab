//! From-scratch cryptographic primitives for the SRP handshake and
//! wire encryption - SHA-1, SHA-256, big-integer modular exponentiation
//! and RC4. fire-crab's core stays dependency-free; each primitive is
//! validated against published test vectors (the unit tests below) the
//! same way the on-disk decoders are validated against the engine.

// ---------------------------------------------------------------- SHA-1 ---

pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let ml = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&ml.to_be_bytes());

    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (i, wi) in w.iter_mut().take(16).enumerate() {
            *wi = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A827999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }
    let mut out = [0u8; 20];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

// -------------------------------------------------------------- SHA-256 ---

pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let ml = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&ml.to_be_bytes());

    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, wi) in w.iter_mut().take(16).enumerate() {
            *wi = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ ((!v[4]) & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v[7] = v[6];
            v[6] = v[5];
            v[5] = v[4];
            v[4] = v[3].wrapping_add(t1);
            v[3] = v[2];
            v[2] = v[1];
            v[1] = v[0];
            v[0] = t1.wrapping_add(t2);
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    let mut out = [0u8; 32];
    for (i, val) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&val.to_be_bytes());
    }
    out
}

// --------------------------------------------------------------- BigUint ---
// Minimal big-endian-input, little-endian-limb unsigned bignum, enough
// for SRP modular exponentiation with the 1024-bit group.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BigUint {
    /// base-2^32 limbs, least significant first, no trailing zeros
    limbs: Vec<u32>,
}

impl BigUint {
    pub fn zero() -> Self {
        BigUint { limbs: vec![] }
    }
    pub fn from_bytes_be(b: &[u8]) -> Self {
        let mut limbs = Vec::new();
        let mut i = b.len();
        while i > 0 {
            let lo = i.saturating_sub(4);
            let mut v = 0u32;
            for &byte in &b[lo..i] {
                v = (v << 8) | byte as u32;
            }
            limbs.push(v);
            i = lo;
        }
        let mut r = BigUint { limbs };
        r.trim();
        r
    }
    /// Minimal big-endian bytes (no leading zeros) - matches the
    /// reference's bigToBuf (Firebird hashes over minimal encodings).
    pub fn to_bytes_be(&self) -> Vec<u8> {
        if self.limbs.is_empty() {
            return vec![];
        }
        let mut out = Vec::with_capacity(self.limbs.len() * 4);
        for &limb in self.limbs.iter().rev() {
            out.extend_from_slice(&limb.to_be_bytes());
        }
        let first = out.iter().position(|&b| b != 0).unwrap_or(out.len());
        out[first..].to_vec()
    }
    fn trim(&mut self) {
        while self.limbs.last() == Some(&0) {
            self.limbs.pop();
        }
    }
    fn is_zero(&self) -> bool {
        self.limbs.is_empty()
    }
    fn bit(&self, i: usize) -> bool {
        self.limbs
            .get(i / 32)
            .map(|l| (l >> (i % 32)) & 1 == 1)
            .unwrap_or(false)
    }
    fn bits(&self) -> usize {
        match self.limbs.last() {
            None => 0,
            Some(&top) => (self.limbs.len() - 1) * 32 + (32 - top.leading_zeros() as usize),
        }
    }
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering::*;
        if self.limbs.len() != other.limbs.len() {
            return self.limbs.len().cmp(&other.limbs.len());
        }
        for i in (0..self.limbs.len()).rev() {
            match self.limbs[i].cmp(&other.limbs[i]) {
                Equal => continue,
                o => return o,
            }
        }
        Equal
    }
    /// self -= other, assuming self >= other
    fn sub(&self, other: &Self) -> Self {
        let mut out = Vec::with_capacity(self.limbs.len());
        let mut borrow = 0i64;
        for i in 0..self.limbs.len() {
            let o = *other.limbs.get(i).unwrap_or(&0) as i64;
            let mut d = self.limbs[i] as i64 - o - borrow;
            if d < 0 {
                d += 1 << 32;
                borrow = 1;
            } else {
                borrow = 0;
            }
            out.push(d as u32);
        }
        let mut r = BigUint { limbs: out };
        r.trim();
        r
    }
    /// raw addition (no modulus)
    fn add(&self, other: &Self) -> Self {
        let n = self.limbs.len().max(other.limbs.len()) + 1;
        let mut out = vec![0u32; n];
        let mut carry = 0u64;
        for (i, o) in out.iter_mut().enumerate() {
            let s = *self.limbs.get(i).unwrap_or(&0) as u64
                + *other.limbs.get(i).unwrap_or(&0) as u64
                + carry;
            *o = (s & 0xffff_ffff) as u32;
            carry = s >> 32;
        }
        let mut r = BigUint { limbs: out };
        r.trim();
        r
    }
    /// Schoolbook multiplication straight into the result's limbs.
    ///
    /// It used to accumulate into a `Vec<u64>` and then build a SECOND
    /// vector out of it (`out.into_iter().map(|v| v as u32).collect()`) -
    /// two allocations and a full copy per multiply, and modpow does one
    /// per exponent bit. The carry still travels in a u64; only the
    /// storage changed.
    fn mul(&self, other: &Self) -> Self {
        if self.is_zero() || other.is_zero() {
            return BigUint::zero();
        }
        let (n, k) = (self.limbs.len(), other.limbs.len());
        let mut out = vec![0u32; n + k];
        for (i, &a) in self.limbs.iter().enumerate() {
            let mut carry = 0u64;
            for (j, &b) in other.limbs.iter().enumerate() {
                let cur = out[i + j] as u64 + a as u64 * b as u64 + carry;
                out[i + j] = cur as u32;
                carry = cur >> 32;
            }
            // out[i + k] is still zero: no inner pass has reached it
            out[i + k] = carry as u32;
        }
        let mut r = BigUint { limbs: out };
        r.trim();
        r
    }
    /// self mod m, by limb-wise long division: Knuth's algorithm D
    /// (TAOCP 4.3.1, in the `divmnu` shape), which produces one estimated
    /// quotient digit per LIMB of the dividend.
    ///
    /// What it replaced was binary long division - shift, compare,
    /// conditionally subtract, once per BIT - so reducing the 2048-bit
    /// product of two SRP-group numbers ran 2048 rounds and allocated a
    /// fresh Vec on most of them. An attach did 3275 of these reductions,
    /// 6.6 million rounds and 1.65 million allocating subtractions.
    ///
    /// The two degenerate moduli keep the OLD function's answers exactly,
    /// because callers exist for both: `x mod 0` returned x (the loop
    /// subtracted nothing), and `x mod 1` returned 0.
    fn rem(&self, m: &Self) -> Self {
        use std::cmp::Ordering::Less;
        if m.limbs.is_empty() || self.cmp(m) == Less {
            return self.clone();
        }
        // one-limb divisor: the schoolbook single-digit pass
        if m.limbs.len() == 1 {
            let d = m.limbs[0] as u64;
            let mut r = 0u64;
            for &l in self.limbs.iter().rev() {
                r = (((r << 32) | l as u64) % d) & 0xffff_ffff;
            }
            let mut out = BigUint { limbs: vec![r as u32] };
            out.trim();
            return out;
        }

        const B: u64 = 1 << 32;
        let n = m.limbs.len();
        let ulen = self.limbs.len();
        // normalise: shift both so the divisor's top limb has its high bit
        // set, which is what makes the two-limb quotient estimate below
        // wrong by at most one
        let sh = m.limbs[n - 1].leading_zeros();
        // the shifted divisor is only needed when there IS a shift; when
        // the top limb already has its high bit set the modulus is used
        // where it lies, and nothing is allocated for it
        let mut vbuf: Vec<u32>;
        let mut u = vec![0u32; ulen + 1];
        let v: &[u32] = if sh == 0 {
            u[..ulen].copy_from_slice(&self.limbs);
            &m.limbs
        } else {
            vbuf = vec![0u32; n];
            for i in (1..n).rev() {
                vbuf[i] = (m.limbs[i] << sh) | (m.limbs[i - 1] >> (32 - sh));
            }
            vbuf[0] = m.limbs[0] << sh;
            u[ulen] = self.limbs[ulen - 1] >> (32 - sh);
            for i in (1..ulen).rev() {
                u[i] = (self.limbs[i] << sh) | (self.limbs[i - 1] >> (32 - sh));
            }
            u[0] = self.limbs[0] << sh;
            &vbuf
        };

        for j in (0..=(ulen - n)).rev() {
            // estimate the quotient digit from the top two limbs
            let num = (u[j + n] as u64) * B + u[j + n - 1] as u64;
            let mut qhat = num / v[n - 1] as u64;
            let mut rhat = num % v[n - 1] as u64;
            // `qhat >= B` is not dead code even though no test and no
            // real handshake reaches it (see
            // [diff_fuzz::sweep_the_division_estimate_edges]): it keeps
            // the multiply below inside u64, since `(B + 1)(B - 1)` is
            // already u64::MAX and the carry would push it over
            while qhat >= B || qhat * v[n - 2] as u64 > rhat * B + u[j + n - 2] as u64 {
                qhat -= 1;
                rhat += v[n - 1] as u64;
                if rhat >= B {
                    break;
                }
            }
            // u[j..j+n+1] -= qhat * v
            let mut borrow = 0i64;
            let mut carry = 0u64;
            for i in 0..n {
                let p = qhat * v[i] as u64 + carry;
                carry = p >> 32;
                let t = u[i + j] as i64 - borrow - (p & 0xffff_ffff) as i64;
                u[i + j] = t as u32;
                borrow = if t < 0 { 1 } else { 0 };
            }
            let t = u[j + n] as i64 - carry as i64 - borrow;
            u[j + n] = t as u32;
            if t < 0 {
                // the estimate was one too large (about twice in 2^32
                // digits): add the divisor back
                let mut carry = 0u64;
                for i in 0..n {
                    let sum = u[i + j] as u64 + v[i] as u64 + carry;
                    u[i + j] = sum as u32;
                    carry = sum >> 32;
                }
                u[j + n] = (u[j + n] as u64 + carry) as u32;
            }
        }

        // the remainder is the low n limbs, denormalised in place - the
        // dividend's working buffer becomes the result rather than being
        // copied into a third one
        if sh != 0 {
            for i in 0..n - 1 {
                u[i] = (u[i] >> sh) | (u[i + 1] << (32 - sh));
            }
            u[n - 1] >>= sh;
        }
        u.truncate(n);
        let mut out = BigUint { limbs: u };
        out.trim();
        out
    }
    /// base^exp mod m (square-and-multiply).
    ///
    /// For an ODD modulus of two limbs or more - which the SRP prime is,
    /// and which is the only shape this crate's own callers ever pass -
    /// the squarings and multiplies run in the MONTGOMERY domain, where
    /// reduction is a shift instead of a division. The conversions in and
    /// out are two ordinary reductions plus one extra Montgomery multiply,
    /// and they are counted in every measurement quoted for this function.
    ///
    /// Every other modulus - even, single-limb, one, zero - keeps the
    /// plain square-and-multiply below, unchanged, so those answers are
    /// the old function's answers by construction (`x mod 0` reduces
    /// nothing in either version).
    pub fn modpow(base: &Self, exp: &Self, m: &Self) -> Self {
        if m.limbs.len() >= 2 && m.limbs[0] & 1 == 1 {
            return BigUint::modpow_odd(base, exp, m);
        }
        let mut result = BigUint::from_bytes_be(&[1]).rem(m);
        let mut b = base.rem(m);
        for i in 0..exp.bits() {
            if exp.bit(i) {
                result = result.mul(&b).rem(m);
            }
            b = b.mul(&b).rem(m);
        }
        result
    }

    /// `base^exp mod m` for an odd `m` of at least two limbs, by
    /// Montgomery multiplication (Koc's CIOS form: interleave the
    /// multiply with the reduction, one limb at a time).
    ///
    /// The trick is the domain change. Working with `a~ = a*R mod m`,
    /// where `R = 2^(32n)` is bigger than `m` and coprime to it because
    /// `m` is odd, a product `a~ * b~ * R^-1 mod m` can be computed with
    /// shifts and multiplies alone - no trial quotient, no division. So
    /// the inner loop, which ran a full Knuth division after every
    /// squaring and every multiply, runs none at all; the only divisions
    /// left in an exponentiation are the two that enter the domain.
    fn modpow_odd(base: &Self, exp: &Self, m: &Self) -> Self {
        let n = m.limbs.len();
        let md = &m.limbs[..];

        // n0 = -m[0]^-1 mod 2^32, by Newton's iteration on the inverse
        // (each step doubles the number of correct bits: 2, 4, 8, 16, 32)
        let m0 = md[0];
        let mut inv: u32 = 1;
        for _ in 0..5 {
            inv = inv.wrapping_mul(2u32.wrapping_sub(m0.wrapping_mul(inv)));
        }
        let n0 = inv.wrapping_neg();

        // R mod m and base*R mod m: the two ordinary reductions this
        // costs. R is 2^(32n), i.e. one 1 limb above the modulus.
        let mut r_limbs = vec![0u32; n];
        r_limbs.push(1);
        let r_mod = (BigUint { limbs: r_limbs }).rem(m);
        let mut shifted = vec![0u32; n];
        shifted.extend_from_slice(&base.rem(m).limbs);
        let mut sh = BigUint { limbs: shifted };
        sh.trim();
        let base_mont = sh.rem(m);

        let pad = |v: &BigUint| -> Vec<u32> {
            let mut o = v.limbs.clone();
            o.resize(n, 0);
            o
        };
        let mut cur = pad(&r_mod); // 1 in the Montgomery domain
        let mut b = pad(&base_mont);
        let mut out = vec![0u32; n];
        let mut t = vec![0u32; n + 2];

        for i in 0..exp.bits() {
            if exp.bit(i) {
                mont_mul(&cur, &b, md, n0, &mut t, &mut out);
                std::mem::swap(&mut cur, &mut out);
            }
            mont_mul(&b, &b, md, n0, &mut t, &mut out);
            std::mem::swap(&mut b, &mut out);
        }

        // leave the domain: a~ * 1 * R^-1 = a
        let mut one = vec![0u32; n];
        one[0] = 1;
        mont_mul(&cur, &one, md, n0, &mut t, &mut out);
        let mut r = BigUint { limbs: out };
        r.trim();
        r
    }
    /// (self + other) mod m
    pub fn add_mod(&self, other: &Self, m: &Self) -> Self {
        self.add(other).rem(m)
    }
    /// (self - other) mod m, result non-negative (matches C++ mod()).
    pub fn sub_mod(&self, other: &Self, m: &Self) -> Self {
        let a = self.rem(m);
        let b = other.rem(m);
        if a.cmp(&b) != std::cmp::Ordering::Less {
            a.sub(&b)
        } else {
            a.add(m).sub(&b) // (a + m) - b, no reduction (a < b < m)
        }
    }
    /// (self * other) mod m
    pub fn mul_mod(&self, other: &Self, m: &Self) -> Self {
        self.mul(other).rem(m)
    }
}

/// One Montgomery multiplication: `out = a * b * R^-1 mod m`, with
/// `R = 2^(32n)`, `n` = the modulus's limb count, `n0 = -m[0]^-1 mod
/// 2^32`, and `a`, `b`, `out` all exactly `n` limbs. `t` is scratch of
/// `n + 2` limbs, reused across a whole exponentiation so that the inner
/// loop allocates nothing at all.
///
/// This is Koc's CIOS: one pass per limb of `a`, each pass adding
/// `a[i] * b` and then a multiple of `m` chosen to clear the bottom limb,
/// which is then shifted away. The running value stays below `2 * m`, so
/// one conditional subtraction at the end brings it into range.
fn mont_mul(a: &[u32], b: &[u32], m: &[u32], n0: u32, t: &mut [u32], out: &mut [u32]) {
    let n = m.len();
    for x in t.iter_mut() {
        *x = 0;
    }
    for &ai in a.iter().take(n) {
        // t += a[i] * b
        let mut carry = 0u64;
        for j in 0..n {
            let cur = t[j] as u64 + ai as u64 * b[j] as u64 + carry;
            t[j] = cur as u32;
            carry = cur >> 32;
        }
        let cur = t[n] as u64 + carry;
        t[n] = cur as u32;
        t[n + 1] = (cur >> 32) as u32;

        // t += m * (t[0] * n0 mod 2^32), which makes t[0] zero, then
        // shift one limb down
        let mp = t[0].wrapping_mul(n0);
        let mut carry = (t[0] as u64 + mp as u64 * m[0] as u64) >> 32;
        for j in 1..n {
            let cur = t[j] as u64 + mp as u64 * m[j] as u64 + carry;
            t[j - 1] = cur as u32;
            carry = cur >> 32;
        }
        let cur = t[n] as u64 + carry;
        t[n - 1] = cur as u32;
        t[n] = t[n + 1] + (cur >> 32) as u32;
    }

    // t < 2m: subtract the modulus once if it is not already below it
    let mut ge = t[n] != 0;
    if !ge {
        ge = true;
        for j in (0..n).rev() {
            if t[j] != m[j] {
                ge = t[j] > m[j];
                break;
            }
        }
    }
    if ge {
        let mut borrow = 0i64;
        for j in 0..n {
            let d = t[j] as i64 - m[j] as i64 - borrow;
            out[j] = d as u32;
            borrow = if d < 0 { 1 } else { 0 };
        }
    } else {
        out[..n].copy_from_slice(&t[..n]);
    }
}

/// Limb-level access, for the differential fuzz alone: it compares the
/// LIMB VECTORS as well as the byte forms, so a result that merely prints
/// the same (a stray trailing zero limb, say) cannot pass.
#[cfg(test)]
impl BigUint {
    pub(crate) fn from_limbs_for_test(l: &[u32]) -> Self {
        let mut r = BigUint { limbs: l.to_vec() };
        r.trim();
        r
    }
    pub(crate) fn limbs_for_test(&self) -> &[u32] {
        &self.limbs
    }
}

// ---------------------------------------------------------- WIRE CIPHERS ---
// The wire-encryption plugins the engine ships and a client may pick
// (firebird.conf WireCryptPlugin, default "ChaCha64, ChaCha, Arc4"):
//
// * Arc4 - byte-for-byte the engine's Cypher
//   (src/plugins/crypt/arc4/Arc4.cpp), keyed with the SRP session key;
// * ChaCha / ChaCha64 - src/plugins/crypt/chacha/ChaCha.cpp: the key is
//   SHA-256 of the session key (`createCypher`: "stretched key"), the IV
//   is the plugin's SPECIFIC DATA - 16 bytes for ChaCha (12 of nonce, 4 of
//   big-endian initial counter, `chacha_ivctr32`), 8 for ChaCha64 (an
//   8-byte nonce with a 64-bit counter from 0, `chacha_ivctr64`) - which
//   the SERVER generates and announces in its accept keys, the client
//   adopting it.
//
// [Rc4] keeps its name (every read/write site in the server threads an
// `Option<Rc4>`) and is now any of the three.

enum Cipher {
    Arc4 { s: [u8; 256], i: u8, j: u8 },
    ChaCha(ChaCha20),
}

pub struct Rc4 {
    c: Cipher,
}

impl Rc4 {
    /// Arc4 over the key as given
    pub fn new(key: &[u8]) -> Self {
        let mut s = [0u8; 256];
        for (i, si) in s.iter_mut().enumerate() {
            *si = i as u8;
        }
        let mut j = 0u8;
        for i in 0..256 {
            j = j.wrapping_add(s[i]).wrapping_add(key[i % key.len()]);
            s.swap(i, j as usize);
        }
        Rc4 { c: Cipher::Arc4 { s, i: 0, j: 0 } }
    }
    /// The engine's "ChaCha" plugin: SHA-256-stretched key, a 16-byte IV
    /// (12 nonce bytes, then the 32-bit initial counter big-endian)
    pub fn chacha(session_key: &[u8], iv: &[u8; 16]) -> Self {
        let key = sha256(session_key);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&iv[..12]);
        let ctr = u32::from_be_bytes([iv[12], iv[13], iv[14], iv[15]]);
        Rc4 { c: Cipher::ChaCha(ChaCha20::new(&key, Nonce::Ietf(nonce, ctr))) }
    }
    /// The engine's "ChaCha64" plugin: SHA-256-stretched key, an 8-byte
    /// nonce with a 64-bit counter from zero
    pub fn chacha64(session_key: &[u8], iv: &[u8; 8]) -> Self {
        let key = sha256(session_key);
        Rc4 { c: Cipher::ChaCha(ChaCha20::new(&key, Nonce::Original(*iv))) }
    }
    pub fn transform(&mut self, buf: &[u8]) -> Vec<u8> {
        match &mut self.c {
            Cipher::Arc4 { s, i, j } => {
                let mut out = Vec::with_capacity(buf.len());
                for &byte in buf {
                    *i = i.wrapping_add(1);
                    *j = j.wrapping_add(s[*i as usize]);
                    s.swap(*i as usize, *j as usize);
                    let k = s[(s[*i as usize].wrapping_add(s[*j as usize])) as usize];
                    out.push(byte ^ k);
                }
                out
            }
            Cipher::ChaCha(c) => c.transform(buf),
        }
    }
}

/// The two ChaCha20 nonce layouts libtomcrypt offers: the IETF one (RFC
/// 7539: 96-bit nonce, 32-bit counter) and the original (64-bit nonce,
/// 64-bit counter).
enum Nonce {
    Ietf([u8; 12], u32),
    Original([u8; 8]),
}

/// ChaCha20 (D. J. Bernstein; the quarter-round and block function of RFC
/// 7539), as a byte stream: the keystream block is regenerated per 64
/// bytes and XORed in, the position carried across calls.
pub struct ChaCha20 {
    state: [u32; 16],
    block: [u8; 64],
    used: usize,
    wide_counter: bool,
}

impl ChaCha20 {
    fn new(key: &[u8; 32], nonce: Nonce) -> ChaCha20 {
        let mut state = [0u32; 16];
        state[0..4].copy_from_slice(&[0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]);
        for i in 0..8 {
            state[4 + i] = u32::from_le_bytes(key[4 * i..4 * i + 4].try_into().unwrap());
        }
        let wide_counter = match nonce {
            Nonce::Ietf(n, ctr) => {
                state[12] = ctr;
                for i in 0..3 {
                    state[13 + i] = u32::from_le_bytes(n[4 * i..4 * i + 4].try_into().unwrap());
                }
                false
            }
            Nonce::Original(n) => {
                state[12] = 0;
                state[13] = 0;
                state[14] = u32::from_le_bytes(n[0..4].try_into().unwrap());
                state[15] = u32::from_le_bytes(n[4..8].try_into().unwrap());
                true
            }
        };
        ChaCha20 { state, block: [0u8; 64], used: 64, wide_counter }
    }
    fn quarter(x: &mut [u32; 16], a: usize, b: usize, c: usize, d: usize) {
        x[a] = x[a].wrapping_add(x[b]);
        x[d] = (x[d] ^ x[a]).rotate_left(16);
        x[c] = x[c].wrapping_add(x[d]);
        x[b] = (x[b] ^ x[c]).rotate_left(12);
        x[a] = x[a].wrapping_add(x[b]);
        x[d] = (x[d] ^ x[a]).rotate_left(8);
        x[c] = x[c].wrapping_add(x[d]);
        x[b] = (x[b] ^ x[c]).rotate_left(7);
    }
    fn next_block(&mut self) {
        let mut x = self.state;
        for _ in 0..10 {
            Self::quarter(&mut x, 0, 4, 8, 12);
            Self::quarter(&mut x, 1, 5, 9, 13);
            Self::quarter(&mut x, 2, 6, 10, 14);
            Self::quarter(&mut x, 3, 7, 11, 15);
            Self::quarter(&mut x, 0, 5, 10, 15);
            Self::quarter(&mut x, 1, 6, 11, 12);
            Self::quarter(&mut x, 2, 7, 8, 13);
            Self::quarter(&mut x, 3, 4, 9, 14);
        }
        for i in 0..16 {
            let v = x[i].wrapping_add(self.state[i]);
            self.block[4 * i..4 * i + 4].copy_from_slice(&v.to_le_bytes());
        }
        // the counter: 32 bits (IETF) or 64 bits (original)
        self.state[12] = self.state[12].wrapping_add(1);
        if self.wide_counter && self.state[12] == 0 {
            self.state[13] = self.state[13].wrapping_add(1);
        }
        self.used = 0;
    }
    pub fn transform(&mut self, buf: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(buf.len());
        for &b in buf {
            if self.used == 64 {
                self.next_block();
            }
            out.push(b ^ self.block[self.used]);
            self.used += 1;
        }
        out
    }
}

// --------------------------------------------------------- LEGACY_AUTH ----
// The Legacy_Auth plugin's credential is the classic DES crypt(3) of the
// password under the fixed salt "9z" (src/common/enc.cpp ENC_crypt,
// LEGACY_PASSWORD_SALT), the two salt characters dropped - the client
// sends those 11 characters as its specific data. The C library's crypt
// still implements the DES scheme on this platform, so it is asked
// rather than ported.
#[link(name = "crypt")]
extern "C" {
    fn crypt(key: *const std::os::raw::c_char, salt: *const std::os::raw::c_char) -> *const std::os::raw::c_char;
}

/// The 11 characters a Legacy_Auth client sends for `password`, or None
/// when the platform's crypt has no DES scheme
pub fn legacy_credential(password: &str) -> Option<String> {
    let key = std::ffi::CString::new(password).ok()?;
    let salt = std::ffi::CString::new("9z").ok()?;
    // SAFETY: both pointers are valid NUL-terminated strings for the call;
    // crypt returns a pointer into static storage (or NULL), copied out
    // before any other call
    let out = unsafe { crypt(key.as_ptr(), salt.as_ptr()) };
    if out.is_null() {
        return None;
    }
    let full = unsafe { std::ffi::CStr::from_ptr(out) }.to_string_lossy().into_owned();
    if full.len() < 13 || !full.starts_with("9z") {
        return None;
    }
    Some(full[2..].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{:02x}", x)).collect()
    }

    #[test]
    fn sha1_vectors() {
        assert_eq!(hex(&sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(
            hex(&sha1(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn rc4_vector() {
        // RFC 6229 / classic: key "Key", "Plaintext" -> BBF316E8D940AF0AD3
        let mut c = Rc4::new(b"Key");
        assert_eq!(
            hex(&c.transform(b"Plaintext")).to_uppercase(),
            "BBF316E8D940AF0AD3"
        );
    }

    #[test]
    fn bignum_modpow_small() {
        let two = BigUint::from_bytes_be(&[2]);
        let ten = BigUint::from_bytes_be(&[10]);
        let thousand = BigUint::from_bytes_be(&[0x03, 0xE8]);
        // 2^10 mod 1000 = 1024 mod 1000 = 24
        assert_eq!(
            BigUint::modpow(&two, &ten, &thousand).to_bytes_be(),
            vec![24]
        );
    }

    #[test]
    fn bignum_modpow_larger() {
        // 4^13 mod 497 = 445 (a standard modexp example)
        let four = BigUint::from_bytes_be(&[4]);
        let thirteen = BigUint::from_bytes_be(&[13]);
        let m = BigUint::from_bytes_be(&[0x01, 0xF1]); // 497
                                                       // 4^13 mod 497 = 445 = 0x01BD
        assert_eq!(
            BigUint::modpow(&four, &thirteen, &m).to_bytes_be(),
            vec![0x01, 0xBD]
        );
    }

    #[test]
    fn bytes_roundtrip_minimal() {
        let b = BigUint::from_bytes_be(&[0x00, 0x00, 0x12, 0x34, 0x56]);
        assert_eq!(b.to_bytes_be(), vec![0x12, 0x34, 0x56]); // leading zeros dropped
    }
}

#[cfg(test)]
mod cipher_tests {
    use super::*;

    #[test]
    fn chacha20_rfc7539_block_vector() {
        // RFC 7539 section 2.4.2: key 00..1f, nonce 00:00:00:00:00:00:00:4a:00:00:00:00, counter 1
        let mut key = [0u8; 32];
        for (i, k) in key.iter_mut().enumerate() {
            *k = i as u8;
        }
        let nonce = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0];
        let mut c = ChaCha20::new(&key, Nonce::Ietf(nonce, 1));
        let plain = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let out = c.transform(plain);
        assert_eq!(&out[..8], &[0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80]);
    }

    #[test]
    fn chacha_roundtrips_and_the_wrapper_matches() {
        let session = b"some session key bytes";
        let iv16 = [7u8; 16];
        let mut a = Rc4::chacha(session, &iv16);
        let mut b = Rc4::chacha(session, &iv16);
        let msg = b"the quick brown fox jumps over the lazy dog, twice over the block boundary, and then some more bytes to pass 64";
        let enc = a.transform(msg);
        assert_ne!(&enc[..], &msg[..]);
        assert_eq!(b.transform(&enc), msg.to_vec());
        let iv8 = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let mut c = Rc4::chacha64(session, &iv8);
        let mut d = Rc4::chacha64(session, &iv8);
        assert_eq!(d.transform(&c.transform(msg)), msg.to_vec());
    }

    #[test]
    fn legacy_credential_is_the_des_crypt_tail() {
        // crypt("masterkey", "9z") = "9zQP3LMZ/MJh." on a DES-capable libcrypt
        if let Some(c) = legacy_credential("masterkey") {
            assert_eq!(c, "QP3LMZ/MJh.");
        }
    }
}

// ------------------------------------------------- THE REFERENCE BIGNUM ---
// The bignum exactly as it stood before the arithmetic was made fast:
// binary long division (one shift/compare/subtract per BIT), a `sub` that
// allocates a fresh Vec, `mul` through a u64 scratch vector, and
// square-and-multiply calling `rem` after every step. It is kept, verbatim
// and compiled only for tests, as the ORACLE the fast version is fuzzed
// against - because on the authentication path a modular exponentiation
// that is subtly wrong does not fail loudly. It fails for one user in
// sixteen, and it looks like a password problem.
#[cfg(test)]
pub(crate) mod slow {
    /// base-2^32 limbs, least significant first, no trailing zeros
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Slow {
        pub limbs: Vec<u32>,
    }

    impl Slow {
        pub fn zero() -> Self {
            Slow { limbs: vec![] }
        }
        pub fn from_limbs(l: &[u32]) -> Self {
            let mut r = Slow { limbs: l.to_vec() };
            r.trim();
            r
        }
        pub fn from_bytes_be(b: &[u8]) -> Self {
            let mut limbs = Vec::new();
            let mut i = b.len();
            while i > 0 {
                let lo = i.saturating_sub(4);
                let mut v = 0u32;
                for &byte in &b[lo..i] {
                    v = (v << 8) | byte as u32;
                }
                limbs.push(v);
                i = lo;
            }
            let mut r = Slow { limbs };
            r.trim();
            r
        }
        pub fn to_bytes_be(&self) -> Vec<u8> {
            if self.limbs.is_empty() {
                return vec![];
            }
            let mut out = Vec::with_capacity(self.limbs.len() * 4);
            for &limb in self.limbs.iter().rev() {
                out.extend_from_slice(&limb.to_be_bytes());
            }
            let first = out.iter().position(|&b| b != 0).unwrap_or(out.len());
            out[first..].to_vec()
        }
        fn trim(&mut self) {
            while self.limbs.last() == Some(&0) {
                self.limbs.pop();
            }
        }
        fn is_zero(&self) -> bool {
            self.limbs.is_empty()
        }
        fn bit(&self, i: usize) -> bool {
            self.limbs
                .get(i / 32)
                .map(|l| (l >> (i % 32)) & 1 == 1)
                .unwrap_or(false)
        }
        fn bits(&self) -> usize {
            match self.limbs.last() {
                None => 0,
                Some(&top) => (self.limbs.len() - 1) * 32 + (32 - top.leading_zeros() as usize),
            }
        }
        pub fn cmp(&self, other: &Self) -> std::cmp::Ordering {
            use std::cmp::Ordering::*;
            if self.limbs.len() != other.limbs.len() {
                return self.limbs.len().cmp(&other.limbs.len());
            }
            for i in (0..self.limbs.len()).rev() {
                match self.limbs[i].cmp(&other.limbs[i]) {
                    Equal => continue,
                    o => return o,
                }
            }
            Equal
        }
        fn shl1(&self) -> Self {
            let mut out = Vec::with_capacity(self.limbs.len() + 1);
            let mut carry = 0u32;
            for &l in &self.limbs {
                out.push((l << 1) | carry);
                carry = l >> 31;
            }
            if carry != 0 {
                out.push(carry);
            }
            let mut r = Slow { limbs: out };
            r.trim();
            r
        }
        fn set_bit0(&mut self) {
            if self.limbs.is_empty() {
                self.limbs.push(1);
            } else {
                self.limbs[0] |= 1;
            }
        }
        pub fn sub(&self, other: &Self) -> Self {
            let mut out = Vec::with_capacity(self.limbs.len());
            let mut borrow = 0i64;
            for i in 0..self.limbs.len() {
                let o = *other.limbs.get(i).unwrap_or(&0) as i64;
                let mut d = self.limbs[i] as i64 - o - borrow;
                if d < 0 {
                    d += 1 << 32;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                out.push(d as u32);
            }
            let mut r = Slow { limbs: out };
            r.trim();
            r
        }
        pub fn add(&self, other: &Self) -> Self {
            let n = self.limbs.len().max(other.limbs.len()) + 1;
            let mut out = vec![0u32; n];
            let mut carry = 0u64;
            for (i, o) in out.iter_mut().enumerate() {
                let s = *self.limbs.get(i).unwrap_or(&0) as u64
                    + *other.limbs.get(i).unwrap_or(&0) as u64
                    + carry;
                *o = (s & 0xffff_ffff) as u32;
                carry = s >> 32;
            }
            let mut r = Slow { limbs: out };
            r.trim();
            r
        }
        pub fn mul(&self, other: &Self) -> Self {
            if self.is_zero() || other.is_zero() {
                return Slow::zero();
            }
            let mut out = vec![0u64; self.limbs.len() + other.limbs.len()];
            for (i, &a) in self.limbs.iter().enumerate() {
                let mut carry = 0u64;
                for (j, &b) in other.limbs.iter().enumerate() {
                    let cur = out[i + j] + a as u64 * b as u64 + carry;
                    out[i + j] = cur & 0xffff_ffff;
                    carry = cur >> 32;
                }
                out[i + other.limbs.len()] += carry;
            }
            let mut r = Slow {
                limbs: out.into_iter().map(|v| v as u32).collect(),
            };
            r.trim();
            r
        }
        /// self mod m, by binary long division (shift-and-subtract)
        pub fn rem(&self, m: &Self) -> Self {
            if self.cmp(m) == std::cmp::Ordering::Less {
                return self.clone();
            }
            let mut r = Slow::zero();
            for i in (0..self.bits()).rev() {
                r = r.shl1();
                if self.bit(i) {
                    r.set_bit0();
                }
                if r.cmp(m) != std::cmp::Ordering::Less {
                    r = r.sub(m);
                }
            }
            r
        }
        pub fn modpow(base: &Self, exp: &Self, m: &Self) -> Self {
            let mut result = Slow::from_bytes_be(&[1]).rem(m);
            let mut b = base.rem(m);
            for i in 0..exp.bits() {
                if exp.bit(i) {
                    result = result.mul(&b).rem(m);
                }
                b = b.mul(&b).rem(m);
            }
            result
        }
        pub fn add_mod(&self, other: &Self, m: &Self) -> Self {
            self.add(other).rem(m)
        }
        pub fn sub_mod(&self, other: &Self, m: &Self) -> Self {
            let a = self.rem(m);
            let b = other.rem(m);
            if a.cmp(&b) != std::cmp::Ordering::Less {
                a.sub(&b)
            } else {
                a.add(m).sub(&b)
            }
        }
        pub fn mul_mod(&self, other: &Self, m: &Self) -> Self {
            self.mul(other).rem(m)
        }
    }
}

#[cfg(test)]
mod diff_fuzz {
    //! The differential fuzz that makes the rewrite safe: every operation
    //! of the fast bignum against the slow one it replaced, over random
    //! operands AND over the edges an authentication path actually meets -
    //! the SRP prime as modulus, values at and just under and just over
    //! the modulus, zero, one, powers of two on every limb boundary,
    //! full-width operands, and limbs chosen to force carry and borrow
    //! chains the whole length of the number.
    //!
    //! Bit for bit: each comparison is on the minimal big-endian encoding
    //! - the form all of these numbers take on the wire - AND on the limb
    //! vector, so a result that merely prints the same (a stray trailing
    //! zero limb, say) cannot pass.
    //!
    //! `FC_FUZZ_CASES=n` sets the random case count (default 20 000; the
    //! oracle is the implementation being replaced for being slow, so it
    //! sets the price).
    //!
    //! One shape is deliberately NOT fuzzed: `modpow` with a ZERO
    //! modulus. `rem` by zero reduces nothing in either implementation, so
    //! the running square doubles in WIDTH every iteration - a 33-bit
    //! exponent asks for a number of eight billion bits. It is not a
    //! disagreement, it is an unbounded computation, and no caller makes
    //! it: every modpow on this path passes the SRP prime. Zero moduli are
    //! fuzzed everywhere else, and against modpow with exponents small
    //! enough for the oracle to finish.
    use super::slow::Slow;
    use super::BigUint;

    /// The 1024-bit SRP group prime (srp.cpp), the modulus every
    /// exponentiation on the authentication path actually uses.
    const N_HEX: &str = concat!(
        "E67D2E994B2F900C3F41F08F5BB2627ED0D49EE1FE767A52EFCD565CD6E76881",
        "2C3E1E9CE8F0A8BEA6CB13CD29DDEBF7A96D4A93B55D488DF099A15C89DCB064",
        "0738EB2CBDD9A8F7BAB561AB1B0DC1C6CDABF303264A08D1BCA932D1F1EE428B",
        "619D970F342ABA9A65793B8B2F041AE5364350C16F735F56ECBCA87BD57B29E7"
    );

    /// xorshift64*, so any failing case is reproducible from its seed
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            self.0 = x;
            x.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }
        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
        /// a limb biased towards the values that break carry chains
        fn limb(&mut self) -> u32 {
            let r = self.next();
            match r % 8 {
                0 => 0,
                1 => 0xffff_ffff,
                2 => 1,
                3 => 0x8000_0000,
                4 => 0x7fff_ffff,
                _ => (r >> 8) as u32,
            }
        }
    }

    fn hex_bytes(h: &str) -> Vec<u8> {
        (0..h.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap())
            .collect()
    }

    fn n_limbs() -> Vec<u32> {
        BigUint::from_bytes_be(&hex_bytes(N_HEX))
            .limbs_for_test()
            .to_vec()
    }

    fn pair(l: &[u32]) -> (BigUint, Slow) {
        (BigUint::from_limbs_for_test(l), Slow::from_limbs(l))
    }

    fn same(fast: &BigUint, slow: &Slow, what: &str) {
        assert_eq!(
            fast.to_bytes_be(),
            slow.to_bytes_be(),
            "{}: fast {:?} slow {:?}",
            what,
            fast.limbs_for_test(),
            slow.limbs,
        );
        assert_eq!(
            fast.limbs_for_test(),
            &slow.limbs[..],
            "{}: limb vectors differ (normalisation)",
            what
        );
    }

    /// Values of a few limbs: zero, one, the limb boundaries, all-ones,
    /// the high bit alone and beside it. Cheap enough to take every
    /// ordered pair.
    fn small_corpus() -> Vec<Vec<u32>> {
        vec![
            vec![],
            vec![1],
            vec![2],
            vec![3],
            vec![0x7fff_ffff],
            vec![0x8000_0000],
            vec![0x8000_0001],
            vec![0xffff_ffff],
            vec![0, 1],
            vec![1, 1],
            vec![0xffff_ffff, 1],
            vec![0, 0x8000_0000],
            vec![0xffff_ffff, 0xffff_ffff],
            vec![0, 0, 1],
            vec![1, 0, 1],
            vec![0xffff_ffff, 0, 1],
            vec![0xffff_ffff, 0xffff_ffff, 0xffff_ffff],
            vec![0, 0, 0, 1],
            vec![0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff],
            vec![2, 0, 0, 0x8000_0000],
        ]
    }

    /// The SRP-sized values: the prime, its neighbours and multiples, its
    /// square (the width a product being reduced actually has), and the
    /// powers of two and all-ones at 512, 1024 and 2048 bits.
    fn big_corpus() -> Vec<Vec<u32>> {
        let n = n_limbs();
        let s = Slow::from_limbs(&n);
        let one = Slow::from_limbs(&[1]);
        let mut v = vec![
            n.clone(),
            s.sub(&one).limbs,
            s.add(&one).limbs,
            s.add(&s).limbs,
            s.add(&s).sub(&one).limbs,
            s.mul(&s).limbs,
            s.mul(&s).sub(&one).limbs,
        ];
        for w in [5usize, 16, 32, 33, 64] {
            let mut p = vec![0u32; w];
            p[w - 1] = 0x8000_0000; // 2^(32w-1)
            v.push(p.clone());
            p[w - 1] = 1; // 2^(32(w-1))
            v.push(p);
            v.push(vec![0xffff_ffff; w]); // 2^32w - 1
        }
        v
    }

    /// The moduli worth checking every value against: the SRP prime, one
    /// and zero (both degenerate, both reached by real code paths), and a
    /// small odd and a small even one - odd and even because the fast
    /// modpow reduces oddly-modulused exponentiation in the Montgomery
    /// domain and even ones the plain way.
    fn moduli() -> Vec<Vec<u32>> {
        vec![
            n_limbs(),
            vec![],
            vec![1],
            vec![0xffff_ffff, 3],
            vec![0xffff_fffe, 3],
            vec![0xffff_ffff],
            vec![0xffff_fffe],
        ]
    }

    fn check_all(a_l: &[u32], b_l: &[u32], m_l: &[u32], what: &str) {
        let (a, sa) = pair(a_l);
        let (b, sb) = pair(b_l);
        let (m, sm) = pair(m_l);

        same(&a.mul(&b), &sa.mul(&sb), &format!("{} mul", what));
        same(&a.add(&b), &sa.add(&sb), &format!("{} add", what));
        same(&a.rem(&m), &sa.rem(&sm), &format!("{} rem", what));
        same(&b.rem(&m), &sb.rem(&sm), &format!("{} rem b", what));
        // sub is defined for self >= other in both versions; feed it the
        // ordered pair
        let (hi, lo, shi, slo) = if a.cmp(&b) != std::cmp::Ordering::Less {
            (&a, &b, &sa, &sb)
        } else {
            (&b, &a, &sb, &sa)
        };
        same(&hi.sub(lo), &shi.sub(slo), &format!("{} sub", what));
        same(
            &a.add_mod(&b, &m),
            &sa.add_mod(&sb, &sm),
            &format!("{} add_mod", what),
        );
        same(
            &a.sub_mod(&b, &m),
            &sa.sub_mod(&sb, &sm),
            &format!("{} sub_mod", what),
        );
        same(
            &a.mul_mod(&b, &m),
            &sa.mul_mod(&sb, &sm),
            &format!("{} mul_mod", what),
        );
    }

    fn check_modpow(a_l: &[u32], e_l: &[u32], m_l: &[u32], what: &str) {
        let (a, sa) = pair(a_l);
        let (e, se) = pair(e_l);
        let (m, sm) = pair(m_l);
        same(
            &BigUint::modpow(&a, &e, &m),
            &Slow::modpow(&sa, &se, &sm),
            &format!("{} modpow", what),
        );
    }

    fn cases() -> usize {
        std::env::var("FC_FUZZ_CASES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(20_000)
    }

    /// mul, add, sub, rem, add_mod, sub_mod and mul_mod: every ordered
    /// pair of the small corpus, every big value against a spread of
    /// partners and moduli, then random widths and carry-hostile limbs.
    #[test]
    /// THE QUOTIENT-ESTIMATE EDGES OF KNUTH D, SWEPT EXHAUSTIVELY OVER A
    /// SMALL ALPHABET rather than sampled randomly.
    ///
    /// A reviewer mutation-tested the random fuzz by deleting the
    /// `qhat >= B ||` term from `rem`'s correction loop and found the
    /// mutant SURVIVED a million random cases - the shape that reaches
    /// it needs a dividend limb exactly equal to the divisor's top limb
    /// after normalisation, which uniform random operands essentially
    /// never produce. Random operands are the wrong instrument for a
    /// branch whose trigger is an equality.
    ///
    /// So this walks every combination of limbs drawn from the values
    /// that sit on the estimate's boundaries - 0, 1, `B/2 - 1`, `B/2`
    /// and `B - 1` - along with the maximal borrow and carry chains,
    /// checking every result against the same slow oracle the random
    /// fuzz uses.
    ///
    /// WHAT IT DOES NOT REACH, stated plainly because the point of this
    /// test is honesty about coverage: the `qhat >= B` term is STILL not
    /// exercised. Deleting it leaves this sweep green too. The trigger
    /// is `u[j + n] == v[n - 1]` after normalisation, and at the first
    /// step that limb is the extension word - zero whenever the divisor
    /// is already normalised - so it can only arise from a PARTIAL
    /// REMAINDER mid-division, which no corpus here constructs. A
    /// reviewer's counters over 200 real handshakes agree: the branch is
    /// taken zero times in production.
    ///
    /// The term nevertheless stays, and not merely because Knuth prints
    /// it. Algorithm D bounds `qhat` at `B + 1` before correction;
    /// without this term a `qhat` of `B` or `B + 1` survives into
    /// `qhat * v[i] as u64 + carry`, and `(B + 1)(B - 1)` is already
    /// `u64::MAX`, so the carry overflows it - wrapping silently in
    /// release and panicking in debug. It guards the arithmetic, not
    /// just the digit.
    #[test]
    fn sweep_the_division_estimate_edges() {
        const EDGE: [u32; 5] = [0, 1, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff];
        let tuples = |n: usize| -> Vec<Vec<u32>> {
            let mut out = vec![Vec::new()];
            for _ in 0..n {
                let mut next = Vec::with_capacity(out.len() * EDGE.len());
                for t in &out {
                    for e in EDGE {
                        let mut v = t.clone();
                        v.push(e);
                        next.push(v);
                    }
                }
                out = next;
            }
            out
        };
        let mut checked = 0usize;
        for divisor in tuples(2).into_iter().chain(tuples(3)) {
            // a zero divisor reduces nothing in either version (see the
            // module note); the oracle agrees, but it is not a division
            if divisor.iter().all(|&l| l == 0) {
                continue;
            }
            let (m, sm) = pair(&divisor);
            for dividend in tuples(3).into_iter().chain(tuples(4)) {
                let (a, sa) = pair(&dividend);
                same(&a.rem(&m), &sa.rem(&sm), "estimate-edge rem");
                checked += 1;
            }
        }
        // the sweep is only worth its runtime if it is actually large
        assert!(checked > 100_000, "swept only {} pairs", checked);
    }

    fn fuzz_the_operations() {
        let small = small_corpus();
        for (i, a) in small.iter().enumerate() {
            for (j, b) in small.iter().enumerate() {
                // a rotating modulus from the corpus itself, and then
                // every listed modulus - the SRP prime included, which is
                // the one real code uses
                check_all(a, b, &small[(i + j + 1) % small.len()], "small");
                for m in moduli() {
                    check_all(a, b, &m, "small/moduli");
                }
            }
        }

        let big = big_corpus();
        let partners: Vec<Vec<u32>> = vec![
            vec![1],
            vec![2],
            Slow::from_limbs(&n_limbs()).sub(&Slow::from_limbs(&[1])).limbs,
            vec![0xffff_ffff; 32],
        ];
        for (i, a) in big.iter().enumerate() {
            for b in &partners {
                for m in moduli() {
                    check_all(a, b, &m, &format!("big[{}]", i));
                }
            }
            // and big against big, with the prime as the modulus: the
            // 2048-bit product reduced by a 1024-bit modulus is exactly
            // what modpow's inner loop does
            for b in &big {
                check_all(a, b, &n_limbs(), &format!("bigxbig[{}]", i));
            }
        }

        let mut rng = Rng(0x5EED_1234_ABCD_0001);
        for _ in 0..cases() {
            let wa = 1 + rng.below(40);
            let wb = 1 + rng.below(40);
            let wm = 1 + rng.below(36);
            let a: Vec<u32> = (0..wa).map(|_| rng.limb()).collect();
            let b: Vec<u32> = (0..wb).map(|_| rng.limb()).collect();
            let mut m: Vec<u32> = (0..wm).map(|_| rng.limb()).collect();
            // half the time force an ODD modulus - the Montgomery path
            if rng.next() & 1 == 0 {
                m[0] |= 1;
            }
            check_all(&a, &b, &m, "random");
        }
    }

    /// modpow, whose cost is why any of this changed: the exhaustive
    /// small edges, the two exponent widths the handshake really uses
    /// against the SRP prime, and random exponents against odd and even
    /// moduli.
    #[test]
    fn fuzz_modpow() {
        let n = n_limbs();
        let small = small_corpus();
        let exps: Vec<Vec<u32>> = vec![
            vec![],
            vec![1],
            vec![2],
            vec![3],
            vec![13],
            vec![0xffff_ffff],
            vec![0, 1],
        ];
        // every small base, every small exponent, every nonzero modulus
        for a in &small {
            for e in &exps {
                for m in moduli() {
                    if m.is_empty() {
                        continue; // see the note at the top of the module
                    }
                    check_modpow(a, e, &m, "small");
                }
            }
        }
        // the zero modulus, with exponents small enough that the doubling
        // width stays finite (the oracle reduces nothing there)
        for a in [vec![], vec![1u32], vec![2], vec![0xffff_ffff], vec![7, 9]] {
            for e in [vec![], vec![1u32], vec![2], vec![3], vec![7]] {
                check_modpow(&a, &e, &[], "zero-modulus");
            }
        }
        // SRP scale: every big value as a base, with a 160-bit exponent
        // (x and u are SHA-1 outputs) and a 1024-bit one (a and b are
        // full-width private keys), against the prime
        let e160: Vec<u32> = vec![0xdead_beef, 0x1234_5678, 0x9abc_def0, 0x0f1e_2d3c, 0x5a5a_5a5a];
        for (i, a) in big_corpus().iter().enumerate() {
            check_modpow(a, &e160, &n, &format!("big[{}] 160-bit exp", i));
            check_modpow(a, &n, &n, &format!("big[{}] 1024-bit exp", i));
        }

        let mut rng = Rng(0xC0FF_EE00_1234_5678);
        // one 1024-bit exponentiation costs the ORACLE about 110 ms, so
        // modpow gets a five-hundredth of the case count
        let count = (cases() / 500).max(40);
        for i in 0..count {
            let base: Vec<u32> = (0..1 + rng.below(40)).map(|_| rng.limb()).collect();
            if i % 2 == 0 {
                // the handshake's own shapes, against the prime
                let w = if i % 4 == 0 { 5 } else { 32 };
                let e: Vec<u32> = (0..w).map(|_| rng.limb()).collect();
                check_modpow(&base, &e, &n, "random srp-shaped");
            } else {
                let mut m: Vec<u32> = (0..1 + rng.below(6)).map(|_| rng.limb()).collect();
                if rng.next() & 1 == 0 {
                    m[0] |= 1; // odd: the Montgomery path
                } else {
                    m[0] &= !1; // even: the plain path
                }
                if Slow::from_limbs(&m).limbs.is_empty() {
                    m = vec![2]; // never zero: see the note above
                }
                let e: Vec<u32> = (0..1 + rng.below(4)).map(|_| rng.limb()).collect();
                check_modpow(&base, &e, &m, "random small-modulus");
            }
        }
    }
}
