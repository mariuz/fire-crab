#!/bin/bash
# TPB NO WAIT - the last of W4. A WAIT transaction that meets a row
# another ACTIVE transaction holds blocks until that one ends (the lock
# manager, gated in serve-real-concurrency). A NO WAIT transaction does
# NOT block: the engine raises the update-conflict AT ONCE, naming the
# blocker -
#   deadlock / update conflicts with concurrent update /
#   concurrent transaction number is @1
# - the SAME vector as a committed conflict, and the SAME under both
# isolations (measured). The rig (qa/fbnowait.c) holds A's update open
# and has B (NO WAIT) hit the same row.
#
#   qa/serve-real-nowait.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4736}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbnowait"
if ! cc -o "$RIG" "$(dirname "$0")/fbnowait.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the no-wait rig (cc/libfbclient missing)"; exit 0
fi
mkf() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
COMMIT;
EOF
}
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nw-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$D"/fc-nw-*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fail=1; fi; }
norm() { printf '%s' "$1" | sed 's/number is [0-9]*/number is N/'; }
run() { norm "$(timeout 15 "$RIG" "$1" "$2" 2>&1)"; }
for iso in conc read; do
    ef="$D/fc-nw-e-$iso.fdb"; ff="$D/fc-nw-f-$iso.fdb"
    mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
    check "NO WAIT ($iso) raises the conflict at once, matches the engine" \
        "$(run "127.0.0.1/$PORT:$ff" "$iso")" "$(run "localhost:$ef" "$iso")"
done
check "...and it is the update-conflict vector, not a block" \
    "$(run "127.0.0.1/$PORT:$D/fc-nw-f-conc.fdb" conc)" \
    "B nowait: deadlock | update conflicts with concurrent update | concurrent transaction number is N | "
echo "ran $ran checks"
exit $fail
