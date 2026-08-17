#!/bin/bash
# UPDATE CONFLICT under snapshot - the write half of snapshot
# isolation. A snapshot transaction may READ a stable view (Inc445),
# but it may NOT write over a row another transaction committed after
# its snapshot began: the engine answers
#   deadlock / update conflicts with concurrent update /
#   concurrent transaction number is @1
# The rig (qa/fbconf.c) drives two attachments: A takes a snapshot, B
# modifies+commits row 1, A then writes row 1. Measured uniform across
# UPDATE-over-update, DELETE-over-update and UPDATE-over-delete. Under
# READ COMMITTED A writes B's latest with no conflict.
#
#   qa/serve-real-updateconflict.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4735}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbconf"
if ! cc -o "$RIG" "$(dirname "$0")/fbconf.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the conflict rig (cc/libfbclient missing)"; exit 0
fi
mkf() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
COMMIT;
EOF
}
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-uc-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RIG" "$D"/fc-uc-*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fail=1; fi; }
# the concurrent transaction id differs between servers - normalize it
norm() { printf '%s' "$1" | sed 's/number is [0-9]*/number is N/'; }
run() { # <conn> <op> [read]
    norm "$("$RIG" "$1" "$2" ${3:-} 2>&1)"
}
for op in update delete del-by-b; do
    ef="$D/fc-uc-e-$op.fdb"; ff="$D/fc-uc-f-$op.fdb"
    mkf "localhost:$ef"; mkf "$ff"; chmod 666 "$ef" "$ff" 2>/dev/null
    check "SNAPSHOT $op-over-commit: the update-conflict vector matches" \
        "$(run "127.0.0.1/$PORT:$ff" "$op")" "$(run "localhost:$ef" "$op")"
done
# read committed: A writes B's latest, no conflict, on both
er="$D/fc-uc-e-rc.fdb"; fr="$D/fc-uc-f-rc.fdb"
mkf "localhost:$er"; mkf "$fr"; chmod 666 "$er" "$fr" 2>/dev/null
check "READ COMMITTED: A writes over B's commit, no conflict" \
    "$(run "127.0.0.1/$PORT:$fr" update read)" "$(run "localhost:$er" update read)"
check "...and that is a plain success" "$(run "127.0.0.1/$PORT:$fr" update read)" "A after B: SUCCEEDED"
echo "ran $ran checks"
exit $fail
