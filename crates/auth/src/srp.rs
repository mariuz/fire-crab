//! SRP-6a for the `Srp256` and `Srp` plugins, converted from
//! `src/auth/SecureRemotePassword/srp.cpp` + `srp.h`, with the server
//! half from `server/SrpServer.cpp` and the verifier half from
//! `manage/SrpManagement.cpp`.
//!
//! The exchange authenticates without the password ever crossing the
//! wire: the client presents A = g^a mod N, the server replies with a
//! salt and B, and both sides derive the same session key K from the
//! shared secret S - which an eavesdropper cannot compute. The proof M
//! then convinces the server the client knew the password.
//!
//! Firebird's SRP deviates from RFC 2945/5054 in four specific ways,
//! catalogued in the crate documentation and marked at each site below.
//! This converts the engine's ACTUAL computation, cross-checked against
//! the paper's from-scratch reference (samples/nodejs/srp-handshake.js),
//! against node-firebird's independent implementation, against the
//! verifiers the engine itself stored for real users, and ultimately by
//! the live server accepting the proof.

use crate::crypto::{sha1, sha256, BigUint};

/// The fixed 1024-bit group (srp.cpp): Tom Wu's demo prime, g = 2.
const N_HEX: &str = concat!(
    "E67D2E994B2F900C3F41F08F5BB2627ED0D49EE1FE767A52EFCD565CD6E76881",
    "2C3E1E9CE8F0A8BEA6CB13CD29DDEBF7A96D4A93B55D488DF099A15C89DCB064",
    "0738EB2CBDD9A8F7BAB561AB1B0DC1C6CDABF303264A08D1BCA932D1F1EE428B",
    "619D970F342ABA9A65793B8B2F041AE5364350C16F735F56ECBCA87BD57B29E7"
);

/// srp.h:106-108 - the group is 1024 bits, so keys and verifiers are 128
/// bytes and the salt is 32.
pub const SRP_KEY_SIZE: usize = 128;
pub const SRP_VERIFIER_SIZE: usize = SRP_KEY_SIZE;
pub const SRP_SALT_SIZE: usize = 32;

fn n() -> BigUint {
    BigUint::from_bytes_be(&hex_to_bytes(N_HEX))
}
fn g() -> BigUint {
    BigUint::from_bytes_be(&[2])
}

/// Which SRP plugin: the two differ ONLY in the hash used for the proof M
/// (`RemotePasswordImpl<SHA>::makeProof`, srp.h:134). Everything else -
/// the scramble u, the user hash x, the session key K - is SHA-1 in both,
/// because those use the `Auth::SecureHash<Firebird::Sha1> hash` member of
/// the base class (srp.h:91). A converter that "upgrades" Srp256 to
/// SHA-256 throughout produces a client that can never log in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Algo {
    /// The original plugin: proof M is SHA-1 (20 bytes).
    Srp,
    /// The default since Firebird 3.0.4: proof M is SHA-256 (32 bytes).
    Srp256,
}

impl Algo {
    /// The name that travels in `cnct_plugin_name` and comes back in
    /// `p_acpt_plugin` (`RemotePassword::pluginName`, srp.cpp).
    pub fn plugin_name(self) -> &'static str {
        match self {
            Algo::Srp => "Srp",
            Algo::Srp256 => "Srp256",
        }
    }

    /// Parse a plugin name as it appears on the wire; unknown names are
    /// refused rather than silently defaulted (a wrong default here is an
    /// authentication failure that looks like a bad password).
    pub fn from_plugin_name(name: &str) -> Option<Algo> {
        match name {
            "Srp" => Some(Algo::Srp),
            "Srp256" => Some(Algo::Srp256),
            _ => None,
        }
    }

    /// The proof hash. `Srp` yields 20 bytes, `Srp256` 32.
    pub fn proof_hash(self, data: &[u8]) -> Vec<u8> {
        match self {
            Algo::Srp => sha1(data).to_vec(),
            Algo::Srp256 => sha256(data).to_vec(),
        }
    }
}

