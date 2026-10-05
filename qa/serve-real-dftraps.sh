#!/bin/bash
# SET DECFLOAT TRAPS TO [..] AND SET DECFLOAT ROUND <mode> - session state.
#
# Both refused here (the paper's samples/nodejs/numerics.js: `1/0 after SET
# DECFLOAT TRAPS TO : Infinity`). Measured on 6.0.0.2196: with a trap stood
# down a DECFLOAT x / 0 answers a SIGNED Infinity, 0 / 0 NaN and an
# overflow Infinity; RDB$GET_CONTEXT('SYSTEM', 'DECFLOAT_TRAPS') reads the
# mask back in the engine's order (`None` when empty); an unknown trap or
# mode is the engine's bare 42000 *Invalid decfloat trap state @1* /
# *rounding mode @1*; and a new attachment starts from the default
# (Division_by_zero, Invalid_operation, Overflow).
#
# Answered: those three traps in any combination over DECFLOAT arithmetic,
# and SET DECFLOAT ROUND <mode> for all eight modes (7): an operation's
# result, a narrowing, a text or a wide literal converted in, QUANTIZE,
# ROUND and a CAST out all round by it; TRUNC / CEILING / FLOOR keep their
# own direction. Recorded: an Inexact or Underflow trap refuses. A stood-down trap reaches every site (6): EXP / POWER / LOG answer
# the special of the TRUE sign, SUM / AVG / VAR carry it on, and a
# conversion answers 0 at an exact target (Invalid) and the float's own
# Infinity / NaN at DOUBLE and FLOAT - except a NaN into a SCALED BIGINT or
# INT128, where the engine answers uninitialised garbage and this server
# refuses (BOUNDARY cells). THE SIGNED ZERO follows IEEE 754:
# a quotient or product keeps the XOR sign (0 / -2.5 is -0E+1), unary minus
# flips a zero, -0 + -0 is -0, x / -Infinity is -0 at the least exponent
# (-0E-398 / -0E-6176) - all pre-existing, found here. RECORDED: a NEGATED
# exact literal converts with its minus ONLY under a DECFLOAT item (CAST(-0.0
# AS DECFLOAT(16)) is -0.0 as the item, '0.0' cast on to VARCHAR) - the
# engine's preferred-descriptor literal fold; this server answers +0.
#
#   qa/serve-real-dftraps.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4642}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dft-eng-$PORT.fdb"; FC="$D/dft-fc-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INT, X DECFLOAT(16), Y DECFLOAT(34));
INSERT INTO T VALUES (1, 1, 0);
INSERT INTO T VALUES (2, -2.5, 0);
INSERT INTO T VALUES (3, 0, 0);
INSERT INTO T VALUES (4, 7, 2);
CREATE TABLE Z (ID INT, D16 DECFLOAT(16), D34 DECFLOAT(34), I INT, N NUMERIC(9,2));
INSERT INTO Z VALUES (1, -CAST(0 AS DECFLOAT(16)), CAST(-0.00 AS DECFLOAT(34)), 0, 0);
INSERT INTO Z VALUES (2, 0, 0, 0, 0);
INSERT INTO Z VALUES (3, CAST(-0.0 AS DECFLOAT(16)), -CAST(0E5 AS DECFLOAT(34)), 0, 0);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/dft-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/dft-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dft-$PORT.log" 2>&1 & srv=$!
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

TR="RDB\$GET_CONTEXT('SYSTEM', 'DECFLOAT_TRAPS')"
echo "--- 1 every trap stood down: the special values"
both "1 x / 0, -x / 0, 0 / 0, an overflow, and the context variable" "SET DECFLOAT TRAPS TO;
SELECT CAST(1 AS DECFLOAT(16)) / 0 A, CAST(-1 AS DECFLOAT(34)) / 0 B, CAST(0 AS DECFLOAT(16)) / 0 C, CAST('1E6144' AS DECFLOAT(34)) * 10 O, $TR T FROM RDB\$DATABASE;"
both "1 ... over columns, per row" "SET DECFLOAT TRAPS TO;
SELECT ID, X / Y, X * 1E6144, Y / X FROM T ORDER BY ID;"
both "1 ... in a WHERE, an expression, an ORDER BY" "SET DECFLOAT TRAPS TO;
SELECT ID FROM T WHERE X / Y > 0 ORDER BY ID; SELECT ID, (X / Y) + 1 FROM T ORDER BY X / Y, ID;"

