#!/bin/bash
# A DECFLOAT column keeps its type through a DERIVED TABLE, a CTE and a
# VIEW - where fire-crab typed it INT64 and answered ZEROS.
#
# The synthetic relation the outer query sees for a derived table / CTE /
# view is built from the inner plan's ProjCols by desc_of_projcol, whose
# sqltype->dtype table had no arm for 32760 (DECFLOAT(16)) or 32762
# (DECFLOAT(34)): both fell to the INT64 default, so `WHERE a > 2` found no
# row, `SUM(a)` described INT128 and answered 0, `ORDER BY a` sorted zeros,
# `a * 2` was 0 and a JOIN on the column matched nothing. A bare
# `SELECT *` / `SELECT a` pass-through kept the ProjCol whole and was
# right, which is what hid it (the same bug class the TIME ZONE arms
# closed earlier). Measured against the engine: the column keeps
# DECFLOAT(16)/(34) through all three surfaces; SUM -> DECFLOAT(34),
# AVG/MIN/MAX keep the width, COUNT -> INT64, arithmetic -> DECFLOAT(34)
# (a both-df16 -a / COALESCE keep 16), `a || ''` -> VARYING 23 / 42.
#
# Also folded in: `UNION DISTINCT`, a synonym of the bare UNION that the
# union splitter refused (top level, derived, CTE).
#
# The views are created ON THE ENGINE before the copy (fire-crab does not
# run that DDL) - the copy is read through fire-crab's own metadata path.
#
# Usage: qa/serve-real-derivedecfloat.sh [port]   (default 4175)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4175}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfderiv-eng.fdb"; FC="$D/dfderiv-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfderiv-build.log 2>&1 <<'SQL'
create table t(id int, n int, s varchar(10), d16 decfloat(16), d34 decfloat(34));
create table u(id int, n int, s varchar(10));
create view v16 as select id, d16 a from t;
create view v34 as select id, d34 a from t;
commit;
insert into t values (1, 10, 'a', 1.5, 2.5);
insert into t values (2, 20, 'b', 3.5, 4.5);
insert into t values (3, 30, 'c', null, null);
insert into u values (2, 20, 'b');
insert into u values (4, 40, 'd');
commit;
SQL
if grep -qi error /tmp/dfderiv-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfderiv-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfderiv.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# every output column's describe line + every value line (set list on) +
# any failure block; the name/alias/table lines are deliberately NOT
# compared (see the recorded nit at the end)
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -aiE '^0[0-9]: sqltype|^[A-Z_][A-Z0-9_]* |SQLSTATE|^-' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
refuses_fc() { local f; f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if printf '%s' "$f" | grep -qiE 'SQLSTATE'; then echo "OK   $1 (fc refuses, deferred)"; else echo "FAIL $1 (fc should refuse)"; echo "     fc =[$f]"; fail=1; fi; }
U16="(select d16 a from t union all select d16 from t) q"
U34="(select d34 a from t union all select d34 from t) q"

