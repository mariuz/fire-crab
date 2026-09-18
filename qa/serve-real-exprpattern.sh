#!/bin/bash
# AN EXPRESSION AS THE PATTERN: `<x> LIKE <expr>` where the pattern is not a
# literal or a `?` but a VALUE computed per row - a sibling column,
# `V || '%'`, `TRIM(V)`, a CASE, a scalar subquery.
#
# The engine answers all of them. This server refused every one, and not by
# a guard downstream: [parse_pattern] admits only literal tokens and
# `Tok::Param`, so the predicate never became a `RawTerm` and the WHOLE
# statement declined. Re-measured before the work: 11 of 13 shapes refused
# here, and NONE was a wrong answer - a pure capability gap.
#
# A `?` pattern is NOT this gap and already worked (7 of 7, all four
# families); the cells below pin that it still does.
#
# TWO LAWS THIS GATE EXISTS TO HOLD:
#
#  1. NO TRANSCODE. A literal pattern is statement text the attachment
#     decodes, so it moves with the attachment; an expression pattern is a
#     VALUE carrying its own column's charset and does not. Measured: every
#     expression-pattern shape answers IDENTICALLY under NONE, WIN1252 and
#     UTF8. The cells run the same statement under all three.
#
#  2. THE NONE PAIRINGS ARE ASYMMETRIC. `<none> LIKE <none>` matches;
#     `<none value> LIKE <real pattern>` MISSES the non-ASCII row and does
#     NOT raise; `<real value> LIKE <none pattern>` RAISES 22000 Malformed
#     string. Three different answers, none of them guessable.
#
# THIS SLICE IS `LIKE` ONLY. STARTING WITH, CONTAINING and SIMILAR TO with
# an expression pattern still refuse; they are recorded as gaps below so the
# day someone implements them, those cells go red and ask to be promoted.
#
# Usage: qa/serve-real-exprpattern.sh [port]   (default 4361)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4361}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/exprpat-eng.fdb"; FC="$D/exprpat-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/exprpat-build.log 2>&1 <<'SQL'
-- U/W/N are the VALUE columns in three charsets; PU/PW/PN the PATTERN
-- columns beside them. Row 1 carries NON-ASCII, row 2 is pure ASCII, so a
-- rule about BYTES and a rule about COLUMN KIND can be told apart. Row 3
-- has a NULL pattern and row 4 a NULL value, for the 3VL cells.
create table t (id int,
  u varchar(20) character set utf8,
  w varchar(20) character set win1252,
  n varchar(20) character set none,
  pu varchar(20) character set utf8,
  pw varchar(20) character set win1252,
  pn varchar(20) character set none,
  ci varchar(20) character set utf8 collate unicode_ci);
commit;
insert into t values (1, 'caf' || _utf8 x'C3A9', 'caf' || _win1252 x'E9', 'caf' || x'E9',
                         'caf' || _utf8 x'C3A9' || '%', 'caf' || _win1252 x'E9' || '%',
                         'caf' || x'E9' || '%', 'CAFE');
insert into t values (2, 'plain', 'plain', 'plain', 'pla%', 'pla%', 'pla%', 'PLAIN');
insert into t values (3, 'nopat', 'nopat', 'nopat', NULL, NULL, NULL, 'NOPAT');
insert into t values (4, NULL, NULL, NULL, 'any%', 'any%', 'any%', NULL);
commit;
SQL
if grep -qi error /tmp/exprpat-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/exprpat-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exprpattern.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "something is listening" is not "OUR server is listening": if the port was
# taken, fcwire exited at bind and every cell below would measure the OTHER
# server while reporting success. Fatal, not a warning.
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# the rows (or REFUSE) under an optional client charset, exactly nonecmp's
# idiom: collapsing every failure to one word is why the raise cells below
# use their own helper instead of this one
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
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# A RECORDED CAPABILITY GAP: the ENGINE answers and this server REFUSES.
# Both sides asked, so a cell where the engine also fails cannot score a
# silent OK. Goes red the day fire-crab answers - which is the signal to
# promote it to `agree`, not to delete it.
gap() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" "$2" "${3:-}")
    if [ "$e" = REFUSE ] || [ -z "$e" ]; then
        echo "FAIL $1 [VACUOUS: the ENGINE did not answer either: $e]"; fail=1
    elif [ "$f" = REFUSE ]; then echo "OK   refused (engine answers $e): $1"
    else echo "FAIL $1 now ANSWERS [$f] - the gap is closed; promote this cell to agree"; fail=1
    fi
}

