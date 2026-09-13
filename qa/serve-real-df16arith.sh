#!/bin/bash
# DECFLOAT(16)-op-DECFLOAT(16) arithmetic describes and evaluates as
# DECFLOAT(16) (16 sig), matching the engine; any DECFLOAT(34) or promoted
# non-decfloat operand stays DECFLOAT(34). fire-crab used an arith-always-34
# rule (every decfloat arithmetic tree described df34 and computed 34 sig).
#
# The engine carries decfloat arithmetic in a 34-sig decimal128 intermediate
# (decQuad) and NARROWS to decimal64 only at MATERIALIZATION - a bare df16
# output column or a store into a df16 column. So fire-crab now:
#   * DESCRIBES a decfloat arithmetic tree by the recursive engine rule -
#     both operands reduce to df16 => DECFLOAT(16) (32760/8), any df34 or a
#     promoted non-decfloat operand => DECFLOAT(34) (32762/16); Neg keeps
#     the child's width;
#   * keeps computing the value as a 34-sig DecFloat34 (so a consumer that
#     keeps it wide - CAST(.. AS VARCHAR), further arithmetic - sees 34 sig,
#     as the engine does);
#   * NARROWS to decimal64 (16 sig HALF-UP) in ProjCol::value_of when the
#     announced column is DECFLOAT(16), raising the engine's 22003 on a
#     decimal64 magnitude overflow - the materialization point.
# This also unblocks AVG/MIN/MAX over a both-df16 Bin or -df16 (now
# DECFLOAT(16)); SUM stays DECFLOAT(34). Held against the live engine.
#
# Usage: qa/serve-real-df16arith.sh [port]   (default 4169)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4169}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/df16arith-eng.fdb"; FC="$D/df16arith-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/df16arith-build.log 2>&1 <<'SQL'
create table t(id int, a decfloat(16), b decfloat(16), c decfloat(34), i int, big decfloat(16));
commit;
insert into t values (1, 1.5, 2.5, 1.25, 100, 9.9E+300);
insert into t values (2, 3.5, 4.5, 2.75, 200, 1.0);
commit;
SQL
if grep -qi error /tmp/df16arith-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/df16arith-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-df16arith.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^X |SQLSTATE' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
vc() { printf "cast(%s as varchar(70))" "$1"; }

echo "-- WIDTH: both-df16 -> DECFLOAT(16) 32760/8 --"
for e in "a+b" "a-b" "a*b" "a/b" "-a" "(a+b)+b" "((a+b)*b)+a"; do agree "$e" "select $e x from t where id=1;"; done
echo "-- WIDTH: any df34 or promoted operand -> DECFLOAT(34) 32762/16 --"
for e in "a+c" "a*c" "a-c" "a/c" "-c" "a+i" "a*2" "a+1.5" "(a+b)*c" "(a+b)+i" "c+c"; do agree "$e" "select $e x from t where id=1;"; done
echo "-- VALUE at 16 sig (bare df16 delivery, HALF-UP) --"
agree "1/3 df16"  "select cast(1 as decfloat(16))/cast(3 as decfloat(16)) x from t where id=1;"
agree "2/3 df16"  "select cast(2 as decfloat(16))/cast(3 as decfloat(16)) x from t where id=1;"
agree "1/7 df16"  "select cast(1 as decfloat(16))/cast(7 as decfloat(16)) x from t where id=1;"
agree "big mul"   "select cast(1234567.123456 as decfloat(16))*cast(9.999 as decfloat(16)) x from t where id=1;"
agree "a+b=4.0"   "select a+b x from t where id=1;"
agree "a*b=3.75"  "select a*b x from t where id=1;"
agree "-a=-1.5"   "select -a x from t where id=1;"
echo "-- the 34-sig INTERMEDIATE leaks to a wider consumer (must NOT narrow) --"
agree "CAST(1/3 df16 AS varchar)" "select $(vc "cast(1 as decfloat(16))/cast(3 as decfloat(16))") x from t where id=1;"
agree "downstream (1/3)*3"        "select $(vc "cast(1 as decfloat(16))/cast(3 as decfloat(16))*cast(3 as decfloat(16))") x from t where id=1;"
echo "-- DECFLOAT(34) contrast: stays 34 sig --"
agree "1/3 df34" "select cast(1 as decfloat(34))/cast(3 as decfloat(34)) x from t where id=1;"
echo "-- OVERFLOW: bare df16 materialization raises 22003; wider consumer does not --"
agree "big*big bare raises"       "select big*big x from t where id=1;"
agree "big*big filtered no raise" "select big*big x from t where id=2;"
agree "CAST(big*big AS varchar)"  "select $(vc "big*big") x from t where id=1;"
echo "-- a df16-arith branch inside a conditional announces df16 --"
agree "coalesce(a+b, a)" "select coalesce(a+b, a) x from t where id=1;"
echo "-- aggregates now unblocked: AVG/MIN/MAX over both-df16 arith / -df16 --"
agree "avg(a-b)" "select avg(a-b) x from t;"
agree "min(a-b)" "select min(a-b) x from t;"
agree "max(-a)"  "select max(-a) x from t;"
agree "sum(a-b) stays df34" "select sum(a-b) x from t;"
agree "avg(a-b) value" "select $(vc "avg(a-b)") x from t;"
echo "-- regression: bare df16 column + df34 column unchanged --"
agree "a col df16" "select a x from t where id=1;"
agree "c col df34" "select c x from t where id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS df16arith" || echo "FAIL df16arith"
exit $fail
