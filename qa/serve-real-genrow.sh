#!/bin/bash
# NEXT VALUE FOR <seq> / GEN_ID(<name>, <n>) in the SELECT LIST of a
# ROW-RETURNING query - one generator advance PER ROW, mid-fetch. Unlike
# the single-row RDB$DATABASE form (serve-real-genstep), here the SELECT
# walks a real table and each emitted row advances the generator and
# carries the new value. The engine evaluates it during FETCH, in OUTPUT
# order (after any ORDER BY), so with `ORDER BY X` the value follows the
# sorted output, not the scan order.
#
# THE differential is the engine. The SAME query runs through BOTH
# fire-crab (node -> fcwire, WORK) and the C++ engine (isql, REF); the
# per-row values must match value-for-value AND the stored generator value
# afterwards must match. gfix validates the file.
#
#   qa/serve-real-genrow.sh [port]
#
# Builds its own scratch database (a 3-row table with UNSORTED keys - so
# scan order differs from sorted order - a plain sequence, an INCREMENT
# BY 5 sequence, and a generator).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4093}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/genrow_src.fdb"
WORK="/tmp/fc-genrow-work.fdb"; REF="/tmp/fc-genrow-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"; rm -f "$SRC" "$WORK" "$REF"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE SRC (X INTEGER);
CREATE SEQUENCE SEQ;
CREATE SEQUENCE SEQ5 START WITH 100 INCREMENT BY 5;
CREATE GENERATOR G;
COMMIT;
INSERT INTO SRC VALUES (30);
INSERT INTO SRC VALUES (10);
INSERT INTO SRC VALUES (20);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-genrow.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# run one SELECT through fire-crab; print each row's columns pipe-joined,
# one row per line (values in select-list order)
fc_rows() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
          process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(1);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR");db.detach();process.exit(0);}
              if(!r||!r.length)console.log("<none>");
              else for(const row of r)console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
              db.detach();process.exit(0);});
          });' 2>/dev/null)
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
# run one SELECT through the engine (isql) on REF; same pipe-joined shape.
# Build the pipe string in SQL so column widths do not matter.
en_rows() { # <select-cols> <from/order tail>
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL | strip | grep -v '^$'
SET HEADING OFF;
$1;
SQL
}
# read a generator's stored value from a file through the engine
gen_of() { # <file> <gen>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -oE '[-0-9]+' | head -1
SET HEADING OFF;
SELECT GEN_ID($2, 0) FROM RDB\$DATABASE;
SQL
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ] && [ -n "$2" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1
    fi
}

# 1) no ORDER BY: one advance per row in scan order. fc must equal the
#    engine row-for-row (both walk the same file the same way).
Q1="SELECT NEXT VALUE FOR SEQ, X FROM SRC"
check "NEXT VALUE FOR, no order (per-row vs engine)" \
    "$(fc_rows "$Q1")" "$(en_rows "SELECT (NEXT VALUE FOR SEQ) || '|' || X FROM SRC")"
# 2) ORDER BY X: the value follows OUTPUT order (X 10,20,30 -> 4,5,6 after
#    the two rows SEQ already advanced above)
Q2="SELECT NEXT VALUE FOR SEQ, X FROM SRC ORDER BY X"
check "NEXT VALUE FOR, ORDER BY X (output order)" \
    "$(fc_rows "$Q2")" "$(en_rows "SELECT (NEXT VALUE FOR SEQ) || '|' || X FROM SRC ORDER BY X")"
# 3) GEN_ID with a step, ORDER BY DESC
Q3="SELECT GEN_ID(SEQ5, 5), X FROM SRC ORDER BY X DESC"
check "GEN_ID(SEQ5,5), ORDER BY X DESC" \
    "$(fc_rows "$Q3")" "$(en_rows "SELECT GEN_ID(SEQ5, 5) || '|' || X FROM SRC ORDER BY X DESC")"
# 4) WHERE filters rows before the advance count (only matching rows bump)
Q4="SELECT GEN_ID(G, 1), X FROM SRC WHERE X > 15 ORDER BY X"
check "GEN_ID(G,1) with WHERE (only matching rows advance)" \
    "$(fc_rows "$Q4")" "$(en_rows "SELECT GEN_ID(G, 1) || '|' || X FROM SRC WHERE X > 15 ORDER BY X")"

# stored generator values must match the engine's. WORK advanced once per
# fc query above; REF advanced once per en_rows query in the SAME order
# (same generators, same steps, same row counts) - so they are in lockstep
# and no replay is needed (replaying would double-advance REF).
kill $srv 2>/dev/null; wait $srv 2>/dev/null
for g in SEQ SEQ5 G; do
    check "stored $g matches engine" "$(gen_of "$WORK" "$g")" "$(gen_of "$REF" "$g")"
done

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
if [ -z "$(printf '%s' "$val" | strip)" ]; then
    echo "OK   gfix -v -full clean"
else
    echo "DIFF gfix -v -full"; echo "     $val"; fail=1
fi

exit $fail
