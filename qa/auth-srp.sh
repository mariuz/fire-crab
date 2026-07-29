#!/bin/bash
# SRP authentication, differentially tested against the engine in the
# three ways an auth conversion can be wrong:
#
#   1. THE STORED VERIFIER. `CREATE USER` makes the ENGINE compute
#      v = g^x mod N and store it beside a random salt in
#      plg$srp.plg$srp. fire-crab recomputes v from the same password
#      and must reproduce those bytes exactly - an oracle nobody can
#      argue with, because the engine wrote it. fcauth reads the
#      security database with fire-crab's own ODS decoder (no attach:
#      databases.conf ships `security.db` with RemoteAccess = false, and
#      a direct attach collides with the running server).
#
#   2. THE MINIMAL-HEX SALT (the subtle one). The salt is stored as 32
#      raw bytes but travels - and enters x - as BigInteger::getText,
#      uppercase hex with NO leading zeros (SrpServer.cpp:325). So one
#      user in sixteen has a 63-character salt. This gate ALTERs a user
#      until the engine hands out such a salt, then shows that only the
#      minimal form reproduces the stored verifier, that the 64-char
#      padded form and the raw bytes do NOT, and that a live login as
#      that user still succeeds.
#
#   3. THE LIVE SERVER. fcauth performs the real handshake against the
#      running engine - op_connect presenting A, op_cond_accept carrying
#      salt and B, op_cont_auth carrying M - and the engine's own SRP
#      plugin, working from its stored verifier, accepts or refuses.
#      Wrong password, unknown user and an unserved plugin must each be
#      refused with the engine's own status code, never accepted.
#
# Plus a cross-implementation check: node-firebird's SRP (an independent
# implementation with its own bignum and SHA) must produce identical
# A, B, u, x, S, K and M from the same fixed inputs, for both plugins.
#
#   qa/auth-srp.sh [host] [port]
#
# Creates and drops its own users (FCAUTH1, FCAUTHZ) and one scratch
# database; touches nothing else.

set -u
FCAUTH="${FCAUTH:-$(dirname "$0")/../target/release/fcauth}"
ISQL="${ISQL:-isql}"
HOST="${1:-127.0.0.1}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
SEC="${FC_SECURITY_DB:-/opt/firebird/security6.fdb}"
D=/tmp/fbhandson
DB="$D/fc-auth.fdb"
SNAP="$D/fc-auth-sec.fdb"

mkdir -p "$D"; rm -f "$DB" "$SNAP"
fail=0

[ -r "$SEC" ] || { echo "SKIP security database $SEC is not readable"; exit 0; }

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

sql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1; }

# A snapshot of the security database, retried until the user we just
# wrote is visible in it: the server may still be holding the freshly
# committed page in its cache.
snap_until() { # <user>
    i=0
    while [ $i -lt 20 ]; do
        cp "$SEC" "$SNAP" 2>/dev/null
        "$FCAUTH" stored "$SNAP" "$1" >/dev/null 2>&1 && return 0
        i=$((i + 1)); sleep 0.2
    done
    return 1
}
field() { awk -v k="$2" '$1 == k {print $2}' <<<"$1"; }

# --------------------------------------------------- 1. stored verifier ---
create_user() { # <user> <password>
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<EOF
CREATE OR ALTER USER $1 PASSWORD '$2';
COMMIT;
EOF
}

PW1="fc-auth-pw-1"
create_user FCAUTH1 "$PW1"
if ! snap_until FCAUTH1; then
    echo "FAIL FCAUTH1 never appeared in the security database snapshot"
    exit 1
fi
st=$("$FCAUTH" stored "$SNAP" FCAUTH1)
salt=$(field "$st" SALT)
stored_v=$(field "$st" VERIFIER)
ours=$("$FCAUTH" verifier FCAUTH1 "$PW1" "$salt")
our_v=$(field "$ours" V)
if [ -n "$stored_v" ] && [ "$our_v" = "$stored_v" ]; then
    echo "OK   fire-crab reproduces the verifier CREATE USER stored (${#stored_v} hex digits)"
else
    echo "DIFF stored verifier not reproduced"
    echo "     engine:    $stored_v"
    echo "     fire-crab: $our_v"
    fail=1
fi