both "1 an untrapped NaN compares EQUAL, in DECFLOAT(34) too (=, >, ORDER BY)" "SET DECFLOAT TRAPS TO;
SELECT ID FROM T WHERE X / Y = X / Y ORDER BY ID; SELECT ID FROM T WHERE X / Y > 0 ORDER BY ID; SELECT ID FROM T ORDER BY X / Y, ID;"
both "1 CONTROL the default traps: a DECFLOAT(34) NaN compare raises 22000" "SELECT ID FROM T WHERE ID = 3 AND CAST('NaN' AS DECFLOAT(34)) > 0;"
both "1 a zero quotient or product keeps the operands' sign (traps or not)" "SELECT CAST(0 AS DECFLOAT(34)) / CAST(-2.5 AS DECFLOAT(16)) Q, CAST(0 AS DECFLOAT(16)) * -3 N, CAST(-1 AS DECFLOAT(16)) + 1 S FROM RDB\$DATABASE;"

both "1 an untrapped Overflow reaches a CAST too: text, a narrowing, either sign" "SET DECFLOAT TRAPS TO;
SELECT CAST('1E9999' AS DECFLOAT(16)) A1, CAST('-1E9999' AS DECFLOAT(34)) A2, CAST(CAST('1E385' AS DECFLOAT(34)) AS DECFLOAT(16)) A3, CAST(CAST('-1E385' AS DECFLOAT(34)) AS DECFLOAT(16)) A4, CAST(-1E300 AS DECFLOAT(16)) * 1E300 A5 FROM RDB\$DATABASE;"
both "1 CONTROL under the default traps the same CASTs raise 22003" "SELECT CAST('1E9999' AS DECFLOAT(16)) A1 FROM RDB\$DATABASE; SELECT CAST(CAST('1E385' AS DECFLOAT(34)) AS DECFLOAT(16)) A3 FROM RDB\$DATABASE;"

echo "--- 2 one trap at a time"
both "2 only Division_by_zero: 0 / 0 is NaN, 1 / 0 raises" "SET DECFLOAT TRAPS TO Division_by_zero;
SELECT $TR T FROM RDB\$DATABASE; SELECT CAST(0 AS DECFLOAT(16)) / 0 C FROM RDB\$DATABASE; SELECT CAST(1 AS DECFLOAT(16)) / 0 A FROM RDB\$DATABASE;"
both "2 only Invalid_operation: 1 / 0 is Infinity, 0 / 0 raises" "SET DECFLOAT TRAPS TO Invalid_operation;
SELECT $TR T FROM RDB\$DATABASE; SELECT CAST(1 AS DECFLOAT(16)) / 0 A FROM RDB\$DATABASE; SELECT CAST(0 AS DECFLOAT(16)) / 0 C FROM RDB\$DATABASE;"
both "2 Overflow, Division_by_zero (any order, any case)" "SET DECFLOAT TRAPS TO overflow, DIVISION_BY_ZERO;
SELECT $TR T FROM RDB\$DATABASE; SELECT CAST(0 AS DECFLOAT(16)) / 0 C FROM RDB\$DATABASE; SELECT CAST('1E6144' AS DECFLOAT(34)) * 10 O FROM RDB\$DATABASE;"

