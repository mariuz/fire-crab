# Converting authentication: `src/auth/SecureRemotePassword` → `fire-crab-auth`

The paper's companion chapter is
[security-architecture.md](../../../security-architecture.md); this file is the
conversion record — what the C++ actually computes, the four places it departs
from the RFC it cites, and how each claim is checked against the running engine
rather than against our own opinion.

## Why authentication is a subsystem, not part of the wire

In the C++ engine the remote layer does not authenticate. `src/remote/` carries
opaque blobs between a client and a named PLUGIN (`Srp256`, `Srp`,
`Legacy_Auth`) and asks only "are you satisfied yet?". The decision lives in
`src/auth/`. fire-crab now mirrors that split:

| Role | C++ | fire-crab |
|---|---|---|
| framing, `op_connect` / `op_cont_auth` / `op_crypt` | `src/remote/` | `fire-crab-wire` |
| the SRP computation | `src/auth/SecureRemotePassword/srp.cpp` | `fire-crab-auth` |
| the server's side of it | `.../server/SrpServer.cpp` | `SrpVerifier` |
| the verifier `CREATE USER` stores | `.../manage/SrpManagement.cpp` | `compute_verifier` |
| SHA-1 / SHA-256 / bignum / Arc4 | `common/`, `plugins/crypt/arc4` | `fire_crab_auth::crypto` |

The split is what lets one implementation serve four roles: fire-crab logs IN
to the real engine as a client, ACCEPTS logins from real clients (node-firebird,
isql, the .NET and Java drivers) as a server, COMPUTES the verifier a user
manager would store, and prints intermediate values as an oracle (`fcauth`).

## The exchange, in the engine's own terms

```
client                                   server
  a  <- random 128 bytes                   (holds salt, v = g^x mod N)
  A  = g^a mod N            --A-->
                            <-salt,B--     B = (k*v + g^b) mod N
  u  = SHA1(A|B)                           u = SHA1(A|B)
  x  = SHA1(salt|SHA1(user:pass))
  S  = (B - k*g^x)^(a+u*x)                 S = (A * v^u)^b
  K  = SHA1(S)                             K = SHA1(S)
  M  = H(H(N)^H(g), H(user), salt, A, B, K)       -- compared by VALUE
                            --M-->          accept iff its own M matches
```

`K` then keys the Arc4 wire cipher, so authentication and encryption come out
of one exchange. The password appears nowhere on the wire, and the server never
holds it — only `(salt, v)`, which is why a stolen security database cannot be
replayed as a login without breaking the discrete log.

## The four deviations from RFC 2945/5054

Each is a real interoperability trap. Each is pinned by a unit test in
`crates/auth/src/srp.rs` and, ultimately, by the live engine's verdict.

1. **`u = SHA1(A | B)` over MINIMAL bytes.** The RFC pads `A` and `B` to
   `|N| = 128`. Firebird hashes `BigInteger::getBytes`, whose length is
   `mp_ubin_size` — the minimal big-endian encoding (`src/common/BigInteger.cpp`).
   Pad, and `u`, `S` and `M` all diverge.
   *Consequence for the converter*: `BigUint::to_bytes_be` must drop leading
   zeros, and `processStrippedInt` (srp.cpp:75) is then equivalent to
   `processInt` — its zero-stripping can only fire for the value zero.
2. **`n1 = H(N) ^ H(g)` is a modPow, not a xor.** srp.cpp:199 computes
   `n1 = n1.modPow(n2, prime)`. The comment one line above says "H(prime) ^
   H(g)". The code is the specification; the comment is testimony.
3. **`K` is SHA-1 even in `Srp256`.** The plugin's hash parameterizes only
   `makeProof` (srp.h:134). The scramble `u`, the user hash `x` and the session
   key `K = H(S)` use the base class's `SecureHash<Sha1>` member (srp.h:91).
   So `Srp256` mixes both hashes and Arc4 is keyed by 20 bytes in both plugins.
   A converter that "upgrades Srp256 to SHA-256 throughout" produces a client
   that can never log in.
4. **Every number travels as `BigInteger::getText` — minimal uppercase hex.**
   Not just the salt: `A` (srp.cpp:110), `B` (srp.cpp:124) and `M` are all
   written with `getText`, which emits no leading zero. The salt is the case
   that bites, because it is stored as 32 raw bytes and converted at send time
   (`SrpServer.cpp:325`): **one user in sixteen has a 63-character salt**, and
   `x` must be computed over exactly those characters.

Deviation 4 has two distinct consequences, and both are gated:

* On the wire, a proof `M` whose top nibble is zero arrives one digit short.
  A server comparing proof STRINGS rejects a valid login about once every
  sixteen attaches. `SrpVerifier::verify_with` compares by value
  (`proof_matches`) — the engine compares `BigInteger`s, in which leading zeros
  do not exist.
