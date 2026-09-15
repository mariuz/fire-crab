#!/bin/bash
# The DECFLOAT leftovers, all measured against the live engine:
#
# 1. An EXPONENT literal outside DOUBLE's range is typed DECFLOAT(34). fire-
#    crab typed every exponent literal with an i64-sized significand DOUBLE,
#    so `1e400` was DOUBLE Infinity, `1e-330` DOUBLE 0, and `WHERE A < 1e400`
#    compared against infinity and answered rows where the engine traps. The
#    engine's rule: DOUBLE while the decimal value, AS WRITTEN, is at most
#    1.7976931348623157e308 (`1.7976931348623157081e308` is already DECFLOAT,
#    `17976931348623157e292` is DOUBLE) and the leading digit's decimal
#    exponent is -308 or more (`1.5e-308`, `0.01e-306` DOUBLE; `9.99e-309`,
#    `12.5e-310` DECFLOAT); a ZERO by its written exponent (`0e308`,
#    `0e-308` DOUBLE; `0e309`, `0e-309` DECFLOAT).
# 2. A TEXT whose exponent leaves decimal128's range CLAMPS in a CAST and in
#    a store, as decNumber does: '1E-6177' is 0E-6176, '6E-6177' 1E-6176,
#    '-1E-7000' -0E-6176, '1E+6112' 1.0E+6112; past emax it raises *Decimal
#    float overflow*. fire-crab refused them all as conversion errors.
# 3. SUM / AVG over a +Infinity and a -Infinity row raise *Decimal float
#    invalid operation* (grouped and windowed too); fire-crab answered NaN.
#
# BOUNDARY (recorded, not gated): the engine's own decimal-to-DOUBLE literal
# conversion is imprecise near DOUBLE's lower limit - `1e-307` renders
# 1.000000000000000e-307 (the correctly rounded double renders ...999e-308),
# `1.5e-308` and `1.0e-308` render 0 while `1e-308` does not. Those literals
# are DOUBLE on both servers and were before this change; only their TYPE is
# gated here, through values that convert the same way.
#
# Usage: qa/serve-real-dfliteral.sh [port]   (default 4180)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4180}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dflit-eng.fdb"; FC="$D/dflit-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dflit-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, A DECFLOAT(34), S DECFLOAT(16), G INTEGER);
INSERT INTO T VALUES (1, CAST('Infinity' AS DECFLOAT(34)), CAST('Infinity' AS DECFLOAT(16)), 1);
INSERT INTO T VALUES (2, CAST('-Infinity' AS DECFLOAT(34)), CAST('-Infinity' AS DECFLOAT(16)), 1);
INSERT INTO T VALUES (3, 5, 5, 2);
INSERT INTO T VALUES (4, CAST('NaN' AS DECFLOAT(34)), CAST('NaN' AS DECFLOAT(16)), 3);
INSERT INTO T VALUES (5, CAST('Infinity' AS DECFLOAT(34)), CAST('Infinity' AS DECFLOAT(16)), 4);
INSERT INTO T VALUES (6, 1, 1, 4);
CREATE TABLE F (ID INTEGER, A DECFLOAT(34), DP DOUBLE PRECISION);
INSERT INTO F VALUES (1, 1E+300, 1e300);
INSERT INTO F VALUES (2, 5, 5);
INSERT INTO F VALUES (3, CAST('1E+400' AS DECFLOAT(34)), NULL);
INSERT INTO F VALUES (4, CAST('1E-400' AS DECFLOAT(34)), NULL);
CREATE TABLE W (ID INTEGER, A DECFLOAT(34), S DECFLOAT(16));
COMMIT;
SQL
if grep -qi error /tmp/dflit-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dflit-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dflit.log 2>&1 &
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
agree() { # <label> <sql> - describe, rows and error text compared whole
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
}

echo "-- 1. an exponent literal outside DOUBLE's range types DECFLOAT(34) (describe + value) --"
for lit in 1e308 1.7976931348623157e308 1.79769313486231570e308 17976931348623157e292 1.7976931348623158e308 1.7976931348623157081e308 1.8e308 2e308 9e308 1e309 1E309 10e308 0.1e310 1e400 -1e400 -1.8e308 \
           2.3e-308 1e-306 9.99e-309 1e-309 1.5e-309 12.5e-310 123e-311 1e-310 1e-320 5e-324 2e-324 -2e-324 1e-330 1e-400 100e-326 \
           0e308 0e309 0e-308 0e-309 0e-310 0e400 0e-400 -0e400 0.0e999 0.0e0 0e5; do
    agree "SELECT $lit" "SELECT $lit FROM RDB\$DATABASE;"
