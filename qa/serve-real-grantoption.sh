#!/bin/bash
# REVOKE GRANT OPTION FOR - drop the grant option, keep the privilege.
#
# A plain REVOKE deletes the privilege row. REVOKE GRANT OPTION FOR <priv>
# instead keeps the row and sets its RDB$GRANT_OPTION to 0 - the grantee
# still holds the privilege but may no longer pass it on. The ACL does not
# encode the grant option, so it is not recomputed (it stays as it stands).
#
# The differential is the engine, three ways:
#   1. fire-crab and the engine apply the same statements on two copies of
#      one database; the RDB$USER_PRIVILEGES rows (privilege and grant
#      option) are compared;
#   2. the revoked-option privilege is confirmed still present with option 0
#      while its sibling keeps option 1, and the ACL blob is compared byte
#      for byte (unchanged);
#   3. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-grantoption.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4168}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-go-src.fdb"; WORK="$D/fc-go-work.fdb"; REF="$D/fc-go-ref.fdb"
FBK="$D/fc-go-work.fbk"; RST="$D/fc-go-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

G1="GRANT SELECT ON T TO BOB WITH GRANT OPTION"
G2="GRANT UPDATE ON T TO BOB WITH GRANT OPTION"
R1="REVOKE GRANT OPTION FOR SELECT ON T FROM BOB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B INTEGER);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$G1; $G2; $R1;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-go.log 2>&1 &
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

check "GRANT SELECT ... WITH GRANT OPTION"       "$(node_run "$G1")" "OK"
check "GRANT UPDATE ... WITH GRANT OPTION"       "$(node_run "$G2")" "OK"
check "REVOKE GRANT OPTION FOR SELECT"           "$(node_run "$R1")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the privilege rows ---------------------------------------------
privq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$PRIVILEGE)||'|opt='||RDB$GRANT_OPTION
  FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME='T' AND RDB$USER='BOB'
  ORDER BY RDB$PRIVILEGE;
SQL
}
work_priv=$(privq "$WORK")
check "BOB's privilege rows match the engine reference" "$work_priv" "$(privq "$REF")"
case "$work_priv" in
    "S|opt=0"$'\n'"U|opt=1")
        echo "OK   SELECT kept (option now 0), UPDATE keeps its option 1" ;;
    *) echo "DIFF the option comparison was vacuous or wrong"; echo "     $work_priv"; fail=1 ;;
esac

# --- 2. the ACL is unchanged (byte for byte) ---------------------------
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$RELATIONS R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-go-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-go-acl.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-go-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the ACL matches the engine's byte for byte (BOB still has update, select)" \
      "$(aclq "$WORK")" "$(aclq "$REF")"

# --- 3. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-go-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-go-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-go-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-go-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-go-restore.log | head; fail=1
fi
check "the restored options match fire-crab's" "$(privq "$RST")" "$(privq "$WORK")"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