# the same pair, checked the way the engine checks it: a server half that
# holds ONLY the stored bytes must accept a client that knows the password
ck=$("$FCAUTH" check "$SNAP" FCAUTH1 "$PW1")
case "$ck" in
    *"RECOMPUTED MATCH"*"PROOF ACCEPTED"*)
        echo "OK   the stored verifier alone (no password) accepts our proof" ;;
    *) echo "DIFF check said: $(tr '\n' ' ' <<<"$ck")"; fail=1 ;;
esac

# teeth: a WRONG password must not reproduce the stored verifier
ck=$("$FCAUTH" check "$SNAP" FCAUTH1 "not-the-password")
case "$ck" in
    *"RECOMPUTED DIFFER"*"PROOF REJECTED"*)
        echo "OK   a wrong password reproduces neither the verifier nor a proof" ;;
    *) echo "DIFF a wrong password was not rejected: $(tr '\n' ' ' <<<"$ck")"; fail=1 ;;
esac

# ALTER USER: the engine re-randomises the salt, so the whole pair moves
PW2="fc-auth-pw-2"
create_user FCAUTH1 "$PW2"
snap_until FCAUTH1
st2=$("$FCAUTH" stored "$SNAP" FCAUTH1)
salt2=$(field "$st2" SALT)
v2=$(field "$st2" VERIFIER)
ours2=$(field "$("$FCAUTH" verifier FCAUTH1 "$PW2" "$salt2")" V)
if [ "$salt2" != "$salt" ] && [ "$ours2" = "$v2" ]; then
    echo "OK   ALTER USER re-salts and re-verifies; fire-crab follows"
elif [ "$salt2" = "$salt" ]; then
    echo "DIFF ALTER USER kept the same salt"; fail=1
else
    echo "DIFF the re-salted verifier was not reproduced"; fail=1
fi

# ------------------------------------------- 2. the minimal-hex salt ------
# hunt for a salt whose leading nibble is zero (p = 1/16 per ALTER)
zero_salt=""; tries=0
while [ $tries -lt 48 ]; do
    tries=$((tries + 1))
    create_user FCAUTHZ "fc-auth-z-$tries"
    snap_until FCAUTHZ || continue
    s=$(field "$("$FCAUTH" stored "$SNAP" FCAUTHZ)" SALT)
    case "$s" in
        0*) zero_salt="$s"; zero_pw="fc-auth-z-$tries"; break ;;
    esac
done
if [ -z "$zero_salt" ]; then
    echo "SKIP no leading-zero salt in $tries tries (p=1/16 each) - the"
    echo "     minimal-hex law is still pinned by unit tests"
else
    stz=$("$FCAUTH" stored "$SNAP" FCAUTHZ)
    vz=$(field "$stz" VERIFIER)
    minimal=$("$FCAUTH" verifier FCAUTHZ "$zero_pw" "$zero_salt")
    salt_text=$(field "$minimal" SALT_TEXT)
    v_min=$(field "$minimal" V)
    padded=$("$FCAUTH" verifier-padded FCAUTHZ "$zero_pw" "$zero_salt")
    v_pad=$(field "$padded" V_PADDED)
    v_raw=$(field "$padded" V_RAW)
    if [ "$v_min" = "$vz" ]; then
        echo "OK   leading-zero salt (found in $tries tries, text is ${#salt_text} chars):"
        echo "     the MINIMAL hex text reproduces the engine's verifier"
    else
        echo "DIFF minimal-hex verifier differs from the stored one"; fail=1
    fi
    if [ "$v_pad" != "$vz" ] && [ "$v_raw" != "$vz" ]; then
        echo "OK   the 64-char padded salt and the raw 32 bytes do NOT (the"
        echo "     one-in-sixteen login failure this law prevents)"
    else
        echo "DIFF a padded or raw salt also matched - the law is untested"; fail=1
    fi
    lg=$("$FCAUTH" login "$HOST" "$PORT" "$DB" FCAUTHZ "$zero_pw" Srp256 2>&1)
    slen=$(field "$lg" SALT_LEN)
    case "$lg" in
        *"AUTH OK"*)
            echo "OK   the live server logs that user in, salt $slen characters on the wire" ;;
        *) echo "DIFF live login for the leading-zero-salt user: $(tr '\n' ' ' <<<"$lg")"; fail=1 ;;
    esac
fi

# ------------------------------------------------------ 3. live logins ----
lg=$("$FCAUTH" login "$HOST" "$PORT" "$DB" FCAUTH1 "$PW2" Srp256 2>&1)
case "$lg" in
    *"AUTH OK plugin=Srp256"*)
        echo "OK   Srp256 handshake accepted by the live engine ($(field "$lg" AUTH))" ;;
    *) echo "DIFF Srp256 login: $(tr '\n' ' ' <<<"$lg")"; fail=1 ;;
