#!/bin/bash
# SELECT-LIST EXPRESSIONS: arithmetic (+, -, *, unary -, parens) over
# integer columns and literals, and constant literals, in the select
# list - SELECT A + B, A * 2, -A, 1 + 1 FROM t. The server evaluates
# each expression per decoded row, propagating NULL through arithmetic
# (SQL three-valued), and describes the result as BIGINT. The un-aliased
# output column takes the engine's own operation name (ADD / SUBTRACT /
# MULTIPLY / NEGATE / CONSTANT), which is why the differential below can
# compare the isql column HEADER too, not just the values.
#
# The oracle is the engine: every query runs IDENTICALLY through
# fire-crab (node-firebird) and through isql on the same file, values
# and column names compared.
#
#   qa/serve-real-selectexpr.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4092}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/selexpr_src.fdb"; CLEAN="$DIR/selexpr_clean.fdb"
WORK="/tmp/fc-selexpr-work.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE E (ID INTEGER NOT NULL, A INTEGER, B INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO E VALUES (1, 10, 3, 'x');
INSERT INTO E VALUES (2, 5, 100, 'y');
INSERT INTO E VALUES (3, NULL, 7, 'z');
INSERT INTO E VALUES (4, -8, 2, 'w');
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" "$SRC" >/dev/null 2>&1 <<'EOF'
COMMIT;
EOF
cp "$SRC" "$CLEAN"; cp "$CLEAN" "$WORK"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-selexpr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

# node: run <query>, print header (column titles) then each row, values
# joined by '|', so both the column NAME and the values are compared
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(r&&r.length) console.log("H:"+Object.keys(r[0]).join("|"));
          for(const row of (r||[]))
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

fail=0
# compare fire-crab and isql on the SAME select. isql prints the column
# header (titles) which we prefix H: to match node's header line, then
# the rows; both sides sorted so row order is not under test here.
compare() { # <label> <select>
    fc=$(node_run "$2" | sort)
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING ON;
$2;
EOF
)
    # turn isql's "===" underline + header into H:col|col, values below
    is=$(printf '%s\n' "$is" | awk '
        /^=+/ { next }
        NR==1 { gsub(/[ \t]+/,"|"); print "H:" $0; next }
        { gsub(/^[ \t]+|[ \t]+$/,""); gsub(/[ \t]+/,"|"); print }
    ' | sort)
    if [ "$fc" = "$is" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}

# --- arithmetic over columns -------------------------------------------
compare "add columns"       "SELECT A + B FROM E WHERE ID = 1"
compare "subtract columns"  "SELECT A - B FROM E WHERE ID = 2"
compare "multiply column"   "SELECT A * 2 FROM E WHERE ID = 1"
compare "precedence * over +" "SELECT A + B * 2 FROM E WHERE ID = 1"
compare "parens override"   "SELECT (A + B) * 2 FROM E WHERE ID = 1"
# unary minus: aliased so both sides carry a comparable header (the
# un-aliased engine header for -A is blank, which isql prints as spaces
# that the harness strips - a display artifact, not a value difference)
compare "unary minus"       "SELECT -A AS NEG FROM E WHERE ID = 4"
compare "column then expr"  "SELECT A, A * B FROM E WHERE ID = 2"
compare "NULL propagates"   "SELECT A + B FROM E WHERE ID = 3"
compare "nested"            "SELECT A * B - A FROM E WHERE ID = 1"

# --- constant literals -------------------------------------------------
compare "int literal"       "SELECT 1 + 1 FROM E WHERE ID = 1"
compare "literal times col" "SELECT 3 * A FROM E WHERE ID = 1"

# --- aliases -----------------------------------------------------------
compare "aliased expr"      "SELECT A + B AS TOTAL FROM E WHERE ID = 1"
compare "aliased mult"      "SELECT A * B AS PROD FROM E WHERE ID = 2"

# --- multiple expression columns + a plain column ----------------------
compare "mixed columns"     "SELECT ID, A + B, A - B FROM E WHERE ID = 1"

exit $fail