/// Whether the client's proof hex denotes the same NUMBER as `expected`
/// (a fixed-width hash). Leading zeros on either side are insignificant:
/// the client writes minimal hex digits, we hold zero-padded bytes.
pub fn proof_matches(expected: &[u8], client_m_hex: &str) -> bool {
    let got = hex_to_bytes(client_m_hex);
    let trim = |b: &[u8]| -> Vec<u8> {
        let at = b.iter().position(|x| *x != 0).unwrap_or(b.len());
        b[at..].to_vec()
    };
    trim(expected) == trim(&got)
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

/// `BigInteger::getText`: the number's UPPERCASE hex digits with NO
/// leading zero (`mp_to_radix`, BigInteger.cpp). This is the form EVERY
/// number takes when Firebird writes it as text - the salt, the public
/// keys A and B, the proof M - so it is also the wire form, and it is
/// never a fixed width.
///
/// This is the fourth deviation, and the one that bites hardest. The
/// security database stores `PLG$SALT` as 32 raw bytes; the server does
/// NOT send those bytes. `SrpServer.cpp:324-326` reads them, builds a
/// BigInteger and sends `getText` - so the salt arrives as up to 64
/// uppercase hex CHARACTERS, and x is computed over those characters.
/// When the stored salt's first byte is below 0x10 the text is 63
/// characters (one in sixteen users), below 0x01 it is 62, and so on.
///
/// An implementation that zero-pads the salt to 64 characters (or that
/// hashes the raw 32 bytes) authenticates fine against itself and against
/// most users, then fails for one user in sixteen with "your user name
/// and password are not defined" - and the same subtlety decides whether
/// a locally computed verifier equals the one `CREATE USER` stored.
pub fn hex_text(bytes: &[u8]) -> String {
    let hex = bytes_to_hex_upper(bytes);
    let at = hex.find(|c| c != '0').unwrap_or(hex.len());
    if at == hex.len() {
        "0".to_string() // the number zero prints as one digit
    } else {
        hex[at..].to_string()
    }
}

/// The salt as it travels: [`hex_text`] of the stored 32 bytes. Named
/// separately because this is the application that bites - see above.
pub fn salt_text(salt_bytes: &[u8]) -> String {
    hex_text(salt_bytes)
}

/// x = SHA1(salt | SHA1(user ':' password)) - `RemotePassword::getUserHash`
/// (srp.cpp:85-101). `salt` is the salt AS IT TRAVELS: the hex text bytes
/// from [`salt_text`], not the stored binary salt.
pub fn user_hash(user: &str, password: &str, salt: &[u8]) -> BigUint {
    let inner = sha1(format!("{}:{}", user, password).as_bytes());
    let mut x_in = salt.to_vec();
    x_in.extend_from_slice(&inner);
    BigUint::from_bytes_be(&sha1(&x_in))
}

/// v = g^x mod N - `RemotePassword::computeVerifier` (srp.cpp:103), the
/// user manager's half of SRP. This is what `CREATE USER` / `ALTER USER`
/// stores in `plg$srp.plg$srp.PLG$VERIFIER` beside the salt, and what the
/// server later loads INSTEAD of a password (`SrpServer.cpp:320`).
///
/// The returned bytes are `BigInteger::getBytes` form - minimal
/// big-endian, so normally 128 bytes but shorter for the one verifier in
/// 256 whose leading byte is zero, exactly as the engine stores it in a
/// `VARCHAR(128) CHARACTER SET OCTETS` column.
pub fn compute_verifier(user: &str, password: &str, salt: &[u8]) -> Vec<u8> {
    let x = user_hash(user, password, salt);
    BigUint::modpow(&g(), &x, &n()).to_bytes_be()
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
        // getText, not a padded 256 characters: `genClientKey`
        // (srp.cpp:110) writes clientPublicKey.getText(pubkey)
        a_hex: hex_text(&a_pub.to_bytes_be()),
        a_priv,
        a_pub,
    }
}

