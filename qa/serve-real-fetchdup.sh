#!/bin/bash
# A CURSOR IS CONSUMED BY ITS FETCH - every cursor, not just a
# materialised one.
#
# Any query returning 500 ROWS OR MORE delivered EVERY ROW TWICE. Not a
# window, not a join, not a sort: a plain `SELECT ID FROM T` with no
# WHERE, no ORDER BY and nothing else. Row 1 came back twice and so did
# row 500; 1002 lines where the engine sends 502.
#
# `emit_rows` walks the WHOLE plan and ignores the count the client
# asked for, so after it runs there is nothing left to deliver - but
# only `Plan::Rows` was emptied afterwards. A STREAMING plan was left
# intact, so the next op_fetch re-walked it from the start.
#
# WHY 500. That is where fbclient stops trusting one response and sends
# a second op_fetch: 499 rows is ONE fetch and one copy, 500 is TWO
# fetches and two copies. The boundary is exact and it is the client's,
# not the server's - there is no 500 anywhere in the server.
#
# WHY NOTHING CAUGHT IT. Under one fetch the answer is correct, and one
# fetch is every hand-written test in the suite. It is only wrong from
# the SECOND fetch onwards. This gate therefore builds 600 rows on
# purpose and asserts the MULTIPLICITY of individual rows - a row-count
# check alone passes the broken server on its first batch.
#
# AND WHY THE OBVIOUS PROBE MISSES IT: node-firebird does NOT send the
# second op_fetch, so it reports the correct row count against a server
# that is duplicating. An earlier investigation checked with exactly
# that driver, got the right answer, and wrongly concluded the
# duplication was an isql rendering artifact. THE CLIENT HAS TO BE ONE
# THAT EXERCISES THE PATH - here that is isql over fbclient. Do not
# "simplify" this gate onto the node driver.
#
#   qa/serve-real-fetchdup.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4361}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fetchdup-a.fdb"
B="$D/fc-fetchdup-b.fdb"
ROWS=600

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, G INTEGER);
CREATE SEQUENCE SQ;
COMMIT;
INSERT INTO T (ID, G) SELECT NEXT VALUE FOR SQ, 0 FROM RDB\$TYPES A, RDB\$TYPES B ROWS $ROWS;
COMMIT;
UPDATE T SET G = MOD(ID, 5);
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done
got=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$B" 2>&1 | tr -dc '0-9')
[ "$got" = "$ROWS" ] || { echo "FAIL fixture has $got rows, expected $ROWS - this gate cannot test the fetch boundary without them"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fetchdup.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

fail=0; ran=0
FC="127.0.0.1/$PORT:$A"
EN="127.0.0.1/3050:$B"

rows_of() { # <dsn> <sql>
    printf 'SET HEADING OFF;\n%s;\n' "$2" |
        timeout 240 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -av '^[[:space:]]*$'
}
both() { # <label> <sql>
    ran=$((ran + 1))
    rows_of "$EN" "$2" > /tmp/fd_en.$$ ; rows_of "$FC" "$2" > /tmp/fd_fc.$$
    # an EMPTY result is a legitimate answer: compare, but do not
    # require content
    if cmp -s /tmp/fd_en.$$ /tmp/fd_fc.$$; then
        echo "OK   $1 ($(wc -l < /tmp/fd_en.$$) rows, byte-identical)"
    else
        echo "DIFF $1: engine $(wc -l < /tmp/fd_en.$$) rows, fcwire $(wc -l < /tmp/fd_fc.$$)"
        fail=1
    fi
    rm -f /tmp/fd_en.$$ /tmp/fd_fc.$$
}

echo "--- 1. across the fetch boundary, every plan shape ---------------------"
both "a plain scan of $ROWS rows"      "SELECT ID FROM T"
both "just under the boundary (499)"   "SELECT FIRST 499 ID FROM T"
both "exactly at it (500)"             "SELECT FIRST 500 ID FROM T"
both "just over it (501)"              "SELECT FIRST 501 ID FROM T"
both "with a WHERE"                    "SELECT ID FROM T WHERE ID > 0"
both "with an ORDER BY"                "SELECT ID FROM T ORDER BY ID"
both "with a projection expression"    "SELECT ID, ID*2 D FROM T ORDER BY ID"
both "a self join over the boundary"   "SELECT A.ID FROM T A JOIN T B ON A.ID=B.ID ORDER BY A.ID"
both "a grouped result"                "SELECT G, COUNT(*) C FROM T GROUP BY G ORDER BY G"
both "DISTINCT"                        "SELECT DISTINCT G FROM T ORDER BY G"
both "a UNION ALL of $ROWS + $ROWS"    "SELECT ID FROM T UNION ALL SELECT ID FROM T"
both "a windowed scan over the boundary" \
    "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM T ORDER BY ID"

# THE TEETH: a count alone passes a duplicating server on its first
# batch, so assert the multiplicity of specific rows - the first, one in
# the middle, and the last.
ran=$((ran + 1))
rows_of "$FC" "SELECT ID FROM T" > /tmp/fd_t.$$
f1=$(awk '$1==1{n++} END{print n+0}' /tmp/fd_t.$$)
fm=$(awk '$1==500{n++} END{print n+0}' /tmp/fd_t.$$)
fl=$(awk -v r="$ROWS" '$1==r{n++} END{print n+0}' /tmp/fd_t.$$)
tt=$(wc -l < /tmp/fd_t.$$)
if [ "$f1" = "1" ] && [ "$fm" = "1" ] && [ "$fl" = "1" ] && [ "$tt" = "$ROWS" ]; then
    echo "OK   teeth: rows 1, 500 and $ROWS each appear exactly once in $tt rows"
else
    echo "DIFF teeth: $tt rows; row 1 x$f1, row 500 x$fm, row $ROWS x$fl - the cursor is being re-walked"
    fail=1
fi
rm -f /tmp/fd_t.$$

echo "--- 2. small results, which were always correct -----------------------"
both "5 rows"                          "SELECT FIRST 5 ID FROM T ORDER BY ID"
both "100 rows"                        "SELECT FIRST 100 ID FROM T ORDER BY ID"
both "a single row"                    "SELECT FIRST 1 ID FROM T ORDER BY ID"
both "an empty result"                 "SELECT ID FROM T WHERE ID < 0"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 17 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
