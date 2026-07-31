#!/bin/bash
# PER-COLUMN GRANT / REVOKE - the field-level privileges, and the ACL
# recompile they drive.
#
# GRANT UPDATE|REFERENCES (<cols>) ON <t> TO <grantees> writes a
# RDB$USER_PRIVILEGES row per grantee per column (RDB$FIELD_NAME set) and,
# for each granted column, a SQL$GRANT<n> security class of its own on
# RDB$RELATION_FIELDS.RDB$SECURITY_CLASS. The recompute is a faithful port
# of the engine's GRANT_privileges (grant.epp): the relation's own ACL now
# folds in the field grantees, ordered by a squeeze-and-reappend that puts
# a grantee after their LAST granted field - so a grantee on two columns
# lands out of alphabetical order in the relation ACL, exactly as the
# engine writes it. When field grants add a grantee the relation did not
# have, the default class (RDB$DEFAULT_CLASS) is rebuilt without them.
#
# REVOKE deletes the field rows and recompiles; a column whose last grant
# is removed loses its SQL$GRANT<n> class (dropped) and its
# RDB$SECURITY_CLASS (cleared to NULL).
#
# The differential is the engine, five ways:
#   1. the same GRANT / REVOKE sequence on two copies of one database; the
#      RDB$USER_PRIVILEGES rows and RDB$RELATION_FIELDS.RDB$SECURITY_CLASS
#      columns are compared;
#   2. the relation's ACL, the default class ACL and each field's class ACL
#      are compared BYTE FOR BYTE - including the out-of-order relation ACL;
#   3. a revoked column's class is gone and its column class is NULL on both;
#   4. a grant on a missing column is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-colgrant.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4161}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-cg-src.fdb"; WORK="$D/fc-cg-work.fdb"; REF="$D/fc-cg-ref.fdb"
FBK="$D/fc-cg-work.fbk"; RST="$D/fc-cg-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# a relation grant (ZARA), column grants that make BOB span two columns
# (the reorder trigger), a PUBLIC grant (the union), then a REVOKE that
# empties column B
G1="GRANT SELECT ON T TO ZARA"
G2="GRANT UPDATE (A, B) ON T TO BOB"
G3="GRANT REFERENCES (A) ON T TO CAROL"
G4="GRANT UPDATE (A) ON T TO DAVE"
G5="GRANT SELECT ON T TO PUBLIC"
R1="REVOKE UPDATE (B) ON T FROM BOB"
RJ="GRANT UPDATE (NOSUCH) ON T TO BOB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B INTEGER, C INTEGER);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$G1; $G2; $G3; $G4; $G5; $R1;
COMMIT;
EOF
eng_rj=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$RJ;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cg.log 2>&1 &
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

for g in "$G1" "$G2" "$G3" "$G4" "$G5" "$R1"; do
    check "$g" "$(node_run "$g")" "OK"
done
r=$(node_run "$RJ")
case "$r" in ERR*) echo "OK   a grant on a missing column is refused" ;;
    *) echo "DIFF missing-column grant accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rj" in *[Ee]rror*|*"does not exist"*|*"not defined"*) echo "OK   the engine refuses it too" ;;
    *) echo "DIFF engine did not refuse the missing-column grant"; echo "     $eng_rj"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. privilege rows and each column's security class ----------------
rowsq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'P|'||TRIM(RDB$USER)||'|'||TRIM(RDB$PRIVILEGE)||'|'||COALESCE(TRIM(RDB$FIELD_NAME),'-')||'|'||RDB$GRANT_OPTION
  FROM RDB$USER_PRIVILEGES WHERE RDB$RELATION_NAME='T' AND RDB$USER<>'SYSDBA'
  ORDER BY RDB$USER, RDB$FIELD_NAME NULLS FIRST, RDB$PRIVILEGE;
