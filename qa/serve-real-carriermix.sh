#!/bin/bash
# THE CARRIER/REAL CHARSET MIX in a pattern predicate, all four families,
# all three worlds.
#
# Every mix REFUSED before this slice - eight guard sites, four in the
# value world and four in the predicate world, with HAVING inheriting the
# latter. Refusals, not wrong answers, which is why they were safe to
# leave standing until the contract was known.
#
# THE RULE IS NOT PER-FAMILY. An earlier record of mine said it was -
# "LIKE and STARTING raise, CONTAINING and SIMILAR answer" - and that was
# an artefact of ONE fixture whose carrier pattern was `'af'`/`'pp'`,
# pure ASCII. Measured properly, all four families behave IDENTICALLY and
# the rule is per-ROW, on the PATTERN's BYTES:
#
#   carrier VALUE / real PATTERN   answers in BYTE SPACE - the real
#                                  pattern is re-spelled as the carrier of
#                                  its own octets ([Expr::CarrierEnc], the
#                                  wrapper cmp_sides already uses for a
#                                  comparison), so the NON-ASCII row
#                                  silently MISSES and nothing raises.
#   real VALUE / carrier PATTERN   the pattern's octets are DECODED into
#                                  the real set ([Expr::CarrierDec]):
#                                  ASCII octets spell it and ANSWER,
#                                  others raise 22000 - PER ROW, so one
#                                  statement answers for a row whose
#                                  pattern is ASCII and raises for a row
#                                  whose pattern is not.
#
# THE VALUE-GATING PAIR BELOW IS THE POINT OF THIS GATE. A server that
# refused at prepare, or raised for the whole statement, would pass every
# other cell here and fail those two.
#
# Usage: qa/serve-real-carriermix.sh [port]   (default 4366)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4366}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/carmix-eng.fdb"; FC="$D/carmix-fc.fdb"
mkdir -p "$D"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/$REAL:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" >/tmp/carmix-build.log 2>&1 <<'SQL'
-- ROW 1 IS NON-ASCII ON EVERY COLUMN AND ROW 2 IS PURE ASCII. That split
-- is the whole fixture: it is what lets "misses the non-ASCII row" be told
-- apart from "matches nothing", and what makes the per-row raise visible.
-- U/PU/SU/RU are UTF8 (real); N/PN/SN/RN are NONE (byte carriers);
-- AN is a carrier pattern that is ASCII even on row 1.
create table t (id int,
  u varchar(20) character set utf8,  n  varchar(20) character set none,
  pu varchar(20) character set utf8, pn varchar(20) character set none,
  an varchar(20) character set none,
  su varchar(20) character set utf8, sn varchar(20) character set none,
  ru varchar(20) character set utf8, rn varchar(20) character set none);
commit;
insert into t values (1, 'caf' || _utf8 x'C3A9', 'caf' || x'E9',
  'caf' || _utf8 x'C3A9' || '%', 'caf' || x'E9' || '%', 'caf%',
  _utf8 x'C3A9', x'E9', 'caf' || _utf8 x'C3A9', 'caf' || x'E9');
insert into t values (2,'plain','plain','pla%','pla%','pla%','ai','ai','pl','pl');
commit;
SQL
if grep -qi error /tmp/carmix-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/carmix-build.log; exit 1
fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-carriermix.log 2>&1 &
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
# EVERY CELL MUST BE ABLE TO SHOW WHICH ROW MATCHED. A count alone would
# hide the silent miss this whole slice is about, so the listing cells
# project ID and the counted ones alias N.
sig() { local r
    r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
        | sed 's/  */ /g' | grep -aivE '^$|SQL>')
    if printf '%s' "$r" | grep -aqi 'failed\|malformed\|error'; then echo "REFUSE"
    else printf '%s' "$r" | grep -aiE '^(N|ID|CNT) ' | tr -d ' \n'; fi; }

agree() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/$REAL:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = REFUSE ] && [ "$f" = REFUSE ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - use both_raise for a raise cell]"; fail=1
    elif [ -z "$e" ] && [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: both answered NOTHING - project ID or alias N]"; fail=1
    elif [ "$e" = "$f" ]; then echo "OK   $1 [$e]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# both servers must raise AND SAY THE SAME THING - sig() collapses every