echo "-- aggregates over a derived decfloat: SUM -> DECFLOAT(34), AVG/MIN/MAX keep width --"
agree "sum d16 union"        "select sum(a) from $U16;"
agree "sum d16 plain"        "select sum(a) from (select d16 a from t) q;"
agree "sum d34 union"        "select sum(a) from $U34;"
agree "sum d16+d34 mixed"    "select sum(a) from (select d16 a from t union all select d34 from t) q;"
agree "sum d16 U int"        "select sum(a) from (select d16 a from t union all select id from u) q;"
agree "avg/min/max/count d16" "select avg(a), min(a), max(a), count(a) from $U16;"
agree "avg/min/max d34"      "select avg(a), min(a), max(a) from $U34;"
agree "sum cast-df34 inner"  "select sum(a) from (select cast(d16 as decfloat(34)) a from t) q;"
agree "group by having"      "select a, sum(a) from $U16 group by a having count(*) > 1 order by a;"
echo "-- SUM/AVG start from a zero of EXPONENT 0 (engine cohort): a positive-exponent input pads --"
agree "2 x 9.99e15"          "select sum(a) from (select cast('9.99e15' as decfloat(16)) a from rdb\$database union all select cast('9.99e15' as decfloat(16)) from rdb\$database) q;"
agree "9.99e15 df16 4 aggs"  "select avg(x), min(x), max(x), sum(x) from (select cast('9.99e15' as decfloat(16)) x from rdb\$database) q;"
agree "9.99e16 df16 avg"     "select avg(x), sum(x) from (select cast('9.99e16' as decfloat(16)) x from rdb\$database union all select cast('1e16' as decfloat(16)) from rdb\$database) q;"
agree "3 x 1E+3 -> 3000"     "select sum(x), avg(x), min(x) from (select cast('1E+3' as decfloat(34)) x from rdb\$database union all select cast('1E+3' as decfloat(34)) from rdb\$database union all select cast('1E+3' as decfloat(34)) from rdb\$database) q;"
agree "1E+3 + -1E+3 -> 0"    "select sum(x), avg(x) from (select cast('1E+3' as decfloat(34)) x from rdb\$database union all select cast('-1E+3' as decfloat(34)) from rdb\$database) q;"
agree "0E+5 -> 0"            "select sum(x), avg(x) from (select cast('0E+5' as decfloat(34)) x from rdb\$database) q;"
agree "1E+400 pads to 34"    "select sum(x), avg(x) from (select cast('1E+400' as decfloat(34)) x from rdb\$database) q;"
agree "1.5 + 2E+2 mixed exp" "select sum(x), avg(x) from (select cast('1.5' as decfloat(16)) x from rdb\$database union all select cast('2E+2' as decfloat(16)) from rdb\$database) q;"
agree "windowed sum/avg pad" "select sum(x) over (), avg(x) over () from (select cast('9.99e15' as decfloat(16)) x from rdb\$database) q;"
agree "base-table sum cohort" "select sum(d16), avg(d34) from t;"
echo "-- CTE --"
agree "cte sum"              "with q as (select d16 a from t) select sum(a) from q;"
agree "cte where"            "with q as (select d16 a from t) select a from q where a > 2;"
agree "cte d34 avg"          "with q(a) as (select d34 from t) select avg(a) from q;"
echo "-- WHERE / ORDER BY / GROUP BY on the derived column --"
agree "where d16 > 2"        "select a from (select d16 a from t) q where a > 2;"
agree "where d34 > 3"        "select a from (select d34 a from t) q where a > 3;"
agree "where = 1.5"          "select a from (select d16 a from t) q where a = 1.5;"
agree "where is not null"    "select a from (select d16 a from t) q where a is not null;"
agree "order by desc"        "select a from (select d16 a from t) q order by a desc;"
agree "order by d34 asc"     "select a from (select d34 a from t) q order by a;"
agree "group by (values)"    "select a, count(*) from $U16 group by a order by a;"
agree "distinct"             "select distinct a from $U16 order by a;"
agree "count distinct"       "select count(distinct a) from (select d16 a from t) q;"
echo "-- expressions over the derived column --"
agree "d34 * 2"              "select a * 2 from (select d34 a from t) q;"
agree "d16 + 0"              "select a + 0 from (select d16 a from t) q;"
agree "-d16"                 "select -a from (select d16 a from t) q;"
agree "coalesce(d16,0)"      "select coalesce(a, 0) from (select d16 a from t) q;"
agree "d16 || ''"            "select a || '' from (select d16 a from t) q;"
agree "d34 || ''"            "select a || '' from (select d34 a from t) q;"
agree "cast varchar"         "select cast(a as varchar(20)) from (select d16 a from t) q;"
agree "inner d16*2, where"   "select a from (select d16 * 2 a from t) q where a > 4;"
agree "case when (in WHERE)" "select a from (select d16 a from t) q where case when a > 2 then 'hi' else 'lo' end = 'hi';"
echo "-- joins / subqueries --"
agree "join where q.a > 2"   "select q.a, t.id from (select id i, d16 a from t) q join t on t.id = q.i where q.a > 2;"
agree "derived join derived" "select q1.a from (select d16 a from t) q1 join (select d16 b from t) q2 on q1.a = q2.b order by 1;"
agree "exists"               "select q.a from (select d16 a from t) q where exists (select 1 from t where t.d16 = q.a);"
agree "in subquery (int)"    "select id from t where id in (select i from (select id i, d16 a from t) q where a > 2);"
agree "derived then union"   "select a from (select d16 a from t) q where a > 2 union all select 0 from rdb\$database;"
echo "-- edges --"
agree "1e300 U -7 <> 0"      "select * from (select cast('1e300' as decfloat(34)) a from rdb\$database union all select cast(-7 as decfloat(16)) from rdb\$database) q where a <> 0;"
agree "null U 2 is null"     "select a from (select cast(null as decfloat(16)) a from rdb\$database union all select 2 from rdb\$database) q where a is null;"
agree "lag default"          "select a, lag(a, 1, 0) over (order by id) from (select id, d16 a from t) q order by id;"
echo "-- views created on the engine --"
agree "v16 star"             "select * from v16 order by id;"
agree "v16 sum"              "select sum(a) from v16;"
agree "v16 where"            "select a from v16 where a > 2;"
agree "v34 * 2"              "select a * 2 from v34 order by id;"
agree "v34 max/min"          "select max(a), min(a) from v34;"
agree "v16 join t"           "select v16.a from v16 join t on t.id = v16.id where v16.a = 1.5;"
echo "-- UNION DISTINCT is a synonym of UNION --"
agree "top-level union distinct" "select 1 a from rdb\$database union distinct select 1 from rdb\$database;"
agree "derived union distinct"   "select * from (select id a from t union distinct select id from u) q order by a;"
agree "cte union distinct"       "with q as (select id a from t union distinct select id from u) select count(*), sum(a) from q;"
agree "union distinct d16"       "select a from (select d16 a from t union distinct select d16 from t) q order by a;"
echo "-- pre-existing boundaries, NOT derived-specific (the base-table form refuses too): recorded --"
refuses_fc "decfloat IN subquery"  "select id from t where d16 in (select d16 from t where d16 > 2);"
refuses_fc "HAVING over decfloat"  "select sum(d16) from t having sum(d16) > 1;"
echo "-- controls: other types through a derived table unchanged --"
agree "numeric(9,2) sum"     "select sum(a) from (select cast(id as numeric(9,2)) a from t union all select n from u) q;"
agree "double sum"           "select sum(a) from (select cast(id as double precision) a from t union all select n from u) q;"
agree "bigint sum"           "select sum(a) from (select cast(id as bigint) a from t union all select n from u) q;"
agree "int where"            "select q.a from (select id a from t union all select id from u) q where q.a > 1 order by 1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS derivedecfloat" || echo "FAIL derivedecfloat"
exit $fail
