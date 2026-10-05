#!/bin/bash
# A DECFLOAT IN PSQL: an EXECUTE BLOCK output, a local, a FOR SELECT INTO
# target - refused whole until this gate (the BLR compiler has no DECFLOAT
# descriptor, and the output reader it fell back to had no text type).
#
# Measured on 6.0.0.2196: a DECFLOAT(16) / (34) output describes as the
# column of that type does (Nullable); an assignment converts as the slot's
# CAST (R = 1 is 1, 'abc' the 22018 with the block location, 1.234567890
# 12345678 rounds to 16 digits); the arithmetic traps as SQL's does (R / 0
# the 22012, an overflow 22003, each `At block line`); a DECFLOAT local
# reads into SQL as its own value and cohort (`WHERE A > :R`, `TOTALORDER(R,
# 2.50)`); a DECFLOAT(16) NaN compares EQUAL to itself (`IF (R = R)` takes
# THEN). Fixed with it: an output list mixing a type the BLR compiler has
# (VARCHAR) with one it has not (DOUBLE, BOOLEAN, DECFLOAT) is typed per
# output, as the inputs already were.
#
# RECORDED: `R = 2.5e0` - the engine reads a double LITERAL from its text
# under the DECFLOAT target (2.5), this server converts the double (2.500
# 000000000000).
#
#   qa/serve-real-dfpsql.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4644}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfp-eng-$PORT.fdb"; FC="$D/dfp-fc-$PORT.fdb"
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
SET TERM ^;
CREATE PROCEDURE PD (X DECFLOAT(16)) RETURNS (R DECFLOAT(34)) AS BEGIN R = X * 2; SUSPEND; END^
CREATE FUNCTION FD (X DECFLOAT(34)) RETURNS DECFLOAT(16) AS BEGIN RETURN X / 4; END^
CREATE PROCEDURE PE (X INT) RETURNS (R DECFLOAT(16), C VARCHAR(5)) AS BEGIN R = X; IF (R > 1) THEN C = 'big'; SUSPEND; R = R / 0; SUSPEND; END^
SET TERM ;^
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/dfp-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/dfp-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dfp-$PORT.log" 2>&1 & srv=$!
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


echo "--- 1 a DECFLOAT output and local"
both "1 the describe; an assignment from a literal, a local, a column" "SET SQLDA_DISPLAY ON;
SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16), S DECFLOAT(34)) AS BEGIN R = 1.50; S = R * 3; SUSPEND; END^
SET SQLDA_DISPLAY OFF^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = 1; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS DECLARE X DECFLOAT(16) = 2; BEGIN R = X + 1; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN SELECT A FROM T WHERE ID = 1 INTO R; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(34)) AS BEGIN R = CAST('2.50' AS DECFLOAT(16)); SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = 1.23456789012345678; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = NULL; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = -R; SUSPEND; END^
SET TERM ;^"
both "1 a loop, a FOR SELECT, the functions" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS DECLARE I INT = 0; BEGIN R = 0; WHILE (I < 5) DO BEGIN R = R + 0.1; I = I + 1; END SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN FOR SELECT A FROM T WHERE ID < 4 ORDER BY ID INTO R DO SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(34)) AS BEGIN R = QUANTIZE(CAST(2.555 AS DECFLOAT(34)), CAST(0.01 AS DECFLOAT(34))); SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = ABS(CAST(-2.555 AS DECFLOAT(16))); SUSPEND; END^
SET TERM ;^"
both "1 a local read into SQL keeps its value and cohort" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16), C SMALLINT) AS BEGIN R = 2.5; C = TOTALORDER(R, 2.50); SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16), N INT) AS BEGIN R = 1.1; SELECT COUNT(*) FROM T WHERE A > :R INTO N; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(34), N INT) AS BEGIN R = CAST('Infinity' AS DECFLOAT(34)); SELECT COUNT(*) FROM T WHERE B < :R INTO N; SUSPEND; END^
SET TERM ;^"

