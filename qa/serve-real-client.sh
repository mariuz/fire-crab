#!/bin/sh
# The server-side gate: fire-crab runs as a SERVER and a genuine,
# third-party Firebird client (node-firebird, which contains no fire-crab
# code) authenticates and queries it end-to-end. This is the honest
# firebird-qa direction - the suite drives a server, so the server must
# accept real clients, not just fire-crab's own loopback.
#
#   qa/serve-real-client.sh [port]
#
# The client performs the whole exchange over the encrypted wire:
#   op_connect -> protocol 20 negotiation
#   server-side SRP-256 (no password on the wire) -> session key
#   op_crypt -> Arc4 armed both directions with the session key
#   op_attach (encrypted)
#   op_transaction / allocate / prepare / execute / fetch
# and must decode the fixed answer (4242) that this milestone's server
# returns for every query. A value mismatch, or a decode of null, is a
# protocol bug (it was, once: a missing FB_PROTOCOL_FLAG made the client
# parse rows in the legacy null-indicator layout - see server.rs).
#
# Requires: node with the node-firebird package importable. The paper's
# samples/nodejs directory provides it; point NODE_PATH at its
# node_modules if running elsewhere.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
PORT="${1:-3050}"
EXPECT="${EXPECT:-4242}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP node not found"; exit 0
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-real.log 2>&1 &
srv=$!
# give the listener a moment; kill the server on exit no matter what
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
    i=$((i + 1)); sleep 0.1
done

got=$(node -e '
const Firebird = require("node-firebird");
Firebird.attach({host:"127.0.0.1",port:'"$PORT"',database:"probe",user:"'"$U"'",password:"'"$P"'"}, (err, db) => {
  if (err) { console.log("ERR "+err.message); process.exit(0); }
  db.query("SELECT CAST(42 AS BIGINT) FROM RDB$DATABASE", (e2, r) => {
    if (e2) { console.log("ERR "+e2.message); }
    else {
      const row = r && r[0];
      const val = row ? row[Object.keys(row)[0]] : null;
      console.log("VAL "+val);
    }
    db.detach(); process.exit(0);
  });
});' 2>&1 | tail -1)

case "$got" in
    "VAL $EXPECT")
        echo "OK   node-firebird authenticated, attached and fetched $EXPECT over the wire"
        exit 0 ;;
    *)
        echo "FAIL node-firebird result: $got (expected VAL $EXPECT)"
        exit 1 ;;
esac
