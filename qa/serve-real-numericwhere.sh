#!/bin/bash
# WHERE predicates over scaled NUMERIC/DECIMAL and INT128 columns - the
# surface col_kind never classified (statements fell back to the fixed
# answer). Comparisons now decompose both sides into (raw, scale) and
# align exactly in i128 - the engine's dialect-3 compare - so integer
# and decimal literals, BETWEEN/IN desugarings, NULL tests, NOT, and
# `?` parameters (bound with their wire scale) all work; decimal
# literals also work against plain INT columns (A > 9.5), and INSERT /
# UPDATE SET take decimal literals that rescale exactly into their
# target (1.5 -> NUMERIC(9,2) 1.50; 1.5 into an INTEGER refuses - the
# engine rounds there, fire-crab never writes an inexact value).
#
# The differential is the engine, three ways:
#   1. every predicate runs through fire-crab (node) AND through isql
#      on the SAME file, selecting the integer ID only - identical row
#      sets, no render normalization in the way;
#   2. fire-crab UPDATEs and DELETEs through numeric predicates and
#      INSERTs decimal literals; the engine mirrors on a ref copy and
#      the tables match;
#   3. gbak round trip and gfix -v -full.
#
#   qa/serve-real-numericwhere.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4289}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-numw-work.fdb"; REF="$D/fc-numw-ref.fdb"
FBK="$D/fc-numw-work.fbk"; RST="$D/fc-numw-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE TABLE T (ID INTEGER, A INTEGER, N NUMERIC(9,2), M NUMERIC(18,4), I INT128);
COMMIT;
INSERT INTO T VALUES (1, 10, 12.50, 0.0001, 42);
INSERT INTO T VALUES (2, 3, -1.25, 7.0000, -5000000000);
INSERT INTO T VALUES (3, 9, NULL, 123.4567, NULL);
INSERT INTO T VALUES (4, -8, 2.00, NULL, 0);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-numw.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
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
node_q() { # <query> [json params]
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" FC_P="${2:-[]}" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_q "$1" "${2:-[]}")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
# a predicate through fire-crab vs the ENGINE on the same file
predq() { # <label> <where-clause>
    fc=$(node_run "SELECT ID FROM T WHERE $2 ORDER BY ID")
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
SELECT ID FROM T WHERE $2 ORDER BY ID;
SQL
)
    fc=$(printf '%s' "$fc" | tr '\n' ' ' | strip)
    check "$1 [$2]" "$fc" "$is"
}

# --- 1. the predicate matrix: fire-crab == engine, same file -----------
predq "scaled equality, written scale"   "N = 12.50"
predq "scaled equality, shorter scale"   "N = 12.5"
predq "scaled vs integer literal"        "N > 3"
predq "scaled negative bound"            "N <= -1.25"
predq "scaled inequality"                "N <> 2"
predq "scaled NULL test"                 "N IS NULL"
predq "scaled BETWEEN"                   "N BETWEEN 1 AND 20"
predq "scaled IN with a decimal"         "N IN (99, 12.50)"
predq "NOT over a scaled compare"        "NOT (N < 5)"
predq "fine-scale equality"              "M = 0.0001"
predq "INT128 equality"                  "I = 42"
predq "INT128 negative range"            "I > -5"
predq "INT128 below an i64 literal"      "I < 5000000000"
predq "decimal literal vs INT column"    "A > 9.5"
predq "mixed AND/OR across kinds"        "N > 0 AND I >= 0 OR A = 3"
# a parameter binds with its wire scale
fcp=$(node_run 'SELECT ID FROM T WHERE M = ? ORDER BY ID' '[7]' | tr '\n' ' ' | strip)
check "numeric parameter (M = ? bound 7)" "$fcp" "2"

# --- 2. DML through numeric predicates + decimal literals --------------
check "fc INSERT with decimal literals" \
      "$(node_run 'INSERT INTO T (ID, A, N, M, I) VALUES (5, 1, 3.75, 2.5, 9)')" "OK"
check "fc UPDATE SET a decimal through a scaled WHERE" \
      "$(node_run 'UPDATE T SET N = 9.25 WHERE N = 2.00')" "OK"
check "fc DELETE through a fine-scale WHERE" \
      "$(node_run 'DELETE FROM T WHERE M = 0.0001')" "OK"
case "$(node_run 'INSERT INTO T (ID, A) VALUES (9, 1.5)')" in
    ERR*) echo "OK   an inexact decimal into INTEGER refuses (the engine would round)" ;;
    *) echo "DIFF inexact-decimal refusal"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (ID, A, N, M, I) VALUES (5, 1, 3.75, 2.5, 9);
UPDATE T SET N = 9.25 WHERE N = 2.00;
DELETE FROM T WHERE M = 0.0001;
COMMIT;
SQL
dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID||'|'||COALESCE(A,-99)||'|'||COALESCE(N,-99)||'|'||COALESCE(M,-99)||'|'||COALESCE(I,-99) FROM T ORDER BY ID;
SQL
}
work_d=$(dump "$WORK")
check "the DML through numeric predicates matches the engine" "$work_d" "$(dump "$REF")"
case "$work_d" in
    *"5|1|3.75|2.5000|9"*) echo "OK   the decimal literals landed exactly (3.75, 2.5000)" ;;
    *) echo "DIFF the dump comparison was vacuous"; echo "     $work_d"; fail=1 ;;
esac

# --- 3. gbak and gfix ---------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-numw-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-numw-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-numw-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-numw-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-numw-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
