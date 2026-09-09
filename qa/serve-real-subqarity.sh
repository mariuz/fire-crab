#!/bin/bash
# A SUBQUERY OPERAND MUST MATCH ITS COMPARISON'S DEGREE.
#
# A subquery used as a SCALAR operand, an IN / NOT IN right side, or a
# quantified (ANY/ALL/SOME) operand must project exactly ONE column; the
# engine raises SQLSTATE 07002 / -104 "count of column list and variable
# list do not match" at prepare, independent of cardinality. fire-crab
# folded the multi-column inner away and then took column 1, silently
# answering a WRONG ROWSET (`WHERE a = (SELECT x, x*10 FROM t2)` returned
# the a=1 row). Fixed at corr_describe with a scalar_arity gate: a
# scalar/IN/quantified operand of degree != 1 refuses. EXISTS is exempt
# (it ignores its projection), and a single-column operand is unchanged.
#
# A "raise" row asserts BOTH the engine errors AND fire-crab returns no
# rows (refuses) - the law is match-or-refuse, never the wrong rowset.
#
# Usage: qa/serve-real-subqarity.sh [port]   (default 4153)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4153}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/subqarity.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/subqarity-build.log 2>&1 <<'SQL'
create table t (a int, b int); create table t2 (x int);
commit;
insert into t values (1,10);insert into t values (2,20);insert into t values (3,30);
insert into t2 values (1);
commit;
SQL
if grep -qi error /tmp/subqarity-build.log; then echo "FAIL fixture:"; sed 's/^/  /' /tmp/subqarity-build.log; exit 1; fi
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-subqarity.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "ERR"; else printf '%s' "$r" | grep -iE '^(A|S) ' | tr '\n' ',' | sed 's/ //g'; fi; }
refuse() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    { [ "$e" = "ERR" ] && [ "$f" = "ERR" ]; } && echo "OK   refuse $1" || { echo "FAIL refuse $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
echo "-- degree mismatch: engine raises 07002, fc must refuse (not answer col 1) --"
refuse "= (SELECT x,x*10)"     "select a from t where a=(select x,x*10 from t2);"
refuse "IN (SELECT a,b)"       "select a from t where a in (select a,b from t);"
refuse "= (SELECT a,b,a+b)"    "select a from t where a=(select a,b,a+b from t);"
refuse "SELECT-list (SELECT x,x*10)" "select a,(select x,x*10 from t2) s from t;"
refuse "NOT IN (SELECT x,x*10)" "select a from t where a not in (select x,x*10 from t2);"
echo "-- accepted shapes: must NOT refuse --"
agree "EXISTS(SELECT a,b)"     "select a from t where exists(select a,b from t) order by a;"
agree "= (SELECT x) 1col"      "select a from t where a=(select x from t2);"
agree "IN (SELECT x) 1col"     "select a from t where a in (select x from t2) order by a;"
agree "SELECT-list (SELECT x) 1col" "select a,(select x from t2) s from t order by a;"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS subqarity" || echo "FAIL subqarity"
exit $fail
