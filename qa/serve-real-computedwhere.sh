#!/bin/bash
# A COMPUTED BY COLUMN IS ITS EXPRESSION IN A WHERE FILTER (AND IN A
# SELECT-LIST EXPRESSION), NOT A REFUSAL.
#
# A computed column has no stored bytes, so fire-crab expanded it only
# in the BARE select list and refused (SQLSTATE 42000) everywhere else -
# `WHERE c1 > 5`, `c1 IN (...)`, `c1 BETWEEN`, `c1 + 1`, a computed over
# a computed - where the engine substitutes the defining expression and
# answers. The single-table planner now arms the relation's parsed
# COMPUTED BY expressions so resolve_expr expands a computed reference in
# place: the WHERE predicate takes the per-row expression path, and a
# select-list expression over a computed column resolves too. The value
# is cast to the column's DECLARED type (the engine's blr_cast), so the
# rowset and the described type match.
#
# STILL REFUSED, by design (separate by-field-id resolution paths that
# read record bytes; a refusal is law-safe, never a wrong value): a
# computed column as an AGGREGATE source (SUM/MAX/AVG), an ORDER BY key,
# or a GROUP BY key; and computed references across a JOIN / derived
# table. Those are recorded follow-ons. Held against the live engine.
#
# Usage: qa/serve-real-computedwhere.sh [port]   (default 4154)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4154}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/computedwhere-eng.fdb"; FC="$D/computedwhere-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/computedwhere-build.log 2>&1 <<'SQL'
create table t(a int, b int, s varchar(10),
  c1 computed by (a+b),
  c2 computed by (a*2),
  c3 computed by (s||'!'),
  c4 computed by (case when a>b then a else b end),
  c5 computed by (c1+c2));
commit;
insert into t values (1,2,'x'); insert into t values (3,5,'y'); insert into t values (6,5,'z');
insert into t values (7,4,'q'); insert into t values (null,5,'n'); insert into t values (7,null,'m');
commit;
SQL
if grep -qi error /tmp/computedwhere-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/computedwhere-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-computedwhere.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { local r; r=$(printf 'set list on;\nset sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -viE '^$|SQL>|Database:'); \
    if printf '%s' "$r" | grep -qiE 'SQLSTATE|error|failed'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^01: sqltype|^[A-Z0-9_]+ +[0-9x!a-z-]' | sed 's/  */ /g' | tr '\n' ','; fi; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
refuses() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" != "REFUSE" ] && [ "$f" = "REFUSE" ]; then echo "OK   defer-refuse: $1 (eng answers)"; \
    else echo "FAIL defer: $1 eng=[$e] fc=[$f]"; fail=1; fi; }

echo "-- the fix: a computed column in a WHERE filter --"
agree "WHERE c1>5"          "select a,b from t where c1>5 order by a;"
agree "WHERE c1=a+b"        "select a from t where c1=a+b order by a;"
agree "WHERE c1 IN (3,8)"   "select a from t where c1 in (3,8) order by a;"
agree "WHERE c1 BETWEEN 2,9" "select a from t where c1 between 2 and 9 order by a;"
agree "WHERE c3 concat"     "select s from t where c3='x!';"
agree "WHERE c4 case"       "select a,b from t where c4=7 order by a;"
agree "WHERE c5 comp-over-comp" "select a from t where c5>10 order by a;"
agree "WHERE c1 IS NULL"    "select a from t where c1 is null order by b;"
agree "WHERE c1>5 AND a<7"  "select a from t where c1>5 and a<7 order by a;"
agree "WHERE c2 (a*2) > 10" "select a from t where c2>10 order by a;"
echo "-- select-list expression over a computed column --"
agree "c1+1 (type + value)" "select c1+1 x from t where c1 is not null order by a;"
agree "c1*c2 describe"      "select c1*c2 x from t where 1=0;"
echo "-- regression: the bare projection and its describe are unchanged --"
agree "bare c1..c5 describe" "select c1,c2,c3,c4,c5 from t where 1=0;"
agree "bare c1 rows"        "select c1 from t order by a;"
agree "bare c3 text rows"   "select c3 from t order by s;"
echo "-- deferred contexts still REFUSE (law-safe, recorded follow-on) --"
refuses "SUM(c1) aggregate"  "select sum(c1) s from t;"
refuses "MAX(c1) aggregate"  "select max(c1) m from t;"
refuses "ORDER BY c1 (not in list)" "select a from t order by c1;"
refuses "GROUP BY c1"        "select c1, count(*) n from t group by c1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS computedwhere" || echo "FAIL computedwhere"
exit $fail
