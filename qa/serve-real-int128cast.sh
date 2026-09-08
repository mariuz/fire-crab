#!/bin/bash
# A CAST OF AN OUT-OF-RANGE VALUE TO AN INT128-BACKED NUMERIC RAISES,
# AND AN IN-RANGE ONE KEEPS CLEAN DIGITS.
#
# The overflow bound for NUMERIC/DECIMAL of precision 19..38 is the
# BACKING INT128 range (|scaled value| <= 2^127-1), independent of the
# declared precision. fire-crab's approximate-source cast to such a
# target had two silent wrong answers:
#   * it SATURATED to 2^127-1 instead of raising 22003
#     (cast(1e39 as numeric(38,0)) answered 170141... where the engine
#     raises numeric-value-out-of-range);
#   * an in-range double stored its EXACT BINARY expansion, not its
#     decimal significance - cast(1.5e38 as numeric(38,0)) came back
#     150000000000000006067947700923341471744.
# Both are fixed by adding the 2^127 range gate (the exact one the
# integer-target cast already uses) and by converting the double through
# its shortest round-trip decimal. The narrower backings (2/4/8) are
# untouched - a double large enough to reach them already overflows to
# 22003. Held against the live engine.
#
# Usage: qa/serve-real-int128cast.sh [port]   (default 4147)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4147}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/int128cast.fdb"
rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-int128cast.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the value, or the SQLSTATE
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|Database:|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then printf '%s' "$r" | grep -oi '2200[0-9]' | head -1; \
    else printf '%s' "$r" | grep -iE '^X ' | tr -d ' \n' | sed 's/^X//'; fi; }
agree() { # <cast-expr>
    local q e f
    q="select $1 x from rdb\$database;"
    e=$(sig "127.0.0.1/3050:$DB" "$q"); f=$(sig "127.0.0.1/$PORT:$DB" "$q")
    if [ "$e" = "$f" ]; then echo "OK   $1  [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- out of the INT128 backing: 22003, not a saturated value --"
for c in \
  "cast(1e39 as numeric(38,0))" \
  "cast(5e38 as numeric(38,0))" \
  "cast(1e40 as numeric(38,0))" \
  "cast(1.8e38 as numeric(38,0))" \
  "cast(-1e39 as numeric(38,0))" \
  "cast(2e38 as numeric(19,0))" ; do agree "$c"; done
echo "-- in range: clean decimal significance --"
for c in \
  "cast(1.5e38 as numeric(38,0))" \
  "cast(1.7e38 as numeric(38,0))" \
  "cast(1e38 as numeric(38,0))" \
  "cast(1e30 as numeric(38,0))" \
  "cast(-1.5e38 as numeric(38,0))" \
  "cast(1.5e10 as numeric(38,4))" \
  "cast(0.1e0 as numeric(38,4))" \
  "cast(1e20 as numeric(38,0))" ; do agree "$c"; done
echo "-- controls (narrower backings unchanged) --"
for c in \
  "cast(2e38 as numeric(18,0))" \
  "cast(1.5e0 as numeric(9,2))" \
  "cast(1e0 as numeric(4,2))" ; do agree "$c"; done

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS int128cast" || echo "FAIL int128cast"
exit $fail