# A RECORDED GAP WHERE THE ENGINE RAISES. `gap` cannot express this: it
# scores an engine failure as VACUOUS, and `agree` scores two different
# failures as equal because sig() collapses both to the word REFUSE. So
# this asserts the two failures are DIFFERENT and each is the right one -
# the engine's 22000 *Malformed string* against this server's 42000
# decline. Goes red if the engine stops raising, if this server starts
# ANSWERING, or if it starts raising 22000 itself (which would be the
# promotion signal: implement the raise, then make this a both-raise cell).
gap_raise() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local ch="" e f
    [ -n "${3:-}" ] && ch="-ch $3"
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *22000*) ;; *) echo "FAIL $1: the ENGINE no longer raises 22000 [$e]"; fail=1; return;; esac
    case "$f" in
        *22000*) echo "FAIL $1 now RAISES 22000 too - promote this cell to a both-raise"; fail=1;;
        *4200*)  echo "OK   engine raises 22000, this server declines: $1";;
        *)       echo "FAIL $1: this server neither raises nor declines [$f]"; fail=1;;
    esac
}

echo "-- 1. the CAPABILITY: a pattern that is a value, not a literal --"
agree "u LIKE pu (sibling column)"    "select id from t where u like pu order by id;"
# COUNTED: every row either matches (1, 2), has a NULL pattern (3) or a
# NULL value (4), so NOT LIKE legitimately lists NOTHING - and an empty
# listing is the one answer a match-nothing bug would also produce.
agree "u NOT LIKE pu (counted)"       "select count(*) n from t where u not like pu;"
agree "u LIKE pu || '' (concat)"      "select id from t where u like pu || '' order by id;"
agree "u LIKE TRIM(pu)"               "select id from t where u like trim(pu) order by id;"
agree "u LIKE CASE WHEN 1=1 THEN pu ELSE pu END" \
      "select id from t where u like case when 1=1 then pu else pu end order by id;"
agree "u LIKE (SELECT MAX(pu) FROM t)" "select id from t where u like (select max(pu) from t) order by id;"
agree "pu LIKE u (pattern on the LEFT, counted)" "select count(*) n from t where pu like u;"
agree "u LIKE pu ESCAPE '!'"          "select id from t where u like pu escape '!' order by id;"
agree "count over u LIKE pu"          "select count(*) n from t where u like pu;"

echo "-- 2. NO TRANSCODE: the same statement under all three attachments --"
agree "u LIKE pu @NONE"               "select id from t where u like pu order by id;" NONE
agree "u LIKE pu @WIN1252"            "select id from t where u like pu order by id;" WIN1252
agree "u LIKE pu @UTF8"               "select id from t where u like pu order by id;" UTF8
agree "w LIKE pw @NONE"               "select id from t where w like pw order by id;" NONE
agree "w LIKE pw @WIN1252"            "select id from t where w like pw order by id;" WIN1252
agree "w LIKE pw @UTF8"               "select id from t where w like pw order by id;" UTF8

