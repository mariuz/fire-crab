#!/bin/bash
# THE FRAGMENTED STORE: a record too large for one page is written as a
# fragment chain, exactly the shape the engine reads and writes.
#
# The head carries `rhd_incomplete` and an rhdf forward pointer; middle
# fragments carry `rhd_fragment | rhd_incomplete`; the last fragment
# `rhd_fragment` alone. Every piece is NOT_PACKED - the engine's unpack
# tests that PER PIECE (vio.cpp:575-602) - and the chain is written TAIL
# FIRST so each piece can point at an already-placed successor. The
# writer's split points are its own: the assembled image is identical
# and both readers just follow the chain (gstat may count a different
# fragment total for the same bytes - that is the split, not the data).
#
# Before this, `INSERT` of a big row was refused ("record larger than a
# page") while the READ side already assembled engine-written chains.
# UPDATE and DELETE of a fragmented HEAD still refuse - fail-closed,
# per-row (the same table's small rows update and delete fine), the row
# and the file untouched - pinned below as the recorded boundary.
#
#   qa/serve-real-fragstore.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4491}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
FC="$D/fc-fragstore.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0; ran=0

rm -f "$FC"
# the NONE attachment matters: a UTF8 one types the LPAD at 4 bytes per
# char and hits the engine's 64K implementation limit before any row
"$ISQL" -q -b -ch NONE -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$FC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE F (ID INTEGER, T VARCHAR(30000) CHARACTER SET NONE);
COMMIT;
INSERT INTO F VALUES (1, LPAD('', 20000, 'abcdefghij'));
INSERT INTO F VALUES (2, 'small');
COMMIT;
EOF
chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fragstore.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }

node_q() { FC_DB="$FC" FC_PORT="$PORT" FC_Q="$1" FC_PARAM="${2:-}" timeout 60 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  const params = process.env.FC_PARAM ? [process.env.FC_PARAM] : [];
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,params,(e2,r)=>{
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      if(Array.isArray(r)) for(const row of r)
        console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
      else console.log("OK");
      db.detach();process.exit(0);});});' 2>/dev/null
}
isql_q() { printf 'SET HEADING OFF;\n%s;\n' "$1" |
    "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$FC" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]\{1,\}/|/g; s/|$//' | grep -v '^$'; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

# --- 1. fc reads the engine's fragmented chain -------------------------
check "fc assembles the engine's 20000-byte chain" \
    "$(node_q 'SELECT ID, CHAR_LENGTH(T) AS L FROM F ORDER BY ID')" \
    "1|20000
2|5"

# --- 2. fc WRITES a chain, everybody reads it --------------------------
BIG=$(python3 -c "print('qrstuvwxyz'*2000)")
check "fc stores a 20000-byte row (a parameter, split across pages)" \
    "$(node_q 'INSERT INTO F VALUES (3, ?)' "$BIG")" "OK"
check "fc reassembles its own chain" \
    "$(node_q 'SELECT CHAR_LENGTH(T) AS L FROM F WHERE ID = 3')" "20000"
check "the ENGINE reassembles fc's chain" \
    "$(isql_q 'SELECT ID, CHAR_LENGTH(T) FROM F ORDER BY ID')" \
    "1|20000
2|5
3|20000"
check "... and matches it by content" \
    "$(isql_q "SELECT ID FROM F WHERE T STARTING WITH 'qrstuvwxyz'")" "3"
ran=$((ran + 1))
frags=$("$GSTAT" -r -t F -user "$U" -pas "$P" "$FC" 2>/dev/null |
    grep -oE "total fragments: [0-9]+" | grep -oE "[0-9]+")
if [ "${frags:-0}" -ge 3 ]; then
    echo "OK   gstat counts the chains (total fragments: $frags)"
else
    echo "DIFF gstat fragments: [$frags] - the row did not fragment"
    fail=1
fi
ran=$((ran + 1))
g=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$g" ]; then
    echo "OK   gfix -v -full finds nothing wrong with fc's chain"
else
    echo "DIFF gfix: $g"
    fail=1
fi

# --- 3. the recorded boundary: DML over a fragmented HEAD --------------
# refused fail-closed and PER ROW - the same table's small rows move
check "UPDATE of a fragmented head refuses (recorded boundary)" \
    "$(node_q "UPDATE F SET T = 'x' WHERE ID = 3")" "ERR"
check "DELETE of a fragmented head refuses too" \
    "$(node_q 'DELETE FROM F WHERE ID = 1')" "ERR"
check "... while the small row on the same table still updates" \
    "$(node_q "UPDATE F SET T = 'moved' WHERE ID = 2")" "OK"
check "and the fragmented rows are untouched by the refusals" \
    "$(isql_q 'SELECT ID, CHAR_LENGTH(T) FROM F ORDER BY ID')" \
    "1|20000
2|5
3|20000"

kill $srv 2>/dev/null; srv=""
rm -f "$FC"
if [ "$ran" -lt 11 ]; then
    echo "DIFF only $ran checks ran (expected at least 11) - did one silently skip?"
    fail=1
fi
exit $fail
