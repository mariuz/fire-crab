#!/bin/bash
# WHAT A ROLLBACK LEAVES BEHIND.
#
# This server used to undo a transaction by putting back the image the
# transaction started from - a rewrite of the whole database to undo two
# hundred rows, and a rewrite that would land on top of anybody else's
# committed work, which is why the write side had to be held from a
# transaction's first write to its end.
#
# With real transaction state a rollback is TWO BITS: `tra_dead` in the
# TIP. The rows stay on the pages, the index entries naming them stay in
# the trees, the pages allocated stay allocated - and none of it counts,
# because every reader walks past a version whose transaction it does
# not count to the one behind it. THAT IS WHAT THE ENGINE DOES TOO, and
# this gate holds fire-crab to the engine's own answers on all of it:
# the rows are gone, the file is valid, and the engine's own sweep
# collects the dead versions. (A plain SELECT often collects them too -
# Firebird's cooperative GC - but WHETHER it does is the engine's
# scheduling, so that one is reported and not asserted.)
#
# THE CARVE-OUT IS MEASURED, NOT ASSUMED. An image is still what undoes
# a DDL statement - this server's catalog rows are settled as they are
# written - and a ROLLBACK TO a mark, which asks a transaction to undo
# part of itself. The last section holds those.
#
#   qa/serve-real-undo.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4695}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-undo-crab.fdb"
B="$D/fc-undo-engine.fdb"
LOG="/tmp/fc-serve-undo-$PORT.log"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1, 'one');
INSERT INTO T VALUES (2, 'two');
COMMIT;
EOF
    chmod 666 "$1"
}

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1
    fi
}

