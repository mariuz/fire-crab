//! SRP-6a client for the Srp256 plugin, converted from
//! `src/auth/SecureRemotePassword/srp.cpp`. The exchange authenticates
//! without the password ever crossing the wire: the client presents
//! A = g^a mod N, the server replies with a salt and B, and both sides
//! derive the same session key K from the shared secret S - which an
//! eavesdropper cannot compute. The proof M then convinces the server
//! the client knew the password.
//!
//! Firebird's SRP deviates from RFC 2945/5054 in specific ways (marked
//! below); this converts the engine's actual computation, cross-checked
//! against the paper's from-scratch reference
//! (samples/nodejs/srp-handshake.js) and, ultimately, by the live
//! server accepting the proof.

use crate::crypto::{sha1, sha256, BigUint};

/// The fixed 1024-bit group (srp.cpp): Tom Wu's demo prime, g = 2.
const N_HEX: &str = concat!(
    "E67D2E994B2F900C3F41F08F5BB2627ED0D49EE1FE767A52EFCD565CD6E76881",
    "2C3E1E9CE8F0A8BEA6CB13CD29DDEBF7A96D4A93B55D488DF099A15C89DCB064",
    "0738EB2CBDD9A8F7BAB561AB1B0DC1C6CDABF303264A08D1BCA932D1F1EE428B",
    "619D970F342ABA9A65793B8B2F041AE5364350C16F735F56ECBCA87BD57B29E7"
);

fn n() -> BigUint {
    BigUint::from_bytes_be(&hex_to_bytes(N_HEX))
}
fn g() -> BigUint {
    BigUint::from_bytes_be(&[2])
}

pub fn hex_to_bytes(h: &str) -> Vec<u8> {
    let h = if h.len() % 2 == 1 {
        format!("0{}", h)
    } else {
        h.to_string()
    };
    (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap_or(0))
        .collect()
}

pub fn bytes_to_hex_upper(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02X}", x)).collect()
}

/// The result of the client computation.
pub struct SrpClient {
    /// client public key A = g^a mod N, as uppercase hex (wire form)
    pub a_hex: String,
    a_priv: BigUint,
    a_pub: BigUint,
}

/// Start the client side: pick a private key `a` (128 bytes), compute
/// A = g^a mod N. `a_bytes` is the caller's randomness.
pub fn client_start(a_bytes: &[u8]) -> SrpClient {
    let a_priv = BigUint::from_bytes_be(a_bytes).rem_pub(&n());
    let a_pub = BigUint::modpow(&g(), &a_priv, &n());
    SrpClient {
        a_hex: bytes_to_hex_upper(&a_pub.to_bytes_be()),
        a_priv,
        a_pub,
    }
}

/// Everything the proof step derives.
pub struct SrpProof {
    /// M, the client proof (SHA-256 for Srp256), as uppercase hex
    pub m_hex: String,
    /// K, the session key = SHA1(S) - the wire-encryption key (20 bytes,
    /// SHA-1 even in Srp256)
    pub session_key: [u8; 20],
}

