#!/bin/bash
# CAST(? AS <type>) - a PARAMETER in the SELECT LIST. The projection had
# no parameter atom at all (a `?` there refused); this is the first slice
# that gives it one. The engine types the `?` slot AS THE CAST TARGET and
# the CAST converts the bound value, so the whole string->integer grammar
# (rounding half away from zero, an exponent, the width check) applies to
# a bound value exactly as to a literal - measured against the live
# engine, value by value.
#
# The rig (qa/fbparam.c) binds the value as VARCHAR (value-derived, as
# node-firebird does) and coerces the OUTPUT to BIGINT so the read does
# not depend on the announced column width - which lets the comparison
# hold the VALUE fixed across the two servers. It prints the integer, or
# CONV_ERROR (22018) / OUT_OF_RANGE (22003) / NULL.
#
# FIRST-SLICE SCOPE: a plain single-table SELECT, projection parameters
# only (a `?` in BOTH the projection and the WHERE refuses - the
# textual-order merge is a later slice), integer/numeric/approx cast
# targets (a `?` cast to text or a temporal refuses). A pre-existing,
# unrelated divergence rides along: fire-crab describes a CAST-to-integer
# OUTPUT column as INT64 where the engine names the target width
# (CAST(1 AS SMALLINT) is 580 here, 500 there) - the VALUE is identical,
# which is why this gate reads through a BIGINT coercion.
#
#   qa/serve-real-castparam.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4741}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbparam"
if ! cc -o "$RIG" "$(dirname "$0")/fbparam.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the param rig (cc/libfbclient missing)"; exit 0
fi
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
}
EDB="$D/fc-castparam-e.fdb"; FDB="$D/fc-castparam-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparam-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

both() { # <sql> <boundval>
    local e c
    e=$(timeout 15 "$RIG" "localhost:$EDB" "$1" "$2" 2>&1)
    c=$(timeout 15 "$RIG" "127.0.0.1/$PORT:$FDB" "$1" "$2" 2>&1)
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   [$1 <- '$2'] => $c"
    else echo "DIFF [$1 <- '$2']"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
}
SI="SELECT CAST(? AS SMALLINT) FROM RDB\$DATABASE"
IN="SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE"
BI="SELECT CAST(? AS BIGINT) FROM RDB\$DATABASE"

# --- the string grammar reaches a bound value: rounding, spaces, exponent ---
both "$IN" "2.5"
both "$IN" "-2.5"
both "$IN" "2.49"
both "$SI" "12.5"
both "$IN" "1e3"
both "$IN" "  2  "
both "$BI" "3.9"
both "$IN" "42"
# --- the width check on a bound value: 22003 ---------------------------------
both "$SI" "32767"
both "$SI" "32768"
both "$IN" "99999999999"
both "$IN" "2147483648"
# --- a non-numeric bound value stays 22018, CAST strict on internal blanks ---
both "$IN" "abc"
both "$IN" "1 2"
# --- NULL binds to NULL ------------------------------------------------------
both "$IN" "NULL"

echo "ran $ran checks"
exit $fail
