#!/bin/bash
# AGGREGATE FOLDS THAT SATURATED OR SWALLOWED A NaN.
#
# Measured on engine 2182 and matched:
#
#   * SUM / AVG over an exact source accumulate in 128 bits and raise
#     22003 "Integer overflow" (with the arithmetic-exception prefix) the
#     moment the running sum leaves INT128 - in SCAN ORDER: max + 1 raises
#     even when a later -5 would bring the total back.  The bound is the
#     full i128, not 10^38 (two NUMERIC(38,0) 6E37s sum to 1.2E38).  This
#     server's fold used saturating_add and answered a clamped 2^127-1 (or
#     2^127-1 minus the later rows) - grouped, windowed and plain alike.
#   * a DOUBLE / FLOAT SUM or AVG whose running sum reaches an infinity
#     raises 22003 "Floating-point overflow" - 1E308 + 1E308, and an
#     Infinity INPUT alone (a VAR_POP that overflowed) too.  A NaN input
#     passes through as NaN.  This answered Infinity.
#   * STDDEV_POP / STDDEV_SAMP of a NaN variance (Sxx - Sx*Sx/n as
#     Inf - Inf) is NaN: f64::max(NaN, 0.0) is 0.0, so this answered 0.
#
# Second pass (the review's findings), measured and matched:
#
#   * a SORTED GROUP BY group, and a window with a PARTITION BY or an
#     ORDER BY, folds in the engine's SORT-RECORD order, not scan order:
#     the group / partition / order keys, then the NULL flags of every
#     field the statement references, then those fields' values as native
#     little-endian 32-bit words, low word first (a double's IEEE bits, an
#     INT128's four words).  So grouped SUM(D) over 1E155, -1E155, 1 is 0
#     (1.0's low word is 0: it folds first), INT128 max, 1, -5 grouped do
#     not overflow, max, -max, max, -max grouped do; a referenced ID or K
#     (select list, WHERE, another window's PARTITION BY) reorders it.
#     OVER () does not sort: scan order.  This folded in scan order.
#   * VAR / STDDEV over an INT128-backed or DECFLOAT source fold in
#     decimal128 (fma for the squares) and answer DECFLOAT(34), NOT
#     nullable - an empty or single-row SAMP group is the NULL that shows
#     as 0E-6176.  The engine's STDDEV_POP there answers the VARIANCE
#     (its execute takes the root for STDDEV_SAMP only).  This answered a
#     DOUBLE (INT128, NUMERIC(38,s)) or refused (DECFLOAT).
#   * MIN / MAX meeting a NaN: the engine's double compare says LESS for
#     any NaN pair, so MIN takes the later value and MAX keeps its own
#     (NaN then 1: MIN 1, MAX NaN; 1 then NaN: MIN NaN, MAX 1).
#   * CAST(<an infinite double> AS FLOAT) is Infinity (this raised 22003
#     numeric value is out of range, and so did a SUM over it).
#   * SUM / AVG / COUNT / MIN / MAX (ALL x) are the plain fold (refused).
#   * INSERT ... SELECT of a NaN / infinite aggregate stores it (refused).
#
# RECORDED, not fixed (cells pin the divergence):
#   * a GROUP BY whose LATER group overflows: the engine sends the
#     groups folded before it, then the error; this server folds every
#     group before it answers, so it sends the error alone.
#   * SUM(DISTINCT <col>) and a windowed STDDEV_POP are refused here
#     (a bare Dynamic SQL Error); the engine answers them.
#   * CORR / COVAR / REGR_* whose FIRST argument is INT128-backed fold in
#     decimal128 on the engine (DECFLOAT(34)); refused here rather than
#     answered as a DOUBLE.
#   * INSERT ... VALUES (.., (SELECT <a NaN aggregate>)): the VALUES fold
#     splices each subquery's answer back as a literal at prepare, and a
#     NaN / an infinity has none - refused; the engine stores NaN.
#   * EXECUTE BLOCK RETURNS (R INT128 | NUMERIC(38,s) | DOUBLE PRECISION)
#     and CREATE VIEW over a GROUP BY are refused here (a PSQL / DDL
#     surface, not the fold) - so the PSQL and view spellings of these
#     raises are unchecked.
#
# Usage: qa/serve-real-aggfold.sh [port]   (default 5300)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5300}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/aggfold-eng.fdb"; FC="$D/aggfold-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, G INTEGER, H INT128, N NUMERIC(38,0), N2 NUMERIC(38,2), B BIGINT, D DOUBLE PRECISION, F FLOAT);
INSERT INTO T VALUES (1, 1, 170141183460469231731687303715884105727, 60000000000000000000000000000000000000, 1.25, 9223372036854775807, 1e155, 3e38);
INSERT INTO T VALUES (2, 1, 1, 60000000000000000000000000000000000000, 2.50, 9223372036854775807, -1e155, 3e38);
INSERT INTO T VALUES (3, 1, -5, 1, 3.75, 9223372036854775807, 1, 1);
INSERT INTO T VALUES (4, 2, -5, -60000000000000000000000000000000000000, 4, 1, 1e308, NULL);
INSERT INTO T VALUES (5, 2, 170141183460469231731687303715884105727, -60000000000000000000000000000000000000, 5, 1, -1e308, NULL);
INSERT INTO T VALUES (6, 2, 1, -60000000000000000000000000000000000000, 6, 1, 1e308, NULL);
CREATE TABLE DX (X DOUBLE PRECISION);
INSERT INTO DX VALUES (1e300); INSERT INTO DX VALUES (1); INSERT INTO DX VALUES (1e200);
CREATE TABLE V (X DOUBLE PRECISION);
INSERT INTO V VALUES (1e155); INSERT INTO V VALUES (-1e155);
CREATE TABLE P (ID INTEGER, G INTEGER, H INT128, D DOUBLE PRECISION, N NUMERIC(38,0));
INSERT INTO P VALUES (1, 1, -170141183460469231731687303715884105727, -1e308, -100000000000000000000000000000000000000);
INSERT INTO P VALUES (2, 1, 170141183460469231731687303715884105727, 1e308, 100000000000000000000000000000000000000);
INSERT INTO P VALUES (3, 1, -170141183460469231731687303715884105727, -1e308, -100000000000000000000000000000000000000);
INSERT INTO P VALUES (4, 1, 170141183460469231731687303715884105727, 1e308, 100000000000000000000000000000000000000);
INSERT INTO P VALUES (5, 2, 170141183460469231731687303715884105727, 1e308, 100000000000000000000000000000000000000);
INSERT INTO P VALUES (6, 2, -170141183460469231731687303715884105727, -1e308, -100000000000000000000000000000000000000);
INSERT INTO P VALUES (7, 2, 170141183460469231731687303715884105727, 1e308, 100000000000000000000000000000000000000);
INSERT INTO P VALUES (8, 2, -170141183460469231731687303715884105727, -1e308, -100000000000000000000000000000000000000);
CREATE TABLE W (ID INTEGER, G INTEGER, K INTEGER, X DOUBLE PRECISION, H INT128);
INSERT INTO W VALUES (1, 1, 0, -1e16, 170141183460469231731687303715884105727);
INSERT INTO W VALUES (2, 1, 5, 1, 1);
INSERT INTO W VALUES (3, 1, 9, 1, -5);
INSERT INTO W VALUES (4, 2, 9, 1, 1);
INSERT INTO W VALUES (5, 2, 5, 1, -5);
INSERT INTO W VALUES (6, 2, 0, -1e16, 170141183460469231731687303715884105727);
INSERT INTO W VALUES (7, 3, 1, 1, -5);
INSERT INTO W VALUES (8, 3, 2, -1e16, 170141183460469231731687303715884105727);
INSERT INTO W VALUES (9, 3, 3, 1, 1);
CREATE TABLE S (ID INTEGER, G INTEGER, H INT128, N NUMERIC(38,2), D16 DECFLOAT(16), D34 DECFLOAT(34), B BIGINT);
INSERT INTO S VALUES (1, 1, 1, 1.25, 1, 1, 1);
INSERT INTO S VALUES (2, 1, 2, 2.50, 2, 2, 2);
INSERT INTO S VALUES (3, 1, 4, 3.75, 4, 4, 4);
INSERT INTO S VALUES (4, 2, 10, 0.01, 0.1, 0.1, 10);
INSERT INTO S VALUES (5, 2, NULL, NULL, NULL, NULL, NULL);
INSERT INTO S VALUES (6, 3, 7, 7, 7, 7, 7);
INSERT INTO S VALUES (7, 3, 8, 8, 8, 8, 8);
CREATE TABLE R1 (ID INTEGER, D DOUBLE PRECISION, F FLOAT);
CREATE TABLE R2 (ID INTEGER, D DOUBLE PRECISION);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/aggfold-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/aggfold-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/aggfold-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-aggfold-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# both raise, with DIFFERENT errors - recorded (the class is right)
err_differs() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" = "$ev" ] || [ "${fv#*SQLSTATE}" = "$fv" ]; then
        echo "FAIL $1 - both must raise (eng=[$ev] fc=[$fv])"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THE ERRORS NOW AGREE; promote the cell"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:90}], this server [${fv:0:90}])"; fi
}
# a divergence we RECORD: the engine's answer is pinned, this server's
# must still differ (when it agrees, promote the cell)
recorded() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - NOW AGREES; promote the cell"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:90}], this server [${fv:0:90}])"; fi
}
DUAL='FROM RDB$DATABASE'
IOV='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.'
FOV='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.'
MAX=170141183460469231731687303715884105727
TWO="(SELECT CAST($MAX AS INT128) X $DUAL UNION ALL SELECT CAST(1 AS INT128) $DUAL)"

