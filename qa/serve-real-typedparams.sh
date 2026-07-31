#!/bin/bash
# `?` PARAMETERS over the temporal and approximate families - `WHERE D =
# ?` with a DATE, `WHERE DP > ?` with a DOUBLE - against the REAL engine
# as a twin: the same driver, the same statement, the same argument list,
# two servers, two identical databases.
#
# A parameter is a two-sided contract and both sides are checked here:
#
#   1. The DESCRIBE the server publishes for the slot. The client builds
#      its encoder from it, so announcing the wrong type does not produce
#      a wrong answer - it produces a wrongly ENCODED message, and the
#      values that survive are the ones whose two encodings happen to
#      agree. Every check below sends a real value and compares the ROWS.
#   2. The BINDING of the arrived value back into a comparison. A
#      temporal or approximate parameter cannot travel as one of the
#      exact `Rhs` shapes, so these bind straight to a literal
#      EXPRESSION and the term becomes an ordinary three-valued
#      comparison - the same one a written-out literal produces. The gate
#      runs the literal form beside the parameter form for exactly that
#      reason: they must select the same rows.
#
# One refusal is deliberate. The input BLR is VALUE-derived, not
# descriptor-derived - node-firebird sends any JS Date as blr_timestamp
# whatever the describe announced. Against a DATE column that is
# harmless, because a DATE reads as midnight against a TIMESTAMP. Against
# a TIME column it is not: the engine compares the two by promoting the
# TIME with the CURRENT DATE, so every stored row sorts above a 1970
# timestamp - and reading the timestamp's time half instead (the obvious
# thing) answers a different set of rows with no error anywhere. So the
# statement refuses, and the gate pins both halves: the engine's answer
# is recorded as the promotion it is, and fire-crab refuses rather than
# guessing.
#
#   qa/serve-real-typedparams.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4465}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-tp-crab.fdb"
B="$D/fc-tp-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, D DATE, TS TIMESTAMP, TM TIME,
                DP DOUBLE PRECISION, F FLOAT, N NUMERIC(9,2), NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, '2020-01-01', '2020-01-01 08:30:00', '08:30:00',  1.5,  1.5,  10.25, 'aa');
INSERT INTO T VALUES (2, '2021-06-15', '2021-06-15 12:00:00', '12:00:00',  2.5,  2.5,  20.75, 'bb');
INSERT INTO T VALUES (3, '2019-03-03', '2019-03-03 23:59:59', '23:59:59', -0.5, -0.5,  5.00,  'cc');
INSERT INTO T VALUES (4, NULL,          NULL,                  NULL,       NULL, NULL, NULL,  'dd');
INSERT INTO T VALUES (5, '2022-12-31', '2022-12-31 00:00:00', '00:00:00',  4.0,  4.0,  4.00,  'ee');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-typedparams.log 2>&1 &
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

