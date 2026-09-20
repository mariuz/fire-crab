#!/bin/bash
# AN EXPRESSION AS THE PATTERN, for CONTAINING and STARTING WITH - the two
# families the LIKE slice left refusing. `<x> CONTAINING <expr>` and
# `<x> STARTING WITH <expr>` where the pattern is a sibling column,
# `V || ''`, `TRIM(V)` or a scalar subquery.
#
# Measured before the work: every one of these refused (42000) while the
# engine answered, and NONE was a wrong answer - a pure capability gap, the
# same shape LIKE's was.
#
# THE CARRIER CONTRACT IS NOT LIKE'S, and that is why it was measured
# rather than copied. The engine gives the three families THREE different
# answers for a real value against a byte-carrier pattern:
#
#   <real> LIKE <carrier>          RAISES 22000 Malformed string
#   <real> CONTAINING <carrier>    ANSWERS 2, no raise
#   <real> STARTING WITH <carrier> RAISES 22000
#
# This server USED TO REFUSE every carrier/real mix in both families - a
# deliberate gap, recorded because the literal arms reach their answers by
# transcoding a LITERAL at prepare, which a per-row pattern cannot do, and
# because this server had no STARTING raise mechanism at all.
#
# PROMOTED 2026-09-20: all four section-5 cells and the SIMILAR TO cell in
# section 9 were re-measured and now MATCH the engine exactly - the three
# CONTAINING/STARTING mixes answer the same ROWS (1 and 2), and
# `<real> STARTING WITH <carrier>` raises the same `22000 Malformed string`.
# The gap was closed by some EARLIER chunk and nobody unrecorded it: the
# PREVIOUS committed binary (/tmp/fcwire-prev-0e5a8f4) closes all five too,
# so this is pre-existing, not the work in flight. Section 6 (a
# COLLATE-canonical left side) is the part that still refuses, and stays a
# recorded `gap`.
#
# Usage: qa/serve-real-exprpattern2.sh [port]   (default 4362)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4362}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/exprpat2-eng.fdb"; FC="$D/exprpat2-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/exprpat2-build.log 2>&1 <<'SQL'
-- row 1 carries NON-ASCII, row 2 is pure ASCII, so a rule about BYTES and a
-- rule about COLUMN KIND can be told apart. Row 3 has NULL patterns and
-- row 4 a NULL value, for the 3VL cells.
create table t (id int,
  u varchar(20) character set utf8,
  n varchar(20) character set none,
  sub varchar(20) character set utf8,
  pre varchar(20) character set utf8,
  subn varchar(20) character set none,
  pren varchar(20) character set none,
  ci varchar(20) character set utf8 collate unicode_ci);
commit;
insert into t values (1, 'caf' || _utf8 x'C3A9', 'caf' || x'E9',
                         'af', 'ca', 'af', 'caf' || x'E9', 'CAFE');
insert into t values (2, 'plain', 'plain', 'ai', 'pl', 'ai', 'pl', 'PLAIN');
insert into t values (3, 'nopat', 'nopat', NULL, NULL, NULL, NULL, 'NOPAT');
insert into t values (4, NULL, NULL, 'x', 'x', 'x', 'x', NULL);
commit;
SQL
if grep -qi error /tmp/exprpat2-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/exprpat2-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exprpattern2.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "something is listening" is not "OUR server is listening": if the port was
# taken, fcwire exited at bind and every cell would measure the OTHER server.
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
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

# the engine ANSWERS and this server REFUSES - a recorded gap. Goes red the
# day fire-crab answers, which is the signal to promote it.
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

# BOTH sides raise 22000. This replaces the old `gap_raise` (engine raises
# 22000, this server declines 42000), which fired on 2026-09-20 because the
# server now raises. `agree` cannot serve here: sig() maps EVERY failure to
# the single token REFUSE, so it would score a 42000 decline equal to the
# engine's 22000. This asserts the engine still raises 22000 AND that the two
# failure texts are character-for-character the same.
agree_raise() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *22000*) ;; *) echo "FAIL $1: the ENGINE no longer raises 22000 [$e]"; fail=1; return;; esac
    if [ "$e" = "$f" ]; then echo "OK   both raise 22000: $1"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- 1. CONTAINING with a pattern that is a value --"
agree "cnt u CONTAINING sub"          "select count(*) n from t where u containing sub;"
agree "u CONTAINING sub (listed)"     "select id from t where u containing sub order by id;"
agree "cnt u NOT CONTAINING sub"      "select count(*) n from t where u not containing sub;"
agree "u CONTAINING sub || ''"        "select id from t where u containing sub || '' order by id;"
agree "u CONTAINING TRIM(sub)"        "select id from t where u containing trim(sub) order by id;"
# MIN, not MAX, on purpose: MIN(sub) is 'af', which row 1 actually contains,
# so this cell returns a ROW. With MAX it was 'x', matching nothing, and the
# cell compared an empty listing against an empty listing - which is exactly
# what a match-nothing bug would also produce.
agree "u CONTAINING (SELECT MIN(sub) FROM t)" \
      "select id from t where u containing (select min(sub) from t) order by id;"
agree "cnt sub CONTAINING u (pattern LEFT)" "select count(*) n from t where sub containing u;"