echo "--- 1. AN EXACT SUM / AVG PAST INT128 RAISES (it saturated)"
pin  "1 SUM(INT128) max + 1" "SELECT SUM(X) FROM $TWO;" "SUM|$IOV"
pin  "1 AVG(INT128) max + 1" "SELECT AVG(X) FROM $TWO;" "AVG|$IOV"
pin  "1 SUM(NUMERIC(38,0)) 1E38 + 1E38" "SELECT SUM(X) FROM (SELECT CAST(1e38 AS NUMERIC(38,0)) X $DUAL UNION ALL SELECT CAST(1e38 AS NUMERIC(38,0)) $DUAL);" "SUM|$IOV"
pin  "1 in scan order: max + 1 - 5 raises though the total fits" "SELECT SUM(H) FROM T WHERE G = 1;" "SUM|$IOV"
pin  "1 downward: -6E37 x 3" "SELECT SUM(N) FROM T WHERE G = 2;" "SUM|$IOV"
pin  "1 SUM(-H) past the minimum" "SELECT SUM(-H) FROM T WHERE ID IN (1, 5);" "SUM|$IOV"
pin  "1 SUM(-H - 1)" "SELECT SUM(-H - 1) FROM T WHERE ID IN (1, 5);" "SUM|$IOV"
pin  "1 AVG over a column" "SELECT AVG(H) FROM T WHERE ID IN (1, 5);" "AVG|$IOV"
pin  "1 SUM(BIGINT) widened to INT128 then past it" "SELECT SUM(CAST(B AS INT128) * 18446744073709551616) FROM T;" "SUM|$IOV"
pin  "1 a window running SUM" "SELECT ID, SUM(H) OVER (ORDER BY ID) FROM T WHERE G = 1 ORDER BY ID;" "ID SUM|$IOV"
pin  "1 a grouped SUM that overflows in every order" "SELECT G, SUM(N) FROM T WHERE G = 2 GROUP BY G;" "G SUM|$IOV"
pin  "1 CONTROL the bound is i128, not 10^38" "SELECT SUM(N) FROM T WHERE G = 1;" "SUM|120000000000000000000000000000000000001"
pin  "1 CONTROL -5 + max + 1 fits in scan order" "SELECT SUM(H), AVG(H) FROM T WHERE G = 2;" "SUM AVG|170141183460469231731687303715884105723 56713727820156410577229101238628035241"
pin  "1 CONTROL a window whose prefixes fit" "SELECT ID, SUM(H) OVER (ORDER BY ID) FROM T WHERE G = 2 ORDER BY ID;" "ID SUM|4 -5|5 170141183460469231731687303715884105722|6 170141183460469231731687303715884105723"
pin  "1 CONTROL SUM(BIGINT) widens" "SELECT SUM(B), AVG(B) FROM T;" "SUM AVG|27670116110564327424 4611686018427387904"
pin  "1 CONTROL a scaled NUMERIC(38,2)" "SELECT SUM(N2), AVG(N2) FROM T;" "SUM AVG|22.50 3.75"
dsame "1 CONTROL describe" "SELECT SUM(H), AVG(H), SUM(N2), SUM(B), SUM(D) FROM T WHERE ID = 3;"

