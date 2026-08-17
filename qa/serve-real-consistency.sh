#!/bin/bash
# TPB CONSISTENCY - degree3, "table stability", the strictest isolation
# and the last of the isolation family. Its visibility is a stable
# snapshot, as concurrency's is; what it ADDS is table locking, measured
# against the live engine:
#
#   * a CONSISTENCY transaction that writes a table reserves it in
#     PROTECTED WRITE, so a concurrent writer to ANY row of that table -
#     even a different row, which under concurrency would not conflict -
#     loses at once with
#       lock conflict on no wait transaction /
#       Acquire lock for relation ("PUBLIC"."<T>") failed
#   * a table the consistency transaction never touched stays free;
#   * an ORDINARY (concurrency) transaction takes only SHARED WRITE, so
#     two ordinary writers to different rows of one table do NOT conflict.
#
# ...and a consistency transaction reserves the tables it READS in
# PROTECTED READ too, so a concurrent writer to a table it only read
# loses the same way (PR excludes SW). An ordinary reader takes nothing.
#
# The rigs:
#   * qa/fbconsw.c - A (the given TPB) updates row 1 of T; B
#     (concurrency, NO WAIT) updates row 2 of T and then inserts into
#     the untouched U. The WRITE side.
#   * qa/fbcons.c  - A (the given TPB) reads T (COUNT); B (concurrency,
#     NO WAIT) inserts into T, then into the untouched U. The READ side.
# Each is run once with A = CONSISTENCY and once with A = CONCURRENCY,
# differentially against the engine.
#
# THE REMAINING BOUNDARY: the read reservation is best-effort NO WAIT -
# a consistency reader that meets a table ANOTHER writer already holds is
# left to read its snapshot rather than raising (the base read funnels
# have no channel to carry the lock error out). The gate exercises the
# reader-gets-there-first case, which is the common one.
#
#   qa/serve-real-consistency.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4739}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbconsw"
RRIG="$D/fc-fbcons"
CC() { cc -o "$1" "$(dirname "$0")/$2" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; }
if ! CC "$RIG" fbconsw.c || ! CC "$RRIG" fbcons.c; then
    echo "SKIP: cannot build the consistency rigs (cc/libfbclient missing)"; exit 0
fi
mkf() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
CREATE TABLE U (ID INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
COMMIT;
EOF
}
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cons-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$RRIG" "$D"/fc-cons-*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fi; [ "$2" = "$3" ] || fail=1; }
run() { # <conn> <A-tpb...>   - the WRITE rig
    local conn="$1"; shift
    timeout 20 "$RIG" "$conn" "$@" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
rrun() { # <conn> <A-tpb...>  - the READ rig
    local conn="$1"; shift
    timeout 20 "$RRIG" "$conn" "$@" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}

# --- CONSISTENCY: A's write reserves T; B's write to a DIFFERENT row loses ----
ef="$D/fc-cons-e1.fdb"; ff="$D/fc-cons-f1.fdb"
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "a consistency writer blocks a concurrent writer to the same table (and leaves an untouched one free)" \
    "$(run "localhost:$ef" 1 9 1 6)" "$(run "127.0.0.1/$PORT:$ff" 1 9 1 6)"
# and the vector itself, pinned
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "...and it is the relation-lock vector, naming the table" \
    "$(run "127.0.0.1/$PORT:$ff" 1 9 1 6)" \
    'A upd row1: OK|B upd row2 (diff row): lock conflict on no wait transaction | Acquire lock for relation ("PUBLIC"."T") failed ||B insert U: OK|'

# --- CONCURRENCY baseline: no table lock, the diff-row write goes through ------
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "an ordinary transaction takes no table lock (concurrency baseline)" \
    "$(run "localhost:$ef" 1 9 2 6)" "$(run "127.0.0.1/$PORT:$ff" 1 9 2 6)"

# --- CONSISTENCY READ: A's read of T reserves it; B's write to T loses --------
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "a consistency reader blocks a concurrent writer to the table it read (untouched one free)" \
    "$(rrun "localhost:$ef" 1 9 1 6)" "$(rrun "127.0.0.1/$PORT:$ff" 1 9 1 6)"
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "...and it is the relation-lock vector on the read table" \
    "$(rrun "127.0.0.1/$PORT:$ff" 1 9 1 6)" \
    'A read T: 2|B insert T: lock conflict on no wait transaction | Acquire lock for relation ("PUBLIC"."T") failed ||B insert U: OK|'
# an ORDINARY reader takes nothing, so B's write goes through
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "an ordinary reader takes no table lock (concurrency baseline)" \
    "$(rrun "localhost:$ef" 1 9 2 6)" "$(rrun "127.0.0.1/$PORT:$ff" 1 9 2 6)"

echo "ran $ran checks"
exit $fail
