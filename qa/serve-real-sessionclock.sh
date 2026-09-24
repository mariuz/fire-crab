#!/bin/bash
# THE ZONELESS CLOCK IS THE SESSION'S WALL CLOCK, IN A RULED ZONE TOO.
#
# CURRENT_DATE, LOCALTIME, LOCALTIMESTAMP and the text specials 'TODAY',
# 'NOW', 'YESTERDAY', 'TOMORROW' all read the request's instant in the
# SESSION time zone.  This server knew the zone NAMES but not their rules,
# so every session in a named zone - the default one, on any host whose
# zone is not UTC - read GMT:
#
#   host Europe/Bucharest at 01:44 EEST (22:44 UTC the day before)
#   CURRENT_DATE             engine 2026-09-24   here 2026-09-23
#   EXTRACT(HOUR FROM LOCALTIME)  engine 1       here 22   (three hours
#                                                 behind, ALL day)
#   DT = 'TODAY'             engine row 1        here row 2
#
# The rules now come from the host's TZif files (crates/ods/src/tz.rs).
# Measured with it: SET TIME ZONE to a named region was REFUSED here, a
# TIME cast to TIMESTAMP and a zoned value cast to a zoneless type raised
# 22018 on their own render, and a cached plan kept the first prepare's
# clock across a SET TIME ZONE.  And the other direction, a WALL time in
# a region onto the UTC line (§7), refused everywhere - except where a
# zoneless side met a zoned one in a region session, where it was a wrong
# answer: `TIMESTAMP '2026-09-08 10:00' - TIMESTAMP '2026-01-01 00:00
# +00:00'` answered 0.000000000 (serve-real-tempdiff.sh, red on a host
# whose zone is a region).
#
# THE GATE MUST NOT TRUST THE CLOCK TO SHOW THE BUG: a date-shaped defect
# only shows while the local and UTC dates differ.  So it CHOOSES the
# zone: Pacific/Kiritimati (UTC+14) when the UTC hour is 10 or later,
# Pacific/Pago_Pago (UTC-11) before - in either the local date is never
# the UTC date - and it asserts that before any cell runs.  Expected
# dates come from the host (`TZ=<zone> date`), the engine is pinned to
# them, and this server is held to the engine.
#
# Usage: qa/serve-real-sessionclock.sh [port]   (default 4476)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4476}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/sclock-eng.fdb"; FC="$D/sclock-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

