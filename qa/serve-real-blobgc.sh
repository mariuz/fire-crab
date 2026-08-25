#!/bin/bash
# CATALOG BLOB GC - a catalog patch that REPLACES or NULLs a blob field
# (the RDB$RUNTIME summary every ALTER rewrites, an ALTER DOMAIN's
# validation pair, a re-granted ACL, a re-COMMENTed description) now
# FREES the superseded blob's slot instead of leaking it forever.
#
# The engine's law (mapped, vio.cpp/blb.cpp): a user-transaction
# catalog update leaves the old blob to the version GC - purge on the
# next read (vio.cpp:1694 -> BLB_garbage_collect:5649) frees it, with
# identity the (relation, record-number) id and a going-minus-staying
# diff (blb.cpp:424: a blob still named by the staying image is NOT
# freed). fire-crab's sweep skips blob-bearing relations, so COMMIT is
# the one moment this server can free: patch sites capture the old id
# before overwriting, the free is deferred work (DdlDeferred::FreeBlob,
# applied with the other dfw.epp phases before the TIP flip), a
# ROLLBACK simply drops it (the restored row still names the blob), and
# the frees are HELD BACK when another WRITING transaction is active at
# commit (a snapshot may still step to the old row version).
# A rolled-back DDL's own freshly-minted blobs need no counterpart: the
# page-image undo erases them with their pages (a by-hand free there
# DOUBLE-freED the restored slot - measured, reverted).
#
# Observable: gstat -r's per-relation "Blobs: N" (dba.epp:1148 - live
# blh slots on the relation's pages). Before this, 40 ALTER DOMAIN
# cycles left 2 blobs per cycle on RDB$FIELDS and one RDB$RUNTIME per
# cycle on RDB$RELATIONS; now the counts stay FLAT, at or below the
# engine's own (its lazy purge trails by a cycle or two).
#
#   qa/serve-real-blobgc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"; GSTAT="${GSTAT:-gstat}"
PORT="${1:-4992}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-blobgc-crab.fdb"; B="$D/fc-blobgc-engine.fdb"
LOG="/tmp/fc-serve-blobgc-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/fc-blobgc.fbk" "$D/fc-blobgc-r.fdb" "$D/blobgc.sql" "$D/blobgc2.sql"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
bounded() { ran=$((ran + 1)); if [ -n "$2" ] && [ "$2" -le "$3" ]; then echo "OK   $1 ($2 <= $3)"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     cap:  [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/^ //; s/ *$//' | tr '\n' '|'; }
q() { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$1" 2>&1 | norm; }
# gstat -r "Blobs: N" for one system relation of a CLOSED file
blobs_of() { "$GSTAT" -a -r -s -t "$2" -user "$U" -pas "$P" "$1" 2>/dev/null \
    | grep -m1 'Blobs:' | sed 's/.*Blobs: \([0-9]*\),.*/\1/'; }

# --- 40 ALTER DOMAIN cycles: the leak that motivated the GC ---
{ printf 'CREATE DOMAIN DP AS INTEGER CHECK (VALUE > 10);\nCREATE TABLE T1 (A DP, B DP);\nCOMMIT;\n'
  i=1; while [ $i -le 40 ]; do
    printf 'ALTER DOMAIN DP DROP CONSTRAINT;\nALTER DOMAIN DP ADD CHECK (VALUE > %d);\n' "$i"
    i=$((i + 1)); done
  printf 'COMMIT;\n'; } > "$D/blobgc.sql"
errs=$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/blobgc.sql" 2>&1 | grep -c "Statement failed")
check "40 ALTER DOMAIN cycles through fire-crab, error-free" "$errs" "0"
errs=$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/blobgc.sql" 2>&1 | grep -c "Statement failed")
check "the same cycles through the engine, error-free" "$errs" "0"

# the counts, off the CLOSED files (fcwire holds no file open between
# attachments; the engine file is engine-owned throughout)
FA=$(blobs_of "$A" 'RDB$FIELDS'); FE=$(blobs_of "$B" 'RDB$FIELDS')
RA=$(blobs_of "$A" 'RDB$RELATIONS'); RE=$(blobs_of "$B" 'RDB$RELATIONS')
# the leak was 2 per cycle (80+) on RDB$FIELDS and 1 per cycle (40+) on
# RDB$RELATIONS; flat means "a handful, at or below the engine's lazy
# trail". The engine's exact residue depends on its GC timing - cap it.
bounded "fc RDB\$FIELDS blob slots stay flat after 40 cycles" "$FA" "8"
bounded "fc RDB\$RELATIONS blob slots stay flat after 40 cycles" "$RA" "28"
bounded "engine RDB\$FIELDS blob slots (its own lazy purge)" "$FE" "16"
bounded "engine RDB\$RELATIONS blob slots" "$RE" "40"

# --- enforcement still exact after the churn, fc == engine ---
SQL="INSERT INTO T1 VALUES (5, 100);"
check "the 40th check enforces, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "$SQL")" "$(q "127.0.0.1/$REAL:$B" "$SQL")"

# --- ROLLBACK: the deferred free is dropped (old blob survives) and
# the statement's own mints are freed (MintedBlob residue). The
# post-rollback INSERT runs in a FRESH session: the engine's own
# session is POISONED after a rolled-back DDL transaction (every later
# lookup in that attachment answers -204 "Table unknown", qualified or
# not, until reattach - measured on the live engine; fc does not
# reproduce the quirk, so same-session enforcement would diff).
cat > "$D/blobgc2.sql" <<'SQL'
SET AUTODDL OFF;
ALTER DOMAIN DP DROP CONSTRAINT;
ALTER DOMAIN DP ADD CHECK (VALUE > 999);
ROLLBACK;
SET HEADING OFF;
SELECT CAST(F.RDB$VALIDATION_SOURCE AS VARCHAR(40)) FROM RDB$FIELDS F WHERE F.RDB$FIELD_NAME = 'DP';
SQL
check "a rolled-back ALTER cycle keeps the old check, fc == engine" \
    "$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/blobgc2.sql" 2>&1 | norm)" \
    "$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/blobgc2.sql" 2>&1 | norm)"
check "...and it still enforces, in a fresh session, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "INSERT INTO T1 VALUES (12, 100);")" \
    "$(q "127.0.0.1/$REAL:$B" "INSERT INTO T1 VALUES (12, 100);")"
# the rolled-back statement's own mints STAY, beside the dead row
# versions that name them - blob and referencing version always go
# together (freeing the slot and letting the engine's version GC later
# collect the dead version would make it free the slot's NEW occupant
# - measured, the gbak "BLOB not found" class). The engine's sweep
# collects both at once, which is the proof of consistency:
FA2=$(blobs_of "$A" 'RDB$FIELDS')
check "...the rolled-back mints stay beside their dead versions (+2)" "$FA2" "$((FA + 2))"
"$GFIX" -sweep -user "$U" -pas "$P" "$A" >/dev/null 2>&1
FA3=$(blobs_of "$A" 'RDB$FIELDS')
check "...and the ENGINE's sweep collects dead versions and mints together" "$FA3" "$FA"

# --- GRANT/REVOKE + COMMENT churn: the ACL and description blobs ---
{ printf 'CREATE TABLE GT (ID INTEGER);\nCOMMIT;\n'
  i=1; while [ $i -le 20 ]; do
    printf "GRANT SELECT ON GT TO PUBLIC;\nREVOKE SELECT ON GT FROM PUBLIC;\nCOMMENT ON TABLE GT IS 'note %d of some length';\n" "$i"
    i=$((i + 1)); done
  printf 'COMMIT;\n'; } > "$D/blobgc2.sql"
errs=$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/blobgc2.sql" 2>&1 | grep -c "Statement failed")
check "20 GRANT/REVOKE + COMMENT cycles through fire-crab, error-free" "$errs" "0"
errs=$("$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/blobgc2.sql" 2>&1 | grep -c "Statement failed")
check "the same churn through the engine, error-free" "$errs" "0"
SA=$(blobs_of "$A" 'RDB$SECURITY_CLASSES'); SE=$(blobs_of "$B" 'RDB$SECURITY_CLASSES')
# the baseline security catalog carries ~550 ACLs from CREATE DATABASE;
# the churn used to add 40 more on fc - flat means within the engine's
# own settling distance of the baseline
if [ -n "$SA" ] && [ -n "$SE" ] && [ "$SA" -le $((SE + 4)) ]; then
    ran=$((ran + 1)); echo "OK   fc ACL blob slots at or near the engine's ($SA vs $SE)"
else
    ran=$((ran + 1)); echo "DIFF fc ACL blob slots ($SA vs engine $SE)"; fail=1
fi
DA=$(blobs_of "$A" 'RDB$RELATIONS'); DE=$(blobs_of "$B" 'RDB$RELATIONS')
if [ -n "$DA" ] && [ -n "$DE" ] && [ "$DA" -le $((DE + 4)) ]; then
    ran=$((ran + 1)); echo "OK   fc description/runtime blob slots at or near the engine's ($DA vs $DE)"
else
    ran=$((ran + 1)); echo "DIFF fc description/runtime blob slots ($DA vs engine $DE)"; fail=1
fi
check "the last comment reads back, fc == engine" \
    "$(q "127.0.0.1/$PORT:$A" "SELECT CAST(R.RDB\$DESCRIPTION AS VARCHAR(40)) FROM RDB\$RELATIONS R WHERE R.RDB\$RELATION_NAME = 'GT';")" \
    "$(q "127.0.0.1/$REAL:$B" "SELECT CAST(R.RDB\$DESCRIPTION AS VARCHAR(40)) FROM RDB\$RELATIONS R WHERE R.RDB\$RELATION_NAME = 'GT';")"

# --- structure: silent validation and a gbak round trip ---
V=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "gfix -v -full is silent on the GC'd file" "$V" ""
rm -f "$D/fc-blobgc.fbk" "$D/fc-blobgc-r.fdb"
GB=$({ "$GBAK" -b -user "$U" -pas "$P" "$A" "$D/fc-blobgc.fbk" \
    && "$GBAK" -c -user "$U" -pas "$P" "$D/fc-blobgc.fbk" "$D/fc-blobgc-r.fdb"; } 2>&1)
[ -f "$D/fc-blobgc-r.fdb" ] || echo "note: gbak said: $(echo "$GB" | tail -3 | tr '\n' ' ')"
check "gbak round-trips; the restored check still enforces" \
    "$(q "$D/fc-blobgc-r.fdb" "INSERT INTO T1 VALUES (7, 100);" | head -c 60)" \
    "$(q "127.0.0.1/$PORT:$A" "INSERT INTO T1 VALUES (7, 100);" | head -c 60)"

echo
if [ "$fail" = 0 ]; then echo "PASS all $ran checks"; else echo "FAIL"; exit 1; fi