echo "--- 3 the session's own state; ROUND HALF_UP; the names"
both "3 a NEW attachment starts from the default traps" "SELECT $TR T, CAST(1 AS DECFLOAT(16)) / 3 X FROM RDB\$DATABASE; SELECT CAST(1 AS DECFLOAT(16)) / 0 A FROM RDB\$DATABASE;"
both "3 back to the default list" "SET DECFLOAT TRAPS TO;
SET DECFLOAT TRAPS TO Division_by_zero, Invalid_operation, Overflow;
SELECT $TR T FROM RDB\$DATABASE; SELECT CAST(1 AS DECFLOAT(16)) / 0 A FROM RDB\$DATABASE;"
both "3 ROUND HALF_UP is the rounding already" "SET DECFLOAT ROUND HALF_UP;
SELECT RDB\$GET_CONTEXT('SYSTEM', 'DECFLOAT_ROUND') R, CAST(2 AS DECFLOAT(16)) / 3 X, CAST(25 AS DECFLOAT(16)) / 1E1 Z FROM RDB\$DATABASE;"
both "3 an unknown trap and an unknown mode: the engine's bare 42000" "SET DECFLOAT TRAPS TO Nonsense;
SET DECFLOAT ROUND NOSUCH;
SELECT $TR T FROM RDB\$DATABASE;"

echo "--- 5 the signed zero (IEEE 754, whatever the traps)"
both "5 a text -0, a double -0e0 and a negated DECFLOAT keep the sign; the exact -0.0 itself has none" "SELECT CAST('-0' AS DECFLOAT(16)) F3, -0.0 F5, CAST(-0E0 AS DECFLOAT(16)) F7, -CAST(0.00 AS DECFLOAT(34)) F8 FROM RDB\$DATABASE;"
both "5 a NEGATED exact literal under a VARCHAR item, a concatenation or a WHERE is +0" "SELECT CAST(CAST(-0.0 AS DECFLOAT(16)) AS VARCHAR(10)) B, CAST(CAST(-0 AS DECFLOAT(16)) AS VARCHAR(10)) C, CAST(CAST(-0 AS DECFLOAT(34)) AS VARCHAR(10)) E, CAST(-0 AS DECFLOAT(16)) || '' K FROM RDB\$DATABASE;
SELECT ID FROM T WHERE CAST(CAST(-0 AS DECFLOAT(16)) AS VARCHAR(10)) = '0' AND ID = 1;"
both "5 unary minus flips a zero; -0 + -0 and -0 - 0 are -0, opposite signs +0" "SELECT -CAST(0 AS DECFLOAT(16)) G2, CAST(0 AS DECFLOAT(16)) - CAST(0 AS DECFLOAT(16)) G3, -CAST(0 AS DECFLOAT(16)) - CAST(0 AS DECFLOAT(16)) G4, -CAST(0 AS DECFLOAT(16)) + CAST(0 AS DECFLOAT(16)) G5, -CAST(0 AS DECFLOAT(34)) + -CAST(0.0 AS DECFLOAT(34)) G6 FROM RDB\$DATABASE;"
both "5 x / +-Infinity is a signed zero at the format's least exponent" "SELECT CAST(5 AS DECFLOAT(16)) / CAST('-Inf' AS DECFLOAT(16)) H1, CAST(5 AS DECFLOAT(16)) / CAST('Inf' AS DECFLOAT(16)) H2, CAST(5 AS DECFLOAT(34)) / CAST('-Inf' AS DECFLOAT(34)) H3, CAST(-5 AS DECFLOAT(34)) / CAST('-Inf' AS DECFLOAT(34)) H5 FROM RDB\$DATABASE;"
both "5 a -0 is EQUAL to 0, not less; ABS and SIGN of it are 0" "SELECT ABS(-CAST(0 AS DECFLOAT(16))) J1, SIGN(-CAST(0 AS DECFLOAT(16))) J2, -CAST(0 AS DECFLOAT(16)) = 0 J3, CAST(-0 AS DECFLOAT(16)) < 0 J4 FROM RDB\$DATABASE;"
both "5 a stored -0: read back, negated, summed, cast, compared" "SELECT ID, D16, D34 FROM Z ORDER BY ID;
SELECT CAST(-I AS DECFLOAT(16)) N1, CAST(-N AS DECFLOAT(34)) N2, -D16 N3, -(-D16) N4, D16 * -1 N5, D16 - D16 N6, D16 + D16 N7 FROM Z ORDER BY ID;
SELECT SUM(D16) S1, SUM(D34) S2, COUNT(DISTINCT D16) C1, AVG(D34) A1 FROM Z;
SELECT ID FROM Z WHERE D16 = 0 ORDER BY ID;
SELECT CAST(D16 AS VARCHAR(20)) V, CAST(D16 AS DOUBLE PRECISION) DP, CAST(D34 AS NUMERIC(18,2)) NN FROM Z ORDER BY ID;"
both "5 an UPDATE stores the flipped zero" "UPDATE Z SET D34 = -D34 WHERE ID = 2; SELECT D34 FROM Z WHERE ID = 2; ROLLBACK;"

