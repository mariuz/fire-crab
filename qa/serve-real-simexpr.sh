#!/bin/bash
# `SIMILAR TO` WITH AN EXPRESSION PATTERN, in all three worlds - the last
# of the four pattern families.
#
# It was deferred three times as "the expensive corner", on the belief
# that its pattern is a compiled REGEX and a per-row pattern would mean
# compiling one per row. READING [sim_compile] refuted that: it is an
# eight-line recursive-descent parse into a small `SimRe` enum tree
# (Lit/Any/AnySeq/Class/Concat/Alt/Repeat), no regex engine, and both
# `SimRe` and `SimClass` derive Clone. A per-row compile is a cheap tree
# build, no dearer than the rebuild `containing_term`'s per-row form has
# been doing since the CONTAINING slice. THE DEFERRAL WAS AN ASSUMPTION,
# repeated in three chunk records before anyone read the function.
#
# Measured on 979c144: thirteen shapes refused while the engine answered
# all of them, and none was a wrong answer.
#
# THE SHARP CASE IS A MALFORMED PATTERN ARRIVING PER ROW. A literal `[`
# refuses at PREPARE on both servers. A row-dependent one cannot, and the
# engine's rule is VALUE-GATED: it raises 42000 for a row whose pattern is
# `[`, and ANSWERS 2 when a prior conjunct excludes that row. So this
# raises at EVALUATION (`EvalErr::InvalidSimilar`, the error
# `Term::BadSimilar` already uses) and never refuses at prepare - refusing
# would be a wrong answer for the filtered query.
#
# Usage: qa/serve-real-simexpr.sh [port]   (default 4365)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4365}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/simexpr-eng.fdb"; FC="$D/simexpr-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/simexpr-build.log 2>&1 <<'SQL'
-- row 5 carries a MALFORMED pattern, on purpose: it is the only way to
-- reach a per-row compile failure. Row 4 is the NULL 3VL row.
-- THIS DATABASE HAS NO DEFAULT CHARSET, so `u`, `v` and `sub` are all
-- NONE byte carriers - and so is `n`. A cell pairing `n` with `v` is
-- therefore carrier-vs-CARRIER, the pairing that legitimately ANSWERS,
-- not the carrier/real mix its label first claimed. `vu` is declared UTF8
-- explicitly so there is a REAL-charset pattern to mix against.
create table t (id int, u varchar(20), v varchar(20), sub varchar(20),
                n varchar(20) character set none,
                vu varchar(20) character set utf8);
commit;
insert into t values (1,'cafe','caf%','af','cafe','caf%');
insert into t values (2,'apple','app%','pp','apple','app%');
insert into t values (3,'banana','xyz%','zz','banana','xyz%');
insert into t values (4,NULL,'any%','x',NULL,'any%');
insert into t values (5,'x','[','x','x','[');
commit;
SQL
if grep -qi error /tmp/simexpr-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/simexpr-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-simexpr.log 2>&1 &
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
        echo "FAIL $1 [VACUOUS: BOTH refuse - use both_raise for a raise cell]"; fail=1
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

# BOTH servers must raise, AND SAY THE SAME THING. sig() collapses every
# failure to the one word REFUSE, so `agree` would pass a raise that said
# something entirely different - which is the whole risk in a cell about
# an ERROR rather than an answer.
both_raise() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *SQLSTATE*) ;; *) echo "FAIL $1: the ENGINE no longer raises [$e]"; fail=1; return;; esac
    case "$f" in *SQLSTATE*) ;; *) echo "FAIL $1: THIS server does not raise [$f]"; fail=1; return;; esac
    if [ "$e" = "$f" ]; then echo "OK   both raise, same text: $1"
    else echo "FAIL $1 - both raise but the TEXT differs"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi
}

echo "-- 1. the PREDICATE world --"
agree "WHERE u SIMILAR TO v"        "select count(*) as n from t where id < 5 and u similar to v;"
agree "WHERE u NOT SIMILAR TO v"    "select count(*) as n from t where id < 5 and u not similar to v;"
agree "WHERE u SIMILAR TO v ESCAPE" "select count(*) as n from t where id < 5 and u similar to v escape '!';"
agree "WHERE u SIMILAR TO v || ''"  "select count(*) as n from t where id < 5 and u similar to v || '';"
agree "WHERE u SIMILAR TO TRIM(v)"  "select count(*) as n from t where id < 5 and u similar to trim(v);"

