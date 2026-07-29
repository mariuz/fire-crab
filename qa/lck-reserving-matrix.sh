#!/bin/bash
# The lock-manager differential - fire-crab-lck against the LIVE
# engine's lock table, plus the engine's own source.
#
# Phase 1 - the source pin: `fclck pin-source` re-parses the
# compatibility[LCK_max][LCK_max] table out of the vendored lock.cpp
# and diffs it cell-by-cell against the crate's transcription.
#
# Phase 2 - the live 4x4: `SET TRANSACTION RESERVING <table> FOR
# <mode>` maps reservation modes onto the table-lock modes (shared
# read = SR, shared write = SW, protected read = PR, protected write =
# PW). Session A holds each mode through a fifo-fed isql attachment
# while session B probes all four with NO WAIT: the engine answers
# either silence (granted) or "lock conflict on no wait transaction"
# (SQLSTATE 40001), and every cell must equal `fclck compat A B`.
# Sixteen cells - including the matrix's famous one: SR beside PW is
# COMPATIBLE (a protected writer tolerates MVCC readers).
#
# Phase 3 - the live deadlock: two WAIT transactions cross-update two
# tables; the engine's deadlock scan denies one with SQLSTATE 40001
# "deadlock" - the same cycle fire-crab-lck's scan denies with
# Verdict::Deadlock (pinned by the crate's deadlock_two_owner_cycle
# unit test; this phase proves the engine really does what the unit
# test says it does).
#
#   qa/lck-reserving-matrix.sh
#
# Needs the REAL SERVER running (fbguard/firebird on localhost) - two
# attachments must share one lock table, which embedded mode refuses.

set -u
FCLCK="${FCLCK:-$(dirname "$0")/../target/release/fclck}"
ISQL="${ISQL:-isql}"
FB_SRC="${FB_SRC:-$(dirname "$0")/../../firebird}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-lckgate.fdb"
FIFO="$D/lck-fifo"

fail=0

# --- phase 1: the source pin ------------------------------------------
if out=$("$FCLCK" pin-source "$FB_SRC/src/lock/lock.cpp" 2>&1); then
    echo "OK   $out"
else
    echo "DIFF source pin: $out"; fail=1
fi

# --- phase 2: the live 4x4 --------------------------------------------
mkdir -p "$D"; chmod 777 "$D" 2>/dev/null; rm -f "$DB" "$FIFO"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create (is the server running?)"; exit 1; }
CREATE DATABASE 'localhost:$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
CREATE TABLE T2 (ID INTEGER);
COMMIT;
INSERT INTO T VALUES (1);
INSERT INTO T2 VALUES (1);
COMMIT;
EOF

sql_mode() { # SR|SW|PR|PW -> the RESERVING spelling
    case "$1" in
        SR) echo "SHARED READ" ;;
        SW) echo "SHARED WRITE" ;;
        PR) echo "PROTECTED READ" ;;
        PW) echo "PROTECTED WRITE" ;;
    esac
}

for A in SR SW PR PW; do
    mkfifo "$FIFO"
    "$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO" > "$D/lck-a.log" 2>&1 &
    apid=$!
    exec 9>"$FIFO"
    echo "SET TRANSACTION RESERVING T FOR $(sql_mode $A);" >&9
    sleep 1
    for B in SR SW PR PW; do
        out=$("$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" 2>&1 <<EOF | tr -s ' \n' ' '
SET TRANSACTION NO WAIT RESERVING T FOR $(sql_mode $B);
COMMIT;
EOF
)
        case "$out" in
            *"lock conflict"*) engine=CONFLICT ;;
            *"Statement failed"*) engine="ERROR[$out]" ;;
            *) engine=COMPATIBLE ;;
        esac
        ours=$("$FCLCK" compat "$B" "$A")
        if [ "$engine" = "$ours" ]; then
            echo "OK   hold $A, request $B NO WAIT: $engine"
        else
            echo "DIFF hold $A, request $B: engine=$engine fclck=$ours"
            fail=1
        fi
    done
    echo "COMMIT;" >&9; echo "EXIT;" >&9
    exec 9>&-
    wait $apid 2>/dev/null
    rm -f "$FIFO"
done

