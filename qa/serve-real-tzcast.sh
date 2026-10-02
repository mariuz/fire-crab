#!/bin/bash
# CAST INTO A WITH TIME ZONE TYPE, EXTRACT(TIMEZONE_NAME), THE SESSION
# ZONE'S CONTEXT KEY - AND THE EXTRACT ERROR THAT NAMED A TABLE.
#
# The recorded boundaries of the session-clock round, measured and closed:
#
#   CAST(x AS TIMESTAMP WITH TIME ZONE)   refused at prepare, in any zone
#   CAST(x AS TIME WITH TIME ZONE)        refused at prepare, in any zone
#   EXTRACT(TIMEZONE_NAME FROM x)         failed as `Table unknown
#                                         "TIMESTAMP"` - a guess at the
#                                         FROM inside the parentheses
#   RDB$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE')
#                                         raised "not found" - a WRONG
#                                         ERROR where the engine answers;
#                                         PARALLEL_WORKERS and
#                                         CLIENT_OS_USER too
#
# and one wider than all of them: EVERY EXTRACT whose part the operand's
# type does not carry (`EXTRACT(HOUR FROM <date>)`, YEAR of a TIME, any
# part of a text or a number) answered that same "Table unknown" guess
# where the engine raises its -105 "Specified EXTRACT part does not
# exist in input datatype" at prepare, and `EXTRACT(YEAR FROM NULL)` -
# NULL on the engine - named a table "NULL".
#
# The cast law, measured (crates/wire/src/server.rs, the Temporal cast
# arms and cvt_text_tz): a zoned source keeps its zone, a zoneless one is
# a wall time in the SESSION zone; a TIME into a TIMESTAMP WITH TIME ZONE
# is dated on the SESSION's current date (a zoned TIME in its own zone);
# a TIMESTAMP gives a TIME its wall time of day; text takes its zone tail
# or the session zone; and the date specials into a TIMESTAMP WITH TIME
# ZONE are the engine's own quirk - MIDNIGHT UTC of the UTC date.
#
# THE GATE CHOOSES ITS FAR ZONE as serve-real-sessionclock.sh does, so a
# cell that must tell the session's date from UTC's always can.
#
# Usage: qa/serve-real-tzcast.sh [port]   (default 4477)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4477}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/tzcast-eng.fdb"; FC="$D/tzcast-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

UH=$(date -u +%-H)
if [ "$UH" -ge 10 ]; then FAR="Pacific/Kiritimati"; else FAR="Pacific/Pago_Pago"; fi
FARDATE=$(TZ=$FAR date +%F); UTCDATE=$(date -u +%F)
[ "$FARDATE" != "$UTCDATE" ] || { echo "FAIL SENTINEL the chosen zone $FAR is on the UTC date ($UTCDATE)"; exit 1; }
[ -e /usr/share/zoneinfo/$FAR ] || [ -n "${TZDIR:-}" ] || { echo "SKIP this host has no TZif file for $FAR"; exit 0; }

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, TS TIMESTAMP, DT DATE, TM TIME, TSZ TIMESTAMP WITH TIME ZONE, TMZ TIME WITH TIME ZONE, V VARCHAR(40));
CREATE TABLE Z (ID INTEGER, X TIMESTAMP WITH TIME ZONE, Y TIME WITH TIME ZONE);
INSERT INTO T VALUES (1, '2026-07-01 10:00:00', '2026-07-01', '10:00:00', '2026-07-01 10:00:00 Europe/Paris', '10:00:00 +05:00', '2026-07-01 10:00:00');
INSERT INTO T VALUES (2, '2026-01-15 23:30:00', '2026-01-15', '23:30:00', '2026-01-15 23:30:00 UTC', '23:30:00 America/New_York', '2026-01-15 23:30:00 +05:00');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL, NULL);
CREATE TABLE CO (ID INTEGER, X TIMESTAMP WITH TIME ZONE, Y TIME WITH TIME ZONE);
CREATE TABLE CI (ID INTEGER, X TIMESTAMP WITH TIME ZONE, Y TIME WITH TIME ZONE);
INSERT INTO CO VALUES (1, '2026-07-01 10:00 Europe/Paris', '10:00 +05:00');
INSERT INTO CO VALUES (2, '2026-07-01 10:00 UTC', '11:00 UTC');
INSERT INTO CI VALUES (10, '2026-07-01 08:00 UTC', '05:00 UTC');
INSERT INTO CI VALUES (20, '2026-07-01 10:00 +00:00', '12:00 UTC');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/tzcast-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/tzcast-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/tzcast-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-tzcast-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# both raise, with DIFFERENT errors - recorded (the class is right)
err_differs() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" = "$ev" ] || [ "${fv#*SQLSTATE}" = "$fv" ]; then
        echo "FAIL $1 - both must raise (eng=[$ev] fc=[$fv])"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THE ERRORS NOW AGREE; promote the cell"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:90}], this server [${fv:0:90}])"; fi
}
B="SET TIME ZONE 'Europe/Bucharest';"
F="SET TIME ZONE '$FAR';"
DUAL='FROM RDB$DATABASE'
echo "OK   SENTINEL [zone $FAR: $FARDATE | UTC $UTCDATE]"

