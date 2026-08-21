#!/bin/bash
# ARRAYS: op_get_slice (58) / op_put_slice (59) / op_slice (60) over ARRAY
# columns. An ARRAY column holds the id of an ARRAY BLOB - a stream blob
# of Ods::InternalArrayDesc (16 bytes + 24 per dimension) then the
# elements row-major in memory form (blb.cpp store_array / get_array);
# the client names a slice with the SDL gen_sdl emits (the element
# struct, relation and field, a do-loop per dimension, the scalar's
# variables) and the elements travel xdr'd by type. fire-crab's DDL takes
# `<type> [l:u, ...]` (RDB$FIELDS RDB$DIMENSIONS + RDB$FIELD_DIMENSIONS
# rows, the record field dtype_array), a put over a zero id makes a temp
# array the store materialises like a temp blob, and a get reads the
# stored blob (or the temp) through the header's strides.
#
# The client (qa/c/arrays.c, legacy API) builds its ISC_ARRAY_DESC by
# hand: isc_array_lookup_bounds queries the catalog through
# system.rdb$sql.parse_unqualified_names - a surface this server does not
# have (recorded). Text-element arrays are not taken (recorded).
#
#   qa/serve-real-arrays.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4865}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-arrays-engine.fdb"; DBF="$D/fc-arrays-crab.fdb"
LOG="/tmp/fc-serve-arrays-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O1 -o "$D/arrays" "$(dirname "$0")/c/arrays.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE AR (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER [1:5], M DOUBLE PRECISION [0:1, 1:3]);
COMMIT;
SQL
}
rm -f "$DBE" "$DBF" "$D/fc-arrays.fbk"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D/fc-arrays.fbk"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

E=$("$D/arrays" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/arrays" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
# the ENGINE reads the arrays fc stored - and fc's own DDL's table
R=$("$D/arrays" "127.0.0.1/$REAL:$DBF" readonly 2>&1)
W=$("$D/arrays" "127.0.0.1/$REAL:$DBE" readonly 2>&1)
check "the ENGINE reads the arrays fc stored (incl. fc's CREATE TABLE AR2)" "$R" "$W"
ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
if [ -z "$g" ]; then echo "OK   gfix -v -full finds nothing on fc's file"; else echo "DIFF gfix: $g"; fail=1; fi
ran=$((ran + 1)); if "$GBAK" -b -user "$U" -pas "$P" "$DBF" "$D/fc-arrays.fbk" >/dev/null 2>&1; then echo "OK   gbak -b carries fc's file"; else echo "DIFF gbak -b failed"; fail=1; fi
ran=$((ran + 1)); a=$(grep -c 'op_put_slice' "$LOG"); b=$(grep -c 'op_get_slice' "$LOG")
if [ "$a" -ge 3 ] && [ "$b" -ge 5 ]; then echo "OK   coverage: $a puts, $b gets through the server"; else echo "DIFF coverage: puts $a gets $b"; fail=1; fi
echo "ran $ran checks"
exit $fail
