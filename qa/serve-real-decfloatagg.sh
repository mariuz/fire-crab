#!/bin/bash
# SUM / AVG / MIN / MAX over a DECFLOAT column match the engine, where
# fire-crab used to refuse every one of them at describe.
#
# A DECFLOAT column has no ExprType, so the aggregate describe (src_shape)
# hard-refused it and the SUM/AVG fold, keyed on numeric_parts / approx_of,
# silently skipped every decfloat value (an unfixed describe would have
# answered NULL). Now:
#   * SUM -> DECFLOAT(34) always (widens), accumulated in decimal (the
#     engine's DecimalContext, HALF-UP to 34 significant digits);
#   * AVG -> keeps the SOURCE width (DECFLOAT(16) -> 16, DECFLOAT(34) ->
#     34), the decimal sum divided by the non-NULL count and presented at
#     that width;
#   * MIN / MAX -> keep the source width and the winning value (the fold
#     already compared decfloat correctly);
#   * COUNT -> INT64, unchanged.
# NULL rows are skipped; an empty or all-NULL group is NULL. Held both
# ungrouped and grouped against the live engine.
#
# Out of scope, pre-existing and NOT decfloat-specific (refused for every
# type, so not tested here): SUM(DISTINCT)/AVG(DISTINCT), and a grouped
# aggregate with ORDER BY on the key.
#
# Usage: qa/serve-real-decfloatagg.sh [port]   (default 4163)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4163}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfagg-eng.fdb"; FC="$D/dfagg-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfagg-build.log 2>&1 <<'SQL'
create table t(g integer, d16 decfloat(16), d34 decfloat(34));
commit;
insert into t values (1, 1.5,  100.25);
insert into t values (1, 2.5,  200.50);
insert into t values (2, 10.1, 3.333333333333333333333333333333333);
insert into t values (2, null, null);
commit;
-- a table whose d16 average does not divide evenly (repeating), to hold
-- the round-to-16 of an AVG(DECFLOAT(16))
create table r(d16 decfloat(16), d34 decfloat(34));
commit;
insert into r values (1, 1);
insert into r values (2, 2);
insert into r values (4, 4);
commit;
SQL
if grep -qi error /tmp/dfagg-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfagg-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfagg.log 2>&1 &
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

echo "-- SUM -> DECFLOAT(34), value + describe --"
agree "sum(d16)" "select sum(d16) x from t;"
agree "sum(d34)" "select sum(d34) x from t;"
echo "-- AVG keeps source width --"
agree "avg(d16) -> DECFLOAT(16)" "select avg(d16) x from t;"
agree "avg(d34) -> DECFLOAT(34)" "select avg(d34) x from t;"
agree "avg(d16) repeating (7/3)" "select avg(d16) x from r;"
agree "avg(d34) repeating (7/3)" "select avg(d34) x from r;"
echo "-- MIN / MAX keep source width and value --"
agree "min(d16)" "select min(d16) x from t;"
agree "max(d16)" "select max(d16) x from t;"
agree "min(d34)" "select min(d34) x from t;"
agree "max(d34)" "select max(d34) x from t;"
echo "-- COUNT is INT64 (unchanged) --"
agree "count(d16)" "select count(d16) x from t;"
agree "count(*)"   "select count(*) x from t;"
echo "-- grouped (no ORDER BY): key + fold --"
agree "g, sum(d16)" "select g, sum(d16) x from t group by g;"
agree "g, avg(d16)" "select g, avg(d16) x from t group by g;"
agree "g, avg(d34)" "select g, avg(d34) x from t group by g;"
agree "g, min(d16)" "select g, min(d16) x from t group by g;"
agree "g, max(d34)" "select g, max(d34) x from t group by g;"
agree "g, count(d16)" "select g, count(d16) x from t group by g;"
echo "-- edges: empty group, all-NULL group --"
agree "sum over no rows" "select sum(d16) x from t where g=99;"
agree "avg over all-null" "select avg(d16) x from t where d16 is null;"
agree "min over no rows"  "select min(d34) x from t where g=99;"
echo "-- an expression that folds a decfloat aggregate --"
agree "sum(d16)+decfloat lit" "select sum(d16)+cast(1 as decfloat(34)) x from t;"
agree "sum(d34)*2"            "select sum(d34)*cast(2 as decfloat(34)) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloatagg" || echo "FAIL decfloatagg"
exit $fail
