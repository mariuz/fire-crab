#!/bin/bash
# ALTER TABLE ALTER COLUMN SET / DROP DEFAULT - a column's default, changed.
#
# A column default is two blobs on its RDB$RELATION_FIELDS row
# (RDB$DEFAULT_SOURCE, the text; RDB$DEFAULT_VALUE, the literal BLR). SET DEFAULT
# writes (or replaces) them; DROP DEFAULT clears both to NULL. There is no new
# format version (the row layout does not move) - but the default the engine
# actually applies lives in the relation's RDB$RUNTIME summary, so that is
# rebuilt every time, and it is what makes (or unmakes) the default on the next
# insert.
#
# The differential is the engine (both databases start with the same table,
# written by the engine; then fire-crab ALTERs one copy, the engine the other):
#   1. every column's RDB$DEFAULT_SOURCE is compared (SET replaces, SET adds,
#      DROP clears, a string default too);
#   2. the rebuilt RDB$RUNTIME is compared BYTE FOR BYTE (the defaults the
#      engine reads are exactly the engine's);
#   3. the engine applies the result: an INSERT that omits the columns takes
#      the set defaults and leaves the dropped one NULL;
#   4. an unknown column and an unknown table are refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-altercolumndefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4196}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-acd-work.fdb"; REF="$D/fc-acd-ref.fdb"
FBK="$D/fc-acd-work.fbk"; RST="$D/fc-acd-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE TABLE T (A INTEGER DEFAULT 1, B INTEGER, C INTEGER DEFAULT 9, S VARCHAR(8), D INTEGER)"
A_SET="ALTER TABLE T ALTER COLUMN A SET DEFAULT 100"
B_SET="ALTER TABLE T ALTER COLUMN B SET DEFAULT 7"
C_DROP="ALTER TABLE T ALTER COLUMN C DROP DEFAULT"
S_SET="ALTER TABLE T ALTER S SET DEFAULT 'hi'"
R_COL="ALTER TABLE T ALTER COLUMN NOSUCH SET DEFAULT 1"
R_TAB="ALTER TABLE NOSUCH ALTER COLUMN A SET DEFAULT 1"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP;
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$A_SET; $B_SET; $C_DROP; $S_SET;
COMMIT;
EOF
eng_rcol=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_COL;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-acd.log 2>&1 &
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

check "fire-crab: SET DEFAULT 100 (replaces)"   "$(node_run "$A_SET")"  "OK"
check "fire-crab: SET DEFAULT 7 (was none)"     "$(node_run "$B_SET")"  "OK"
check "fire-crab: DROP DEFAULT (had 9)"         "$(node_run "$C_DROP")" "OK"
check "fire-crab: SET DEFAULT 'hi' (string)"    "$(node_run "$S_SET")"  "OK"
r=$(node_run "$R_COL")
case "$r" in ERR*) echo "OK   an unknown column is refused" ;;
    *) echo "DIFF unknown column accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_TAB")
case "$r" in ERR*) echo "OK   an unknown table is refused" ;;
    *) echo "DIFF unknown table accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rcol" in *[Ff]ailed*|*[Ee]rror*|*"does not exist"*) echo "OK   the engine refuses the unknown column too" ;;
    *) echo "DIFF engine did not refuse unknown column"; echo "     $eng_rcol"; fail=1 ;; esac

# --- 1. the default sources --------------------------------------------
srcq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(20)),'<none>')
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_src=$(srcq "$WORK")
check "every column's RDB\$DEFAULT_SOURCE matches the engine after the ALTERs" "$work_src" "$(srcq "$REF")"
case "$work_src" in
    *"A|DEFAULT 100"*"B|DEFAULT 7"*"C|<none>"*"S|DEFAULT 'hi'"*)
        echo "OK   SET replaced (A), SET added (B), DROP cleared (C), string set (S)" ;;
    *) echo "DIFF the source comparison was vacuous or wrong"; echo "     $work_src"; fail=1 ;;
esac

# --- 2. the rebuilt RDB$RUNTIME, byte for byte -------------------------
rtq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-acd-rt.bin
    printf 'BLOBDUMP %s /tmp/fc-acd-rt.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-acd-rt.bin | tr '\n' ' ' | tr -s ' ' | strip
}
check "the rebuilt RDB\$RUNTIME matches the engine byte for byte" "$(rtq "$WORK")" "$(rtq "$REF")"

# --- 3. the engine applies the result ----------------------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (D) VALUES (1);
COMMIT;
SQL
applied=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(A AS VARCHAR(5)),'n')||'|'||COALESCE(CAST(B AS VARCHAR(5)),'n')
       ||'|'||COALESCE(CAST(C AS VARCHAR(5)),'n')||'|'||COALESCE(TRIM(S),'n') FROM T WHERE D=1;
SQL
)
check "an INSERT applies the new defaults (A=100, B=7, C NULL, S=hi)" "$applied" "100|7|n|hi"

# --- 5. gbak and gfix --------------------------------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-acd-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-acd-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-acd-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-acd-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-acd-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
