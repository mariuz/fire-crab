#!/bin/bash
# SNAPSHOT ISOLATION - the engine's (and isql's) default, and the one
# fire-crab did not have: a transaction sees a STABLE view as of its
# start, not the latest committed. isql cannot open two concurrent
# transactions in one script, so the client is qa/fbsnap.c
# (libfbclient): attach A and B, A takes its view, B inserts and
# commits, and we ask whether A sees it.
#
#   * under SNAPSHOT (isc_tpb_concurrency): A does NOT see B's commit -
#     only a FRESH transaction of A's does;
#   * under READ COMMITTED: A sees each commit at once.
#
# Both run against BOTH servers and must answer the same three counts.
# Compiles the rig in-gate; SKIPS if cc/libfbclient are missing.
#
#   qa/serve-real-snapshot.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4734}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
RIG="$D/fc-fbsnap"
if ! cc -o "$RIG" "$(dirname "$0")/fbsnap.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the snapshot rig (cc/libfbclient missing)"; exit 0
fi
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
INSERT INTO T VALUES (1);
INSERT INTO T VALUES (2);
COMMIT;
EOF
}
# each isolation gets its OWN pair of fresh databases (the rig leaves a
# committed row behind), so the counts are deterministic
ESN="$D/fc-snap-e1.fdb"; FSN="$D/fc-snap-f1.fdb"
ERC="$D/fc-snap-e2.fdb"; FRC="$D/fc-snap-f2.fdb"
mkdb "localhost:$ESN"; mkdb "$FSN"; mkdb "localhost:$ERC"; mkdb "$FRC"
chmod 666 "$FSN" "$FRC" "$ESN" "$ERC" 2>/dev/null
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-snap-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ESN" "$FSN" "$ERC" "$FRC" "$RIG"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     engine: $2"; echo "     fcrab:  $3"; fail=1; fi; }

es=$("$RIG" "localhost:$ESN" snap 2>&1)
fs=$("$RIG" "127.0.0.1/$PORT:$FSN" snap 2>&1)
check "SNAPSHOT: a stable view (start / after commit / fresh) matches" "$es" "$fs"
# the engine's own answer is the reference shape
check "SNAPSHOT: and it is the stable 2 / 2 / 3" "$es" \
    "A sees at start: 2
A sees after B commits: 2
A sees in a fresh transaction: 3"

er=$("$RIG" "localhost:$ERC" read 2>&1)
fr=$("$RIG" "127.0.0.1/$PORT:$FRC" read 2>&1)
check "READ COMMITTED: sees each commit, matches" "$er" "$fr"
check "READ COMMITTED: and it is 2 / 3 / 3" "$er" \
    "A sees at start: 2
A sees after B commits: 3
A sees in a fresh transaction: 3"

echo "ran $ran checks"
exit $fail
