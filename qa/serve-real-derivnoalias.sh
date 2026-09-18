#!/bin/bash
# AN UNNAMED DERIVED TABLE - `SELECT ID FROM (SELECT ID FROM T)`, with no
# alias after the closing paren.
#
# THE ENGINE ANSWERS IT; this server refused it in EVERY row-source
# position: alone, either side of a comma join, the right of a JOIN ... ON,
# two of them together, over a UNION, with ORDER BY inside, nested, and in
# the column-list form that names no table (`(SELECT ID FROM T) (A)`).
#
# WHY 445 GATES NEVER CAUGHT IT: `qa/serve-real-derived.sh` aliases ALL
# FOURTEEN of its derived tables. A suite can cover a feature thoroughly
# and still share one habit with the code it tests.
#
# FIVE SITES, not the one the name suggests - two parsers
# ([parse_table_ref], [parse_derived_table], both `canon_ident(rest)?`)
# and THREE that refused on a missing alias by themselves before either
# parser was consulted (`tr.alias.clone()?` twice, `tr.alias.as_deref()?`
# once). Widening a parser alone would have built clean and changed
# nothing - the same shape as the LikeExpr routing guard.
#
# THE NAME IS ABSENT, NOT INVENTED, and section 4 is what holds that
# line. On the engine an unnamed derived table is reachable ONLY
# unqualified: `X.ID` is -206 and so is the inner table's own `T.ID`,
# and the -204 for an ambiguity renders it with NO NAME AT ALL
# ("between derived table  and derived table"). So the empty name is
# the faithful one - and unlike a synthesised word it cannot shadow a
# real table that happens to be called that. (A real table named `PUN`
# beside an unnamed derived table answers fine on the engine; this
# server already synthesises that exact word elsewhere.)
#
# Usage: qa/serve-real-derivnoalias.sh [port]   (default 4371)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4371}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dnoalias-eng.fdb"; FC="$D/dnoalias-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/dnoalias-build.log 2>&1 <<'SQL'
-- two tables with a SHARED column name (ID), so the ambiguity cell in
-- section 4 can actually be ambiguous, and different row counts so a
-- cross join's 4 is distinguishable from either side's 2.
create table t (id int, c varchar(20));
create table u (id int, n int);
commit;
insert into t values (1,'apple');
insert into t values (2,'pear');
insert into u values (1,10);
insert into u values (2,20);
commit;
SQL
if grep -qi error /tmp/dnoalias-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dnoalias-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dnoalias.log 2>&1 &
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
sig() { local r
    r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
        | sed 's/  */ /g' | grep -aivE '^$|SQL>')
    if printf '%s' "$r" | grep -aqi 'failed\|malformed\|error'; then echo "REFUSE"
    else printf '%s' "$r" | grep -aiE '^(ID|A|CNT) ' | tr -d ' \n'; fi; }

agree() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = REFUSE ] && [ "$f" = REFUSE ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - a refusal cell belongs in section 4]"; fail=1
    elif [ -z "$e" ] && [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: both answered NOTHING - project ID/A or alias CNT]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# Both refuse, with DIFFERENT text, and that is the point: the engine's
# code is pinned so the cell goes red if the engine ever starts ANSWERING
# (which would make this server's refusal a wrong answer), while this
# server's own vector is allowed to differ and stays visible.
both_refuse() { # <label> <sql> <engine-message-fragment>
    ran=$((ran + 1))
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *"$3"*) ;; *) echo "FAIL $1: the ENGINE no longer refuses with '$3' [$e]"; fail=1; return;; esac
    case "$f" in *SQLSTATE*) echo "OK   both refuse (engine: $3): $1";;
                 *) echo "FAIL $1: THIS server ANSWERS [$f] - the name became referenceable"; fail=1;; esac
}

echo "-- 1. the fix: an UNNAMED derived table, in every row-source position --"
agree "alone, projection"          "select id from (select id from t) order by id;"
agree "alone, COUNT(*)"            "select count(*) as cnt from (select id from t);"
agree "comma join, derived FIRST"  "select count(*) as cnt from (select id from t), u;"
agree "comma join, derived SECOND" "select count(*) as cnt from u, (select id from t);"
agree "JOIN ... ON, derived RIGHT" "select count(*) as cnt from u join (select id from t) on 1=1;"
agree "two unnamed derived tables" "select count(*) as cnt from (select id from t), (select id from u);"
agree "over a UNION"               "select count(*) as cnt from (select id from t union select id from u);"
agree "ORDER BY inside"            "select count(*) as cnt from (select id from t order by id);"
agree "nested twice"               "select count(*) as cnt from (select id from (select id from t) x);"
agree "column list naming NO table" "select a from (select id from t) (a) order by a;"

