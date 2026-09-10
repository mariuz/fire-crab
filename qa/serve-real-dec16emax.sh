#!/bin/bash
# DECIMAL64 (DECFLOAT(16)) ENCODES A HIGH-EXPONENT VALUE CORRECTLY AND
# RAISES ON OVERFLOW.
#
# A decimal64's stored exponent must be <= 369 (biased <= 767); a value
# handed to the encoder with a higher exponent and a short coefficient -
# a cast of 1E+384 arrives as coefficient 1, exponent 384 - overflowed
# the two combination-field exponent bits and produced GARBAGE:
# fire-crab answered 8.000000000000001E-369 for CAST(1E+384 AS
# DECFLOAT(16)) where the engine answers 1.000000000000000E+384. And a
# magnitude the format cannot hold (adjusted exponent > emax 384, e.g.
# 1E+385) must raise 22003 "Decimal float overflow"; fire-crab answered
# more garbage. Fixed by normalising the coefficient (pad trailing zeros
# to bring the exponent into range) and refusing what still will not fit.
#
# Held against the live engine.
#
# Usage: qa/serve-real-dec16emax.sh [port]   (default 4155)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4155}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/dec16emax.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dec16emax.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "R$(printf '%s' "$r"|grep -o '2200[0-9]'|head -1)"; else printf '%s' "$r" | grep -iE '^V ' | tr -d ' \n' | sed 's/^V//'; fi; }
agree() { local e f; e=$(sig "$E" "$2"); f=$(sig "$F" "$2"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
c34() { echo "select cast(cast('$1' as decfloat(34)) as decfloat(16)) v from rdb\$database;"; }

echo "-- high exponent, in range: canonical value (was garbage) --"
agree "1E+383"   "$(c34 1E+383)"
agree "1E+384"   "$(c34 1E+384)"
agree "5E+384"   "$(c34 5E+384)"
agree "9.999999999999999E+384" "$(c34 9.999999999999999E+384)"
agree "-1E+384"  "$(c34 -1E+384)"
agree "direct DECFLOAT(16) literal" "select cast('1E+384' as decfloat(16)) v from rdb\$database;"
echo "-- overflow: 22003, not garbage --"
agree "1E+385"   "$(c34 1E+385)"
agree "1E+400"   "$(c34 1E+400)"
agree "-9E+400"  "$(c34 -9E+400)"
echo "-- controls: mid-range and small unchanged --"
agree "1.5"      "$(c34 1.5)"
agree "1E+50"    "$(c34 1E+50)"
agree "1E+200"   "$(c34 1E+200)"
agree "1E-370"   "$(c34 1E-370)"
agree "123.456 direct" "select cast(123.456 as decfloat(16)) v from rdb\$database;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dec16emax" || echo "FAIL dec16emax"
exit $fail