# An ISO-8601 string in the argument list becomes a JS Date; everything
# else travels as the JSON value it is.
query() { # <sql> <json args> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_A="$2" FC_PORT="$3" FC_DB="$4" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          const args=JSON.parse(process.env.FC_A).map(v =>
            (typeof v === "string" && /^\d{4}-\d\d-\d\dT/.test(v)) ? new Date(v + "Z") : v);
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,args,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql> <json args>
    a=$(query "$2" "$3" "$PORT" "$A")
    b=$(query "$2" "$3" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
# the parameter form and the written-out literal form must select the
# same rows on the same server - a bind that lands the value in the
# wrong shape shows up here even when both servers agree with each other
same_as_literal() { # <label> <sql with ?> <json args> <sql with the literal>
    p=$(query "$2" "$3" "$PORT" "$A")
    l=$(query "$4" "[]" "$PORT" "$A")
    if [ "$p" = "$l" ]; then
        echo "OK   $1 binds to what the literal means: $p"
    else
        echo "DIFF $1: parameter [$p] literal [$l]"
        fail=1
    fi
}

# --- the families that already worked, as the control ------------------
both "an INTEGER parameter" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[2]'
both "a TEXT parameter" "SELECT ID FROM T WHERE NAME = ? ORDER BY ID" '["bb"]'
both "a NUMERIC parameter" "SELECT ID FROM T WHERE N > ? ORDER BY ID" '[10]'

# --- 1. DATE and TIMESTAMP ---------------------------------------------
both "= a DATE parameter" "SELECT ID FROM T WHERE D = ? ORDER BY ID" \
     '["2021-06-15T00:00:00.000"]'
both "> a DATE parameter" "SELECT ID FROM T WHERE D > ? ORDER BY ID" \
     '["2020-06-15T00:00:00.000"]'
both "<= a DATE parameter" "SELECT ID FROM T WHERE D <= ? ORDER BY ID" \
     '["2020-01-01T00:00:00.000"]'
both "a TIMESTAMP column against a parameter" \
     "SELECT ID FROM T WHERE TS > ? ORDER BY ID" '["2020-06-15T00:00:00.000"]'
both "BETWEEN two DATE parameters" \
     "SELECT ID FROM T WHERE D BETWEEN ? AND ? ORDER BY ID" \
     '["2020-01-01T00:00:00.000","2022-01-01T00:00:00.000"]'
both "a parameter on an EXPRESSION side" \
     "SELECT ID FROM T WHERE D + 1 > ? ORDER BY ID" '["2021-06-15T00:00:00.000"]'
both "two parameters of different families in one predicate" \
     "SELECT ID FROM T WHERE D = ? OR NAME = ? ORDER BY ID" \
     '["2020-01-01T00:00:00.000","cc"]'
both "a NULL temporal parameter is UNKNOWN, not an error" \
     "SELECT ID FROM T WHERE D = ? ORDER BY ID" '[null]'
both "a temporal parameter in a DML WHERE" \
     "UPDATE T SET NAME = 'px' WHERE D = ?" '["2020-01-01T00:00:00.000"]'
both "the table after it" "SELECT ID, NAME FROM T ORDER BY ID" '[]'

same_as_literal "a DATE parameter" \
     "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["2020-06-15T00:00:00.000"]' \
     "SELECT ID FROM T WHERE D > DATE'2020-06-15' ORDER BY ID"

# --- 2. FLOAT and DOUBLE PRECISION -------------------------------------
both "> a DOUBLE parameter" "SELECT ID FROM T WHERE DP > ? ORDER BY ID" '[1.5]'
both "= a DOUBLE parameter" "SELECT ID FROM T WHERE DP = ? ORDER BY ID" '[2.5]'
both "a FLOAT column against a parameter" \
     "SELECT ID FROM T WHERE F > ? ORDER BY ID" '[1.5]'
both "an INTEGER value for an approximate slot converts" \
     "SELECT ID FROM T WHERE DP > ? ORDER BY ID" '[1]'
both "a parameter against approximate ARITHMETIC" \
     "SELECT ID FROM T WHERE DP * 2 > ? ORDER BY ID" '[3]'
both "BETWEEN two approximate parameters" \
     "SELECT ID FROM T WHERE DP BETWEEN ? AND ? ORDER BY ID" '[0, 3]'
both "a NULL approximate parameter" "SELECT ID FROM T WHERE DP > ? ORDER BY ID" '[null]'
both "an approximate parameter in a DML WHERE" \
     "UPDATE T SET NAME = 'py' WHERE DP > ?" '[3]'
both "the table after it" "SELECT ID, NAME FROM T ORDER BY ID" '[]'

same_as_literal "a DOUBLE parameter" \
     "SELECT ID FROM T WHERE DP > ? ORDER BY ID" '[1.5]' \
     "SELECT ID FROM T WHERE DP > 1.5 ORDER BY ID"

# --- the deliberate refusal --------------------------------------------
# node-firebird sends every JS Date as blr_timestamp, so a TIME
# comparison arrives as a TIMESTAMP - and the engine answers it by
# promoting the TIME with the CURRENT DATE. Both facts are pinned: the
# engine returns EVERY non-null row for `TM > <a 1970 timestamp>` (which
# a time-of-day comparison would not), and fire-crab refuses rather than
# reading the timestamp's time half and answering a different set.
e=$(query "SELECT ID FROM T WHERE TM > ? ORDER BY ID" '["1970-01-01T09:00:00.000"]' "$REAL" "$B")
c=$(query "SELECT ID FROM T WHERE TM > ? ORDER BY ID" '["1970-01-01T09:00:00.000"]' "$PORT" "$A")
all=$(query "SELECT ID FROM T WHERE TM IS NOT NULL ORDER BY ID" '[]' "$REAL" "$B")
case "$c" in
    ERR*)
        if [ "$e" = "$all" ]; then
            echo "OK   a TIMESTAMP value for a TIME parameter: the engine promotes it with the current date ($e), fire-crab refuses"
        else
            echo "DIFF the engine's TIME/TIMESTAMP answer was [$e], not every row [$all]"
            fail=1
        fi ;;
    *) echo "DIFF fire-crab answered a TIME parameter: [$c]"; fail=1 ;;