esac

# the engine's session key is not observable, but its VERDICT is - and a
# wrong password must reach isc_login (335544472), not an acceptance
lg=$("$FCAUTH" login "$HOST" "$PORT" "$DB" FCAUTH1 "wrong-$PW2" Srp256 2>&1)
case "$lg" in
    *"AUTH FAIL gds=335544472"*)
        echo "OK   a wrong password is refused with isc_login after the proof" ;;
    *) echo "DIFF wrong-password login: $(tr '\n' ' ' <<<"$lg")"; fail=1 ;;
esac

lg=$("$FCAUTH" login "$HOST" "$PORT" "$DB" FCAUTHNOSUCH "whatever" Srp256 2>&1)
case "$lg" in
    *"gds=335544472"*)
        echo "OK   an unknown user is refused with isc_login too (no enumeration)" ;;
    *) echo "DIFF unknown-user login: $(tr '\n' ' ' <<<"$lg")"; fail=1 ;;
esac

# the Srp (SHA-1 proof) variant: a default firebird.conf serves ONLY
# Srp256, so offering just Srp cannot reach a proof. Record the ENGINE's
# own refusal rather than claiming the variant works - its arithmetic is
# pinned by the loopback and vector tests instead.
lg=$("$FCAUTH" login "$HOST" "$PORT" "$DB" FCAUTH1 "$PW2" Srp 2>&1)
case "$lg" in
    *"AUTH OK plugin=Srp"*)
        echo "OK   the Srp (SHA-1 proof) variant is served here and accepted" ;;
    *"CONNECT REFUSED gds=335545106"*)
        echo "OK   Srp is not in this server's AuthServer list: the engine"
        echo "     refuses at op_connect with isc_login_error (335545106)" ;;
    *) echo "DIFF Srp login: $(tr '\n' ' ' <<<"$lg")"; fail=1 ;;
esac

# ------------------------------------------- 4. cross-implementation ------
NF="$(dirname "$0")/../../../samples/nodejs/node_modules/node-firebird"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$NF/lib/srp.js" ]; then
    echo "SKIP node-firebird not available for the cross-implementation vectors"
else
    for algo in Srp256 Srp; do
        v=$("$FCAUTH" vectors "$algo")
        want_a=$(field "$v" A); want_b=$(field "$v" B); want_k=$(field "$v" K)
        want_m=$(field "$v" M); want_salt=$(field "$v" SALT)
        got=$(NF="$NF" SALT="$want_salt" ALGO="$algo" node -e '
          const srp = require(process.env.NF + "/lib/srp.js");
          const hash = process.env.ALGO === "Srp256" ? "sha256" : "sha1";
          const salt = Buffer.from(process.env.SALT, "ascii");
          const a = BigInt("0x" + "07".repeat(128));
          const b = BigInt("0x" + "09".repeat(128));
          const hex = (x) => x.toString(16).toUpperCase();
          const c = srp.clientSeed(a);
          const s = srp.serverSeed("SYSDBA", "masterkey", salt, b, "sha1");
          const p = srp.clientProof("SYSDBA", "masterkey", salt,
                                    c.public, s.public, a, hash);
          console.log("A " + hex(c.public));
          console.log("B " + hex(s.public));
          console.log("K " + hex(p.clientSessionKey));
          console.log("M " + hex(p.authData));
        ' 2>&1)
        got_a=$(field "$got" A); got_b=$(field "$got" B)
        got_k=$(field "$got" K); got_m=$(field "$got" M)
        if [ "$got_a" = "$want_a" ] && [ "$got_b" = "$want_b" ] &&
           [ "$got_k" = "$want_k" ] && [ "$got_m" = "$want_m" ]; then
            echo "OK   $algo: A, B, K and M agree with node-firebird's independent SRP"
        else
            echo "DIFF $algo vectors disagree with node-firebird"
            echo "     A  ours $want_a"
            echo "        node $got_a"
            echo "     B  ours $want_b"
            echo "        node $got_b"
            echo "     K  ours $want_k / node $got_k"
            echo "     M  ours $want_m / node $got_m"
            fail=1
        fi
    done
fi

# ----------------------------------------------------------- cleanup -----
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<'SQL'
DROP USER FCAUTH1;
DROP USER FCAUTHZ;
COMMIT;
SQL
rm -f "$SNAP"
exit $fail