# failure to one word, so `agree` would pass a 22000 that said something
# else entirely, which is the whole risk in a cell about an ERROR
both_raise() { # <label> <sql>
    ran=$((ran + 1))
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | tr -d '\r' | grep -a . | paste -sd'|' -)
    case "$e" in *22000*) ;; *) echo "FAIL $1: the ENGINE no longer raises 22000 [$e]"; fail=1; return;; esac
    case "$f" in *22000*) ;; *) echo "FAIL $1: THIS server does not raise 22000 [$f]"; fail=1; return;; esac
    if [ "$e" = "$f" ]; then echo "OK   both raise, same text: $1"
    else echo "FAIL $1 - both raise but the TEXT differs"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi
}

echo "-- 1. carrier VALUE / real PATTERN: byte space, row 1 silently MISSES --"
agree "N LIKE PU"            "select id from t where n like pu order by id;"
agree "N CONTAINING SU"      "select id from t where n containing su order by id;"
agree "N STARTING WITH RU"   "select id from t where n starting with ru order by id;"
agree "N SIMILAR TO PU"      "select id from t where n similar to pu order by id;"
agree "counted, to pin the MISS" "select count(*) as n from t where n like pu;"
agree "SELECT N LIKE PU (value world)" "select (n like pu) as n from t order by id;"
# ALIASED `cnt`, NOT `n`: this fixture HAS a column named `n`, and a
# select-list alias that shadows a grouped column makes the ENGINE refuse
# the HAVING (42000) - so the cell measured my alias, not the carrier mix.
# (That collision turned out to be a real divergence in its own right, and
# is filed separately: this server ANSWERS where the engine refuses.)
agree "HAVING N LIKE PU"     "select count(*) as cnt from t group by n, pu having n like pu;"

echo "-- 2. real VALUE / ASCII carrier pattern: decodes and ANSWERS --"
agree "U LIKE AN"            "select id from t where u like an order by id;"
agree "U SIMILAR TO AN"      "select id from t where u similar to an order by id;"
agree "U CONTAINING SN, row 2 only" "select count(*) as n from t where id = 2 and u containing sn;"
agree "U STARTING WITH RN, row 2 only" "select count(*) as n from t where id = 2 and u starting with rn;"

echo "-- 3. real VALUE / NON-ASCII carrier pattern: RAISES 22000 --"
both_raise "U LIKE PN"           "select id from t where u like pn order by id;"
both_raise "U CONTAINING SN"     "select id from t where u containing sn order by id;"
both_raise "U STARTING WITH RN"  "select id from t where u starting with rn order by id;"
both_raise "U SIMILAR TO PN"     "select id from t where u similar to pn order by id;"
both_raise "SELECT U LIKE PN (value world)" "select (u like pn) as n from t order by id;"

echo "-- 4. THE VALUE-GATING PAIR - the same shape, one row each way --"
# a server that refused at prepare, or raised for the whole statement,
# passes every other cell in this gate and fails exactly these two
agree "row 2 only (ASCII pattern): ANSWERS" "select count(*) as n from t where id = 2 and u like pn;"
both_raise "row 1 only (non-ASCII pattern): RAISES" "select count(*) from t where id = 1 and u like pn;"

echo "-- 5. the MATCHED pairings must not move --"
agree "U LIKE PU (real/real)"       "select id from t where u like pu order by id;"
agree "N LIKE PN (carrier/carrier)" "select id from t where n like pn order by id;"
agree "U CONTAINING SU (real/real)" "select id from t where u containing su order by id;"
agree "N SIMILAR TO PN (carr/carr)" "select id from t where n similar to pn order by id;"
agree "U STARTING WITH RU (real)"   "select id from t where u starting with ru order by id;"

echo "-- 6. the LITERAL forms must not move --"
agree "U LIKE 'caf%'"        "select id from t where u like 'caf%' order by id;"
agree "N LIKE 'pla%'"        "select id from t where n like 'pla%' order by id;"
agree "U CONTAINING 'ai'"    "select id from t where u containing 'ai' order by id;"
agree "U SIMILAR TO 'pla%'"  "select id from t where u similar to 'pla%' order by id;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
# THE COUNTED FLOOR, derived from a measured run (27) and never typed from
# the cell list. A helper defined below its first call, an `if` that eats a
# block, an early `exit` in the fixture build - each silently REMOVES cells
# while every remaining one still says OK. Only the count sees that.
if [ "$ran" -lt 27 ]; then
    echo "FAIL only $ran checks ran - the floor is 27; cells went MISSING"
    fail=1
fi
echo "ran $ran checks"
# THE VERDICT MUST REACH THE CALLER - a gate that ends on an `echo` exits 0
# with every cell failing.
exit $fail
