#!/bin/bash
# `CAST(<expr> AS <type>)` across the whole target list, against the REAL
# engine as a twin: the same driver, the same statement, two servers, two
# identical databases.
#
# The target list held INTEGER and CHAR/VARCHAR only; NUMERIC, FLOAT/
# DOUBLE PRECISION, DATE, TIME and TIMESTAMP refused. What makes CAST
# worth its own gate is that almost every conversion has a ROUNDING or a
# FORMAT rule, and each of those is a silent wrong answer when it is off
# by one digit:
#
#   1. To an INTEGER, the engine rounds HALF AWAY FROM ZERO - not
#      truncation and not banker's rounding. All three agree on 1.4; they
#      disagree on 2.5 (3, 2, 2) and on -2.5 (-3, -2, -2), so those are
#      the checks.
#   2. To a NUMERIC(p, s), the same rounding at the declared SCALE:
#      12.55 to scale 1 is 12.6, and -12.55 is -12.6. A truncating
#      conversion answers 12.5 and looks perfectly reasonable.
#      Precision past 18 stores as INT128 and must announce that width,
#      or the value travels in a slot too narrow to hold it.
#   3. To TEXT, the format is the engine's own rendering, and the
#      approximate ones are the interesting case: a DOUBLE prints at 16
#      SIGNIFICANT digits and a FLOAT at 8, trailing zeros kept,
#      scientific outside the fixed range (C's `%#.16g` / `%#.8g`).
#      Rust's default float formatting prints the shortest
#      round-tripping form - "1.5" where the engine writes
#      "1.500000000000000" - which is a different STRING for the same
#      number, and this text is what a CAST and a `||` both produce.
#   4. Between temporal types: a DATE becomes MIDNIGHT of a TIMESTAMP and
#      a TIMESTAMP splits into either half.
#   5. From TEXT, with the engine's lenient parse ('2021-6-15' is a date)
#      and its conversion error where the text is not a value.
#   6. Refusals that must stay refusals, each for a stated reason.
#
#   qa/serve-real-cast.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4445}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cast-crab.fdb"
B="$D/fc-cast-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# N ends in 5 at the scale below its own, so every rounding rule answers
# differently; row 2 is its negative, because half-away-from-zero and
# round-half-up part company on negatives.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, I INTEGER, N NUMERIC(9,2), DP DOUBLE PRECISION,
                F FLOAT, S VARCHAR(20), D DATE, TS TIMESTAMP);
COMMIT;
INSERT INTO T VALUES (1, 7,  12.55,  1.5,  1.5,  '42',         '2020-01-01', '2020-01-01 08:30:00');
INSERT INTO T VALUES (2, -7, -12.55, 2.5,  2.5,  '2021-06-15', '2021-06-15', '2021-06-15 12:00:00');
INSERT INTO T VALUES (3, 0,  0.50,   -0.5, -0.5, 'abc',        NULL,          NULL);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cast.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
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
# every row, so a rule that is right for the positive and wrong for the
# negative cannot hide
cast() { # <expression>
    both "$1" "SELECT ID, $1 AS X FROM T ORDER BY ID"
}

# --- 1. to the integer family: HALF AWAY FROM ZERO ---------------------
cast "CAST(N AS INTEGER)"
cast "CAST(DP AS INTEGER)"
cast "CAST(F AS INTEGER)"
cast "CAST(2.5 AS INTEGER)"
cast "CAST(-2.5 AS INTEGER)"
cast "CAST(1.4 AS INTEGER)"
cast "CAST(-1.4 AS INTEGER)"
cast "CAST(I AS BIGINT)"
cast "CAST(S AS INTEGER)"

# --- 2. to an exact numeric at a declared scale ------------------------
cast "CAST(I AS NUMERIC(9,2))"
cast "CAST(N AS NUMERIC(9,1))"
cast "CAST(N AS NUMERIC(9,0))"
cast "CAST(N AS NUMERIC(18,4))"
cast "CAST(DP AS NUMERIC(9,2))"
cast "CAST(N AS DECIMAL(9,3))"
cast "CAST(N AS NUMERIC)"
cast "CAST(N AS NUMERIC(5))"
cast "CAST('12.55' AS NUMERIC(9,1))"
# precision past 18 is stored as INT128 - the describe has to say so
cast "CAST(I AS NUMERIC(20,3))"
cast "CAST(N AS NUMERIC(25,4))"

