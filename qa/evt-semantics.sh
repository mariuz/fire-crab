#!/bin/bash
# EVENT SEMANTICS - the converted event table against the LIVE engine,
# through the paper's own event client.
#
# An event is not a message but a COUNTER (event.h:105's evnt_count),
# and a client's interest carries the count it has already seen
# (req_int's rint_count). Everything observable follows: delivery is
# COMMIT-TIME, ROLLBACK swallows posts, and several posts of one name
# COALESCE into ONE delivery carrying the new counter.
#
# The differential is semantic rather than byte-level: the shared-memory
# arena is transport, but WHO is told WHAT and WHEN is policy. The
# paper's node client (samples/nodejs/events.js) prints those three
# facts against a real server over a real auxiliary connection; `fcevt
# replay` prints them from the converted table; the gate asserts they
# agree - including the counter DELTA, which is the invariant (absolute
# counters depend on the database's history).
#
#   qa/evt-semantics.sh
#
# Needs the REAL SERVER (the aux connection for op_event) and node.

set -u
FCEVT="${FCEVT:-$(dirname "$0")/../target/release/fcevt}"
ISQL="${ISQL:-isql}"
SAMPLES="${SAMPLES:-$(dirname "$0")/../../../samples/nodejs}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-evtgate.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
[ -f "$SAMPLES/events.js" ] || { echo "SKIP the paper's event sample not found"; exit 0; }
mkdir -p "$D"; chmod 777 "$D" 2>/dev/null; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create (is the server running?)"; exit 1; }
CREATE DATABASE 'localhost:$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

fail=0
# --- the live engine, through the paper's client ----------------------
live=$(cd "$SAMPLES" && FB_DATABASE="$DB" \
    NODE_PATH="$SAMPLES/node_modules" timeout 90 node events.js 2>&1)
crab=$("$FCEVT" replay 2>&1)

# 1. ROLLBACK swallows posts
if printf '%s' "$live" | grep -q "after POST_EVENT + ROLLBACK : 0 deliveries" &&
   printf '%s' "$crab" | grep -q "after rollback deliveries=0"; then
    echo "OK   ROLLBACK swallows posts (engine: 0 deliveries, fcevt: 0)"
else
    echo "DIFF rollback behaviour"
    printf '%s\n' "$live" | sed -n 's/^/     live: /p' | head -5
    printf '%s\n' "$crab" | sed -n 's/^/     crab: /p'
    fail=1
fi

# 2. delivery is COMMIT-TIME
if printf '%s' "$live" | grep -q "before COMMIT      : 0 deliveries" &&
   printf '%s' "$crab" | grep -q "before commit deliveries=0"; then
    echo "OK   delivery is COMMIT-TIME (engine: nothing before commit, fcevt: same)"
else
    echo "DIFF commit-time delivery"; fail=1
fi

# 3. posts COALESCE - one delivery, counter delta = number of posts
live_delta=$(printf '%s' "$live" | sed -n 's/.*delta=\([0-9]*\).*/\1/p' | head -1)
crab_delta=$(printf '%s' "$crab" | sed -n 's/.*delta=\([0-9]*\).*/\1/p' | head -1)
live_one=$(printf '%s' "$live" | grep -c "one delivery, 3 posts coalesced")
crab_one=$(printf '%s' "$crab" | grep -c "after commit deliveries=1")
if [ "$live_delta" = "3" ] && [ "$crab_delta" = "3" ] &&
   [ "$live_one" = "1" ] && [ "$crab_one" = "1" ]; then
    echo "OK   3 posts COALESCE into ONE delivery, counter delta 3 on both sides"
else
    echo "DIFF coalescing: live delta=[$live_delta] one=[$live_one], crab delta=[$crab_delta] one=[$crab_one]"
    fail=1
fi

# 4. the engine's own baseline convention: a subscriber is told the
#    CURRENT counter at once (the sample prints it), which is what the
#    crate's queue() does for an interest below the count
if printf '%s' "$live" | grep -q "baseline counter = "; then
    echo "OK   a subscriber learns the current counter as its baseline"
else
    echo "DIFF no baseline line from the live client"; fail=1
fi

exit $fail
