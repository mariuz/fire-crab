#!/bin/bash
# A PATTERN PREDICATE USED AS A VALUE, with an EXPRESSION pattern.
# `SELECT U LIKE V`, `CASE WHEN U CONTAINING SUB THEN ..`,
# `IIF(U STARTING WITH PRE, ..)`, `(U LIKE V) = TRUE`, `ORDER BY (U LIKE
# V)`, `HAVING MAX(U) LIKE MAX(V)`.
#
# Every predicate in Firebird is also a BOOLEAN value, and this server had
# two grammars for them: the PREDICATE world (`Term`, per-row) and the
# VALUE world (`RawCond` -> `Cond2`). The expression pattern landed in the
# first and not the second, so `WHERE <x> LIKE V` answered while
# `SELECT <x> LIKE V` refused - an asymmetry this server created, measured
# at 9 of 9 shapes refusing with no wrong answers.
#
# THE TWO WORLDS PARSE DIFFERENTLY, which is why this is its own slice and
# not a copy: the predicate world runs on TOKENS ([parse_leaf], `Tok::`),
# while this one is a CHARACTER-level recursive-descent parser
# ([parse_raw_cond] over `&[char]`), whose pattern positions read a quoted
# literal only ([read_quoted]). The fallback here is [expr_add] - the same
# entry point the LEFT side uses, which reaches [expr_concat] and so takes
# `V || '%'`.
#
# SIMILAR TO is deliberately OUT OF SCOPE, exactly as in the predicate
# world: its pattern is a compiled `SimRe`, so a per-row pattern means
# `sim_compile` PER ROW - a cost to measure in its own slice.
#
# Usage: qa/serve-real-exprvalue.sh [port]   (default 4363)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4363}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/exprval-eng.fdb"; FC="$D/exprval-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/exprval-build.log 2>&1 <<'SQL'
-- row 4 has a NULL value, for the 3VL cells; N/SUBN are byte carriers so
-- the carrier/real mix has somewhere to be measured.
create table t (id int,
  u varchar(20) character set utf8,
  v varchar(20) character set utf8,
  sub varchar(20) character set utf8,
  pre varchar(20) character set utf8,
  n varchar(20) character set none,
  subn varchar(20) character set none);
commit;
insert into t values (1,'cafe','caf%','af','ca','cafe','af');
insert into t values (2,'apple','app%','pp','ap','apple','pp');
insert into t values (3,'banana','xyz%','zz','xy','banana','zz');
insert into t values (4,NULL,'any%','x','x',NULL,'x');
commit;
SQL
if grep -qi error /tmp/exprval-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/exprval-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exprvalue.log 2>&1 &
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
# EVERY CELL ALIASES ITS PROJECTED COLUMN AS N OR ID. A value-world cell
# projects a BOOLEAN (`<true>`/`<false>`/`<null>`), and without the alias
# the row filter below would match nothing and every cell would compare
# two empty strings - passing whatever the server did.
sig() { local ch=""; [ -n "${3:-}" ] && ch="-ch $3"; local r
    r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 \
        | sed 's/  */ /g' | grep -aivE '^$|SQL>')
    if printf '%s' "$r" | grep -aqi 'failed\|malformed\|error'; then echo "REFUSE"
    else printf '%s' "$r" | grep -aiE '^(N|ID) ' | tr -d ' \n'; fi; }

agree() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" "$2" "${3:-}")
    if [ "$e" = REFUSE ] && [ "$f" = REFUSE ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - this cell measures nothing]"; fail=1
    elif [ -z "$e" ] && [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: both answered NOTHING - alias the column as N or ID]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# the engine ANSWERS and this server REFUSES - a recorded gap, red the day
# it closes, which is the signal to promote it rather than delete it.
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

echo "-- 1. the value world, three families --"
agree "SELECT u LIKE v"            "select (u like v) as n from t order by id;"
agree "SELECT u NOT LIKE v"        "select (u not like v) as n from t order by id;"
agree "SELECT u CONTAINING sub"    "select (u containing sub) as n from t order by id;"
agree "SELECT u STARTING WITH pre" "select (u starting with pre) as n from t order by id;"
agree "SELECT u LIKE v || ''"      "select (u like v || '') as n from t order by id;"
agree "SELECT u LIKE TRIM(v)"      "select (u like trim(v)) as n from t order by id;"

echo "-- 2. wrapped in the shapes a boolean value appears in --"
agree "CASE WHEN u LIKE v"         "select (case when u like v then 1 else 0 end) as n from t order by id;"
agree "CASE WHEN u CONTAINING sub" "select (case when u containing sub then 1 else 0 end) as n from t order by id;"
agree "IIF(u STARTING WITH pre)"   "select iif(u starting with pre,1,0) as n from t order by id;"
agree "COALESCE over a predicate"  "select coalesce(case when u like v then 1 end,9) as n from t order by id;"

