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
CREATE TABLE E (ID INTEGER NOT NULL, A INTEGER, B INTEGER, S VARCHAR(10), N NUMERIC(9,2), M NUMERIC(9,4));
COMMIT;
INSERT INTO E VALUES (1, 10, 3, 'x', 12.50, 1.2345);
INSERT INTO E VALUES (2, 5, 100, 'y', -3.25, 4.0000);
INSERT INTO E VALUES (3, NULL, 7, 'z', NULL, 2.0000);
INSERT INTO E VALUES (4, -8, 2, 'w', 13.50, 0.5000);
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

# node-firebird renders a NUMERIC as a JavaScript number, dropping the
# trailing zeros isql keeps (25.00 -> 25, 156.2500 -> 156.25). Strip
# trailing zeros from pure-decimal fields on BOTH sides so the display
# artifact does not fail the compare - a WRONG scale still changes the
# significant digits and is caught (25 vs 0.25 vs 2500). Only decimal-
# looking fields are touched, so text/CAST values stay exact.
denum() {
    awk -F'|' '{
        for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]+\.[0-9]+$/) {
            sub(/0+$/, "", $i); sub(/\.$/, "", $i)
        }
        s=$1; for (i=2;i<=NF;i++) s=s"|"$i; print s
    }'
}

# a numeric-normalizing compare for the arithmetic block (values compared
# up to trailing-zero display; column HEADERS still compared exactly)
comparen() { # <label> <select>
    fc=$(node_run "$2" | denum | sort)
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING ON;
$2;
EOF
)
    is=$(printf '%s\n' "$is" | awk '
        /^=+/ { next }
        NR==1 { gsub(/[ \t]+/,"|"); print "H:" $0; next }
        { gsub(/^[ \t]+|[ \t]+$/,""); gsub(/[ \t]+/,"|"); print }
    ' | denum | sort)
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

# --- integer division (truncates toward zero, named DIVIDE) ------------
compare "divide columns"    "SELECT A / B FROM E WHERE ID = 1"
compare "divide truncates"  "SELECT A / B FROM E WHERE ID = 2"
compare "divide negative"   "SELECT A / B FROM E WHERE ID = 4"
compare "divide toward zero" "SELECT B / A FROM E WHERE ID = 4"
compare "divide literal"    "SELECT 7 / 2 FROM E WHERE ID = 1"
compare "divide NULL"       "SELECT A / B FROM E WHERE ID = 3"
compare "divide then mul"   "SELECT A / B * 2 FROM E WHERE ID = 1"

# --- string concatenation (|| binds tighter, named CONCATENATION) ------
compare "concat columns"    "SELECT S || S FROM E WHERE ID = 1"
compare "concat literal"    "SELECT S || '!' FROM E WHERE ID = 1"
compare "concat both sides" "SELECT '[' || S || ']' FROM E WHERE ID = 2"
compare "concat coerces int" "SELECT A || 'n' FROM E WHERE ID = 1"
compare "concat chains left" "SELECT 'a' || 'b' || 'c' FROM E WHERE ID = 1"
compare "concat NULL"       "SELECT S || NULL FROM E WHERE ID = 1"

# --- CAST(x AS type): integer family and text width, over int/text -----
compare "cast int to varchar" "SELECT CAST(A AS VARCHAR(20)) FROM E WHERE ID = 1"
compare "cast int to char"    "SELECT CAST(A AS CHAR(5)) FROM E WHERE ID = 1"
compare "cast string to int"  "SELECT CAST('100' AS INTEGER) FROM E WHERE ID = 1"
compare "cast trims to int"   "SELECT CAST(' 55 ' AS INTEGER) FROM E WHERE ID = 1"
compare "cast to bigint"      "SELECT CAST(A AS BIGINT) FROM E WHERE ID = 1"
compare "cast to smallint"    "SELECT CAST(A AS SMALLINT) FROM E WHERE ID = 2"
compare "cast negative"       "SELECT CAST(A AS VARCHAR(10)) FROM E WHERE ID = 4"
compare "cast of expr"        "SELECT CAST(A + B AS VARCHAR(10)) FROM E WHERE ID = 1"
compare "cast then concat"    "SELECT CAST(A AS VARCHAR(4)) || '!' FROM E WHERE ID = 1"
compare "cast NULL"           "SELECT CAST(A AS VARCHAR(5)) FROM E WHERE ID = 3"
compare "cast aliased"        "SELECT CAST(A AS INTEGER) AS X FROM E WHERE ID = 1"

# --- CAST over a scaled NUMERIC column: round to int (half away from
#     zero), render with decimals to text (the deferred item now done) ---
compare "cast numeric round up"   "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 1"
compare "cast numeric half to 14" "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 4"
compare "cast numeric neg below"  "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 2"
compare "cast numeric to varchar" "SELECT CAST(N AS VARCHAR(10)) FROM E WHERE ID = 1"
compare "cast numeric neg varchar" "SELECT CAST(N AS VARCHAR(10)) FROM E WHERE ID = 2"
compare "cast numeric NULL"       "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 3"

# --- numeric arithmetic: the engine's dialect-3 scale rules ------------
#     +/- take the finer scale, * and / add the two scales (/ scales the
#     dividend by 10^(-2*s2) then truncates). Column headers ADD/SUBTRACT/
#     MULTIPLY/DIVIDE and values (with their decimal places) both compared.
comparen "num add same scale"   "SELECT N + N AS R FROM E WHERE ID = 1"
comparen "num add finer scale"  "SELECT N + M AS R FROM E WHERE ID = 1"
comparen "num sub"              "SELECT N - M AS R FROM E WHERE ID = 1"
comparen "num add int col"      "SELECT N + A AS R FROM E WHERE ID = 1"
comparen "num add int literal"  "SELECT N + 1 AS R FROM E WHERE ID = 1"
comparen "num mul same scale"   "SELECT N * N AS R FROM E WHERE ID = 1"
comparen "num mul finer scale"  "SELECT N * M AS R FROM E WHERE ID = 1"
comparen "num mul int"          "SELECT N * A AS R FROM E WHERE ID = 1"
comparen "num mul literal"      "SELECT N * 2 AS R FROM E WHERE ID = 1"
comparen "num div same scale"   "SELECT N / M AS R FROM E WHERE ID = 2"
comparen "num div finer scale"  "SELECT N / M AS R FROM E WHERE ID = 1"
comparen "num div int col"      "SELECT N / A AS R FROM E WHERE ID = 1"
comparen "num div literal"      "SELECT N / 4 AS R FROM E WHERE ID = 1"
comparen "num precedence"       "SELECT N + M * 2 AS R FROM E WHERE ID = 1"
comparen "num negate"           "SELECT -N AS R FROM E WHERE ID = 1"
comparen "num header default"   "SELECT N * M FROM E WHERE ID = 1"
comparen "num NULL propagates"  "SELECT N * M AS R FROM E WHERE ID = 3"

# --- decimal literals: scale = written fractional digits (trailing zeros
#     count), and they arithmetic-combine like any numeric operand -------
comparen "declit add"          "SELECT N + 1.5 AS R FROM E WHERE ID = 1"
comparen "declit trailing zero" "SELECT N + 1.50 AS R FROM E WHERE ID = 1"
comparen "declit mul"          "SELECT N * 1.5 AS R FROM E WHERE ID = 1"
comparen "declit div"          "SELECT N / 1.5 AS R FROM E WHERE ID = 1"
comparen "declit both literals" "SELECT 1.5 + 2.25 AS R FROM E WHERE ID = 1"
comparen "declit times int"    "SELECT 1.5 * 2 AS R FROM E WHERE ID = 1"
comparen "declit bare"         "SELECT 1.5 AS R FROM E WHERE ID = 1"

# --- runtime errors: BOTH the engine and fire-crab reject the row rather
#     than answering. Divide-by-zero is the arithmetic exception (SQLSTATE
#     22012); a bad or too-long CAST is the conversion error (22018).
errck() { # <label> <select> <isql-error-pattern>
    fc=$(node_run "$2")
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF
$2;
EOF
)
    if printf '%s' "$fc" | grep -qi "ERR" \
       && printf '%s' "$is" | grep -qi "$3"; then
        echo "OK   $1 (both reject)"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}
errck "divide by zero literal" "SELECT A / 0 FROM E WHERE ID = 1"          "divide by zero"
errck "divide by zero column"  "SELECT A / (B - B) FROM E WHERE ID = 1"    "divide by zero"
errck "cast bad string"        "SELECT CAST(S AS INTEGER) FROM E WHERE ID = 1"   "conversion error"
errck "cast too long"          "SELECT CAST(A AS VARCHAR(1)) FROM E WHERE ID = 1" "conversion error"

exit $fail