* In the security database, a verifier computed over a zero-padded 64-character
  salt (or over the raw 32 bytes) is simply a different number from the one
  `CREATE USER` stored — so the user can never log in, and the failure reads as
  "your user name and password are not defined".

## How each claim is checked

`qa/auth-srp.sh` (13 checks) uses three independent oracles:

**The engine's own stored verifier.** `CREATE USER` makes the ENGINE compute
`v` and store it with a random salt in `plg$srp.plg$srp`. fire-crab recomputes
`v` from the same password and must reproduce those bytes exactly. `ALTER USER`
re-randomizes the salt, so the whole pair moves and must still be reproduced.
A wrong password must reproduce neither the verifier nor a proof.

Reading that table needs no SQL, and cannot use it: `databases.conf` ships the
`security.db` alias with `RemoteAccess = false`, so no client may attach to the
security database over TCP, and a direct local attach collides with the running
server (*"Database already opened with engine instance"*). `fcauth stored`
reads the file with fire-crab's own ODS decoder instead — pages, no attachment.
`PLG$VERIFIER` and `PLG$SALT` are `CHARACTER SET OCTETS`, so they are read as
BYTES (`fire_crab_ods::field_bytes`, added for this): decoding them as text
replaces every byte above 0x7F and the verifier stops being a number.

**The one-in-sixteen salt, on purpose.** The gate ALTERs a user until the
engine hands out a salt whose leading nibble is zero (found in 9–11 tries in
practice), then asserts that the minimal-hex form reproduces the stored
verifier, that the padded and raw forms do NOT, and that a live login as that
user succeeds with a 63-character salt on the wire. Without this hunt the law
is untested by construction: fifteen users in sixteen pass either way.

**The live server.** `fcauth login` performs the real handshake — `op_connect`
presenting `A`, `op_cond_accept` carrying salt and `B`, `op_cont_auth` carrying
`M` — and stops there. Nothing is attached, so an `AUTH OK` means precisely
one thing: the engine's own SRP plugin recomputed our proof from its stored
verifier and agreed. The refusal paths are gated as carefully as the success
path, each against the engine's own status code:

| attempt | engine's answer |
|---|---|
| correct password, `Srp256` | accepted |
| wrong password | `isc_login` (335544472), after the proof |
| unknown user | `isc_login` (335544472), at `op_connect` |
| plugin `Srp` offered alone | `isc_login_error` (335545106) at `op_connect` |

The last row is honest rather than convenient: a default `firebird.conf` sets
`AuthServer = Srp256` only, so the SHA-1 variant cannot be proven against this
server. Its arithmetic is pinned by loopback and by cross-implementation
vectors instead, and the gate records the engine's refusal code rather than
claiming a pass. Changing the server's configuration to make a test pass would
be a gate testing itself.

**A fourth, independent implementation.** node-firebird's `lib/srp.js` has its
own bignum (JS `BigInt`) and its own SHA. Given the same fixed `a`, `b` and
salt, its `A`, `B`, `K` and `M` must equal ours digit for digit — for both
plugins. This is where the `getText` wire form was caught: our `A` was
zero-padded to 256 digits where node (and the engine) send 255. The number was
right and the login worked; the bytes were not what a real client sends.

## What is deliberately not converted

* **`Legacy_Auth`** — DES `crypt` over an 8-character password, kept only for
  pre-3.0 clients. Converting it would add a weak path to fire-crab for no
  differential value.
* **The wire-crypt plugins beyond Arc4** — ChaCha20/ChaCha64 are what the
  native client negotiates (`MON$WIRE_CRYPT_PLUGIN` shows `ChaCha64` for isql
  and `Arc4` for fire-crab, which makes a clean discriminator in
  `qa/diff-login.sh`).
* **Random `a`/`b` in the oracle.** `fcauth` uses fixed private keys so its
  vectors are reproducible. That is right for an oracle and wrong for a client:
  `fire_crab_wire::login` takes its randomness from the caller, because a
  reused `a` makes a recorded handshake replayable.
* **`isc_dpb_password` / cleartext attach** — refused rather than implemented.

## Frontier

* `Legacy_UserManager` and the `PLG$USERS` table (the legacy hash) — readable
  with the same ODS route, if a differential is ever wanted.
* Mapping and roles (`RDB$AUTH_MAPPING`): who the authenticated identity
  BECOMES inside the database is a separate subsystem from proving it.
* The `Srp` variant against a server configured to serve it — the gate already
  accepts that outcome if it appears (`AUTH OK plugin=Srp`).
* Multi-hop authentication (`op_cont_auth` loops for plugins that need more
  than one round trip); SRP needs exactly one.
