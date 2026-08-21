#!/bin/bash
# op_info_blob (43) and op_seek_blob (61), and op_get_segment's framing
# for a SEGMENTED blob: the remote server packs WHOLE segments into the
# client's buffer, one [u16 LE len][bytes] frame each, and answers
# resp_object 1 when the last frame is a partial segment (isc_segment),
# 2 at EOF (server.cpp get_segment) - a client reading segment by
# segment sees the segments it wrote, not one run. isc_blob_info answers
# num_segments (blb_count: one per put), max_segment, total_length and
# type on the read AND the write handle; isc_seek_blob is stream-only
# (isc_bad_segstr_type on a segmented blob), its position clamped to
# [0, length] in all three modes (blb.cpp BLB_lseek).
#
# The client is qa/c/blobinfo.c against libfbclient - the only client
# on this box that issues the two ops; node-firebird has neither. Its
# output is compared line by line against the engine's.
#
#   qa/serve-real-blobinfo.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4839}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-blobinfo-engine.fdb"; DBF="$D/fc-blobinfo-crab.fdb"
LOG="/tmp/fc-serve-blobinfo-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
fail=0; ran=0
mkdir -p "$D"
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O1 -o "$D/blobinfo" "$(dirname "$0")/c/blobinfo.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" || { echo "FAIL compile"; exit 1; }
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, SEG BLOB SUB_TYPE 0, STR BLOB SUB_TYPE 0);
COMMIT;
SQL
}
rm -f "$DBE" "$DBF" "$D/fc-blobinfo.fbk"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D/fc-blobinfo.fbk"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

E=$("$D/blobinfo" "127.0.0.1/$REAL:$DBE" 2>&1)
C=$("$D/blobinfo" "127.0.0.1/$PORT:$DBF" 2>&1)
n=$(echo "$E" | wc -l)
i=1
while [ $i -le $n ]; do
    el=$(echo "$E" | sed -n "${i}p"); cl=$(echo "$C" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$C" | wc -l)" "$n"
# INLINE MODE: the client keeps its default inline-blob size, so both
# servers ship the small blobs WITH the row (op_inline_blob, protocol 19)
# and the client answers info / seek / get_segment from its copy - the
# stream blob now reads back in max_segment pieces on both sides. A
# second row, so the twin databases stay in step.
E2=$("$D/blobinfo" "127.0.0.1/$REAL:$DBE" inline 2>&1)
C2=$("$D/blobinfo" "127.0.0.1/$PORT:$DBF" inline 2>&1)
n2=$(echo "$E2" | wc -l)
i=1
while [ $i -le $n2 ]; do
    el=$(echo "$E2" | sed -n "${i}p"); cl=$(echo "$C2" | sed -n "${i}p")
    check "inline, line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "inline: the same number of lines" "$(echo "$C2" | wc -l)" "$n2"
check "the ENGINE reads the blobs fc stored" \
    "$(printf 'SET HEADING OFF;\nSELECT OCTET_LENGTH(SEG), OCTET_LENGTH(STR) FROM B ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBF" 2>&1 | tr -s ' \n' ' ')" " 314 50 314 50 "
ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
if [ -z "$g" ]; then echo "OK   gfix -v -full finds nothing on fc's file"; else echo "DIFF gfix: $g"; fail=1; fi
ran=$((ran + 1)); if "$GBAK" -b -user "$U" -pas "$P" "$DBF" "$D/fc-blobinfo.fbk" >/dev/null 2>&1; then echo "OK   gbak -b carries fc's file"; else echo "DIFF gbak -b failed"; fail=1; fi
ran=$((ran + 1)); a=$(grep -c 'info blob' "$LOG"); b=$(grep -c 'seek blob' "$LOG"); c=$(grep -c 'inline blob' "$LOG")
if [ "$a" -ge 4 ] && [ "$b" -ge 8 ] && [ "$c" -ge 2 ]; then echo "OK   coverage: $a info, $b seek through the server, $c blobs shipped inline"; else echo "DIFF coverage: info $a seek $b inline $c"; fail=1; fi
echo "ran $ran checks"
exit $fail
