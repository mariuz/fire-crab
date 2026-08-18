#!/bin/bash
# A REAL COLLATION: WIN1252 COLLATE PXW_INTL, driven by the converted
# narrow collation driver (ods::coll, from the engine's own
# lc_narrow.cpp + pw1252intl.h tables).
#
# A collation is a KEY FUNCTION and a COMPARE FUNCTION. Before the
# driver, fire-crab answered a collated ORDER BY in char-code order
# ('A' < 'a', 'é' after 'z') and a collated WHERE range by the same
# wrong compare - silently, the worst kind. Now:
#
#   ORDER   the engine's order, measured live: a á A a-b ab aB Ab ab-
#           aé b e é ss ß st z - case and accents at the SECONDARY
#           level, the ß expansion losing its tie against 'ss'
#   WHERE   =, ranges and BETWEEN through the same keys ('a ' = 'a'
#           pads; 'a' <> 'A' holds - the collation orders, it does not
#           erase case)
#   KEYS    fire-crab's DML maintains the PXW_INTL index with the
#           engine's own key bytes - proven by the ENGINE's index scan
#           finding fc-written rows, equality and accent-blind range
#           alike, and gfix -v -full clean
#
#   qa/serve-real-collate.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4778}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-collate-re.fdb"; FC="$D/fc-collate-fc.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0; ran=0

mkdb() {
    rm -f "$1"
    "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE K (S VARCHAR(10) CHARACTER SET WIN1252 COLLATE PXW_INTL);
CREATE INDEX IDX_K ON K (S);
COMMIT;
INSERT INTO K VALUES ('a');
INSERT INTO K VALUES ('b');
INSERT INTO K VALUES ('A');
INSERT INTO K VALUES ('é');
INSERT INTO K VALUES ('e');
INSERT INTO K VALUES ('ab');
INSERT INTO K VALUES ('aé');
INSERT INTO K VALUES ('ß');
INSERT INTO K VALUES ('ss');
INSERT INTO K VALUES ('st');
INSERT INTO K VALUES ('a-b');
INSERT INTO K VALUES ('ab-');
INSERT INTO K VALUES ('Ab');
INSERT INTO K VALUES ('aB');
INSERT INTO K VALUES ('á');
INSERT INTO K VALUES ('z');
COMMIT;
EOF
    chmod 666 "$1"
}
mkdb "$RE" || { echo "FAIL scratch RE"; exit 1; }
mkdb "$FC" || { echo "FAIL scratch FC"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-collate.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }

node_q() { FC_DB="$FC" FC_PORT="$PORT" FC_Q="$1" timeout 30 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:"SYSDBA",password:"masterkey",encoding:"UTF8"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,(e2,r)=>{
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      if(Array.isArray(r)) for(const row of r)
        console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
      else console.log("OK");
      db.detach();process.exit(0);});});' 2>/dev/null
}
isql_q() { # <db> <sql>
    printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]\{1,\}/|/g; s/|$//' | grep -v '^$'
}
twin() { # <label> <sql>
    ran=$((ran + 1))
    a=$(node_q "$2")
    b=$(isql_q "$RE" "$2")
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: [$a]"
        echo "     engine: [$b]"
        fail=1
    fi
}

# --- 1. the ORDER, whole ------------------------------------------------
twin "ORDER BY answers the collation's order, all sixteen rows" \
     "SELECT S FROM K ORDER BY S"
twin "... and DESC walks it backwards" \
     "SELECT S FROM K ORDER BY S DESC"

# --- 2. the COMPARE family ---------------------------------------------
twin "equality pads ('a ' meets 'a')" "SELECT COUNT(*) FROM K WHERE S = 'a '"
twin "... but case holds ('a' <> 'A')" "SELECT COUNT(*) FROM K WHERE S = 'A'"
twin "a range takes the accents with their base letters" \
     "SELECT COUNT(*) FROM K WHERE S < 'b'"
twin "... and the ß expansion ties break the engine's way" \
     "SELECT COUNT(*) FROM K WHERE S >= 'ss'"
twin "BETWEEN under the collation" \
     "SELECT COUNT(*) FROM K WHERE S BETWEEN 'a' AND 'b'"
twin "the punctuation weight ('a-b' below 'ab', not equal to it)" \
     "SELECT COUNT(*) FROM K WHERE S < 'ab'"
twin "<> excludes exactly the padded match" \
     "SELECT COUNT(*) FROM K WHERE S <> 'a'"

# --- 2b. UPPER/LOWER by the COLLATION's own case tables ----------------
# the Paradox accent-stripping convention (ToUpperConversionTbl,
# transcribed and validated byte-for-byte against the live engine):
# UPPER('é') is 'E' where the default collation answers 'É'; LOWER
# keeps the accent; 'ß' and 'ƒ' have no pairs and nothing raises
twin "UPPER strips accents, LOWER keeps them - the collation's own tables" \
     "SELECT S, UPPER(S) AS U, LOWER(S) AS L FROM K ORDER BY S"

# --- 2c. a bound parameter adopts the collation ------------------------
node_qa() { FC_DB="$FC" FC_PORT="$PORT" FC_Q="$1" FC_A="$2" timeout 30 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:"SYSDBA",password:"masterkey",encoding:"UTF8"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,[process.env.FC_A],(e2,r)=>{
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      if(Array.isArray(r)) for(const row of r)
        console.log(Object.values(row).map(v=>String(v).replace(/\s+$/,"")).join("|"));
      else console.log("OK");
      db.detach();process.exit(0);});});' 2>/dev/null
}
ran=$((ran + 1))
a=$(node_qa "SELECT COUNT(*) FROM K WHERE S = ?" "a ")
if [ "$a" = "1" ]; then
    echo "OK   a bound 'a ' pads to the one 'a' row through the collation"
else
    echo "DIFF bound-param collated equality: [$a] (want 1)"
    fail=1
fi
ran=$((ran + 1))
a=$(node_qa "SELECT COUNT(*) FROM K WHERE S < ?" "b")
if [ "$a" = "9" ]; then
    echo "OK   a bound range compares by the collation (accents ride their bases)"
else
    echo "DIFF bound-param collated range: [$a] (want 9)"
    fail=1
fi

# --- 3. fire-crab WRITES, the ENGINE's index reads ---------------------
ran=$((ran + 1))
r=$(node_q "INSERT INTO K VALUES ('mésa')")
r2=$(node_q "INSERT INTO K VALUES ('Meta')")
if [ "$r" = "OK" ] && [ "$r2" = "OK" ]; then
    echo "OK   fc INSERTs through the PXW_INTL index"
else
    echo "DIFF collated-index DML: [$r] [$r2]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT S FROM K WHERE S = 'mésa'")
if [ "$got" = "mésa" ]; then
    echo "OK   the ENGINE finds fc's row by collated equality"
else
    echo "DIFF engine collated lookup: [$got]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT S FROM K WHERE S > 'mes' AND S < 'mf' ORDER BY S")
if [ "$got" = "mésa
Meta" ]; then
    echo "OK   ... and the accent-and-case-blind RANGE answers both fc rows"
else
    echo "DIFF engine collated range: [$got]"
    fail=1
fi
ran=$((ran + 1))
g=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$g" ]; then
    echo "OK   gfix -v -full finds nothing wrong with fc's collated keys"
else
    echo "DIFF gfix: $g"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC"
if [ "$ran" -lt 16 ]; then
    echo "DIFF only $ran checks ran (expected at least 16) - did one silently skip?"
    fail=1
fi
exit $fail
