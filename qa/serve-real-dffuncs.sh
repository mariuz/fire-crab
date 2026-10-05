#!/bin/bash
# QUANTIZE, NORMALIZE_DECFLOAT, COMPARE_DECFLOAT and TOTALORDER - the four
# DECFLOAT functions, refused at prepare until this gate.
#
# Measured on 6.0.0.2196: QUANTIZE(x, y) rounds x HALF-UP to y's exponent
# (1.2355 at 0.001 is 1.236), keeps x's sign (a -0 too), and past the
# result's precision or with exactly one Infinity is the 22000 invalid
# operation (NaN under SET DECFLOAT TRAPS TO). NORMALIZE_DECFLOAT strips
# the trailing zeros (100 is 1E+2, -0.00 is -0). Both describe DECFLOAT(34)
# only when the FIRST operand is one - an exact, a double, a text and a
# DECFLOAT(16) give DECFLOAT(16) (makeDecFloatResult). COMPARE_DECFLOAT is a
# SMALLINT by TOTAL order - 0 equal, 1 less, 2 greater (1.0 against 1 is 1)
# - and 3 when either side is a NaN; TOTALORDER is -1 / 0 / 1 by IEEE 754
# totalOrder (-0 < 0, 1.00 < 1.0 < 1, -1 < -1.0, NaN beyond +Infinity).
#
# BOUNDARY: a signalling or a negative NaN has no form in this server's
# decoded DECFLOAT; its CAST refuses, so TOTALORDER over one refuses.
#
#   qa/serve-real-dffuncs.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4643}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dff-eng-$PORT.fdb"; FC="$D/dff-fc-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INT, A DECFLOAT(16), B DECFLOAT(34), I INT, N NUMERIC(9,2), DP DOUBLE PRECISION, S VARCHAR(20));
INSERT INTO T VALUES (1, 1.2345, 1.2345, 7, 1.50, 2.5, '1.0');
INSERT INTO T VALUES (2, 1.00, -1.0, -3, -0.25, -0.125, '-2.50');
INSERT INTO T VALUES (3, 100, 1E+2, 0, 0, 0, '0.00');
INSERT INTO T VALUES (4, CAST('Infinity' AS DECFLOAT(16)), CAST('-Infinity' AS DECFLOAT(34)), 1, 1, 1, '1E+3');
INSERT INTO T VALUES (5, CAST('NaN' AS DECFLOAT(16)), CAST('NaN' AS DECFLOAT(34)), 2, 2, 2, '7');
INSERT INTO T VALUES (6, -CAST(0.00 AS DECFLOAT(16)), -CAST(0 AS DECFLOAT(34)), 5, 5, 5, '5');
INSERT INTO T VALUES (7, NULL, NULL, NULL, NULL, NULL, NULL);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/dff-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/dff-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dff-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch "${3:-UTF8}" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ -z "$2" ]; then echo "FAIL $1 [the engine answered nothing]"; fail=1
    elif [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
both() { check "$1" "$(run "127.0.0.1/$REAL:$ENG" "$2" "${3:-UTF8}")" "$(run "127.0.0.1/$PORT:$FC" "$2" "${3:-UTF8}")"; }

rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}

boundary() { # <label> <sql> <the engine's pinned answer> - THIS server must REFUSE it
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "${c#*Statement failed}" = "$c" ] || [ "${c%DONE|}" = "$c" ]; then echo "FAIL $1 - this server must refuse it, and answered [$c]"; fail=1
    else echo "OK   $1 (boundary: the engine's answer is garbage, this server refuses)"; fi
}

boundary() { # <label> <sql> <the engine's pinned answer> - THIS server must REFUSE it
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "${c#*Statement failed}" = "$c" ] || [ "${c%DONE|}" = "$c" ]; then echo "FAIL $1 - this server must refuse it, and answered [$c]"; fail=1
    else echo "OK   $1 (boundary: no form here, this server refuses)"; fi
}

