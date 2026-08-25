#!/bin/bash
# SQZ PACK-ON-WRITE - every record fire-crab stores is now RLE-packed
# when that is smaller (the engine's own store law, sqz.cpp
# m_allowUnpacked: pack only when it shrinks, else raw with
# rhd_not_packed), and a new version a FULL page cannot take whole is
# fragmented in place of refusing (dpm.epp DPM_update ->
# store_big_record: head in the fixed slot, tail elsewhere).
#
# What this closed (measured): repeated ALTER DOMAIN cycles on an 8K
# database died at "no room on page 112" (RDB$FIELDS) after ~3 cycles -
# every fc catalog write landed UNPACKED where the engine RLE-packs,
# and a version that outgrew its crowded page was refused instead of
# fragmented. Both halves are exercised here ON 8K PAGES, the size that
# used to fail:
#   - 24 drop/add cycles through fire-crab, error-free, engine-verified
#   - the same cycles through the engine (its own file) and the
#     surviving catalog text compared differentially
#   - enforcement after the cycles, fc vs engine, same 23000 vector
#   - packed USER rows written by fc and read back by the ENGINE
#     byte-for-byte (compressible CHAR runs - the rows that pack)
#   - gfix -v -full silent on the fc-written file, gbak round trip
#
# Laws pinned by the writer (unit-pinned in ods, gate-pinned here):
#   - pack IFF smaller, per record and per fragment PIECE; blob data
#     is NEVER packed (its own path)
#   - the FILL pad to RHDF_SIZE lands on EVERY store, raw included
#     (dpm.epp:471 - the engine's fragment() writes an rhdf header into
#     the old slot assuming it); re-store sites trim the zero tail back
#     to fmt_length (engine BUGCHECK 179 otherwise)
#   - a fragmented catalog row stays updatable: the old head is CLONED
#     as the back version (forward pointer and all), the primary slot
#     gets a fresh head
#
#   qa/serve-real-sqzpack.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4991}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-sqzpack-crab.fdb"; B="$D/fc-sqzpack-engine.fdb"
LOG="/tmp/fc-serve-sqzpack-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
# 8K pages ON PURPOSE: the page size the unpacked writer could not
# survive three ALTER cycles on
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/fc-sqzpack.fbk" "$D/fc-sqzpack-r.fdb" "$D/sqzpack.sql" "$D/sqzpack-rows.sql"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/^ //; s/ *$//' | tr '\n' '|'; }
run() { "$ISQL" -q -ch NONE -user "$U" -pas "$P" "$1" -i "$2" 2>&1; }
q()   { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$1" 2>&1 | norm; }

# --- the ALTER cycle that used to die on 8K, 24 times over ---
{ printf 'CREATE DOMAIN DP AS INTEGER CHECK (VALUE > 10);\nCREATE TABLE T1 (A DP, B DP);\nCREATE TABLE T2 (A DP);\nCOMMIT;\n'
  i=1; while [ $i -le 24 ]; do
    printf 'ALTER DOMAIN DP DROP CONSTRAINT;\nALTER DOMAIN DP ADD CHECK (VALUE > %d);\n' "$i"
    i=$((i + 1)); done
  printf 'COMMIT;\n'; } > "$D/sqzpack.sql"

errs=$(run "127.0.0.1/$PORT:$A" "$D/sqzpack.sql" | grep -c "Statement failed")
check "24 ALTER DOMAIN cycles on 8K through fire-crab, error-free (was: no room on page 112)" "$errs" "0"
errs=$(run "127.0.0.1/${FC_REAL_PORT:-3050}:$B" "$D/sqzpack.sql" | grep -c "Statement failed")
check "the same cycles through the engine, error-free" "$errs" "0"

# the surviving catalog text, differentially (the blob read exercises
# fc's own read of the row it packed and re-fragmented 24 times)
SQL="SELECT CAST(F.RDB\$VALIDATION_SOURCE AS VARCHAR(60)) FROM RDB\$FIELDS F WHERE F.RDB\$FIELD_NAME = 'DP';"
check "the 24th check's source survives, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "$SQL")" "$(q "127.0.0.1/${FC_REAL_PORT:-3050}:$B" "$SQL")"

# enforcement after the churn: same 23000 vector both sides
SQL="INSERT INTO T1 VALUES (5, 100);"
check "the final check still enforces, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "$SQL")" "$(q "127.0.0.1/${FC_REAL_PORT:-3050}:$B" "$SQL")"

# --- packed USER rows: written by fc, read back by the ENGINE ---
{ printf 'CREATE TABLE PACKED (ID INTEGER, PAD CHAR(200), TXT VARCHAR(120));\nCOMMIT;\n'
  i=1; while [ $i -le 30 ]; do
    printf "INSERT INTO PACKED VALUES (%d, 'x', 'run %d then spaces');\n" "$i" "$i"
    i=$((i + 1)); done
  printf "UPDATE PACKED SET TXT = TXT || ' grown after the fact' WHERE ID <= 15;\nCOMMIT;\n"; } > "$D/sqzpack-rows.sql"
errs=$(run "127.0.0.1/$PORT:$A" "$D/sqzpack-rows.sql" | grep -c "Statement failed")
check "30 compressible rows + growing UPDATE through fire-crab, error-free" "$errs" "0"
SQL="SELECT ID, CHAR_LENGTH(PAD), TXT FROM PACKED WHERE ID IN (1, 15, 16, 30) ORDER BY ID;"
FCROWS=$(q "127.0.0.1/$PORT:$A" "$SQL")
check "fc reads its own packed rows" \
    "$FCROWS" "1 200 run 1 then spaces grown after the fact|15 200 run 15 then spaces grown after the fact|16 200 run 16 then spaces|30 200 run 30 then spaces|"
# the engine, straight onto the file fc wrote (the server is done with
# it once the connection above closed; local attach reads committed state)
check "the ENGINE reads fc's packed rows byte-for-byte" "$(q "$A" "$SQL")" "$FCROWS"

# --- structure: silent validation and a gbak round trip ---
V=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "gfix -v -full is silent on the packed file" "$V" ""
rm -f "$D/fc-sqzpack.fbk" "$D/fc-sqzpack-r.fdb"
"$GBAK" -b -user "$U" -pas "$P" "$A" "$D/fc-sqzpack.fbk" >/dev/null 2>&1 \
    && "$GBAK" -c -user "$U" -pas "$P" "$D/fc-sqzpack.fbk" "$D/fc-sqzpack-r.fdb" >/dev/null 2>&1
check "gbak round-trips the packed file; the restore keeps every row" \
    "$(q "$D/fc-sqzpack-r.fdb" "SELECT COUNT(*) FROM PACKED;")" "30|"

echo
if [ "$fail" = 0 ]; then echo "PASS all $ran checks"; else echo "FAIL"; exit 1; fi
