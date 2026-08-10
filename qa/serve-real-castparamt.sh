#!/bin/bash
# CAST(? AS <temporal>) - a PARAMETER in the SELECT LIST cast to a DATE, a
# TIME or a TIMESTAMP. The integer/numeric/approx projection param landed
# earlier (qa/serve-real-castparam.sh); this slice extends the `?` to the
# temporal targets, which are the clean half of "text/temporal":
#
#   * the `?` slot DESCRIBES as its native temporal type - CAST(? AS DATE)
#     is 570 SQL_TYPE_DATE len 4, TIME 560 len 4, TIMESTAMP 510 len 8,
#     subtype 0, on both the OUTPUT and the INPUT side (probed against the
#     live engine with qa/fbdesc.c);
#   * a value-derived VARCHAR bound into that slot (exactly as
#     node-firebird sends it) takes the engine's string->temporal grammar
#     and the CAST converts it - '2020-06-15' -> a DATE, '13:45:30.1234'
#     -> a TIME keeping its 1/10000s fraction, and a bad spelling stays an
#     error - measured value by value against the live engine.
#
# The rig (qa/fbparamt.c) reads the single output column in its NATIVE
# type and prints the RAW stored integer(s) (the ISC_DATE, the ISC_TIME,
# the timestamp pair), so the differential is on the exact value the two
# servers computed, with no server-side output coercion in the middle.
#
# TEXT targets are OUT OF SCOPE and asserted to REFUSE: CAST(? AS
# VARCHAR/CHAR) is unimplemented server-wide (even CAST('ab' AS
# VARCHAR(3)) as a literal is SQLSTATE 42000, and an over-length source
# owes the engine's 22001 "string right truncation" this server does not
# raise), so the `?` refuses to prepare rather than half-convert. The
# whole CAST-to-text feature is a separate slice.
#
#   qa/serve-real-castparamt.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4745}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbparamt"; DESC="$D/fc-fbdesc"
if ! cc -o "$RIG" "$(dirname "$0")/fbparamt.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the param rig (cc/libfbclient missing)"; exit 0
fi
cc -o "$DESC" "$(dirname "$0")/fbdesc.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null || DESC=""
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
}
EDB="$D/fc-castparamt-e.fdb"; FDB="$D/fc-castparamt-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparamt-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$DESC" "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"

# --- the value differential: a bound VARCHAR cast to a temporal ---------------
both() { # <sql> <boundval> <label>
    local e c
    e=$(timeout 15 "$RIG" "$E" "$1" "$2" 2>&1)
    c=$(timeout 15 "$RIG" "$F" "$1" "$2" 2>&1)
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   [$3 <- '$2'] => $c"
    else echo "DIFF [$3 <- '$2']"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
}
DT="SELECT CAST(? AS DATE) FROM RDB\$DATABASE"
TM="SELECT CAST(? AS TIME) FROM RDB\$DATABASE"
TS="SELECT CAST(? AS TIMESTAMP) FROM RDB\$DATABASE"
both "$DT" "2020-06-15"           "DATE"
both "$DT" "2020-6-5"             "DATE"      # a one-digit month/day still reads
both "$DT" "1858-11-17"           "DATE"      # the MJD epoch, stored 0
both "$DT" "NULL"                 "DATE"      # NULL binds to NULL
both "$DT" "notadate"             "DATE"      # a bad spelling: same error both sides
both "$TM" "13:45:30"             "TIME"
both "$TM" "13:45:30.1234"        "TIME"      # the 1/10000s fraction survives
both "$TM" "00:00:00"             "TIME"
both "$TS" "2020-06-15 13:45:30"      "TIMESTAMP"
both "$TS" "2020-06-15 13:45:30.5000" "TIMESTAMP"
both "$TS" "2020-06-15"                "TIMESTAMP"  # date-only: midnight time part

# --- the describe: the `?` slot IS the temporal target, both sides ------------
if [ -n "$DESC" ]; then
    dboth() { # <sql> <label>
        local e c
        e=$("$DESC" "$E" "$1" 2>&1)
        c=$("$DESC" "$F" "$1" 2>&1)
        ran=$((ran + 1))
        if [ "$e" = "$c" ]; then echo "OK   describe $2 [$(echo "$e" | tr '\n' ' ')]"
        else echo "DIFF describe $2"; echo "     engine: $e"; echo "     fcrab:  $c"; fail=1; fi
    }
    dboth "$DT" "CAST(? AS DATE)"
    dboth "$TM" "CAST(? AS TIME)"
    dboth "$TS" "CAST(? AS TIMESTAMP)"
fi

# --- a TEXT target refuses to prepare on both servers (boundary) --------------
refuses() { # <sql> <label>
    local e c
    e=$(printf 'SELECT %s FROM RDB$DATABASE;\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | grep -c 'Statement failed')
    c=$(printf 'SELECT %s FROM RDB$DATABASE;\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | grep -c 'Statement failed')
    ran=$((ran + 1))
    # the engine rejects the paramless isql prepare too (no value), so both
    # sides fail to produce a row - what is pinned is that neither converts
    if [ "$e" -ge 1 ] && [ "$c" -ge 1 ]; then echo "OK   $2 refuses on both"
    else echo "DIFF $2  engine_fail=$e fcrab_fail=$c"; fail=1; fi
}
refuses "CAST(? AS VARCHAR(5))" "CAST(? AS VARCHAR(5))"
refuses "CAST(? AS CHAR(3))"    "CAST(? AS CHAR(3))"

echo "ran $ran checks"
exit $fail