echo "--- 2. A DOUBLE SUM / AVG REACHING INFINITY RAISES (it answered Infinity)"
pin  "2 SUM 1E308 + 1E308" "SELECT SUM(X) FROM (SELECT 1e308 X $DUAL UNION ALL SELECT 1e308 $DUAL);" "SUM|$FOV"
pin  "2 AVG 1E308 + 1E308" "SELECT AVG(X) FROM (SELECT 1e308 X $DUAL UNION ALL SELECT 1e308 $DUAL);" "AVG|$FOV"
pin  "2 a window SUM OVER ()" "SELECT SUM(X) OVER () FROM (SELECT 1e308 X $DUAL UNION ALL SELECT 1e308 $DUAL);" "SUM|$FOV"
pin  "2 a window AVG OVER (PARTITION)" "SELECT AVG(X) OVER (PARTITION BY 1) FROM (SELECT 1e308 X $DUAL UNION ALL SELECT 1e308 $DUAL);" "AVG|$FOV"
pin  "2 an Infinity INPUT alone raises" "SELECT SUM(W) FROM (SELECT VAR_POP(X) W FROM V);" "SUM|$FOV"
pin  "2 ...AVG too" "SELECT AVG(W) FROM (SELECT VAR_POP(X) W FROM V);" "AVG|$FOV"
pin  "2 CONTROL a NaN input passes through" "SELECT SUM(W), AVG(W) FROM (SELECT VAR_POP(X) W FROM DX);" "SUM AVG|NaN NaN"
pin  "2 CONTROL 1E308 - 1E308 + 1E308 fits in scan order" "SELECT SUM(D) FROM T WHERE G = 2;" "SUM|1.000000000000000e+308"
pin  "2 CONTROL a running window that fits" "SELECT ID, SUM(D) OVER (ORDER BY ID) FROM T WHERE G = 2 ORDER BY ID;" "ID SUM|4 1.000000000000000e+308|5 0.000000000000000|6 1.000000000000000e+308"
pin  "2 CONTROL FLOAT sums in double" "SELECT SUM(F), AVG(F) FROM T WHERE G = 1;" "SUM AVG|6.000000010995512e+38 2.000000003665171e+38"
pin  "2 CONTROL 3E300 is finite" "SELECT SUM(X) FROM (SELECT 1e300 X $DUAL UNION ALL SELECT 1e300 $DUAL UNION ALL SELECT 1e300 $DUAL);" "SUM|3.000000000000000e+300"

