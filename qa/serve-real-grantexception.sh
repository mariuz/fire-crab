#!/bin/bash
# GRANT / REVOKE USAGE ON EXCEPTION - the GRANT machinery, on an exception.
#
# USAGE on an exception is the same two effects a table grant has, one object
# type over: an RDB$USER_PRIVILEGES row per grantee (privilege 'X', object type
# 7, not 0) and a recompute of the SEQUENCE's security-class ACL. The ACL is
# the same acl.h version-2 format - owner ACE first (alter/control/drop/usage,
# bytes 6 1 3 12), then each grantee with USAGE (12) alphabetically, PUBLIC
# (the all-users wildcard) last.
#
# fire-crab creates exceptions, but to keep the two databases identical the engine
# writes the exception (and the users) into both databases; then fire-crab grants on one copy and the
# engine on the other, and the catalog is compared.
#
# The differential is the engine, five ways:
#   1. after GRANT to two users (one WITH GRANT OPTION) and PUBLIC, every
#      RDB$USER_PRIVILEGES 'X' row is compared (user, grant option, grantor);
#   2. the exception's security-class RDB$ACL is compared BYTE FOR BYTE;
#   3. after a REVOKE, the row is gone and the ACL is recomputed to match;
#   4. an unknown exception is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-grantexception.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4208}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-ge-work.fdb"; REF="$D/fc-ge-ref.fdb"
FBK="$D/fc-ge-work.fbk"; RST="$D/fc-ge-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

G_BOB="GRANT USAGE ON EXCEPTION E1 TO BOB"
G_ALICE="GRANT USAGE ON EXCEPTION E1 TO ALICE WITH GRANT OPTION"
G_PUB="GRANT USAGE ON EXCEPTION E1 TO PUBLIC"
R_BOB="REVOKE USAGE ON EXCEPTION E1 FROM BOB"
R_UNK="GRANT USAGE ON EXCEPTION NOSUCH TO BOB"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE EXCEPTION E1 'boom';
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$G_BOB; $G_ALICE; $G_PUB;
COMMIT;
EOF
eng_unk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_UNK;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ge.log 2>&1 &
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

privq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$USER)||'|'||TRIM(RDB$PRIVILEGE)||'|ot='||RDB$OBJECT_TYPE||'|go='||RDB$GRANT_OPTION||'|by='||TRIM(RDB$GRANTOR)
  FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME='E1' ORDER BY RDB$USER;
SQL
}
aclq() { # <file>
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT c.RDB$ACL FROM RDB$SECURITY_CLASSES c JOIN RDB$EXCEPTIONS p
  ON p.RDB$SECURITY_CLASS = c.RDB$SECURITY_CLASS WHERE p.RDB$EXCEPTION_NAME='E1';
SQL
)
    [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-ge-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-ge-acl.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-ge-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}

check "fire-crab: GRANT USAGE TO BOB"                 "$(node_run "$G_BOB")"   "OK"
check "fire-crab: GRANT USAGE TO ALICE WITH GRANT OPTION" "$(node_run "$G_ALICE")" "OK"
check "fire-crab: GRANT USAGE TO PUBLIC"              "$(node_run "$G_PUB")"   "OK"
r=$(node_run "$R_UNK")
case "$r" in ERR*) echo "OK   an unknown exception is refused" ;;
    *) echo "DIFF unknown exception accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_unk" in *[Ff]ailed*|*[Ee]rror*|*"not exist"*|*"not defined"*) echo "OK   the engine refuses the unknown exception too" ;;
    *) echo "DIFF engine did not refuse unknown exception"; echo "     $eng_unk"; fail=1 ;; esac

work_priv=$(privq "$WORK")
check "the RDB\$USER_PRIVILEGES 'G' rows match the engine" "$work_priv" "$(privq "$REF")"
case "$work_priv" in
    *"ALICE|G|ot=7|go=1"*"BOB|G|ot=7|go=0"*"PUBLIC|G|ot=7"*)
        echo "OK   ALICE has the grant option, BOB does not, PUBLIC is present" ;;
    *) echo "DIFF the privilege comparison was vacuous"; echo "     $work_priv"; fail=1 ;;
esac
work_acl=$(aclq "$WORK")
check "the exception's security-class ACL matches byte for byte" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 "*" 0 2 6 1 3 12 0 "*) echo "OK   the owner ACE carries alter/control/drop/usage (6 1 3 12)" ;;
    *) echo "DIFF the owner ACE is not as expected"; echo "     $work_acl"; fail=1 ;;
esac

# --- REVOKE ------------------------------------------------------------
check "fire-crab: REVOKE USAGE FROM BOB" "$(node_run "$R_BOB")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$R_BOB;
COMMIT;
EOF
check "after REVOKE, the privilege rows match the engine" "$(privq "$WORK")" "$(privq "$REF")"
check "after REVOKE, the ACL is recomputed to match the engine" "$(aclq "$WORK")" "$(aclq "$REF")"
case "$(privq "$WORK")" in
    *BOB*) echo "DIFF BOB's privilege survived the revoke"; fail=1 ;;
    *) echo "OK   BOB's privilege row is gone after the revoke" ;;
esac

# --- gbak and gfix -----------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-ge-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-ge-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-ge-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-ge-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-ge-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
