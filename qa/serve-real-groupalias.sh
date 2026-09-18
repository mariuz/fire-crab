#!/bin/bash
# TWO UNRELATED `GROUP BY` DEFECTS, fixed together because ONE probe found
# both while diagnosing a failing cell in another gate.
#
# (A) WAS A WRONG ANSWER. An AGGREGATE select item aliased to the name of a
#     GROUPED column makes the statement invalid: the alias makes
#     `GROUP BY N` look like it references the aggregate, and the engine
#     rejects it - MEASURED, not paraphrased - with 42000 / -104 /
#     "Cannot use an aggregate or window function in a GROUP BY clause".
#     This server took the real column and ANSWERED `2|1`.
#     [parse_group_by] matched `SelItem::Col` and `SelItem::Expr` aliases
#     but NEVER `SelItem::Agg`, and its comment called a shadowing alias
#     "harmless" - which is what made it silent.
#
#     NOTE WHAT IS NOT REQUIRED: no HAVING, no ORDER BY. The BARE statement
#     already refuses on the engine, and `ORDER BY 1` refuses too. The
#     first filing of this defect said HAVING/ORDER BY were required; a
#     boundary probe reshaped it within the hour, which is why the bare
#     cells lead this gate.
#
# (B) WAS A REFUSAL, and has nothing to do with aliases. `ORDER BY` a
#     GROUP BY key that is NOT in the select list refused here and answers
#     on the engine. [build_group_items] seeds a slot for every unclaimed
#     `key_fid` but ONLY inside `if !deferred.is_empty()`, so a plain
#     `SELECT COUNT(*) FROM T GROUP BY N ORDER BY N` never got one.
#     Seeded on demand in plan_group's ORDER BY resolver - exactly what
#     [resolve_having] already does, the SECOND place that one mechanism
#     was missing.
#
# THE CONTROLS CARRY AS MUCH WEIGHT AS THE FIXES. (A)'s refusal must NOT
# catch a non-aggregate alias, an alias over a NON-grouped column, or a
# non-colliding alias: a refusal that is too broad is a new wrong answer
# pointing the other way.
#
# Usage: qa/serve-real-groupalias.sh [port]   (default 4367)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4367}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/grpalias-eng.fdb"; FC="$D/grpalias-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/grpalias-build.log 2>&1 <<'SQL'
-- N groups into TWO buckets of different sizes (2 and 1), so an ORDER BY
-- on the KEY and one on the COUNT give DIFFERENT orders - which is what
-- makes the unprojected-key cells able to fail rather than coincide.
create table t (id int, n varchar(20), v varchar(20), k int);
commit;
insert into t values (1,'plain','x',10);
insert into t values (2,'plate','y',20);
insert into t values (3,'plain','z',30);
commit;
SQL
if grep -qi error /tmp/grpalias-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/grpalias-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupalias.log 2>&1 &
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
    else printf '%s' "$r" | grep -aiE '^(N|ID|CNT|V|K) ' | tr -d ' \n'; fi; }

agree() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = REFUSE ] && [ "$f" = REFUSE ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - use both_refuse for a refusal cell]"; fail=1
    elif [ -z "$e" ] && [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: both answered NOTHING - project N/ID or alias CNT]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# BOTH must refuse - but NOT with the same text, and that is deliberate.
# The engine says -104 "Cannot use an aggregate function"; this server says
# a generic 42000. Pinning the ENGINE's message means the cell goes red if
# the engine ever stops refusing (which would make our refusal a wrong
# answer), while the differing vector stays VISIBLE instead of smoothed
# over by a helper that only asks "did both fail?".
both_refuse() { # <label> <sql> <engine-message-fragment>
    ran=$((ran + 1))
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *"$3"*) ;; *) echo "FAIL $1: the ENGINE no longer refuses with '$3' [$e]"; fail=1; return;; esac
    case "$f" in *SQLSTATE*) echo "OK   both refuse (engine: $3): $1";;
                 *) echo "FAIL $1: THIS server ANSWERS [$f] - the wrong answer is back"; fail=1;; esac
}

echo "-- 1. (A) the wrong answer: an AGGREGATE aliased to a GROUPED column --"
both_refuse "bare COUNT(*) AS N, GROUP BY N" \
    "select count(*) as n from t group by n;" "Cannot use an aggregate or window function in a GROUP BY clause"
both_refuse "bare MAX(K) AS N, GROUP BY N" \
    "select max(k) as n from t group by n;" "Cannot use an aggregate or window function in a GROUP BY clause"
both_refuse "with HAVING N = 'plain'" \
    "select count(*) as n from t group by n having n = 'plain';" "Cannot use an aggregate or window function in a GROUP BY clause"
both_refuse "with ORDER BY N" \
    "select count(*) as n from t group by n order by n;" "Cannot use an aggregate or window function in a GROUP BY clause"
both_refuse "with ORDER BY 1 (an ORDINAL names nothing)" \
    "select count(*) as n from t group by n order by 1;" "Cannot use an aggregate or window function in a GROUP BY clause"
both_refuse "the colliding alias on a SECOND select item" \
    "select n as v, count(*) as n from t group by n order by n;" "Cannot use an aggregate or window function in a GROUP BY clause"

echo "-- 2. (A) CONTROLS - the refusal must not be one word wider --"
agree "non-colliding alias C"        "select count(*) as cnt from t group by n order by cnt;"
agree "NON-aggregate alias N"        "select n as n, count(*) as cnt from t group by n order by n;"
agree "alias over a NON-grouped column" \
      "select count(*) as v from t group by n having n = 'plain';"
agree "plain aliased SELECT, no GROUP BY" "select n as n from t order by id;"
# A colliding alias on a NON-aggregate item: K is a real column, and NOT the
# grouped one. The refusal keys on SelItem::Agg, so this must still answer.
agree "NON-aggregate alias over another column" \
      "select n as k, count(*) as cnt from t group by n order by k;"

echo "-- 3. (B) ORDER BY a grouped key that is NOT projected --"
agree "ORDER BY unprojected key"     "select count(*) as cnt from t group by n order by n;"
agree "the same, DESC"               "select count(*) as cnt from t group by n order by n desc;"
agree "GROUP BY n,v - ORDER BY v"    "select n, count(*) as cnt from t group by n, v order by v;"
agree "unprojected key + HAVING"     "select count(*) as cnt from t group by n having count(*) > 0 order by n;"

echo "-- 4. (B) CONTROLS --"
agree "ORDER BY 1 (the aggregate)"   "select count(*) as cnt from t group by n order by 1;"
agree "the key IS projected"         "select n, count(*) as cnt from t group by n order by n;"
agree "ungrouped, unprojected order column" "select k as cnt from t order by n;"
agree "no aggregate at all"          "select n from t group by n order by n;"

echo "-- 5. recorded, NOT fixed: HAVING over a select alias (both refuse, different vectors) --"
both_refuse "HAVING CNT > 1 over alias CNT" \
    "select count(*) as cnt from t group by n having cnt > 1;" "SQL error code = -206"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN (20 on the fixing binary), never
# typed. It catches the failure a pass/fail tally cannot: cells SILENTLY
# DISAPPEARING - an early `exit`, a helper renamed, a section deleted - which
# otherwise reports a clean sweep over nothing.
if [ "$ran" -lt 20 ]; then
    echo "FAIL only $ran checks ran; 20 were measured - cells went missing"; fail=1
fi
# THE VERDICT MUST REACH THE CALLER - a gate that ends on an `echo` exits 0
# with every cell failing.
exit $fail