echo "--- 3. STDDEV OF A NaN VARIANCE IS NaN (it answered 0)"
pin  "3 STDDEV_POP / STDDEV_SAMP" "SELECT STDDEV_POP(X), VAR_POP(X), STDDEV_SAMP(X), VAR_SAMP(X) FROM DX;" "STDDEV_POP VAR_POP STDDEV_SAMP VAR_SAMP|NaN NaN NaN NaN"
pin  "3 grouped (a lone 1E300 is Inf - Inf)" "SELECT X, STDDEV_POP(X) FROM DX GROUP BY X ORDER BY X;" "X STDDEV_POP|1.000000000000000 0.000000000000000|1.000000000000000e+200 NaN|1.000000000000000e+300 NaN"
pin  "3 over an Infinity input" "SELECT VAR_POP(W), STDDEV_POP(W), STDDEV_SAMP(W) FROM (SELECT VAR_POP(X) W FROM V UNION ALL SELECT 1e0 $DUAL);" "VAR_POP STDDEV_POP STDDEV_SAMP|NaN NaN NaN"
pin  "3 CONTROL an infinite variance's STDDEV is Infinity" "SELECT VAR_POP(X), VAR_SAMP(X), STDDEV_POP(X), STDDEV_SAMP(X) FROM V;" "VAR_POP VAR_SAMP STDDEV_POP STDDEV_SAMP|Infinity Infinity Infinity Infinity"
pin  "3 CONTROL an ordinary STDDEV" "SELECT STDDEV_POP(ID), STDDEV_SAMP(ID) FROM T WHERE ID < 4;" "STDDEV_POP STDDEV_SAMP|0.8164965809277260 1.000000000000000"
pin  "3 CONTROL CORR / COVAR" "SELECT CORR(X, X), COVAR_POP(X, X) FROM V;" "CORR COVAR_POP|NaN Infinity"

