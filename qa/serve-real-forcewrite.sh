#!/bin/bash
# `gfix -write sync|async` THROUGH FIRE-CRAB.
#
# The roadmap filed gbak/gfix/nbackup under "as services", and for this
# one that is wrong in a way worth writing down: **gfix -write does not
# use the services API at all**. It ATTACHES, carrying the mode in the
# DPB as `isc_dpb_force_write` (tag 24, consts_pub.h:59), and detaches.
# A server that answered only the service manager left the switch doing
# nothing while looking like it had worked.
#
# What it asks for is one bit: `hdr_force_write` (ods.h:724) in the
# header page. `fire_crab_pio::plan_for_header` has read that bit since
# it was converted - it is what decides whether a flush opens the file
# with SYNC - so what was missing was only the ability to CHANGE it.
#
# The oracle is the engine's own tool reading the engine's own header:
# `gstat -h` prints `Attributes force write` when the bit is on and
# nothing when it is off, and the same script is run against both
# servers.
#
#   qa/serve-real-forcewrite.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4698}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
E="$D/fc-fw-engine.fdb"
A="$D/fc-fw-crab.fdb"
LOG="/tmp/fc-serve-forcewrite-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1, 'one');
COMMIT;
EOF
    chmod 666 "$1"
}

# what the ENGINE'S OWN TOOL says the header holds
attrs() { # <file>
    "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>&1 |
        grep -i 'attributes' | sed 's/.*Attributes//' | tr -s ' \t' ' ' |
        sed 's/^ *//; s/ *$//'
}

make_db "$E" || { echo "FAIL scratch engine db"; exit 1; }
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$E" "$A"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

# --- 1. a fresh database is forced-write on both -------------------------
check "a fresh database says 'force write' (engine's own header)" "$(attrs "$E")" "force write"
check "...and so does fire-crab's copy" "$(attrs "$A")" "$(attrs "$E")"

# --- 2. gfix -write async, through each server --------------------------
"$GFIX" -write async -user "$U" -pas "$P" "127.0.0.1/$REAL:$E" >/dev/null 2>&1
eng_async=$(attrs "$E")
check "ENGINE: gfix -write async clears it" "$eng_async" ""
"$GFIX" -write async -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
check "fc: gfix -write async clears it too" "$(attrs "$A")" "$eng_async"

# --- 3. and back again ---------------------------------------------------
"$GFIX" -write sync -user "$U" -pas "$P" "127.0.0.1/$REAL:$E" >/dev/null 2>&1
eng_sync=$(attrs "$E")
check "ENGINE: gfix -write sync sets it" "$eng_sync" "force write"
"$GFIX" -write sync -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
check "fc: gfix -write sync sets it too" "$(attrs "$A")" "$eng_sync"

# --- 4. the database still works, and the engine still reads it ---------
rows=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$A" 2>&1 | tr -d ' \n')
check "fc: the database the switch touched still reads" "$rows" "1"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | tr -d ' \n')
check "fc: and gfix -v -full finds nothing wrong with it" "$val" ""

# --- 5. COVERAGE: the flush FOLLOWED the new mode -----------------------
# The bit is not decoration: `plan_for_header` reads it to decide whether
# the file is opened with SYNC, so a flush after the change must report
# the mode the change asked for. Both states have to appear, or the
# checks above could pass against a server that wrote the bit and went on
# flushing the way it always had.
off=$(grep -c 'forced writes off' "$LOG")
on=$(grep -c 'forced writes on' "$LOG")
ran=$((ran + 1))
if [ "$off" -ge 1 ] && [ "$on" -ge 1 ]; then
    echo "OK   coverage: flushes ran in both modes (off $off, on $on)"
else
    echo "DIFF coverage: the flush never changed mode (off $off, on $on)"; fail=1
fi

echo "ran $ran checks"
exit $fail
