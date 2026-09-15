#!/bin/bash
# Four small wrong answers on numeric builtins and conversions, each measured
# against the live engine.
#
# 1. ABS keeps the operand's NUMERIC / DECIMAL family code when its result
#    type is the operand's own (INT64 -> INT64, INT128 -> INT128): ABS over a
#    NUMERIC(18,4) describes sub_type 1, over DECIMAL(18,4) sub_type 2. A
#    WIDENED result (a NUMERIC(9,2) LONG backing -> INT64) is sub_type 0.
#    fire-crab described 0 for all of them.
# 2. ABS of the BIGINT minimum raises *numeric value is out of range* (under
#    the arithmetic exception) - in a projection AND in a WHERE. fire-crab
#    raised *Integer overflow* in the projection and, in a WHERE, dropped the
#    raise and answered rows (`WHERE ABS(BI) > 0` returned all three).
# 3. The CVT rounding adds its constant (0.5 + epsilon) in ONE step: an
#    integer-valued double in [2^52, 2^53) casts one HIGHER than the value -
#    `CAST(8000000000000000e0 AS BIGINT)` is 8000000000000001, a DOUBLE 8.99
#    cast to NUMERIC(18,15) is 8.990000000000001, 5e11 to NUMERIC(18,4) is
#    500000000000.0001. fire-crab added 0.5 and then the epsilon, where the
#    tie rounded to even and the epsilon vanished.
# 4. NULLIF(<DECFLOAT>, <text>) converts the text and raises *conversion
#    error* when it is not a number; fire-crab answered the first operand.
#    A DECFLOAT(16) column against the literal 'inf' raises too (the
#    parameter rule, now on the literal path).
#
# Usage: qa/serve-real-absround.sh [port]   (default 4181)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4181}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/absr-eng.fdb"; FC="$D/absr-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/absr-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, N92 NUMERIC(9,2), D92 DECIMAL(9,2), N184 NUMERIC(18,4), D184 DECIMAL(18,4), N382 NUMERIC(38,2), D382 DECIMAL(38,2), BI BIGINT, I128 INT128, I INTEGER, SI SMALLINT, N41 NUMERIC(4,1), DP DOUBLE PRECISION, D16 DECFLOAT(16), D34 DECFLOAT(34), VC VARCHAR(10));
INSERT INTO T VALUES (1, -1.25, -1.25, -12345.6789, -12345.6789, -1.25, -1.25, -9223372036854775807, -5, -2147483647, -32767, -12.5, 8000000000000000, 1.5, 1.5, '1.5');
INSERT INTO T VALUES (2, 2.5, 2.5, 3.5, 3.5, 7.75, 7.75, 5, 5, 5, 5, 2.5, 8.99, 0, 0, 'x');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL, NULL, -9223372036854775808, NULL, -2147483648, -32768, NULL, 4503599627370497, NULL, NULL, NULL);
INSERT INTO T VALUES (4, 0, 0, 0, 0, 0, 0, 7, 7, 7, 7, 0, -8000000000000000, CAST('Infinity' AS DECFLOAT(16)), 2, '2');
CREATE TABLE S (ID INTEGER, BI BIGINT, N184 NUMERIC(18,4), D184 DECIMAL(18,4), DP DOUBLE PRECISION);
INSERT INTO S VALUES (1, 5, -3.5, -3.5, 4503599627370496);
INSERT INTO S VALUES (2, -9223372036854775807, 2.5, 2.5, 9007199254740990);
COMMIT;
SQL
if grep -qi error /tmp/absr-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/absr-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-absr.log 2>&1 &
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
# the engine raises; fire-crab must not answer (a refusal is law-safe, the vector is recorded)
raises() {
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    case "$e" in *"Statement failed"*) ;; *) echo "FAIL $1 (the engine no longer raises: $e)"; fail=1; return ;; esac
    case "$f" in *"Statement failed"*) echo "OK   $1 (raises)" ;; *) echo "DIFF $1 - engine raises, fc: $f"; fail=1 ;; esac
}

