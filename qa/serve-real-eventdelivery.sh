#!/bin/bash
# EVENT DELIVERY - the auxiliary connection, and what it carries.
#
# `qa/serve-real-events.sh` gates the POST; this gates the TELLING, which
# is a different socket and a different conversation. A client asks for
# somewhere to be told things (`op_connect_request`), the server answers
# a port, the client opens a SECOND connection, registers an interest
# with an EPB (`op_que_events`), and every delivery is an `op_event`
# frame pushed on that second socket by whichever attachment's COMMIT
# moved the counter.
#
# THE ORACLE IS THE PAPER'S OWN CLIENT. `samples/nodejs/events.js` is
# published with the paper, drives exactly that dance through a pure-JS
# wire implementation, and prints one line per law it demonstrates. This
# gate runs THE SAME FILE against the live engine and against fire-crab
# and requires the output to match line for line - which is a stronger
# statement than any assertion this gate could write itself, because the
# client was not written for it.
#
# The absolute counters are part of that match, and they are where the
# converted table was WRONG until this slice measured it:
#
#   * a delivery carries `evnt_count + 1` (event.cpp:884), so a
#     subscriber to an event nobody has posted is told 1, not 0;
#   * a post to a name with NO event block is dropped whole
#     (`if (event)`, event.cpp:376), and the block is made by a
#     subscription - so two posts before anybody listened leave the next
#     subscriber's baseline at 1.
#
# Both were invisible while the gates compared DELTAS, which is what
# `qa/evt-semantics.sh` had to do without a delivery path to read.
#
#   qa/serve-real-eventdelivery.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
SAMPLES="${SAMPLES:-$(dirname "$0")/../../../samples/nodejs}"
PORT="${1:-4712}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-evtdel-engine.fdb"
DBF="$D/fc-evtdel-crab.fdb"
LOG="/tmp/fc-serve-evtdel-$PORT.log"
fail=0
ran=0

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
[ -f "$SAMPLES/events.js" ] || { echo "SKIP the paper's event sample not found"; exit 0; }
mkdir -p "$D"; chmod 777 "$D" 2>/dev/null

build() { # <path>
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
COMMIT;
EOF
    chmod 666 "$1"
}
build "$DBE" || { echo "FAIL create engine db"; exit 1; }
build "$DBF" || { echo "FAIL create crab db"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

# EACH SERVER GETS ITS OWN DATABASE, as qa/serve-real-autonomous.sh does
# and for a related reason: the event counter is per database and the
# sample's own posts move it, so a shared file would have the engine's
# run decide what fire-crab's baseline is.
sample() { # <host:port> <db>
    (cd "$SAMPLES" && FB_HOST=127.0.0.1 FB_PORT="$1" FB_DATABASE="$2" \
        timeout 90 node events.js 2>&1)
}
eng=$(sample "$REAL" "$DBE")
crab=$(sample "$PORT" "$DBF")

# --- 1. the whole conversation, line for line ---------------------------
ran=$((ran + 1))
if [ "$eng" = "$crab" ]; then
    echo "OK   the paper's own event client prints the same thing on both servers"
    printf '%s\n' "$crab" | sed 's/^/     /'
else
    echo "DIFF the two runs differ"
    printf '%s\n' "$eng" | sed 's/^/     engine: /'
    printf '%s\n' "$crab" | sed 's/^/     fc:     /'
    fail=1
fi

# --- 2. the individual laws, so a shared failure cannot read as agreement -
# If node were missing or both runs errored, the comparison above would
# still pass. These require the LINES, on both sides.
law() { # <label> <pattern>
    ran=$((ran + 1))
    if printf '%s' "$eng" | grep -q "$2" && printf '%s' "$crab" | grep -q "$2"; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $(printf '%s' "$eng" | grep "$2" || echo '(absent)')"
        echo "     fc:     $(printf '%s' "$crab" | grep "$2" || echo '(absent)')"
        fail=1
    fi
}
law "a subscriber is told the counter at once, and it is 1" "baseline counter = 1"
law "ROLLBACK swallows posts" "ROLLBACK : 0 deliveries"
law "delivery is COMMIT-TIME" "before COMMIT      : 0 deliveries"
law "3 posts COALESCE into ONE delivery carrying 4" "counter=4, delta=3"
law "the client finished" "^done\."

# --- 3. TEETH -----------------------------------------------------------
# The output above could in principle come from a client that never
# reached this server. The log must show the whole dance.
teeth() { # <label> <pattern> <min>
    local n
    n=$(grep -c "$2" "$LOG")
    ran=$((ran + 1))
    if [ "$n" -ge "$3" ]; then
        echo "OK   teeth: $1 ($n)"
    else
        echo "DIFF teeth: $1 - only $n"; fail=1
    fi
}
teeth "an auxiliary port was handed out" "op_connect_request: aux port" 1
teeth "interests were registered" "op_que_events" 2
teeth "op_event frames were pushed" "op_event session" 2
# and the delivery that matters carries the counter the engine's would
ran=$((ran + 1))
if grep -q 'op_event session .* count 4' "$LOG"; then
    echo "OK   teeth: the commit's delivery carried counter 4"
else
    echo "DIFF teeth: no delivery carrying 4"; fail=1
fi

echo "ran $ran checks"
exit $fail
