#!/bin/bash
# FOREIGN KEY ... ON DELETE / ON UPDATE CASCADE - the referential action,
# the trigger BLR the engine synthesises for it, AND the RDB$RUNTIME entry
# that makes the trigger load.
#
# A CASCADE action stores its rule in RDB$REF_CONSTRAINTS and synthesises a
# system trigger on the REFERENCED (parent) table - CHECK_<n> from the
# RDB$TRIGGER_NAME generator, AFTER UPDATE (type 4) / AFTER DELETE (type 6),
# system flag 4. Its RDB$TRIGGER_BLR is a small program (single column):
#   delete: FOR (child WHERE child.fk = OLD.pk) ERASE
#   update: IF OLD.pk <> NEW.pk THEN
#             FOR (child WHERE child.fk = OLD.pk) MODIFY SET child.fk = NEW.pk
# The crucial detail: the engine loads a relation's triggers from the
# RSR_trigger_name entries in the relation's RDB$RUNTIME summary, NOT by
# scanning RDB$TRIGGERS - so the parent's RDB$RUNTIME must name the trigger
# or it never fires.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine create the same tables on two copies of one
#      database; the RDB$TRIGGERS rows and RDB$REF_CONSTRAINTS rules match;
#   2. the trigger BLR matches BYTE FOR BYTE, and the parent's RDB$RUNTIME
#      blob matches byte for byte (the trigger names are in it);
#   3. the engine EXECUTES fire-crab's triggers: UPDATE of the parent key
#      cascades to the child, DELETE cascade-deletes the child;
#   4. a single-action FK (ON DELETE CASCADE only) makes exactly one trigger;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-fkcascade.sh [port]
#
# Builds its own scratch databases (one written by fire-crab, one by the
# engine).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4166}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fkc-work.fdb"; REF="$D/fc-fkc-ref.fdb"
FBK="$D/fc-fkc-work.fbk"; RST="$D/fc-fkc-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

M="CREATE TABLE MASTER (ID INTEGER NOT NULL PRIMARY KEY)"
DET="CREATE TABLE DETAIL (ID INTEGER, MID INTEGER, CONSTRAINT FK_D FOREIGN KEY (MID) REFERENCES MASTER (ID) ON DELETE CASCADE ON UPDATE CASCADE)"
M2="CREATE TABLE M2 (ID INTEGER NOT NULL PRIMARY KEY)"
D2="CREATE TABLE D2 (MID INTEGER, CONSTRAINT FK_D2 FOREIGN KEY (MID) REFERENCES M2 (ID) ON DELETE CASCADE)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$M; $DET; $M2; $D2;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fkc.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

for s in "$M" "$DET" "$M2" "$D2"; do
    check "fire-crab: ${s:0:28}..." "$(node_run "$s")" "OK"
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. trigger rows + rules -------------------------------------------
trigq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'T|'||TRIM(RDB$TRIGGER_NAME)||'|'||TRIM(RDB$RELATION_NAME)||'|typ='||RDB$TRIGGER_TYPE
       ||'|seq='||RDB$TRIGGER_SEQUENCE||'|sys='||RDB$SYSTEM_FLAG||'|inact='||RDB$TRIGGER_INACTIVE
       ||'|flags='||RDB$FLAGS||'|valid='||RDB$VALID_BLR
  FROM RDB$TRIGGERS WHERE RDB$SYSTEM_FLAG=4 AND RDB$RELATION_NAME IN ('MASTER','M2')
  ORDER BY RDB$TRIGGER_NAME;
SELECT 'R|'||TRIM(RDB$CONSTRAINT_NAME)||'|'||TRIM(RDB$UPDATE_RULE)||'|'||TRIM(RDB$DELETE_RULE)
  FROM RDB$REF_CONSTRAINTS ORDER BY RDB$CONSTRAINT_NAME;
SQL
}
work_trig=$(trigq "$WORK")
check "the trigger rows and referential rules match the engine" "$work_trig" "$(trigq "$REF")"
case "$work_trig" in
    *"T|CHECK_1|MASTER|typ=4|"*"T|CHECK_2|MASTER|typ=6|"*"T|CHECK_3|M2|typ=6|"*"R|FK_D|CASCADE|CASCADE"*"R|FK_D2|RESTRICT|CASCADE"*)
        echo "OK   CHECK_1=AFTER UPDATE, CHECK_2=AFTER DELETE on MASTER; D2's single ON DELETE trigger; rules right" ;;
    *) echo "DIFF the trigger comparison was vacuous or wrong"; echo "     $work_trig"; fail=1 ;;
esac

# --- 2. trigger BLR + parent RDB$RUNTIME, byte for byte ----------------
blob_bytes() { # <file> <select>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
$2
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-fkc-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-fkc-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-fkc-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
B1="SELECT RDB\$TRIGGER_BLR FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME='CHECK_1';"
B2="SELECT RDB\$TRIGGER_BLR FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME='CHECK_2';"
RT="SELECT RDB\$RUNTIME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='MASTER';"
check "CHECK_1 (update-cascade) BLR matches byte for byte" "$(blob_bytes "$WORK" "$B1")" "$(blob_bytes "$REF" "$B1")"
check "CHECK_2 (delete-cascade) BLR matches byte for byte" "$(blob_bytes "$WORK" "$B2")" "$(blob_bytes "$REF" "$B2")"
check "MASTER's RDB\$RUNTIME (naming the triggers) matches byte for byte" "$(blob_bytes "$WORK" "$RT")" "$(blob_bytes "$REF" "$RT")"

# --- 3. the engine EXECUTES fire-crab's triggers -----------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO MASTER VALUES (1);
INSERT INTO MASTER VALUES (2);
INSERT INTO DETAIL VALUES (10, 1);
INSERT INTO DETAIL VALUES (11, 1);
INSERT INTO DETAIL VALUES (20, 2);
COMMIT;
UPDATE MASTER SET ID = 99 WHERE ID = 1;
COMMIT;
DELETE FROM MASTER WHERE ID = 2;
COMMIT;
SQL
casc=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'UPD|'||COUNT(*) FROM DETAIL WHERE MID = 99;
SELECT 'OLD|'||COUNT(*) FROM DETAIL WHERE MID = 1;
SELECT 'DEL|'||COUNT(*) FROM DETAIL WHERE MID = 2;
SQL
)
check "the engine RAN fire-crab's cascade: UPDATE moved 2 children, DELETE removed 1" \
      "$casc" "UPD|2
OLD|0
DEL|0"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fkc-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-fkc-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fkc-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-fkc-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-fkc-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