echo "-- 1. ABS keeps the NUMERIC / DECIMAL family code at an unwidened type --"
agree "ABS(NUMERIC(9,2)), ABS(DECIMAL(9,2)) widen -> sub_type 0" "SELECT ABS(N92), ABS(D92) FROM T WHERE ID = 1;"
agree "ABS(NUMERIC(18,4)) sub 1, ABS(DECIMAL(18,4)) sub 2"        "SELECT ABS(N184), ABS(D184) FROM T WHERE ID = 1;"
agree "ABS(NUMERIC(38,2)) sub 1, ABS(DECIMAL(38,2)) sub 2"        "SELECT ABS(N382), ABS(D382) FROM T WHERE ID = 1;"
agree "ABS(BIGINT), ABS(INT128), ABS(INTEGER), ABS(SMALLINT), ABS(NUMERIC(4,1))" "SELECT ABS(BI), ABS(I128), ABS(I), ABS(SI), ABS(N41) FROM T WHERE ID = 1;"
agree "ABS over a NUMERIC(18,4) column through a derived table"   "SELECT ABS(X) FROM (SELECT N184 X FROM T WHERE ID = 1) Q;"
agree "ABS values over every row"                                "SELECT ID, ABS(N184), ABS(D382), ABS(SI) FROM T ORDER BY ID;"
agree "ABS(N184) arithmetic keeps its describe"                   "SELECT ABS(N184) + 1, -ABS(D184) FROM T WHERE ID = 2;"
echo "-- 2. ABS of the BIGINT minimum raises numeric out of range - projection and WHERE --"
agree "ABS(BIGINT min) projection vector"      "SELECT ABS(BI) FROM T WHERE ID = 3;"
raises "WHERE ABS(BI) > 0 does not skip the min row" "SELECT ID FROM T WHERE ABS(BI) > 0 ORDER BY ID;"
raises "WHERE ID = 3 AND ABS(BI) = 1"          "SELECT ID FROM T WHERE ID = 3 AND ABS(BI) = 1;"
agree "WHERE ABS(BI) > 0 over rows without the minimum" "SELECT ID FROM T WHERE ID <> 3 AND ABS(BI) > 6 ORDER BY ID;"
agree "WHERE ABS(I) > 0 (INTEGER min widens, no raise)" "SELECT ID FROM T WHERE ABS(I) > 0 ORDER BY ID;"
agree "WHERE ABS(N184) > 1"                     "SELECT ID FROM T WHERE ABS(N184) > 1 ORDER BY ID;"
agree "ABS(INTEGER min), ABS(SMALLINT min)"    "SELECT ABS(I), ABS(SI) FROM T WHERE ID = 3;"
echo "-- 3. the CVT rounding adds (0.5 + epsilon) in one step --"
agree "CAST(8000000000000000e0 AS BIGINT)"       "SELECT CAST(8000000000000000e0 AS BIGINT), CAST(-8000000000000000e0 AS BIGINT) FROM RDB\$DATABASE;"
agree "CAST at the 2^52 / 2^53 edges"            "SELECT CAST(4503599627370496e0 AS BIGINT), CAST(4503599627370498e0 AS BIGINT), CAST(9007199254740990e0 AS BIGINT), CAST(9007199254740992e0 AS BIGINT), CAST(4503599627370495e0 AS BIGINT) FROM RDB\$DATABASE;"
agree "CAST(DP AS BIGINT / NUMERIC(18,0)) column" "SELECT ID, CAST(DP AS BIGINT), CAST(DP AS NUMERIC(18,0)) FROM T ORDER BY ID;"
agree "CAST(8.99 AS NUMERIC(18,15))"              "SELECT CAST(DP AS NUMERIC(18,15)) FROM T WHERE ID = 2;"
agree "CAST(5e11 AS NUMERIC(18,4))"               "SELECT CAST(5e11 AS NUMERIC(18,4)), CAST(-5e11 AS NUMERIC(18,4)) FROM RDB\$DATABASE;"
agree "ordinary rounding unchanged"               "SELECT CAST(2.5e0 AS INTEGER), CAST(-2.5e0 AS INTEGER), CAST(1.005e0 AS NUMERIC(9,2)), CAST(0.49999999999999994e0 AS INTEGER), CAST(1e15 AS BIGINT) FROM RDB\$DATABASE;"
agree "FLOAT source rounding"                     "SELECT CAST(CAST(2.675 AS FLOAT) AS NUMERIC(9,2)), CAST(CAST(16777216 AS FLOAT) AS INTEGER) FROM RDB\$DATABASE;"
agree "store: INSERT .. SELECT DP into BIGINT / NUMERIC(18,0)" "INSERT INTO S (ID, BI, N184) SELECT 10 + ID, DP, DP / 1000 FROM T WHERE ID IN (1, 3, 4); SELECT ID, BI, N184 FROM S WHERE ID > 9 ORDER BY ID;"
agree "ROUND(DP) unchanged"                        "SELECT ROUND(DP), ROUND(DP, 0) FROM T WHERE ID = 1;"
echo "-- 4. NULLIF(<DECFLOAT>, <text>) converts the text --"
agree "NULLIF(D16, VC) equal -> NULL"          "SELECT NULLIF(D16, VC) FROM T WHERE ID = 1;"
agree "NULLIF(D16, VC) 'x' raises"             "SELECT NULLIF(D16, VC) FROM T WHERE ID = 2;"
agree "NULLIF(D16, '1.5') -> NULL"             "SELECT NULLIF(D16, '1.5') FROM T WHERE ID = 1;"
agree "NULLIF(D16, 'abc') raises"              "SELECT NULLIF(D16, 'abc') FROM T WHERE ID = 1;"
agree "NULLIF(D34, '2') -> NULL"               "SELECT NULLIF(D34, '2') FROM T WHERE ID = 4;"
agree "NULLIF(D34, '3') -> the value"          "SELECT NULLIF(D34, '3') FROM T WHERE ID = 4;"
agree "NULLIF(D34, VC) over a NULL text"       "SELECT NULLIF(D34, VC) FROM T WHERE ID = 3;"
agree "NULLIF(D16, 1.5) numeric unchanged"     "SELECT NULLIF(D16, 1.5), NULLIF(D16, 2) FROM T WHERE ID = 1;"
agree "D16 = 'inf' literal raises"             "SELECT ID FROM T WHERE D16 = 'inf';"
agree "D16 = ' 1.5 ' literal trims"            "SELECT ID FROM T WHERE D16 = ' 1.5 ' ORDER BY ID;"
agree "D16 = '1.5000000000000001' narrows"     "SELECT ID FROM T WHERE D16 = '1.5000000000000001' ORDER BY ID;"
agree "D34 = 'inf' is a value"                 "SELECT ID FROM T WHERE D34 = 'inf' ORDER BY ID;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS absround" || echo "FAIL absround"
exit $fail
