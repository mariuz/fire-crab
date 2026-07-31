#!/bin/bash
# THE SECURITY CATALOG OF A TABLE. Creating a table is not three
# catalog relations, it is five: beside RDB$RELATIONS, RDB$RELATION_FIELDS
# and RDB$FORMATS the engine writes
#
#   * an RDB$SECURITY_CLASSES row named SQL$<n>, carrying the owner's
#     ACL - the relation's RDB$SECURITY_CLASS;
#   * a SECOND one named SQL$DEFAULT<n>, the RDB$DEFAULT_CLASS its
#     fields inherit, with the same ACL;
#   * five RDB$USER_PRIVILEGES rows, the owner's S/I/U/D/R
#     WITH GRANT OPTION (user type 8, object type 0).
#
# The two class NAMES come from two different counters in the generator
# vector - slot 1 (RDB$SECURITY_CLASS, the SQL$<n> counter) and slot 2
# (the system generator actually named SQL$DEFAULT) - and, unlike the
# generated INTEG_/RDB$<n> names, the engine does NOT check whether the
# name it gets is free. RDB$SECURITY_CLASSES has a unique index on the
# column, so a writer that invented a name without advancing the counter
# would hand the engine a duplicate-key error on its next CREATE TABLE.
#
# The ACL is the engine's own encoding (acl.h): version 2, an id list
# naming the owner as a person, then alter, control, drop, insert,
# update, delete, select, references.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine create the same tables on two copies of
#      one database; RDB$RELATIONS' class columns, the
#      RDB$SECURITY_CLASSES rows and the RDB$USER_PRIVILEGES rows are
#      compared;
#   2. the ACL BLOB is compared byte for byte, and the engine's own
#      SHOW GRANTS is compared verbatim;
#   3. the engine CONTINUES from fire-crab's file - its next CREATE
#      TABLE must land the same two class names as on its own copy,
#      which it can only do if fire-crab advanced both counters;
#   4. DROP TABLE takes the relation's class row and its privileges and
#      LEAVES the SQL$DEFAULT<n> row behind, exactly as the engine's
#      does;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-security.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4151}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-sec-src.fdb"; WORK="$D/fc-sec-work.fdb"; REF="$D/fc-sec-ref.fdb"
FBK="$D/fc-sec-work.fbk"; RST="$D/fc-sec-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

T1="CREATE TABLE T1 (A INTEGER NOT NULL, B VARCHAR(10), CONSTRAINT PK_T1 PRIMARY KEY (A))"
T2="CREATE TABLE T2 (X INTEGER)"
T3="CREATE TABLE T3 (Y INTEGER, Z VARCHAR(4))"
DROP2="DROP TABLE T2"

# one scratch database, copied - so both counters start identical
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$T1; $T2; $T3;
COMMIT;
$DROP2;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-sec.log 2>&1 &
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

check "create T1 (with a PRIMARY KEY)" "$(node_run "$T1")" "OK"
check "create T2"                      "$(node_run "$T2")" "OK"
check "create T3"                      "$(node_run "$T3")" "OK"
check "drop T2"                        "$(node_run "$DROP2")" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the security catalog -------------------------------------------
secq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'REL|'||TRIM(RDB$RELATION_NAME)||'|'||COALESCE(TRIM(RDB$SECURITY_CLASS),'-')
       ||'|'||COALESCE(TRIM(RDB$DEFAULT_CLASS),'-')||'|'||TRIM(RDB$OWNER_NAME)
  FROM RDB$RELATIONS WHERE COALESCE(RDB$SYSTEM_FLAG,0) = 0 ORDER BY RDB$RELATION_NAME;
SELECT 'PRIV|'||TRIM(RDB$RELATION_NAME)||'|'||TRIM(RDB$PRIVILEGE)||'|'||RDB$GRANT_OPTION
       ||'|'||TRIM(RDB$USER)||'|'||TRIM(RDB$GRANTOR)||'|'||RDB$USER_TYPE||'|'||RDB$OBJECT_TYPE
       ||'|'||TRIM(RDB$RELATION_SCHEMA_NAME)||'|'||COALESCE(TRIM(RDB$FIELD_NAME),'-')
  FROM RDB$USER_PRIVILEGES WHERE RDB$OBJECT_TYPE = 0
  ORDER BY RDB$RELATION_NAME, RDB$PRIVILEGE;
