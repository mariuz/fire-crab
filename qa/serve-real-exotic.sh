#!/bin/bash
# INT128 and DECFLOAT decode + native wire transport. Two differentials:
#
#   1. RENDER: `fcstat rows` (Value::render - INT128 scaled like any
#      exact numeric, DECFLOAT via the from-scratch decimal64/128 DPD
#      decode and decNumberToString) must equal isql's own text for the
#      same rows - including preserved cohort (100.00 keeps its zeros),
#      the plain/scientific boundary (0.000001 vs 1E-7), 38-digit
#      INT128, and 34-digit DECFLOAT(34);
#   2. WIRE: node-firebird receives SQL_INT128/SQL_DEC16/SQL_DEC34 in
#      the engine's native XDR forms (16-byte BE int128, BE decimal64/
#      128 words) and its typed decode must match isql. ORDER BY on
#      these columns must sort numerically (100.00 after 1.5, which
#      lexicographic ordering would invert).
#
# Values are chosen to dodge three node-firebird CLIENT bugs that break
# against any server: readInt128 reads the high half unsigned (negative
# INT128 decodes wrong), scale-0 BigInt formatting slices at -0 (huge
# scale-0 values decode wrong), and decodeDecimal64/128 read the DPD
# coefficient as plain binary (any multi-digit coefficient mis-decodes;
# single-digit ones coincide in both encodings). The render
# differential carries the full-fidelity cases instead.
#
#   qa/serve-real-exotic.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4063}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/exotic_src.fdb"; CLEAN="$DIR/exotic_clean.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE X (ID INTEGER, I128 NUMERIC(38,0), N38 NUMERIC(38,4), D16 DECFLOAT(16), D34 DECFLOAT(34));
COMMIT;
INSERT INTO X VALUES (1, 4242, 123456789012345.6789, 1.5, 1.5);
INSERT INTO X VALUES (2, 9007199254740000, 0.0001, 100.00, 1234567890123456789012345678.9012);
INSERT INTO X VALUES (3, NULL, NULL, NULL, NULL);
INSERT INTO X VALUES (4, 12345678901234567890123456789012345678, -999.9999, 1E-7, 0.000001);
INSERT INTO X VALUES (5, 7, -42, -2.5, 1E+3);
INSERT INTO X VALUES (6, NULL, NULL, 0.5, 9);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/exotic.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/exotic.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$CLEAN" | strip | grep -v '^$'
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

# --- differential 1: fcstat's rendered rows == isql's text -------------
rel_id=$(isql_q "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'X';" | tr -d ' ')
check "render: fcstat rows == isql (cohorts, boundaries, negatives)" \
    "$("$FCSTAT" rows "$CLEAN" "$rel_id" | tr '\t' '|' | sort)" \
    "$(isql_q "SELECT COALESCE(CAST(I128 AS VARCHAR(50)),'<null>') || '|' || COALESCE(CAST(N38 AS VARCHAR(50)),'<null>') || '|' || COALESCE(CAST(D34 AS VARCHAR(50)),'<null>') || '|' || COALESCE(CAST(D16 AS VARCHAR(50)),'<null>') || '|' || ID FROM X;" | sort)"

# --- differential 2: native wire types through node-firebird -----------
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exotic.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

node_once() {
    FC_DB="$CLEAN" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
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
node_run() {
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

check "wire: INT128 (positive, JS-safe range)" \
    "$(node_run "SELECT ID, I128 FROM X WHERE ID = 1 OR ID = 2 OR ID = 5 ORDER BY ID")" \
    "$(isql_q "SELECT ID || '|' || I128 FROM X WHERE ID IN (1,2,5) ORDER BY ID;")"
check "wire: NUMERIC(38,4) - scaled int128, string path over 2^53" \
    "$(node_run "SELECT ID, N38 FROM X WHERE ID = 1 OR ID = 2 ORDER BY ID")" \
    "$(isql_q "SELECT ID || '|' || N38 FROM X WHERE ID IN (1,2) ORDER BY ID;")"
# single-digit coefficients only: node's decodeDecimal64/128 read the
# DPD declets as binary, so anything wider mis-decodes client-side (the
# render differential above covers the full shapes)
check "wire: DECFLOAT(16) and DECFLOAT(34)" \
    "$(node_run "SELECT ID, D16, D34 FROM X WHERE ID = 6 ORDER BY ID")" \
    "$(isql_q "SELECT ID || '|' || D16 || '|' || D34 FROM X WHERE ID = 6;")"
check "wire: the all-NULL row" \
    "$(node_run "SELECT I128, N38, D16, D34 FROM X WHERE ID = 3")" \
    "<null>|<null>|<null>|<null>"
check "ORDER BY INT128 sorts numerically" \
    "$(node_run "SELECT ID FROM X ORDER BY I128, ID")" \
    "$(isql_q "SELECT ID FROM X ORDER BY I128, ID;" | tr -d ' ')"
check "ORDER BY DECFLOAT sorts numerically (not lexically)" \
    "$(node_run "SELECT ID FROM X ORDER BY D16, ID")" \
    "$(isql_q "SELECT ID FROM X ORDER BY D16, ID;" | tr -d ' ')"
exit $fail