SELECT 'FC|'||TRIM(RDB$FIELD_NAME)||'|'||CASE WHEN RDB$SECURITY_CLASS IS NULL THEN 'null'
       WHEN RDB$SECURITY_CLASS STARTING WITH 'SQL$GRANT' THEN 'grantclass' ELSE TRIM(RDB$SECURITY_CLASS) END
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_rows=$(rowsq "$WORK")
check "the privilege rows and column classes match the engine" "$work_rows" "$(rowsq "$REF")"
case "$work_rows" in
    *"P|BOB|U|A|"*"P|CAROL|R|A|"*"P|DAVE|U|A|"*"P|ZARA|S|-|"*"FC|A|grantclass"*"FC|B|null"*"FC|C|null"*)
        echo "OK   the rows carry the column grants; A has a class, B was emptied, C untouched" ;;
    *) echo "DIFF the row comparison was vacuous"; echo "     $work_rows"; fail=1 ;;
esac
case "$work_rows" in
    *"P|BOB|U|B|"*) echo "DIFF BOB still has the revoked UPDATE(B)"; fail=1 ;;
    *) echo "OK   BOB's UPDATE(B) row is gone (revoked)" ;;
esac

# --- 2. the ACLs, byte for byte ----------------------------------------
aclbytes() { # <file> <select>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
$2
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-cg-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-cg-acl.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-cg-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
REL="SELECT C.RDB\$ACL FROM RDB\$RELATIONS R JOIN RDB\$SECURITY_CLASSES C ON C.RDB\$SECURITY_CLASS=R.RDB\$SECURITY_CLASS WHERE R.RDB\$RELATION_NAME='T';"
DEF="SELECT C.RDB\$ACL FROM RDB\$RELATIONS R JOIN RDB\$SECURITY_CLASSES C ON C.RDB\$SECURITY_CLASS=R.RDB\$DEFAULT_CLASS WHERE R.RDB\$RELATION_NAME='T';"
FA="SELECT C.RDB\$ACL FROM RDB\$RELATION_FIELDS F JOIN RDB\$SECURITY_CLASSES C ON C.RDB\$SECURITY_CLASS=F.RDB\$SECURITY_CLASS WHERE F.RDB\$RELATION_NAME='T' AND F.RDB\$FIELD_NAME='A';"
check "the relation ACL matches byte for byte (the reordered grantees)" "$(aclbytes "$WORK" "$REL")" "$(aclbytes "$REF" "$REL")"
check "the default class ACL matches byte for byte (restrct)"           "$(aclbytes "$WORK" "$DEF")" "$(aclbytes "$REF" "$DEF")"
check "field A's class ACL matches byte for byte"                        "$(aclbytes "$WORK" "$FA")" "$(aclbytes "$REF" "$FA")"
# teeth: the relation ACL is NOT plain alphabetical - the relation grantee
# ZARA precedes the field grantees BOB/CAROL/DAVE (they are appended after
# the relation-level grantees), which an alphabetical sort (B < Z) would
# never produce
relacl=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -E 'person:'
SET BLOB ALL; SET HEADING OFF;
SELECT C.RDB$ACL FROM RDB$RELATIONS R JOIN RDB$SECURITY_CLASSES C ON C.RDB$SECURITY_CLASS=R.RDB$SECURITY_CLASS WHERE R.RDB$RELATION_NAME='T';
SQL
)
zpos=$(printf '%s\n' "$relacl" | grep -n 'ZARA' | head -1 | cut -d: -f1)
bpos=$(printf '%s\n' "$relacl" | grep -n 'BOB' | head -1 | cut -d: -f1)
if [ -n "$zpos" ] && [ -n "$bpos" ] && [ "$zpos" -lt "$bpos" ]; then
    echo "OK   ZARA (relation grantee) precedes BOB (field grantee) - not alphabetical order"
else
    echo "DIFF the relation ACL order teeth (ZARA=$zpos BOB=$bpos)"; printf '%s\n' "$relacl"; fail=1
fi

# --- 4. the engine CONTINUES from fire-crab's file ---------------------
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<'SQL'
GRANT UPDATE (C) ON T TO EVE;
COMMIT;
SQL
    aclbytes "$1" "$REL"
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CASE WHEN RDB$SECURITY_CLASS STARTING WITH 'SQL$GRANT' THEN 'grantclass' ELSE 'other' END
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' AND RDB$FIELD_NAME='C';
SQL
}
check "the engine's next column grant lands identically on fire-crab's file" "$(contq "$WORK")" "$(contq "$REF")"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cg-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cg-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cg-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cg-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cg-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