echo "--- 1. INTO TIMESTAMP WITH TIME ZONE: a zoneless value is a wall time in the session zone"
pin  "1 TIMESTAMP, summer"  "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 Europe/Bucharest"
pin  "1 ...its instant"     "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|2026-09-08 07:00:00.0000 UTC"
pin  "1 ...winter"          "$B SELECT CAST(TIMESTAMP '2026-01-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|2026-01-08 08:00:00.0000 UTC"
pin  "1 ...the spring gap"  "$B SELECT CAST(TIMESTAMP '2026-03-29 03:30:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-03-29 04:30:00.0000 Europe/Bucharest"
pin  "1 ...an offset session" "SET TIME ZONE '+05:00'; SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 +05:00"
pin  "1 DATE is midnight"   "$B SELECT CAST(DATE '2026-09-08' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 00:00:00.0000 Europe/Bucharest"
pin  "1 a zoned TIMESTAMP keeps its zone" "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00 +05:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 +05:00"
pin  "1 a TIME is dated on the SESSION's date" "$F SELECT CAST(CAST(TIME '10:00:00' AS TIMESTAMP WITH TIME ZONE) AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "1 a zoned TIME: its wall time, the session's date, its own zone" "$F SELECT CAST(TIME '20:00:00 -12:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|$FARDATE 20:00:00.0000 -12:00"
pin  "1 ...a region's TIME" "$F SELECT CAST(TIME '10:00:00 Europe/Paris' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|$FARDATE 10:00:00.0000 Europe/Paris"
pin  "1 NULL"               "SELECT CAST(NULL AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|<null>"
pin  "1 a number is 22018"  "SELECT CAST(1 AS TIMESTAMP WITH TIME ZONE) $DUAL;" 'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "1"'

echo "--- 2. TEXT INTO TIMESTAMP WITH TIME ZONE"
pin  "2 no tail: the session zone" "$B SELECT CAST('2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 Europe/Bucharest"
pin  "2 a date-only string is midnight" "$B SELECT CAST('2026-09-08' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 00:00:00.0000 Europe/Bucharest"
pin  "2 an offset tail"     "$B SELECT CAST('2026-09-08 10:00:00 +05:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 +05:00"
pin  "2 a region tail"      "$B SELECT CAST('2026-09-08 10:00:00 America/New_York' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|2026-09-08 14:00:00.0000 UTC"
pin  "2 'TODAY' is MIDNIGHT UTC of the UTC date - the engine's quirk" "$F SELECT CAST('TODAY' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|$UTCDATE 00:00:00.0000 UTC"
pin  "2 ...'TOMORROW'"      "$F SELECT CAST('TOMORROW' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|$(date -u -d tomorrow +%F) 00:00:00.0000 UTC"
pin  "2 ...'YESTERDAY'"     "$F SELECT CAST('YESTERDAY' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|$(date -u -d yesterday +%F) 00:00:00.0000 UTC"
pin  "2 'NOW' is the instant" "$F SELECT DATEDIFF(MINUTE, CAST('NOW' AS TIMESTAMP WITH TIME ZONE), CURRENT_TIMESTAMP) $DUAL;" "DATEDIFF|0"
pin  "2 ...seen as a wall time in the session" "$F SELECT CAST(CAST('NOW' AS TIMESTAMP WITH TIME ZONE) AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "2 garbage is 22018"   "SELECT CAST('bad' AS TIMESTAMP WITH TIME ZONE) $DUAL;" 'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "bad"'

