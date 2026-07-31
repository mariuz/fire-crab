#!/bin/bash
# CREATE / DROP EXCEPTION - a named exception, the mirror of a sequence.
#
# CREATE EXCEPTION is the same shape as CREATE SEQUENCE: a RDB$EXCEPTIONS
# row whose number comes from the system generator NAMED RDB$EXCEPTIONS
# (exceptions have their own counter, 1, 2, ...), a SQL$<n> security class
# carrying the owner's ACL - the same alter/control/drop/usage a sequence
# owner holds - and one RDB$USER_PRIVILEGES row, the owner's USAGE grant
# (object type 7). DROP EXCEPTION takes the row, its security class AND the
# privilege; the number counter is not rewound.
#
# Two counters have to advance in lock-step with the engine's, and the
# engine never re-checks the names it draws from them: SQL$<n> from the
# RDB$SECURITY_CLASS generator (RDB$SECURITY_CLASSES has a unique index on
# it) and the exception number from the RDB$EXCEPTIONS generator. A writer
# that invented either would hand the engine a duplicate on its next
# CREATE.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same CREATE / DROP EXCEPTION
#      sequence on two copies of one database; the RDB$EXCEPTIONS rows and
#      the RDB$USER_PRIVILEGES rows are compared;
#   2. the ACL blob is compared byte for byte;
#   3. the engine CONTINUES from fire-crab's file - one more CREATE
#      EXCEPTION must land the same number and the same class name;
#   4. a duplicate name and a missing DROP are refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-exception.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4158}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-exc-src.fdb"; WORK="$D/fc-exc-work.fdb"; REF="$D/fc-exc-ref.fdb"
FBK="$D/fc-exc-work.fbk"; RST="$D/fc-exc-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# three exceptions (one message with a '' escape), then a drop of the
# middle one - so the number counter is proven not to rewind and a class
# is proven to go
E1="CREATE EXCEPTION E_ONE 'the first exception'"
E2="CREATE EXCEPTION E_TWO 'it''s the second'"
E3="CREATE EXCEPTION E_THREE 'the third exception'"
DROP2="DROP EXCEPTION E_TWO"
# refused by both
R_DUP="CREATE EXCEPTION E_ONE 'again'"
R_MISS="DROP EXCEPTION E_NOPE"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$E1; $E2; $E3;
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

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-exc.log 2>&1 &
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

check "CREATE EXCEPTION E_ONE"                 "$(node_run "$E1")" "OK"
check "CREATE EXCEPTION E_TWO (with '' escape)" "$(node_run "$E2")" "OK"
check "CREATE EXCEPTION E_THREE"               "$(node_run "$E3")" "OK"
check "DROP EXCEPTION E_TWO"                    "$(node_run "$DROP2")" "OK"
r=$(node_run "$R_DUP")
case "$r" in ERR*) echo "OK   a duplicate exception name is refused" ;;
    *) echo "DIFF duplicate name accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_MISS")
case "$r" in ERR*) echo "OK   dropping a missing exception is refused" ;;
    *) echo "DIFF missing drop accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_dup" in *already*exists*) echo "OK   the engine refuses the duplicate too" ;;
    *) echo "DIFF engine did not refuse duplicate"; echo "     $eng_dup"; fail=1 ;; esac
case "$eng_miss" in *not*found*) echo "OK   the engine refuses the missing drop too" ;;
    *) echo "DIFF engine did not refuse missing drop"; echo "     $eng_miss"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$EXCEPTIONS rows and the owner privileges ----------------
excq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'EXC|'||TRIM(RDB$EXCEPTION_NAME)||'|'||RDB$EXCEPTION_NUMBER||'|'||TRIM(RDB$MESSAGE)
       ||'|'||COALESCE(RDB$SYSTEM_FLAG,0)||'|'||COALESCE(TRIM(RDB$SECURITY_CLASS),'-')
       ||'|'||TRIM(RDB$OWNER_NAME)||'|'||TRIM(RDB$SCHEMA_NAME)
  FROM RDB$EXCEPTIONS WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 ORDER BY RDB$EXCEPTION_NUMBER;
SELECT 'PRIV|'||TRIM(RDB$RELATION_NAME)||'|'||TRIM(RDB$PRIVILEGE)||'|'||RDB$GRANT_OPTION
       ||'|'||TRIM(RDB$USER)||'|'||RDB$USER_TYPE||'|'||RDB$OBJECT_TYPE
  FROM RDB$USER_PRIVILEGES WHERE RDB$OBJECT_TYPE=7 ORDER BY RDB$RELATION_NAME;
SQL
}
work_exc=$(excq "$WORK")
check "the RDB\$EXCEPTIONS rows and owner privileges match the engine" "$work_exc" "$(excq "$REF")"
case "$work_exc" in
    *"EXC|E_ONE|1|the first exception|0|SQL\$"*"EXC|E_THREE|3|"*"PRIV|E_ONE|G|1|SYSDBA|8|7"*)
        echo "OK   the compared rows carry the numbers, the message and the USAGE grant" ;;
    *) echo "DIFF the exception comparison was vacuous"; echo "     $work_exc"; fail=1 ;;
esac
check "  ... E_TWO is gone (dropped), its number not reused" \
      "$(printf '%s\n' "$work_exc" | grep -c '^EXC|E_TWO|')" "0"
case "$work_exc" in
    *"EXC|E_TWO|"*) echo "DIFF the '' escape row leaked"; fail=1 ;;
    *) echo "OK   the dropped E_TWO (the '' escape one) really is gone" ;;
esac

# --- 2. the ACL blob, byte for byte ------------------------------------
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$EXCEPTIONS E JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = E.RDB$SECURITY_CLASS WHERE E.RDB$EXCEPTION_NAME = 'E_ONE';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-exc-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-exc-acl.bin;\n' "$bid" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-exc-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the owner's ACL blob matches the engine's" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 83 89 83 68 66 65 0 2 6 1 3 12 0 0")
        echo "OK   the ACL is the sequence-owner encoding (alter/control/drop/usage)" ;;
    *) echo "DIFF unexpected ACL encoding"; echo "     got:  $work_acl"; fail=1 ;;
esac

# --- 3. the engine CONTINUES from fire-crab's file ---------------------
# one more CREATE EXCEPTION, by the engine, on each copy: the same number
# (4 - the dropped E_TWO's 2 is not reused) and the same class name only
# if fire-crab advanced both counters.
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<'SQL'
CREATE EXCEPTION E_NEXT 'the continuation';
COMMIT;
SQL
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT RDB$EXCEPTION_NUMBER||'|'||COALESCE(TRIM(RDB$SECURITY_CLASS),'-')
  FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME = 'E_NEXT';
SQL
}
cont_w=$(contq "$WORK"); cont_r=$(contq "$REF")
check "the engine's next exception lands on the same number and class" "$cont_w" "$cont_r"
case "$cont_w" in
    "4|SQL\$"*) echo "OK   the continuation took number 4 (E_TWO's 2 not reused)" ;;
    *) echo "DIFF the continuation was vacuous or reused a number"; echo "     $cont_w"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-exc-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-exc-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-exc-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-exc-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-exc-restore.log | head; fail=1
fi
rst_msg=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT RDB$MESSAGE FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME = 'E_ONE';
SQL
)
check "E_ONE's message survives the round trip" "$rst_msg" "the first exception"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
