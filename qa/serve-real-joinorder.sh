#!/bin/bash
# An ORDER BY over a JOIN fetch STREAMS: the join cursor hands back its
# COMBINED rows unprojected, they are drained into the external sort at
# open (runs past the budget), and each fetch pulls its batch from the
# merge and projects it - the result is never a Vec of the whole output.
# Before this the ordered join was the one fetch shape that still
# materialised; the same rows in the same order are the point, and the
# server is run with a 64 KB sort budget so the sort SPILLS.
#
#   qa/serve-real-joinorder.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4843}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-joinorder-engine.fdb"; DBF="$D/fc-joinorder-crab.fdb"
LOG="/tmp/fc-serve-joinorder-$PORT.log"
fail=0; ran=0
mkdir -p "$D"
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE D (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20), REGION INTEGER);
CREATE TABLE E (ID INTEGER NOT NULL PRIMARY KEY, DID INTEGER, SAL INTEGER, NAME VARCHAR(30));
CREATE TABLE R (ID INTEGER NOT NULL PRIMARY KEY, RNAME VARCHAR(10));
COMMIT;
INSERT INTO R VALUES (1, 'north'); INSERT INTO R VALUES (2, 'south'); INSERT INTO R VALUES (3, 'east');
INSERT INTO D VALUES (1, 'sales', 1); INSERT INTO D VALUES (2, 'ops', 2); INSERT INTO D VALUES (3, 'dev', 2);
INSERT INTO D VALUES (4, 'empty', 3); INSERT INTO D VALUES (5, NULL, NULL);
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 1; BEGIN
  WHILE (I <= 3000) DO BEGIN
    INSERT INTO E VALUES (:I, CASE WHEN MOD(:I, 7) = 0 THEN NULL ELSE MOD(:I, 4) END, MOD(:I * 37, 1000), 'emp' || LPAD(:I, 5, '0'));
    I = I + 1;
  END
END^
SET TERM ;^
COMMIT;
SQL
}
rm -f "$DBE" "$DBF"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 FC_SORT_MEMORY=65536 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
run() { printf 'SET HEADING OFF;\nSET COUNT ON;\n%s\n' "$2" | timeout 120 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | grep -v '^$' | md5sum | cut -c1-12; }
eng() { run "127.0.0.1/$REAL:$DBE" "$1"; }
crab() { run "127.0.0.1/$PORT:$DBF" "$1"; }
both() { local e c; e=$(eng "$2"); c=$(crab "$2"); ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

both "inner join, ORDER BY a key of each side" \
    "SELECT E.ID, E.NAME, D.NAME FROM E JOIN D ON D.ID = E.DID ORDER BY D.NAME, E.ID DESC;"
both "LEFT JOIN, NULL partners sort first ASC / last DESC" \
    "SELECT E.ID, D.NAME FROM E LEFT JOIN D ON D.ID = E.DID ORDER BY D.NAME, E.ID; SELECT E.ID, D.NAME FROM E LEFT JOIN D ON D.ID = E.DID ORDER BY D.NAME DESC, E.ID;"
both "a chain of three, ordered by the far side" \
    "SELECT E.ID, R.RNAME FROM E JOIN D ON D.ID = E.DID JOIN R ON R.ID = D.REGION ORDER BY R.RNAME, E.SAL, E.ID;"
both "ORDER BY an expression and a position" \
    "SELECT E.ID, E.SAL + D.ID FROM E JOIN D ON D.ID = E.DID ORDER BY 2 DESC, 1;"
both "ORDER BY a column not projected" \
    "SELECT E.NAME FROM E JOIN D ON D.ID = E.DID ORDER BY E.SAL DESC, E.ID;"
both "a WHERE above the join, then the sort" \
    "SELECT E.ID, D.NAME FROM E JOIN D ON D.ID = E.DID WHERE E.SAL > 900 ORDER BY D.NAME, E.ID;"
both "RIGHT JOIN last part: the mirror rows sort with the rest" \
    "SELECT E.ID, D.NAME FROM E RIGHT JOIN D ON D.ID = E.DID ORDER BY D.NAME, E.ID;"
both "RIGHT JOIN with the BIG side preserved: the stored side spills" \
    "SELECT D.ID, E.ID FROM D RIGHT JOIN E ON E.DID = D.ID WHERE E.ID > 2980 OR D.ID IS NULL ORDER BY E.ID DESC;"
both "FULL JOIN, the big side last, under a WHERE on each side" \
    "SELECT COUNT(*), COUNT(D.ID), COUNT(E.ID) FROM D FULL JOIN E ON E.DID = D.ID;"
both "FULL JOIN with ORDER BY" \
    "SELECT E.ID, D.ID FROM E FULL JOIN D ON D.ID = E.DID WHERE E.ID IS NULL OR E.ID > 2990 ORDER BY D.ID, E.ID;"
both "FIRST n after the sort" \
    "SELECT FIRST 5 E.ID, D.NAME FROM E JOIN D ON D.ID = E.DID ORDER BY E.SAL DESC, E.ID;"
both "FIRST n SKIP m after the sort (OFFSET/FETCH over a join: a pre-existing plan refusal, not this slice's)" \
    "SELECT FIRST 7 SKIP 10 E.ID FROM E JOIN D ON D.ID = E.DID ORDER BY E.ID;"
both "the cursor fetched in small batches: the same rows" \
    "SELECT E.ID, D.NAME FROM E JOIN D ON D.ID = E.DID ORDER BY E.NAME DESC;"
ran=$((ran + 1)); n=$(grep -c 'sort cursor:' "$LOG"); sp=$(grep -c 'sort cursor:.*runs=[0-9]*[2-9]' "$LOG")
if [ "$n" -ge 8 ]; then echo "OK   coverage: $n ordered fetches streamed through the sort cursor ($sp past the budget)"; else echo "DIFF coverage: [$n] sort cursors"; grep 'sort' "$LOG" | head -3; fail=1; fi
# the RIGHT/FULL last side lives in a RowStore (RAM to the budget, a
# file past it); the 64 KB budget makes E's 3000 rows spill
ran=$((ran + 1)); m=$(grep -c 'join mirror store: rows=' "$LOG"); ms=$(grep -c 'join mirror store: rows=[0-9]* spilled=[1-9]' "$LOG")
if [ "$m" -ge 2 ] && [ "$ms" -ge 1 ]; then echo "OK   coverage: $m mirror sides stored, $ms spilled past the budget"; else echo "DIFF coverage: mirror stores $m, spilled $ms"; grep 'mirror' "$LOG" | head -3; fail=1; fi
echo "ran $ran checks"
exit $fail