echo "-- 2. CONTROLS: the three alias SPELLINGS must keep working --"
agree "bare alias X"               "select id from (select id from t) x order by id;"
agree "AS X"                       "select id from (select id from t) as x order by id;"
agree "column-list alias X(A)"     "select a from (select id from t) x(a) order by a;"

echo "-- 3. CONTROLS: unaliased subqueries that are NOT derived tables --"
# these already agreed BEFORE the fix; they mark where it must not reach
agree "IN (SELECT ...)"            "select count(*) as cnt from t where id in (select id from u);"
agree "EXISTS (SELECT ...)"        "select count(*) as cnt from t where exists (select 1 from u);"
agree "scalar subquery in SELECT"  "select (select count(*) from u) as cnt from rdb\$database;"
agree "CTE reference, no alias"    "with c as (select id from t) select count(*) as cnt from c;"

echo "-- 4. THE NAME IS ABSENT, NOT INVENTED: these must STILL refuse --"
both_refuse "X.ID over an unnamed derived table" \
    "select x.id from (select id from t);" "SQL error code = -206"
both_refuse "T.ID - the INNER table's own name" \
    "select t.id from (select id from t);" "SQL error code = -206"
both_refuse "ambiguous ID across two unnamed derived tables" \
    "select id from (select id from t), (select id from u);" "SQL error code = -204"

echo "-- 5. paths the fix made REACHABLE (they were dead code for this shape) --"
# parse_derived_table returned None for an unnamed derived table, so every
# site behind it was unreachable for it. Widening the parser LIT THEM UP -
# and a newly reachable path that answers where the engine refuses would be
# a wrong answer introduced by the fix, not found by it.
agree "WHERE over it"      "select id from (select id from t) where id > 1;"
agree "GROUP BY over it"   "select id from (select id from t) group by id order by id;"
agree "ORDER BY DESC"      "select id from (select id from t) order by id desc;"
agree "SELECT * over it"   "select * from (select id from t) order by id;"
agree "EXISTS, correlated" \
      "select id from t where exists (select 1 from (select id from u) where id = t.id);"
agree "IN over it"         "select id from t where id in (select id from (select id from u));"
agree "scalar subquery over it" \
      "select (select count(*) from (select id from u)) as cnt from rdb\$database;"

echo "-- 6. the RESERVED binding name must not become REFERENCEABLE --"
# The single-side path REBUILDS the statement text, so it cannot carry the
# empty name and binds under RDB$FC_UNNAMED_DERIVED instead. That name is
# NOT protected: a bare `CREATE TABLE RDB$FC_UNNAMED_DERIVED (ID INT)`
# SUCCEEDS on the engine (measured), and the word is a legal alias and
# qualifier. Binding under it unguarded would ANSWER the first cell below,
# which the engine refuses with -206 - so the planner refuses any statement
# that mentions the name at all. A refusal, never a wrong answer.
both_refuse "the reserved name used as a QUALIFIER" \
    "select rdb\$fc_unnamed_derived.id from (select id from t);" "SQL error code = -206"
agree "a real table actually ALIASED that way" \
    "select count(*) as cnt from (select id from t), u rdb\$fc_unnamed_derived;"
# projected AS CNT because `sig` greps ^(ID|A|CNT): a cell whose column
# name the signature does not match reads as TWO EMPTY ANSWERS, which is
# exactly what a match-nothing bug produces. The alias under test is the
# INNER one, so naming the outer projection changes nothing it measures.
agree "an ALIASED expression inside answers" \
    "select e as cnt from (select 1+1 as e from t);"
# and the UNNAMED one still refuses on BOTH - which is why it is a
# both_refuse cell and not an agree one: `agree` scores two refusals
# VACUOUS, and a vacuous cell is indistinguishable from a broken fixture
both_refuse "an UNNAMED expression inside still refuses" \
    "select * from (select 1+1 from t);" "SQL error code = -104"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN (31 on the fixing binary),
# never typed. It catches what a pass/fail tally cannot: cells SILENTLY
# DISAPPEARING - an early `exit`, a helper renamed, a section deleted -
# which otherwise reports a clean sweep over nothing.
if [ "$ran" -lt 31 ]; then
    echo "FAIL only $ran checks ran; 31 were measured - cells went missing"; fail=1
fi
# THE VERDICT MUST REACH THE CALLER - a gate ending on an `echo` exits 0
# with every cell failing.
exit $fail
