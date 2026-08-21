#!/bin/bash
# op_ping (93) and op_transact (79) / op_transact_response (80):
# IAttachment::ping is a bare op answered clean; transactRequest is the
# legacy isc_transact_request - a BLR request with its input message
# (message 0) run to completion in ONE round trip, the output message
# (message 1) coming back in the response. fire-crab compiles the BLR
# through the same parser its isql SHOW support uses (a for-loop over a
# relation, receive, send, parameters), runs it, and answers the first
# message-1 the program sent. A BLR it cannot parse is an error on both
# sides (the engine's vector names the BLR position; fc's is the generic
# SQL error - the gate compares the first word).
#
#   qa/serve-real-transact.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4859}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-transact-engine.fdb"; DBF="$D/fc-transact-crab.fdb"
LOG="/tmp/fc-serve-transact-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v g++ >/dev/null 2>&1 || { echo "SKIP g++ not found"; exit 0; }
[ -f "$FBINC/firebird/Interface.h" ] || { echo "SKIP $FBINC/firebird/Interface.h not found"; exit 0; }
g++ -std=c++17 -O1 -o "$D/transact" "$(dirname "$0")/c/transact.cpp" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE S (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(10));
COMMIT;
INSERT INTO S VALUES (1, 'one'); INSERT INTO S VALUES (2, 'two'); INSERT INTO S VALUES (3, 'three');
INSERT INTO S VALUES (4, 'four'); INSERT INTO S VALUES (5, 'five'); INSERT INTO S VALUES (6, 'six'); INSERT INTO S VALUES (7, 'seven');
COMMIT;
SQL
}
rm -f "$DBE" "$DBF"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
E=$("$D/transact" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/transact" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
ran=$((ran + 1)); a=$(grep -c 'op_transact blr' "$LOG")
if [ "$a" -ge 3 ]; then echo "OK   coverage: $a transact requests served"; else echo "DIFF coverage: transact $a"; fail=1; fi
echo "ran $ran checks"
exit $fail