echo "-- 2. the VALUE world --"
agree "SELECT u SIMILAR TO v"       "select (u similar to v) as n from t where id < 5 order by id;"
agree "CASE WHEN u SIMILAR TO v"    "select (case when u similar to v then 1 else 0 end) as n from t where id < 5 order by id;"
agree "IIF(u SIMILAR TO v,1,0)"     "select iif(u similar to v,1,0) as n from t where id < 5 order by id;"
agree "(u SIMILAR TO v) = TRUE"     "select count(*) as n from t where id < 5 and (u similar to v) = true;"

echo "-- 3. the HAVING world --"
agree "HAVING u SIMILAR TO v"       "select count(*) as n from t where id < 5 group by u, v having u similar to v;"
agree "HAVING MAX(u) SIMILAR TO MAX(v)" \
      "select count(*) as n from t where id < 5 group by u having max(u) similar to max(v);"
agree "HAVING MAX(u) SIMILAR TO v"  "select count(*) as n from t where id < 5 group by u, v having max(u) similar to v;"

echo "-- 4. NULL is UNKNOWN, never a raise --"
agree "row 4 (NULL value)"          "select count(*) as n from t where id = 4 and u similar to v;"
agree "row 4, negated"              "select count(*) as n from t where id = 4 and u not similar to v;"

echo "-- 5. A MALFORMED PATTERN PER ROW - value-gated --"
both_raise "row 5 alone: both raise"  "select count(*) from t where id = 5 and u similar to v;"
both_raise "all rows: both raise"     "select count(*) from t where u similar to v;"
both_raise "a LITERAL '[' (prepare)"  "select count(*) from t where u similar to '[';"
# THE DECISIVE CELL: with the malformed row excluded by a prior conjunct
# the engine ANSWERS, so a server that refused at prepare would be wrong.
agree "row 5 EXCLUDED: must ANSWER"   "select count(*) as n from t where id <> 5 and u similar to v;"
# `id <> 5`, not `id < 5`: both select rows 1-4 here, but only the first
# SAYS what this cell tests - that a row whose pattern is malformed, when
# excluded by the WHERE clause, never reaches the PROJECTION and so never
# raises. A cell whose SQL does not express its intent is a weak cell even
# when it passes.
agree "row 5 excluded, value world"   "select (u similar to v) as n from t where id <> 5 order by id;"

echo "-- 6. the carrier pairings: matched answers, the MIX refuses --"
# BOTH SIDES ARE CARRIERS here (no default charset on this database), which
# is the pairing that answers - the same rule the other three families
# follow. This cell was first written as a `gap` claiming a "real pattern",
# and it went red saying the gap was closed: the fixture had no real-charset
# column in it at all.
agree "n SIMILAR TO v (BOTH carriers - answers)" \
      "select count(*) as n from t where id < 5 and n similar to v;"
# ...and the genuine mix, against the explicitly-UTF8 pattern column
gap "n SIMILAR TO vu (carrier value, UTF8 pattern)" \
    "select count(*) as n from t where id < 5 and n similar to vu;"

echo "-- 7. the LITERAL forms in all three worlds must not move --"
agree "WHERE u SIMILAR TO 'caf%'"   "select count(*) as n from t where u similar to 'caf%';"
agree "SELECT u SIMILAR TO 'caf%'"  "select (u similar to 'caf%') as n from t where id < 5 order by id;"
agree "HAVING MAX(u) SIMILAR TO 'caf%'" \
      "select count(*) as n from t group by u having max(u) similar to 'caf%';"
agree "WHERE u NOT SIMILAR TO 'caf%'" "select count(*) as n from t where u not similar to 'caf%';"

echo "-- 8. the other three families must not move (chunks 37-40) --"
agree "WHERE u LIKE v"              "select count(*) as n from t where id < 5 and u like v;"
agree "WHERE u CONTAINING sub"      "select count(*) as n from t where id < 5 and u containing sub;"
agree "SELECT u LIKE v"             "select (u like v) as n from t where id < 5 order by id;"
agree "HAVING u LIKE v"             "select count(*) as n from t where id < 5 group by u, v having u like v;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
# THE COUNTED FLOOR, derived from a measured run (29) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 29 ]; then
    echo "FAIL only $ran checks ran - the floor is 29; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# THE VERDICT MUST REACH THE CALLER - a gate that ends on an `echo` exits 0
# with every cell failing.
exit $fail
