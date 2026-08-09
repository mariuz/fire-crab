#!/bin/bash
# TPB LOCK TIMEOUT - the WAIT/NO WAIT pair's missing middle. A WAIT
# transaction blocks until the holder ends (serve-real-concurrency); a
# NO WAIT one raises the conflict at once (serve-real-nowait). LOCK
# TIMEOUT N waits, but only N seconds - then it raises the SAME
# update-conflict vector the other two conflict shapes do:
#   deadlock / update conflicts with concurrent update /
#   concurrent transaction number is @1
# (measured: isc_tpb_lock_timeout=1 waits ~1s, then that three-item
# vector, naming the blocker). The rig (qa/fblto.c) holds A's update
# open and has B - concurrency, WAIT, lock_timeout 1 - hit the same row;
# B waits about a second and then loses.
#
#   qa/serve-real-locktimeout.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4737}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fblto"
if ! cc -o "$RIG" "$(dirname "$0")/fblto.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the lock-timeout rig (cc/libfbclient missing)"; exit 0
fi
mkf() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
COMMIT;
EOF
}
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-lto-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$D"/fc-lto-*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fail=1; fi; }
# the tx number varies; the "waited ~Ns" line varies by a tick either
# way, so pin it to the vector line alone
vec() { printf '%s' "$1" | sed -n 's/.*\(B(lto1s): .*\)/\1/p' | sed 's/number is [0-9]*/number is N/'; }
run() { vec "$(timeout 20 "$RIG" "$1" 2>&1)"; }

ef="$D/fc-lto-e.fdb"; ff="$D/fc-lto-f.fdb"
mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
check "LOCK TIMEOUT expiry raises the conflict, matches the engine" \
    "$(run "127.0.0.1/$PORT:$ff")" "$(run "localhost:$ef")"
check "...and it is the update-conflict vector, naming the blocker" \
    "$(run "127.0.0.1/$PORT:$ff")" \
    "B(lto1s): deadlock | update conflicts with concurrent update | concurrent transaction number is N | "
# it really WAITED - a NO WAIT would answer in well under a second; the
# timeout holds the caller about its full second before the conflict
waited=$(timeout 20 "$RIG" "127.0.0.1/$PORT:$ff" 2>&1 | sed -n 's/.*waited ~\([0-9]*\)s/\1/p')
check "...after actually waiting the timeout (>=1s)" \
    "$([ "${waited:-0}" -ge 1 ] && echo yes || echo no)" "yes"
echo "ran $ran checks"
exit $fail
