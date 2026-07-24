#!/bin/bash
# CREATE / DROP DOMAIN - a standalone type definition.
#
# A domain is a reusable field definition: one RDB$FIELDS row named by the
# user (no relation link, no security class), the same row a table column's
# auto-domain gets. NOT NULL sets RDB$NULL_FLAG on the domain itself. The
# on-disk detail that matters is that RDB$FIELD_LENGTH is the BYTE length -
# for a VARCHAR(20) that is 20, not the +2 count-word storage length. DROP
# DOMAIN deletes the row and is refused while a table column still uses the
# domain as its RDB$FIELD_SOURCE.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create the same domains on two copies of
#      one database; every RDB$FIELDS row (type, length, char length, scale,
#      sub type, null flag, charset/collation) is compared;
#   2. RDB$FIELD_LENGTH is confirmed to be the char count for VARCHAR;
#   3. a DROP of a domain in use is refused, and a plain DROP removes it,
#      on both;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-domain.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4164}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-dom-src.fdb"; WORK="$D/fc-dom-work.fdb"; REF="$D/fc-dom-ref.fdb"
FBK="$D/fc-dom-work.fbk"; RST="$D/fc-dom-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

C1="CREATE DOMAIN D_INT AS INTEGER"
C2="CREATE DOMAIN D_NAME VARCHAR(20)"
C3="CREATE DOMAIN D_NN AS INTEGER NOT NULL"
C4="CREATE DOMAIN D_AMT AS NUMERIC(9,2)"
DROP1="DROP DOMAIN D_INT"
# refused: a domain used by a table column (D_USED + table T come from
# the shared scratch db, so the domain is in use on both copies)
R_USED="DROP DOMAIN D_USED"
# refused: a missing domain
R_MISS="DROP DOMAIN D_NOPE"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN D_USED AS INTEGER;
CREATE TABLE T (X D_USED);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$C1; $C2; $C3; $C4;
COMMIT;
$DROP1;
COMMIT;
EOF
eng_used=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_USED;
EOF
)
eng_miss=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_MISS;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dom.log 2>&1 &
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

for c in "$C1" "$C2" "$C3" "$C4"; do
    check "$c" "$(node_run "$c")" "OK"
done
check "DROP DOMAIN D_INT (unused)" "$(node_run "$DROP1")" "OK"
r=$(node_run "$R_USED")
case "$r" in ERR*) echo "OK   DROP of a domain in use is refused" ;;
    *) echo "DIFF in-use domain drop accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_MISS")
case "$r" in ERR*) echo "OK   DROP of a missing domain is refused" ;;
    *) echo "DIFF missing domain drop accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_used" in *[Ee]rror*|*"used"*|*"dependencies"*) echo "OK   the engine refuses the in-use drop too" ;;
    *) echo "DIFF engine did not refuse in-use drop"; echo "     $eng_used"; fail=1 ;; esac
case "$eng_miss" in *[Ee]rror*|*"not found"*|*"not exist"*) echo "OK   the engine refuses the missing drop too" ;;
    *) echo "DIFF engine did not refuse missing drop"; echo "     $eng_miss"; fail=1 ;; esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the RDB$FIELDS rows --------------------------------------------
domq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'D|'||TRIM(RDB$FIELD_NAME)||'|typ='||RDB$FIELD_TYPE||'|len='||RDB$FIELD_LENGTH
       ||'|scale='||COALESCE(RDB$FIELD_SCALE,-9)||'|sub='||COALESCE(RDB$FIELD_SUB_TYPE,-9)
       ||'|nn='||COALESCE(RDB$NULL_FLAG,-9)||'|sys='||COALESCE(RDB$SYSTEM_FLAG,-9)
       ||'|cs='||COALESCE(RDB$CHARACTER_SET_ID,-9)||'|clen='||COALESCE(RDB$CHARACTER_LENGTH,-9)
       ||'|coll='||COALESCE(RDB$COLLATION_ID,-9)
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME STARTING WITH 'D_' ORDER BY RDB$FIELD_NAME;
SQL
}
work_dom=$(domq "$WORK")
check "the RDB\$FIELDS domain rows match the engine reference" "$work_dom" "$(domq "$REF")"
case "$work_dom" in
    *"D|D_NAME|typ=37|len=20|"*"clen=20|"*"D|D_NN|typ=8|len=4|scale=0|sub=0|nn=1"*)
        echo "OK   VARCHAR domain length is the char count (20), and NOT NULL set RDB\$NULL_FLAG" ;;
    *) echo "DIFF the domain comparison was vacuous or wrong"; echo "     $work_dom"; fail=1 ;;
esac
case "$work_dom" in
    *"D|D_INT|"*) echo "DIFF D_INT survived the drop"; fail=1 ;;
    *) echo "OK   the dropped D_INT is gone" ;;
esac

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dom-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dom-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dom-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dom-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dom-restore.log | head; fail=1
fi
check "the restored domains match fire-crab's" "$(domq "$RST")" "$(domq "$WORK")"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