echo "--- 4. A SORTED GROUP BY GROUP FOLDS IN RECORD ORDER (it folded in scan order); recorded refusals"
pin  "4 grouped SUM(DOUBLE): 1, 1E155, -1E155 in record order is 0" "SELECT G, SUM(D) FROM T WHERE G = 1 GROUP BY G;" "G SUM|1 0.000000000000000"
pin  "4 grouped SUM(INT128): 1, -5, max in record order does not overflow" "SELECT SUM(H) FROM T WHERE G = 1 GROUP BY G;" "SUM|170141183460469231731687303715884105723"
# the engine sends the groups folded before the failing one, then the
# error; this server folds every group before it answers any row
recorded "4 the groups before an overflowing one are not sent" "SELECT G, SUM(N) FROM T GROUP BY G;" "G SUM|1 120000000000000000000000000000000000001|$IOV"
pin      "4 SUM(DISTINCT) answers (promoted 2026-09-26; the aggplan chunk)" "SELECT SUM(DISTINCT N) FROM T;" "SUM|1"
pin      "4 a windowed STDDEV_POP answers (promoted 2026-09-26; the aggplan chunk)" "SELECT STDDEV_POP(X) OVER () FROM V;" "STDDEV_POP|Infinity|Infinity"

echo "--- 5. GROUP BY AND PARTITIONED WINDOWS: THE SORT RECORD'S ORDER (it folded in scan order)"
pin  "5 grouped SUM(INT128): -max, max ... overflows in record order" "SELECT G, SUM(H) FROM P GROUP BY G ORDER BY G;" "G SUM|$IOV"
pin  "5 grouped SUM(NUMERIC(38,0))" "SELECT G, SUM(N) FROM P GROUP BY G ORDER BY G;" "G SUM|$IOV"
pin  "5 grouped AVG(INT128)" "SELECT G, AVG(H) FROM P GROUP BY G ORDER BY G;" "G AVG|$IOV"
pin  "5 grouped SUM(DOUBLE): 1E308 + 1E308 first" "SELECT G, SUM(D) FROM P GROUP BY G ORDER BY G;" "G SUM|$FOV"
pin  "5 HAVING SUM(DOUBLE) raises too" "SELECT G FROM P GROUP BY G HAVING SUM(D) > 0 ORDER BY G;" "G|$FOV"
pin  "5 grouped STDDEV_POP: Inf - Inf is NaN" "SELECT G, STDDEV_POP(D) FROM P GROUP BY G ORDER BY G;" "G STDDEV_POP|1 NaN|2 NaN"
pin  "5 a referenced ID orders by ID: no overflow" "SELECT G, SUM(H), MAX(ID) FROM P GROUP BY G ORDER BY G;" "G SUM MAX|1 0 4|2 0 8"
pin  "5 ...an ID named only in the WHERE too" "SELECT G, SUM(H) FROM P WHERE ID > 0 GROUP BY G ORDER BY G;" "G SUM|1 0|2 0"
pin  "5 grouped SUM(DOUBLE): the 1s first, whatever the scan order" "SELECT G, CAST(SUM(X) AS DECIMAL(18,0)) FROM W GROUP BY G ORDER BY G;" "G CAST|1 -9999999999999998|2 -9999999999999998|3 -9999999999999998"
pin  "5 CONTROL ungrouped folds in scan order" "SELECT CAST(SUM(X) AS DECIMAL(18,0)) FROM W WHERE G = 1;" "CAST|-10000000000000000"
pin  "5 window PARTITION BY: record order" "SELECT G, CAST(SUM(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S FROM W ORDER BY 1, 2;" "G S|1 -9999999999999998|1 -9999999999999998|1 -9999999999999998|2 -9999999999999998|2 -9999999999999998|2 -9999999999999998|3 -9999999999999998|3 -9999999999999998|3 -9999999999999998"
pin  "5 window: a projected K leads the record" "SELECT G, K, CAST(SUM(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S FROM W ORDER BY 1, 2;" "G K S|1 0 -10000000000000000|1 5 -10000000000000000|1 9 -10000000000000000|2 0 -10000000000000000|2 5 -10000000000000000|2 9 -10000000000000000|3 1 -10000000000000000|3 2 -10000000000000000|3 3 -10000000000000000"
pin  "5 window: a projected ID orders by ID" "SELECT ID, CAST(SUM(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S FROM W ORDER BY 1;" "ID S|1 -10000000000000000|2 -10000000000000000|3 -10000000000000000|4 -9999999999999998|5 -9999999999999998|6 -9999999999999998|7 -10000000000000000|8 -10000000000000000|9 -10000000000000000"
pin  "5 window: K named only in the WHERE" "SELECT G, CAST(SUM(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S FROM W WHERE K >= 0 ORDER BY 1, 2;" "G S|1 -10000000000000000|1 -10000000000000000|1 -10000000000000000|2 -10000000000000000|2 -10000000000000000|2 -10000000000000000|3 -10000000000000000|3 -10000000000000000|3 -10000000000000000"
pin  "5 window: K named by another window's PARTITION BY" "SELECT G, CAST(SUM(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S, COUNT(*) OVER (PARTITION BY K) C FROM W ORDER BY 1, 2;" "G S C|1 -10000000000000000 2|1 -10000000000000000 2|1 -10000000000000000 2|2 -10000000000000000 2|2 -10000000000000000 2|2 -10000000000000000 2|3 -10000000000000000 1|3 -10000000000000000 1|3 -10000000000000000 1"
pin  "5 window ORDER BY: peers in record order" "SELECT G, CAST(SUM(X) OVER (ORDER BY G) AS DECIMAL(18,0)) S FROM W ORDER BY 1, 2;" "G S|1 -9999999999999998|1 -9999999999999998|1 -9999999999999998|2 -19999999999999996|2 -19999999999999996|2 -19999999999999996|3 -29999999999999996|3 -29999999999999996|3 -29999999999999996"
pin  "5 window AVG" "SELECT G, CAST(AVG(X) OVER (PARTITION BY G) AS DECIMAL(18,0)) S FROM W ORDER BY 1, 2;" "G S|1 -3333333333333333|1 -3333333333333333|1 -3333333333333333|2 -3333333333333333|2 -3333333333333333|2 -3333333333333333|3 -3333333333333333|3 -3333333333333333|3 -3333333333333333"
pin  "5 window SUM(INT128): 1, -5, max fits" "SELECT G, SUM(H) OVER (PARTITION BY G) S FROM W WHERE G = 1;" "G S|1 170141183460469231731687303715884105723|1 170141183460469231731687303715884105723|1 170141183460469231731687303715884105723"
pin  "5 window SUM(INT128): K first, max + 1 raises" "SELECT G, K, SUM(H) OVER (PARTITION BY G) S FROM W WHERE G = 1;" "G K S|$IOV"
pin  "5 CONTROL OVER () does not sort: scan order" "SELECT G, CAST(SUM(X) OVER () AS DECIMAL(18,0)) S FROM W WHERE G = 1;" "G S|1 -10000000000000000|1 -10000000000000000|1 -10000000000000000"
pin  "5 CONTROL ...and scan order the other way" "SELECT G, CAST(SUM(X) OVER () AS DECIMAL(18,0)) S FROM W WHERE G = 2;" "G S|2 -9999999999999998|2 -9999999999999998|2 -9999999999999998"
pin  "5 CONTROL an explicit ORDER BY K" "SELECT G, CAST(SUM(X) OVER (PARTITION BY G ORDER BY K) AS DECIMAL(18,0)) S FROM W WHERE G = 3 ORDER BY 2;" "G S|3 -10000000000000000|3 -10000000000000000|3 1"

