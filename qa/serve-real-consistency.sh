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
# The rig (qa/fbconsw.c): A (the given TPB) updates row 1 of T; B
# (concurrency, NO WAIT) updates row 2 of T and then inserts into the
# untouched U. Run once with A = CONSISTENCY and once with A =
# CONCURRENCY, differentially against the engine.
#
# THE READ-SIDE BOUNDARY: a consistency transaction also reserves the
# tables it READS (protected read), so a concurrent writer to a table it
# only read loses too. fire-crab reserves at the WRITE only, so that case
# does not yet conflict here - the write-anchored half is converted, the
# read-anchored half is the recorded next step.
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
if ! cc -o "$RIG" "$(dirname "$0")/fbconsw.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the consistency rig (cc/libfbclient missing)"; exit 0
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
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$D"/fc-cons-*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fail=1; fi; }
run() { # <conn> <A-tpb...>
    local conn="$1"; shift
    timeout 20 "$RIG" "$conn" "$@" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
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

echo "ran $ran checks"
exit $fail
