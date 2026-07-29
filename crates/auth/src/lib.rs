//! fire-crab-auth - the conversion of Firebird's authentication core,
//! `src/auth/SecureRemotePassword/` (srp.cpp, srp.h, the client and
//! server plugins and the user manager), together with the from-scratch
//! primitives it needs: SHA-1, SHA-256, unsigned big-integer modular
//! exponentiation and Arc4.
//!
//! # Why authentication is its own subsystem
//!
//! In the C++ engine authentication is not part of the wire protocol: it
//! is a set of PLUGINS (`Srp256`, `Srp`, `Legacy_Auth`) that the remote
//! layer merely carries messages for. `src/remote/` knows only "hand this
//! opaque blob to the named plugin and ask whether it is satisfied yet".
//! fire-crab now mirrors that split - `fire-crab-wire` frames and
//! transports, `fire-crab-auth` decides - which is what lets the same
//! computation serve four different roles:
//!
//!   * as a CLIENT, proving fire-crab's identity to the real engine
//!     (`fire_crab_wire::login`),
//!   * as a SERVER, checking a real client's proof (`fcwire serve`, which
//!     node-firebird, isql and the .NET/Java drivers all log in to),
//!   * as a USER MANAGER, computing the verifier that `CREATE USER`
//!     stores in `plg$srp.plg$srp` - the shape this slice adds,
//!   * as an ORACLE (`fcauth`), printing intermediate values so the
//!     engine's own stored verifiers and the paper's reference
//!     implementations can be compared against ours.
//!
//! # What SRP-6a buys, in one paragraph
//!
//! The password never crosses the wire, and the server never stores
//! anything an attacker who steals the security database can replay: it
//! holds a random 32-byte `salt` and a `verifier` v = g^x mod N, where
//! x = SHA1(salt | SHA1(user ':' password)). The client sends A = g^a,
//! the server answers with the salt and B = k*v + g^b; both sides then
//! reach the same secret S (the client via the password, the server via
//! the verifier) and hash it to a session key K = SHA1(S). The client's
//! proof M = H(H(N)^H(g), H(user), salt, A, B, K) convinces the server
//! that the client really derived the same K. K then keys the Arc4 wire
//! cipher, so authentication and encryption come out of one exchange.
//!
//! # The four places Firebird deviates from RFC 5054
//!
//! Every one of these is a real interoperability trap; each is pinned by
//! a unit test in `srp.rs` and, ultimately, by the live server accepting
//! (or refusing) our proof:
//!
//! 1. **u = SHA1(A | B) over MINIMAL bytes.** The RFC hashes A and B
//!    zero-padded to |N| = 128 bytes. Firebird hashes
//!    `BigInteger::getBytes`, whose length is `mp_ubin_size` - the
//!    minimal big-endian encoding (`src/common/BigInteger.cpp`). Padding
//!    gives a different u, a different S, and a proof the server rejects.
//! 2. **n1 = H(N) ^ H(g) is a modPow, not a xor.** `srp.cpp:199`
//!    computes `n1 = n1.modPow(n2, prime)` where n1 = H(N), n2 = H(g).
//!    The comment above it says "H(prime) ^ H(g)"; the code raises to a
//!    power. The code is the specification.
//! 3. **K is SHA-1 even in Srp256.** The plugin's hash (SHA-256 for
//!    `Srp256`) applies only to the PROOF; the scramble u, the user hash
//!    x and the session key K = H(S) always use the SHA-1 member `hash`
//!    of `RemotePassword` (srp.h:91). So Srp256 mixes both hashes, and a
//!    20-byte K keys Arc4 in both plugins.
//! 4. **The salt on the wire is hex TEXT, minimally encoded.** The
//!    security database stores 32 raw bytes; `SrpServer.cpp:325` sends
//!    `BigInteger(bytes).getText(salt)`, i.e. UPPERCASE hex with no
//!    leading zeros - so a salt whose first byte is < 0x10 travels as 63
//!    characters, not 64, and x must be computed over exactly those
//!    characters. See [`salt_text`].
//!
//! # Layout
//!
//! * [`crypto`] - SHA-1, SHA-256, [`crypto::BigUint`] (modpow over the
//!   1024-bit group), [`crypto::Rc4`]. No dependencies, vector-tested.
//! * [`srp`] - the SRP-6a exchange: [`srp::Algo`] (the two plugin
//!   variants), the client half, the server half, and the user-manager
//!   half ([`srp::compute_verifier`]).
//!
//! The `fcauth` binary is the oracle interface; see `src/main.rs`.

pub mod crypto;
pub mod srp;

pub use srp::{
    bytes_to_hex_upper, client_start, compute_verifier, hex_text, hex_to_bytes, proof_matches,
    salt_text, user_hash, Algo, SrpClient, SrpProof, SrpVerifier, SRP_KEY_SIZE, SRP_SALT_SIZE,
    SRP_VERIFIER_SIZE,
};
