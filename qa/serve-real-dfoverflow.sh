#!/bin/bash
# DECFLOAT arithmetic at the edges of decimal128's exponent range: an
# OVERFLOW raises *Decimal float overflow* (22003), an UNDERFLOW clamps -
# as the engine does. fire-crab encoded the out-of-range exponent into the
# decimal128 word and answered GARBAGE.
#
# Measured against the live engine:
#   * a result whose adjusted exponent passes emax 6144 raises
#     `isc_decfloat_overflow` - per row, value-gated (a WHERE over the other
#     rows answers them), through a projection, a WHERE, a CAST, SUM and AVG.
#     `9.99..E+6144 + 9.99..E+6144` answered 8.000000000000000000000000000000000E-2047,
#     `9.99..E+6144 * 10` answered `NaN999...`, `1E+6000 * 1E+200` 8.0E-6055,
#     SUM of two maxima 9.12E-6143, and `WHERE A * 10 > 0` returned EVERY row;
#   * a result whose exponent falls below -6176 is SUBNORMAL: the digits the
#     format cannot carry round away HALF-UP and the exponent clamps to -6176 -
#     `1E-6000 / 1E+200` is 0E-6176, `5E-6176 * 0.1` is 1E-6176,
#     `1E-6176 / 2` is 1E-6176; fire-crab answered 8.0E-2071-style garbage;
#   * a stored exponent above 6111 pads the coefficient, a zero clamps to
#     0E+6111 (SUM of +max and -max);
#   * a DECFLOAT(16) result that overflows decimal64 at materialization
#     raises the SAME *Decimal float overflow* vector (fire-crab raised the
#     generic *numeric value is out of range*).
#
# Usage: qa/serve-real-dfoverflow.sh [port]   (default 4179)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4179}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfov-eng.fdb"; FC="$D/dfov-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfov-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, A DECFLOAT(34), B DECFLOAT(34), F FLOAT, S16 DECFLOAT(16), I INTEGER);
INSERT INTO T VALUES (1, CAST('9.999999999999999999999999999999999E+6144' AS DECFLOAT(34)), CAST('9.999999999999999999999999999999999E+6144' AS DECFLOAT(34)), 3.4e38, CAST('9.999999999999999E+384' AS DECFLOAT(16)), 10);
INSERT INTO T VALUES (2, CAST('1E+6000' AS DECFLOAT(34)), CAST('1E+200' AS DECFLOAT(34)), 1e30, CAST('1E+300' AS DECFLOAT(16)), 2);
INSERT INTO T VALUES (3, CAST('1E-6176' AS DECFLOAT(34)), CAST('1E-100' AS DECFLOAT(34)), 1e-30, CAST('1E-398' AS DECFLOAT(16)), 2);
INSERT INTO T VALUES (4, CAST('1E-6000' AS DECFLOAT(34)), CAST('1E+200' AS DECFLOAT(34)), 2, CAST('1E-300' AS DECFLOAT(16)), 2);
INSERT INTO T VALUES (5, CAST('5E-6176' AS DECFLOAT(34)), CAST('0.1' AS DECFLOAT(34)), 0.5, CAST('5E-398' AS DECFLOAT(16)), 3);
INSERT INTO T VALUES (6, CAST('Infinity' AS DECFLOAT(34)), CAST('-Infinity' AS DECFLOAT(34)), 1, CAST('Infinity' AS DECFLOAT(16)), 1);
INSERT INTO T VALUES (7, CAST('1.234567890123456789012345678901234E+6144' AS DECFLOAT(34)), 10, 10, 1, 1);
INSERT INTO T VALUES (8, CAST('-9.999999999999999999999999999999999E+6144' AS DECFLOAT(34)), CAST('9.999999999999999999999999999999999E+6144' AS DECFLOAT(34)), -3.4e38, 1, 1);
INSERT INTO T VALUES (9, CAST('1E+6144' AS DECFLOAT(34)), CAST('1E+6110' AS DECFLOAT(34)), 1, 1, 1);
INSERT INTO T VALUES (10, CAST('1.5E-6176' AS DECFLOAT(34)), CAST('-5E-6176' AS DECFLOAT(34)), 1, 1, 1);
COMMIT;
SQL
if grep -qi error /tmp/dfov-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfov-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfov.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
q() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -a -v '^$' | sed 's/[[:space:]][[:space:]]*/ /g' | tr '\n' '|'; }
agree() { # <label> <sql> - rows AND error text compared whole
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
}
one() { agree "$1" "SELECT $2 FROM T WHERE ID = $3;"; }