# --- 3. to the approximate family, and to TEXT -------------------------
cast "CAST(I AS DOUBLE PRECISION)"
cast "CAST(N AS DOUBLE PRECISION)"
cast "CAST(DP AS FLOAT)"
cast "CAST(I AS VARCHAR(10))"
cast "CAST(N AS VARCHAR(10))"
cast "CAST(DP AS VARCHAR(30))"
cast "CAST(F AS VARCHAR(30))"
cast "CAST(I AS CHAR(5))"
cast "CAST(D AS VARCHAR(20))"
cast "CAST(TS AS VARCHAR(30))"
# the plain columns print the same way outside a CAST
both "an approximate column rendered by concatenation" \
     "SELECT ID, '[' || DP || ']' AS X FROM T ORDER BY ID"
both "and a FLOAT, which prints to FEWER digits" \
     "SELECT ID, '[' || F || ']' AS X FROM T ORDER BY ID"

# --- 4. between temporal types -----------------------------------------
cast "CAST(D AS TIMESTAMP)"
cast "CAST(TS AS DATE)"
cast "CAST(TS AS TIME)"
cast "CAST(D AS DATE)"

# --- 5. from TEXT ------------------------------------------------------
cast "CAST('2021-06-15' AS DATE)"
cast "CAST('2021-6-15' AS DATE)"
cast "CAST('08:30' AS TIME)"
cast "CAST('2020-01-01 08:30' AS TIMESTAMP)"
cast "CAST('1.5' AS DOUBLE PRECISION)"

# --- nesting, and CAST in a predicate ----------------------------------
cast "CAST(CAST(N AS INTEGER) AS VARCHAR(8))"
cast "CAST(CAST(D AS VARCHAR(20)) AS DATE)"
both "a CAST in the WHERE" \
     "SELECT ID FROM T WHERE CAST(N AS INTEGER) > 0 ORDER BY ID"
both "a CAST against a column" \
     "SELECT ID FROM T WHERE CAST(D AS TIMESTAMP) = TS ORDER BY ID"
both "a CAST in an aggregate" "SELECT SUM(CAST(N AS INTEGER)) FROM T"
both "a NULL casts to NULL of any type" \
     "SELECT ID, CAST(D AS TIMESTAMP) AS X FROM T WHERE ID = 3"

# --- 6. the conversion errors ------------------------------------------
# the engine raises 22018 / 22001; this server refuses or raises. What
# neither may do is answer a VALUE.
for bad in "CAST(S AS INTEGER)" "CAST(S AS DATE)" "CAST(S AS DOUBLE PRECISION)" \
           "CAST(N AS CHAR(3))"; do
    a=$(query "SELECT $bad FROM T WHERE ID = 3" "$PORT" "$A")
    b=$(query "SELECT $bad FROM T WHERE ID = 3" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $bad is an error on BOTH" ;;
        *) echo "DIFF $bad: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done

# --- refusals that must STAY refusals ----------------------------------
# a TIME does not become a DATE or a TIMESTAMP: the engine would use the
# CURRENT DATE, which this server does not do - the same reason the two
# do not compare.
r=$(query "SELECT CAST(CAST('08:30' AS TIME) AS TIMESTAMP) FROM T WHERE ID = 1" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   TIME to TIMESTAMP is refused (the engine uses the current date)" ;;
    *) echo "DIFF TIME to TIMESTAMP answered: [$r]"; fail=1 ;;
esac
# a target this parser does not know must refuse rather than fall back to
# some other conversion
r=$(query "SELECT CAST(I AS BLOB) FROM T WHERE ID = 1" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   an unsupported CAST target is refused, not approximated" ;;
    *) echo "DIFF CAST AS BLOB answered: [$r]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