/// Everything the proof step derives.
pub struct SrpProof {
    /// M, the client proof (SHA-256 for Srp256, SHA-1 for Srp), as
    /// uppercase hex
    pub m_hex: String,
    /// K, the session key = SHA1(S) - the wire-encryption key (20 bytes,
    /// SHA-1 in BOTH plugins)
    pub session_key: [u8; 20],
    /// u = SHA1(A | B), the scramble - exposed so the oracle can compare
    /// intermediate values with other implementations
    pub scramble_hex: String,
    /// x = SHA1(salt | SHA1(user:password)), the user hash
    pub x_hex: String,
    /// S, the shared secret, before hashing to K
    pub secret_hex: String,
}

/// u = SHA1(A | B) over MINIMAL bytes - `computeScramble` (srp.cpp:147).
///
/// DEVIATION 1: the RFC pads A and B to |N|. `processStrippedInt` also
/// drops a leading zero byte if one is present, which for
/// `BigInteger::getBytes` (minimal encoding) can only happen for the
/// value zero - so stripped and unstripped agree here, and minimal bytes
/// are the whole law.
fn scramble(a_pub: &BigUint, b_pub: &BigUint) -> BigUint {
    let mut u_in = a_pub.to_bytes_be();
    u_in.extend_from_slice(&b_pub.to_bytes_be());
    BigUint::from_bytes_be(&sha1(&u_in))
}

/// k = SHA1(N | PAD(g)) with g zero-padded to |N| = 128 bytes - the
/// multiplier of the SRP-6a group (`RemoteGroup`, srp.cpp).
fn k_param() -> BigUint {
    let modulus = n();
    let mut padded_g = vec![0u8; SRP_KEY_SIZE - 1];
    padded_g.push(2);
    let mut k_in = modulus.to_bytes_be();
    k_in.extend_from_slice(&padded_g);
    BigUint::from_bytes_be(&sha1(&k_in))
}

/// M = H(n1 | n2 | salt | A | B | K) - `clientProof` (srp.cpp:197) and
/// `makeProof` (srp.h:137), with
///   n1 = H(N) ^ H(g), computed as modPow (DEVIATION 2)
///   n2 = H(user)
/// and H = the PLUGIN's hash (DEVIATION 3: only here).
fn make_proof(
    algo: Algo,
    user: &str,
    salt: &[u8],
    a_pub: &BigUint,
    b_pub: &BigUint,
    session_key: &[u8; 20],
) -> Vec<u8> {
    let modulus = n();
    let gg = g();
    let h_n = BigUint::from_bytes_be(&sha1(&modulus.to_bytes_be()));
    let h_g = BigUint::from_bytes_be(&sha1(&gg.to_bytes_be()));
    let n1 = BigUint::modpow(&h_n, &h_g, &modulus);
    let n2 = BigUint::from_bytes_be(&sha1(user.as_bytes()));

    let mut m_in = n1.to_bytes_be();
    m_in.extend_from_slice(&n2.to_bytes_be());
    m_in.extend_from_slice(salt);
    m_in.extend_from_slice(&a_pub.to_bytes_be());
    m_in.extend_from_slice(&b_pub.to_bytes_be());
    m_in.extend_from_slice(session_key);
    algo.proof_hash(&m_in)
}

impl SrpClient {
    /// Compute the Srp256 proof and session key from the server's `salt`
    /// and public key `b` (as received on the wire), for
    /// `user`/`password`.
    pub fn proof(&self, user: &str, password: &str, salt: &[u8], b_hex: &str) -> SrpProof {
        self.proof_with(Algo::Srp256, user, password, salt, b_hex)
    }

