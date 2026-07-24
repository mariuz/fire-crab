#!/bin/bash
# ALTER EXCEPTION / CREATE OR ALTER EXCEPTION - changing an exception's
# message.
#
# ALTER EXCEPTION <name> <message> rewrites RDB$MESSAGE in place, leaving
# the number and the security class untouched (the exception must exist).
# CREATE OR ALTER EXCEPTION alters it when it exists - keeping its number -
# and creates it (allocating the next number) when it does not, so the same
# statement is the create arm on a fresh name and the alter arm on a known
# one.
#
# The differential is the engine, four ways:
#   1. the same ALTER / CREATE OR ALTER statements on two copies of one
#      database; every RDB$EXCEPTIONS row (message, number, class) is
#      compared;
#   2. the number and security class are confirmed unchanged by an ALTER,
#      and a CREATE OR ALTER of a new exception is confirmed to take the
#      next number;
#   3. an ALTER of a missing exception is refused on both;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-altexception.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4163}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-ae-src.fdb"; WORK="$D/fc-ae-work.fdb"; REF="$D/fc-ae-ref.fdb"
FBK="$D/fc-ae-work.fbk"; RST="$D/fc-ae-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

A1="ALTER EXCEPTION E_ONE 'the altered message'"
A2="CREATE OR ALTER EXCEPTION E_TWO 'it''s now changed'"
A3="CREATE OR ALTER EXCEPTION E_FRESH 'made by create-or-alter'"
R_MISS="ALTER EXCEPTION NOPE 'x'"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE EXCEPTION E_ONE 'the first message';
CREATE EXCEPTION E_TWO 'the second message';
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$A1; $A2; $A3;
COMMIT;
EOF
eng_miss=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_MISS;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ae.log 2>&1 &
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

check "ALTER EXCEPTION E_ONE"                            "$(node_run "$A1")" "OK"
check "CREATE OR ALTER EXCEPTION E_TWO (existing, '' escape)" "$(node_run "$A2")" "OK"
check "CREATE OR ALTER EXCEPTION E_FRESH (new)"          "$(node_run "$A3")" "OK"
r=$(node_run "$R_MISS")
case "$r" in ERR*) echo "OK   ALTER of a missing exception is refused" ;;
    *) echo "DIFF missing-exception alter accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_miss" in *[Ee]rror*|*"not found"*) echo "OK   the engine refuses it too" ;;
    *) echo "DIFF engine did not refuse the missing alter"; echo "     $eng_miss"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$EXCEPTIONS rows ----------------------------------------
excq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'EXC|'||TRIM(RDB$EXCEPTION_NAME)||'|'||RDB$EXCEPTION_NUMBER||'|'||TRIM(RDB$MESSAGE)
       ||'|'||COALESCE(TRIM(RDB$SECURITY_CLASS),'-')||'|'||TRIM(RDB$OWNER_NAME)
  FROM RDB$EXCEPTIONS WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 ORDER BY RDB$EXCEPTION_NUMBER;
SQL
}
work_exc=$(excq "$WORK")
check "the RDB\$EXCEPTIONS rows match the engine reference" "$work_exc" "$(excq "$REF")"
case "$work_exc" in
    *"EXC|E_ONE|1|the altered message|SQL\$"*"EXC|E_TWO|2|it's now changed|SQL\$"*"EXC|E_FRESH|3|made by create-or-alter|SQL\$"*)
        echo "OK   the messages changed; E_ONE/E_TWO kept numbers 1/2, E_FRESH took 3" ;;
    *) echo "DIFF the exception comparison was vacuous or wrong"; echo "     $work_exc"; fail=1 ;;
esac
# teeth: the altered exceptions kept their original numbers (an ALTER is
# not a drop-and-recreate)
n1=$(printf '%s\n' "$work_exc" | grep '^EXC|E_ONE|' | cut -d'|' -f3)
check "  ... ALTER kept E_ONE's number (1, not a new one)" "$n1" "1"

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-ae-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-ae-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-ae-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-ae-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-ae-restore.log | head; fail=1
fi
rst_msg=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT RDB$MESSAGE FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME = 'E_TWO';
SQL
)
check "E_TWO's altered message (with its '' escape) survives the round trip" "$rst_msg" "it's now changed"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
