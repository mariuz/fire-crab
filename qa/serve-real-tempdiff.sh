#!/bin/bash
# TEMPORAL SUBTRACTION IS TYPE-DISCIPLINED, AND A TIMESTAMP DIFFERENCE
# ROUNDS THE WAY THE ENGINE DOES.
#
# The engine allows a temporal difference only between operands of the
# SAME family (add_datettime): DATE - DATE (integer days), TIME - TIME
# (seconds, scale 4), and TIMESTAMP - TIMESTAMP (days, scale 9, the
# WITH TIME ZONE spelling mixing freely with the plain one on the UTC
# instant). Every MIXED pair - a DATE against a TIMESTAMP either order,
# a TIME against anything but a TIME - is the engine's "expression
# evaluation not supported / -Invalid data type in DATE/TIME/TIMESTAMP
# addition or subtraction in add_datettime()", SQLSTATE 42000. And
# temporal + temporal is refused whatever the families.
#
# fire-crab used to INVENT a fractional-day number for a DATE-vs-
# TIMESTAMP difference (DATE - TIMESTAMP answered -0.4166..., the engine
# raises) - a confident wrong value. It also TRUNCATED the scale-9
# timestamp difference where the engine rounds half away from zero
# (a 10-hour difference is 0.416666667, not ...666).
#
# Both wrong answers are pinned here against the live engine over a
# trivial fixture; the value, or the refusal, must agree.
#
# Usage: qa/serve-real-tempdiff.sh [port]   (default 4142)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4142}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/tempdiff.fdb"
rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-tempdiff.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the VALUE, or the word REFUSE if the statement raised
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^V ' | tr -d ' \n' | sed 's/^V//'; fi; }
agree() { # <label> <expr>
    local q e f
    q="select $2 v from rdb\$database;"
    e=$(sig "127.0.0.1/3050:$DB" "$q"); f=$(sig "127.0.0.1/$PORT:$DB" "$q")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

TS="timestamp'2026-09-08 10:00:00'"; TS2="timestamp'2026-01-01 00:00:00'"
DT="date'2026-09-08'"; TM="time'10:00:00'"
TZ="timestamp'2026-09-08 10:00:00 +02:00'"; TZ2="timestamp'2026-01-01 00:00:00 +00:00'"
TMZ="time'10:00:00 +02:00'"

# --- legal, same-family differences ---
agree "DATE - DATE (integer days)"          "$DT - date'2026-01-01'"
agree "TIME - TIME (scale 4 seconds)"       "$TM - time'01:00:00'"
agree "TIMESTAMP - TIMESTAMP rounds up"     "$TS - $TS2"
agree "TIMESTAMP - TIMESTAMP negative"      "$TS2 - $TS"
agree "TSTZ - TSTZ on the UTC instant"      "$TZ - $TZ2"
agree "TIMESTAMP - TSTZ (mixed zoning ok)"  "$TS - $TZ2"
agree "TSTZ - TIMESTAMP (mixed zoning ok)"  "$TZ - $TS2"
agree "TIMETZ - TIMETZ"                     "$TMZ - time'01:00:00 +02:00'"

# --- mixed families: the engine REFUSES, so must fire-crab ---
agree "DATE - TIMESTAMP refuses"            "$DT - $TS"
agree "TIMESTAMP - DATE refuses"            "$TS - $DT"
agree "DATE - TIMESTAMP WITH TZ refuses"    "$DT - $TZ2"
agree "DATE - TIME refuses"                 "$DT - $TM"
agree "TIMESTAMP - TIME refuses"            "$TS - $TM"
agree "TIME - TIMESTAMP refuses"            "$TM - $TS"

# --- addition: temporal + number legal, temporal + temporal refused ---
agree "DATE + int shifts whole days"        "$DT + 5"
agree "TIMESTAMP + int keeps the fraction"  "$TS + 1"
agree "DATE + TIME is that day at that time" "$DT + $TM"
agree "DATE + DATE refuses"                  "$DT + date'2026-01-01'"
agree "TIMESTAMP + TIMESTAMP refuses"        "$TS + $TS2"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS tempdiff" || echo "FAIL tempdiff"
exit $fail