    /// The same, for either plugin variant.
    pub fn proof_with(
        &self,
        algo: Algo,
        user: &str,
        password: &str,
        salt: &[u8],
        b_hex: &str,
    ) -> SrpProof {
        let modulus = n();
        let gg = g();
        let big_b = BigUint::from_bytes_be(&hex_to_bytes(b_hex));

        let k = k_param();
        let u = scramble(&self.a_pub, &big_b);
        let x = user_hash(user, password, salt);

        // S = (B - k * g^x) ^ (a + u*x) mod N - clientSessionKey
        // (srp.cpp:157)
        let gx = BigUint::modpow(&gg, &x, &modulus);
        let kgx = k.mul_mod(&gx, &modulus);
        let base = big_b.sub_mod(&kgx, &modulus);
        let exp = self.a_priv.add_mod(&u.mul_mod(&x, &modulus), &modulus);
        let s = BigUint::modpow(&base, &exp, &modulus);

        // K = SHA1(S) - always SHA-1 (DEVIATION 3)
        let session_key = sha1(&s.to_bytes_be());
        let m = make_proof(algo, user, salt, &self.a_pub, &big_b, &session_key);

        SrpProof {
            // getText again - which is exactly why the server side has to
            // compare proofs by VALUE (see `verify_with`)
            m_hex: hex_text(&m),
            session_key,
            scramble_hex: hex_text(&u.to_bytes_be()),
            x_hex: hex_text(&x.to_bytes_be()),
            secret_hex: hex_text(&s.to_bytes_be()),
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

// ---- server side (the verifier + proof-check half of srp.cpp) ----

/// What a server needs for a user: the salt AS IT TRAVELS (hex text
/// bytes) and the verifier v = g^x mod N.
///
/// Note which one is authoritative. The engine's server plugin NEVER has
/// the password: `SrpServer.cpp:298-326` loads `PLG$VERIFIER` and
/// `PLG$SALT` from the security database, converts the salt to text, and
/// works from the verifier alone. Use [`SrpVerifier::from_stored`] for
/// that path; [`SrpVerifier::new`] derives the pair from a password, which
/// is what the user manager does at `CREATE USER` time (and what
/// `fcwire serve` does for its single demo account).
pub struct SrpVerifier {
    pub salt: Vec<u8>,
    v: BigUint,
    user: String,
}

impl SrpVerifier {
    /// Build the verifier for `user`/`password` with the given salt (the
    /// hex TEXT bytes - see [`salt_text`]).
    pub fn new(user: &str, password: &str, salt: &[u8]) -> SrpVerifier {
        let x = user_hash(user, password, salt);
        let v = BigUint::modpow(&g(), &x, &n());
        SrpVerifier {
            salt: salt.to_vec(),
            v,
            user: user.to_string(),
        }
    }

    /// The engine's server path: a verifier LOADED from storage, with no
    /// password anywhere. `verifier` is the raw `PLG$VERIFIER` bytes and
    /// `salt` the hex text bytes the server sends.
    pub fn from_stored(user: &str, salt: &[u8], verifier: &[u8]) -> SrpVerifier {
        SrpVerifier {
            salt: salt.to_vec(),
            v: BigUint::from_bytes_be(verifier),
            user: user.to_string(),
        }
    }

    /// The verifier as the security database stores it (minimal
    /// big-endian bytes, `BigInteger::getBytes`).
    pub fn verifier_bytes(&self) -> Vec<u8> {
        self.v.to_bytes_be()
    }

    /// Server ephemeral: pick private b, return (b_priv, B) where
    /// B = (k*v + g^b) mod N - the value sent to the client as hex
    /// (`genServerKey`, srp.cpp:124).
    pub fn server_public(&self, b_bytes: &[u8]) -> (BigUint, String) {
        let modulus = n();
        let b_priv = BigUint::from_bytes_be(b_bytes).rem_pub(&modulus);
        let gb = BigUint::modpow(&g(), &b_priv, &modulus);
        let kv = k_param().mul_mod(&self.v, &modulus);
        let big_b = kv.add_mod(&gb, &modulus);
        (b_priv, hex_text(&big_b.to_bytes_be()))
    }

    /// The server's own session key: K = SHA1((A * v^u) ^ b mod N) -
    /// `serverSessionKey` (srp.cpp:181). Reached without the password.
    pub fn session_key(&self, a_hex: &str, b_priv: &BigUint, b_hex: &str) -> [u8; 20] {
        let modulus = n();
        let big_a = BigUint::from_bytes_be(&hex_to_bytes(a_hex));
        let big_b = BigUint::from_bytes_be(&hex_to_bytes(b_hex));
        let u = scramble(&big_a, &big_b);
        let vu = BigUint::modpow(&self.v, &u, &modulus);
        let base = big_a.mul_mod(&vu, &modulus);
        let s = BigUint::modpow(&base, b_priv, &modulus);
        sha1(&s.to_bytes_be())
    }

    /// Verify the client's Srp256 proof M given the client public key A
    /// (hex), the server private b and public B (hex). Returns the
    /// session key K on success, None if the proof does not match.
    pub fn verify(
        &self,
        a_hex: &str,
        b_priv: &BigUint,
        b_hex: &str,
        client_m_hex: &str,
    ) -> Option<[u8; 20]> {
        self.verify_with(Algo::Srp256, a_hex, b_priv, b_hex, client_m_hex)
    }

    /// The same, for either plugin variant.
    pub fn verify_with(
        &self,
        algo: Algo,
        a_hex: &str,
        b_priv: &BigUint,
        b_hex: &str,
        client_m_hex: &str,
    ) -> Option<[u8; 20]> {
        let big_a = BigUint::from_bytes_be(&hex_to_bytes(a_hex));
        let big_b = BigUint::from_bytes_be(&hex_to_bytes(b_hex));
        let session_key = self.session_key(a_hex, b_priv, b_hex);
        let expected = make_proof(algo, &self.user, &self.salt, &big_a, &big_b, &session_key);
        // Compare the proof by VALUE, not as text. The client sends M as
        // BigInteger::getText - MINIMAL hex digits - so a proof whose top
        // nibble is zero arrives 63 chars (or 62, ...) where our own hex
        // is always the zero-padded 64. A string compare then rejects a
        // perfectly good proof once every ~16 attaches; the engine
        // compares BigIntegers, in which leading zeros do not exist.
        if proof_matches(&expected, client_m_hex) {
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
    fn proof_compare_ignores_leading_zeros() {
        // the engine's client sends its proof as MINIMAL hex digits
        // (BigInteger::getText), so a hash whose leading nibble(s) are
        // zero arrives shorter than our zero-padded 64 - the ~1-in-16
        // auth rejection this replaces
        let expected = [0x0a, 0xbc, 0xde];
        assert!(proof_matches(&expected, "0ABCDE")); // padded form
        assert!(proof_matches(&expected, "ABCDE")); // nibble trimmed
        assert!(proof_matches(&expected, "abcde")); // lower case
        let two_zero = [0x00, 0x0a, 0xbc];
        assert!(proof_matches(&two_zero, "000ABC"));
        assert!(proof_matches(&two_zero, "ABC")); // whole byte + nibble gone
                                                  // a genuinely different proof still fails
        assert!(!proof_matches(&expected, "ABCDF"));
        assert!(!proof_matches(&expected, ""));
        assert!(!proof_matches(&expected, "0ABCDE00"));
    }

    #[test]
    fn matches_node_reference_fixed_inputs() {
        // same fixed a/salt/B as scratch/srp_ref.js
        let a = [7u8; 128];
        let c = client_start(&a);
        assert_eq!(c.a_hex, "FFFDFCC41ADB7A7646831B3DB71B531020F5B00017AD60623CBF0CC64832442F84FA78267154169E1F5DFB18323F41AD54FD442C6581AA23A4D190A815F5BA6236C943AB198F265B2CB72E673E05838CD50172E99FAA09C44842C86BA36F3DDFD5507F9985F2497DD7BD28BBC137C44EB2425B8073D9E8AEBAD5CA2F83038D3", "A");
        let salt = hex_to_bytes("46323038423239394336363543323635444435413239443145433831374644393231334246343345384446334241324535453244313436463845303134353757");
        let b_hex = "1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF";
        // the wire form is getText: this A's top nibble is zero, so the
        // engine's own client would send 255 hex digits, not 256
        assert_eq!(c.a_hex.len(), 255);
        let pr = c.proof("SYSDBA", "masterkey", &salt, b_hex);
        assert_eq!(
            pr.m_hex, "C2A9B2BC58EDC171B41142A9FC93ABF7F01596D815F36780F2751B1D8C8EEE8D",
            "M"
        );
    }

    #[test]
    fn client_and_server_agree_on_the_session_key() {
        // full SRP loopback, for BOTH plugins: the proof the server
        // computes for itself must equal the client's, and both must
        // derive the same K
        for algo in [Algo::Srp256, Algo::Srp] {
            let salt = [0x5Au8; 32];
            let verifier = SrpVerifier::new("SYSDBA", "masterkey", &salt);
            let client = client_start(&[7u8; 128]);
            let (b_priv, b_hex) = verifier.server_public(&[9u8; 128]);
            let proof = client.proof_with(algo, "SYSDBA", "masterkey", &salt, &b_hex);
            let k = verifier
                .verify_with(algo, &client.a_hex, &b_priv, &b_hex, &proof.m_hex)
                .unwrap_or_else(|| panic!("{:?}: server must accept the client proof", algo));
            assert_eq!(k, proof.session_key, "{:?}: session keys must match", algo);
            // a wrong password must be rejected
            let bad = client.proof_with(algo, "SYSDBA", "wrong", &salt, &b_hex);
            assert!(verifier
                .verify_with(algo, &client.a_hex, &b_priv, &b_hex, &bad.m_hex)
                .is_none());
        }
    }

    #[test]
    fn the_two_plugins_differ_only_in_the_proof() {
        // Srp's M is a 20-byte SHA-1, Srp256's a 32-byte SHA-256, but the
        // session key that keys Arc4 is the SAME 20 bytes in both -
        // DEVIATION 3, the one that makes "Srp256 means SHA-256
        // everywhere" a login failure
        let salt = [0x5Au8; 32];
        let verifier = SrpVerifier::new("SYSDBA", "masterkey", &salt);
        let client = client_start(&[7u8; 128]);
        let (_, b_hex) = verifier.server_public(&[9u8; 128]);
        let p1 = client.proof_with(Algo::Srp, "SYSDBA", "masterkey", &salt, &b_hex);
        let p256 = client.proof_with(Algo::Srp256, "SYSDBA", "masterkey", &salt, &b_hex);
        assert_eq!(p1.m_hex.len(), 40, "Srp proof is SHA-1");
        assert_eq!(p256.m_hex.len(), 64, "Srp256 proof is SHA-256");
        assert_ne!(p1.m_hex, p256.m_hex);
        assert_eq!(p1.session_key, p256.session_key, "K is SHA1(S) in both");
        assert_eq!(p1.x_hex, p256.x_hex, "x is SHA-1 in both");
        assert_eq!(p1.scramble_hex, p256.scramble_hex, "u is SHA-1 in both");
    }

    #[test]
    fn plugin_names_round_trip() {
        assert_eq!(Algo::from_plugin_name("Srp256"), Some(Algo::Srp256));
        assert_eq!(Algo::from_plugin_name("Srp"), Some(Algo::Srp));
        assert_eq!(Algo::from_plugin_name("Legacy_Auth"), None);
        assert_eq!(Algo::Srp.plugin_name(), "Srp");
        assert_eq!(Algo::Srp256.plugin_name(), "Srp256");
    }

    #[test]
    fn salt_text_is_minimal_uppercase_hex() {
        // DEVIATION 4: BigInteger::getText drops leading zeros, so the
        // salt that enters x is NOT a fixed 64 characters
        assert_eq!(
            salt_text(&[0xF2, 0x08, 0xB2]),
            "F208B2",
            "a normal salt is plain uppercase hex"
        );
        assert_eq!(
            salt_text(&[0x0A, 0xBC]),
            "ABC",
            "a leading zero NIBBLE disappears - 63 chars for a 32-byte salt"
        );
        assert_eq!(
            salt_text(&[0x00, 0x00, 0x1F]),
            "1F",
            "whole leading zero BYTES disappear too"
        );
        assert_eq!(salt_text(&[0x00, 0x00]), "0", "zero prints as one digit");
        assert_eq!(salt_text(&[]), "0");
    }

    #[test]
    fn a_padded_salt_computes_a_different_verifier() {
        // the teeth on DEVIATION 4: for a salt with a leading zero
        // nibble, hashing the 64-character padded text (or the raw bytes)
        // gives a verifier the engine would never have stored, i.e. a
        // login that fails for one user in sixteen
        let mut raw = [0x5Au8; SRP_SALT_SIZE];
        raw[0] = 0x0A;
        let minimal = salt_text(&raw);
        assert_eq!(minimal.len(), 63);
        let padded = bytes_to_hex_upper(&raw);
        assert_eq!(padded.len(), 64);
        let v_min = compute_verifier("SYSDBA", "masterkey", minimal.as_bytes());
        let v_pad = compute_verifier("SYSDBA", "masterkey", padded.as_bytes());
        let v_raw = compute_verifier("SYSDBA", "masterkey", &raw);
        assert_ne!(v_min, v_pad);
        assert_ne!(v_min, v_raw);
    }

    #[test]
    fn stored_verifier_needs_no_password() {
        // the engine's server never sees a password: from_stored + the
        // verifier bytes must produce the same B, K and verdict as the
        // password-derived path
        let salt = b"5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A";
        let derived = SrpVerifier::new("SYSDBA", "masterkey", salt);
        let stored = SrpVerifier::from_stored("SYSDBA", salt, &derived.verifier_bytes());
        let (b1, hex1) = derived.server_public(&[9u8; 128]);
        let (_, hex2) = stored.server_public(&[9u8; 128]);
        assert_eq!(hex1, hex2, "B depends only on the verifier");
        let client = client_start(&[7u8; 128]);
        let proof = client.proof("SYSDBA", "masterkey", salt, &hex1);
        assert_eq!(
            stored.verify(&client.a_hex, &b1, &hex1, &proof.m_hex),
            Some(proof.session_key),
            "a stored verifier accepts the same proof"
        );
    }

    #[test]
    fn verifier_size_is_the_group_size() {
        // v = g^x mod N is a residue: 128 bytes, except for the ~1-in-256
        // verifier whose leading byte is zero and which the engine
        // therefore stores SHORTER (VARCHAR(128), not CHAR(128))
        let v = compute_verifier("SYSDBA", "masterkey", b"ABCDEF");
        assert_eq!(v.len(), SRP_VERIFIER_SIZE);
        assert!(v.len() <= SRP_VERIFIER_SIZE);
    }

    #[test]
    fn the_wire_form_of_every_number_is_get_text() {
        // A, B and M all travel as BigInteger::getText - minimal
        // uppercase hex - so none of them has a fixed width. Our own A
        // here happens to start with a zero nibble, which is why the
        // engine's client would send 255 digits and a converter that pads
        // to 256 sends bytes no real client sends. node-firebird agrees
        // (qa/auth-srp.sh compares A, B, K and M with it digit for
        // digit).
        let c = client_start(&[7u8; 128]);
        assert!(!c.a_hex.starts_with('0'));
        assert_eq!(c.a_hex.len(), 255);
        // the NUMBER is unchanged: padded and minimal parse alike, which
        // is why a padded A still logs in
        assert_eq!(
            hex_to_bytes(&c.a_hex),
            hex_to_bytes(&format!("0{}", c.a_hex))
        );
        let salt = [0x5Au8; 32];
        let v = SrpVerifier::new("SYSDBA", "masterkey", &salt);
        let (_, b_hex) = v.server_public(&[9u8; 128]);
        assert!(!b_hex.starts_with('0'));
        let p = c.proof("SYSDBA", "masterkey", &salt, &b_hex);
        assert!(!p.m_hex.starts_with('0'));
    }

    #[test]
    fn n_parses_to_1024_bits() {
        let modulus = n();
        assert_eq!(modulus.to_bytes_be().len(), SRP_KEY_SIZE); // 1024 bits
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
