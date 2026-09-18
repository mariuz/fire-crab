#!/bin/bash
# A `HAVING` TERM WHOSE RIGHT SIDE IS AN EXPRESSION.
#
# Measured on c0fe691: SIXTEEN shapes refused while the engine answered
# every one, and none was a wrong answer. The boundary was one sentence -
# in HAVING the right side had to be a LITERAL - and it was wider than the
# pattern families: `MAX(N) = MAX(ID)`, `MAX(N) > MAX(ID) - 1`,
# `MAX(U) = V` and `U = V` refused too, while every working form
# (`COUNT(*) >= 1`, `MAX(U) LIKE 'caf%'`, `MAX(U) = 'cafe'`,
# `MAX(N) * 2 > 2`, `MAX(U) IS NULL`) had a literal on the right.
#
# THE ROOT CAUSE WAS SINGLE: [resolve_having] folded aggregates from
# `rt.lhs` ONLY, so an aggregate or a column on the RIGHT was never lifted
# into a group slot - which is why even its own `(RawLhs::Agg,
# RawKind::CmpExpr)` special case still refused `MAX(N) = MAX(ID)`.
#
# THIS IS THE THIRD ROUTING SITE. Chunks 37/38 widened
# [resolve_predicate]'s two guards and chunk 39 [resolve_raw_cond]'s;
# `HAVING` has its own resolver over a SYNTHETIC GROUP-ROW VIEW, which is
# why the capability did not reach it. The lesson recorded with it: when a
# capability must be "routed", COUNT THE ROUTERS before believing a count.
#
# THE SAFE FAILURE MATTERS HERE. A column that is not a group key is
# simply ABSENT from the synthetic view, so such a term REFUSES rather
# than resolving against a wrong slot - the hazard that kept this out of
# the value-world chunk.
#
# Usage: qa/serve-real-havingexpr.sh [port]   (default 4364)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4364}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/havexpr-eng.fdb"; FC="$D/havexpr-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/havexpr-build.log 2>&1 <<'SQL'
create table t (id int, u varchar(20), v varchar(20),
                sub varchar(20), pre varchar(20), n int);
commit;
insert into t values (1,'cafe','caf%','af','ca',1);
insert into t values (2,'apple','app%','pp','ap',2);
insert into t values (3,'banana','xyz%','zz','xy',3);
insert into t values (4,NULL,'any%','x','x',4);
commit;
SQL
if grep -qi error /tmp/havexpr-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/havexpr-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-havingexpr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# every cell aliases its projected column as N or ID - a HAVING cell
# projects COUNT(*), and without the alias the row filter matches nothing
# and two empty strings compare equal, passing whatever the server did
sig() { local ch=""; [ -n "${3:-}" ] && ch="-ch $3"; local r
    r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 \
        | sed 's/  */ /g' | grep -aivE '^$|SQL>')
    if printf '%s' "$r" | grep -aqi 'failed\|malformed\|error'; then echo "REFUSE"
    else printf '%s' "$r" | grep -aiE '^(N|ID) ' | tr -d ' \n'; fi; }

agree() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = REFUSE ] && [ "$f" = REFUSE ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - this cell measures nothing]"; fail=1
    elif [ -z "$e" ] && [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: both answered NOTHING - alias the column as N or ID]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

gap() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = REFUSE ] || [ -z "$e" ]; then
        echo "FAIL $1 [VACUOUS: the ENGINE did not answer either: $e]"; fail=1
    elif [ "$f" = REFUSE ]; then echo "OK   refused (engine answers $e): $1"
    else echo "FAIL $1 now ANSWERS [$f] - the gap is closed; promote this cell to agree"; fail=1
    fi
}

echo "-- 1. the LITERAL right side must not move --"
agree "HAVING COUNT(*) >= 1"        "select count(*) as n from t group by u having count(*) >= 1;"
agree "HAVING MAX(u) LIKE 'caf%'"   "select count(*) as n from t group by u having max(u) like 'caf%';"
agree "HAVING MAX(u) = 'cafe'"      "select count(*) as n from t group by u having max(u) = 'cafe';"
agree "HAVING MAX(n) * 2 > 2"       "select count(*) as n from t group by u having max(n) * 2 > 2;"
agree "HAVING MAX(u) IS NULL"       "select count(*) as n from t group by u having max(u) is null;"
agree "HAVING MAX(u) CONTAINING 'af'" "select count(*) as n from t group by u having max(u) containing 'af';"
agree "HAVING MAX(u) STARTING WITH 'ca'" "select count(*) as n from t group by u having max(u) starting with 'ca';"

