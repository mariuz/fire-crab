#!/bin/bash
# THE VIRTUAL SYSTEM RELATIONS RDB$TIME_ZONES AND RDB$KEYWORDS. The engine
# computes their rows (RDB$RELATION_TYPE 3, like MON$): the zone list and
# the parser's keyword table. This server scanned their EMPTY storage and
# answered no rows - COUNT 0 where the engine counts 638 and 529 - and
# its own zone list lacked the newest zone, America/Coyhaique (64898), so
# the engine's TIMESTAMP '.. America/Coyhaique' was refused here too.
#
# Measured on 6.0.0.2196: RDB$TIME_ZONES is (INTEGER id, CHAR(63) UTF8
# name, blank-padded), scanned in list order from GMT (65535) down;
# RDB$KEYWORDS is (VARCHAR(63) ASCII, BOOLEAN reserved), scanned in name
# order, 233 reserved. The keyword table is GENERATED from the engine
# (crates/ods/src/keywords.rs). RDB$CONFIG (the server's configuration,
# 70 rows of this host's firebird.conf) is RECORDED, not served. And a
# SUBQUERY over any computed relation - MON$ included - walked its empty
# storage: `3 IN (SELECT MON$SQL_DIALECT FROM MON$DATABASE)` was false.
#
#   qa/serve-real-virtualrel.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-6130}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/vrel-eng-$PORT.fdb"; FC="$D/vrel-fc-$PORT.fdb"
LOG="/tmp/fc-serve-vrel-$PORT.log"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INT, S VARCHAR(40));
INSERT INTO T VALUES (1, 'Europe/Kyiv'); INSERT INTO T VALUES (2, 'SELECT'); INSERT INTO T VALUES (3, 'nope');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/vrel-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/vrel-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "$LOG" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" 2>/dev/null; rm -f "$ENG" "$FC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/^ *//; s/ *$//' | tr '\n' '|'; }
# both <label> <sql> <a fragment the ENGINE's answer must contain>: the
# fragment keeps a cell that measures nothing from passing
both() {
    ran=$((ran + 1))
    local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    case "$e" in *"$3"*) ;; *) echo "FAIL $1 - THE ENGINE ANSWERS [$e], without [$3]"; fail=1; return;; esac
    if [ "$c" != "$e" ]; then echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1
    else echo "OK   $1"; fi
}
rec() {
    ran=$((ran + 1))
    local e c; e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$e], not the pinned [$3]"; fail=1
    elif [ "$c" = "$e" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$c" != "$4" ]; then echo "FAIL $1 - this server answers [$c], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded)"; fi
}

echo "--- 1 RDB\$TIME_ZONES"
both "1 the describe and the first rows, in list order" "SET SQLDA_DISPLAY ON; SELECT FIRST 3 * FROM RDB\$TIME_ZONES;" "|65534 ACT|"
both "1 COUNT / MIN / MAX of the ids (638 rows)" "SELECT COUNT(*), MIN(RDB\$TIME_ZONE_ID), MAX(RDB\$TIME_ZONE_ID) FROM RDB\$TIME_ZONES;" "638 64898 65535"
both "1 the newest zone, America/Coyhaique" "SELECT RDB\$TIME_ZONE_ID, TRIM(RDB\$TIME_ZONE_NAME) FROM RDB\$TIME_ZONES WHERE RDB\$TIME_ZONE_ID = 64898;" "America/Coyhaique"
both "1 ...and a literal in it now parses" "SELECT CAST(TIMESTAMP '2026-01-15 12:00:00 America/Coyhaique' AS VARCHAR(60)) FROM RDB\$DATABASE;" "America/Coyhaique"
both "1 a lookup by name" "SELECT RDB\$TIME_ZONE_ID FROM RDB\$TIME_ZONES WHERE RDB\$TIME_ZONE_NAME = 'Europe/Kyiv';" "64900"
both "1 the CHAR(63) is blank-padded" "SELECT CHAR_LENGTH(RDB\$TIME_ZONE_NAME), OCTET_LENGTH(RDB\$TIME_ZONE_NAME) FROM RDB\$TIME_ZONES WHERE RDB\$TIME_ZONE_ID = 65535;" "63 63"
both "1 a sort with a window" "SELECT FIRST 3 SKIP 600 RDB\$TIME_ZONE_NAME FROM RDB\$TIME_ZONES ORDER BY RDB\$TIME_ZONE_NAME DESC;" "Africa"
both "1 joined to a user table" "SELECT T.ID, Z.RDB\$TIME_ZONE_ID FROM T JOIN RDB\$TIME_ZONES Z ON Z.RDB\$TIME_ZONE_NAME = T.S;" "64900"
both "1 an IN subquery over it" "SELECT ID FROM T WHERE S IN (SELECT RDB\$TIME_ZONE_NAME FROM RDB\$TIME_ZONES) ORDER BY 1;" "|1|"
both "1 grouped by region" "SELECT FIRST 4 SUBSTRING(RDB\$TIME_ZONE_NAME FROM 1 FOR POSITION('/' IN RDB\$TIME_ZONE_NAME) - 1) AS R, COUNT(*) FROM RDB\$TIME_ZONES WHERE RDB\$TIME_ZONE_NAME CONTAINING '/' GROUP BY 1 ORDER BY 2 DESC, 1;" "America"