echo "-- OVERFLOW: *Decimal float overflow* (22003), not garbage --"
one "max + max"            "A + B"      1
one "-max - max"           "A - B"      8
one "1E+6000 * 1E+200"     "A * B"      2
one "max * 10"             "A * 10"     1
one "1.23E+6144 * 10"      "A * 10"     7
one "max * FLOAT 3.4e38"   "A * F"      1
one "1E+6144 / 1E-10"      "A / CAST('1E-10' AS DECFLOAT(34))" 9
one "max * max"            "A * A"      2
one "max + INTEGER"        "A + I * A"  1
agree "CAST(overflow AS VARCHAR)" "SELECT CAST(A * 10 AS VARCHAR(60)) FROM T WHERE ID = 1;"
agree "WHERE A * 10 > 0 raises at the overflowing row" "SELECT ID FROM T WHERE A * 10 > 0 ORDER BY ID;"
agree "a dead row does not raise"  "SELECT ID FROM T WHERE ID = 2 AND A * 10 > 0;"
agree "SUM of two large values"    "SELECT SUM(A) FROM T WHERE ID IN (1, 7);"
agree "AVG of two large values"    "SELECT AVG(A) FROM T WHERE ID IN (1, 7);"
agree "SUM(A * 10) over max"       "SELECT SUM(A * 10) FROM T WHERE ID IN (1, 2);"
echo "-- no overflow at the edge: the result rounds / pads --"
one "max + 1 rounds back"     "A + 1"   1
one "1E+6144 * 1 pads"        "A * 1"   9
one "1E+6144 + 1E+6110"       "A + B"   9
one "1E+6144 - 1E+6110"       "A - B"   9
one "1E+6144 / 10"            "A / 10"  9
agree "SUM(+max, -max) is 0E+6111" "SELECT SUM(A) FROM T WHERE ID IN (1, 8);"
one "-max"                    "-A"      8
echo "-- UNDERFLOW: subnormal HALF-UP to exponent -6176 --"
one "1E-6000 / 1E+200"     "A / B"   4
one "1E-6176 * 1E-100"     "A * B"   3
one "5E-6176 * 0.1"        "A * B"   5
one "1E-6176 / 2"          "A / 2"   3
one "1E-6176 / 3"          "A / 3"   3
one "1E-6176 * 0.4"        "A * 0.4" 3
one "1E-6176 * 0.6"        "A * 0.6" 3
one "1.5E-6176 + 0"        "A + 0"   10
one "1.5E-6176 * 1"        "A * 1"   10
one "-5E-6176 * 0.1"       "B * 0.1" 10
one "1E-6000 * 1E-6000"    "A * A"   4
one "1E-30 FLOAT * 1E-6176" "A * F"  3
one "1E-6176 / 1E-100"     "A / B"   3
one "1E-6176 + 1E-6176"    "A + A"   3
echo "-- specials unchanged --"
one "Inf + -Inf traps"     "A + B"   6
one "Inf * 0 traps"        "A * 0"   6
agree "SUM(Inf)"           "SELECT SUM(A) FROM T WHERE ID = 6;"
agree "SUM(-Inf, max)"     "SELECT SUM(B) FROM T WHERE ID IN (6, 8);"
one "1 / 0 traps"          "I / CAST(0 AS DECFLOAT(34))" 2
echo "-- DECFLOAT(16): overflow at materialization is the SAME vector --"
one "S16 + S16 (max)"      "S16 + S16"   1
one "S16 * S16 (1E+600)"   "S16 * S16"   2
one "S16 * S16 underflow"  "S16 * S16"   3
one "S16 * S16 tiny"       "S16 * S16"   4
agree "CAST(S16 * S16 AS VARCHAR) keeps the wide value" "SELECT CAST(S16 * S16 AS VARCHAR(60)) FROM T WHERE ID = 2;"
agree "CAST('1E+385' AS DECFLOAT(16))" "SELECT CAST('1E+385' AS DECFLOAT(16)) FROM RDB\$DATABASE;"
echo "-- ordinary arithmetic unchanged --"
agree "ordinary values"    "SELECT CAST(1 AS DECFLOAT(34)) / 3, CAST(2.5 AS DECFLOAT(34)) * 4, CAST(0.1 AS DECFLOAT(16)) + CAST(0.2 AS DECFLOAT(16)) FROM RDB\$DATABASE;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dfoverflow" || echo "FAIL dfoverflow"
exit $fail
