#!/bin/bash
# ALTER TABLE ALTER COLUMN ... POSITION n - reorder a column.
#
# Moving a column changes only its display order: RDB$FIELD_POSITION shifts (and
# the runtime's positions follow), while the field ids, the record format and the
# stored bytes stay put. So a reorder is a catalog patch plus a runtime rebuild,
# never a rewrite of the data. A position out of range is refused.
#
# The differential is the engine (both databases start with the same table;
# fire-crab reorders one copy, the engine the other):
#   1. after two moves (a column to the front, another to the back), every
#      RDB$RELATION_FIELDS position/field-id pair matches;
#   2. the RDB$RUNTIME is compared BYTE FOR BYTE (positions moved, ids kept);
#   3. SELECT * returns the columns in the new order with the original data;
#   4. a position below 1 is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-columnposition.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4227}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-pos-work.fdb"; REF="$D/fc-pos-ref.fdb"
FBK="$D/fc-pos-work.fbk"; RST="$D/fc-pos-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE TABLE T (A INTEGER, B INTEGER, C INTEGER, D INTEGER)"
M1="ALTER TABLE T ALTER COLUMN C POSITION 1"
M2="ALTER TABLE T ALTER COLUMN A POSITION 4"
R_OOR="ALTER TABLE T ALTER COLUMN B POSITION 0"
M3="ALTER TABLE T ALTER COLUMN B POSITION 9"

for f in "$REF" "$WORK"; do
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL db $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP;
COMMIT;
EOF
done
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$M1; $M2; $M3;
COMMIT;
EOF
eng_oor=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_OOR;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-pos.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
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
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }
posq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$' | tr '\n' ',' | sed 's/,$//'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||':'||RDB$FIELD_POSITION||'/'||RDB$FIELD_ID FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='T' ORDER BY RDB$FIELD_POSITION;
SQL
}
rtq() { b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT RDB$RUNTIME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-pos-rt.bin; printf 'BLOBDUMP %s /tmp/fc-pos-rt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-pos-rt.bin | tr '\n' ' ' | tr -s ' ' | strip; }

check "fire-crab: move C to position 1" "$(node_run "$M1")" "OK"
check "fire-crab: move A to position 4" "$(node_run "$M2")" "OK"
check "fire-crab: POSITION 9 clamps to the last column" "$(node_run "$M3")" "OK"
r=$(node_run "$R_OOR")
case "$r" in ERR*) echo "OK   a position below 1 is refused" ;;
    *) echo "DIFF out-of-range position accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_oor" in *[Ff]ailed*|*[Ee]rror*) echo "OK   the engine refuses it too" ;;
    *) echo "DIFF engine did not refuse"; echo "     $eng_oor"; fail=1 ;; esac

work_pos=$(posq "$WORK")
check "every RDB\$FIELD_POSITION / field-id matches the engine after the moves" "$work_pos" "$(posq "$REF")"
case "$work_pos" in "C:0/2,D:1/3,A:2/0,B:3/1") echo "OK   order is C,D,A,B (B clamped to last) with ids kept" ;;
    *) echo "DIFF unexpected order"; echo "     $work_pos"; fail=1 ;; esac
check "the RDB\$RUNTIME matches the engine byte for byte (positions moved, ids kept)" "$(rtq "$WORK")" "$(rtq "$REF")"

# SELECT * order and data intact
"$ISQL" -q -b -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (A,B,C,D) VALUES (10,20,30,40); COMMIT;
SQL
row=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT C||'|'||D||'|'||A||'|'||B FROM T;
SQL
)
check "SELECT reads the columns in the new order with the original data (C,D,A,B = 30,40,10,20)" "$row" "30|40|10|20"

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-pos-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-pos-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-pos-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-pos-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-pos-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
