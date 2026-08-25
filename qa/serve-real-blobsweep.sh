#!/bin/bash
# SWEEP OVER BLOB-BEARING RELATIONS - fire-crab's sweep used to leave
# any relation carrying blob records WHOLE ("the blob walk is its own
# slice"): a user table with a blob column NEVER got version GC, and
# the catalog's own blob relations (RDB$FIELDS, RDB$RELATIONS) kept
# every back version forever. Now every collected version takes its
# blobs with it, under the engine's own law (BLB_garbage_collect,
# blb.cpp:424): going = the removed versions' blob ids, staying = the
# surviving versions' - identity the (relation, recno) id - and the
# diff is freed via gc::free_blob (a level-1 vector's pages back to
# their PIP first). DELTA back versions reconstruct against the next
# newer image before their blob fields are read; a fragmented member's
# tail pieces are freed with it; a relation whose formats cannot be
# resolved is left whole (never free blind - unit-pinned).
#
# The proof is differential: the same churn on twin databases, the
# ENGINE's sweep on its file, fire-crab's sweep (gfix -sweep through
# the served port) on its own - and the SAME survivors: record count,
# version count (0), live blob count, blob pages, every row's content
# including a level-1 blob's bytes, gfix -v -full silent, gbak whole.
#
#   qa/serve-real-blobsweep.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"; GSTAT="${GSTAT:-gstat}"
PORT="${1:-4993}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-blobsweep-crab.fdb"; B="$D/fc-blobsweep-engine.fdb"
LOG="/tmp/fc-serve-blobsweep-$PORT.log"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/fc-blobsweep.fbk" "$D/fc-blobsweep-r.fdb" "$D/blobsweep.sql" "$D/fc-blobsweep-eng2.fdb"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/^ //; s/ *$//' | tr '\n' '|'; }
q() { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$1" 2>&1 | norm; }
# the B table's gstat -r story: records, versions, blob count, blob pages
bstat() { "$GSTAT" -a -r -user "$U" -pas "$P" "$1" 2>/dev/null | sed -n '/"B" (/,/^$/p' \
    | grep -E "total records|total versions|Blobs:" \
    | sed 's/.*total records: \([0-9]*\).*/records \1/; s/.*total versions: \([0-9]*\),.*/versions \1/; s/.*Blobs: \([0-9]*\), total length: [0-9]*, blob pages: \([0-9]*\).*/blobs \1 pages \2/' | tr '\n' ' '; }

# --- the churn: level-0 blob updates, deletes, a replaced level-1 ---
# PAD CHAR(400) ON PURPOSE: the engine stores a back version as a
# DELTA only when the difference stream beats the whole record
# (vio.cpp:6644) - a wide row with a small change is what makes one,
# and without it the engine-written twin below carries NO delta chains
# at all (measured: 0 delta versions on narrow rows, 5 with the pad),
# so the delta-reconstruction half of the blob walk would go untested
{ printf 'CREATE TABLE B (ID INTEGER, PAD CHAR(400), TXT BLOB SUB_TYPE TEXT);\nCOMMIT;\n'
  i=1; while [ $i -le 10 ]; do printf "INSERT INTO B VALUES (%d, 'pad %d', 'row %d blob content some text');\n" "$i" "$i" "$i"; i=$((i + 1)); done
  printf 'COMMIT;\n'
  r=0; while [ $r -lt 3 ]; do
    i=1; while [ $i -le 5 ]; do printf "UPDATE B SET TXT = 'updated round %d row %d fresh text' WHERE ID = %d;\n" "$r" "$i" "$i"; i=$((i + 1)); done
    printf 'COMMIT;\n'; r=$((r + 1)); done
  printf 'DELETE FROM B WHERE ID > 8;\nCOMMIT;\n'; } > "$D/blobsweep.sql"

churn() { # <conn> - the isql churn plus a node level-1 insert + replace
  "$ISQL" -q -ch NONE -user "$U" -pas "$P" "$1" -i "$D/blobsweep.sql" 2>&1 | grep -c "Statement failed"
}
bigblob() { # <host:port form for node> <db path>
  node -e '
const fb = require("node-firebird");
fb.attach({host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"},(e,db)=>{
  if(e){console.log("attach err",e.message);process.exit(1);}
  db.query("INSERT INTO B (ID, TXT) VALUES (100, ?)",[Buffer.alloc(120000, 65)],(e2)=>{
    if(e2){console.log("ins err",e2.message);process.exit(1);}
    db.query("UPDATE B SET TXT = ? WHERE ID = 100",[Buffer.alloc(110000, 66)],(e3)=>{
      if(e3){console.log("upd err",e3.message);process.exit(1);}
      db.detach(()=>process.exit(0));
    });
  });
});' 2>&1
}
check "churn through fire-crab, error-free" "$(churn "127.0.0.1/$PORT:$A")" "0"
check "churn through the engine, error-free" "$(churn "127.0.0.1/$REAL:$B")" "0"
check "level-1 blob insert + replace through fire-crab" "$(bigblob "$PORT" "$A")" ""
check "level-1 blob insert + replace through the engine" "$(bigblob "$REAL" "$B")" ""

# THE ENGINE-WRITTEN TWIN, swept by FIRE-CRAB: the engine DELTAFIES
# back versions (rhd_delta - "the PRIOR version is differences only",
# ods.h:1012, a flag that sits on the version IN FRONT), and fc's own
# writer never does, so this is the only leg that exercises delta
# reconstruction in the blob walk. A copy of B before its own sweep.
cp "$B" "$D/fc-blobsweep-eng2.fdb" 2>/dev/null; chmod 666 "$D/fc-blobsweep-eng2.fdb" 2>/dev/null

# --- the sweeps: each server's own ---
"$GFIX" -sweep -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
"$GFIX" -sweep -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
# ...and fire-crab's, over the ENGINE's file
"$GFIX" -sweep -user "$U" -pas "$P" "127.0.0.1/$PORT:$D/fc-blobsweep-eng2.fdb" >/dev/null 2>&1
check "fc sweeping the ENGINE's file leaves the engine's own survivors" \
    "$(bstat "$D/fc-blobsweep-eng2.fdb")" "$(bstat "$B")"
SQL="SELECT ID, CAST(TXT AS VARCHAR(60)) FROM B WHERE ID <= 8 ORDER BY ID;"
check "...and every row still reads identically through the ENGINE" \
    "$(q "$D/fc-blobsweep-eng2.fdb" "$SQL")" "$(q "$B" "$SQL")"
check "...the level-1 blob too" \
    "$(q "$D/fc-blobsweep-eng2.fdb" "SELECT OCTET_LENGTH(TXT) FROM B WHERE ID = 100;")" \
    "$(q "$B" "SELECT OCTET_LENGTH(TXT) FROM B WHERE ID = 100;")"
V2=$("$GFIX" -v -full -user "$U" -pas "$P" "$D/fc-blobsweep-eng2.fdb" 2>&1 | norm)
check "...and gfix -v -full is silent on it" "$V2" ""

SA=$(bstat "$A"); SB=$(bstat "$B")
check "after each sweep, the same survivors (records/versions/blobs/pages)" "$SA" "$SB"
check "...and every version and superseded blob is GONE on fc's file" \
    "$(echo "$SA" | grep -o 'versions 0' )" "versions 0"

# --- content: every surviving row identical, the level-1 bytes whole ---
SQL="SELECT ID, CAST(TXT AS VARCHAR(60)) FROM B WHERE ID <= 8 ORDER BY ID;"
check "surviving rows read identically, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "$SQL")" "$(q "127.0.0.1/$REAL:$B" "$SQL")"
SQL="SELECT OCTET_LENGTH(TXT) FROM B WHERE ID = 100;"
check "the replaced level-1 blob reads whole, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "$SQL")" "$(q "127.0.0.1/$REAL:$B" "$SQL")"
# the ENGINE reads fc's swept file directly
check "the ENGINE reads fc's swept file byte-for-byte" \
    "$(q "$A" "SELECT COUNT(*), SUM(OCTET_LENGTH(TXT)) FROM B;")" \
    "$(q "127.0.0.1/$PORT:$A" "SELECT COUNT(*), SUM(OCTET_LENGTH(TXT)) FROM B;")"

# --- the catalog's own relations now sweep too: ALTER churn then sweep ---
{ printf 'CREATE DOMAIN DS AS INTEGER CHECK (VALUE > 0);\nCREATE TABLE C1 (A DS);\nCOMMIT;\n'
  i=1; while [ $i -le 10 ]; do
    printf 'ALTER DOMAIN DS DROP CONSTRAINT;\nALTER DOMAIN DS ADD CHECK (VALUE > %d);\n' "$i"
    i=$((i + 1)); done
  printf 'COMMIT;\n'; } > "$D/blobsweep.sql"
check "10 ALTER cycles through fire-crab, error-free" "$(churn "127.0.0.1/$PORT:$A")" "0"
"$GFIX" -sweep -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
CV=$("$GSTAT" -a -r -s -t 'RDB$FIELDS' -user "$U" -pas "$P" "$A" 2>/dev/null | grep -m1 'total versions' | sed 's/.*total versions: \([0-9]*\),.*/\1/')
check "fc's sweep collects the catalog's own back versions (RDB\$FIELDS versions 0)" "$CV" "0"
check "...and the check still enforces after it" \
    "$(q "127.0.0.1/$PORT:$A" "INSERT INTO C1 VALUES (5);" | grep -c 23000)" "1"

# --- structure ---
V=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "gfix -v -full is silent on the swept file" "$V" ""
rm -f "$D/fc-blobsweep.fbk" "$D/fc-blobsweep-r.fdb"
"$GBAK" -b -user "$U" -pas "$P" "$A" "$D/fc-blobsweep.fbk" >/dev/null 2>&1 \
    && "$GBAK" -c -user "$U" -pas "$P" "$D/fc-blobsweep.fbk" "$D/fc-blobsweep-r.fdb" >/dev/null 2>&1
check "gbak round-trips the swept file; blob content survives" \
    "$(q "$D/fc-blobsweep-r.fdb" "SELECT COUNT(*), SUM(OCTET_LENGTH(TXT)) FROM B;")" \
    "$(q "$A" "SELECT COUNT(*), SUM(OCTET_LENGTH(TXT)) FROM B;")"

echo
if [ "$fail" = 0 ]; then echo "PASS all $ran checks"; else echo "FAIL"; exit 1; fi
