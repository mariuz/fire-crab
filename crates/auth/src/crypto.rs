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
        let mut r = BigUint { limbs: out };
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
    fn mul(&self, other: &Self) -> Self {
        if self.is_zero() || other.is_zero() {
            return BigUint::zero();
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
        let mut r = BigUint {
            limbs: out.into_iter().map(|v| v as u32).collect(),
        };
        r.trim();
        r
    }
    /// self mod m, by binary long division (shift-and-subtract).
    fn rem(&self, m: &Self) -> Self {
        if self.cmp(m) == std::cmp::Ordering::Less {
            return self.clone();
        }
        let mut r = BigUint::zero();
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
    /// base^exp mod m (square-and-multiply).
    pub fn modpow(base: &Self, exp: &Self, m: &Self) -> Self {
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

// ----------------------------------------------------------------- RC4 -----
// Arc4, byte-for-byte the engine's Cypher (src/plugins/crypt/arc4/Arc4.cpp).

pub struct Rc4 {
    s: [u8; 256],
    i: u8,
    j: u8,
}

impl Rc4 {
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
        Rc4 { s, i: 0, j: 0 }
    }
    pub fn transform(&mut self, buf: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(buf.len());
        for &byte in buf {
            self.i = self.i.wrapping_add(1);
            self.j = self.j.wrapping_add(self.s[self.i as usize]);
            self.s.swap(self.i as usize, self.j as usize);
            let k =
                self.s[(self.s[self.i as usize].wrapping_add(self.s[self.j as usize])) as usize];
            out.push(byte ^ k);
        }
        out
    }
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
