#!/bin/bash
# A NON-FINITE DECFLOAT cast to DOUBLE/FLOAT TRAPS exactly as the engine
# does, instead of shipping a silent Infinity/NaN or the wrong error.
#
# The cast-out-of-DECFLOAT chunk decoded the operand and parsed its
# canonical string to f64 - which for an Infinity/NaN source yields a
# non-finite double the DOUBLE branch shipped verbatim (a confident wrong
# value, the archetypal LAW break), while the FLOAT branch narrowed it and
# posted numeric_out_of_range for BOTH cases. The engine instead:
#   * Infinity (either sign, either target): SQLSTATE 22003 with the
#     float-overflow gdscode emitted ALONE - "Floating-point overflow. ..."
#     with NO "arithmetic exception" prefix (a genuine binary-float
#     arithmetic overflow DOES keep that prefix - the control below holds
#     it - so the two share a SQLSTATE but not the message shape);
#   * NaN and sNaN (either target): SQLSTATE 22000, decimal-float invalid
#     operation emitted alone.
# A new EvalErr::FloatOverflowBare carries the un-wrapped float_overflow;
# the guard sits only in the two decfloat-source cast arms, so every finite
# conversion is untouched (controls). Held against the live engine.
#
# Usage: qa/serve-real-castdfnonfinite.sh [port]   (default 4162)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4162}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/castdfnf-eng.fdb"; FC="$D/castdfnf-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/castdfnf-build.log 2>&1 <<'SQL'
create table t(x integer);
commit;
insert into t values (1);
commit;
SQL
if grep -qi error /tmp/castdfnf-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/castdfnf-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castdfnf.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# full failure block (SQLSTATE + every gds line) or the value - so the gate
# holds the message SHAPE (arith_except prefix present or absent), not just
# the SQLSTATE
sig() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -viE '^$|SQL>|Database:' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
c() { printf "cast(cast('%s' as decfloat(%s)) as %s)" "$1" "$3" "$2"; }

echo "-- Infinity -> DOUBLE/FLOAT: 22003 float_overflow emitted ALONE --"
agree "+Inf df34 -> double" "select $(c Infinity  'double precision' 34) v from t;"
agree "-Inf df34 -> double" "select $(c -Infinity 'double precision' 34) v from t;"
agree "+Inf df34 -> float"  "select $(c Infinity  'float' 34) v from t;"
agree "-Inf df34 -> float"  "select $(c -Infinity 'float' 34) v from t;"
agree "+Inf df16 -> double" "select $(c Infinity  'double precision' 16) v from t;"
agree "+Inf df16 -> float"  "select $(c Infinity  'float' 16) v from t;"
echo "-- NaN / sNaN -> DOUBLE/FLOAT: 22000 decfloat invalid operation --"
agree "NaN df34 -> double"  "select $(c NaN  'double precision' 34) v from t;"
agree "sNaN df34 -> double" "select $(c sNaN 'double precision' 34) v from t;"
agree "NaN df34 -> float"   "select $(c NaN  'float' 34) v from t;"
agree "sNaN df34 -> float"  "select $(c sNaN 'float' 34) v from t;"
agree "NaN df16 -> double"  "select $(c NaN  'double precision' 16) v from t;"
agree "sNaN df16 -> float"  "select $(c sNaN 'float' 16) v from t;"
echo "-- controls: finite conversions still succeed with the right value --"
agree "1.5 df34 -> double"  "select $(c 1.5  'double precision' 34) v from t;"
agree "-2.5 df16 -> double" "select $(c -2.5 'double precision' 16) v from t;"
agree "0.1 df34 -> float"   "select $(c 0.1  'float' 34) v from t;"
agree "3.14 df16 -> float"  "select $(c 3.14 'float' 16) v from t;"
echo "-- control: a genuine binary-float overflow KEEPS the arith_except prefix --"
agree "double*double overflow" "select cast('1e300' as double precision)*cast('1e300' as double precision) v from t;"
agree "float overflow via cast" "select cast('1e40' as float) v from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castdfnonfinite" || echo "FAIL castdfnonfinite"
exit $fail
