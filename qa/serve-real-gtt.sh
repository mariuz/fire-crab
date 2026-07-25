#!/bin/bash
# GLOBAL TEMPORARY TABLE - a table whose rows are per-connection.
#
# A GTT is an ordinary table's catalog with one field different:
# RDB$RELATION_TYPE is 5 for ON COMMIT DELETE ROWS (the default) and 4 for ON
# COMMIT PRESERVE ROWS, where a persistent table is 0. Everything else - the
# fields, the format, the runtime, the security catalog - is written exactly as
# a regular CREATE TABLE. (The rows themselves live in per-connection temporary
# space at runtime, which is not part of what fire-crab writes.)
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine create three GTTs (DELETE / PRESERVE / no
#      clause) and one persistent table on two copies; every RDB$RELATION_TYPE
#      is compared;
#   2. one GTT's RDB$FORMATS descriptor is compared BYTE FOR BYTE (the field
#      layout is a regular table's);
#   3. the engine can use a GTT fire-crab wrote (an insert succeeds);
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-gtt.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4229}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-gtt-work.fdb"; REF="$D/fc-gtt-ref.fdb"
FBK="$D/fc-gtt-work.fbk"; RST="$D/fc-gtt-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

G1="CREATE GLOBAL TEMPORARY TABLE G1 (A INTEGER, B VARCHAR(5)) ON COMMIT DELETE ROWS"
G2="CREATE GLOBAL TEMPORARY TABLE G2 (A INTEGER) ON COMMIT PRESERVE ROWS"
G3="CREATE GLOBAL TEMPORARY TABLE G3 (A INTEGER)"
R="CREATE TABLE R (A INTEGER)"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$G1; $G2; $G3; $R;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL work db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-gtt.log 2>&1 &
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

check "fire-crab: GTT ON COMMIT DELETE ROWS" "$(node_run "$G1")" "OK"
check "fire-crab: GTT ON COMMIT PRESERVE ROWS" "$(node_run "$G2")" "OK"
check "fire-crab: GTT with no ON COMMIT clause" "$(node_run "$G3")" "OK"
check "fire-crab: a plain persistent table still works" "$(node_run "$R")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

typeq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$RELATION_NAME)||'|'||RDB$RELATION_TYPE FROM RDB$RELATIONS WHERE RDB$RELATION_NAME IN ('G1','G2','G3','R') ORDER BY 1;
SQL
}
work_t=$(typeq "$WORK")
check "every RDB\$RELATION_TYPE matches the engine" "$work_t" "$(typeq "$REF")"
case "$work_t" in *"G1|5"*"G2|4"*"G3|5"*"R|0"*)
    echo "OK   DELETE ROWS is 5, PRESERVE ROWS is 4, the default is 5, persistent is 0" ;;
    *) echo "DIFF vacuous"; echo "     $work_t"; fail=1 ;; esac

fmtq() { b=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON; SELECT f.RDB$DESCRIPTOR FROM RDB$FORMATS f JOIN RDB$RELATIONS r ON r.RDB$RELATION_ID = f.RDB$RELATION_ID WHERE r.RDB$RELATION_NAME='G1';
SQL
); [ -n "$b" ] || { echo "(none)"; return; }
    rm -f /tmp/fc-gtt-fmt.bin; printf 'BLOBDUMP %s /tmp/fc-gtt-fmt.bin;\n' "$b" | "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-gtt-fmt.bin | tr '\n' ' ' | tr -s ' ' | strip; }
check "a GTT's RDB\$FORMATS descriptor matches the engine byte for byte" "$(fmtq "$WORK")" "$(fmtq "$REF")"

# the engine can use it (an insert into a GTT fire-crab wrote succeeds)
ins=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO G2 (A) VALUES (1); COMMIT;
SQL
)
case "$ins" in *[Ee]rror*) echo "DIFF the engine could not use the GTT"; echo "     $ins"; fail=1 ;;
    *) echo "OK   the engine inserts into a GTT fire-crab wrote" ;; esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-gtt-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else echo "DIFF gbak backup"; cat /tmp/fc-gtt-backup.log; fail=1; fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-gtt-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-gtt-restore.log; then echo "OK   gbak RESTORES it"
else echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-gtt-restore.log | head; fail=1; fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
exit $fail
