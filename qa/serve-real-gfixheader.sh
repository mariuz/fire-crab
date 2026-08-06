#!/bin/bash
# THE REST OF gfix's HEADER SWITCHES, THROUGH FIRE-CRAB.
#
# `qa/serve-real-forcewrite.sh` established the shape: gfix does not use
# the services API - it builds ONE dpb, attaches with it, and detaches
# (`EXE_action`, src/alice/exe.cpp:71). This is the other three items
# that dpb can carry, all of them the header page:
#
#   -use full|reserve   isc_dpb_no_reserve (27)       hdr_no_reserve 0x8
#   -buffers N          isc_dpb_set_page_buffers (61) hdr_page_buffers @32
#   -housekeeping N     isc_dpb_sweep_interval (22)   a CLUMPLET
#
# The third is the one with something to learn. The sweep interval is
# not a field: it is an entry in the VARIABLE header, and a fresh
# database does not have one at all - so honouring the switch means
# ADDING a clumplet, which means maintaining `hdr_end` (offset 36), the
# field that says where the terminator is. Nothing that only READS the
# header needs it - `variable_header` walks to the terminator - and
# getting it wrong is not a wrong answer but silent corruption: the
# engine appends AT `hdr_end` (`HeaderClumplet::add`, pag.cpp:150), so a
# stale one makes its next header write land on top of what fire-crab
# stored.
#
# That is what the last check is for, and it is the reason this gate can
# fail: after fire-crab adds the sweep interval, THE ENGINE is made to
# write the same variable header (`ALTER DATABASE ADD DIFFERENCE FILE`,
# which inserts its clumplet at the FRONT - pag.cpp:425 passes
# first=true - and memmoves the rest using hdr_end). Both entries have
# to survive, in the engine's own order.
#
# The oracle throughout is the engine's own tools on both sides: gfix
# writes, `gstat -h` reads.
#
#   qa/serve-real-gfixheader.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4699}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
E="$D/fc-hdrsw-engine.fdb"
A="$D/fc-hdrsw-crab.fdb"
LOG="/tmp/fc-serve-gfixheader-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

make_db() {
    rm -f "$1" "$1.delta"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1, 'one');
COMMIT;
EOF
    chmod 666 "$1"
}

# the three lines gstat prints for these switches, as one string
hdr() { # <file>
    "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>&1 |
        grep -iE 'attributes|page buffers|sweep interval' |
        tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//' | tr '\n' '|'
}

# the whole variable-header section, which is where the clumplets are
vars() { # <file>
    "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>&1 |
        sed -n '/Variable header data:/,/\*END\*/p' |
        sed "s|$1|<db>|g" | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//' | tr '\n' '|'
}

# run one gfix command line against each server, engine first
both() { # <switches...>
    "$GFIX" $@ -user "$U" -pas "$P" "127.0.0.1/$REAL:$E" >/dev/null 2>&1
    "$GFIX" $@ -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
}

make_db "$E" || { echo "FAIL scratch engine db"; exit 1; }
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$E" "$A" "$E.delta" "$A.delta"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check "the two scratch databases start identical" "$(hdr "$A")" "$(hdr "$E")"

# --- 1. -use full / -use reserve: hdr_no_reserve --------------------------
both -use full
eng=$(hdr "$E")
check "ENGINE: -use full says 'no reserve'" "$eng" "Page buffers 0|Attributes force write, no reserve|"
check "fc: -use full, the same header" "$(hdr "$A")" "$eng"

both -use reserve
eng=$(hdr "$E")
check "ENGINE: -use reserve takes it back off" "$eng" "Page buffers 0|Attributes force write|"
check "fc: -use reserve, the same header" "$(hdr "$A")" "$eng"

# --- 2. -buffers N: hdr_page_buffers -------------------------------------
both -buffers 500
eng=$(hdr "$E")
check "ENGINE: -buffers 500" "$eng" "Page buffers 500|Attributes force write|"
check "fc: -buffers 500, the same header" "$(hdr "$A")" "$eng"

# --- 3. -housekeeping N: A CLUMPLET THAT WAS NOT THERE --------------------
# a fresh database has no sweep-interval entry, so this ADDS one and the
# line appears in gstat's variable-header section for the first time
both -housekeeping 12345
eng=$(hdr "$E")
check "ENGINE: -housekeeping 12345 adds the entry" "$eng" \
      "Page buffers 500|Attributes force write|Sweep interval: 12345|"