echo "--- 3. INTO TIME WITH TIME ZONE"
pin  "3 TIME: a wall time in the session zone" "$B SELECT CAST(TIME '10:00:00' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 Europe/Bucharest"
pin  "3 ...placed on the base date (+02:00 all year)" "$B SELECT CAST(TIME '10:00:00' AS TIME WITH TIME ZONE) AT TIME ZONE 'UTC' $DUAL;" "AT|08:00:00.0000 UTC"
pin  "3 TIMESTAMP: its time of day" "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 Europe/Bucharest"
pin  "3 a zoned TIMESTAMP: its wall time, its zone (summer)" "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00 Europe/Paris' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 Europe/Paris"
pin  "3 ...(winter)"        "$B SELECT CAST(TIMESTAMP '2026-01-08 10:00:00 Europe/Paris' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 Europe/Paris"
pin  "3 ...UTC"             "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00 UTC' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 UTC"
pin  "3 a zoned TIME keeps its zone" "$B SELECT CAST(TIME '10:00:00 +05:00' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 +05:00"
pin  "3 text, no tail"      "$B SELECT CAST('10:00' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 Europe/Bucharest"
pin  "3 text, a region tail" "$B SELECT CAST('10:00:00 America/New_York' AS TIME WITH TIME ZONE) $DUAL;" "CAST|10:00:00.0000 America/New_York"
pin  "3 'NOW' is the session's wall time" "$B SELECT DATEDIFF(MINUTE, LOCALTIME, CAST(CAST('NOW' AS TIME WITH TIME ZONE) AS TIME)) $DUAL;" "DATEDIFF|0"
pin  "3 'TODAY' is 22018"   "SELECT CAST('TODAY' AS TIME WITH TIME ZONE) $DUAL;" 'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "TODAY"'
pin  "3 a DATE is 22018 on its text" "SELECT CAST(DATE '2026-09-08' AS TIME WITH TIME ZONE) $DUAL;" 'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "2026-09-08"'
pin  "3 ...and a zoned TIME into a DATE" "SELECT CAST(TIME '10:00:00 +05:00' AS DATE) $DUAL;" 'CAST|Statement failed, SQLSTATE = 22018|conversion error from string "10:00:00.0000 +05:00"'

echo "--- 4. A ZONED TIME INTO A ZONELESS TIMESTAMP: dated on the session's date"
pin  "4 TIME '10:00 +05:00' in the far session: 10:00 +05:00 on the session's date, read there" \
     "$F SELECT CAST(TIME '10:00:00 +05:00' AS TIMESTAMP) $DUAL;" "CAST|$(TZ=$FAR date -d "$FARDATE 10:00 +0500" '+%F %T').0000"
same "4 TIME '20:00 -12:00' in Bucharest"   "$B SELECT CAST(TIME '20:00:00 -12:00' AS TIMESTAMP) $DUAL;"

echo "--- 5. THE SPELLINGS"
pin  "5 WITHOUT TIME ZONE is the zoneless type" "SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITHOUT TIME ZONE), CAST(TIME '10:00' AS TIME WITHOUT TIME ZONE) $DUAL;" "CAST CAST|2026-09-08 10:00:00.0000 10:00:00.0000"
same "5 lower case"         "$B select cast(timestamp '2026-09-08 10:00:00' as timestamp with time zone) $DUAL;"
dsame "5 describe: 32754/12 and 32756/8, named CAST" "$B SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE), CAST(TIME '10:00' AS TIME WITH TIME ZONE) $DUAL;"

echo "--- 6. OVER A TABLE"
pin  "6 CAST(<col> AS TIMESTAMP WITH TIME ZONE) per row" "$B SELECT ID, CAST(TS AS TIMESTAMP WITH TIME ZONE) FROM T ORDER BY ID;" \
     "ID CAST|1 2026-07-01 10:00:00.0000 Europe/Bucharest|2 2026-01-15 23:30:00.0000 Europe/Bucharest|3 <null>"
