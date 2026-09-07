#!/bin/bash
# A CAST FROM A STRING TO A NUMERIC OR FLOATING TYPE VALIDATES ITS RESULT
# THE WAY THE ENGINE DOES - it raises where the engine raises rather than
# answering a wrong number.
#
# Two silent wrong answers, both measured against Firebird 6 and pinned
# here for every case that flips success<->raise:
#
#  NUMERIC(p,s): the engine gates on the BACKING integer width twice -
#   the string's pre-round COEFFICIENT must fit (a plain decimal's
#   trailing fraction zeros dropped first), AND the rounded stored value
#   must fit. CAST('0.99995' AS NUMERIC(4,4)) raises 22003 even though it
#   rounds to 1.0000 which fits, because 99995 overflows the int16
#   backing; widen to NUMERIC(9,4) (int32) and it succeeds. fire-crab
#   used to round first and answer 1.0000.
#
#  DOUBLE PRECISION: the engine never produces Infinity or NaN from a
#   string. 'inf'/'nan'/'infinity' are 22018 conversion errors, and a
#   value that overflows binary64 ('1e400','1e309') is 22003. fire-crab
#   used Rust's f64 parse and answered Infinity / NaN.
#
# Comparison: the exact SQLSTATE (or value) through the engine and
# fire-crab must agree, over a trivial fixture the engine created.
#
# Usage: qa/serve-real-castrange.sh [port]   (default 4138)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4138}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/castrange.fdb"
rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castrange.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the value, or the SQLSTATE, whichever the query produced
sig() { "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | sed 's/  */ /g' \
    | grep -iE '2200[0-9]|Infinity|NaN|[0-9]' \
    | grep -ivE '^ X|SQL error code|line 1|conversion error from' \
    | head -1 | sed 's/^ *//;s/ *$//'; }
agree() { # <cast-expr>
    local q e f
    q="select $1 x from rdb\$database;"
    e=$(sig "127.0.0.1/3050:$DB" <<< "$q"); f=$(sig "127.0.0.1/$PORT:$DB" <<< "$q")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

# --- NUMERIC(p,s): coefficient gate and stored-value gate ---
for c in \
  "cast('0.99995' as numeric(4,4))" \
  "cast('0.99995' as numeric(9,4))" \
  "cast('0.9999000' as numeric(4,4))" \
  "cast('1.5' as numeric(4,4))" \
  "cast('3.2767' as numeric(4,4))" \
  "cast('3.2768' as numeric(4,4))" \
  "cast('3.9' as numeric(4,4))" \
  "cast('-3.2768' as numeric(4,4))" \
  "cast('-3.2769' as numeric(4,4))" \
  "cast('99.99' as numeric(4,2))" \
  "cast('99.999' as numeric(4,2))" \
  "cast('327.67' as numeric(4,2))" \
  "cast('327.68' as numeric(4,2))" \
  "cast('15000000.00' as numeric(9,2))" \
  "cast('21474836.47' as numeric(9,2))" \
  "cast('21474836.48' as numeric(9,2))" \
  "cast('99999999999999.99999' as numeric(18,4))" \
  "cast('922337203685477.5807' as numeric(18,4))" \
  "cast('922337203685477.5808' as numeric(18,4))" ; do
  agree "$c"
done
# --- DOUBLE PRECISION: no Infinity/NaN from a string ---
for c in \
  "cast('1.5' as double precision)" \
  "cast('1e300' as double precision)" \
  "cast('1.7976931348623157e308' as double precision)" \
  "cast('1e309' as double precision)" \
  "cast('1e400' as double precision)" \
  "cast('nan' as double precision)" \
  "cast('inf' as double precision)" \
  "cast('infinity' as double precision)" \
  "cast('-inf' as double precision)" \
  "cast('abc' as double precision)" ; do
  agree "$c"
done

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castrange" || echo "FAIL castrange"
exit $fail