UH=$(date -u +%-H)
if [ "$UH" -ge 10 ]; then FAR="Pacific/Kiritimati"; OTHER="Pacific/Pago_Pago"
else FAR="Pacific/Pago_Pago"; OTHER="Pacific/Kiritimati"; fi
FARDATE=$(TZ=$FAR date +%F); UTCDATE=$(date -u +%F); OTHERDATE=$(TZ=$OTHER date +%F)
FARYEST=$(TZ=$FAR date -d yesterday +%F); FARTOM=$(TZ=$FAR date -d tomorrow +%F)
HOSTDATE=$(date +%F)
BUCDATE=$(TZ=Europe/Bucharest date +%F)
[ "$FARDATE" != "$UTCDATE" ] || { echo "FAIL SENTINEL the chosen zone $FAR is on the UTC date ($UTCDATE) - the gate would measure nothing"; exit 1; }
[ "$FARDATE" != "$OTHERDATE" ] || { echo "FAIL SENTINEL $FAR and $OTHER share a date"; exit 1; }
[ -e /usr/share/zoneinfo/$FAR ] || [ -n "${TZDIR:-}" ] || { echo "SKIP this host has no TZif file for $FAR"; exit 0; }

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<SQL
CREATE TABLE T (ID INTEGER, DT DATE, TS TIMESTAMP, TM TIME);
CREATE TABLE DF (ID INTEGER, DT DATE DEFAULT CURRENT_DATE, TS TIMESTAMP DEFAULT LOCALTIMESTAMP);
INSERT INTO T VALUES (1, '$FARDATE', '$FARDATE 00:00:00', '12:30:00');
INSERT INTO T VALUES (2, '$UTCDATE', '$UTCDATE 00:00:00', '01:02:03');
INSERT INTO T VALUES (3, '2020-01-15', '2020-01-15 10:20:30', '10:20:30');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/sclock-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/sclock-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/sclock-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-sclock-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# run a SCRIPT (a session: SET TIME ZONE carries to the statements after
# it) and print its data lines, one per line, blanks squeezed
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the ENGINE pinned to what the host clock says, and this server held to
# the engine. <label> <script> <expected-engine-output>
pin() {
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then
        echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# engine and this server agree, nothing pinned (a value the host clock
# cannot predict to the second)
same() {
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the engine answers and this server refuses - recorded
eng_refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - the ENGINE answers [$ev], not [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - this server answers [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
Z="SET TIME ZONE '$FAR';"
DUAL='FROM RDB$DATABASE'
echo "OK   SENTINEL [zone $FAR: $FARDATE | UTC $UTCDATE | $OTHER: $OTHERDATE]"

echo "--- 1. THE CLOCK KEYWORDS read the session's wall clock"
pin  "1 CURRENT_DATE"                       "$Z SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$FARDATE"
pin  "1 CAST(LOCALTIMESTAMP AS DATE)"       "$Z SELECT CAST(LOCALTIMESTAMP AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "1 CAST(CURRENT_TIMESTAMP AS DATE) - a zoned instant into a DATE (raised 22018 here)" "$Z SELECT CAST(CURRENT_TIMESTAMP AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "1 CURRENT_DATE - CAST(LOCALTIMESTAMP AS DATE) - the two clocks agree" "$Z SELECT CURRENT_DATE - CAST(LOCALTIMESTAMP AS DATE) $DUAL;" "SUBTRACT|0"
same "1 EXTRACT(HOUR FROM LOCALTIME) - was UTC's hour all day" "$Z SELECT EXTRACT(HOUR FROM LOCALTIME) $DUAL;"
same "1 EXTRACT(HOUR FROM LOCALTIMESTAMP)"  "$Z SELECT EXTRACT(HOUR FROM LOCALTIMESTAMP) $DUAL;"
same "1 EXTRACT(MINUTE FROM LOCALTIME)"     "$Z SELECT EXTRACT(MINUTE FROM LOCALTIME) $DUAL;"
pin  "1 EXTRACT(TIMEZONE_HOUR FROM CURRENT_TIMESTAMP) - an instant's offset in a region" \
     "$Z SELECT EXTRACT(TIMEZONE_HOUR FROM CURRENT_TIMESTAMP) $DUAL;" "EXTRACT|$( [ $FAR = Pacific/Kiritimati ] && echo 14 || echo -11)"
pin  "1 CAST(CURRENT_TIME AS TIME) under an OFFSET zone - a zoned TIME into a TIME (raised 22018 here, offsets too)" \
     "SET TIME ZONE '+05:00'; SELECT DATEDIFF(HOUR, LOCALTIME, CAST(CURRENT_TIME AS TIME)) $DUAL;" "DATEDIFF|0"

echo "--- 2. THE TEXT SPECIALS read the same clock"
pin  "2 CAST('TODAY' AS DATE)"              "$Z SELECT CAST('TODAY' AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "2 CAST('NOW' AS DATE)"                "$Z SELECT CAST('NOW' AS DATE) $DUAL;" "CAST|$FARDATE"
pin  "2 CAST('YESTERDAY' AS DATE)"          "$Z SELECT CAST('YESTERDAY' AS DATE) $DUAL;" "CAST|$FARYEST"
pin  "2 CAST('TOMORROW' AS DATE)"           "$Z SELECT CAST('TOMORROW' AS DATE) $DUAL;" "CAST|$FARTOM"
pin  "2 CAST('TODAY' AS TIMESTAMP)"         "$Z SELECT CAST('TODAY' AS TIMESTAMP) $DUAL;" "CAST|$FARDATE 00:00:00.0000"
pin  "2 DATEDIFF(DAY, 'NOW', CURRENT_DATE)" "$Z SELECT DATEDIFF(DAY, CAST('NOW' AS DATE), CURRENT_DATE) $DUAL;" "DATEDIFF|0"
same "2 EXTRACT(HOUR FROM CAST('NOW' AS TIMESTAMP))" "$Z SELECT EXTRACT(HOUR FROM CAST('NOW' AS TIMESTAMP)) $DUAL;"
pin  "2 CAST(CAST('12:30:00' AS TIME) AS TIMESTAMP) - a TIME is dated today (raised 22018 here)" \
     "$Z SELECT CAST(CAST('12:30:00' AS TIME) AS TIMESTAMP) $DUAL;" "CAST|$FARDATE 12:30:00.0000"

echo "--- 3. ROWS AGAINST THE CLOCK (row 1 holds the zone's today, row 2 UTC's)"
pin  "3 DT = 'TODAY'"                       "$Z SELECT ID FROM T WHERE DT = 'TODAY';" "ID|1"
pin  "3 DT = CURRENT_DATE"                  "$Z SELECT ID FROM T WHERE DT = CURRENT_DATE;" "ID|1"
pin  "3 DT = CAST('TODAY' AS DATE)"         "$Z SELECT ID FROM T WHERE DT = CAST('TODAY' AS DATE);" "ID|1"
pin  "3 DT <> 'TODAY'"                      "$Z SELECT ID FROM T WHERE DT <> 'TODAY' ORDER BY ID;" "ID|2|3"
pin  "3 TS >= 'TODAY'"                      "$Z SELECT ID FROM T WHERE TS >= 'TODAY' ORDER BY ID;" "ID|$( [ "$FARDATE" \> "$UTCDATE" ] && echo 1 || echo '1|2')"
pin  "3 DT = 'YESTERDAY' OR DT = 'TOMORROW' - UTC's date is one of them" \
     "$Z SELECT ID FROM T WHERE DT = 'YESTERDAY' OR DT = 'TOMORROW';" "ID|2"
pin  "3 SUM(IIF(DT = CURRENT_DATE, 1, 0))"  "$Z SELECT SUM(IIF(DT = CURRENT_DATE, 1, 0)) $DUAL CROSS JOIN T;" "SUM|1"
pin  "3 TM dated today: CAST(TM AS TIMESTAMP) of row 1" "$Z SELECT CAST(TM AS TIMESTAMP) FROM T WHERE ID = 1;" "CAST|$FARDATE 12:30:00.0000"

echo "--- 4. A DEFAULT reads the session clock too"
pin  "4 DEFAULT CURRENT_DATE / LOCALTIMESTAMP" \
     "$Z INSERT INTO DF (ID) VALUES (1); SELECT DT, CAST(TS AS DATE) FROM DF WHERE ID = 1; ROLLBACK;" "DT CAST|$FARDATE $FARDATE"

echo "--- 5. SET TIME ZONE TO A REGION, and a plan that must not keep the old one"
pin  "5 SET TIME ZONE '$OTHER' (a region was REFUSED here)" "SET TIME ZONE '$OTHER'; SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$OTHERDATE"
pin  "5 SET TIME ZONE 'Europe/Bucharest'"   "SET TIME ZONE 'Europe/Bucharest'; SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$BUCDATE"
pin  "5 THE SAME TEXT across a zone change - a cached plan kept the first clock" \
     "$Z SELECT CURRENT_DATE $DUAL; SET TIME ZONE '$OTHER'; SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$FARDATE|CURRENT_DATE|$OTHERDATE"
pin  "5 ...and 'TODAY' across it"           "$Z SELECT ID FROM T WHERE DT = 'TODAY'; SET TIME ZONE '$OTHER'; SELECT ID FROM T WHERE DT = 'TODAY';" \
     "ID|1|$( [ "$OTHERDATE" = "$UTCDATE" ] && echo 'ID|2' || echo '')"
same "5 ...and LOCALTIME's hour across it"  "$Z SELECT EXTRACT(HOUR FROM LOCALTIME) $DUAL; SET TIME ZONE '$OTHER'; SELECT EXTRACT(HOUR FROM LOCALTIME) $DUAL;"
pin  "5 SET TIME ZONE LOCAL - the host's own zone" "$Z SET TIME ZONE LOCAL; SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$HOSTDATE"
pin  "5 CONTROL an OFFSET zone, which always converted" "SET TIME ZONE '+14:00'; SELECT CURRENT_DATE $DUAL;" "CURRENT_DATE|$(TZ=Etc/GMT-14 date +%F)"

echo "--- 6. A ZONED VALUE RENDERS in its region's wall time"
pin  "6 winter: UTC 10:20:30 in Europe/Bucharest" \
     "SELECT TIMESTAMP '2020-01-15 10:20:30 UTC' AT TIME ZONE 'Europe/Bucharest' $DUAL;" "AT|2020-01-15 12:20:30.0000 Europe/Bucharest"
pin  "6 summer: +03:00, the rule's other half" \
     "SELECT TIMESTAMP '2020-07-15 10:20:30 UTC' AT TIME ZONE 'Europe/Bucharest' $DUAL;" "AT|2020-07-15 13:20:30.0000 Europe/Bucharest"
pin  "6 across the day: UTC 23:30 in Kiritimati" \
     "SELECT TIMESTAMP '2020-01-15 23:30:00 UTC' AT TIME ZONE 'Pacific/Kiritimati' $DUAL;" "AT|2020-01-16 13:30:00.0000 Pacific/Kiritimati"
pin  "6 the DST edge, 2026-03-29 00:59 UTC is still +02:00" \
     "SELECT TIMESTAMP '2026-03-29 00:59:00 UTC' AT TIME ZONE 'Europe/Bucharest' $DUAL;" "AT|2026-03-29 02:59:00.0000 Europe/Bucharest"
pin  "6 ...and 01:00 UTC is +03:00"         "SELECT TIMESTAMP '2026-03-29 01:00:00 UTC' AT TIME ZONE 'Europe/Bucharest' $DUAL;" "AT|2026-03-29 04:00:00.0000 Europe/Bucharest"
pin  "6 a zoned instant cast to TIMESTAMP goes through the SESSION zone" \
     "$Z SELECT CAST(TIMESTAMP '2020-01-01 00:00 UTC' AS TIMESTAMP) $DUAL;" "CAST|$( [ $FAR = Pacific/Kiritimati ] && echo '2020-01-01 14:00:00.0000' || echo '2019-12-31 13:00:00.0000')"

echo "--- 7. A WALL TIME IN A REGION goes onto the UTC line (local -> UTC)"
# Measured against the engine, Europe/Bucharest 2026: a wall time in the
# spring GAP takes the offset before the switch (03:30 is 01:30 UTC, later
# than 04:00's 01:00), one in the autumn OVERLAP is the FIRST occurrence
# (+03:00), and 1900's LMT +01:44:24 counts in whole minutes.  Before this,
# every one of these refused - and a zoneless side against a zoned one in
# a region session was no refusal: `TS - TSTZ` answered 0.000000000.
B="SET TIME ZONE 'Europe/Bucharest';"
pin  "7 EXTRACT(TIMEZONE_HOUR FROM LOCALTIMESTAMP) - a wall time's offset in the session region" \
     "$Z SELECT EXTRACT(TIMEZONE_HOUR FROM LOCALTIMESTAMP) $DUAL;" "EXTRACT|$( [ $FAR = Pacific/Kiritimati ] && echo 14 || echo -11)"
pin  "7 EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2026-01-10 10:00') - winter" \
     "$B SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2026-01-10 10:00:00') $DUAL;" "EXTRACT|2"
pin  "7 the GAP: 03:30 on 2026-03-29 takes the offset before the switch" \
     "SELECT TIMESTAMP '2026-03-29 03:30:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-03-29 01:30:00.0000 UTC"
pin  "7 ...and 04:00, the first wall time after it" \
     "SELECT TIMESTAMP '2026-03-29 04:00:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-03-29 01:00:00.0000 UTC"
pin  "7 ...and 02:59:59, the last before it" \
     "SELECT TIMESTAMP '2026-03-29 02:59:59 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-03-29 00:59:59.0000 UTC"
pin  "7 the gap's wall time renders back an hour on" \
     "SELECT CAST(TIMESTAMP '2026-03-29 03:30:00 Europe/Bucharest' AS VARCHAR(50)) $DUAL;" "CAST|2026-03-29 04:30:00.0000 Europe/Bucharest"
pin  "7 the OVERLAP: 03:30 on 2026-10-25 is the first occurrence" \
     "SELECT TIMESTAMP '2026-10-25 03:30:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-10-25 00:30:00.0000 UTC"
pin  "7 ...and 04:00, past it" \
     "SELECT TIMESTAMP '2026-10-25 04:00:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-10-25 02:00:00.0000 UTC"
pin  "7 LMT: 1900-01-01 12:00 is 10:16 UTC (whole minutes)" \
     "SELECT TIMESTAMP '1900-01-01 12:00:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|1900-01-01 10:16:00.0000 UTC"
pin  "7 the footer's century: 2100-07-01 is +03:00" \
     "SELECT TIMESTAMP '2100-07-01 12:00:00 Europe/Bucharest' AT TIME ZONE 'UTC' $DUAL;" "AT|2100-07-01 09:00:00.0000 UTC"
pin  "7 a ZONELESS wall time in the session region, AT TIME ZONE" \
     "$B SELECT TIMESTAMP '2026-10-25 03:30:00' AT TIME ZONE 'UTC' $DUAL;" "AT|2026-10-25 00:30:00.0000 UTC"
pin  "7 TIMESTAMP - TSTZ in a region session (answered 0.000000000)" \
     "$B SELECT TIMESTAMP '2026-09-08 10:00:00' - TIMESTAMP '2026-01-01 00:00:00 +00:00' $DUAL;" "SUBTRACT|250.291666667"
pin  "7 TSTZ - TIMESTAMP in a region session (refused)" \
     "$B SELECT TIMESTAMP '2026-09-08 10:00:00 +02:00' - TIMESTAMP '2026-01-01 00:00:00' $DUAL;" "SUBTRACT|250.416666667"
pin  "7 TSTZ = TIMESTAMP in a region session" \
     "$B SELECT IIF(TIMESTAMP '2026-09-08 07:00:00 UTC' = TIMESTAMP '2026-09-08 10:00:00', 1, 0) $DUAL;" "CASE|1"
pin  "7 CONTROL the same difference under an OFFSET zone, which always converted" \
     "SET TIME ZONE '+03:00'; SELECT TIMESTAMP '2026-09-08 10:00:00' - TIMESTAMP '2026-01-01 00:00:00 +00:00' $DUAL;" "SUBTRACT|250.291666667"

echo "--- 8. A TIME IN A REGION sits on the base date 2020-01-01"
# Measured: a TIME WITH TIME ZONE in a region is placed by the zone's
# offset on 2020-01-01 - Bucharest +02:00 in September, New York -05:00,
# Sydney +11:00 (its January is summer), Sao Paulo -03:00 (DST dropped in
# 2019).  Rendering, AT TIME ZONE, comparison, subtraction, EXTRACT and
# CURRENT_TIME all use it; only a CAST into a ZONELESS TIME dates the
# value's wall time TODAY and converts by today's rules (10:00 +02:00 is
# 11:00 in Bucharest in September).  Every cell here refused before.
pin  "8 TIME in Sydney is +11:00 all year (January's offset)" \
     "SELECT TIME '12:00:00 Australia/Sydney' AT TIME ZONE 'UTC' $DUAL;" "AT|01:00:00.0000 UTC"
pin  "8 ...New York -05:00" "SELECT TIME '12:00:00 America/New_York' AT TIME ZONE 'UTC' $DUAL;" "AT|17:00:00.0000 UTC"
pin  "8 ...Sao Paulo -03:00 - no January before 2019" "SELECT TIME '12:00:00 America/Sao_Paulo' AT TIME ZONE 'UTC' $DUAL;" "AT|15:00:00.0000 UTC"
pin  "8 a TIME rendered in a region" "SELECT TIME '23:30:00 UTC' AT TIME ZONE 'Europe/Bucharest' $DUAL;" "AT|01:30:00.0000 Europe/Bucharest"
pin  "8 a zoneless TIME in the session region, AT TIME ZONE" "$B SELECT TIME '12:00:00' AT TIME ZONE 'UTC' $DUAL;" "AT|10:00:00.0000 UTC"
pin  "8 TIME - TIME WITH TIME ZONE in a region session" "$B SELECT TIME '10:00:00' - TIME '09:00:00 UTC' $DUAL;" "SUBTRACT|-3600.0000"
pin  "8 TIME WITH TIME ZONE = TIME in a region session" \
     "$B SELECT IIF(TIME '10:00:00 UTC' = TIME '12:00:00', 1, 0), IIF(TIME '09:00:00 UTC' = TIME '12:00:00', 1, 0) $DUAL;" "CASE CASE|1 0"
pin  "8 EXTRACT(TIMEZONE_HOUR) of a region's TIME, and of a zoneless one" \
     "$B SELECT EXTRACT(TIMEZONE_HOUR FROM TIME '12:00:00 Australia/Sydney'), EXTRACT(TIMEZONE_HOUR FROM TIME '12:00:00') $DUAL;" "EXTRACT EXTRACT|11 2"
pin  "8 CAST(CURRENT_TIME AS TIME) is LOCALTIME in a region" \
     "$Z SELECT DATEDIFF(HOUR, LOCALTIME, CAST(CURRENT_TIME AS TIME)) $DUAL;" "DATEDIFF|0"
pin  "8 ...and in Bucharest, where the base date and today differ" \
     "$B SELECT DATEDIFF(MINUTE, LOCALTIME, CAST(CURRENT_TIME AS TIME)) $DUAL;" "DATEDIFF|0"
same "8 CURRENT_TIME's UTC time is the WALL time through the base date" \
     "$B SELECT EXTRACT(HOUR FROM CURRENT_TIME AT TIME ZONE 'UTC') - EXTRACT(HOUR FROM LOCALTIME) $DUAL;"
same "8 CAST(<zoned TIME> AS TIME) dates it today: 10:00 +02:00" \
     "$B SELECT CAST(TIME '10:00:00 +02:00' AS TIME), CAST(TIME '08:00:00 UTC' AS TIME) $DUAL;"
same "8 ...and a region's TIME, under a third zone" \
     "SET TIME ZONE 'America/New_York'; SELECT CAST(TIME '12:00:00 Australia/Sydney' AS TIME), CAST(TIME '10:00:00 +02:00' AS TIME) $DUAL;"
same "8 ...and the zone-tailed text route" "$B SELECT CAST('10:00:00 +02:00' AS TIME) $DUAL;"

echo "--- 9. RECORDED (the engine answers, this server refuses)"
eng_refused "9 CAST(<timestamp> AS TIMESTAMP WITH TIME ZONE) - a CAST target this server does not type, in any zone" \
            "SET TIME ZONE '+03:00'; SELECT CAST(TIMESTAMP '2026-09-08 10:00:00' AS TIMESTAMP WITH TIME ZONE) $DUAL;" "CAST|2026-09-08 10:00:00.0000 +03:00"
eng_refused "9 RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE')" "SET TIME ZONE '+05:00'; SELECT RDB\$GET_CONTEXT('SYSTEM', 'SESSION_TIMEZONE') $DUAL;" "RDB\$GET_CONTEXT|+05:00"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-sclock-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-sclock-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
# the whole run inside one zone-day: a run that straddled the chosen
# zone's midnight measured two days and says so
[ "$(TZ=$FAR date +%F)" = "$FARDATE" ] || { echo "FAIL the run straddled midnight in $FAR - rerun"; fail=1; }

echo "ran $ran checks"
if [ "$ran" -lt 70 ]; then echo "FAIL only $ran checks ran (floor 70) - cells went missing"; fail=1; fi
exit $fail