# --- phase 3: the live deadlock ---------------------------------------
mkfifo "$FIFO"; FIFO2="$D/lck-fifo2"; rm -f "$FIFO2"; mkfifo "$FIFO2"
"$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO" > "$D/lck-a.log" 2>&1 &
apid=$!
"$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO2" > "$D/lck-b.log" 2>&1 &
bpid=$!
exec 9>"$FIFO"; exec 8>"$FIFO2"
echo "SET TRANSACTION WAIT;" >&9
echo "UPDATE T SET ID = ID + 0;" >&9
echo "SET TRANSACTION WAIT;" >&8
echo "UPDATE T2 SET ID = ID + 0;" >&8
sleep 1
# A blocks on B's row; B closing the cycle must draw the deadlock
echo "UPDATE T2 SET ID = ID + 0;" >&9
sleep 1
echo "UPDATE T SET ID = ID + 0;" >&8
echo "COMMIT;" >&8
# the scan fires within DeadlockTimeout (default 10s)
deadline=$((SECONDS + 25))
verdict=""
while [ $SECONDS -lt $deadline ]; do
    if grep -q "deadlock" "$D/lck-a.log" "$D/lck-b.log" 2>/dev/null; then
        verdict=deadlock
        break
    fi
    sleep 1
done
echo "COMMIT;" >&9; echo "EXIT;" >&9; echo "EXIT;" >&8
exec 9>&-; exec 8>&-
wait $apid 2>/dev/null; wait $bpid 2>/dev/null
rm -f "$FIFO" "$FIFO2"
if [ "$verdict" = "deadlock" ]; then
    echo "OK   live cross-update draws the engine's deadlock - the cycle fclck's scan denies"
else
    echo "DIFF no deadlock error appeared within the window"
    tail -3 "$D/lck-a.log" "$D/lck-b.log"
    fail=1
fi

# --- phase 4: owner teardown unblocks the queue ------------------------
# A holds PW; B's WAIT reservation parks behind it; A DETACHES (the
# fifo closes) and the engine's owner purge regrants B - the same
# release-all-and-regrant fclck's purge_owner runs (pinned by its
# purge_regrants_the_queue unit test)
mkfifo "$FIFO"; FIFO2="$D/lck-fifo2"; rm -f "$FIFO2"; mkfifo "$FIFO2"
"$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO" > "$D/lck-a.log" 2>&1 &
apid=$!
"$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO2" > "$D/lck-b.log" 2>&1 &
bpid=$!
exec 9>"$FIFO"; exec 8>"$FIFO2"
echo "SET TRANSACTION RESERVING T FOR PROTECTED WRITE;" >&9
sleep 1
# B parks: a WAIT reservation conflicting with A's PW
echo "SET TRANSACTION WAIT RESERVING T FOR PROTECTED WRITE;" >&8
echo "SELECT 'B-PROCEEDED' FROM RDB\$DATABASE;" >&8
echo "COMMIT;" >&8
echo "EXIT;" >&8
sleep 2
if grep -q "B-PROCEEDED" "$D/lck-b.log" 2>/dev/null; then
    echo "DIFF teardown: B proceeded while A still held PW"
    fail=1
fi
# A detaches WITHOUT committing - the owner purge must release its
# locks and regrant B
echo "EXIT;" >&9
exec 9>&-
deadline=$((SECONDS + 15))
ok=0
while [ $SECONDS -lt $deadline ]; do
    if grep -q "B-PROCEEDED" "$D/lck-b.log" 2>/dev/null; then
        ok=1
        break
    fi
    sleep 1
done
exec 8>&-
wait $apid 2>/dev/null; wait $bpid 2>/dev/null
rm -f "$FIFO" "$FIFO2"
if [ $ok -eq 1 ]; then
    echo "OK   A's detach releases its locks and B's parked reservation proceeds (owner purge + regrant)"
else
    echo "DIFF B never proceeded after A detached"
    tail -3 "$D/lck-b.log"
    fail=1
fi

# --- phase 5: the lock timeout ----------------------------------------
# A holds PW; B waits WITH A DEADLINE (SET TRANSACTION WAIT LOCK
# TIMEOUT 2) - the engine expires the wait with "lock time-out on
# wait transaction" while A still holds, the same expiry
# fclck's expire(now) runs over deadline-carrying parked requests
# (pinned by its timeouts_expire_parked_requests unit test)
mkfifo "$FIFO"
"$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" < "$FIFO" > "$D/lck-a.log" 2>&1 &
apid=$!
exec 9>"$FIFO"
echo "SET TRANSACTION RESERVING T FOR PROTECTED WRITE;" >&9
sleep 1
out=$(timeout 20 "$ISQL" -q -user "$U" -pas "$P" "localhost:$DB" 2>&1 <<'SQL' | tr -s ' 
' ' '
SET TRANSACTION WAIT LOCK TIMEOUT 2 RESERVING T FOR PROTECTED WRITE;
COMMIT;
SQL
)
echo "COMMIT;" >&9; echo "EXIT;" >&9
exec 9>&-
wait $apid 2>/dev/null
rm -f "$FIFO"
case "$out" in
    *"time-out"*|*"timeout"*)
        echo "OK   the engine expires the deadlined wait: lock time-out while A holds" ;;
    *)
        echo "DIFF no lock timeout: [$out]"; fail=1 ;;
esac

exit $fail
