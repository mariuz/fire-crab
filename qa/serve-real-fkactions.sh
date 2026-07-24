#!/bin/bash
# FOREIGN KEY referential actions beyond simple cascade: ON DELETE / ON
# UPDATE SET NULL, and MULTI-COLUMN cascade.
#
# The trigger BLR generalises: the WHERE boolean is an AND-chain of
# (child.fk_i = OLD.pk_i) across the key columns; the UPDATE guard is an
# OR-chain of (OLD.pk_i <> NEW.pk_i); a MODIFY assigns each child.fk_i
# either NEW.pk_i (cascade) or NULL (set-null). fire-crab emits all of it
# byte for byte (blr_and 58, blr_or 57, blr_null 45).
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create the same tables (a SET NULL FK and a
#      two-column CASCADE FK) on two copies; the rules and trigger rows
#      match, and the trigger BLR matches BYTE FOR BYTE;
#   2. the engine EXECUTES fire-crab's triggers: deleting a parent NULLs the
#      SET NULL child's FK column, and deletes the two-column child;
#   3. an ON UPDATE SET NULL parent-key change NULLs the child;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-fkactions.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4167}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fka-work.fdb"; REF="$D/fc-fka-ref.fdb"
FBK="$D/fc-fka-work.fbk"; RST="$D/fc-fka-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

MN="CREATE TABLE MN (ID INTEGER NOT NULL PRIMARY KEY)"
DN="CREATE TABLE DN (K INTEGER, MID INTEGER, CONSTRAINT FKN FOREIGN KEY (MID) REFERENCES MN (ID) ON DELETE SET NULL ON UPDATE SET NULL)"
MC="CREATE TABLE MC (A INTEGER NOT NULL, B INTEGER NOT NULL, CONSTRAINT PKC PRIMARY KEY (A, B))"
DC="CREATE TABLE DC (X INTEGER, Y INTEGER, CONSTRAINT FKC FOREIGN KEY (X, Y) REFERENCES MC (A, B) ON DELETE CASCADE)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$MN; $DN; $MC; $DC;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fka.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

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

for s in "$MN" "$DN" "$MC" "$DC"; do
    check "fire-crab: ${s:0:26}..." "$(node_run "$s")" "OK"
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. rules + trigger rows + BLR -------------------------------------
metq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'R|'||TRIM(RDB$CONSTRAINT_NAME)||'|'||TRIM(RDB$UPDATE_RULE)||'|'||TRIM(RDB$DELETE_RULE)
  FROM RDB$REF_CONSTRAINTS ORDER BY RDB$CONSTRAINT_NAME;
SELECT 'T|'||TRIM(RDB$TRIGGER_NAME)||'|'||TRIM(RDB$RELATION_NAME)||'|typ='||RDB$TRIGGER_TYPE
  FROM RDB$TRIGGERS WHERE RDB$SYSTEM_FLAG=4 ORDER BY RDB$TRIGGER_NAME;
SQL
}
work_met=$(metq "$WORK")
check "the rules and trigger rows match the engine" "$work_met" "$(metq "$REF")"
case "$work_met" in
    *"R|FKC|RESTRICT|CASCADE"*"R|FKN|SET NULL|SET NULL"*"T|CHECK_1|MN|typ=4"*"T|CHECK_2|MN|typ=6"*"T|CHECK_3|MC|typ=6"*)
        echo "OK   FKN has both SET NULL rules + 2 triggers on MN; FKC one CASCADE trigger on MC" ;;
    *) echo "DIFF the metadata comparison was vacuous or wrong"; echo "     $work_met"; fail=1 ;;
esac
blrq() { # <file> <trigger>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB\$TRIGGER_BLR FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME = '$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-fka-blr.bin
    printf 'BLOBDUMP %s /tmp/fc-fka-blr.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-fka-blr.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "CHECK_1 (update SET NULL) BLR byte for byte"     "$(blrq "$WORK" CHECK_1)" "$(blrq "$REF" CHECK_1)"
check "CHECK_2 (delete SET NULL) BLR byte for byte"     "$(blrq "$WORK" CHECK_2)" "$(blrq "$REF" CHECK_2)"
check "CHECK_3 (two-column cascade) BLR byte for byte"  "$(blrq "$WORK" CHECK_3)" "$(blrq "$REF" CHECK_3)"

# --- 2/3. the engine EXECUTES fire-crab's triggers ---------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO MN VALUES (1);
INSERT INTO MN VALUES (2);
INSERT INTO DN VALUES (10, 1);
INSERT INTO DN VALUES (11, 2);
INSERT INTO MC VALUES (5, 6);
INSERT INTO MC VALUES (5, 7);
INSERT INTO DC VALUES (5, 6);
INSERT INTO DC VALUES (5, 7);
COMMIT;
UPDATE MN SET ID = 99 WHERE ID = 1;   /* SET NULL on update: DN row for 1 -> NULL */
DELETE FROM MN WHERE ID = 2;          /* SET NULL on delete: DN row for 2 -> NULL */
DELETE FROM MC WHERE A = 5 AND B = 6; /* multi-col cascade: DC (5,6) gone, (5,7) stays */
COMMIT;
SQL
res=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'DN_NULL|'||COUNT(*) FROM DN WHERE MID IS NULL;
SELECT 'DN_LEFT|'||COUNT(*) FROM DN WHERE MID IS NOT NULL;
SELECT 'DC56|'||COUNT(*) FROM DC WHERE X = 5 AND Y = 6;
SELECT 'DC57|'||COUNT(*) FROM DC WHERE X = 5 AND Y = 7;
SQL
)
check "the engine ran SET NULL (both DN rows NULLed) and the 2-col cascade (only (5,6) deleted)" \
      "$res" "DN_NULL|2
DN_LEFT|0
DC56|0
DC57|1"

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fka-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-fka-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fka-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-fka-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-fka-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
