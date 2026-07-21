#!/bin/sh
# Login differential: fire-crab performs a full SRP-256 authentication +
# Arc4 wire encryption + op_attach against a live server, and the engine
# must see it as a genuine attachment - the same way it sees any client.
#
#   qa/diff-login.sh <host:port> <db-path>
#
# Checks:
#   1. correct credentials -> login succeeds (op_attach returns a handle)
#   2. the engine's MON$ATTACHMENTS records the fire-crab attachment as
#      MON$AUTH_METHOD = Srp256, MON$WIRE_CRYPT_PLUGIN = Arc4 (isql, the
#      native client, uses ChaCha64 - a clean discriminator)
#   3. a wrong password is rejected with isc_login (gds 335544472)
#   4. a nonexistent user is rejected
#
# The SRP proof M is additionally pinned to the node reference by a unit
# test (srp::tests::matches_node_reference_fixed_inputs) - so the live
# acceptance here validates the whole handshake, not just that some proof
# was accepted.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
ADDR="${1:-localhost:3050}"
DB="${2:?usage: diff-login.sh <host:port> <db-path>}"
HOST="${ADDR%%:*}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

fail=0

# 1. correct login
if "$FCWIRE" login "$ADDR" "$DB" "$U" "$P" | grep -q '^HANDLE'; then
    echo "OK   login as $U succeeds (SRP-256 auth, Arc4 crypt, op_attach)"
else
    echo "DIFF login as $U failed"; fail=1
fi

# 2. the engine's view while fire-crab holds the attachment open
"$FCWIRE" login "$ADDR" "$DB" "$U" "$P" 3 >/dev/null 2>&1 &
sleep 1
seen=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$DB" <<'EOF' 2>/dev/null | tr -d ' '
SET HEADING OFF;
SELECT COUNT(*) FROM MON$ATTACHMENTS
WHERE MON$AUTH_METHOD = 'Srp256' AND MON$WIRE_CRYPT_PLUGIN = 'Arc4';
EOF
)
wait 2>/dev/null
if [ "${seen:-0}" -ge 1 ]; then
    echo "OK   engine records the attachment as Srp256 + Arc4 (MON\$ATTACHMENTS)"
else
    echo "DIFF engine did not record an Srp256/Arc4 attachment"; fail=1
fi

# 3. wrong password rejected
if "$FCWIRE" login "$ADDR" "$DB" "$U" definitely_wrong 2>&1 | grep -q '335544472'; then
    echo "OK   wrong password rejected with isc_login (335544472)"
else
    echo "DIFF wrong password not rejected as expected"; fail=1
fi

# 4. nonexistent user must NOT log in (Firebird's anti-enumeration path
#    may reject at the proof or stall; either way, no handle is issued)
if "$FCWIRE" login "$ADDR" "$DB" NOSUCHUSER whatever 2>/dev/null | grep -q '^HANDLE'; then
    echo "DIFF nonexistent user unexpectedly logged in"; fail=1
else
    echo "OK   nonexistent user does not log in"
fi

exit $fail
