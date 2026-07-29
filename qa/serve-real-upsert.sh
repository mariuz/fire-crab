#!/bin/bash
# UPDATE OR INSERT INTO <t> (cols) VALUES (...) [MATCHING (cols)] - the
# engine's upsert, desugared at prepare into the UPDATE and INSERT plans
# fire-crab already runs: try the update whose WHERE is the MATCHING
# columns, and store when no row moved (StmtNodes.cpp UpdateOrInsertNode's
# own execution plan). The MATCHING list defaults to the table's PRIMARY
# KEY columns - and a PK-less table without MATCHING must refuse AT
# PREPARE with the engine's exact vector: isc_dsql_error +
# isc_primary_key_required, "Primary key required on table @1", SQLSTATE
# 22000. Announcing the generic Dynamic SQL Error there would hide the
# one line that tells the user WHAT to fix.
#
# THE differential is the real engine. The SAME upsert script runs through
# BOTH fire-crab (node -> fcwire, WORK file) and the C++ engine (isql, REF
# file); then the engine OPENS BOTH files and must read identical rows.
# gfix and gbak validate the fire-crab-written file structurally.
#
#   qa/serve-real-upsert.sh [port]
#
# Builds its own scratch database (a PK-less table, a single-column PK
# table, and a two-column PK table for the implicit MATCHING list).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4093}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/upsert_src.fdb"
WORK="/tmp/fc-upsert-work.fdb"; REF="/tmp/fc-upsert-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"; rm -f "$SRC" "$WORK" "$REF"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE NOPK (A INTEGER, B VARCHAR(10));
CREATE TABLE WPK (A INTEGER NOT NULL PRIMARY KEY, B VARCHAR(10));
CREATE TABLE MPK (A INTEGER NOT NULL, B INTEGER NOT NULL, C VARCHAR(10),
                  PRIMARY KEY (A, B));
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-upsert.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-upsert-work.fbk' EXIT
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

# the identical upsert script - run through fire-crab here, and through
# the engine (below) on REF
S1="UPDATE OR INSERT INTO WPK (A, B) VALUES (1, 'one')"
S2="UPDATE OR INSERT INTO WPK (A, B) VALUES (1, 'uno')"
S3="UPDATE OR INSERT INTO WPK (A, B) VALUES (2, 'two')"
S4="UPDATE OR INSERT INTO NOPK (A, B) VALUES (7, 'seven') MATCHING (A)"
S5="UPDATE OR INSERT INTO NOPK (A, B) VALUES (7, 'SEVEN') MATCHING (A)"
S6="UPDATE OR INSERT INTO MPK (A, B, C) VALUES (1, 1, 'x')"
S7="UPDATE OR INSERT INTO MPK (A, B, C) VALUES (1, 2, 'y')"
S8="UPDATE OR INSERT INTO MPK (A, B, C) VALUES (1, 2, 'z')"

# --- phase 1: write through fire-crab, read back through fire-crab ---
check "upsert-insert on the PK table"      "$(node_run "$S1")" "<no rows>"
check "upsert-update on the PK table"      "$(node_run "$S2")" "<no rows>"
check "upsert-insert of a second key"      "$(node_run "$S3")" "<no rows>"
check "MATCHING insert on the PK-less table" "$(node_run "$S4")" "<no rows>"
check "MATCHING update on the PK-less table" "$(node_run "$S5")" "<no rows>"
check "two-column implicit PK, first key"  "$(node_run "$S6")" "<no rows>"
check "two-column implicit PK, second key" "$(node_run "$S7")" "<no rows>"
check "two-column implicit PK, update"     "$(node_run "$S8")" "<no rows>"
check "fire-crab reads the upserted rows" \
    "$(node_run "SELECT A, B FROM WPK ORDER BY A")" \
"1|uno
2|two"
check "fire-crab reads the MATCHING row" \
    "$(node_run "SELECT A, B FROM NOPK")" \
"7|SEVEN"
check "fire-crab reads the two-column rows" \
    "$(node_run "SELECT A, B, C FROM MPK ORDER BY A, B")" \
"1|1|x
1|2|z"
# without MATCHING on a PK-less table: the engine's SPECIFIC error at
# prepare - the one line that names what is missing
err=$(node_run "UPDATE OR INSERT INTO NOPK (A, B) VALUES (1, 'x')")
case "$err" in
    ERR*"Primary key required on table"*)
        echo "OK   PK-less upsert without MATCHING raises the engine's error" ;;
    *)
        echo "DIFF PK-less upsert without MATCHING raises the engine's error"
        echo "     got: $err"; fail=1 ;;
esac
# ...and the error left no row behind
check "the refused upsert wrote nothing" \
    "$(node_run "SELECT COUNT(*) FROM NOPK")" "1"

# --- phase 2: run the SAME script through the engine on REF ---
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$S1;
$S2;
$S3;
$S4;
$S5;
$S6;
$S7;
$S8;
COMMIT;
EOF

# the engine reads rows from BOTH files - identical
rows_of() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A || '|' || TRIM(B) FROM WPK ORDER BY A;
SELECT A || '|' || TRIM(B) FROM NOPK;
SELECT A || '|' || B || '|' || TRIM(C) FROM MPK ORDER BY A, B;
SQL
}
check "ENGINE reads identical rows from both files" "$(rows_of "$WORK")" "$(rows_of "$REF")"
# and the concrete expected values, so a both-wrong bug can't pass
check "stored rows are the engine's" "$(rows_of "$WORK")" \
"1|uno
2|two
7|SEVEN
1|1|x
1|2|z"

# --- phase 3: engine-side structural validation ---
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full finds nothing wrong" "$(printf '%s' "$val" | strip)" ""
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-upsert-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi

exit $fail