pin  "6 ...from a text column" "$B SELECT ID, CAST(V AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC' FROM T ORDER BY ID;" \
     "ID AT|1 2026-07-01 07:00:00.0000 UTC|2 2026-01-15 18:30:00.0000 UTC|3 <null>"
pin  "6 ...TIME WITH TIME ZONE of a zoned column" "$B SELECT ID, CAST(TSZ AS TIME WITH TIME ZONE) FROM T ORDER BY ID;" \
     "ID CAST|1 10:00:00.0000 Europe/Paris|2 23:30:00.0000 UTC|3 <null>"
pin  "6 in WHERE, by instant" "$B SELECT ID FROM T WHERE CAST(TS AS TIMESTAMP WITH TIME ZONE) = TIMESTAMP '2026-07-01 07:00:00 UTC';" "ID|1"
pin  "6 in ORDER BY"        "$B SELECT ID FROM T WHERE ID < 3 ORDER BY CAST(TM AS TIME WITH TIME ZONE) DESC;" "ID|2|1"
pin  "6 INSERT ... CAST, read back" \
     "$B INSERT INTO Z VALUES (1, CAST(TIMESTAMP '2026-07-01 10:00:00' AS TIMESTAMP WITH TIME ZONE), CAST(TIME '10:00' AS TIME WITH TIME ZONE)); SELECT X, Y FROM Z; ROLLBACK;" \
     "X Y|2026-07-01 10:00:00.0000 Europe/Bucharest 10:00:00.0000 Europe/Bucharest"

echo "--- 7. EXTRACT(TIMEZONE_NAME)"
pin  "7 a region"           "SELECT EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2026-09-08 10:00:00 Europe/Bucharest') $DUAL;" "EXTRACT|Europe/Bucharest"
pin  "7 an offset"          "SELECT EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2026-09-08 10:00:00 +05:00') $DUAL;" "EXTRACT|+05:00"
pin  "7 -00:00 is +00:00, GMT is GMT, Etc/GMT+5 its own" \
     "SELECT EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2020-01-01 10:00 -00:00'), EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2020-01-01 10:00 GMT'), EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2020-01-01 10:00 Etc/GMT+5') $DUAL;" \
     "EXTRACT EXTRACT EXTRACT|+00:00 GMT Etc/GMT+5"
pin  "7 a TIME WITH TIME ZONE" "SELECT EXTRACT(TIMEZONE_NAME FROM TIME '10:00:00 UTC') $DUAL;" "EXTRACT|UTC"
pin  "7 a ZONELESS value answers the session zone" "SET TIME ZONE 'America/New_York'; SELECT EXTRACT(TIMEZONE_NAME FROM LOCALTIMESTAMP), EXTRACT(TIMEZONE_NAME FROM TIME '10:00') $DUAL;" "EXTRACT EXTRACT|America/New_York America/New_York"
pin  "7 CURRENT_TIMESTAMP"  "$B SELECT EXTRACT(TIMEZONE_NAME FROM CURRENT_TIMESTAMP) $DUAL;" "EXTRACT|Europe/Bucharest"
pin  "7 per row"            "SELECT ID, EXTRACT(TIMEZONE_NAME FROM TSZ), EXTRACT(TIMEZONE_NAME FROM TMZ) FROM T ORDER BY ID;" \
     "ID EXTRACT EXTRACT|1 Europe/Paris +05:00|2 UTC America/New_York|3 <null> <null>"
pin  "7 NULL"               "SELECT EXTRACT(TIMEZONE_NAME FROM NULL) $DUAL;" "EXTRACT|<null>"
dsame "7 describe: VARCHAR(32) CHARACTER SET ASCII" "SELECT EXTRACT(TIMEZONE_NAME FROM CURRENT_TIMESTAMP), EXTRACT(TIMEZONE_NAME FROM TSZ) FROM T;"
pin  "7 a DATE is -105"     "SELECT EXTRACT(TIMEZONE_NAME FROM DATE '2020-01-01') $DUAL;" \
     'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -105|-Specified EXTRACT part does not exist in input datatype'

