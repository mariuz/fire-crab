#!/bin/bash
# ROUND over an APPROXIMATE value is an EXACT scaled value that DESCRIBES as
# DOUBLE (FLOAT for a FLOAT operand) - the engine's evlRound builds an INT64
# of scale -n (0 for n <= 0) and the describe keeps the operand's type.
# What sees the exact value, and what sees a double, was measured shape by
# shape against the live engine:
#
#   EXACT  a CAST to text (`CAST(ROUND(dp, 2) AS VARCHAR(20))` is '2.68',
#          ROUND(0.1, 2) '0.10', ROUND(-0.001, 2) '0.00', ROUND(dp) '3',
#          ROUND(dp, -2) '1200'), a `||`, a derived-table pass-through, a
#          unary minus, and every STORE: INTEGER 3, NUMERIC(9,1) 2.7,
#          NUMERIC(18,3) 2.680, DOUBLE 2.68, DECFLOAT(34) / (16) 2.68,
#          VARCHAR '2.68', an UPDATE through a subquery '2.7'.
#   DOUBLE arithmetic (ROUND(dp, 2) * 3 is 8.040000000000001), comparisons,
#          ORDER BY, DISTINCT, a COALESCE / IIF (typed DOUBLE:
#          CAST(COALESCE(ROUND(dp, 2), 0) AS VARCHAR) is '2.680000000000000'),
#          MIN / MAX, a UNION with a DOUBLE branch.
#
# fire-crab carried a double, so every EXACT consumer rendered
# '2.680000000000000', and INSERT .. SELECT ROUND(dp, 2) into a DECFLOAT
# column refused. Also here: an APPROXIMATE operand converted to text
# announces its render width - `DP || ''` is VARYING(24), a FLOAT one 15 -
# where fire-crab announced 32765.
#
# Usage: qa/serve-real-roundexact.sh [port]   (default 4182)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4182}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/rndx-eng.fdb"; FC="$D/rndx-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/rndx-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, DP DOUBLE PRECISION, FL FLOAT, G INTEGER);
INSERT INTO T VALUES (1, 2.675, 2.675, 1);
INSERT INTO T VALUES (2, 9.995, 9.995, 1);
INSERT INTO T VALUES (3, 145.045, 145.045, 2);
INSERT INTO T VALUES (4, -2.675, -2.675, 2);
INSERT INTO T VALUES (5, 1234.5678, 1234.5678, 3);
INSERT INTO T VALUES (6, 0.1, 0.1, 3);
INSERT INTO T VALUES (8, 2.6800000000000002, 2.68, 4);
INSERT INTO T VALUES (9, -0.001, -0.001, 4);
CREATE TABLE WV (ID INTEGER, V VARCHAR(30));
CREATE TABLE WD (ID INTEGER, D34 DECFLOAT(34));
CREATE TABLE WI (ID INTEGER, I INTEGER, N91 NUMERIC(9,1), D DOUBLE PRECISION, D16 DECFLOAT(16), N183 NUMERIC(18,3));
COMMIT;
SQL
if grep -qi error /tmp/rndx-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/rndx-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-rndx.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
q() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -a -v '^$' | grep -a -v 'INPUT message\|OUTPUT message\|: name:\|: table:' | sed 's/[[:space:]][[:space:]]*/ /g' | tr '\n' '|'; }
agree() {
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
}

