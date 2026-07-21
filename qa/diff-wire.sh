#!/bin/sh
# Wire-protocol negotiation differential: fire-crab's op_connect
# handshake must reproduce the exact protocol version the reference
# clients negotiate with the same server. The server always selects
# the highest offered version it supports, so:
#
#   - offering 13 alone yields 13 - what the paper's PURE-WIRE clients
#     (node-firebird, rsfbclient's pure_rust backend) negotiate;
#   - offering up to 20 yields 20 - what the NATIVE fbclient (the C++
#     client, fb-cpp, fbintf) negotiates;
#   - offering an intermediate range yields its maximum;
#   - offering only legacy versions (<13) is rejected - Firebird 6's
#     protocol floor.
#
#   qa/diff-wire.sh <host:port> <db-path>
#
# fire-crab connects over real TCP, sends op_connect, and reads the
# server's op_accept/op_cond_accept - the same exchange src/remote does.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ADDR="${1:-localhost:3050}"
DB="${2:?usage: diff-wire.sh <host:port> <db-path>}"

neg() { # $1 offer-list -> negotiated version, or "reject"
    "$FCWIRE" negotiate "$ADDR" "$DB" "$1" 2>/dev/null | awk '/PROTOCOL/{print $2}' \
        | grep . || echo reject
}

check() { # $1 offer  $2 expected  $3 label
    got=$(neg "$1")
    if [ "$got" = "$2" ]; then
        echo "OK   offer [$1] -> protocol $got  ($3)"
    else
        echo "DIFF offer [$1] -> $got, expected $2  ($3)"
        return 1
    fi
}

fail=0
check "13"                   "13"     "matches node-firebird / rsfbclient pure-wire" || fail=1
check "13,16,17,18,19,20"    "20"     "matches the native fbclient (C++/fb-cpp/fbintf)" || fail=1
check "16,17"                "17"     "server picks the max offered" || fail=1
check "18,19"                "19"     "server picks the max offered" || fail=1
check "10,11,12"             "reject" "Firebird 6 protocol floor (>=13)" || fail=1
exit $fail
