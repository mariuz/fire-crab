#!/bin/bash
# SUM/AVG/MIN/MAX over a DECFLOAT EXPRESSION (df+1, df*2, a CAST-to-DECFLOAT,
# a lowered COALESCE/CASE/IIF/NULLIF) describes and evaluates like the
# engine, where fire-crab answered only over a decfloat COLUMN and refused
# an expression source at prepare.
#
# The fold already produced the right VALUE (the per-row expression
# evaluates to a decfloat Value and the decfloat accumulator/keep folds it);
# only the DESCRIBE refused. Now:
#   * SUM over any decfloat expression -> DECFLOAT(34) (width-immune, engine
#     agrees - even d16-d16 and -d16);
#   * AVG/MIN/MAX PRESERVE the expression's own decfloat width: a Bin with a
#     non-decfloat operand or any df34 -> df34 (d16+1, d16*2), a CAST/lowered
#     COALESCE leaf -> its own width, a df34 leaf -> df34.
# REFUSED (law-safe, never a wrong width): AVG/MIN/MAX over a Bin whose BOTH
# operands are DECFLOAT(16) (d16-d16) or a Neg of a df16 cohort (-d16) - the
# engine keeps df16 but the shipped arith-always-34 fold would emit df34, so
# describing either width would disagree with the other. SUM is immune (its
# result is df34, which the engine also gives) and IS answered for those.
#
# Held against the live engine (describe + value); a scratch db removed after.
#
# Usage: qa/serve-real-decfloataggexpr.sh [port]   (default 4168)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4168}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfaggexpr-eng.fdb"; FC="$D/dfaggexpr-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfaggexpr-build.log 2>&1 <<'SQL'
create table t(id int, d16 decfloat(16), d34 decfloat(34), i integer);
commit;
insert into t values (1, 1.5, 10.25, 100);
insert into t values (2, 2.5, 20.75, 200);
insert into t values (3, null, 30.5, 300);
commit;
SQL
if grep -qi error /tmp/dfaggexpr-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfaggexpr-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfaggexpr.log 2>&1 &
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
refuses_fc() { local f; f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | grep -iE 'SQLSTATE'); [ -n "$f" ] && echo "OK   refuse $1" || { echo "FAIL refuse $1 (fc answered)"; fail=1; }; }
vc() { printf "cast(%s as varchar(50))" "$1"; }

echo "-- SUM over any decfloat expression -> DECFLOAT(34) --"
agree "sum(d16+1)"            "select sum(d16+1) x from t;"
agree "sum(d16*2)"           "select sum(d16*2) x from t;"
agree "sum(d16-d16)"         "select sum(d16-d16) x from t;"
agree "sum(-d16)"            "select sum(-d16) x from t;"
agree "sum(cast(i as df34))" "select sum(cast(i as decfloat(34))) x from t;"
agree "sum(coalesce(d16,0))" "select sum(coalesce(d16, cast(0 as decfloat(16)))) x from t;"
echo "-- AVG/MIN/MAX preserve the expression's width (df34 for arith with a scalar) --"
for f in avg min max; do agree "$f(d16+1)" "select $f(d16+1) x from t;"; done
for f in avg min max; do agree "$f(d16*2)" "select $f(d16*2) x from t;"; done
for f in avg min max; do agree "$f(d34+1)" "select $f(d34+1) x from t;"; done
echo "-- AVG/MIN/MAX over a CAST / lowered-COALESCE leaf -> that leaf's width --"
agree "avg(cast(i as df16))"       "select avg(cast(i as decfloat(16))) x from t;"
agree "min(cast(d16 as df16))"     "select min(cast(d16 as decfloat(16))) x from t;"
agree "max(cast(i as df34))"       "select max(cast(i as decfloat(34))) x from t;"
agree "avg(coalesce(d16,0)) df16"  "select avg(coalesce(d16, cast(0 as decfloat(16)))) x from t;"
agree "max(coalesce(d16,d34)) df34" "select max(coalesce(d16,d34)) x from t;"
echo "-- VALUE (exact digits) --"
agree "sum(d16+1)=6.0"        "select $(vc "sum(d16+1)") x from t;"
agree "sum(cast i df34)=600"  "select $(vc "sum(cast(i as decfloat(34)))") x from t;"
agree "avg(coalesce(d16,0))"  "select $(vc "avg(coalesce(d16, cast(0 as decfloat(16))))") x from t;"
agree "max(coalesce)=30.5"    "select $(vc "max(coalesce(d16,d34))") x from t;"
agree "min(d16*2)=3.0"        "select $(vc "min(d16*2)") x from t;"
echo "-- empty / all-null / NULL-skip semantics --"
agree "sum over no rows"      "select sum(d16+1) x from t where id=99;"
agree "avg(d16) skips null"   "select $(vc "avg(d16)") x from t;"
echo "-- grouped --"
agree "g, sum(d16+1)"         "select id, sum(d16+1) x from t group by id;"
agree "g, avg(d16*2)"         "select id, avg(d16*2) x from t group by id;"
# The df16-arithmetic chunk unblocked these: AVG/MIN/MAX over a both-df16
# Bin or -df16 now describe DECFLOAT(16) and fold at 16 sig, matching the
# engine (the fold's 34-sig result is narrowed at materialization).
echo "-- AVG/MIN/MAX over both-df16 Bin / -df16 -> DECFLOAT(16) (now answered) --"
agree "avg(d16-d16)"     "select avg(d16-d16) x from t;"
agree "min(d16-d16)"     "select min(d16-d16) x from t;"
agree "max(d16-d16)"     "select max(d16-d16) x from t;"
agree "avg(-d16)"        "select avg(-d16) x from t;"
agree "min(-d16)"        "select min(-d16) x from t;"
agree "sum(d16-d16)=0.0" "select $(vc "sum(d16-d16)") x from t;"
echo "-- regression: aggregate over a decfloat COLUMN unchanged --"
agree "sum(d16) col"          "select sum(d16) x from t;"
agree "avg(d16) col"          "select avg(d16) x from t;"
agree "min(d34) col"          "select min(d34) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloataggexpr" || echo "FAIL decfloataggexpr"
exit $fail
