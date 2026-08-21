#!/bin/bash
# Blob PARAMETERS in UPDATE ... SET and UPDATE OR INSERT: a temp blob id
# passed as a ? is materialised at the store (blb.cpp blb::move) just as
# at an INSERT - the engine's laws, measured by qa/c/blobupdate.c against
# the live engine: a NULL indicator stores NULL; an ALL-ZERO quad stores
# an EMPTY blob (len 0, not NULL); ONE temp id may feed SEVERAL rows of
# one UPDATE (each gets its own copy); the PERMANENT id of another row's
# blob is accepted and COPIED (a new id, the source row still reads); a
# text blob created without a bpb lands in a SUB_TYPE 1 column as is;
# UPDATE OR INSERT takes a temp blob on both branches; a rolled-back
# update leaves the old blob; a temp id from a committed or rolled-back
# transaction is "invalid BLOB ID". The client's output is compared line
# by line against the engine's.
#
#   qa/serve-real-blobupdate.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4853}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-blobupdate-engine.fdb"; DBF="$D/fc-blobupdate-crab.fdb"
LOG="/tmp/fc-serve-blobupdate-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O1 -o "$D/blobupdate" "$(dirname "$0")/c/blobupdate.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, SEG BLOB SUB_TYPE 0, TXT BLOB SUB_TYPE 1);
COMMIT;
INSERT INTO B VALUES (1, 10, 'seed-one', 'text-one');
INSERT INTO B VALUES (2, 20, 'seed-two', 'text-two');
INSERT INTO B VALUES (3, 30, 'seed-three', 'text-three');
INSERT INTO B VALUES (4, 40, 'seed-four', 'text-four');
COMMIT;
SQL
}
rm -f "$DBE" "$DBF" "$D/fc-blobupdate.fbk"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D/fc-blobupdate.fbk"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

E=$("$D/blobupdate" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/blobupdate" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: ${el:0:80}" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
lens() { printf 'SET HEADING OFF;\nSELECT ID, OCTET_LENGTH(SEG), OCTET_LENGTH(TXT) FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
check "the ENGINE reads the blobs fc stored" "$(lens "127.0.0.1/$REAL:$DBF")" "$(lens "127.0.0.1/$REAL:$DBE")"
ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
if [ -z "$g" ]; then echo "OK   gfix -v -full finds nothing on fc's file"; else echo "DIFF gfix: $g"; fail=1; fi
ran=$((ran + 1)); if "$GBAK" -b -user "$U" -pas "$P" "$DBF" "$D/fc-blobupdate.fbk" >/dev/null 2>&1; then echo "OK   gbak -b carries fc's file"; else echo "DIFF gbak -b failed"; fail=1; fi
echo "ran $ran checks"
exit $fail