done
agree "1e400 in arithmetic"          "SELECT 1e400 + 1, 1e-400 * 2 FROM RDB\$DATABASE;"
agree "1e309 beside a DOUBLE column" "SELECT DP * 1e309 FROM F WHERE ID = 2;"
agree "WHERE A < 1e400 (decimal compare; the NaN row traps)" "SELECT ID FROM T WHERE A < 1e400 ORDER BY ID;"
agree "WHERE A < 1e400 over finite rows" "SELECT ID FROM F WHERE A < 1e400 ORDER BY ID;"
agree "WHERE A = 1e400"              "SELECT ID FROM F WHERE A = 1e400 ORDER BY ID;"
agree "WHERE A > 1e-400"             "SELECT ID FROM F WHERE A > 1e-400 ORDER BY ID;"
agree "WHERE DP < 1e309"             "SELECT ID FROM F WHERE DP < 1e309 ORDER BY ID;"
agree "WHERE A = 1e308 (a DOUBLE literal)" "SELECT ID FROM F WHERE A = 1e308 ORDER BY ID;"
agree "CAST(1e400 AS VARCHAR(20))"   "SELECT CAST(1e400 AS VARCHAR(20)) FROM RDB\$DATABASE;"
agree "COALESCE(NULL, 1e400)"        "SELECT COALESCE(NULL, 1e400) FROM RDB\$DATABASE;"
echo "-- 2. a text past decimal128's exponent range clamps in CAST and store; past emax it raises --"
for t in 1E-6177 6E-6177 5E-6177 4E-6177 -1E-7000 0E-6200 1E+6112 1E+6144 9.9E+6144 1E+6145 1.5E-6177 123E+6120; do
    agree "CAST('$t' AS DECFLOAT(34))" "SELECT CAST('$t' AS DECFLOAT(34)) FROM RDB\$DATABASE;"
done
agree "CAST('1E+6112' AS DECFLOAT(16))" "SELECT CAST('1E+6112' AS DECFLOAT(16)) FROM RDB\$DATABASE;"
agree "CAST('1E-6177' AS DECFLOAT(16))" "SELECT CAST('1E-6177' AS DECFLOAT(16)) FROM RDB\$DATABASE;"
agree "INSERT '1E-6177' / '1E+6112' / '-1E-7000' then read" "INSERT INTO W (ID, A) VALUES (1, '1E-6177'); INSERT INTO W (ID, A) VALUES (2, '1E+6112'); INSERT INTO W (ID, A) VALUES (3, '-1E-7000'); SELECT ID, A FROM W ORDER BY ID;"
raises() { # <label> <sql> - the engine raises; fire-crab must raise too (vector recorded)
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    case "$e" in *"Statement failed"*) ;; *) echo "FAIL $1 (the engine no longer raises: $e)"; fail=1; return ;; esac
    case "$f" in *"Statement failed"*) echo "OK   $1 (raises)" ;; *) echo "DIFF $1 - engine raises, fc: $f"; fail=1 ;; esac
}
raises "INSERT '1E+6145' raises (fc refuses: the store path's vector is generic)" "INSERT INTO W (ID, A) VALUES (9, '1E+6145');"
agree "WHERE A = '1E-6177' (literal compare clamps)" "SELECT ID FROM F WHERE A = '1E-6177' ORDER BY ID;"
agree "WHERE A > '1E-6177'"          "SELECT ID FROM F WHERE A > '1E-6177' ORDER BY ID;"
echo "-- 3. SUM / AVG over +Infinity and -Infinity raise invalid operation --"
agree "SUM(+Inf, -Inf)"              "SELECT SUM(A) FROM T WHERE ID IN (1, 2);"
agree "AVG(+Inf, -Inf)"              "SELECT AVG(A) FROM T WHERE ID IN (1, 2);"
agree "SUM over DECFLOAT(16) infinities" "SELECT SUM(S) FROM T WHERE ID IN (1, 2);"
agree "GROUP BY SUM"                 "SELECT G, SUM(A) FROM T GROUP BY G ORDER BY G;"
agree "SUM OVER ()"                  "SELECT SUM(A) OVER () FROM T WHERE ID IN (1, 2);"
agree "SUM(+Inf, 1) is Infinity"     "SELECT SUM(A) FROM T WHERE ID IN (5, 6);"
agree "SUM(NaN, 5) is NaN"           "SELECT SUM(A) FROM T WHERE ID IN (3, 4);"
agree "SUM(+Inf, +Inf)"              "SELECT SUM(A) FROM T WHERE ID IN (1, 5);"
agree "MIN/MAX over infinities"      "SELECT MIN(A), MAX(A) FROM T WHERE ID IN (1, 2, 3);"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dfliteral" || echo "FAIL dfliteral"
exit $fail