check "fc: -housekeeping 12345, the same header" "$(hdr "$A")" "$eng"
check "fc: and the same variable-header section" "$(vars "$A")" "$(vars "$E")"

# --- 4. ONE SWITCH PER INVOCATION, AND gfix PICKS IT ----------------------
# This is where the gate caught its own premise. "gfix builds one dpb, so
# several switches are one header write" is WRONG: `buildDpb`
# (exe.cpp:207-344) is a single ELSE-IF CHAIN, so exactly one item ever
# reaches the dpb, chosen by the chain's order and not the command
# line's - and the switches it drops are dropped SILENTLY, rc=0.
#
# housekeeping sits above buffers in that chain, so it wins from either
# side of the command line...
both -buffers 700 -housekeeping 999
eng=$(hdr "$E")
check "ENGINE: -buffers with -housekeeping: only the sweep interval lands" "$eng" \
      "Page buffers 500|Attributes force write|Sweep interval: 999|"
check "fc: the same, because the item never arrives" "$(hdr "$A")" "$eng"

both -housekeeping 4321 -buffers 700
eng=$(hdr "$E")
check "ENGINE: ...and from the other order too - the chain decides, not argv" "$eng" \
      "Page buffers 500|Attributes force write|Sweep interval: 4321|"
check "fc: the same" "$(hdr "$A")" "$eng"

# ...and buffers sits above no_reserve, so this drops the -use
both -use full -buffers 700
eng=$(hdr "$E")
check "ENGINE: -use full with -buffers: only the buffers land" "$eng" \
      "Page buffers 700|Attributes force write|Sweep interval: 4321|"
check "fc: the same" "$(hdr "$A")" "$eng"

# COVERAGE, and the teeth for the paragraph above: every attach fire-crab
# saw carried exactly ONE header item. If gfix ever combined them this
# count would move, and the claim in the comment would be wrong.
multi=$(grep -c 'header dpb.*Some.*Some' "$LOG")
single=$(grep -c 'header dpb' "$LOG")
ran=$((ran + 1))
if [ "$multi" -eq 0 ] && [ "$single" -ge 6 ]; then
    echo "OK   coverage: all $single gfix attaches carried exactly one item"
else
    echo "DIFF coverage: $multi of $single attaches carried more than one item"; fail=1
fi

# --- 5. ASKING FOR WHAT IS ALREADY TRUE WRITES NOTHING --------------------
both -buffers 700
check "fc: repeating a switch changes nothing" "$(hdr "$A")" "$eng"
quiet=$(grep -c 'already so, nothing written' "$LOG")
ran=$((ran + 1))
if [ "$quiet" -ge 1 ]; then
    echo "OK   coverage: the repeat took no work copy and wrote no page"
else
    echo "DIFF coverage: a no-op gfix still wrote the header"; fail=1
fi

# --- 6. TEETH: hdr_end, AND THE ENGINE WRITING AFTER FIRE-CRAB ------------
# fire-crab APPENDED a clumplet above. If it left hdr_end (offset 36)
# naming the old terminator, the engine's next variable-header write -
# which inserts at the FRONT and memmoves the rest by hdr_end
# (pag.cpp:425, first=true) - lands on top of it. So: make the engine do
# exactly that to fire-crab's database, and require both entries to
# survive in the engine's own order.
for f in "$E" "$A"; do
    printf "ALTER DATABASE ADD DIFFERENCE FILE '%s.delta';\nCOMMIT;\n" "$f" |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$f" >/dev/null 2>&1
done
check "the engine's own write lands AFTER fire-crab's clumplet" "$(vars "$A")" "$(vars "$E")"
check "...and the sweep interval fire-crab wrote is still there" \
      "$(vars "$A" | grep -c 'Sweep interval: 4321')" "1"

# --- 7. the database is still a database ---------------------------------
rows=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$A" 2>&1 | tr -d ' \n')
check "fc: the database the switches touched still reads" "$rows" "1"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | tr -d ' \n')
check "fc: and gfix -v -full finds nothing wrong with it" "$val" ""

echo "ran $ran checks"
exit $fail
