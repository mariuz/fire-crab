#!/bin/bash
# UTF8 LOWER/UPPER USE THE ENGINE'S PER-CHARACTER SIMPLE CASE MAPPING.
#
# fire-crab cased a UTF8 string with Rust's to_lowercase/to_uppercase,
# which return the FULL (sometimes multi-char) Unicode mapping, and kept
# a character UNCHANGED whenever that mapping was multi-char. That is
# right for 'ß' -> 'ß' and for a ligature, but WRONG for U+0130 LATIN
# CAPITAL LETTER I WITH DOT ABOVE: its full lowercase is 'i' + COMBINING
# DOT ABOVE (two chars) but its SIMPLE lowercase - what the engine uses -
# is a single 'i' (U+0069). So LOWER('İ') was left 'İ' (2 octets) where
# the engine answers 'i' (1 octet), and `WHERE LOWER(nm)='istanbul'`
# silently dropped an 'İSTANBUL' row. The fix maps U+0130 -> 'i' on
# lowercasing; every other casing edge already matched.
#
# Held against the live engine over a UTF8 database.
#
# Usage: qa/serve-real-utf8case.sh [port]   (default 4149)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4149}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/utf8case.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set UTF8;" \
    | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/3050:$DB" >/tmp/utf8case-build.log 2>&1 <<'SQL'
create table c (id int, nm varchar(20) character set utf8);
commit;
insert into c values (1,'İSTANBUL');
insert into c values (2,'GROSS');
insert into c values (3,'ÀÉÎ');
commit;
SQL
if grep -qi error /tmp/utf8case-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/utf8case-build.log; exit 1; fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-utf8case.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
both() { # <label> <sql>
    local e f
    e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$E" 2>&1 | sed 's/  */ /g' | grep -iE '^(V|N|OL) ' | tr '\n' '|')
    f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$F" 2>&1 | sed 's/  */ /g' | grep -iE '^(V|N|OL) ' | tr '\n' '|')
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; }
}
echo "-- U+0130 (the fix) --"
both "LOWER('İ') value + octet_length"  "select lower('İ') v, octet_length(lower('İ')) ol from rdb\$database;"
both "LOWER('İSTANBUL')"                "select lower('İSTANBUL') v from rdb\$database;"
both "WHERE LOWER(nm)='istanbul'"       "select count(*) n from c where lower(nm)='istanbul';"
both "UPPER('İ') stays"                 "select upper('İ') v from rdb\$database;"
echo "-- regression: other casing edges unchanged --"
both "LOWER('ÀÉÎ')"                     "select lower('ÀÉÎ') v from rdb\$database;"
both "UPPER('àéî')"                     "select upper('àéî') v from rdb\$database;"
both "UPPER('groß') keeps ß"            "select upper('groß') v from rdb\$database;"
both "LOWER('ẞ')"                       "select lower('ẞ') v from rdb\$database;"
both "UPPER('ﬀ') ligature stays"        "select upper('ﬀ') v from rdb\$database;"
both "UPPER('ı') dotless"               "select upper('ı') v from rdb\$database;"
both "LOWER(nm) id=3"                   "select lower(nm) v from c where id=3;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS utf8case" || echo "FAIL utf8case"
exit $fail