impl SrpClient {
    /// Compute the proof and session key from the server's `salt` and
    /// public key `b` (as received on the wire), for `user`/`password`.
    pub fn proof(&self, user: &str, password: &str, salt: &[u8], b_hex: &str) -> SrpProof {
        let modulus = n();
        let gg = g();
        let big_b = BigUint::from_bytes_be(&hex_to_bytes(b_hex));

        // k = SHA1(N | PAD(g)) with g zero-padded to |N| = 128 bytes
        let mut padded_g = vec![0u8; 128 - 1];
        padded_g.push(2);
        let mut k_in = modulus.to_bytes_be();
        k_in.extend_from_slice(&padded_g);
        let k = BigUint::from_bytes_be(&sha1(&k_in));

        // u = SHA1(A | B) over MINIMAL bytes (DEVIATION: RFC pads)
        let mut u_in = self.a_pub.to_bytes_be();
        u_in.extend_from_slice(&big_b.to_bytes_be());
        let u = BigUint::from_bytes_be(&sha1(&u_in));

        // x = SHA1(salt | SHA1(user ':' password))
        let inner = sha1(format!("{}:{}", user, password).as_bytes());
        let mut x_in = salt.to_vec();
        x_in.extend_from_slice(&inner);
        let x = BigUint::from_bytes_be(&sha1(&x_in));

        // S = (B - k * g^x) ^ (a + u*x) mod N
        let gx = BigUint::modpow(&gg, &x, &modulus);
        let kgx = k.mul_mod(&gx, &modulus);
        let base = big_b.sub_mod(&kgx, &modulus);
        let exp = self.a_priv.add_mod(&u.mul_mod(&x, &modulus), &modulus);
        let s = BigUint::modpow(&base, &exp, &modulus);

        // K = SHA1(S) - always SHA-1
        let session_key = sha1(&s.to_bytes_be());

        // M = SHA256(n1 | n2 | salt | A | B | K), with
        //   n1 = SHA1(N) ^ SHA1(g)  computed as modPow (DEVIATION)
        //   n2 = SHA1(user)
        let h_n = BigUint::from_bytes_be(&sha1(&modulus.to_bytes_be()));
        let h_g = BigUint::from_bytes_be(&sha1(&gg.to_bytes_be()));
        let n1 = BigUint::modpow(&h_n, &h_g, &modulus);
        let n2 = BigUint::from_bytes_be(&sha1(user.as_bytes()));

        let mut m_in = n1.to_bytes_be();
        m_in.extend_from_slice(&n2.to_bytes_be());
        m_in.extend_from_slice(salt);
        m_in.extend_from_slice(&self.a_pub.to_bytes_be());
        m_in.extend_from_slice(&big_b.to_bytes_be());
        m_in.extend_from_slice(&session_key);
        let m = sha256(&m_in);

        SrpProof {
            m_hex: bytes_to_hex_upper(&m),
            session_key,
        }
    }
}

// small helper: BigUint::rem is private; expose a public reduce
impl BigUint {
    pub fn rem_pub(&self, m: &BigUint) -> BigUint {
        // reduce via add_mod with zero (add_mod ends in rem)
        self.add_mod(&BigUint::zero(), m)
    }
}


// ---- server side (converts the verifier + proof-check half of srp.cpp) ----

/// The shared parameters a server needs to compute for a user: the salt,
/// the verifier v = g^x mod N (x = SHA1(salt | SHA1(user:pass))), and the
/// group. In a real server the (salt, v) pair is what RDB$AUTH stores;
/// here it is derived on the fly for the demo user.
pub struct SrpVerifier {
    pub salt: Vec<u8>,
    v: BigUint,
    user: String,
}

fn k_param() -> BigUint {
    let modulus = n();
    let mut padded_g = vec![0u8; 128 - 1];
    padded_g.push(2);
    let mut k_in = modulus.to_bytes_be();
    k_in.extend_from_slice(&padded_g);
    BigUint::from_bytes_be(&sha1(&k_in))
}

fn compute_x(user: &str, password: &str, salt: &[u8]) -> BigUint {
    let inner = sha1(format!("{}:{}", user, password).as_bytes());
    let mut x_in = salt.to_vec();
    x_in.extend_from_slice(&inner);
    BigUint::from_bytes_be(&sha1(&x_in))
}

impl SrpVerifier {
    /// Build the verifier for `user`/`password` with the given salt
    /// (32 bytes of printable randomness, as Firebird stores).
    pub fn new(user: &str, password: &str, salt: &[u8]) -> SrpVerifier {
        let x = compute_x(user, password, salt);
        let v = BigUint::modpow(&g(), &x, &n());
        SrpVerifier {
            salt: salt.to_vec(),
            v,
            user: user.to_string(),
        }
    }

    /// Server ephemeral: pick private b, return (b_priv, B) where
    /// B = (k*v + g^b) mod N - the value sent to the client as hex.
    pub fn server_public(&self, b_bytes: &[u8]) -> (BigUint, String) {
        let modulus = n();
        let b_priv = BigUint::from_bytes_be(b_bytes).rem_pub(&modulus);
        let gb = BigUint::modpow(&g(), &b_priv, &modulus);
        let kv = k_param().mul_mod(&self.v, &modulus);
        let big_b = kv.add_mod(&gb, &modulus);
        (b_priv, bytes_to_hex_upper(&big_b.to_bytes_be()))
    }

