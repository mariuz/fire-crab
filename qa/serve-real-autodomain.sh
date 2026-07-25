#!/bin/bash
# An auto-domain (RDB$<n>) is owned by the table's owner.
#
# Every column of a built-in type gets a per-table auto-domain RDB$FIELDS row.
# The engine stamps it with RDB$OWNER_NAME (the table's owner) but no security
# class (unlike a user domain). fire-crab wrote the row without an owner - a
# latent gap no gate compared, since the domain and format gates looked at the
# type and the format, not the auto-domain's owner.
#
# The differential is the engine:
#   1. fire-crab and the engine each create a table (and ALTER TABLE ADD a
#      column) on two copies; every auto-domain RDB$FIELDS row - name, type,
#      owner and security class - is compared;
#   2. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-autodomain.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4219}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-adom-work.fdb"; REF="$D/fc-adom-ref.fdb"
FBK="$D/fc-adom-work.fbk"; RST="$D/fc-adom-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL="CREATE TABLE T (A INTEGER, B VARCHAR(5), C CHAR(3))"
ALT="ALTER TABLE T ADD E BIGINT"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL; $ALT;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-adom.log 2>&1 &
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

check "fire-crab creates the table" "$(node_run "$DDL")" "OK"
check "fire-crab ALTER TABLE ADD a column" "$(node_run "$ALT")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

adomq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|t='||RDB$FIELD_TYPE||'|len='||RDB$FIELD_LENGTH
       ||'|own='||COALESCE(TRIM(RDB$OWNER_NAME),'NULL')
       ||'|sc='||COALESCE(TRIM(RDB$SECURITY_CLASS),'NULL')
       ||'|sys='||RDB$SYSTEM_FLAG
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME STARTING WITH 'RDB$' AND RDB$SYSTEM_FLAG=0
  ORDER BY RDB$FIELD_NAME;
SQL
}
work_ad=$(adomq "$WORK")
check "every auto-domain RDB\$FIELDS row matches the engine" "$work_ad" "$(adomq "$REF")"
case "$work_ad" in
    *"RDB\$1|"*"|own=SYSDBA|sc=NULL"*"RDB\$4|"*"|own=SYSDBA|sc=NULL"*)
        echo "OK   the auto-domains are owned by SYSDBA with no security class (incl. the ALTER-added one)" ;;
    *) echo "DIFF the auto-domain comparison was vacuous or wrong"; echo "     $work_ad"; fail=1 ;;
esac

# gbak and gfix
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-adom-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-adom-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-adom-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-adom-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-adom-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