echo "-- EXACT consumers: text --"
agree "CAST(ROUND(DP, 2) AS VARCHAR(20)) every row"  "SELECT ID, CAST(ROUND(DP, 2) AS VARCHAR(20)) FROM T ORDER BY ID;"
agree "ROUND(DP) / ROUND(DP, -2) / ROUND(DP, 1) text" "SELECT ID, CAST(ROUND(DP) AS VARCHAR(20)), CAST(ROUND(DP, -2) AS VARCHAR(20)), CAST(ROUND(DP, 1) AS VARCHAR(20)) FROM T ORDER BY ID;"
agree "ROUND(FL, 2) text"                            "SELECT ID, CAST(ROUND(FL, 2) AS VARCHAR(20)) FROM T ORDER BY ID;"
agree "ROUND(DP, 2) || '|' (width 25)"               "SELECT ROUND(DP, 2) || '|' FROM T ORDER BY ID;"
agree "ROUND(FL, 2) || '' (width 15)"                "SELECT ROUND(FL, 2) || '' FROM T ORDER BY ID;"
agree "-ROUND(DP, 2) and ROUND(-DP, 2) text"         "SELECT ID, CAST(-ROUND(DP, 2) AS VARCHAR(20)), CAST(ROUND(-DP, 2) AS VARCHAR(20)) FROM T WHERE ID IN (1, 9) ORDER BY ID;"
agree "a derived-table column keeps it"              "SELECT CAST(R AS VARCHAR(20)) FROM (SELECT ROUND(DP, 2) R FROM T WHERE ID = 1) Q;"
agree "text GROUP BY"                                "SELECT CAST(ROUND(DP, 2) AS VARCHAR(20)) R, COUNT(*) FROM T GROUP BY 1 ORDER BY 1;"
agree "text UNION of two ROUNDs"                     "SELECT CAST(ROUND(DP, 2) AS VARCHAR(20)) FROM T WHERE ID = 1 UNION ALL SELECT CAST(ROUND(DP, 1) AS VARCHAR(20)) FROM T WHERE ID = 6;"
agree "CAST(ROUND(DP, 2) AS VARCHAR(3)) raises"      "SELECT CAST(ROUND(DP, 2) AS VARCHAR(3)) FROM T WHERE ID = 1;"
agree "constant ROUND(2.675e0, 2) text"              "SELECT ROUND(2.675e0, 2), CAST(ROUND(2.675e0, 2) AS VARCHAR(20)) FROM RDB\$DATABASE;"
echo "-- EXACT consumers: stores --"
agree "INSERT .. SELECT into VARCHAR"   "INSERT INTO WV (ID, V) SELECT ID, ROUND(DP, 2) FROM T WHERE ID IN (1, 6, 9); SELECT ID, V FROM WV ORDER BY ID;"
agree "INSERT .. SELECT into DECFLOAT(34)" "INSERT INTO WD (ID, D34) SELECT ID, ROUND(DP, 2) FROM T WHERE ID IN (1, 6, 9); SELECT ID, D34 FROM WD ORDER BY ID;"
agree "INSERT .. SELECT into INTEGER / NUMERIC / DOUBLE / DECFLOAT(16) / NUMERIC(18,3)" "INSERT INTO WI (ID, I, N91, D, D16, N183) SELECT ID, ROUND(DP, 2), ROUND(DP, 2), ROUND(DP, 2), ROUND(DP, 2), ROUND(DP, 2) FROM T WHERE ID IN (1, 2, 6); SELECT ID, I, N91, D, D16, N183 FROM WI ORDER BY ID;"
agree "INSERT .. SELECT ROUND(DP, -2) into INTEGER / VARCHAR / DECFLOAT" "DELETE FROM WI; INSERT INTO WI (ID, I, D, D16) SELECT ID, ROUND(DP, -2), ROUND(DP, -2), ROUND(DP, -2) FROM T WHERE ID IN (1, 3, 5); SELECT ID, I, D, D16 FROM WI ORDER BY ID;"
agree "UPDATE through a correlated subquery"  "UPDATE WV SET V = (SELECT ROUND(DP, 1) FROM T WHERE T.ID = WV.ID); SELECT ID, V FROM WV ORDER BY ID;"
agree "INSERT .. SELECT -ROUND into DECFLOAT" "DELETE FROM WD; INSERT INTO WD (ID, D34) SELECT ID, -ROUND(DP, 2) FROM T WHERE ID IN (1, 4); SELECT ID, D34 FROM WD ORDER BY ID;"
echo "-- DOUBLE consumers --"
agree "ROUND(DP, 2) itself describes DOUBLE"   "SELECT ID, ROUND(DP, 2), ROUND(FL, 2) FROM T WHERE ID IN (1, 6) ORDER BY ID;"
agree "arithmetic is double"                   "SELECT ID, ROUND(DP, 2) + 0.001, ROUND(DP, 2) * 3, ROUND(DP, 2) / 7 FROM T WHERE ID IN (1, 6) ORDER BY ID;"
agree "CAST(arithmetic AS VARCHAR)"            "SELECT CAST(ROUND(DP, 2) * 3 AS VARCHAR(30)) FROM T WHERE ID = 1;"
agree "compare with literals"                  "SELECT ID FROM T WHERE ROUND(DP, 2) IN (2.68, 0.1) ORDER BY ID;"
agree "compare with the DOUBLE column"         "SELECT ID FROM T WHERE ROUND(DP, 2) = DP ORDER BY ID;"
agree "ORDER BY"                               "SELECT ID FROM T ORDER BY ROUND(DP, 2), ID;"
agree "COUNT(DISTINCT)"                        "SELECT COUNT(DISTINCT ROUND(DP, 2)) FROM T;"
agree "COALESCE is DOUBLE"                     "SELECT CAST(COALESCE(ROUND(DP, 2), 0) AS VARCHAR(20)) FROM T WHERE ID = 1;"
agree "IIF is DOUBLE"                          "SELECT CAST(IIF(ID > 0, ROUND(DP, 2), DP) AS VARCHAR(20)) FROM T WHERE ID = 1;"
agree "CASE is DOUBLE"                         "SELECT CAST(CASE WHEN ID > 0 THEN ROUND(DP, 2) END AS VARCHAR(20)) FROM T WHERE ID = 1;"
agree "UNION with a DOUBLE branch"             "SELECT CAST(X AS VARCHAR(30)) FROM (SELECT ROUND(DP, 2) X FROM T WHERE ID = 1 UNION ALL SELECT DP FROM T WHERE ID = 6) Q;"
agree "nested ROUND(ROUND(DP, 2), 1)"          "SELECT ROUND(ROUND(DP, 2), 1), CAST(ROUND(ROUND(DP, 2), 1) AS VARCHAR(20)) FROM T WHERE ID = 1;"
agree "ABS(ROUND(DP, 2)) text and value"      "SELECT ABS(ROUND(DP, 2)), CAST(ABS(ROUND(DP, 2)) AS VARCHAR(20)) FROM T WHERE ID = 4;"
agree "TRUNC stays a double"                   "SELECT CAST(TRUNC(DP, 2) AS VARCHAR(30)) FROM T WHERE ID IN (1, 3) ORDER BY ID;"
echo "-- the approximate text width --"
agree "DP || '' is VARYING(24)"                "SELECT DP || '' FROM T WHERE ID = 1;"
agree "FL || '' width"                         "SELECT FL || '' FROM T WHERE ID = 1;"
agree "(DP * 2) || 'x' width"                  "SELECT (DP * 2) || 'x' FROM T WHERE ID = 1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS roundexact" || echo "FAIL roundexact"
exit $fail
