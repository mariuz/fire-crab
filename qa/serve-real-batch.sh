#!/bin/bash
# The BATCH API over the wire (op_batch_create 99, op_batch_msg 100,
# op_batch_exec 101, op_batch_rls 102, op_batch_cancel 109, op_batch_sync
# 110; IBatch / DsqlBatch.cpp): the client queues a prepared DML
# statement's input messages and runs them in one round trip; the reply
# (op_batch_cs) is a completion state - per message its update count
# under TAG_RECORD_COUNTS (SUCCESS_NO_INFO without), EXECUTE_FAILED for
# a failure, each failure's position with its status vector up to
# TAG_DETAILED_ERRORS (64 by default) and the positions of the rest; the
# run stops at the first failure unless TAG_MULTIERROR. A second
# createBatch on a statement supersedes the open one (probed). fire-crab
# runs each message through the ordinary DML path (its own statement
# undo), so a failed message leaves nothing and the next one runs.
#
# The client is qa/c/batch.cpp over the OO API - the only API with a
# batch. Blobs inside a batch (op_batch_regblob / blob_stream / set_bpb)
# are not taken yet.
#
#   qa/serve-real-batch.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4847}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-batch-engine.fdb"; DBF="$D/fc-batch-crab.fdb"
LOG="/tmp/fc-serve-batch-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v g++ >/dev/null 2>&1 || { echo "SKIP g++ not found"; exit 0; }
[ -f "$FBINC/firebird/Interface.h" ] || { echo "SKIP $FBINC/firebird/Interface.h not found"; exit 0; }
g++ -std=c++17 -O1 -o "$D/batch" "$(dirname "$0")/c/batch.cpp" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(10));
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
E=$("$D/batch" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/batch" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
ran=$((ran + 1)); a=$(grep -c 'batch create:' "$LOG"); b=$(grep -c 'batch exec:' "$LOG"); c=$(grep -c 'batch message .* failed' "$LOG")
if [ "$a" -ge 6 ] && [ "$b" -ge 6 ] && [ "$c" -ge 4 ]; then echo "OK   coverage: $a batches created, $b executed, $c failed messages reported"; else echo "DIFF coverage: created $a executed $b failed $c"; fail=1; fi
check "the ENGINE reads the rows fc's batches stored" \
    "$(printf 'SET HEADING OFF;\nSELECT ID, V FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBF" 2>&1 | tr -s ' \n' ' ')" \
    "$(printf 'SET HEADING OFF;\nSELECT ID, V FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBE" 2>&1 | tr -s ' \n' ' ')"
echo "ran $ran checks"
exit $fail