# The engine gives these THREE pairings THREE different answers:
# carrier/carrier MATCHES, carrier-value/real-pattern MISSES the non-ASCII
# row without raising, real-value/carrier-pattern RAISES 22000. There is no
# one byte-space rule to apply, and answering by resolving both sides and
# comparing gave three WRONG ANSWERS on the first cut - `n LIKE pu` listed
# the row the engine misses, `u LIKE pn` answered rows where the engine
# raises. So the two MIXED pairings now refuse, and only the matched pair
# is answered. Refusing is a gap; answering was wrong.
echo "-- 3. the ASYMMETRIC NONE pairings - matched pair answered, MIXES refused --"
agree "n LIKE pn (carrier BOTH sides: answered)" "select id from t where n like pn order by id;"
gap "n LIKE pu (carrier value, real pattern - engine MISSES the non-ASCII row)" \
    "select count(*) n from t where n like pu;"
gap "n LIKE pu listed (same mix, listing form)" \
    "select id from t where n like pu order by id;"
gap_raise "u LIKE pn (real value, carrier pattern - engine raises 22000)" \
    "select id from t where u like pn order by id;"

echo "-- 4. NULL on either side is UNKNOWN, never a raise --"
# COUNTED for the same reason: UNKNOWN filters the row out, so each of
# these lists nothing, and `N0` says that POSITIVELY rather than by absence.
agree "row 3 has a NULL pattern"      "select count(*) n from t where id = 3 and u like pu;"
agree "row 4 has a NULL value"        "select count(*) n from t where id = 4 and u like pu;"
agree "NOT LIKE over a NULL pattern"  "select count(*) n from t where id = 3 and u not like pu;"
# A PRE-EXISTING, UNRELATED GAP: `IS UNKNOWN` over a predicate refuses on
# this server whatever the predicate is - measured on the PREVIOUS binary
# (4af9add), where `(U LIKE 'caf%') IS UNKNOWN` and even `(U IS NULL) IS
# UNKNOWN` refuse identically. Nothing to do with expression patterns; kept
# here as a `gap` because this gate is where it was found.
gap "IS UNKNOWN over a predicate (pre-existing)" \
    "select count(*) n from t where (u like pu) is unknown;"

echo "-- 5. the LITERAL and ? forms must not move --"
agree "u LIKE 'caf%' literal"         "select id from t where u like 'caf%' order by id;"
agree "u LIKE 'pla_n' literal"        "select id from t where u like 'pla_n' order by id;"
agree "u NOT LIKE 'pla%' literal"     "select id from t where u not like 'pla%' order by id;"
agree "u LIKE 'caf!%' ESCAPE literal" "select id from t where u like 'caf!%' escape '!' order by id;"
agree "u LIKE NULL"                   "select id from t where u like null order by id;"

echo "-- 6. DELIBERATE DECLINES: shapes this slice refuses on purpose --"
gap "a COLLATE-canonical left side" \
    "select id from t where ci collate unicode_ci like pu order by id;"

echo "-- 7. THE OTHER THREE FAMILIES still refuse - LIKE only, this slice --"
# COUNTED, not listed: `u starting with pu` legitimately matches NOTHING
# (pu is a LIKE pattern, and STARTING WITH reads `%` as a literal), and an
# empty listing is indistinguishable from a refusal in sig() - the first run
# scored both cells VACUOUS for exactly that reason. `count(*)` makes the
# engine's answer `N0`: still an answer, and still not a refusal.
gap "STARTING WITH an expression"     "select count(*) n from t where u starting with pu;"
gap "CONTAINING an expression"        "select count(*) n from t where u containing pu;"
gap "SIMILAR TO an expression"        "select id from t where u similar to pu order by id;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"

# THE COUNTED FLOOR, derived from a measured run (32) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 32 ]; then
    echo "FAIL only $ran checks ran - the floor is 32; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# ...AND THE VERDICT MUST REACH THE CALLER. Without this the script ends on
# an `echo` and exits 0: the first three runs of this gate reported
# `exit=0` with 24 cells FAILING, which is a gate with no teeth at all.
exit $fail