    /// Verify the client's proof M given the client public key A (hex),
    /// the server private b and public B (hex). Returns the session key
    /// K on success, None if the proof does not match.
    pub fn verify(
        &self,
        a_hex: &str,
        b_priv: &BigUint,
        b_hex: &str,
        client_m_hex: &str,
    ) -> Option<[u8; 20]> {
        let modulus = n();
        let big_a = BigUint::from_bytes_be(&hex_to_bytes(a_hex));
        let big_b = BigUint::from_bytes_be(&hex_to_bytes(b_hex));

        // u = SHA1(A | B), minimal bytes
        let mut u_in = big_a.to_bytes_be();
        u_in.extend_from_slice(&big_b.to_bytes_be());
        let u = BigUint::from_bytes_be(&sha1(&u_in));

        // S = (A * v^u)^b mod N
        let vu = BigUint::modpow(&self.v, &u, &modulus);
        let base = big_a.mul_mod(&vu, &modulus);
        let s = BigUint::modpow(&base, b_priv, &modulus);
        let session_key = sha1(&s.to_bytes_be());

        // expected M = SHA256(n1 | n2 | salt | A | B | K)
        let gg = g();
        let h_n = BigUint::from_bytes_be(&sha1(&modulus.to_bytes_be()));
        let h_g = BigUint::from_bytes_be(&sha1(&gg.to_bytes_be()));
        let n1 = BigUint::modpow(&h_n, &h_g, &modulus);
        let n2 = BigUint::from_bytes_be(&sha1(self.user.as_bytes()));
        let mut m_in = n1.to_bytes_be();
        m_in.extend_from_slice(&n2.to_bytes_be());
        m_in.extend_from_slice(&self.salt);
        m_in.extend_from_slice(&big_a.to_bytes_be());
        m_in.extend_from_slice(&big_b.to_bytes_be());
        m_in.extend_from_slice(&session_key);
        let expected = bytes_to_hex_upper(&sha256(&m_in));

        if expected == client_m_hex.to_uppercase() {
            Some(session_key)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_node_reference_fixed_inputs() {
        // same fixed a/salt/B as scratch/srp_ref.js
        let a = [7u8; 128];
        let c = client_start(&a);
        assert_eq!(c.a_hex, "0FFFDFCC41ADB7A7646831B3DB71B531020F5B00017AD60623CBF0CC64832442F84FA78267154169E1F5DFB18323F41AD54FD442C6581AA23A4D190A815F5BA6236C943AB198F265B2CB72E673E05838CD50172E99FAA09C44842C86BA36F3DDFD5507F9985F2497DD7BD28BBC137C44EB2425B8073D9E8AEBAD5CA2F83038D3", "A");
        let salt = hex_to_bytes("46323038423239394336363543323635444435413239443145433831374644393231334246343345384446334241324535453244313436463845303134353757");
        let b_hex = "1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF";
        let pr = c.proof("SYSDBA", "masterkey", &salt, b_hex);
        assert_eq!(
            pr.m_hex, "C2A9B2BC58EDC171B41142A9FC93ABF7F01596D815F36780F2751B1D8C8EEE8D",
            "M"
        );
    }

    #[test]
    fn client_and_server_agree_on_the_session_key() {
        // full SRP loopback: the client proof the server computes for
        // itself must equal the client's, and both must derive the same K
        let salt = [0x5Au8; 32];
        let verifier = SrpVerifier::new("SYSDBA", "masterkey", &salt);
        let client = client_start(&[7u8; 128]);
        let (b_priv, b_hex) = verifier.server_public(&[9u8; 128]);
        let proof = client.proof("SYSDBA", "masterkey", &salt, &b_hex);
        let k = verifier
            .verify(&client.a_hex, &b_priv, &b_hex, &proof.m_hex)
            .expect("server must accept the client proof");
        assert_eq!(k, proof.session_key, "session keys must match");
        // a wrong password must be rejected
        let bad = client.proof("SYSDBA", "wrong", &salt, &b_hex);
        assert!(verifier.verify(&client.a_hex, &b_priv, &b_hex, &bad.m_hex).is_none());
    }

    #[test]
    fn n_parses_to_1024_bits() {
        let modulus = n();
        assert_eq!(modulus.to_bytes_be().len(), 128); // 1024 bits
    }

    #[test]
    fn client_public_key_is_deterministic() {
        // fixed private key -> fixed A (regression guard for the modpow)
        let a = [7u8; 128];
        let c1 = client_start(&a);
        let c2 = client_start(&a);
        assert_eq!(c1.a_hex, c2.a_hex);
        assert!(!c1.a_hex.is_empty());
    }
}
