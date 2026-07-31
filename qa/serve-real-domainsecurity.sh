#!/bin/bash
# CREATE/DROP DOMAIN writes (and removes) the security catalog.
#
# A user domain is an owned object: CREATE DOMAIN gives its RDB$FIELDS row an
# RDB$OWNER_NAME and an RDB$SECURITY_CLASS (SQL$<n>), writes that class with the
# owner's alter/control/drop/usage ACL (bytes 6 1 3 12, like a sequence's), and
# writes the owner a USAGE ('G', object type 9) privilege row. DROP DOMAIN
# removes the class row and the privilege rows with the domain. fire-crab wrote
# none of this before - a latent gap the domain type/default gates never
# compared.
#
# The differential is the engine:
#   1. fire-crab and the engine each CREATE the same domain on two copies; the
#      RDB$FIELDS owner and security class, the owner's privilege row, and the
#      security-class ACL blob are compared (the class number is compared too:
#      both counters start from the same fresh database);
#   2. DROP DOMAIN removes the class row and the privilege rows on both;
#   3. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-domainsecurity.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4215}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dsec-work.fdb"; REF="$D/fc-dsec-ref.fdb"
FBK="$D/fc-dsec-work.fbk"; RST="$D/fc-dsec-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

CRE="CREATE DOMAIN DOM1 AS INTEGER"
DRP="DROP DOMAIN DOM1"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$CRE;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dsec.log 2>&1 &
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

check "fire-crab CREATE DOMAIN" "$(node_run "$CRE")" "OK"

# --- 1. owner, class, privilege, ACL ----------------------------------
metaq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'sc='||TRIM(RDB$SECURITY_CLASS)||'|owner='||TRIM(RDB$OWNER_NAME) FROM RDB$FIELDS WHERE RDB$FIELD_NAME='DOM1';
SELECT 'priv:'||TRIM(RDB$USER)||'|'||TRIM(RDB$PRIVILEGE)||'|ot='||RDB$OBJECT_TYPE||'|go='||RDB$GRANT_OPTION
  FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME='DOM1';
SQL
}
work_meta=$(metaq "$WORK")
check "owner, security class and owner privilege match the engine" "$work_meta" "$(metaq "$REF")"
case "$work_meta" in
    *"owner=SYSDBA"*"priv:SYSDBA|G|ot=9|go=1"*)
        echo "OK   the domain is owned by SYSDBA with a USAGE (G, object type 9) privilege" ;;
    *) echo "DIFF the meta comparison was vacuous"; echo "     $work_meta"; fail=1 ;;
esac
aclq() { # <file>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT c.RDB$ACL FROM RDB$SECURITY_CLASSES c JOIN RDB$FIELDS f
  ON f.RDB$SECURITY_CLASS = c.RDB$SECURITY_CLASS WHERE f.RDB$FIELD_NAME='DOM1';
SQL
)
    [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-dsec-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-dsec-acl.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-dsec-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the domain's security-class ACL matches byte for byte" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 "*" 0 2 6 1 3 12 0 0") echo "OK   the owner ACE is alter/control/drop/usage (6 1 3 12)" ;;
    *) echo "DIFF the owner ACE is not as expected"; echo "     $work_acl"; fail=1 ;;
esac

# --- 2. DROP removes the class and the privileges ---------------------
check "fire-crab DROP DOMAIN" "$(node_run "$DRP")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$DRP;
COMMIT;
EOF
leftq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'priv='||COUNT(*) FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME='DOM1';
SQL
}
check "DROP removes the domain's privilege rows on fire-crab as on the engine" "$(leftq "$WORK")" "$(leftq "$REF")"
case "$(leftq "$WORK")" in *"priv=0"*) echo "OK   no privilege rows are left orphaned after the drop" ;;
    *) echo "DIFF privilege rows survived the drop"; fail=1 ;; esac

# --- 3. gbak and gfix (re-create so there is something to back up) ----
node_run_reopen() { # a fresh server, the drop left the db usable
    "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dsec2.log 2>&1 &
    srv=$!
    i=0; while [ $i -lt 20 ]; do
        command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
        i=$((i + 1)); sleep 0.1
    done
    kill -0 $srv 2>/dev/null || {
        echo "FAIL fcwire did not restart - port $PORT already in use?"
        exit 1
    }
    node_run "CREATE DOMAIN DOM2 AS VARCHAR(5)"
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
}
check "fire-crab re-creates a domain after the drop" "$(node_run_reopen)" "OK"
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dsec-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dsec-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dsec-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dsec-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dsec-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
