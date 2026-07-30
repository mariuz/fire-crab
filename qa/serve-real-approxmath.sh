#!/bin/bash
# ARITHMETIC over approximate numbers, and the literals that make one -
# against the REAL engine as a twin: the same driver, the same statement,
# two servers, two identical databases.
#
# The previous slice made FLOAT and DOUBLE comparable and foldable;
# `DP * 2` still refused, because `Expr::Bin` had arms for integers, for
# exact numerics and for the temporal types, and nothing for the
# approximate family. This closes that - and with it two rules that are
# only visible in arithmetic:
#
#   1. ONE approximate operand makes the whole result approximate. `DP +
#      N` is a DOUBLE, not a NUMERIC(9,2), and the difference shows in
#      the DIGITS: an exact result of 11.75 prints as 11.75, an
#      approximate one as 11.75000000000000. The gate concatenates the
#      results into text for exactly that reason - a driver that decodes
#      both into a JS number would hide the type.
#   2. The engine RAISES on float division by zero (SQLSTATE 22012,
#      `isc_exception_float_divide_by_zero`) and on overflow (22003) - it
#      does NOT answer an IEEE infinity or a NaN. A value there would be
#      a wrong answer, not a lenient one. The two divide-by-zero errors
#      are DIFFERENT gds codes with different message text -
#      `isc_exception_integer_divide_by_zero` shares SQLSTATE 22012 but
#      says "Integer divide by zero" - so the gate checks that the two
#      statements do not collapse into one.
#
#   3. An EXPONENT makes a literal approximate whatever it looks like
#      otherwise: `1e3` is a DOUBLE 1000, not the integer, and `1.5e0` is
#      a DOUBLE where a bare `1.5` is an exact NUMERIC. Both the select
#      list's parser and the predicate tokenizer have to agree about
#      that, so both are exercised.
#
#   qa/serve-real-approxmath.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4455}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-apmath-crab.fdb"
B="$D/fc-apmath-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, DP DOUBLE PRECISION, F FLOAT, N NUMERIC(9,2),
                I INTEGER, G INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 1.5,  1.5,  10.25, 3,    1);
INSERT INTO T VALUES (2, 2.5,  2.5,  20.75, 7,    1);
INSERT INTO T VALUES (3, -0.5, -0.5, 5.00,  2,    2);
INSERT INTO T VALUES (4, NULL, NULL, NULL,  NULL, 2);
INSERT INTO T VALUES (5, 4.0,  4.0,  4.00,  4,    2);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-approxmath.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").replace(/\n/g," ").slice(0,90));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
# The result is concatenated into TEXT, so the comparison sees the
# engine's own rendering - which is where an approximate result differs
# from an exact one carrying the same value (11.75000000000000 against
# 11.75). Decoded as numbers by the driver, the two would look identical.
expr_text() { # <expression>
    both "$1" "SELECT ID, '[' || ($1) || ']' AS X FROM T ORDER BY ID"
}

# --- 1. the four operators, and the promotion --------------------------
expr_text "DP * 2"
expr_text "DP + 1"
expr_text "DP - 0.5"
expr_text "DP / 3"
expr_text "DP * DP"
expr_text "-DP * 2"
expr_text "DP * 2 + 1"
expr_text "(DP + 1) * (DP - 1)"
# a mixed pair: the EXACT side converts, and the result prints as a
# double - this is the check that the promotion happened at all
expr_text "DP + N"
expr_text "DP * N"
expr_text "I / DP"
expr_text "N * F"
expr_text "F + DP"
expr_text "F * 2"
# ... while a pair of exact operands stays exact, printing far shorter
expr_text "N + 1"
expr_text "I * 2"
expr_text "N / 2"

# --- 2. the two float exceptions ---------------------------------------
both "float division by zero raises" "SELECT DP / 0 FROM T WHERE ID = 1"
both "and it is NOT the integer error" "SELECT I / 0 FROM T WHERE ID = 1"
# the messages must differ - collapsing both to one code would pass a
# check that only asked 'did it fail?'
fdz=$(query "SELECT DP / 0 FROM T WHERE ID = 1" "$PORT" "$A")
idz=$(query "SELECT I / 0 FROM T WHERE ID = 1" "$PORT" "$A")
case "$fdz:$idz" in
    *Floating-point*:*Integer*) echo "OK   the two divide-by-zero errors are distinct codes" ;;
    *) echo "DIFF divide-by-zero codes: float [$fdz] integer [$idz]"; fail=1 ;;
esac
both "an overflow raises rather than answering infinity" \
     "SELECT CAST(1e200 AS DOUBLE PRECISION) * CAST(1e200 AS DOUBLE PRECISION) FROM T WHERE ID = 1"
# a NULL operand is still NULL, not an error
both "NULL / 0 is NULL, not a division error" \
     "SELECT ID, DP / 0 AS X FROM T WHERE ID = 4"

# --- 3. exponent literals ----------------------------------------------
expr_text "1e3"
expr_text "1.5e-3"
expr_text "2e0 + 1"
expr_text "DP * 1e200"
expr_text "1.5"
expr_text "1e0 / 3"
# ... and in the PREDICATE, whose tokenizer is a different lexer
both "an exponent literal in a WHERE" \
     "SELECT ID FROM T WHERE DP > 1.5e0 ORDER BY ID"
both "an exponent literal against an exact column" \
     "SELECT ID FROM T WHERE N > 1e1 ORDER BY ID"
both "an exponent literal in BETWEEN" \
     "SELECT ID FROM T WHERE DP BETWEEN 1e0 AND 3e0 ORDER BY ID"
both "the same bounds written exactly" \
     "SELECT ID FROM T WHERE DP BETWEEN 1 AND 3 ORDER BY ID"

# --- arithmetic where the rest of the pipeline can see it --------------
both "arithmetic in a WHERE" "SELECT ID FROM T WHERE DP * 2 > 3 ORDER BY ID"
both "arithmetic under an aggregate" "SELECT SUM(DP * 2), AVG(DP / 2) FROM T"
both "arithmetic in a GROUP BY key" \
     "SELECT DP * 2, COUNT(*) FROM T GROUP BY DP * 2 ORDER BY 1"
both "arithmetic in ORDER BY" "SELECT ID FROM T ORDER BY -DP, ID"
both "arithmetic in a subquery's value" \
     "SELECT ID FROM T WHERE DP > (SELECT AVG(DP * 2) FROM T) ORDER BY ID"
both "an UPDATE computing an approximate value" \
     "UPDATE T SET DP = DP * 2 WHERE ID = 1"
both "the table after it" "SELECT ID, '[' || DP || ']' AS X FROM T ORDER BY ID"

rm -f "$A" "$B"
exit $fail
