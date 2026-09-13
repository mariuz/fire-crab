#!/bin/bash
# A CONDITIONAL WITH A DECFLOAT BRANCH TYPES AND EVALUATES AS DECFLOAT,
# matching the engine - where fire-crab used to refuse the mix (42000).
#
# COALESCE / CASE / IIF / DECODE / NULLIF with a DECFLOAT branch: the
# engine types the result DECFLOAT and coerces the other branch into it.
# Precedence (measured, order-independent): DECFLOAT dominates every exact
# numeric AND DOUBLE/FLOAT; within DECFLOAT, DECFLOAT(34) > DECFLOAT(16).
# The width is 34 iff ANY branch is a df34 leaf, else 16 - a non-decfloat
# sibling converts INTO that width and never bumps 16->34. NULLIF takes its
# FIRST operand's type/width alone. A bare NULL branch is transparent; the
# node is always Nullable (as the engine describes it).
#
# fire-crab has no ExprType for DECFLOAT; instead the whole conditional
# node is wrapped in a CAST to DECFLOAT at resolve time (decfloat_conditional),
# so the existing decfloat-cast describe (its own width) and eval (Value ->
# decimal at the result width, reusing value_as_dec / f64_to_dec / fit_dec64)
# carry it. A non-numeric (TEXT/temporal/bool) sibling is left unwrapped and
# still refuses (the conditional_type guard) - TEXT-dominant folding is a
# separate slice.
#
# Usage: qa/serve-real-dfcond.sh [port]   (default 4150)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4150}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/dfcond.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/dfcond-build.log 2>&1 <<'SQL'
create table t (id int, d16 decfloat(16), e16 decfloat(16), d34 decfloat(34), n numeric(18,4), i integer, dp double precision);
commit;
insert into t values (1, 2.5, null, 2.5, 2.5, 2, 0.1);
insert into t values (2, 10, null, 10, 10.0, 10, 0.5);
commit;
SQL
if grep -qi error /tmp/dfcond-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/dfcond-build.log; exit 1; fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfcond.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
# describe (sqltype/len/scale) + value, or the SQLSTATE
sig() { local r; r=$(printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qiE 'SQLSTATE'; then printf '%s' "$r" | grep -oiE 'SQLSTATE = [0-9A-Z]+' | head -1; \
    else printf '%s' "$r" | grep -iE '^01: sqltype|^(V|ID|X) ' | tr '\n' '|'; fi; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1" || { echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; }; }
fc_refuses() { local f; f=$(sig "$F" "$2"); printf '%s' "$f" | grep -qiE 'SQLSTATE' \
    && echo "OK   refuse $1 (deferred; engine answers)" \
    || { echo "FAIL refuse $1 expected fc REFUSE, got [$f]"; fail=1; }; }
vc() { printf "cast(%s as varchar(40))" "$1"; }

echo "-- decfloat conditional mixes: TYPE/WIDTH now matches (was refuse) --"
agree "COALESCE(d16,i)"   "select coalesce(d16,i) v from t where id=1;"
agree "COALESCE(i,d16)"   "select coalesce(i,d16) v from t where id=1;"
agree "COALESCE(d16,n)"   "select coalesce(d16,n) v from t where id=1;"
agree "COALESCE(d16,dp)"  "select coalesce(d16,dp) v from t where id=1;"
agree "COALESCE(dp,d16)"  "select coalesce(dp,d16) v from t where id=1;"
agree "COALESCE(d16,d34)" "select coalesce(d16,d34) v from t where id=1;"
agree "COALESCE(d34,d16)" "select coalesce(d34,d16) v from t where id=1;"
agree "CASE d34 else int" "select case when id=1 then d34 else 5 end v from t where id=1;"
agree "IIF(d34,int)"      "select iif(id=1,d34,5) v from t where id=1;"
agree "DECODE d34/int"    "select decode(id,1,d34,9) v from t where id=1;"
agree "NULLIF(d34,i)"     "select nullif(d34,i) v from t where id=1;"
agree "NULLIF(d34,d16)"   "select nullif(d34,d16) v from t where id=1;"
echo "-- VALUE (exact digits via varchar) --"
agree "COALESCE(null,1.5d16)"     "select $(vc "coalesce(e16, cast(1.5 as decfloat(16)))") v from t where id=1;"
agree "d16 widened into d34"      "select $(vc "coalesce(d16,d34)") v from t where id=1;"
agree "int 5 -> d34"              "select $(vc "coalesce(cast(null as decfloat(34)), 5)") v from t where id=1;"
agree "double 0.1 -> d34 (17sig)" "select $(vc "coalesce(cast(null as decfloat(34)), 0.1e0)") v from t where id=1;"
agree "double 0.1 -> d16 (16sig)" "select $(vc "coalesce(cast(null as decfloat(16)), 0.1e0)") v from t where id=1;"
agree "int overflow -> d16 HALF-UP" "select $(vc "coalesce(cast(null as decfloat(16)), 12345678901234567890)") v from t where id=1;"
agree "CASE else NULL no-match d34" "select case when id=99 then d34 else null end v from t where id=1;"
agree "NULLIF(d16,d16) equal->NULL"  "select $(vc "nullif(d16, cast(2.5 as decfloat(16)))") v from t where id=1;"
echo "-- decfloat conditional under WHERE / arithmetic (via is_decfloat_arith) --"
agree "WHERE coalesce(d16,0)>1" "select id from t where coalesce(d16, cast(0 as decfloat(16))) > 1;"
agree "coalesce(d16,0)+1"       "select $(vc "coalesce(d16,cast(0 as decfloat(16)))+1") v from t where id=1;"
echo "-- controls: non-decfloat conditionals + NULLIF-first-operand unchanged --"
agree "COALESCE(i,n)"           "select coalesce(i,n) v from t where id=2;"
agree "COALESCE(null,text)"     "select coalesce(cast(null as varchar(3)),'xx') v from rdb\$database;"
agree "CASE int"                "select case when id=1 then 7 else 9 end v from t where id=1;"
agree "COALESCE(null-num,dbl)"  "select coalesce(cast(null as numeric(9,2)),cast(2.5 as double precision)) v from rdb\$database;"
agree "NULLIF(i,d34)->int"      "select nullif(i,d34) v from t where id=1;"
agree "NULLIF(i,5)"             "select nullif(i,5) v from t where id=1;"
echo "-- an aggregate over a decfloat conditional now answers (agg-over-decfloat-expression) --"
agree "SUM(COALESCE(d16,0))"        "select sum(coalesce(d16, cast(0 as decfloat(16)))) v from t;"
agree "AVG(COALESCE(d16,0))"        "select avg(coalesce(d16, cast(0 as decfloat(16)))) v from t;"
echo "-- deferred (still refuse): TEXT-mixed decfloat conditional --"
fc_refuses "COALESCE(d16,varchar)"  "select coalesce(d16, cast(1 as varchar(10))) v from t where id=1;"
fc_refuses "COALESCE(d16,'5')"      "select coalesce(d16, '5') v from t where id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dfcond" || echo "FAIL dfcond"
exit $fail