rows() { # <db> - what the ENGINE finds
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
relid() { # <db>
    printf 'SET HEADING OFF;\nSELECT RDB$RELATION_ID FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = %s;\n' "'T'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
valid() { # <db>
    "$GFIX" -v -full -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}

# 200 inserts in one transaction, then COMMIT or ROLLBACK
BATCH='const F=require("node-firebird");
const Q=String.fromCharCode(39);
const o={host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
         user:"SYSDBA",password:"masterkey"};
F.attach(o,(e,d)=>{ if(e){console.log("ATTACH_FAIL");process.exit(1);}
  d.transaction(F.ISOLATION_READ_COMMITTED,(e2,t)=>{ if(e2){console.log("TX_FAIL");process.exit(1);}
    let i=100;
    const step=()=>{ if(i<300){ i++;
        t.query("INSERT INTO T VALUES ("+i+", "+Q+"x"+Q+")",()=>step());
      } else {
        const done=()=>{ console.log("done"); process.exit(0); };
        if(process.env.FC_END==="commit") t.commit(done); else t.rollback(done);
      } };
    step(); }); });'

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

# --- 1. THE ENGINE'S OWN ANSWERS, which are the target ------------------
make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
rel=$(relid "$B")
printf 'SET AUTODDL OFF;\nINSERT INTO T VALUES (101, %s);\nROLLBACK;\n' "'x'" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$B" >/dev/null 2>&1
check "ENGINE: a rolled-back INSERT leaves the table at 2 rows" "$(rows "$B")" "2"
check "ENGINE: and the file is valid" "$(valid "$B")" ""

# --- 2. FIRE-CRAB: the rows are gone, and they are still on the pages ---
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
live_before=$("$FCSTAT" versions "$A" "$rel" 2>/dev/null)
FC_PORT="$PORT" FC_DB="$A" FC_END=rollback timeout 120 node -e "$BATCH" >/dev/null 2>&1
# COUNTED BEFORE THE ENGINE IS LET NEAR THE FILE, because reading it
# CHANGES it - see below. All 200 rolled-back versions are on the pages:
# a rollback by transaction state writes two bits and leaves the rest.
after=$("$FCSTAT" versions "$A" "$rel" 2>/dev/null)
check "fc: every rolled-back version is still on the pages" "$after" "202"
# FIRE-CRAB'S OWN COUNT FIRST, because `SELECT COUNT(*)` with no filter
# takes a fast path that counts record HEADERS without decoding them -
# which was right only while every transaction in the file was
# committed. The rows a rollback leaves behind are still headers, and
# this is the check that says they are not rows.
fc_count=$(FC_PORT="$PORT" FC_DB="$A" timeout 60 node -e '
const F=require("node-firebird");
const o={host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
         user:"SYSDBA",password:"masterkey"};
F.attach(o,(e,d)=>{ if(e){console.log("ERR");process.exit(0);}
  d.query("SELECT COUNT(*) AS N FROM T",(e2,r)=>{
    console.log(e2?"ERR":String(r[0].N)); process.exit(0); }); });' 2>/dev/null)
check "fc: COUNT(*) counts rows, not the headers a rollback left" "$fc_count" "2"
check "fc: the ENGINE reads 2 rows after the rollback" "$(rows "$A")" "2"
check "fc: and gfix -v -full finds nothing wrong" "$(valid "$A")" ""
# ...AND THAT READ MAY HAVE COLLECTED THEM. Firebird garbage-collects
# COOPERATIVELY - a SELECT that walks past a dead version can take it
# with it - and measured here it usually does (202 versions down to 34).
# It is NOT asserted: whether a given read collects is the engine's own
# scheduling, and it has been observed collecting nothing. Reported so
# the number is visible; the law is the sweep below.
read_gc=$("$FCSTAT" versions "$A" "$rel" 2>/dev/null)
echo "note fc: after the engine's read, $after -> $read_gc versions (cooperative GC)"
# THE LAW: the engine's garbage collector treats a transaction fire-crab
# marked `tra_dead` exactly as it treats its own, and `gfix -sweep` says
# so every time.
"$GFIX" -sweep -user "$U" -pas "$P" "$A" >/dev/null 2>&1
swept=$("$FCSTAT" versions "$A" "$rel" 2>/dev/null)
check "fc: the engine's own sweep collects every rolled-back version" "$swept" "$live_before"
check "fc: and the table still reads 2 rows" "$(rows "$A")" "2"

# --- 3. COVERAGE: the rollback wrote a PAGE, not the database ----------
# The old undo put back the whole image with one fs::write. The new one
# flips two bits in the TIP, so the careful flush reports ONE page. If
# this ever reports the file again, the rollback is back to O(database).
pages=$(grep 'careful flush:' "$LOG" | tail -1 | sed -n 's/.*flush: \([0-9]*\) pages.*/\1/p')
ran=$((ran + 1))
if [ -n "$pages" ] && [ "$pages" -le 2 ]; then
    echo "OK   coverage: the rollback flushed $pages page(s), not the database"
else
    echo "DIFF coverage: the rollback flushed [$pages] pages"; fail=1
fi

# --- 4. TEETH: the same batch COMMITTED keeps its rows ------------------
# A gate that only ever asserts "the rows are gone" would pass against a
# server that never wrote them.
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
FC_PORT="$PORT" FC_DB="$A" FC_END=commit timeout 120 node -e "$BATCH" >/dev/null 2>&1
check "teeth: the same batch COMMITTED leaves 202 rows" "$(rows "$A")" "202"

# --- 5. THE CARVE-OUT: what an image still undoes -----------------------
# DDL is not transactional in this server - a catalog row is settled as
# it is written - so a rolled-back CREATE TABLE is undone by putting the
# image back, and this holds that it still is. Both servers run the same
# script with AUTODDL OFF, so the setting decides WHICH law is measured
# rather than which side wins.
ddl_rollback() { # <conn>
    printf 'SET AUTODDL OFF;\nCREATE TABLE ROLLED (X INTEGER);\nROLLBACK;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = %s;\n' "'ROLLED'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
make_db "$B" >/dev/null || { echo "FAIL scratch engine db"; exit 1; }
check "ENGINE: a rolled-back CREATE TABLE leaves no relation" "$(ddl_rollback "$B")" "0"
make_db "$A" >/dev/null || { echo "FAIL scratch crab db"; exit 1; }
check "fc: a rolled-back CREATE TABLE leaves no relation (the image path)" \
      "$(ddl_rollback "127.0.0.1/$PORT:$A")" "0"

# ...and a ROLLBACK TO a mark, which one transaction id cannot express
sp_rollback() { # <conn>
    printf 'INSERT INTO T VALUES (9, %s);\nSAVEPOINT S;\nINSERT INTO T VALUES (10, %s);\nROLLBACK TO S;\nCOMMIT;\n' "'a'" "'b'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "${2:-$1}" 2>&1 | tr -d ' \n'
}
make_db "$B" >/dev/null || { echo "FAIL scratch engine db"; exit 1; }
check "ENGINE: ROLLBACK TO a mark keeps the work before it" "$(sp_rollback "$B")" "3"
make_db "$A" >/dev/null || { echo "FAIL scratch crab db"; exit 1; }
check "fc: ROLLBACK TO a mark keeps the work before it (the image path)" \
      "$(sp_rollback "127.0.0.1/$PORT:$A" "$A")" "3"

# --- 6. THE KEY A ROLLED-BACK ROW LEFT IN THE INDEX ---------------------
# The entry is still in the tree - a rollback by transaction state
# removes nothing - so re-inserting the same primary key asks whether
# the uniqueness check reads ENTRIES or RECORDS. It must read records,
# and count only the ones this transaction sees: the rolled-back row is
# not one of them.
reuse_key() { # <conn> <read-conn>
    printf 'INSERT INTO T VALUES (5, %s);\nROLLBACK;\nINSERT INTO T VALUES (5, %s);\nCOMMIT;\n' "'a'" "'b'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    printf 'SET HEADING OFF;\nSELECT COUNT(*) || %s || MAX(S) FROM T WHERE ID = 5;\n' "'|'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "${2:-$1}" 2>&1 | tr -d ' \n'
}
make_db "$B" >/dev/null || { echo "FAIL scratch engine db"; exit 1; }
eng_reuse=$(reuse_key "$B")
check "ENGINE: a rolled-back key can be inserted again" "$eng_reuse" "1|b"
make_db "$A" >/dev/null || { echo "FAIL scratch crab db"; exit 1; }
check "fc: a rolled-back key can be inserted again" \
      "$(reuse_key "127.0.0.1/$PORT:$A" "$A")" "$eng_reuse"

echo "ran $ran checks"
exit $fail
