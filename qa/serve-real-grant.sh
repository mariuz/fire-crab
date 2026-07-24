#!/bin/bash
# GRANT / REVOKE - the privileges a table carries, and the ACL they
# recompute.
#
# A GRANT is two writes, in the engine's order: the fine-grained rows of
# RDB$USER_PRIVILEGES (one per grantee per privilege letter, user type 8,
# object type 0, NULL field name) and a recompute of the relation's OWN
# security-class ACL - the coarse cache the security subsystem reads.
# REVOKE deletes the matching privilege rows and recomputes the ACL again.
#
# The subtlety the engine bakes into the ACL: a named grantee's access
# control entry is its DIRECT privileges UNION whatever PUBLIC holds - a
# user granted only DELETE shows delete AND select once PUBLIC has select,
# because the all-users grant applies to that user too. The entries are
# ordered owner first, named grantees alphabetically, all-users (PUBLIC)
# last, and each privilege list is in the fixed acl.h order
# (insert/update/delete/select/references), not the order granted.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same GRANT / REVOKE sequence on
#      two copies of one database; the RDB$USER_PRIVILEGES rows are
#      compared;
#   2. the relation's ACL blob is compared byte for byte, and the engine's
#      decode of it (SET BLOB ALL) is checked to carry the PUBLIC union;
#   3. SHOW GRANTS is compared verbatim, and a GRANT on a missing table is
#      refused on both;
#   4. the engine CONTINUES from fire-crab's file - one more GRANT, by the
#      engine, must land the same privileges and ACL as on its own copy;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-grant.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4157}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-grant-src.fdb"; WORK="$D/fc-grant-work.fdb"; REF="$D/fc-grant-ref.fdb"
FBK="$D/fc-grant-work.fbk"; RST="$D/fc-grant-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# the sequence applied to both, chosen to exercise: a plain grant, a
# multi-privilege grant WITH GRANT OPTION, a PUBLIC grant (the union
# trigger), a second named user, and a REVOKE that leaves a user with
# some privilege remaining
G1="GRANT SELECT ON T TO BOB"
G2="GRANT INSERT, UPDATE ON T TO ALICE WITH GRANT OPTION"
G3="GRANT SELECT ON T TO PUBLIC"
G4="GRANT DELETE ON T TO CAROL"
R1="REVOKE INSERT ON T FROM ALICE"
# refused by both
RJ="GRANT SELECT ON NOSUCH TO BOB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B VARCHAR(10));
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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-grant.log 2>&1 &
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

check "GRANT SELECT ON T TO BOB"                        "$(node_run "$G1")" "OK"
check "GRANT INSERT, UPDATE ... WITH GRANT OPTION"      "$(node_run "$G2")" "OK"
check "GRANT SELECT ON T TO PUBLIC"                     "$(node_run "$G3")" "OK"
check "GRANT DELETE ON T TO CAROL"                      "$(node_run "$G4")" "OK"
check "REVOKE INSERT ON T FROM ALICE"                   "$(node_run "$R1")" "OK"
r=$(node_run "$RJ")
case "$r" in ERR*) echo "OK   a GRANT on a missing table is refused" ;;
    *) echo "DIFF missing-table grant accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rj" in *[Ee]rror*|*"not"*) echo "OK   the engine refuses it too" ;;
    *) echo "DIFF engine did not refuse the missing-table grant"; echo "     $eng_rj"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$USER_PRIVILEGES rows -----------------------------------
privq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$USER)||'|'||TRIM(RDB$PRIVILEGE)||'|'||RDB$GRANT_OPTION
       ||'|'||TRIM(RDB$GRANTOR)||'|'||RDB$USER_TYPE||'|'||RDB$OBJECT_TYPE
       ||'|'||TRIM(RDB$RELATION_SCHEMA_NAME)||'|'||COALESCE(TRIM(RDB$FIELD_NAME),'-')
  FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME = 'T' AND RDB$USER <> 'SYSDBA'
  ORDER BY RDB$USER, RDB$PRIVILEGE;
SQL
}
work_priv=$(privq "$WORK")
check "the privilege rows match the engine reference" "$work_priv" "$(privq "$REF")"
case "$work_priv" in
    *"ALICE|U|1|"*"BOB|S|0|"*"CAROL|D|0|"*"PUBLIC|S|0|"*)
        echo "OK   the compared rows carry the grantees (ALICE kept UPDATE, INSERT revoked)" ;;
    *) echo "DIFF the privilege comparison was vacuous"; echo "     $work_priv"; fail=1 ;;
esac
check "  ... ALICE's INSERT row is gone (revoked)" \
      "$(printf '%s\n' "$work_priv" | grep -c '^ALICE|I|')" "0"

# --- 2. the ACL blob, byte for byte, and the PUBLIC union --------------
aclbytes() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$RELATIONS R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-grant-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-grant-acl.bin;\n' "$bid" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-grant-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclbytes "$WORK")
check "the recomputed ACL blob matches the engine's byte for byte" "$work_acl" "$(aclbytes "$REF")"
acldecode() { # <file> - only the decoded ACL lines (the blob-id header
    # line and the === rules differ trivially between two files)
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -E 'ACL version|person:|all users:'
SET BLOB ALL; SET HEADING OFF;
SELECT C.RDB$ACL FROM RDB$RELATIONS R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$RELATION_NAME = 'T';
SQL
}
work_dec=$(acldecode "$WORK")
check "the engine's ACL decode matches on both" "$work_dec" "$(acldecode "$REF")"
# the union rule, made observable: CAROL was granted only DELETE, but the
# ACL grants her delete AND select because PUBLIC holds select
case "$work_dec" in
    *"CAROL"*"delete, select"*) echo "OK   the PUBLIC union is in the ACL (CAROL: delete, select)" ;;
    *) echo "DIFF the ACL does not carry the PUBLIC union"; echo "     $work_dec"; fail=1 ;;
esac
case "$work_dec" in
    *"all users"*"(select)"*) echo "OK   the all-users (PUBLIC) entry carries select" ;;
    *) echo "DIFF the all-users entry is wrong"; echo "     $work_dec"; fail=1 ;;
esac

# --- 3. SHOW GRANTS ----------------------------------------------------
showq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SHOW GRANTS;
SQL
}
ref_show=$(showq "$REF")
check "SHOW GRANTS is identical" "$(showq "$WORK")" "$ref_show"
case "$ref_show" in
    *GRANT*BOB*) echo "OK   SHOW GRANTS really printed the grants" ;;
    *) echo "DIFF SHOW GRANTS printed nothing useful"; fail=1 ;;
esac

# --- 4. the engine CONTINUES from fire-crab's file ---------------------
# one more GRANT, by the engine, on each copy. The engine recomputes the
# ACL from the RDB$USER_PRIVILEGES rows fire-crab wrote - so the rows and
# the resulting ACL must match only if fire-crab's rows were right.
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<'SQL'
GRANT REFERENCES ON T TO DAVE;
COMMIT;
SQL
    privq "$1"; aclbytes "$1"
}
cont_w=$(contq "$WORK"); cont_r=$(contq "$REF")
check "the engine's next GRANT lands identically on fire-crab's file" "$cont_w" "$cont_r"
case "$cont_w" in
    *"DAVE|R|0|"*) echo "OK   the continuation really added DAVE's grant" ;;
    *) echo "DIFF the continuation was vacuous"; echo "     $cont_w"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-grant-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-grant-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-grant-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-grant-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-grant-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
