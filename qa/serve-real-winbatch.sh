#!/bin/bash
# A WINDOWED RESULT THAT DOES NOT FIT ONE FETCH BATCH.
#
# A bare top-level `SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) FROM T`
# over 5000 rows came back SIX TIMES OVER - 30000 rows, five of the six
# blocks byte-identical to each other, row 1 appearing at line offsets
# 2, 5002, 10002, 15002, 20002 and 25002. No error, no warning. And a
# driver that honours the protocol's flow control (node-firebird) did not
# merely see duplicates: it HUNG and never returned.
#
# The mechanism, and the reason it hid: `branch_rows` answers None for a
# windowed Project, so the plan was never materialised into `Plan::Rows`,
# and control fell PAST the batching code to a path that ignores the
# client's requested batch size and emits the whole result every time it
# is asked. Under one batch - which is every hand-written test - the
# answer is correct. It is only wrong from the second fetch onwards, so
# the defect is invisible to a small fixture and this gate therefore
# builds a LARGE one on purpose.
#
# That is also why the sweep never caught it: every other window gate
# uses a handful of rows.
#
# The fix materialises a windowed projection in the fetch path BEFORE the
# generic `branch_rows` attempt, through the SAME fold the streaming emit
# path uses ([fold_project_windows]) - one implementation rather than two
# that must be kept in step. The fold order is load-bearing: scan with an
# EMPTY sort key, fold each window over its whole partition, and only
# then sort into output order. A window folds over the partition, so
# folding per batch would be wrong in a way that only shows past the
# first batch boundary, and ROW_NUMBER's tie order is pinned to SCAN
# order, which a pre-sort would move.
#
#   qa/serve-real-winbatch.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4353}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-winbatch-a.fdb"
B="$D/fc-winbatch-b.fdb"
ROWS=5000

mkdir -p "$D"
setup() {
    printf 'DROP DATABASE;\n' | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/dev/null 2>&1
    rm -f "$1"
    # generated through a SEQUENCE over a cross join: a recursive CTE hits
    # the engine's own 1024-level recursion limit at this size, and
    # EXECUTE BLOCK needs a terminator change isql will not take from a
    # heredoc
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF 2>&1
CREATE DATABASE '127.0.0.1/3050:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W2 (ID INTEGER, G INTEGER, V INTEGER);
CREATE SEQUENCE S1;
COMMIT;
INSERT INTO W2 (ID, G, V) SELECT NEXT VALUE FOR S1, 0, 0 FROM RDB\$TYPES A, RDB\$TYPES B ROWS $ROWS;
COMMIT;
UPDATE W2 SET G = MOD(ID,7), V = ID*2;
COMMIT;
EOF
}
for f in "$A" "$B"; do
    n=0; while [ $n -lt 4 ]; do err=$(setup "$f") && break; n=$((n + 1)); sleep 1; done
    [ $n -lt 4 ] || { echo "FAIL create $f: $err"; exit 1; }
done
# the fixture must actually be big, or this gate proves nothing
got=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM W2;\n' |
    timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$B" 2>&1 | tr -dc '0-9')
[ "$got" = "$ROWS" ] || { echo "FAIL fixture has $got rows, expected $ROWS - this gate cannot test batching without them"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-winbatch.log 2>&1 &
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
# byte-for-byte over the WHOLE result, not a count - a count alone would
# pass a result that is the right size and the wrong rows
both() { # <label> <sql>
    ran=$((ran + 1))
    rows_of "$EN" "$2" > /tmp/wb_en.$$ ; rows_of "$FC" "$2" > /tmp/wb_fc.$$
    if cmp -s /tmp/wb_en.$$ /tmp/wb_fc.$$ && [ -s /tmp/wb_en.$$ ]; then
        echo "OK   $1 ($(wc -l < /tmp/wb_en.$$) rows, byte-identical)"
    else
        echo "DIFF $1: engine $(wc -l < /tmp/wb_en.$$) rows, fcwire $(wc -l < /tmp/wb_fc.$$)"
        diff /tmp/wb_en.$$ /tmp/wb_fc.$$ 2>/dev/null | head -3
        fail=1
    fi
    rm -f /tmp/wb_en.$$ /tmp/wb_fc.$$
}

echo "--- 1. a windowed result larger than one fetch batch -----------------"
both "ROW_NUMBER over $ROWS rows"      "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM W2 ORDER BY ID"
both "COUNT(*) OVER () over $ROWS"     "SELECT ID, COUNT(*) OVER () C FROM W2 ORDER BY ID"
both "SUM OVER a PARTITION"            "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM W2 ORDER BY ID"
both "RANK over a tied key"            "SELECT ID, RANK() OVER (ORDER BY G) R FROM W2 ORDER BY ID"
both "LAG with a default"              "SELECT ID, LAG(V,1,0) OVER (ORDER BY ID) L FROM W2 ORDER BY ID"
both "an explicit ROWS frame"          "SELECT ID, SUM(V) OVER (ORDER BY ID ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) S FROM W2 ORDER BY ID"
both "ordered BY the window's own column" \
    "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM W2 ORDER BY RN, ID"
both "two windows in one select list"  "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN, COUNT(*) OVER () C FROM W2 ORDER BY ID"

# THE TEETH: the failure was that the whole result came back repeatedly,
# so assert the multiplicity of a single row directly. A row-count check
# alone would have passed the pre-fix server on the FIRST batch.
ran=$((ran + 1))
rows_of "$FC" "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM W2 ORDER BY ID" > /tmp/wb_t.$$
first=$(awk '$1==1{n++} END{print n+0}' /tmp/wb_t.$$)
last=$(awk -v r="$ROWS" '$1==r{n++} END{print n+0}' /tmp/wb_t.$$)
total=$(wc -l < /tmp/wb_t.$$)
if [ "$first" = "1" ] && [ "$last" = "1" ] && [ "$total" = "$ROWS" ]; then
    echo "OK   teeth: every row appears exactly once ($total rows, first x$first, last x$last)"
else
    echo "DIFF teeth: $total rows total, row 1 appeared x$first and row $ROWS x$last - the result is being re-delivered"
    fail=1
fi
rm -f /tmp/wb_t.$$

echo "--- 2. the controls, which must not have moved -----------------------"
both "the same window over 5 rows, one batch" \
    "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) RN FROM W2 WHERE ID <= 5 ORDER BY ID"
both "no window, $ROWS rows"           "SELECT ID FROM W2 ORDER BY ID"
both "no window, 5 rows"               "SELECT ID FROM W2 WHERE ID <= 5 ORDER BY ID"
both "a grouped result"                "SELECT G, COUNT(*) C FROM W2 GROUP BY G ORDER BY G"
both "DISTINCT"                        "SELECT DISTINCT G FROM W2 ORDER BY G"
both "a large UNION ALL, no window"     "SELECT ID FROM W2 UNION ALL SELECT ID FROM W2"

echo "----------------------------------------------------------------------"
[ "$ran" -ge 15 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