D16="CAST(%s AS DECFLOAT(16))"; D34="CAST(%s AS DECFLOAT(34))"
echo "--- 1 the four functions over DECFLOAT columns (describe and value)"
both "1 QUANTIZE / NORMALIZE_DECFLOAT over both widths: the first operand's type" "SET SQLDA_DISPLAY ON;
SELECT ID, QUANTIZE(A, CAST(0.01 AS DECFLOAT(16))) Q1, QUANTIZE(B, CAST(0.01 AS DECFLOAT(16))) Q2, QUANTIZE(A, CAST(0.001 AS DECFLOAT(34))) Q3, NORMALIZE_DECFLOAT(A) N1, NORMALIZE_DECFLOAT(B) N2 FROM T ORDER BY ID;"
both "1 COMPARE_DECFLOAT / TOTALORDER over the columns: SHORT, total order, NaN 3, NULL NULL" "SET SQLDA_DISPLAY ON;
SELECT ID, COMPARE_DECFLOAT(A, B) C1, TOTALORDER(A, B) T1, COMPARE_DECFLOAT(B, A) C2, TOTALORDER(B, A) T2, COMPARE_DECFLOAT(A, A) C3, TOTALORDER(B, B) T3 FROM T ORDER BY ID;"
both "1 TOTALORDER as a sort key and a predicate" "SELECT T1.ID, T2.ID FROM T T1 JOIN T T2 ON TOTALORDER(T1.A, T2.A) = -1 ORDER BY 1, 2;
SELECT ID FROM T WHERE COMPARE_DECFLOAT(A, 1) = 0 ORDER BY ID; SELECT ID FROM T WHERE COMPARE_DECFLOAT(A, 1) = 3 ORDER BY ID;"

echo "--- 2 the cohort laws"
both "2 QUANTIZE rounds HALF-UP to the pattern's exponent, either way, keeping x's sign" "SELECT QUANTIZE(CAST(1.2355 AS DECFLOAT(16)), CAST(0.001 AS DECFLOAT(34))) A1, QUANTIZE(CAST(-1.2345 AS DECFLOAT(34)), CAST(1E-3 AS DECFLOAT(34))) A2, QUANTIZE(CAST(123 AS DECFLOAT(34)), CAST(1E1 AS DECFLOAT(34))) A3, QUANTIZE(CAST(125 AS DECFLOAT(16)), CAST('1E+1' AS DECFLOAT(16))) A4, QUANTIZE(CAST(5 AS DECFLOAT(34)), CAST('1E-5' AS DECFLOAT(34))) A5, QUANTIZE(-CAST(0 AS DECFLOAT(34)), CAST(0.01 AS DECFLOAT(34))) A6, QUANTIZE(CAST('1E-6000' AS DECFLOAT(34)), CAST(1 AS DECFLOAT(34))) A7, QUANTIZE(CAST(0.5 AS DECFLOAT(16)), CAST(7 AS DECFLOAT(16))) A8 FROM RDB\$DATABASE;"
both "2 NORMALIZE_DECFLOAT strips the trailing zeros; a zero is +-0E0" "SELECT NORMALIZE_DECFLOAT(CAST(1.500 AS DECFLOAT(16))) B1, NORMALIZE_DECFLOAT(CAST(100 AS DECFLOAT(34))) B2, NORMALIZE_DECFLOAT(-CAST(0.00 AS DECFLOAT(34))) B3, NORMALIZE_DECFLOAT(CAST('0E+5' AS DECFLOAT(16))) B4, NORMALIZE_DECFLOAT(CAST('1.2300E+10' AS DECFLOAT(34))) B5, NORMALIZE_DECFLOAT(CAST('-1E+384' AS DECFLOAT(16))) B6 FROM RDB\$DATABASE;"
both "2 total order among equal values: cohorts, signed zeros, infinities" "SELECT COMPARE_DECFLOAT(CAST('1.0' AS DECFLOAT(34)), CAST('1' AS DECFLOAT(34))) C1, TOTALORDER(CAST('-1.0' AS DECFLOAT(34)), CAST('-1' AS DECFLOAT(34))) C2, TOTALORDER(-CAST(0 AS DECFLOAT(34)), CAST(0 AS DECFLOAT(34))) C3, TOTALORDER(CAST(0.0 AS DECFLOAT(34)), CAST(0 AS DECFLOAT(34))) C4, COMPARE_DECFLOAT(CAST('Inf' AS DECFLOAT(34)), CAST('Inf' AS DECFLOAT(34))) C5, TOTALORDER(CAST('Inf' AS DECFLOAT(34)), CAST('9E6144' AS DECFLOAT(34))) C6, TOTALORDER(CAST('2' AS DECFLOAT(34)), CAST('1E1' AS DECFLOAT(34))) C7, TOTALORDER(CAST('1E1' AS DECFLOAT(34)), CAST('10' AS DECFLOAT(34))) C8 FROM RDB\$DATABASE;"
both "2 a NaN: COMPARE 3 whatever the other side, TOTALORDER beyond +Infinity" "SELECT COMPARE_DECFLOAT(CAST('NaN' AS DECFLOAT(34)), CAST('NaN' AS DECFLOAT(34))) D1, TOTALORDER(CAST('NaN' AS DECFLOAT(34)), CAST('NaN' AS DECFLOAT(34))) D2, TOTALORDER(CAST('NaN' AS DECFLOAT(16)), CAST('Inf' AS DECFLOAT(16))) D3, TOTALORDER(1, CAST('NaN' AS DECFLOAT(34))) D4, COMPARE_DECFLOAT(CAST('-Inf' AS DECFLOAT(34)), CAST('NaN' AS DECFLOAT(34))) D5 FROM RDB\$DATABASE;"

