#!/bin/bash
# Column DEFAULT with a context value - CURRENT_DATE / TIMESTAMP / TIME / USER.
#
# These defaults are single-opcode BLR (blr_version5, <op>, blr_eoc):
# CURRENT_DATE 160, CURRENT_TIMESTAMP 161, CURRENT_TIME 162, CURRENT_USER 44
# (blr_user_name) - not the variable/message machinery an expression default
# needs. The source text is the canonical uppercase keyword, and the BLR is
# folded into the relation's RDB$RUNTIME like any default, so the engine
# evaluates it per row.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create the same table on two copies; every
#      RDB$DEFAULT_SOURCE is compared;
#   2. each RDB$DEFAULT_VALUE BLR is compared BYTE FOR BYTE, and the rebuilt
#      RDB$RUNTIME byte for byte;
#   3. the engine EVALUATES the defaults: an inserted row's CURRENT_DATE column
#      equals CURRENT_DATE and its CURRENT_USER column equals the user;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-defaultcurrent.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4228}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-cur-work.fdb"; REF="$D/fc-cur-ref.fdb"
FBK="$D/fc-cur-work.fbk"; RST="$D/fc-cur-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL="CREATE TABLE T (A DATE DEFAULT CURRENT_DATE, B TIMESTAMP DEFAULT CURRENT_TIMESTAMP, C VARCHAR(40) DEFAULT CURRENT_USER, D TIME DEFAULT CURRENT_TIME, E INTEGER)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cur.log 2>&1 &
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
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }

check "fire-crab creates the table with context defaults" "$(node_run "$DDL")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

srcq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(30)),'-') FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_src=$(srcq "$WORK")
check "every RDB\$DEFAULT_SOURCE matches the engine" "$work_src" "$(srcq "$REF")"
case "$work_src" in *"A|DEFAULT CURRENT_DATE"*"C|DEFAULT CURRENT_USER"*"D|DEFAULT CURRENT_TIME"*)
    echo "OK   the sources carry the canonical CURRENT_* keywords" ;;
    *) echo "DIFF vacuous"; echo "     $work_src"; fail=1 ;; esac

blob_bytes() { bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT RDB\$DEFAULT_VALUE FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME='T' AND RDB\$FIELD_NAME='$2';
SQL
); [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-cur-blob.bin; printf 'BLOBDUMP %s /tmp/fc-cur-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-cur-blob.bin | tr '\n' ' ' | tr -s ' ' | strip; }
for c in A B C D; do
    check "$c: RDB\$DEFAULT_VALUE BLR byte for byte" "$(blob_bytes "$WORK" "$c")" "$(blob_bytes "$REF" "$c")"
done
case "$(blob_bytes "$WORK" A)" in "5 160 76") echo "OK   CURRENT_DATE is blr_version5, 160, blr_eoc" ;;
    *) echo "DIFF CURRENT_DATE BLR"; fail=1 ;; esac

rtq() { b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-cur-rt.bin; printf 'BLOBDUMP %s /tmp/fc-cur-rt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-cur-rt.bin | tr '\n' ' ' | tr -s ' ' | strip; }
check "the RDB\$RUNTIME matches the engine byte for byte" "$(rtq "$WORK")" "$(rtq "$REF")"

# the engine evaluates the defaults
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (E) VALUES (1); COMMIT;
SQL
evaluated=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CASE WHEN A=CURRENT_DATE THEN 'date_ok' ELSE 'BAD' END||'|'||TRIM(C) FROM T WHERE E=1;
SQL
)
check "the engine evaluates the context defaults on insert (today's date, the user)" "$evaluated" "date_ok|SYSDBA"

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cur-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-cur-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cur-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cur-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cur-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
