#!/bin/bash
# GRANT / REVOKE a ROLE - role membership, the no-ON grant.
#
# GRANT <role> TO <grantees> [WITH ADMIN OPTION] makes each grantee a
# member of the role: a RDB$USER_PRIVILEGES row with privilege 'M', object
# type 13 (obj_sql_role), the role in RDB$RELATION_NAME, no schema, and
# RDB$GRANT_OPTION = 2 for WITH ADMIN OPTION (not 1). Granting a role then
# recompiles the ROLE's own ACL: the owner (alter, control, drop) plus each
# admin-option member, alphabetically, with the 'drop' privilege the engine
# gives an admin member (a role membership maps to the "O" = drop letter).
# A member without the admin option is NOT in the ACL. Unlike a table
# grant, the role must exist - GRANT of a missing role is refused.
#
# The differential is the engine, five ways:
#   1. the same GRANT / REVOKE sequence on two copies of one database; the
#      RDB$USER_PRIVILEGES member rows are compared (privilege, object type,
#      the 2 for admin option);
#   2. the role's ACL blob is compared BYTE FOR BYTE - only the admin
#      members appear, alphabetically, each with drop;
#   3. the engine CONTINUES from fire-crab's file - one more GRANT lands
#      identically;
#   4. a grant of a missing role is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-rolegrant.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4162}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-rg-src.fdb"; WORK="$D/fc-rg-work.fdb"; REF="$D/fc-rg-ref.fdb"
FBK="$D/fc-rg-work.fbk"; RST="$D/fc-rg-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

G1="GRANT MANAGER TO BOB"
G2="GRANT MANAGER TO ALICE WITH ADMIN OPTION"
G3="GRANT MANAGER TO ZED WITH ADMIN OPTION"
G4="GRANT CLERK TO BOB"
R1="REVOKE MANAGER FROM BOB"
RJ="GRANT NOSUCH TO BOB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE ROLE MANAGER;
CREATE ROLE CLERK;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$G1; $G2; $G3; $G4; $R1;
COMMIT;
EOF
eng_rj=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$RJ;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-rg.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"' EXIT
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

for g in "$G1" "$G2" "$G3" "$G4" "$R1"; do
    check "$g" "$(node_run "$g")" "OK"
done
r=$(node_run "$RJ")
case "$r" in ERR*) echo "OK   a grant of a missing role is refused" ;;
    *) echo "DIFF missing-role grant accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rj" in *[Ee]rror*|*"does not exist"*|*"not found"*) echo "OK   the engine refuses it too" ;;
    *) echo "DIFF engine did not refuse the missing-role grant"; echo "     $eng_rj"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the membership rows --------------------------------------------
memq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'M|'||TRIM(RDB$RELATION_NAME)||'|'||TRIM(RDB$USER)||'|'||TRIM(RDB$PRIVILEGE)
       ||'|'||RDB$GRANT_OPTION||'|'||RDB$USER_TYPE||'|'||RDB$OBJECT_TYPE
  FROM RDB$USER_PRIVILEGES WHERE RDB$OBJECT_TYPE=13 ORDER BY RDB$RELATION_NAME, RDB$USER;
SQL
}
work_mem=$(memq "$WORK")
check "the membership rows match the engine reference" "$work_mem" "$(memq "$REF")"
case "$work_mem" in
    *"M|CLERK|BOB|M|0|8|13"*"M|MANAGER|ALICE|M|2|8|13"*"M|MANAGER|ZED|M|2|8|13"*)
        echo "OK   the rows carry membership (M, object type 13, admin option = 2)" ;;
    *) echo "DIFF the membership comparison was vacuous"; echo "     $work_mem"; fail=1 ;;
esac
case "$work_mem" in
    *"M|MANAGER|BOB|"*) echo "DIFF BOB still a MANAGER member (revoked)"; fail=1 ;;
    *) echo "OK   BOB's MANAGER membership is gone (revoked); CLERK survives" ;;
esac

# --- 2. the role ACL, byte for byte ------------------------------------
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$ROLES R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$ROLE_NAME = 'MANAGER';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-rg-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-rg-acl.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-rg-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the role's ACL matches the engine's byte for byte" "$work_acl" "$(aclq "$REF")"
# teeth: only the admin members (ALICE, ZED) appear, each with drop (code 3)
case "$work_acl" in
    "2 1 3 6 83 89 83 68 66 65 0 2 6 1 3 0 1 3 5 65 76 73 67 69 0 2 3 0 1 3 3 90 69 68 0 2 3 0 0")
        echo "OK   the ACL is owner(alter,control,drop) + ALICE(drop) + ZED(drop), BOB absent" ;;
    *) echo "DIFF unexpected role ACL encoding"; echo "     got:  $work_acl"; fail=1 ;;
esac

# --- 3. the engine CONTINUES from fire-crab's file ---------------------
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<'SQL'
GRANT MANAGER TO EVE WITH ADMIN OPTION;
COMMIT;
SQL
    aclq "$1"
}
check "the engine's next role grant lands identically on fire-crab's file" "$(contq "$WORK")" "$(contq "$REF")"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-rg-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-rg-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-rg-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-rg-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-rg-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
