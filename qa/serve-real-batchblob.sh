#!/bin/bash
# BLOBS INSIDE A BATCH (op_batch_blob_stream 105, op_batch_set_bpb 106,
# op_batch_regblob 104; IBatch addBlob / appendBlobData / setDefaultBpb
# / registerBlob / addBlobStream, DsqlBatch.cpp): the blobs travel in
# the batch's blob stream ahead of the messages - per blob a 4-aligned
# header (batch id, total length, bpb length), the bpb, the data
# (segmented: [u16 len][bytes] per segment, 2-aligned; stream: one run)
# - each message's blob field names one by its BATCH id, and execute()
# stores them: fire-crab turns the stream into closed temp blobs and
# re-spells every message's id to the blob it stands for, ONCE (a second
# message naming the same id, or an id never sent, is isc_batch_blob_id
# and fails the whole execute before any message runs); a registered id
# stands for an EXISTING blob, which the store then copies. Policies
# BLOB_ID_ENGINE, BLOB_ID_USER and BLOB_STREAM (the stream built by the
# client) all run, the engine's answers line for line.
#
#   qa/serve-real-batchblob.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4855}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-batchblob-engine.fdb"; DBF="$D/fc-batchblob-crab.fdb"
LOG="/tmp/fc-serve-batchblob-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v g++ >/dev/null 2>&1 || { echo "SKIP g++ not found"; exit 0; }
[ -f "$FBINC/firebird/Interface.h" ] || { echo "SKIP $FBINC/firebird/Interface.h not found"; exit 0; }
g++ -std=c++17 -O1 -o "$D/batchblob" "$(dirname "$0")/c/batchblob.cpp" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, SEG BLOB SUB_TYPE 0, TXT BLOB SUB_TYPE 1);
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
E=$("$D/batchblob" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/batchblob" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
ran=$((ran + 1)); a=$(grep -c 'batch blob stream:' "$LOG"); b=$(grep -c 'batch blobs:' "$LOG")
if [ "$a" -ge 5 ] && [ "$b" -ge 5 ]; then echo "OK   coverage: $a blob-stream packets, $b executes mapped their blobs"; else echo "DIFF coverage: stream packets $a mapped $b"; fail=1; fi
check "the ENGINE reads the rows fc's batches stored" \
    "$(printf 'SET HEADING OFF;\nSELECT ID, N, OCTET_LENGTH(SEG), OCTET_LENGTH(TXT) FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBF" 2>&1 | tr -s ' \n' ' ')" \
    "$(printf 'SET HEADING OFF;\nSELECT ID, N, OCTET_LENGTH(SEG), OCTET_LENGTH(TXT) FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBE" 2>&1 | tr -s ' \n' ' ')"
echo "ran $ran checks"
exit $fail