esac
# ... while a TIME comparison against a written-out literal still works,
# so the refusal is about the VALUE's wire shape and nothing else
both "a TIME column against a written TIME literal" \
     "SELECT ID FROM T WHERE TM > TIME'09:00:00' ORDER BY ID" '[]'

# --- a `?` ON THE LEFT of the comparison -----------------------------
# The engine describes the parameter from the OTHER side whichever way
# round it is written, so `? < DP` is read from that side too: the sides
# SWAP and the operator MIRRORS. Writing `DP < ?` there instead would
# answer a different set of rows and would do it quietly, so every
# ordering operator is checked in both spellings and the two must give
# DIFFERENT answers for the check to mean anything.
both "a parameter on the LEFT with <" "SELECT ID FROM T WHERE ? < DP ORDER BY ID" '[1]'
both "... and its mirror on the right" "SELECT ID FROM T WHERE DP > ? ORDER BY ID" '[1]'
both "a parameter on the LEFT with >" "SELECT ID FROM T WHERE ? > DP ORDER BY ID" '[1]'
both "... and its mirror" "SELECT ID FROM T WHERE DP < ? ORDER BY ID" '[1]'
both "on the LEFT with <=" "SELECT ID FROM T WHERE ? <= DP ORDER BY ID" '[1.5]'
both "on the LEFT with >=" "SELECT ID FROM T WHERE ? >= DP ORDER BY ID" '[1.5]'
both "on the LEFT with =" "SELECT ID FROM T WHERE ? = DP ORDER BY ID" '[1.5]'
both "on the LEFT with <>" "SELECT ID FROM T WHERE ? <> DP ORDER BY ID" '[1.5]'
# a `?` is POSITIONAL: its number is its place in the TEXT, not its place
# in the rewritten leaf, so a left-side one beside a right-side one must
# keep the order the client bound them in
both "a LEFT parameter beside a RIGHT one" \
     "SELECT ID FROM T WHERE ? < DP AND DP < ? ORDER BY ID" '[0, 3]'
both "two LEFT parameters" \
     "SELECT ID FROM T WHERE ? < DP AND ? < ID ORDER BY ID" '[0, 1]'
both "a LEFT parameter against a TEXT column" \
     "SELECT ID FROM T WHERE ? = NAME ORDER BY ID" '["py"]'
both "a LEFT parameter in a DML WHERE" "UPDATE T SET NAME = 'lp' WHERE ? > DP" '[3]'
both "the table after it" "SELECT ID, NAME FROM T ORDER BY ID" '[]'

rm -f "$A" "$B"
exit $fail