echo "--- 3 operands that are no DECFLOAT"
both "3 an exact, a double, a text, a BIGINT, a column: DECFLOAT(16) unless the FIRST is a DECFLOAT(34)" "SET SQLDA_DISPLAY ON;
SELECT NORMALIZE_DECFLOAT(100) A, NORMALIZE_DECFLOAT(1.50) B, NORMALIZE_DECFLOAT(2.5e0) C, QUANTIZE(1.2345, 0.01) D, QUANTIZE(1.2345, CAST(0.01 AS DECFLOAT(34))) E, NORMALIZE_DECFLOAT('1.50') G, NORMALIZE_DECFLOAT(CAST(100 AS BIGINT)) H FROM RDB\$DATABASE;
SELECT ID, NORMALIZE_DECFLOAT(N) N1, QUANTIZE(DP, 0.1) Q1, NORMALIZE_DECFLOAT(S) S1, COMPARE_DECFLOAT(I, N) C1, TOTALORDER(S, A) T1 FROM T WHERE ID <> 7 ORDER BY ID;"
both "3 COMPARE / TOTALORDER over exact, double and text operands; NULL" "SET SQLDA_DISPLAY ON;
SELECT COMPARE_DECFLOAT(2.5e0, 2.50) A, TOTALORDER('1.0', 1) B, COMPARE_DECFLOAT(NULL, NULL) C, TOTALORDER(1.0, 1) D, COMPARE_DECFLOAT(1, 1.0) E, QUANTIZE(NULL, 1) F, NORMALIZE_DECFLOAT(NULL) G FROM RDB\$DATABASE;"
both "3 a text no decimal reads: the conversion error" "SELECT NORMALIZE_DECFLOAT('abc') X FROM RDB\$DATABASE; SELECT COMPARE_DECFLOAT(1, 'x') Y FROM RDB\$DATABASE;"

echo "--- 4 QUANTIZE's invalid operation; the traps"
both "4 past the precision, an exponent out of range, one Infinity: 22000" "SELECT QUANTIZE(CAST(1 AS DECFLOAT(34)), CAST('1E-6176' AS DECFLOAT(34))) Q1 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST(1 AS DECFLOAT(34)), CAST('1E-34' AS DECFLOAT(34))) Q3 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST(1 AS DECFLOAT(16)), CAST('1E-16' AS DECFLOAT(16))) Q4 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST(1 AS DECFLOAT(34)), CAST('1E-33' AS DECFLOAT(34))) Q2 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST('Inf' AS DECFLOAT(34)), 1) Q7 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST(1 AS DECFLOAT(34)), CAST('-Inf' AS DECFLOAT(34))) Q8 FROM RDB\$DATABASE;
SELECT QUANTIZE(CAST('Inf' AS DECFLOAT(34)), CAST('-Inf' AS DECFLOAT(34))) Q9, QUANTIZE(CAST('NaN' AS DECFLOAT(16)), 1) Q10 FROM RDB\$DATABASE;"
both "4 the Invalid trap stood down: NaN" "SET DECFLOAT TRAPS TO;
SELECT QUANTIZE(CAST(1 AS DECFLOAT(34)), CAST('1E-34' AS DECFLOAT(34))) Q5, QUANTIZE(CAST(1 AS DECFLOAT(16)), CAST('1E-16' AS DECFLOAT(16))) Q6, QUANTIZE(CAST('Inf' AS DECFLOAT(34)), 1) Q7 FROM RDB\$DATABASE;"
both "4 a row whose QUANTIZE raises stops the fetch; the rows before it arrive" "SELECT ID, QUANTIZE(A, CAST(0.01 AS DECFLOAT(16))) Q FROM T ORDER BY ID;"

