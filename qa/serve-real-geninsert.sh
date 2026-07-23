#!/bin/bash
# INSERT ... VALUES (NEXT VALUE FOR <seq>) / (GEN_ID(<name>, <n>)) - an
# auto-id insert. At op_execute fire-crab advances the generator (by the
# sequence's own increment, or by the explicit step), persists the new
# SINT64 into the generator page, and STORES that value into the record's
# field - atomic with the record write, so the generator advance and the
# row land together or not at all. The stored id also flows into the
# primary-key index like any other value.
#
# THE differential is the real engine. The SAME insert script runs through
# BOTH fire-crab (node -> fcwire, WORK file) and the C++ engine (isql, REF
# file); then the engine OPENS BOTH files and must read identical rows and
# identical stored generator values. Auto-id inserts are ubiquitous, so
# getting the id the engine would have assigned - value-for-value - matters.
# gfix and gbak validate the fire-crab-written file structurally.
#
#   qa/serve-real-geninsert.sh [port]
#
# Builds its own scratch database (a table, a plain sequence, an
# INCREMENT BY 5 sequence, and a generator).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4087}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/geninsert_src.fdb"
WORK="/tmp/fc-geninsert-work.fdb"; REF="/tmp/fc-geninsert-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"; rm -f "$SRC" "$WORK" "$REF"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20));
CREATE SEQUENCE SEQ;
CREATE SEQUENCE SEQ5 START WITH 100 INCREMENT BY 5;
CREATE GENERATOR G;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-geninsert.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-geninsert-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# run one statement through fire-crab; <no rows> on a DML statement, rows
# on a SELECT, ERR on a raised SQL error
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() { # retry transient failures
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     want: $3"
        echo "     got:  $2"
        fail=1
    fi
}

# the identical insert script - run through fire-crab here, and through
# the engine (below) on REF. Every id is generator-derived.
INS1="INSERT INTO T (ID, NAME) VALUES (NEXT VALUE FOR SEQ, 'a')"
INS2="INSERT INTO T (ID, NAME) VALUES (NEXT VALUE FOR SEQ, 'b')"
INS3="INSERT INTO T (ID, NAME) VALUES (GEN_ID(G, 5), 'c')"
INS4="INSERT INTO T (ID, NAME) VALUES (GEN_ID(G, 5), 'd')"
INS5="INSERT INTO T (ID, NAME) VALUES (NEXT VALUE FOR SEQ5, 'e')"

# --- phase 1: write through fire-crab, read back through fire-crab ---
check "insert NEXT VALUE FOR (a)" "$(node_run "$INS1")" "<no rows>"
check "insert NEXT VALUE FOR (b)" "$(node_run "$INS2")" "<no rows>"
check "insert GEN_ID(G,5) (c)"    "$(node_run "$INS3")" "<no rows>"
check "insert GEN_ID(G,5) (d)"    "$(node_run "$INS4")" "<no rows>"
check "insert NEXT VALUE FOR SEQ5 (e)" "$(node_run "$INS5")" "<no rows>"
# the ids the engine would have assigned: SEQ 1,2 ; G +5 -> 5,10 ; SEQ5 100
check "fire-crab reads its auto-ids" \
    "$(node_run "SELECT ID, NAME FROM T ORDER BY ID")" \
"1|a
2|b
5|c
10|d
100|e"

# --- phase 2: run the SAME script through the engine on REF ---
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$INS1;
$INS2;
$INS3;
$INS4;
$INS5;
COMMIT;
EOF

# the engine reads rows and generator values from BOTH files - identical
rows_of() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || TRIM(NAME) FROM T ORDER BY ID;
SQL
}
gens_of() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -oE '[-0-9]+'
SET HEADING OFF;
SELECT GEN_ID(SEQ,0) || '|' || GEN_ID(SEQ5,0) || '|' || GEN_ID(G,0) FROM RDB$DATABASE;
SQL
}
check "ENGINE reads identical rows from both files" "$(rows_of "$WORK")" "$(rows_of "$REF")"
check "ENGINE reads identical generator state"      "$(gens_of "$WORK")" "$(gens_of "$REF")"
# and the concrete expected values, so a both-wrong bug can't pass
check "stored rows are the engine's ids" "$(rows_of "$WORK")" \
"1|a
2|b
5|c
10|d
100|e"

# --- phase 3: engine-side structural validation ---
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full finds nothing wrong" "$(printf '%s' "$val" | strip)" ""
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-geninsert-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi

exit $fail