echo "--- 6. VAR / STDDEV OVER INT128 / NUMERIC(38) / DECFLOAT ARE DECFLOAT(34) (a DOUBLE, or refused)"
dsame "6 describe: DECFLOAT(34), not nullable" "SELECT STDDEV_POP(H), STDDEV_SAMP(N), VAR_POP(D16), VAR_SAMP(D34), STDDEV_POP(B) FROM S;"
pin  "6 INT128: STDDEV_POP is the variance" "SELECT STDDEV_POP(H), STDDEV_SAMP(H), VAR_POP(H), VAR_SAMP(H) FROM S;" "STDDEV_POP STDDEV_SAMP VAR_POP VAR_SAMP|10.55555555555555555555555555555555 3.559026084010437070270507988531903 10.55555555555555555555555555555555 12.66666666666666666666666666666666"
pin  "6 NUMERIC(38,2)" "SELECT STDDEV_POP(N), STDDEV_SAMP(N), VAR_POP(N), VAR_SAMP(N) FROM S;" "STDDEV_POP STDDEV_SAMP VAR_POP VAR_SAMP|8.404180555555555555555555555555555 3.175691525741545739571915219755075 8.404180555555555555555555555555555 10.08501666666666666666666666666667"
pin  "6 DECFLOAT(16) (was refused)" "SELECT STDDEV_POP(D16), STDDEV_SAMP(D16), VAR_SAMP(D16) FROM S;" "STDDEV_POP STDDEV_SAMP VAR_SAMP|8.768055555555555555555555555555555 3.243711865543341792994219349789951 10.52166666666666666666666666666667"
pin  "6 DECFLOAT(34) (was refused)" "SELECT STDDEV_POP(D34), STDDEV_SAMP(D34) FROM S;" "STDDEV_POP STDDEV_SAMP|8.768055555555555555555555555555555 3.243711865543341792994219349789951"
pin  "6 grouped: the cohort, and NULL as 0E-6176" "SELECT G, STDDEV_POP(H), STDDEV_SAMP(H), VAR_SAMP(N) FROM S GROUP BY G ORDER BY G;" "G STDDEV_POP STDDEV_SAMP VAR_SAMP|1 1.555555555555555555555555555555557 1.527525231651946668862682397909337 1.5625|2 0 0E-6176 0E-6176|3 0.25 0.7071067811865475244008443621048490 0.5000"
pin  "6 an INT128 EXPRESSION source" "SELECT STDDEV_POP(H + 0), STDDEV_POP(CAST(ID AS INT128)), STDDEV_POP(CAST(ID AS NUMERIC(38,3)) / 7) FROM S;" "STDDEV_POP STDDEV_POP STDDEV_POP|10.55555555555555555555555555555555 4 0.081796"
pin  "6 an empty fold is the NULL shown as 0E-6176" "SELECT STDDEV_POP(H) FROM S WHERE ID > 100;" "STDDEV_POP|0E-6176"
pin  "6 ...which is NULL (a lone row's SAMP; its POP is 0)" "SELECT COALESCE(STDDEV_POP(H), -1), COALESCE(VAR_SAMP(H), -1), VAR_SAMP(H) IS NULL FROM S WHERE ID = 1;" "COALESCE COALESCE BOOL|0 -1 <true>"
pin  "6 CONTROL a BIGINT source stays DOUBLE" "SELECT STDDEV_POP(B), VAR_SAMP(B) FROM S;" "STDDEV_POP VAR_SAMP|3.248931448269655 12.66666666666667"
recorded "6 CORR over an INT128 first argument is refused here" "SELECT CORR(H, ID) FROM S;" "CORR|0.7843266893787232114218613551766932"