SELECT 'CLASS|'||TRIM(C.RDB$SECURITY_CLASS) FROM RDB$SECURITY_CLASSES C
  WHERE C.RDB$SECURITY_CLASS IN (SELECT R.RDB$SECURITY_CLASS FROM RDB$RELATIONS R
                                   WHERE COALESCE(R.RDB$SYSTEM_FLAG,0) = 0)
     OR C.RDB$SECURITY_CLASS IN (SELECT R.RDB$DEFAULT_CLASS FROM RDB$RELATIONS R
                                   WHERE COALESCE(R.RDB$SYSTEM_FLAG,0) = 0)
  ORDER BY 1;
SELECT 'CLASSES|'||COUNT(*) FROM RDB$SECURITY_CLASSES;
SQL
}
work_sec=$(secq "$WORK")
check "the security catalog matches the engine reference" "$work_sec" "$(secq "$REF")"
# teeth: the compared catalog really carries classes and privileges
case "$work_sec" in
    *"REL|T1|SQL\$"*"|SQL\$DEFAULT"*"PRIV|T1|R|1|"*)
        echo "OK   the compared rows really carry a class and the owner's privileges" ;;
    *) echo "DIFF the security comparison was vacuous"; echo "     $work_sec"; fail=1 ;;
esac
check "  ... five privileges per table" \
      "$(printf '%s\n' "$work_sec" | grep -c '^PRIV|T1|')" "5"

# --- 2. the ACL blob, byte for byte, and SHOW GRANTS -------------------
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$RELATIONS R JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = R.RDB$SECURITY_CLASS WHERE R.RDB$RELATION_NAME = 'T1';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-sec-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-sec-acl.bin;\n' "$bid" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-sec-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the owner's ACL blob matches the engine's" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 83 89 83 68 66 65 0 2 6 1 3 7 9 8 4 10 0 0")
        echo "OK   the ACL is the engine's own encoding (acl.h: alter/control/drop/insert/update/delete/select/references)" ;;
    *) echo "DIFF unexpected ACL encoding"; echo "     got:  $work_acl"; fail=1 ;;
esac
showq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SHOW GRANTS;
SQL
}
ref_show=$(showq "$REF")
check "SHOW GRANTS is identical" "$(showq "$WORK")" "$ref_show"
case "$ref_show" in
    *GRANT*) echo "OK   SHOW GRANTS really printed grants" ;;
    *) echo "DIFF SHOW GRANTS printed nothing - the comparison was vacuous"; fail=1 ;;
esac

# --- 4. what DROP TABLE left behind ------------------------------------
# the dropped table's class row and privileges are gone on both; its
# SQL$DEFAULT<n> row survives on both (the engine leaves it)
gone() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'DROPPED-PRIVS|'||COUNT(*) FROM RDB$USER_PRIVILEGES
  WHERE RDB$RELATION_NAME = 'T2' AND RDB$OBJECT_TYPE = 0;
SELECT 'ORPHAN-DEFAULTS|'||COUNT(*) FROM RDB$SECURITY_CLASSES C
  WHERE C.RDB$SECURITY_CLASS STARTING WITH 'SQL$DEFAULT'
    AND NOT EXISTS (SELECT 1 FROM RDB$RELATIONS R
                      WHERE R.RDB$DEFAULT_CLASS = C.RDB$SECURITY_CLASS);
SQL
}
work_gone=$(gone "$WORK")
check "DROP TABLE removed the privileges and left the default class" "$work_gone" "$(gone "$REF")"
case "$work_gone" in
    *"DROPPED-PRIVS|0"*) echo "OK   the dropped table's privileges really are gone" ;;
    *) echo "DIFF the dropped table kept privileges"; echo "     $work_gone"; fail=1 ;;
esac

# --- 3. the engine CONTINUES from fire-crab's file ---------------------
# one more CREATE TABLE, by the engine, on each copy: the same two class
# names only if fire-crab advanced both counters. Without that the
# unique index on RDB$SECURITY_CLASSES would reject the engine's row.
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 >/dev/null <<'SQL'
CREATE TABLE T_NEXT (Q INTEGER);
COMMIT;
SQL
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(TRIM(RDB$SECURITY_CLASS),'-')||'|'||COALESCE(TRIM(RDB$DEFAULT_CLASS),'-')
  FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T_NEXT';
SQL
}
cont_w=$(contq "$WORK"); cont_r=$(contq "$REF")
check "the engine's next table lands on the same two class names" "$cont_w" "$cont_r"
case "$cont_w" in
    "SQL\$"*"|SQL\$DEFAULT"*) echo "OK   the continuation really allocated both classes" ;;
    *) echo "DIFF the continuation check was vacuous"; echo "     $cont_w"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-sec-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-sec-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-sec-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-sec-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-sec-restore.log | head; fail=1
fi
check "the restored copy grants the same privileges" "$(showq "$RST")" "$(showq "$WORK")"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