echo "--- 2 conditions; the traps"
both "2 IF over a DECFLOAT local; a DECFLOAT(16) NaN equals itself" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16), C VARCHAR(10), B BOOLEAN) AS BEGIN R = 1; IF (R > 0) THEN C = 'gt'; B = R < 2; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16), C VARCHAR(10)) AS BEGIN R = CAST('NaN' AS DECFLOAT(16)); IF (R = R) THEN C = 'eq'; ELSE C = 'ne'; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16), C VARCHAR(10)) AS BEGIN SELECT A FROM T WHERE ID = 5 INTO R; IF (R = 3) THEN C = 'eq'; ELSE C = 'ne'; SUSPEND; END^
SET TERM ;^"
both "2 a zero divisor, an overflow, a bad text: the vector and the block location" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = 1; R = R / 0; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = CAST('9E384' AS DECFLOAT(34)) * 10; SUSPEND; END^
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = 'abc'; SUSPEND; END^
SET TERM ;^"

echo "--- 3 an output list mixing the compiler's types with the reader's"
both "3 DOUBLE / DECFLOAT / BOOLEAN beside VARCHAR / CHAR" "SET SQLDA_DISPLAY ON;
SET TERM ^;
EXECUTE BLOCK RETURNS (R DOUBLE PRECISION, C VARCHAR(10)) AS BEGIN R = 1; C = 'x'; SUSPEND; END^
EXECUTE BLOCK RETURNS (C CHAR(3), R DECFLOAT(34), B BOOLEAN, I INTEGER) AS BEGIN C = 'ab'; R = 7; B = TRUE; I = 2; SUSPEND; END^
SET TERM ;^"

echo "--- 4 a stored procedure / function with DECFLOAT parameters (made by the engine)"
both "4 a procedure: the describe, an exact / text / NULL argument, EXECUTE PROCEDURE" "SET SQLDA_DISPLAY ON;
SELECT * FROM PD(1.25);
SET SQLDA_DISPLAY OFF;
SELECT * FROM PD('3.5'); SELECT R FROM PD(NULL); EXECUTE PROCEDURE PD(2);"
both "4 a procedure's IF, SUSPEND, and its zero divisor's location" "SELECT * FROM PE(2);"
both "4 a function: the describe, over a NaN, a column, in WHERE and arithmetic, a bad text" "SET SQLDA_DISPLAY ON;
SELECT FD(10) FROM RDB\$DATABASE;
SET SQLDA_DISPLAY OFF;
SELECT FD(CAST('NaN' AS DECFLOAT(34))) FROM RDB\$DATABASE; SELECT ID, FD(B) FROM T WHERE ID < 4 ORDER BY ID; SELECT ID FROM T WHERE FD(B) > 0.3 ORDER BY ID; SELECT FD(NULL) FROM RDB\$DATABASE;
SELECT FD(1) + 1, FD('abc') FROM RDB\$DATABASE;"

echo "--- 5 RECORDED"
rec "5 RECORDED a double LITERAL into a DECFLOAT local is read from its text" "SET TERM ^;
EXECUTE BLOCK RETURNS (R DECFLOAT(16)) AS BEGIN R = 2.5e0; SUSPEND; END^
SET TERM ;^" ' R|=======================| 2.5|X|======|DONE|' ' R|=======================| 2.500000000000000|X|======|DONE|'
rec "5 RECORDED a duplicate output name: the engine's -637 here a bare refusal (pre-existing)" "SET TERM ^;
EXECUTE BLOCK RETURNS (R INT, R INT) AS BEGIN SUSPEND; END^
SET TERM ;^" 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -637|-duplicate specification of "R" - not supported|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'

rec "5 RECORDED CREATE PROCEDURE / FUNCTION with a DECFLOAT parameter (the BLR compiler has no DECFLOAT dsc)" "SET TERM ^;
CREATE PROCEDURE PD2 (X DECFLOAT(16)) RETURNS (R DECFLOAT(34)) AS BEGIN R = X; SUSPEND; END^
SET TERM ;^
ROLLBACK;" 'X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|X|======|DONE|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dfp-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 13 ]; then echo "FAIL only $ran checks ran (floor 13) - cells went missing"; fail=1; fi
exit $fail
