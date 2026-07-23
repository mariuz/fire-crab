#!/bin/bash
# ALTER TABLE <t> ADD [CONSTRAINT <name>] FOREIGN KEY (...) REFERENCES ...
# - add a foreign key to an EXISTING, already-populated table. fire-crab
# builds the referencing index and backfills it over the committed child
# rows, then writes the same constraint catalog rows create_table writes
# (including the ODS-14 RDB$FOREIGN_KEY_SCHEMA_NAME that makes the partner
# lookup succeed - see serve-real-fk.sh).
#
# THE differential is the engine: fire-crab and the engine each build the
# schema the SAME way (create the tables, insert rows, THEN ALTER ADD the
# FK), and the FK catalog fire-crab writes must match the engine's column
# for column; gbak backs up and RESTORES fire-crab's file (no partner
# error); the restored db enforces the FK (orphan rejected, valid child
# accepted) and gfix finds it clean; and the engine enforces the FK on
# fire-crab's RAW file too.
#
#   qa/serve-real-fkalter.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4141}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fkalter-work.fdb"; REF="$D/fc-fkalter-ref.fdb"
FBK="$D/fc-fkalter.fbk"; RST="$D/fc-fkalter-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# the identical build script - create tables, insert, THEN add the FK
DDL_P="CREATE TABLE P (PID INTEGER NOT NULL PRIMARY KEY, PNAME VARCHAR(10))"
DDL_C="CREATE TABLE C (CID INTEGER NOT NULL PRIMARY KEY, PID INTEGER)"
INS_P="INSERT INTO P VALUES (1, 'a')"
INS_C="INSERT INTO C VALUES (10, 1)"
ALT="ALTER TABLE C ADD CONSTRAINT FK_C_P FOREIGN KEY (PID) REFERENCES P (PID)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_P; $DDL_C; COMMIT;
$INS_P; $INS_C; COMMIT;
$ALT; COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fkalter.log 2>&1 &
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
        db.query(process.env.FC_Q,(e2)=>{console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_once "$1")
        case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;; *) printf '%s' "$r" | strip; return ;; esac
    done
    echo CONN_ERR
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }

# --- fire-crab builds the same schema, then ADDs the FK to a populated C ---
check "create P"       "$(node_run "$DDL_P")" "OK"
check "create C"       "$(node_run "$DDL_C")" "OK"
check "insert parent"  "$(node_run "$INS_P")" "OK"
check "insert child"   "$(node_run "$INS_C")" "OK"
check "ALTER ADD FK"   "$(node_run "$ALT")"   "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- the FK catalog fire-crab wrote == an engine reference built the same way ---
catq() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IDX|'||TRIM(RDB$INDEX_NAME)||'|'||COALESCE(TRIM(RDB$FOREIGN_KEY),'-')||'|'
       ||COALESCE(TRIM(RDB$FOREIGN_KEY_SCHEMA_NAME),'-')||'|'||COALESCE(RDB$UNIQUE_FLAG,-1)
  FROM RDB$INDICES WHERE RDB$RELATION_NAME IN ('C','P') ORDER BY RDB$RELATION_NAME, RDB$INDEX_ID;
SELECT 'RC|'||TRIM(RDB$CONSTRAINT_NAME)||'|'||TRIM(RDB$CONSTRAINT_TYPE)||'|'||COALESCE(TRIM(RDB$INDEX_NAME),'-')
  FROM RDB$RELATION_CONSTRAINTS WHERE RDB$RELATION_NAME IN ('C','P') ORDER BY RDB$CONSTRAINT_NAME;
SELECT 'REF|'||TRIM(RDB$CONSTRAINT_NAME)||'|'||TRIM(RDB$CONST_NAME_UQ)||'|'||TRIM(RDB$MATCH_OPTION)||'|'
       ||TRIM(RDB$UPDATE_RULE)||'|'||TRIM(RDB$DELETE_RULE)||'|'||TRIM(RDB$CONST_SCHEMA_NAME_UQ)
  FROM RDB$REF_CONSTRAINTS;
SELECT 'SEG|'||TRIM(RDB$INDEX_NAME)||'|'||TRIM(RDB$FIELD_NAME)||'|'||RDB$FIELD_POSITION
  FROM RDB$INDEX_SEGMENTS WHERE RDB$INDEX_NAME='FK_C_P';
SQL
}
check "FK catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"

# --- gbak backup + RESTORE ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fkalter-backup.log 2>&1; then
    echo "OK   gbak backs up the file"
else echo "DIFF gbak backup"; cat /tmp/fc-fkalter-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fkalter-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qi "partner" /tmp/fc-fkalter-restore.log; then
    echo "OK   gbak RESTORES the added FK (no partner-index error)"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-fkalter-restore.log | head; fail=1; fi

# --- restored db enforces + is clean ---
orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO C VALUES (99, 12345);
SQL
)
case "$orphan" in *"FOREIGN KEY"*|*"foreign key"*) echo "OK   restored db REJECTS an orphan child" ;;
    *) echo "DIFF restored FK enforcement"; echo "     $orphan"; fail=1 ;; esac
valid=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO C VALUES (11, 1);
SQL
)
check "restored db ACCEPTS a valid child" "$(printf '%s' "$valid" | strip)" ""
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""

# --- engine enforces on fc's RAW file ---
raw=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO C VALUES (98, 55555);
SQL
)
case "$raw" in *"FOREIGN KEY"*|*"foreign key"*) echo "OK   engine enforces the added FK on fc's RAW file" ;;
    *) echo "DIFF raw-file FK enforcement"; echo "     $raw"; fail=1 ;; esac

exit $fail
