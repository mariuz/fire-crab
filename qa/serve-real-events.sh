#!/bin/bash
# POST_EVENT: THE STATEMENT, AND THE COUNTER BEHIND IT.
#
# An event is not a message, it is a COUNTER (`fire_crab_evt`, converted
# from event.cpp and gated on its semantics by qa/evt-semantics.sh).
# `POST_EVENT` inside a transaction changes nothing visible; the COMMIT
# moves the counter; a ROLLBACK swallows the posts; and several posts of
# one name in one transaction move the counter by that many and produce
# ONE delivery carrying the new value.
#
# This gate wires the first half of that to the wire server:
#
#   * THE STATEMENT. A procedure containing `POST_EVENT` used to be
#     refused whole - "body is outside this server's PSQL surface" -
#     which took the procedure's OTHER statements with it. Both servers
#     run the same procedure here and must return the same thing.
#   * THE COUNTER. fire-crab's own event table, read out of the server
#     log: a commit moves it by the number of posts, a rollback does
#     not move it at all.
#
# WHAT IS NOT HERE YET, named so it is not assumed: DELIVERY. A client
# learns about an event over an AUXILIARY connection (op_connect_request,
# a second socket, op_que_events, op_event) and this server speaks none
# of it, so nothing is delivered to anybody. The counter is what the
# delivery would carry, and it is right; the carrying is the next slice.
#
#   qa/serve-real-events.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4697}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
E="$D/fc-events-engine.fdb"
A="$D/fc-events-crab.fdb"
LOG="/tmp/fc-serve-events-$PORT.log"
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
COMMIT;
SET TERM ^;
CREATE PROCEDURE ANNOUNCE RETURNS (N INTEGER) AS
BEGIN
  POST_EVENT 'demo_event';
  N = 42;
END^
CREATE PROCEDURE ANNOUNCE_TWICE RETURNS (N INTEGER) AS
BEGIN
  POST_EVENT 'demo_event';
  POST_EVENT 'demo_event';
  N = 7;
END^
SET TERM ;^
COMMIT;
EOF
    chmod 666 "$1"
}

# --- 1. THE STATEMENT, on both servers ---------------------------------
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

run() { # <conn> <script>
    printf '%s\n' "$2" | "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ','
}

SCRIPT='SET HEADING OFF;
EXECUTE PROCEDURE ANNOUNCE;
COMMIT;
EXECUTE PROCEDURE ANNOUNCE_TWICE;
COMMIT;'
eng=$(run "$E" "$SCRIPT")
check "ENGINE: a procedure that posts an event runs and returns" "$eng" "42,7,"
check "fc: the same procedure, the same answers" "$(run "127.0.0.1/$PORT:$A" "$SCRIPT")" "$eng"

# a rolled-back post must not stop the procedure answering either
ROLLED='SET HEADING OFF;
EXECUTE PROCEDURE ANNOUNCE;
ROLLBACK;'
eng_rb=$(run "$E" "$ROLLED")
check "ENGINE: and one whose transaction rolls back" "$eng_rb" "42,"
check "fc: the same" "$(run "127.0.0.1/$PORT:$A" "$ROLLED")" "$eng_rb"

# --- 2. THE COUNTER, out of fire-crab's own event table -----------------
# The counter is read from the server log (the engine's lives in shared
# memory and is only observable through a delivery - which this server
# now speaks too, gated by `qa/serve-real-eventdelivery.sh`).
#
# THIS ASSERTED THE WRONG LAW UNTIL THE DELIVERY SLICE MEASURED IT.
# `EventManager::postEvent` looks the name up and does NOTHING when
# there is no event block (`if (event)`, event.cpp:376), and the block
# is made by a SUBSCRIPTION. Nobody is listening here, so the engine
# would count none of these posts - and the counter this gate used to
# require (1, then 3) was fire-crab's own invention. It stays at 0, and
# what proves the posts still ARRIVE is the teeth below plus the
# delivery gate, where a listener exists and the counter does move.
counters=$(grep '\[srv\] event "demo_event" counter' "$LOG" | sed -n 's/.*counter \([0-9]*\).*/\1/p' | tr '\n' ',')
check "fc: no listener, no event block, no counter (event.cpp:376)" \
      "$counters" "0,0,0,"
rolled=$(grep -c 'rolled back' "$LOG")
ran=$((ran + 1))
if [ "$rolled" -ge 1 ]; then
    echo "OK   coverage: a rolled-back post was swallowed, not counted"
else
    echo "DIFF coverage: no rollback reached the event table"; fail=1
fi

# --- 3. TEETH ----------------------------------------------------------
# A gate that only ever sees "42" would pass against a server that never
# parsed POST_EVENT at all - it would refuse the procedure, and the
# refusal would show up as an error rather than the answer. So: the
# statement that used to fail is the one being run, and this asserts the
# server logged the post it claims to have made.
posts=$(grep -c 'POST_EVENT' "$LOG")
ran=$((ran + 1))
if [ "$posts" -ge 4 ]; then
    echo "OK   teeth: the server logged $posts posts, so the statement really ran"
else
    echo "DIFF teeth: only $posts posts logged - was POST_EVENT parsed?"; fail=1
fi

echo "ran $ran checks"
exit $fail