echo "--- 7. MIN / MAX MEETING A NaN, CAST(Infinity AS FLOAT), (ALL x)"
NAN1="(SELECT VAR_POP(X) W FROM DX UNION ALL SELECT 1e0 $DUAL)"
NAN2="(SELECT 1e0 W $DUAL UNION ALL SELECT VAR_POP(X) FROM DX)"
pin  "7 NaN then 1: MIN 1, MAX NaN" "SELECT MIN(W), MAX(W) FROM $NAN1;" "MIN MAX|1.000000000000000 NaN"
pin  "7 1 then NaN: MIN NaN, MAX 1" "SELECT MIN(W), MAX(W) FROM $NAN2;" "MIN MAX|NaN 1.000000000000000"
pin  "7 Infinity then NaN" "SELECT MIN(W), MAX(W) FROM (SELECT VAR_POP(X) W FROM V UNION ALL SELECT VAR_POP(X) FROM DX);" "MIN MAX|NaN Infinity"
pin  "7 NaN then Infinity" "SELECT MIN(W), MAX(W) FROM (SELECT VAR_POP(X) W FROM DX UNION ALL SELECT VAR_POP(X) FROM V);" "MIN MAX|Infinity NaN"
pin  "7 CONTROL 1, NaN, 0" "SELECT MIN(W), MAX(W) FROM (SELECT 1e0 W $DUAL UNION ALL SELECT VAR_POP(X) FROM DX UNION ALL SELECT 0e0 $DUAL);" "MIN MAX|0.000000000000000 1.000000000000000"
pin  "7 CAST(Infinity AS FLOAT)" "SELECT CAST(VAR_POP(X) AS FLOAT), CAST(-VAR_POP(X) AS FLOAT) FROM V;" "CAST CAST|Infinity -Infinity"
pin  "7 SUM over a FLOAT Infinity raises Floating-point overflow" "SELECT SUM(W) FROM (SELECT CAST(VAR_POP(X) AS FLOAT) W FROM V);" "SUM|$FOV"
pin  "7 CONTROL a finite double past FLOAT still raises" "SELECT CAST(1e300 AS FLOAT) $DUAL;" "CAST|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range"
pin  "7 SUM/AVG/COUNT/MIN/MAX (ALL x)" "SELECT SUM(ALL ID), AVG(ALL ID), COUNT(ALL ID), MIN(ALL ID), MAX(ALL ID) FROM P;" "SUM AVG COUNT MIN MAX|36 4 8 1 8"
pin  "7 (ALL x) grouped and FILTERed" "SELECT G, SUM(ALL ID), SUM(ALL ID) FILTER (WHERE ID > 5) FROM P GROUP BY G ORDER BY G;" "G SUM SUM|1 10 <null>|2 26 21"
pin  "7 (ALL x) windowed" "SELECT ID, SUM(ALL ID) OVER (PARTITION BY G) FROM P WHERE ID IN (1, 2, 5) ORDER BY ID;" "ID SUM|1 3|2 3|5 5"
err_differs "7 CONTROL STDDEV_POP(ALL x) is a syntax error on the engine" "SELECT STDDEV_POP(ALL ID) FROM P;"

