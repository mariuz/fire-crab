#!/bin/bash
# CREATE / DROP ROLE - the leanest of the security objects.
#
# CREATE ROLE writes a RDB$ROLES row and a SQL$<n> security class, and
# nothing else: no number (a role has none), no RDB$USER_PRIVILEGES rows
# (creating a role does not grant a privilege ON it). The owner's ACL is
# alter/control/drop only - no usage - so it is a distinct ACL from a
# sequence's or an exception's. The one on-disk subtlety: RDB$ROLES's
# RDB$SYSTEM_PRIVILEGES is a CHAR(8) OCTETS, written as eight ZERO bytes
# (an empty system-privilege bitmask), not NULL and not the spaces a text
# CHAR would pad with. DROP ROLE takes the row and its security class.
#
# The SQL$<n> class name comes from the RDB$SECURITY_CLASS generator, which
# the engine draws from without checking the name is free (the column has a
# unique index), so a writer that invents a name off-counter hands the
# engine a duplicate on its next CREATE.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same CREATE / DROP ROLE sequence
#      on two copies of one database; the RDB$ROLES rows are compared, and
#      RDB$SYSTEM_PRIVILEGES is checked to be eight zero bytes on both;
#   2. the ACL blob is compared byte for byte;
#   3. the engine CONTINUES from fire-crab's file - one more CREATE ROLE
#      must land the same class name;
#   4. a duplicate name and a missing DROP are refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-role.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4159}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-role-src.fdb"; WORK="$D/fc-role-work.fdb"; REF="$D/fc-role-ref.fdb"
FBK="$D/fc-role-work.fbk"; RST="$D/fc-role-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

R1="CREATE ROLE MANAGER"
R2="CREATE ROLE CLERK"
R3="CREATE ROLE AUDITOR"
DROP2="DROP ROLE CLERK"
R_DUP="CREATE ROLE MANAGER"
R_MISS="DROP ROLE NOPE"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$R1; $R2; $R3;
COMMIT;
$DROP2;
COMMIT;
EOF
eng_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_DUP;
EOF
)
eng_miss=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_MISS;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-role.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"' EXIT
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

check "CREATE ROLE MANAGER"            "$(node_run "$R1")" "OK"
check "CREATE ROLE CLERK"              "$(node_run "$R2")" "OK"
check "CREATE ROLE AUDITOR"            "$(node_run "$R3")" "OK"
check "DROP ROLE CLERK"                "$(node_run "$DROP2")" "OK"
r=$(node_run "$R_DUP")
case "$r" in ERR*) echo "OK   a duplicate role name is refused" ;;
    *) echo "DIFF duplicate name accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_MISS")
case "$r" in ERR*) echo "OK   dropping a missing role is refused" ;;
    *) echo "DIFF missing drop accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_dup" in *already*exists*) echo "OK   the engine refuses the duplicate too" ;;
    *) echo "DIFF engine did not refuse duplicate"; echo "     $eng_dup"; fail=1 ;; esac
case "$eng_miss" in *not*found*) echo "OK   the engine refuses the missing drop too" ;;
    *) echo "DIFF engine did not refuse missing drop"; echo "     $eng_miss"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$ROLES rows and no privileges ---------------------------
roleq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'ROLE|'||TRIM(RDB$ROLE_NAME)||'|'||TRIM(RDB$OWNER_NAME)||'|'||COALESCE(TRIM(RDB$SECURITY_CLASS),'-')
       ||'|'||COALESCE(RDB$SYSTEM_FLAG,0)
       ||'|'||CASE WHEN RDB$SYSTEM_PRIVILEGES = x'0000000000000000' THEN 'zero8'
                   WHEN RDB$SYSTEM_PRIVILEGES IS NULL THEN 'null' ELSE 'other' END
  FROM RDB$ROLES WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 ORDER BY RDB$ROLE_NAME;
SELECT 'ROLEPRIVS|'||COUNT(*) FROM RDB$USER_PRIVILEGES
  WHERE RDB$RELATION_NAME IN ('MANAGER','AUDITOR','CLERK');
SQL
}
work_role=$(roleq "$WORK")
check "the RDB\$ROLES rows match the engine reference" "$work_role" "$(roleq "$REF")"
case "$work_role" in
    *"ROLE|AUDITOR|SYSDBA|SQL\$"*"|0|zero8"*"ROLE|MANAGER|SYSDBA|SQL\$"*"|0|zero8"*"ROLEPRIVS|0"*)
        echo "OK   the roles carry the owner, a class, an all-zero RDB\$SYSTEM_PRIVILEGES and no privileges" ;;
    *) echo "DIFF the role comparison was vacuous or wrong"; echo "     $work_role"; fail=1 ;;
esac
check "  ... CLERK is gone (dropped)" \
      "$(printf '%s\n' "$work_role" | grep -c '^ROLE|CLERK|')" "0"

# --- 2. the ACL blob, byte for byte ------------------------------------
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$ROLES R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$ROLE_NAME = 'MANAGER';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-role-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-role-acl.bin;\n' "$bid" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-role-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the owner's ACL blob matches the engine's" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 83 89 83 68 66 65 0 2 6 1 3 0 0")
        echo "OK   the ACL is the role-owner encoding (alter/control/drop, no usage)" ;;
    *) echo "DIFF unexpected ACL encoding"; echo "     got:  $work_acl"; fail=1 ;;
esac

# --- 3. the engine CONTINUES from fire-crab's file ---------------------
# one more CREATE ROLE, by the engine, on each copy: the same class name
# only if fire-crab advanced the RDB$SECURITY_CLASS counter.
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<'SQL'
CREATE ROLE R_NEXT;
COMMIT;
SQL
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(TRIM(RDB$SECURITY_CLASS),'-') FROM RDB$ROLES WHERE RDB$ROLE_NAME = 'R_NEXT';
SQL
}
cont_w=$(contq "$WORK"); cont_r=$(contq "$REF")
check "the engine's next role lands on the same class name" "$cont_w" "$cont_r"
case "$cont_w" in
    "SQL\$"*) echo "OK   the continuation really allocated a class" ;;
    *) echo "DIFF the continuation was vacuous"; echo "     $cont_w"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-role-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-role-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-role-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-role-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-role-restore.log | head; fail=1
fi
rst_roles=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$ROLE_NAME) FROM RDB$ROLES WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 ORDER BY RDB$ROLE_NAME;
SQL
)
check "the roles survive the round trip" "$rst_roles" "AUDITOR
MANAGER
R_NEXT"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
