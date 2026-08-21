#!/bin/bash
# op_fetch_scroll (112, protocol 18): a statement executed with
# CURSOR_TYPE_SCROLLABLE scrolls over its result - NEXT, PRIOR, FIRST,
# LAST, ABSOLUTE n (from the first row, or from past the last when
# negative; 0 parks the cursor before the first), RELATIVE k (from the
# current row; 0 re-reads it) - with the engine's positioning rules
# (jrd/recsrc/Cursor.cpp, dsql/DsqlCursor.cpp): a move past either end
# parks the cursor there and answers no row, and the next move counts
# from that end. fire-crab buffers the result at the first fetch (the
# engine's BufferedStream) and answers each operation from it; NEXT and
# PRIOR deliver up to the client's batch, the positioned fetches one. A
# cursor opened WITHOUT the flag refuses every scroll op with
# isc_invalid_fetch_option, naming the option.
#
# The client is qa/c/scroll.cpp over the OO API (IResultSet): the only
# API that scrolls; its own prefetch and relative re-positioning (when
# the direction turns with rows still cached) run against both servers.
#
#   qa/serve-real-scroll.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4845}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-scroll-engine.fdb"; DBF="$D/fc-scroll-crab.fdb"
LOG="/tmp/fc-serve-scroll-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v g++ >/dev/null 2>&1 || { echo "SKIP g++ not found"; exit 0; }
[ -f "$FBINC/firebird/Interface.h" ] || { echo "SKIP $FBINC/firebird/Interface.h not found"; exit 0; }
g++ -std=c++17 -O1 -o "$D/scroll" "$(dirname "$0")/c/scroll.cpp" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
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
E=$("$D/scroll" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/scroll" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
ran=$((ran + 1)); a=$(grep -c 'scrollable cursor:' "$LOG"); b=$(grep -c 'fetch: .*op [1-5]' "$LOG")
if [ "$a" -ge 1 ] && [ "$b" -ge 20 ]; then echo "OK   coverage: $a scrollable cursor buffered, $b scroll ops served"; else echo "DIFF coverage: buffered $a scroll ops $b"; fail=1; fi
echo "ran $ran checks"
exit $fail
