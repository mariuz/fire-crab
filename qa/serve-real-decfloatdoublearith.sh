#!/bin/bash
# DECFLOAT +/-/*// a RUNTIME DOUBLE/FLOAT is DECFLOAT(34) arithmetic,
# matching the engine, where fire-crab refused or errored (is_decfloat_arith
# rejected a double leaf, so a df-op-double tree was not recognized).
#
# Any +/-/*/ between a DECFLOAT operand (df16 or df34) and a runtime
# approximate operand (a DOUBLE/FLOAT column, a CAST(.. AS DOUBLE/FLOAT)),
# EITHER order, is DECFLOAT(34) (32762/16/scale0): DECFLOAT dominates DOUBLE
# (the shipped compare/conditional/union precedence), and the approx forces
# df34 even over a df16. The approx operand is converted to a decimal at 17
# significant digits (f64_to_dec, the CAST-to-DECFLOAT vehicle - a FLOAT
# widened to f64 first) BEFORE the decimal128 op runs at 34-sig HALF-UP.
#
# DEFERRED (kept refusing, never a wrong value): a bare double/float LITERAL
# operand (df * 2.5e0) - the engine's constant fold is measured
# inconsistently across shapes and is not derivable from the f64; and
# SUM/AVG/MIN/MAX over a df-op-approx expression (unmeasured aggregate path).
#
# Also fixes a latent bug the chunk surfaced: an all-zero-significand
# exponent literal (0.0e0, 0e5) was mis-classified as DECFLOAT instead of
# DOUBLE, so `0.1e0 + 0.0e0` looked like a double+decfloat mix where the
# engine sees double+double -> DOUBLE.
#
# Usage: qa/serve-real-decfloatdoublearith.sh [port]   (default 4172)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4172}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfdarith-eng.fdb"; FC="$D/dfdarith-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfdarith-build.log 2>&1 <<'SQL'
create table t(id int, d16 decfloat(16), d34 decfloat(34), dp double precision, fl float);
commit;
insert into t values (1, 1.5, 1.5, 0.1, 0.1);
insert into t values (2, 4, 4, 2.5, 2.5);
commit;
SQL
if grep -qi error /tmp/dfdarith-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfdarith-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfdarith.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
refuses_fc() { local f; f=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | grep -iE 'SQLSTATE'); [ -n "$f" ] && echo "OK   refuse $1 (deferred; engine answers)" || { echo "FAIL refuse $1 (fc answered)"; fail=1; }; }

echo "-- type + value: each op, both orders, df16/df34, dp/fl --"
for e in "d16+dp" "dp+d16" "d16-dp" "dp-d16" "d16*dp" "dp*d16" "d16/dp" "dp/d16"; do agree "$e" "select $e x from t where id=1;"; done
for e in "d34+dp" "d34-dp" "d34*dp" "d34/dp"; do agree "$e" "select $e x from t where id=1;"; done
for e in "d16+fl" "fl+d16" "d34*fl" "fl/d34"; do agree "$e" "select $e x from t where id=1;"; done
agree "d34 + CAST(x AS DOUBLE)" "select d34 + cast(id as double precision) x from t where id=1;"
echo "-- exact value digits (17-sig conversion, trailing zeros kept) --"
agree "d16+dp value"   "select cast(d16+dp as varchar(60)) x from t where id=1;"
agree "d34*dp = 10.0"  "select cast(d34*dp as varchar(60)) x from t where id=2;"
agree "d34(1)/dp(3) 34 threes" "select cast(cast(1 as decfloat(34))/cast(3 as double precision) as varchar(60)) x from t where id=1;"
agree "d16(1)/dp(3) 34 threes" "select cast(cast(1 as decfloat(16))/cast(3 as double precision) as varchar(60)) x from t where id=1;"
agree "d16*fl (float widened)" "select cast(d16*fl as varchar(60)) x from t where id=1;"
echo "-- nested + ripple surfaces (comparison, CAST) --"
agree "(d16+d16)+dp -> df34" "select (d16+d16)+dp x from t where id=1;"
agree "d16*dp+d34"           "select d16*dp+d34 x from t where id=1;"
agree "WHERE d16+dp > 5"     "select id from t where d16+dp > 5;"
agree "CAST(d16+dp AS varchar)" "select cast(d16+dp as varchar(60)) x from t where id=1;"
echo "-- DEFERRED: bare double LITERAL operand, and aggregate over df-op-approx --"
refuses_fc "d16*2.5e0"      "select d16*2.5e0 x from t where id=1;"
refuses_fc "2.5e0*d16"      "select 2.5e0*d16 x from t where id=1;"
refuses_fc "cast(2 as df34)*2.5e0" "select cast(2 as decfloat(34))*2.5e0 x from t where id=1;"
refuses_fc "SUM(d16+dp)"    "select sum(d16+dp) x from t;"
refuses_fc "AVG(d34*dp)"    "select avg(d34*dp) x from t;"
echo "-- zero-significand literal is DOUBLE (the surfaced fix) --"
agree "0.0e0"          "select 0.0e0 x from t where id=1;"
agree "0.1e0+0.0e0"    "select 0.1e0+0.0e0 x from t where id=1;"
agree "0e5"            "select 0e5 x from t where id=1;"
echo "-- regression: df/df and double/double arithmetic unchanged --"
agree "d16+d16 df16"   "select d16+d16 x from t where id=1;"
agree "d16*d34 df34"   "select d16*d34 x from t where id=1;"
agree "d16+int df34"   "select d16+5 x from t where id=1;"
agree "dp+dp double"   "select dp+dp x from t where id=1;"
agree "dp+int double"  "select dp+5 x from t where id=1;"
agree "-d16 df16"      "select -d16 x from t where id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloatdoublearith" || echo "FAIL decfloatdoublearith"
exit $fail