echo "-- 3. and where a value-world predicate is CONSUMED --"
agree "WHERE (u LIKE v) = TRUE"    "select count(*) as n from t where (u like v) = true;"
agree "WHERE (u CONTAINING sub)=TRUE" "select count(*) as n from t where (u containing sub) = true;"
agree "ORDER BY (u LIKE v)"        "select id from t order by (u like v), id;"
# A MEASURED GAP, AND NOT THE ONE THE LABEL FIRST SUGGESTED. `HAVING` has
# its OWN resolver ([resolve_having], which takes `Vec<Vec<RawTerm>>` and
# resolves against a synthetic group-row view), so it is a THIRD routing
# site that the expression patterns of chunks 37, 38 and 39 never reach.
# Measured: `HAVING MAX(U) LIKE 'caf%'` ANSWERS - the literal form is fine -
# while `HAVING U LIKE V` refuses with NO aggregate anywhere in it. So the
# boundary is the expression pattern, not the aggregate, and the second
# cell below states that in its sharpest form.
gap "HAVING MAX(u) LIKE MAX(v)"    "select count(*) as n from t group by u having max(u) like max(v);"
gap "HAVING u LIKE v (no aggregate at all - the sharp form)" \
    "select count(*) as n from t group by u, v having u like v;"
# the LITERAL pattern in HAVING answers and must keep answering - it is
# what proves the gap above is the EXPRESSION pattern and nothing wider
agree "HAVING MAX(u) LIKE 'caf%' (literal, answers)" \
      "select count(*) as n from t group by u having max(u) like 'caf%';"

# AN AGGREGATE IN THE PATTERN, in the VALUE world - the cells that prove
# [walk_cond_aggs] and [substitute_cond_aggs] walk BOTH sides. If either
# missed the pattern, MAX(v) would never be lifted into a grouping slot
# and these go red. Without them the both-sides walk would be justified
# only by a comment, and could be reverted with every cell still green.
agree "SELECT CASE WHEN MAX(u) LIKE MAX(v) GROUP BY u" \
      "select (case when max(u) like max(v) then 1 else 0 end) as n from t group by u order by 1;"
agree "SELECT (MAX(u) LIKE MAX(v)) GROUP BY u" \
      "select (max(u) like max(v)) as n from t group by u order by 1;"
agree "SELECT CASE WHEN MAX(u) CONTAINING MAX(sub) GROUP BY u" \
      "select (case when max(u) containing max(sub) then 1 else 0 end) as n from t group by u order by 1;"

echo "-- 4. NULL on either side is UNKNOWN, never a raise --"
agree "row 4 NULL value, SELECT"   "select (u like v) as n from t where id = 4;"
agree "row 4 NULL value, CASE"     "select (case when u like v then 1 else 0 end) as n from t where id = 4;"
agree "count of UNKNOWN rows"      "select count(*) as n from t where (u like v) = true;"

echo "-- 5. NO TRANSCODE: the same statement under all three attachments --"
agree "SELECT u LIKE v @NONE"      "select (u like v) as n from t order by id;" NONE
agree "SELECT u LIKE v @WIN1252"   "select (u like v) as n from t order by id;" WIN1252
agree "SELECT u LIKE v @UTF8"      "select (u like v) as n from t order by id;" UTF8

echo "-- 6. the LITERAL forms in the value world must not move --"
agree "SELECT u LIKE 'caf%'"       "select (u like 'caf%') as n from t order by id;"
agree "SELECT u CONTAINING 'af'"   "select (u containing 'af') as n from t order by id;"
agree "SELECT u STARTING WITH 'ca'" "select (u starting with 'ca') as n from t order by id;"
agree "SELECT u SIMILAR TO 'caf%'" "select (u similar to 'caf%') as n from t order by id;"
agree "SELECT u LIKE 'caf!%' ESCAPE" "select (u like 'caf!%' escape '!') as n from t order by id;"

echo "-- 7. the PREDICATE world must not move (chunks 37 and 38) --"
agree "WHERE u LIKE v"             "select count(*) as n from t where u like v;"
agree "WHERE u CONTAINING sub"     "select count(*) as n from t where u containing sub;"
agree "WHERE u STARTING WITH pre"  "select count(*) as n from t where u starting with pre;"
agree "WHERE u LIKE 'caf%'"        "select count(*) as n from t where u like 'caf%';"

echo "-- 8. still refused, deliberately or pre-existing --"
gap "SELECT u SIMILAR TO v (sim_compile per row - own slice)" \
    "select (u similar to v) as n from t order by id;"
gap "carrier mix: SELECT n LIKE v"      "select (n like v) as n from t order by id;"
gap "carrier mix: SELECT u CONTAINING subn" "select (u containing subn) as n from t order by id;"
gap "IS UNKNOWN over a predicate (pre-existing)" \
    "select count(*) as n from t where (u like v) is unknown;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
# THE COUNTED FLOOR, derived from a measured run (38) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 38 ]; then
    echo "FAIL only $ran checks ran - the floor is 38; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# THE VERDICT MUST REACH THE CALLER - the LIKE gate ended on an `echo` and
# reported exit 0 through three runs with 24 cells failing.
exit $fail