echo "-- 2. the four families with an EXPRESSION pattern --"
agree "HAVING u LIKE v (group keys, no agg)" \
      "select count(*) as n from t group by u, v having u like v;"
agree "HAVING u CONTAINING sub"     "select count(*) as n from t group by u, sub having u containing sub;"
agree "HAVING u STARTING WITH pre"  "select count(*) as n from t group by u, pre having u starting with pre;"
agree "HAVING u NOT LIKE v"         "select count(*) as n from t group by u, v having u not like v;"
agree "HAVING MAX(u) LIKE MAX(v)"   "select count(*) as n from t group by u having max(u) like max(v);"
agree "HAVING MAX(u) LIKE v"        "select count(*) as n from t group by u, v having max(u) like v;"
agree "HAVING u LIKE MAX(v)"        "select count(*) as n from t group by u having u like max(v);"
agree "HAVING MAX(u) LIKE MAX(v) ESCAPE" \
      "select count(*) as n from t group by u having max(u) like max(v) escape '!';"
agree "HAVING u LIKE v || ''"       "select count(*) as n from t group by u, v having u like v || '';"
agree "HAVING NOT (u LIKE v)"       "select count(*) as n from t group by u, v having not (u like v);"

echo "-- 3. COMPARISONS with an expression right side - the wider half --"
agree "HAVING MAX(n) = MAX(id)"     "select count(*) as n from t group by u having max(n) = max(id);"
agree "HAVING MAX(n) > MAX(id) - 1" "select count(*) as n from t group by u having max(n) > max(id) - 1;"
# ALWAYS TRUE, on purpose: `max(u) = max(v)` matches no group in this
# fixture, so both sides answered NOTHING and the cell compared two
# emptinesses - which my own vacuity guard caught. This form still runs an
# aggregate against an aggregate on the right and returns rows.
agree "HAVING MAX(u) = MAX(u)"      "select count(*) as n from t group by u having max(u) = max(u);"
# FORMS THAT RETURN ROWS. `max(u) = v` and `u = v` match nothing in this
# fixture, so both sides answered NOTHING - an agreement that a
# match-nothing bug would also produce. These keep the same two paths (an
# AGGREGATE against a group KEY, and a group key against an EXPRESSION on
# the right) while actually selecting groups.
agree "HAVING MAX(u) = u (aggregate vs group key)" \
      "select count(*) as n from t group by u, v having max(u) = u;"
agree "HAVING u = u || '' (group key vs expression)" \
      "select count(*) as n from t group by u, v having u = u || '';"
# likewise: n = id in every row, so `<>` matched nothing. `- 1` makes it
# always true while keeping an ARITHMETIC expression on the right.
agree "HAVING MAX(n) <> MAX(id) - 1" "select count(*) as n from t group by u having max(n) <> max(id) - 1;"

echo "-- 4. closed by the SIMILAR TO expression-pattern chunk (serve-real-simexpr) --"
# recorded here as its own slice; that slice landed the same day and
# this cell was promoted when the fourth-router sweep found it expired
agree "HAVING u SIMILAR TO v" \
    "select count(*) as n from t group by u, v having u similar to v;"

echo "-- 5. the other worlds must not move (chunks 37, 38, 39) --"
agree "WHERE u LIKE v"              "select count(*) as n from t where u like v;"
agree "WHERE u CONTAINING sub"      "select count(*) as n from t where u containing sub;"
agree "SELECT u LIKE v (value world)" "select (u like v) as n from t order by id;"
agree "SELECT CASE WHEN u CONTAINING sub" \
      "select (case when u containing sub then 1 else 0 end) as n from t order by id;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
# THE COUNTED FLOOR, derived from a measured run (28) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 28 ]; then
    echo "FAIL only $ran checks ran - the floor is 28; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# THE VERDICT MUST REACH THE CALLER - a gate that ends on an `echo` exits 0
# with every cell failing, which is how the first of these gates reported
# success through three runs.
exit $fail