echo "-- 2. STARTING WITH a pattern that is a value --"
agree "cnt u STARTING WITH pre"       "select count(*) n from t where u starting with pre;"
agree "u STARTING WITH pre (listed)"  "select id from t where u starting with pre order by id;"
agree "cnt u NOT STARTING WITH pre"   "select count(*) n from t where u not starting with pre;"
agree "u STARTING WITH TRIM(pre)"     "select id from t where u starting with trim(pre) order by id;"
agree "u STARTING WITH pre || ''"     "select id from t where u starting with pre || '' order by id;"

echo "-- 3. NULL on either side is UNKNOWN, never a raise --"
agree "row 3 NULL pattern (CONTAINING)" "select count(*) n from t where id = 3 and u containing sub;"
agree "row 4 NULL value (STARTING)"     "select count(*) n from t where id = 4 and u starting with pre;"
agree "row 3 NULL pattern, negated"     "select count(*) n from t where id = 3 and u not containing sub;"

echo "-- 4. two byte carriers need no reconciliation: both sides NONE --"
agree "cnt n CONTAINING subn"         "select count(*) n from t where n containing subn;"
agree "cnt n STARTING WITH pren"      "select count(*) n from t where n starting with pren;"

# PROMOTED 2026-09-20, all four: this server matches the engine on every
# carrier/real mix now, and the PREVIOUS committed binary
# (/tmp/fcwire-prev-0e5a8f4) matches too - the gap was closed by an earlier
# chunk and only the recording was stale. Each answer was re-measured against
# the live engine on 2026-09-20 before the cell was promoted.
echo "-- 5. the carrier/real MIXES: answered here now, and they MATCH --"
# engine: N2, and the same ROWS (1, 2) as the listed form.
agree "cnt n CONTAINING sub (carrier value, real pattern)" \
    "select count(*) n from t where n containing sub;"
# engine: N2, no raise - CONTAINING is the family that does not raise here.
agree "cnt u CONTAINING subn (real value, carrier pattern - no raise)" \
    "select count(*) n from t where u containing subn;"
# engine: N2, rows 1 and 2.
agree "cnt n STARTING WITH pre (carrier value, real pattern)" \
    "select count(*) n from t where n starting with pre;"
# engine: `Statement failed, SQLSTATE = 22000 | Malformed string`, and this
# server now raises that same text - the third of the three different
# carrier answers in the header, and the one this server had no mechanism for.
agree_raise "u STARTING WITH pren (real value, carrier pattern - BOTH raise 22000 Malformed string)" \
    "select id from t where u starting with pren order by id;"

# STILL A GAP on 2026-09-20 (re-measured): the engine answers N2 for both and
# this server refuses. This is the last recorded boundary left in this gate.
echo "-- 6. a COLLATE-canonical left side: still refused (the !is_cmp guard) --"
gap "ci CONTAINING sub"               "select count(*) n from t where ci containing sub;"
gap "ci STARTING WITH pre"            "select count(*) n from t where ci starting with pre;"

echo "-- 7. NO TRANSCODE: the same statement under all three attachments --"
agree "u CONTAINING sub @NONE"        "select id from t where u containing sub order by id;" NONE
agree "u CONTAINING sub @WIN1252"     "select id from t where u containing sub order by id;" WIN1252
agree "u CONTAINING sub @UTF8"        "select id from t where u containing sub order by id;" UTF8
agree "u STARTING WITH pre @NONE"     "select id from t where u starting with pre order by id;" NONE
agree "u STARTING WITH pre @UTF8"     "select id from t where u starting with pre order by id;" UTF8

echo "-- 8. the LITERAL forms must not move --"
agree "cnt u CONTAINING 'af'"         "select count(*) n from t where u containing 'af';"
agree "cnt u NOT CONTAINING 'af'"     "select count(*) n from t where u not containing 'af';"
agree "cnt u STARTING WITH 'ca'"      "select count(*) n from t where u starting with 'ca';"
agree "cnt u CONTAINING 'AF' (case-insensitive)" "select count(*) n from t where u containing 'AF';"
agree "cnt u LIKE 'caf%'"             "select count(*) n from t where u like 'caf%';"

echo "-- 9. the LIKE capability must not move, and SIMILAR is answered too --"
agree "cnt u LIKE sub (LIKE, expression pattern)" "select count(*) n from t where u like sub;"
# COUNTED: `u similar to sub` legitimately matches NOTHING (sub is a
# substring, not a SQL:2008 regex), and an empty listing is indistinguishable
# from a refusal in sig() - the first run scored this cell VACUOUS for
# exactly that reason. `count(*)` makes the engine's answer `N0`.
# PROMOTED 2026-09-20: this server answers N0 too, and returns the same
# (empty) row set in the listed form. The previous committed binary
# (/tmp/fcwire-prev-0e5a8f4) answers it as well, so this too is pre-existing.
# The count form is kept ON PURPOSE: `N0` from both sides is a real cell,
# where two empty listings would be the vacuous one this started as.
agree "cnt u SIMILAR TO sub (matches nothing - sub is a substring, not a regex)" \
    "select count(*) n from t where u similar to sub;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
# THE COUNTED FLOOR, derived from a measured run (35) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 35 ]; then
    echo "FAIL only $ran checks ran - the floor is 35; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# THE VERDICT MUST REACH THE CALLER. The LIKE gate ended on an `echo` and
# reported exit 0 through three runs with 24 cells failing; this one does not.
exit $fail