echo "--- 2 RDB\$KEYWORDS"
both "2 the describe and the first rows" "SET SQLDA_DISPLAY ON; SELECT FIRST 4 * FROM RDB\$KEYWORDS;" "ABSOLUTE"
both "2 reserved / not reserved" "SELECT RDB\$KEYWORD_RESERVED, COUNT(*) FROM RDB\$KEYWORDS GROUP BY 1;" "<true> 233"
both "2 a prefix" "SELECT RDB\$KEYWORD_NAME, RDB\$KEYWORD_RESERVED FROM RDB\$KEYWORDS WHERE RDB\$KEYWORD_NAME STARTING WITH 'SEL' ORDER BY 1;" "SELECT <true>"
both "2 a BOOLEAN column as the WHERE" "SELECT COUNT(*) FROM RDB\$KEYWORDS WHERE RDB\$KEYWORD_RESERVED;" "233"
both "2 the last rows" "SELECT FIRST 3 SKIP 526 RDB\$KEYWORD_NAME FROM RDB\$KEYWORDS;" "ZONE"
both "2 joined to a user table" "SELECT T.ID, K.RDB\$KEYWORD_RESERVED FROM T JOIN RDB\$KEYWORDS K ON K.RDB\$KEYWORD_NAME = T.S;" "2 <true>"
both "2 NOT EXISTS against it" "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM RDB\$KEYWORDS K WHERE K.RDB\$KEYWORD_NAME = UPPER(T.S)) ORDER BY 1;" "|1|"
both "2 the two relations joined to each other: nothing shared" "SELECT COUNT(*) FROM RDB\$KEYWORDS K JOIN RDB\$TIME_ZONES Z ON Z.RDB\$TIME_ZONE_NAME = K.RDB\$KEYWORD_NAME;" "COUNT"

echo "--- 4 a subquery over ANY computed relation read its empty storage (MON\$ too)"
both "4 IN (SELECT .. FROM MON\$DATABASE)" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 3 IN (SELECT MON\$SQL_DIALECT FROM MON\$DATABASE);" "|1|"
both "4 EXISTS over MON\$DATABASE" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE EXISTS (SELECT 1 FROM MON\$DATABASE WHERE MON\$SQL_DIALECT = 3);" "|1|"
echo "--- 3 RECORDED: RDB\$CONFIG (this host's configuration) is not served"
rec "3 RECORDED RDB\$CONFIG answers no rows here" "SELECT COUNT(*) FROM RDB\$CONFIG;" "COUNT|=====================|70|X|======|DONE|" "COUNT|=====================|0|X|======|DONE|"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "$LOG"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 22 ]; then echo "FAIL only $ran checks ran (floor 22) - cells went missing"; fail=1; fi
exit $fail