echo "--- 5 BOUNDARY: a signalling or negative NaN has no form here"
boundary "5 BOUNDARY TOTALORDER over an sNaN" "SELECT TOTALORDER(CAST('sNaN' AS DECFLOAT(34)), CAST('NaN' AS DECFLOAT(34))) T FROM RDB\$DATABASE;" ' T|=======| -1|X|======|DONE|'
boundary "5 BOUNDARY TOTALORDER over a -NaN" "SELECT TOTALORDER(CAST('-NaN' AS DECFLOAT(34)), CAST('-Inf' AS DECFLOAT(34))) T FROM RDB\$DATABASE;" ' T|=======| -1|X|======|DONE|'

echo "--- 6 the routers: DML, arithmetic, conditionals, aggregates, ORDER BY, PSQL"
both "6 an UPDATE / INSERT stores the function's value" "UPDATE T SET B = QUANTIZE(B, CAST(0.001 AS DECFLOAT(34))) WHERE ID = 1; SELECT B FROM T WHERE ID = 1;
INSERT INTO T (ID, A) VALUES (9, NORMALIZE_DECFLOAT(CAST(5.000 AS DECFLOAT(16)))); SELECT A FROM T WHERE ID = 9; ROLLBACK;"
both "6 under arithmetic, a minus, COALESCE, IIF, a cast to text" "SELECT QUANTIZE(A, CAST(0.01 AS DECFLOAT(16))) + 1 X, -NORMALIZE_DECFLOAT(B) Y, COALESCE(QUANTIZE(B, 1), 0) Z FROM T WHERE ID = 2;
SELECT CAST(NORMALIZE_DECFLOAT(A) AS VARCHAR(30)) || '|' V FROM T WHERE ID = 3;
SELECT ID, IIF(COMPARE_DECFLOAT(A, B) = 0, 'eq', 'ne') E FROM T WHERE ID < 4 ORDER BY ID;"
both "6 aggregated and as a sort key" "SELECT MAX(TOTALORDER(A, B)) M, SUM(COMPARE_DECFLOAT(A, B)) S FROM T; SELECT ID FROM T ORDER BY TOTALORDER(A, 1), ID;"
both "6 PSQL: TOTALORDER / COMPARE_DECFLOAT into a SMALLINT" "SET TERM ^;
EXECUTE BLOCK RETURNS (C SMALLINT, K SMALLINT) AS BEGIN C = TOTALORDER(CAST(1 AS DECFLOAT(16)), 2); K = COMPARE_DECFLOAT(CAST('NaN' AS DECFLOAT(16)), 1); SUSPEND; END^
SET TERM ;^"
rec "6 RECORDED GROUP BY a DECFLOAT-valued function (ABS too - every decfloat expression key)" "SELECT NORMALIZE_DECFLOAT(A) G, COUNT(*) FROM T WHERE ID IN (1,2,3) GROUP BY NORMALIZE_DECFLOAT(A) ORDER BY 1;" ' G COUNT|======================= =====================| 1 1| 1.2345 1| 1E+2 1|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'
rec "6 RECORDED PSQL assigning a DECFLOAT-valued function (ABS too)" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = NORMALIZE_DECFLOAT(CAST(2.50 AS DECFLOAT(16))); SUSPEND; END^
SET TERM ;^" ' R|=======================| 2.5|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dff-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 22 ]; then echo "FAIL only $ran checks ran (floor 22) - cells went missing"; fail=1; fi
exit $fail
