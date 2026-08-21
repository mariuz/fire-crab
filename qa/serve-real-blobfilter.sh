#!/bin/bash
# BLOB columns from fire-crab's OWN DDL, literals into them, and blob
# filters. Until this slice every blob table a gate used was an
# engine-built fixture: fc's CREATE TABLE had no BLOB type at all and a
# literal could not land in a blob column. Now: `BLOB [SUB_TYPE
# {n|TEXT|BINARY}] [SEGMENT SIZE n] [CHARACTER SET cs]` (RDB$FIELDS type
# 261, length 8, the sub_type, SEGMENT_LENGTH 80 unless declared, a text
# blob's charset id - which is also what DESCRIBE announces in sqlscale);
# a string literal (sub_type 1) and an `_octets` literal (sub_type 0)
# stored as blobs of the relation at INSERT and UPDATE, the engine's
# filter law between them (no filter converts TEXT into a user sub_type:
# isc_nofilter 1 -> -5; binary lands anywhere; an UPDATE matching no row
# raises nothing); the blob API read with a bpb naming a source/target
# sub_type (no filter needed for same/same, to binary, or binary to
# text; isc_nofilter(from, to) otherwise); DECLARE FILTER / DROP FILTER
# with the engine's vectors (a duplicate name, a duplicate (input,
# output) pair = the unique violation on RDB$INDEX_17, a missing name);
# a declared filter whose module is not there still converts nothing;
# `BLOB SUB_TYPE 2` refused at CREATE TABLE with the engine's nested
# -204; `IS NULL` over a blob column. Client qa/c/blobcol.c prints status
# vectors raw, so the codes and their arguments are compared.
#
# Recorded boundaries: CAST(<blob> AS VARCHAR) is outside fc's expression
# engine (the client reads blobs through the blob API instead); the
# internal filters of the system sub_types (BLR/ACL/... -> text) are not
# mirrored; a text-blob DOMAIN's charset does not reach the descriptor.
#
#   qa/serve-real-blobfilter.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4871}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-blobfilter-engine.fdb"; DBF="$D/fc-blobfilter-crab.fdb"
LOG="/tmp/fc-serve-blobfilter-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O0 -o "$D/blobcol" "$(dirname "$0")/c/blobcol.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile"; exit 1; }
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
E=$("$D/blobcol" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/blobcol" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
# the ENGINE reads the table fc's DDL made, blobs and all
ran=$((ran + 1))
eng=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBF" <<'SQL' 2>&1 | tr -s ' \n' ' '
SET HEADING OFF;
SELECT ID, CAST(T AS VARCHAR(20)), CAST(Z AS VARCHAR(20)) FROM BC WHERE ID IN (1, 2) ORDER BY ID;
SELECT COUNT(*) FROM RDB$FILTERS;
SQL
)
case "$eng" in *"2 text two again"*" 0 "*|*"1 "*"abc"*) echo "OK   the engine reads fc's blob table: [$eng]";; *) echo "DIFF the engine reads fc's blob table: [$eng]"; fail=1;; esac
echo "ran $ran checks"
exit $fail
