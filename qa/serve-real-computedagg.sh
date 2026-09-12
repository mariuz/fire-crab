#!/bin/bash
# A COMPUTED BY COLUMN WORKS AS AN AGGREGATE SOURCE, AN ORDER BY KEY, AND
# A GROUP BY KEY - completing the computed-column expansion (WHERE and
# select-list expressions were the previous chunk).
#
# A computed column has no stored bytes, so fire-crab refused (SQLSTATE
# 42000) SUM/AVG/MIN/MAX/COUNT over one, ORDER BY one, and GROUP BY one,
# where the engine folds/sorts/buckets by the defining expression. Each
# of those paths resolves a column by field id; they now route a
# computed column to its expression (resolve_expr expands it via the
# armed COMPUTED_EXPR, cast to the declared type), reusing the proven
# expression machinery: the aggregate demotes to an Expr source (fold
# and describe), the ORDER BY key falls back to an expression key, and
# the GROUP BY key becomes an expression key matched by its normalized
# column reference. So SUM(c1) widens to INT128, AVG truncates, a
# NUMERIC computed keeps its scale, a computed-over-computed expands
# transitively, and NULL propagates - all matching the engine's value
# and described type.
#
# NOTE (pre-existing, not this chunk): MIN/MAX over a TEXT expression -
# whether MAX(s||'!') or MAX(<text computed>) - announces VARCHAR(32765)
# where the engine announces the expression's real width; the VALUE is
# correct. Gated on value here; the describe width is a separate
# text-expression-aggregate follow-on.
#
# Usage: qa/serve-real-computedagg.sh [port]   (default 4155)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4155}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/computedagg-eng.fdb"; FC="$D/computedagg-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/computedagg-build.log 2>&1 <<'SQL'
create table t(a int, b int, s varchar(10),
  c1 computed by (a+b), c2 computed by (a*2), cd computed by (a/2.0),
  c3 computed by (s||'!'), c5 computed by (c1+c2));
commit;
insert into t values (1,2,'x'); insert into t values (3,4,'y'); insert into t values (5,6,'z');
insert into t values (3,10,'q'); insert into t values (null,7,'n');
commit;
SQL
if grep -qi error /tmp/computedagg-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/computedagg-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-computedagg.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# value + full SQLDA
sigT() { printf 'set list on;\nset sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^[A-Z0-9_]+ +[0-9.x!a-z-]|SQLSTATE' | sed 's/  */ /g' | tr '\n' ','; }
# value only (for the text-aggregate width caveat)
sigV() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^[A-Z0-9_]+ +[0-9.x!a-z-]|SQLSTATE' | sed 's/  */ /g' | tr '\n' ','; }
agree() { local e f; e=$(sigT "127.0.0.1/3050:$ENG" "$2"); f=$(sigT "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
agreeV() { local e f; e=$(sigV "127.0.0.1/3050:$ENG" "$2"); f=$(sigV "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1 (value)"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- aggregate over a computed column (value + described type) --"
agree "SUM(c1) -> INT128"   "select sum(c1) x from t;"
agree "AVG(c1) trunc"       "select avg(c1) x from t;"
agree "MIN(c1)"             "select min(c1) x from t;"
agree "MAX(c1)"             "select max(c1) x from t;"
agree "COUNT(c1)"           "select count(c1) x from t;"
agree "SUM(cd) numeric scale" "select sum(cd) x from t;"
agree "AVG(cd) numeric"     "select avg(cd) x from t;"
agree "SUM(c5) comp-over-comp" "select sum(c5) x from t;"
agree "COUNT(DISTINCT c1)"  "select count(distinct c1) x from t;"
agreeV "MAX(c3) text (value)" "select max(c3) x from t;"
agreeV "MIN(c3) text (value)" "select min(c3) x from t;"
echo "-- GROUP BY a computed column (value + describe) --"
agree "GROUP BY c1 + count" "select c1, count(*) n from t group by c1 order by 1;"
agree "GROUP BY c1 + sum(b)" "select c1, sum(b) sb from t group by c1 order by 1;"
agree "GROUP BY c2"         "select c2, count(*) n from t group by c2 order by 1;"
agree "GROUP BY cd numeric" "select cd, count(*) n from t group by cd order by 1;"
agree "GROUP BY c3 text"    "select c3, count(*) n from t group by c3 order by 1;"
agree "GROUP BY c5 comp/comp" "select c5, count(*) n from t group by c5 order by 1;"
agree "GROUP BY c1 HAVING sum(b)" "select c1 from t group by c1 having sum(b)>5 order by 1;"
echo "-- ORDER BY a computed column not in the select list --"
agree "ORDER BY c1"         "select a from t order by c1;"
agree "ORDER BY c1 DESC"    "select a from t order by c1 desc;"
agree "ORDER BY c1 NULLS FIRST" "select a from t order by c1 nulls first;"
agree "ORDER BY cd numeric" "select a from t order by cd;"
agree "ORDER BY c5"         "select a from t order by c5;"
agree "ORDER BY c3 text"    "select a from t order by c3;"
agree "ORDER BY c1, b"      "select a,b from t order by c1, b;"
echo "-- regression: stored-column agg/order/group, expression forms, prior WHERE chunk --"
agree "SUM(a)/MAX(b) stored" "select sum(a) s, max(b) m from t;"
agree "GROUP BY a stored"   "select a, count(*) n from t group by a order by 1;"
agree "ORDER BY a stored"   "select a from t order by a nulls first;"
agree "SUM(a+b) expr"       "select sum(a+b) x from t;"
agree "GROUP BY a+b expr"   "select a+b k, count(*) n from t group by a+b order by 1;"
agree "ORDER BY a+b expr"   "select a from t order by a+b;"
agree "WHERE c1>5 (prior chunk)" "select a from t where c1>5 order by a;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS computedagg" || echo "FAIL computedagg"
exit $fail
