#!/bin/bash
# ALTER DOMAIN SET / DROP DEFAULT - change a domain's default in place.
#
# A domain's DEFAULT lives as two blobs on its own RDB$FIELDS row
# (RDB$DEFAULT_SOURCE, the text; RDB$DEFAULT_VALUE, the literal BLR). SET
# DEFAULT writes (or replaces) them; DROP DEFAULT patches both to NULL, leaving
# any prior blob orphaned exactly as the engine does. A column that uses the
# domain without its own default sees the change on its next insert.
#
# fire-crab does not yet declare a table column with a user domain type, so the
# end-to-end proof runs the other way: fire-crab changes the domain, and the
# ENGINE - creating a table that uses it, on fire-crab's own file - inherits the
# new default on an insert that omits the column.
#
# The differential is the engine, five ways (both databases start with the same
# domains, written by the engine; then fire-crab ALTERs one copy, the engine the
# other):
#   1. every RDB$DEFAULT_SOURCE is compared after the ALTERs (SET replaces, SET
#      adds to a domain that had none, DROP clears);
#   2. each RDB$DEFAULT_VALUE BLR is compared BYTE FOR BYTE, and the dropped
#      domain has no value on either;
#   3. the engine INHERITS fire-crab's replaced default: a table it creates on
#      fire-crab's file takes the new default on insert;
#   4. an unknown domain is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-alterdomaindefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4189}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-add-work.fdb"; REF="$D/fc-add-ref.fdb"
FBK="$D/fc-add-work.fbk"; RST="$D/fc-add-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE DOMAIN DOM_A AS INTEGER DEFAULT 1; CREATE DOMAIN DOM_B AS VARCHAR(10); CREATE DOMAIN DOM_C AS INTEGER DEFAULT 7;"
A_SET="ALTER DOMAIN DOM_A SET DEFAULT 99"
B_SET="ALTER DOMAIN DOM_B SET DEFAULT 'hey'"
C_DROP="ALTER DOMAIN DOM_C DROP DEFAULT"
R_UNK="ALTER DOMAIN NOSUCH SET DEFAULT 1"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$A_SET; $B_SET; $C_DROP;
COMMIT;
EOF
eng_unk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_UNK;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-add.log 2>&1 &
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

check "fire-crab: SET DEFAULT 99 (replaces)"        "$(node_run "$A_SET")"  "OK"
check "fire-crab: SET DEFAULT 'hey' (was none)"     "$(node_run "$B_SET")"  "OK"
check "fire-crab: DROP DEFAULT (had 7)"             "$(node_run "$C_DROP")" "OK"
r=$(node_run "$R_UNK")
case "$r" in ERR*) echo "OK   an unknown domain is refused" ;;
    *) echo "DIFF unknown domain accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_unk" in *[Ee]rror*|*"not found"*|*"not defined"*) echo "OK   the engine refuses the unknown domain too" ;;
    *) echo "DIFF engine did not refuse unknown domain"; echo "     $eng_unk"; fail=1 ;; esac

# --- 1. the domain default sources after the ALTERs --------------------
srcq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DEFAULT_SOURCE AS VARCHAR(30)),'<none>')
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME LIKE 'DOM\_%' ESCAPE '\' ORDER BY RDB$FIELD_NAME;
SQL
}
work_src=$(srcq "$WORK")
check "every domain's RDB\$DEFAULT_SOURCE matches the engine after the ALTERs" "$work_src" "$(srcq "$REF")"
case "$work_src" in
    *"DOM_A|DEFAULT 99"*"DOM_B|DEFAULT 'hey'"*"DOM_C|<none>"*)
        echo "OK   SET replaced (A), SET added (B), DROP cleared (C)" ;;
    *) echo "DIFF the source comparison was vacuous or wrong"; echo "     $work_src"; fail=1 ;;
esac

# --- 2. the DEFAULT_VALUE BLR, byte for byte ---------------------------
valblr() { # <file> <domain>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT RDB\$DEFAULT_VALUE FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME='$2';
SQL
)
    [ -n "$bid" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-add-blob.bin
    printf 'BLOBDUMP %s /tmp/fc-add-blob.bin;\n' "$bid" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-add-blob.bin | tr '\n' ' ' | tr -s ' ' | strip
}
for d in DOM_A DOM_B; do
    check "$d: RDB\$DEFAULT_VALUE BLR byte for byte" "$(valblr "$WORK" "$d")" "$(valblr "$REF" "$d")"
done
check "DOM_C (dropped) has no RDB\$DEFAULT_VALUE" "$(valblr "$WORK" DOM_C)" "(none)"

# --- 3. the engine inherits fire-crab's replaced default ---------------
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
CREATE TABLE T (X DOM_A, Y INTEGER);
COMMIT;
INSERT INTO T (Y) VALUES (1);
COMMIT;
SQL
inherited=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COALESCE(CAST(X AS VARCHAR(6)),'null') FROM T;
SQL
)
check "the engine inherits fire-crab's replaced domain default (99)" "$inherited" "99"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-add-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-add-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-add-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-add-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-add-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
