#!/bin/bash
# NOT NULL in DESCRIBE - the nullable bit of sqltype (496 vs 497). Until
# this slice every column fc described was nullable; now a NOT NULL base
# column answers the even form, and the bit travels the engine's way:
# an expression is nullable only when an input is (arithmetic, negation,
# CAST, ||, the string/date functions, CASE/IIF by their branches);
# COALESCE, NULLIF, a boolean, a parameter and a subquery are always
# nullable; COUNT never is, SUM/MAX/MIN/AVG are; an INNER JOIN keeps both
# sides, a LEFT/RIGHT/FULL nulls the extended side(s); a derived table, a
# CTE, DISTINCT/FIRST keep the inner bit; a GROUP BY key keeps the
# column's; a UNION is nullable when any branch is. Every statement runs
# through isql with SQLDA display on both servers and the sqltype lines
# are compared (probed laws; the TYPE widths fc already answers are not
# this gate's subject - see the recorded boundaries in the roadmap).
#
#   qa/serve-real-notnulldesc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4875}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-notnulldesc-crab.fdb"
B="$D/fc-notnulldesc-engine.fdb"
LOG="/tmp/fc-serve-notnulldesc-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER, S VARCHAR(5) NOT NULL);
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, AID INTEGER NOT NULL, W INTEGER);
COMMIT;
INSERT INTO A VALUES (1, NULL, 'a'); INSERT INTO A VALUES (2, 5, 'b');
INSERT INTO B VALUES (1, 1, NULL); INSERT INTO B VALUES (2, 1, 3);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# only the NULLABILITY of each output column: "NN" or "null" per position
run() { # <conn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
      | grep 'sqltype:' | sed 's/^\([0-9]*\): sqltype: [0-9]* [A-Z0-9 ]*\(Nullable\)\{0,1\} *scale.*/\1:\2/; s/:$/:NN/; s/:Nullable/:null/' | tr '\n' ' '
}
while IFS= read -r q; do
    [ -z "$q" ] && continue
    e=$(run "127.0.0.1/$REAL:$B" "$q"); c=$(run "127.0.0.1/$PORT:$A" "$q")
    check "$q -> $e" "$c" "$e"
done <<'SQL'
SELECT ID, V, S FROM A;
SELECT * FROM A WHERE ID > 0;
SELECT ID + 1, ID * 2, -ID, ID + V, ID - ID FROM A;
SELECT CAST(ID AS VARCHAR(10)), UPPER(S), S || 'x', ABS(ID), CHAR_LENGTH(S), SUBSTRING(S FROM 1 FOR 2) FROM A;
SELECT COALESCE(V, 0), COALESCE(V, ID), NULLIF(ID, 1), ID IS NULL, NULL FROM A;
SELECT CASE WHEN ID > 1 THEN 1 ELSE 2 END, CASE WHEN ID > 1 THEN 1 END, IIF(ID > 1, 1, 2), IIF(ID > 1, V, 2) FROM A;
SELECT 5, 'lit', CURRENT_DATE FROM A;
SELECT a.ID, a.V, b.ID, b.W, b.AID FROM A a JOIN B b ON b.AID = a.ID;
SELECT a.ID, b.ID, b.AID FROM A a LEFT JOIN B b ON b.AID = a.ID;
SELECT a.ID, b.ID FROM A a RIGHT JOIN B b ON b.AID = a.ID;
SELECT a.ID, b.ID FROM A a FULL JOIN B b ON b.AID = a.ID;
SELECT a.ID + b.ID, a.ID + b.W FROM A a JOIN B b ON b.AID = a.ID;
SELECT a.ID + 1, b.ID + 1 FROM A a LEFT JOIN B b ON b.AID = a.ID;
SELECT COUNT(*), COUNT(V), SUM(ID), MAX(ID), MIN(S), AVG(ID) FROM A;
SELECT ID FROM A GROUP BY ID;
SELECT ID, MAX(V) FROM A GROUP BY ID;
SELECT V, MAX(ID) FROM A GROUP BY V;
SELECT S, ID, COUNT(*) FROM A GROUP BY S, ID HAVING COUNT(*) > 0;
SELECT D.ID, D.V FROM (SELECT ID, V FROM A) D;
WITH C AS (SELECT ID, V FROM A) SELECT ID, V FROM C;
SELECT ID FROM A UNION ALL SELECT ID FROM B;
SELECT ID FROM A UNION ALL SELECT V FROM A;
SELECT FIRST 1 ID FROM A ORDER BY ID;
SELECT DISTINCT ID, V FROM A;
SELECT ROW_NUMBER() OVER (), ID FROM A;
SELECT a.ID FROM A a WHERE EXISTS (SELECT 1 FROM B b WHERE b.AID = a.ID);
SELECT ID FROM A WHERE ID = ?;
SQL
echo "ran $ran checks"
exit $fail
