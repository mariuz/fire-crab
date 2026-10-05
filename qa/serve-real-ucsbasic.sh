#!/bin/bash
# UTF8's UCS_BASIC COLLATION, AND A COLLATE WITH NO CHARACTER SET.
#
# A column declared `COLLATE UCS_BASIC` refused everywhere (the paper's
# samples/nodejs/intl.js): keyable_ttype took collation 0 only. UCS_BASIC is
# NOT UTF8's default order - measured on 2196 it compares with trailing
# blanks TRIMMED and then by code point ('a' = 'a ' < 'a<TAB>'), and its
# DISTINCT / GROUP BY fold 'a' with 'a ' - which is exactly this server's
# plain comparison, so it is keyable here as it stands.
#
# And EVERY `COLLATE` written without a CHARACTER SET refused in column,
# domain and ALTER TABLE ADD definitions: it resolved against NONE, where
# the engine resolves it against the DATABASE's default set.
#
# Recorded: UTF8's DEFAULT collation pads with blanks ('a<TAB>' < 'a'),
# where this server trims - a character below the blank orders differently.
#
#   qa/serve-real-ucsbasic.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4640}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/ucsb-eng-$PORT.fdb"; FC="$D/ucsb-fc-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b -ch UTF8 > /tmp/ucsb-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/ucsb-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-ucsb-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch "${3:-UTF8}" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ -z "$2" ]; then echo "FAIL $1 [the engine answered nothing]"; fail=1
    elif [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
both() { check "$1" "$(run "127.0.0.1/$REAL:$ENG" "$2" "${3:-UTF8}")" "$(run "127.0.0.1/$PORT:$FC" "$2" "${3:-UTF8}")"; }

rec() { # <label> <sql> <engine> <this server>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2" | tr '\n' '|'); c=$(run "127.0.0.1/$PORT:$FC" "$2" | tr '\n' '|')
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - now agrees; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}

echo "--- 1 a COLLATE with no CHARACTER SET takes the database's set"
both "1 columns, a domain, an ALTER TABLE ADD; UCS_BASIC and UNICODE_CI bare" "CREATE DOMAIN DU AS VARCHAR(10) COLLATE UCS_BASIC;
CREATE TABLE U (B VARCHAR(10) COLLATE UCS_BASIC, P VARCHAR(10), C CHAR(5) COLLATE UCS_BASIC, DD DU, CI VARCHAR(10) COLLATE UNICODE_CI);
ALTER TABLE U ADD X VARCHAR(10) COLLATE UCS_BASIC;
CREATE TABLE U8 (B VARCHAR(10) CHARACTER SET UTF8 COLLATE UCS_BASIC);
COMMIT;
SELECT TRIM(RF.RDB\$FIELD_NAME), F.RDB\$CHARACTER_SET_ID, F.RDB\$COLLATION_ID, RF.RDB\$COLLATION_ID FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'U' ORDER BY RF.RDB\$FIELD_POSITION;"
both "1 the rows" "INSERT INTO U (B, P, C, DD, CI, X) VALUES ('a', 'a', 'a', 'a', 'Apple', 'a');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('a ', 'a ', 'a', 'a ', 'APPLE', 'a ');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('a'||ASCII_CHAR(9), 'a'||ASCII_CHAR(9), 'b', 'b', 'banana', 'b');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('é', 'é', 'é', 'é', 'apple', 'é');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('z', 'z', 'z', 'z', 'Zed', 'z');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('Café', 'Café', 'CAFE', 'Café', 'zed', 'Café');
INSERT INTO U (B, P, C, DD, CI, X) VALUES ('cafe', 'cafe', 'cafe', 'cafe', 'Banana', 'cafe');
COMMIT;"

echo "--- 2 UCS_BASIC: trailing blanks trimmed, then code points"
both "2 equality, ranges, LIKE" "SELECT COUNT(*) N FROM U WHERE B = 'a'; SELECT COUNT(*) N FROM U WHERE B = 'cafe'; SELECT COUNT(*) FROM U WHERE B > 'a' AND B < 'z'; SELECT COUNT(*) FROM U WHERE C = 'a   '; SELECT UPPER(B) FROM U WHERE B LIKE 'c%' ORDER BY 1;"
both "2 ORDER BY (blank-trimmed code points; ties by the second key)" "SELECT HEX_ENCODE(B) FROM U ORDER BY B, P; SELECT HEX_ENCODE(DD) FROM U ORDER BY DD, B; SELECT HEX_ENCODE(X) FROM U ORDER BY X DESC, B;"
both "2 DISTINCT and GROUP BY fold 'a' with 'a '" "SELECT COUNT(DISTINCT B) N, COUNT(DISTINCT P) M FROM U; SELECT B, COUNT(*) FROM U GROUP BY B ORDER BY 1; SELECT DISTINCT B FROM U ORDER BY 1;"
both "2 MIN / MAX" "SELECT MIN(B), MAX(B), MIN(X), MAX(DD) FROM U;"
both "2 a bare UNICODE_CI column is the CI order" "SELECT COUNT(*) FROM U WHERE CI = 'apple'; SELECT CI FROM U ORDER BY CI, B;"

echo "--- 3 RECORDED: UTF8's DEFAULT collation PADS with blanks"
rec "3 RECORDED ORDER BY a default-collation column: 'a<TAB>' sorts before 'a' on the engine" \
    "SELECT HEX_ENCODE(P) FROM U WHERE P STARTING WITH 'a' ORDER BY P, B;" 'HEX_ENCODE|================================================================================|6109|61|6120|X|======|DONE|' 'HEX_ENCODE|================================================================================|61|6120|6109|X|======|DONE|'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-ucsb-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 9 on the 2026-10-05 binary, 9 OK
if [ "$ran" -lt 9 ]; then echo "FAIL only $ran checks ran (floor 9) - cells went missing"; fail=1; fi
exit $fail
