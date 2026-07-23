#!/bin/bash
# FOREIGN KEY in CREATE TABLE. fire-crab writes the referencing index
# (irt_foreign, naming the partner PK index), the RDB$RELATION_CONSTRAINTS
# 'FOREIGN KEY' row and the RDB$REF_CONSTRAINTS link. The linchpin the two
# earlier attempts missed is the ODS-14 column RDB$INDICES.
# RDB$FOREIGN_KEY_SCHEMA_NAME: MET_lookup_partner's self-join matches
# IND.RDB$SCHEMA_NAME EQ IDX.RDB$FOREIGN_KEY_SCHEMA_NAME (met.epp:2408),
# so omitting it (NULL) makes the partner lookup fail with "Partner index
# does not exist or is inactive" at gbak restore AND starves the live
# RI-enforcement cache. Setting it to 'PUBLIC' fixes BOTH.
#
# THE differential is the engine, three ways:
#   1. the engine reads fire-crab's FK catalog and it matches, column for
#      column, an engine-built reference of the same schema;
#   2. gbak backs up and RESTORES fire-crab's file (the historic blocker) -
#      the restored database enforces the FK (orphan child rejected, valid
#      child accepted) and gfix finds it clean;
#   3. the engine enforces the FK on fire-crab's RAW file too (an orphan
#      insert is rejected).
#
#   qa/serve-real-fk.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4113}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-fk-work.fdb"; REF="$D/fc-fk-ref.fdb"
FBK="$D/fc-fk-work.fbk"; RST="$D/fc-fk-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# fire-crab's file starts as an engine-created empty database; the engine
# reference gets the tables via ordinary DDL for the catalog comparison.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
DDL_P="CREATE TABLE P (PID INTEGER NOT NULL PRIMARY KEY, PNAME VARCHAR(20))"
DDL_C="CREATE TABLE C (CID INTEGER NOT NULL PRIMARY KEY, PID INTEGER, CONSTRAINT FK_C_P FOREIGN KEY (PID) REFERENCES P(PID))"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_P;
$DDL_C;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fk.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
# run one statement through fire-crab, retrying transient cold-start races
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

# --- fire-crab writes the schema + a row ---
check "create P"            "$(node_run "$DDL_P")" "OK"
check "create C with FK"    "$(node_run "$DDL_C")" "OK"
check "insert parent"       "$(node_run "INSERT INTO P VALUES (1, 'a')")" "OK"
check "insert valid child"  "$(node_run "INSERT INTO C VALUES (10, 1)")" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the FK catalog the engine reads from fc == engine reference ---
catq() { # <file>
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

# --- 2. gbak backup + RESTORE (the historic blocker) ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-fk-backup.log 2>&1; then
    echo "OK   gbak backs up fc's FK database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-fk-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-fk-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qi "partner" /tmp/fc-fk-restore.log; then
    echo "OK   gbak RESTORES fc's FK (no partner-index error)"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-fk-restore.log | head; fail=1
fi

# --- restored db enforces the FK and is structurally clean ---
orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO C VALUES (99, 12345);
SQL
)
case "$orphan" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   restored db REJECTS an orphan child" ;;
    *) echo "DIFF restored FK enforcement (orphan not rejected)"; echo "     $orphan"; fail=1 ;;
esac
valid=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO C VALUES (11, 1);
SQL
)
check "restored db ACCEPTS a valid child" "$(printf '%s' "$valid" | strip)" ""
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""

# --- 3. the engine enforces the FK on fc's RAW file ---
raw_orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO C VALUES (98, 55555);
SQL
)
case "$raw_orphan" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   engine enforces FK on fc's RAW file (orphan rejected)" ;;
    *) echo "DIFF raw-file FK enforcement"; echo "     $raw_orphan"; fail=1 ;;
esac

exit $fail
