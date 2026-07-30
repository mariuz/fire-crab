#!/bin/bash
# The engine's SHARED LOCK TABLE, decoded by fire-crab and diffed against
# the engine's own dump of the same bytes.
#
# The lock table is a file the server maps (/tmp/firebird/fb_lock_<id>) and
# every pointer in it is a self-relative offset. `fb_lock_print` prints it
# as text; fire-crab decodes the same file and must produce the SAME TEXT -
# tabs, column widths, the hash-length distribution and all.
#
# The comparison is exact rather than approximate because both tools read a
# SNAPSHOT: the gate copies the live file and runs `fb_lock_print -f` on the
# copy, so the counters cannot move between the two readings. (Reading the
# live file twice would differ on Enqs and Acquires alone.)
#
#   1. HEADER ONLY, then WITH OWNERS (-o), on a table with one attachment.
#   2. The same on a BUSIER table: three attachments, one holding a table
#      reservation, so there are more owners, more requests and a different
#      hash distribution. A dump that matches in only one state has matched
#      a coincidence.
#   3. Teeth: the dump must contain what it claims to (owner blocks, a
#      nonzero Enqs), and the distribution must account for every hash
#      slot - a walk that silently stops early would still print a plausible
#      table.
#   4. Refusals: a database file is not a lock table; a truncated table is
#      refused rather than decoded into nonsense.
#
#   qa/lck-table-dump.sh
#
# Needs the live server and fb_lock_print.

set -u
FCLCK="${FCLCK:-$(dirname "$0")/../target/release/fclck}"
ISQL="${ISQL:-isql}"
LOCKPRINT="${LOCKPRINT:-fb_lock_print}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DB="${FC_REAL_DB:-/opt/firebird/examples/empbuild/employee.fdb}"
LOCKDIR="${FC_LOCK_DIR:-/tmp/firebird}"
SNAP=/tmp/fc-lock-gate-snap

command -v "$LOCKPRINT" >/dev/null 2>&1 || { echo "SKIP fb_lock_print not found"; exit 0; }
fail=0

# one long-lived attachment through the SERVER: isql reading from a fifo
open_isql() { # <fd> <fifo> [sql...]
    rm -f "$2"; mkfifo "$2"
    "$ISQL" -q -b -user "$U" -pas "$P" "localhost:$DB" < "$2" >/dev/null 2>&1 &
    eval "exec $1> $2"
}
close_isql() { # <fd> <fifo>
    eval "printf 'COMMIT;\nQUIT;\n' >&$1" 2>/dev/null
    eval "exec $1>&-" 2>/dev/null
    rm -f "$2"
}

snapshot() {
    lk=$(ls -t "$LOCKDIR"/fb_lock_* 2>/dev/null | head -1)
    [ -n "$lk" ] && [ -r "$lk" ] || return 1
    cp "$lk" "$SNAP" 2>/dev/null || return 1
    return 0
}

compare() { # <label> <extra fb_lock_print/fclck switches>
    "$LOCKPRINT" -f "$SNAP" $2 > /tmp/fc-lk-engine.txt 2>&1
    "$FCLCK" dump "$SNAP" $2 > /tmp/fc-lk-crab.txt 2>&1
    if [ ! -s /tmp/fc-lk-crab.txt ]; then
        echo "DIFF $1: fire-crab printed nothing ($(head -1 /tmp/fc-lk-engine.txt))"; fail=1; return
    fi
    if diff -q /tmp/fc-lk-engine.txt /tmp/fc-lk-crab.txt >/dev/null; then
        echo "OK   $1: identical to fb_lock_print ($(wc -l < /tmp/fc-lk-crab.txt) lines)"
    else
        echo "DIFF $1"
        diff /tmp/fc-lk-engine.txt /tmp/fc-lk-crab.txt | head -10 | sed 's/^/     /'
        fail=1
    fi
}

# ------------------------------------------- 1. a quiet table ------------
open_isql 8 /tmp/fc-lk-fifo-1
printf 'SELECT COUNT(*) FROM RDB$RELATIONS;\n' >&8
sleep 1
if ! snapshot; then
    close_isql 8 /tmp/fc-lk-fifo-1
    echo "SKIP no readable lock table in $LOCKDIR"
    exit 0
fi
compare "header block, one attachment" ""
compare "header + owner blocks, one attachment" "-o"

# ------------------------------------------- 2. a busier table -----------
open_isql 7 /tmp/fc-lk-fifo-2
open_isql 6 /tmp/fc-lk-fifo-3
# a table reservation takes a real lock in the table
printf 'SET TRANSACTION RESERVING EMPLOYEE FOR PROTECTED WRITE;\nSELECT COUNT(*) FROM EMPLOYEE;\n' >&7
printf 'SELECT COUNT(*) FROM DEPARTMENT;\nSELECT COUNT(*) FROM PROJECT;\n' >&6
sleep 1
if snapshot; then
    compare "header block, three attachments + a PROTECTED WRITE reservation" ""
    compare "header + owner blocks, three attachments" "-o"
    owners=$(grep -c '^OWNER BLOCK' /tmp/fc-lk-crab.txt)
    enqs=$("$FCLCK" dump "$SNAP" | awk -F'[:,]' '/Enqs/{gsub(/ /,"",$2); print $2}')
    if [ "$owners" -ge 2 ] && [ -n "$enqs" ] && [ "$enqs" -gt 0 ]; then
        echo "OK   the dump has real content: $owners owner blocks, $enqs enqueues"
    else
        echo "DIFF thin dump: $owners owner blocks, enqs [$enqs]"; fail=1
    fi
    # every hash slot must be accounted for by the distribution: a walk
    # that stopped early would still print a plausible table
    slots=$("$FCLCK" dump "$SNAP" | awk -F'[:,]' '/Hash slots/{gsub(/ /,"",$2); print $2}')
    summed=$("$FCLCK" dump "$SNAP" |
        awk '/Hash lengths distribution/{f=1;next} f&&/^\t\t/{gsub(/[()%\t]/," "); s+=$3} END{print s}')
    if [ -n "$slots" ] && [ "$summed" = "$slots" ]; then
        echo "OK   the distribution accounts for all $slots hash slots"
    else
        echo "DIFF distribution sums to [$summed] for [$slots] slots"; fail=1
    fi
else
    echo "DIFF could not snapshot the busier table"; fail=1
fi
close_isql 6 /tmp/fc-lk-fifo-3
close_isql 7 /tmp/fc-lk-fifo-2
close_isql 8 /tmp/fc-lk-fifo-1

# ------------------------------------------------- 4. refusals -----------
r=$("$FCLCK" dump "$DB" 2>&1 | head -1)
case "$r" in
    REFUSED*"not a lock table"*)
        echo "OK   a database file is refused, not decoded ($(printf '%s' "$r" | cut -c1-60)...)" ;;
    *) echo "DIFF dumping a database file said: [$r]"; fail=1 ;;
esac
head -c 200 "$SNAP" > /tmp/fc-lk-trunc
r=$("$FCLCK" dump /tmp/fc-lk-trunc 2>&1 | head -1)
case "$r" in
    REFUSED*"too short"*)
        echo "OK   a truncated lock table is refused" ;;
    *) echo "DIFF truncated table said: [$r]"; fail=1 ;;
esac
rm -f /tmp/fc-lk-trunc "$SNAP"
exit $fail