echo "--- 6 a stood-down trap at a function, an aggregate, a conversion"
both "6 EXP / POWER overflow is the Infinity of the TRUE sign; POWER of a negative base invalid is NaN" "SET DECFLOAT TRAPS TO;
SELECT EXP(CAST(100000 AS DECFLOAT(34))) E1, POWER(CAST(10 AS DECFLOAT(34)), 7000) P2, POWER(CAST(0 AS DECFLOAT(34)), -1) P1 FROM RDB\$DATABASE;
SELECT POWER(CAST(-10 AS DECFLOAT(34)), 7001) N1, POWER(CAST(-10 AS DECFLOAT(34)), 7000) N2, POWER(CAST(-10 AS DECFLOAT(34)), 7001.0) N3, POWER(CAST(-8 AS DECFLOAT(34)), 0.5) N4, POWER(CAST(10 AS DECFLOAT(34)), -7000) N5 FROM RDB\$DATABASE;"
both "6 LOG over ln(1): the zero divisor is the Infinity of ln(value)'s sign, 0 / 0 NaN" "SET DECFLOAT TRAPS TO;
SELECT LOG(CAST(1 AS DECFLOAT(34)), 2) L1, LOG(CAST(1 AS DECFLOAT(34)), 0.5) L2, LOG(CAST(1 AS DECFLOAT(34)), 1) L3 FROM RDB\$DATABASE;"
both "6 each trap on its own: Overflow kept still yields NaN, Invalid kept still yields Infinity" "SET DECFLOAT TRAPS TO Overflow;
SELECT POWER(CAST(-8 AS DECFLOAT(34)), 0.5) A, LOG(CAST(1 AS DECFLOAT(34)), 2) B FROM RDB\$DATABASE;
SET DECFLOAT TRAPS TO Invalid_operation;
SELECT EXP(CAST(100000 AS DECFLOAT(34))) C FROM RDB\$DATABASE; SELECT POWER(CAST(-8 AS DECFLOAT(34)), 0.5) D FROM RDB\$DATABASE;"
both "6 CONTROL LN(0) / SQRT(-1) raise their own argument errors whatever the mask" "SET DECFLOAT TRAPS TO;
SELECT LN(CAST(0 AS DECFLOAT(34))) B FROM RDB\$DATABASE; SELECT SQRT(CAST(-1 AS DECFLOAT(34))) C FROM RDB\$DATABASE;"
both "6 SUM / AVG / VAR / a windowed SUM carry the special on" "SET DECFLOAT TRAPS TO;
SELECT SUM(X) S1 FROM (SELECT CAST('9E6144' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('9E6144' AS DECFLOAT(34)) FROM RDB\$DATABASE);
SELECT SUM(X) S2, AVG(X) A2 FROM (SELECT CAST('-9E6144' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('-9E6144' AS DECFLOAT(34)) FROM RDB\$DATABASE);
SELECT SUM(X) S3 FROM (SELECT CAST('9E384' AS DECFLOAT(16)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('9E384' AS DECFLOAT(16)) FROM RDB\$DATABASE);
SELECT AVG(X) A1 FROM (SELECT CAST('Inf' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('-Inf' AS DECFLOAT(34)) FROM RDB\$DATABASE);
SELECT VAR_POP(X) V1, STDDEV_SAMP(X) V2 FROM (SELECT CAST('9E6144' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('-9E6144' AS DECFLOAT(34)) FROM RDB\$DATABASE);
SELECT SUM(X) OVER (ORDER BY X) W1 FROM (SELECT CAST('9E6144' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('8E6144' AS DECFLOAT(34)) FROM RDB\$DATABASE);
SELECT CAST('9E384' AS DECFLOAT(16)) * 10 D16 FROM RDB\$DATABASE;"
both "6 CONTROL under the default traps the same SUM and EXP raise" "SELECT SUM(X) S1 FROM (SELECT CAST('9E6144' AS DECFLOAT(34)) X FROM RDB\$DATABASE UNION ALL SELECT CAST('9E6144' AS DECFLOAT(34)) FROM RDB\$DATABASE); SELECT EXP(CAST(100000 AS DECFLOAT(34))) E1 FROM RDB\$DATABASE;"
CV=""
for m in "" "Overflow" "Invalid_operation"; do
    CV="$CV
SET DECFLOAT TRAPS TO $m;"
    for c in "Inf|DOUBLE PRECISION" "NaN|DOUBLE PRECISION" "-Inf|FLOAT" "NaN|FLOAT" "1E400|DOUBLE PRECISION" "1E40|FLOAT" "1E-400|DOUBLE PRECISION" \
             "Inf|SMALLINT" "-Inf|INT" "NaN|BIGINT" "1E40|INT" "3E9|INT" "1E15|INT" "40000|SMALLINT" "1E30|BIGINT" "-1E40|BIGINT" \
             "1E40|NUMERIC(9,2)" "1E9|NUMERIC(9,2)" "Inf|NUMERIC(18,2)" "1E20|NUMERIC(18,2)" "NaN|NUMERIC(4,1)" "NaN|NUMERIC(18,0)" \
             "NaN|INT128" "Inf|INT128" "1E37|INT128" "1E35|INT128" "1E40|NUMERIC(38,2)"; do
        CV="$CV
SELECT '[$m] ${c%%|*} ${c#*|}' K FROM RDB\$DATABASE;
SELECT CAST(CAST(CAST('${c%%|*}' AS DECFLOAT(34)) AS ${c#*|}) AS VARCHAR(40)) V FROM RDB\$DATABASE;"
    done
done
both "6 a DECFLOAT conversion: Invalid gives 0 at an exact target and NaN at a float, Overflow the float's Infinity; 22003 is no decimal trap" "$CV"
boundary "6 BOUNDARY a NaN into a SCALED BIGINT, untrapped: the engine's garbage" "SET DECFLOAT TRAPS TO;
SELECT CAST(CAST('NaN' AS DECFLOAT(34)) AS NUMERIC(18,2)) G FROM RDB\$DATABASE;" ' G|=====================| 78863920565143470.08|X|======|DONE|'
boundary "6 BOUNDARY a NaN into a SCALED INT128, untrapped: the engine's garbage" "SET DECFLOAT TRAPS TO;
SELECT CAST(CAST('NaN' AS DECFLOAT(34)) AS NUMERIC(38,2)) G FROM RDB\$DATABASE;" ' G|=============================================| 1000000000000000000000000000.00|X|======|DONE|'

echo "--- 4 RECORDED: shapes this server still refuses or answers differently"
rec "4 RECORDED an Inexact trap" "SET DECFLOAT TRAPS TO Inexact, Overflow;
SELECT $TR T FROM RDB\$DATABASE;" 'T|===============================================================================================================================================================================================================================================================|Inexact,Overflow|X|======|DONE|' 'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|T|===============================================================================================================================================================================================================================================================|Division_by_zero,Invalid_operation,Overflow|X|======|DONE|'

rec "4 RECORDED a NEGATED exact literal under a DECFLOAT item converts with its minus (the engine's preferred-desc fold)" "SELECT CAST(-0.0 AS DECFLOAT(16)) F1, CAST(-0 AS DECFLOAT(16)) F2, CAST(-0.00 AS DECFLOAT(34)) F4, CAST(-(0.0) AS DECFLOAT(16)) F6, COALESCE(CAST(-0 AS DECFLOAT(16)), 1) I, CAST(-0 AS DECFLOAT(16)) * 1 H FROM RDB\$DATABASE;" ' F1 F2 F4 F6 I H|======================= ======================= ========================================== ======================= ======================= ==========================================| -0.0 -0 -0.00 -0.0 -0 -0|X|======|DONE|' ' F1 F2 F4 F6 I H|======================= ======================= ========================================== ======================= ======================= ==========================================| 0.0 0 0.00 0.0 0 0|X|======|DONE|'

echo "--- 7 SET DECFLOAT ROUND: every mode, every rounding the context makes"
# each mode's statement TEXT differs (the mode name rides in it): the
# engine's compiled-statement cache reuses a prepare-time fold made under
# ANOTHER mode for the same text - `CAST(<20-digit literal> AS DECFLOAT(16))`
# keeps the first mode's rounding (measured) - which is no law to copy
RM=""
for m in CEILING UP HALF_UP HALF_EVEN HALF_DOWN DOWN FLOOR REROUND; do
    RM="$RM
SET DECFLOAT ROUND $m;
SELECT '$m' M, RDB\$GET_CONTEXT('SYSTEM', 'DECFLOAT_ROUND') R, CAST(2 AS DECFLOAT(34)) / 3 A, CAST(-2 AS DECFLOAT(34)) / 3 B, CAST(1 AS DECFLOAT(16)) / 3 D16, CAST(CAST('1.234567890123456789' AS DECFLOAT(34)) AS DECFLOAT(16)) C, CAST('2.5000000000000005' AS DECFLOAT(16)) E FROM RDB\$DATABASE;
SELECT '$m' M, QUANTIZE(CAST(2.5 AS DECFLOAT(16)), CAST(1 AS DECFLOAT(16))) Q, QUANTIZE(CAST(-2.5 AS DECFLOAT(16)), CAST(1 AS DECFLOAT(16))) QN, ROUND(CAST(2.5 AS DECFLOAT(16)), 0) R0, ROUND(CAST(2.45 AS DECFLOAT(16)), 1) R1 FROM RDB\$DATABASE;
SELECT '$m' M, CAST(CAST(2.5 AS DECFLOAT(16)) AS INT) CI, CAST(CAST(-2.5 AS DECFLOAT(16)) AS NUMERIC(9,0)) CN, CAST(CAST(2.25 AS DECFLOAT(16)) AS NUMERIC(9,1)) CN1, CAST(12345678901234567895 AS DECFLOAT(16)) BI, CAST(-12345678901234567895 AS DECFLOAT(16)) BN FROM RDB\$DATABASE;
SELECT '$m' M, TRUNC(CAST(2.7 AS DECFLOAT(16))) T, CEILING(CAST(2.1 AS DECFLOAT(16))) CE, FLOOR(CAST(-2.1 AS DECFLOAT(16))) FL, X / 3 XD FROM T WHERE ID = 4;"
done
both "7 the eight modes: an operation, a narrowing, a text, QUANTIZE, ROUND, a CAST out, a wide literal; TRUNC / CEILING / FLOOR keep their own" "$RM"
both "7 an unknown mode is the engine's bare 42000; a new attachment starts HALF_UP" "SET DECFLOAT ROUND NOSUCH;
SELECT RDB\$GET_CONTEXT('SYSTEM', 'DECFLOAT_ROUND') R, CAST(2 AS DECFLOAT(34)) / 3 A FROM RDB\$DATABASE;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dft-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 36 ]; then echo "FAIL only $ran checks ran (floor 36) - cells went missing"; fail=1; fi
exit $fail