echo "--- 8. A NaN / INFINITE AGGREGATE INSERTED (it was refused)"
pin  "8 INSERT ... SELECT stores NaN and Infinity" "INSERT INTO R1 (ID, D) SELECT 1, STDDEV_POP(X) FROM DX; INSERT INTO R1 (ID, D) SELECT 2, VAR_POP(X) FROM V; INSERT INTO R1 (ID, D) SELECT 3, -VAR_POP(X) FROM V; INSERT INTO R1 (ID, F) SELECT 4, VAR_POP(X) FROM DX; INSERT INTO R1 (ID, F) SELECT 5, VAR_POP(X) FROM V; SELECT ID, D, F FROM R1 ORDER BY ID;" "ID D F|1 NaN <null>|2 Infinity <null>|3 -Infinity <null>|4 <null> NaN|5 <null> Infinity"
recorded "8 INSERT VALUES (.., (SELECT <NaN>)) is refused here" "INSERT INTO R2 (ID, D) VALUES (7, (SELECT STDDEV_POP(X) FROM DX)); SELECT ID, D FROM R2;" "ID D|7 NaN"

echo "--- 9. RECORDED: PSQL and view spellings (refused here)"
recorded "9 EXECUTE BLOCK RETURNS (R INT128)" "SET TERM ^; EXECUTE BLOCK RETURNS (R INT128) AS BEGIN R = 1; SUSPEND; END^ SET TERM ;^" "R|1"
recorded "9 EXECUTE BLOCK: SUM INTO an INT128 raises there" "SET TERM ^; EXECUTE BLOCK RETURNS (R INT128) AS BEGIN SELECT SUM(H) FROM P WHERE ID IN (2, 4) INTO :R; SUSPEND; END^ SET TERM ;^" "R|$IOV|-At block line: 1, col: 43"
recorded "9 CREATE VIEW over a GROUP BY" "CREATE VIEW VWG AS SELECT G, SUM(ID) S FROM P GROUP BY G; SELECT * FROM VWG ORDER BY G;" "G S|1 10|2 26"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-aggfold-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 90 ]; then echo "FAIL only $ran checks ran (floor 90)"; fail=1; fi
exit $fail
