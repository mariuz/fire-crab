#!/bin/bash
# op_info_transaction (42) - isc_transaction_info, every item: tra_id,
# oldest_interesting / oldest_snapshot / oldest_active (4-byte numbers
# that obey id >= oat >= ost >= oit > 0 on both servers - the VALUES
# depend on each server's history), isolation (consistency 1,
# concurrency 2, read committed 3 + the READ CONSISTENCY option 2 for
# every read-committed flavour on this engine), access (0 read-only / 1
# read-write), lock_timeout (-1 wait, 0 no wait, N seconds),
# fb_info_tra_dbpath (the name as attached, answered FIRST whenever
# asked), fb_info_tra_snapshot_number (0 when read committed), items in
# REQUEST order with repeats repeated and an unknown item answered
# isc_info_error, a buffer the answer does not fit ending in
# isc_info_truncated; and isc_tpb_at_snapshot_number naming a snapshot
# nobody holds is refused at start. Client qa/c/trainfo.c (legacy API).
#
#   qa/serve-real-trainfo.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4869}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-trainfo-engine.fdb"; DBF="$D/fc-trainfo-crab.fdb"
LOG="/tmp/fc-serve-trainfo-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O0 -o "$D/trainfo" "$(dirname "$0")/c/trainfo.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
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
# the attach string is answered verbatim - the port and file differ by construction
E=$("$D/trainfo" "127.0.0.1/$REAL:$DBE" 2>&1 | sed "s#/$REAL:$DBE#/PORT:DB#")
C=$("$D/trainfo" "127.0.0.1/$PORT:$DBF" 2>&1 | sed "s#/$PORT:$DBF#/PORT:DB#")
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
ran=$((ran + 1)); a=$(grep -c 'op_info_transaction items' "$LOG")
if [ "$a" -ge 24 ]; then echo "OK   coverage: $a info requests served"; else echo "DIFF coverage: info requests $a"; fail=1; fi
echo "ran $ran checks"
exit $fail