echo "--- 8. EVERY EXTRACT MISMATCH IS THE ENGINE'S -105 (it named a table)"
E105='Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -105|-Specified EXTRACT part does not exist in input datatype'
pin  "8 HOUR of a DATE literal" "SELECT EXTRACT(HOUR FROM DATE '2020-01-01') $DUAL;" "$E105"
pin  "8 HOUR of a DATE column" "SELECT EXTRACT(HOUR FROM DT) FROM T;" "$E105"
pin  "8 YEAR of a TIME column" "SELECT EXTRACT(YEAR FROM TM) FROM T;" "$E105"
pin  "8 WEEK of a TIME literal" "SELECT EXTRACT(WEEK FROM TIME '10:00') $DUAL;" "$E105"
pin  "8 TIMEZONE_HOUR of a DATE" "SELECT EXTRACT(TIMEZONE_HOUR FROM DT) FROM T;" "$E105"
pin  "8 YEAR of text"       "SELECT EXTRACT(YEAR FROM '2020-01-01') $DUAL;" "$E105"
pin  "8 YEAR of a text column" "SELECT EXTRACT(YEAR FROM V) FROM T;" "$E105"
pin  "8 YEAR of a number"   "SELECT EXTRACT(YEAR FROM 1) $DUAL;" "$E105"
pin  "8 in WHERE"           "SELECT ID FROM T WHERE EXTRACT(HOUR FROM DT) = 1;" "$E105"
pin  "8 YEAR of NULL is NULL (it named a table \"NULL\")" "SELECT EXTRACT(YEAR FROM NULL), EXTRACT(SECOND FROM NULL) $DUAL;" "EXTRACT EXTRACT|<null> <null>"
dsame "8 ...described SHORT and LONG(-4)" "SELECT EXTRACT(YEAR FROM NULL), EXTRACT(SECOND FROM NULL) $DUAL;"
pin  "8 CONTROL a valid part" "SELECT EXTRACT(HOUR FROM CAST(DT AS TIMESTAMP)) FROM T WHERE ID = 1;" "EXTRACT|0"

echo "--- 9. THE SYSTEM CONTEXT: the session zone, and two keys that raised 'not found'"
pin  "9 SESSION_TIMEZONE, a region" "$B SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE') $DUAL;" "RDB\$GET_CONTEXT|Europe/Bucharest"
pin  "9 ...an offset"       "SET TIME ZONE '+05:00'; SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE') $DUAL;" "RDB\$GET_CONTEXT|+05:00"
pin  "9 ...'utc' is UTC"    "SET TIME ZONE 'utc'; SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE') $DUAL;" "RDB\$GET_CONTEXT|UTC"
same "9 ...LOCAL is the host's" "SET TIME ZONE '+05:00'; SET TIME ZONE LOCAL; SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE') $DUAL;"
pin  "9 PARALLEL_WORKERS"   "SELECT RDB\$GET_CONTEXT('SYSTEM', 'PARALLEL_WORKERS') $DUAL;" "RDB\$GET_CONTEXT|1"
pin  "9 CONTROL an unknown key still raises" "SELECT RDB\$GET_CONTEXT('SYSTEM', 'OWNER_NAME') $DUAL;" \
     "RDB\$GET_CONTEXT|Statement failed, SQLSTATE = HY000|Context variable 'OWNER_NAME' is not found in namespace 'SYSTEM'"

echo "--- 10. A PLAN MUST NOT KEEP THE OLD ZONE (the same text across SET TIME ZONE)"
Q="SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE'), EXTRACT(TIMEZONE_NAME FROM LOCALTIMESTAMP), CAST(TIMESTAMP '2020-07-01 10:00' AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE 'UTC', CAST('10:00' AS TIME WITH TIME ZONE) $DUAL;"
pin  "10 Bucharest, then New York" "$B $Q SET TIME ZONE 'America/New_York'; $Q" \
     "RDB\$GET_CONTEXT EXTRACT AT CAST|Europe/Bucharest Europe/Bucharest 2020-07-01 07:00:00.0000 UTC 10:00:00.0000 Europe/Bucharest|RDB\$GET_CONTEXT EXTRACT AT CAST|America/New_York America/New_York 2020-07-01 14:00:00.0000 UTC 10:00:00.0000 America/New_York"

echo "--- 11. A ZONED KEY IS EQUAL BY INSTANT, in every equality context"
# CO and CI hold the SAME instants under DIFFERENT zones (Paris 10:00 is
# 08:00 UTC; 10:00 UTC is 10:00 +00:00).  The correlated scalar's lookup
# table compared the zone id as well, so it found no partner and answered
# NULL where the engine answers the row - a wrong answer older than this
# round (the previous binaries answer it too).
pin  "11 a correlated scalar over a zoned key (answered NULL)" \
     "SELECT ID, (SELECT MAX(CI.ID) FROM CI WHERE CI.X = CO.X) FROM CO ORDER BY ID;" "ID MAX|1 10|2 20"
pin  "11 ...an aggregate over it" "SELECT ID, (SELECT COUNT(*) FROM CI WHERE CI.X < CO.X) FROM CO ORDER BY ID;" "ID COUNT|1 0|2 1"
pin  "11 a join"            "SELECT CO.ID, CI.ID FROM CO JOIN CI ON CI.X = CO.X ORDER BY 1;" "ID ID|1 10|2 20"
pin  "11 a LEFT join on a TIME WITH TIME ZONE" "SELECT CO.ID, CI.ID FROM CO LEFT JOIN CI ON CI.Y = CO.Y ORDER BY 1;" "ID ID|1 10|2 <null>"
pin  "11 an IN list"        "SELECT ID FROM CO WHERE X IN (TIMESTAMP '2026-07-01 08:00 UTC', TIMESTAMP '2026-07-01 10:00 +00:00') ORDER BY ID;" "ID|1|2"
pin  "11 CASE, DECODE, NULLIF" \
     "SELECT ID, CASE X WHEN TIMESTAMP '2026-07-01 08:00 UTC' THEN 'hit' ELSE 'miss' END, DECODE(X, TIMESTAMP '2026-07-01 08:00 UTC', 'one', 'other'), NULLIF(X, TIMESTAMP '2026-07-01 08:00 UTC') FROM CO ORDER BY ID;" \
     "ID CASE DECODE CASE|1 hit one <null>|2 miss other 2026-07-01 10:00:00.0000 UTC"
pin  "11 IS NOT DISTINCT FROM" "SELECT ID FROM CO WHERE X IS NOT DISTINCT FROM TIMESTAMP '2026-07-01 08:00 UTC';" "ID|1"

echo "--- 12. RECORDED"
# the engine answers, this server refuses cleanly - never a wrong answer
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - the ENGINE answers [$ev], not [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - this server answers [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
refused "12 a correlated EXISTS over a zoned key" "SELECT ID FROM CO WHERE EXISTS (SELECT 1 FROM CI WHERE CI.Y = CO.Y) ORDER BY ID;" "ID|1"
refused "12 IN (<subquery>) over a zoned key" "SELECT ID FROM CO WHERE CO.X IN (SELECT X FROM CI) ORDER BY ID;" "ID|1|2"
# CLIENT_OS_USER: the engine names the client's OS user; this server has
# no faithful source for it and answers NULL, as for CLIENT_HOST - the key
# is VALID, so it no longer raises
ran=$((ran + 1))
fv=$(sess "127.0.0.1/$PORT:$FC" "SELECT RDB\$GET_CONTEXT('SYSTEM', 'CLIENT_OS_USER') $DUAL;")
if [ "$fv" = "RDB\$GET_CONTEXT|<null>" ]; then echo "OK   12 CLIENT_OS_USER is a valid key: NULL here, the OS user on the engine (recorded)"
else echo "FAIL 12 CLIENT_OS_USER answered [$fv]"; fail=1; fi
err_differs "12 a TIMESTAMP string into TIME WITH TIME ZONE: the engine reads '-09-08 ...' as an OFFSET (22009), this server 22018" \
     "SELECT CAST('2026-09-08 10:00:00 Europe/Paris' AS TIME WITH TIME ZONE) $DUAL;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-tzcast-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-tzcast-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
[ "$(TZ=$FAR date +%F)" = "$FARDATE" ] && [ "$(date -u +%F)" = "$UTCDATE" ] || { echo "FAIL the run straddled a midnight - rerun"; fail=1; }

echo "ran $ran checks"
if [ "$ran" -lt 86 ]; then echo "FAIL only $ran checks ran (floor 86) - cells went missing"; fail=1; fi
exit $fail
